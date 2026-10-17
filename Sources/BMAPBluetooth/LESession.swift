// BMAP over Bluetooth LE: the GATT service the Bose app uses. A second way in,
// for when another host holds the Classic control channel.

import BMAP
import CoreBluetooth
import Foundation

public final class LESession: NSObject, Requester, CBCentralManagerDelegate, CBPeripheralDelegate {
    public static let service = CBUUID(string: "FEBE")
    /// Needs an encrypted link, which the Classic bond provides.
    public static let secureCharacteristic = CBUUID(string: "C65B8F2F-AEE2-4C89-B758-BC4892D6F2D8")
    public static let plainCharacteristic = CBUUID(string: "D417C028-9818-4354-99D1-2AC09D074591")

    /// Every packet sent and received, as Session reports them.
    public var onTraffic: ((_ outgoing: Bool, _ packet: Packet) -> Void)?
    /// What was found along the way, for --trace.
    public private(set) var notes: [String] = []
    /// Every notification as raw bytes, before framing, for --trace.
    public var onRaw: ((String) -> Void)?

    private let queue = DispatchQueue(label: "bosectl.le")
    private let event = DispatchSemaphore(value: 0)
    private var central: CBCentralManager?

    // Touched only on `queue`.
    private var state = CBManagerState.unknown
    private var name: String?
    private var heard: CBPeripheral?
    private var peripheral: CBPeripheral?
    private var connected = false
    private var disconnected = false
    private var discovered = false
    private var characteristic: CBCharacteristic?
    private var notifying = false
    private var failure: String?
    private var reader = PacketReader()
    private var segments = LESegments.Reassembler()
    private var received: [Packet] = []
    private var raw: [String] = []
    private var subscribed: [CBCharacteristic] = []

    /// Connects over LE to the Bose headphones advertising `name`, or to the
    /// first Bose headphones heard when it is nil.
    public init(name: String?, timeout: TimeInterval = 10) throws
    {
        super.init()
        self.name = name
        central = CBCentralManager(delegate: self, queue: queue)
        let deadline = Date().addingTimeInterval(timeout)
        try wait(until: deadline, "Bluetooth LE to start") { $0.state != .unknown && $0.state != .resetting }
        guard queue.sync(execute: { state }) == .poweredOn else {
            throw LEError("Bluetooth LE is not available (state \(queue.sync { state.rawValue }))")
        }
        try connect(by: deadline)
    }

    deinit {
        close()
    }

    public func close()
    {
        queue.sync {
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
            peripheral = nil
        }
    }

    // MARK: Requests

    public func request(_ packet: Packet, accept: Set<Address>, collect: Collect, timeout: TimeInterval) throws -> [Packet]
    {
        _ = take()
        try write(packet)
        var collector = AnswerCollector(request: packet, accept: accept, collect: collect)
        var deadline = Date().addingTimeInterval(timeout)
        while true {
            for p in take() {
                guard case .progress = try collector.feed(p) else { continue }
                if collector.done { return collector.answers }
                if case .all(let quiet) = collect, !collector.answers.isEmpty {
                    deadline = Date().addingTimeInterval(quiet)
                } else {
                    deadline = Date().addingTimeInterval(timeout)
                }
            }
            if let failure = queue.sync(execute: { failure }) { throw LEError(failure) }
            if queue.sync(execute: { disconnected }) { throw BluetoothError.closedByPeer }
            if Date() >= deadline {
                if case .all = collect, !collector.answers.isEmpty { return collector.answers }
                throw BluetoothError.timeout("a reply to \(packet.address) \(packet.op.name) over LE")
            }
            _ = event.wait(timeout: .now() + 0.05)
        }
    }

    private func write(_ packet: Packet) throws
    {
        onTraffic?(true, packet)
        let data = Data(packet.encoded())
        try queue.sync {
            guard let peripheral, let characteristic else { throw BluetoothError.closedByPeer }
            for segment in LESegments.split([UInt8](data)) {
                peripheral.writeValue(Data(segment), for: characteristic, type: .withoutResponse)
            }
        }
    }

    /// Received packets, reported to onTraffic on the caller's thread.
    private func take() -> [Packet]
    {
        let (packets, rawLines) = queue.sync { () -> ([Packet], [String]) in
            defer { received.removeAll(); raw.removeAll() }
            return (received, raw)
        }
        for line in rawLines { onRaw?(line) }
        for p in packets { onTraffic?(false, p) }
        return packets
    }

    // MARK: Setup

    private func connect(by deadline: Date) throws
    {
        // macOS may already hold an LE link to them; otherwise listen for the
        // advertisement, which carries the headphones' name.
        let target = queue.sync { () -> CBPeripheral? in
            let linked = central?.retrieveConnectedPeripherals(withServices: [LESession.service]) ?? []
            if let match = linked.first(where: { matches($0.name) }) {
                notes.append("using the LE link macOS already has")
                return match
            }
            central?.scanForPeripherals(withServices: nil, options: nil)
            return nil
        }
        if target == nil {
            try wait(until: deadline, "the headphones' LE advertisement (another host may hold their LE link)") { $0.heard != nil }
        }
        try queue.sync {
            central?.stopScan()
            guard let p = target ?? heard else { throw BluetoothError.closedByPeer }
            peripheral = p
            p.delegate = self
            central?.connect(p, options: nil)
        }
        try wait(until: deadline, "the LE connection") { $0.connected }
        queue.sync { peripheral?.discoverServices([LESession.service]) }
        try wait(until: deadline, "the BMAP service over LE") { $0.discovered }
        try wait(until: deadline, "the BMAP characteristic over LE") { $0.characteristic != nil }
        queue.sync {
            for c in subscribed { peripheral?.setNotifyValue(true, for: c) }
        }
        try wait(until: deadline, "notifications from the BMAP characteristic") { $0.notifying }
    }

    private func matches(_ advertised: String?) -> Bool
    {
        guard let name else { return true }
        return advertised?.caseInsensitiveCompare(name) == .orderedSame
    }

    /// Waits for `condition`, checked on the queue after each callback.
    private func wait(until deadline: Date, _ what: String, _ condition: @escaping (LESession) -> Bool) throws
    {
        while true {
            let (met, failed) = queue.sync { (condition(self), failure) }
            if met { return }
            if let failed { throw LEError(failed) }
            if Date() >= deadline { throw BluetoothError.timeout(what) }
            _ = event.wait(timeout: .now() + 0.05)
        }
    }

    // MARK: CoreBluetooth callbacks, on `queue`

    public func centralManagerDidUpdateState(_ central: CBCentralManager)
    {
        state = central.state
        event.signal()
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi: NSNumber
    )
    {
        guard heard == nil,
              let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              BoseAdvertisement.isBose([UInt8](data)),
              matches(advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name)
        else { return }
        heard = peripheral
        notes.append("heard the advertisement at \(rssi) dBm")
        event.signal()
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral)
    {
        connected = true
        event.signal()
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?)
    {
        failure = "the LE connection failed: \(error?.localizedDescription ?? "no reason given")"
        event.signal()
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?)
    {
        disconnected = true
        event.signal()
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?)
    {
        discovered = true
        guard let service = peripheral.services?.first(where: { $0.uuid == LESession.service }) else {
            failure = "the headphones offer no BMAP service over LE"
            event.signal()
            return
        }
        peripheral.discoverCharacteristics([LESession.secureCharacteristic, LESession.plainCharacteristic], for: service)
        event.signal()
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?)
    {
        let found = service.characteristics ?? []
        for c in found {
            notes.append("characteristic \(c.uuid.uuidString): properties 0x\(String(c.properties.rawValue, radix: 16))")
        }
        // Replies may come on either; listen to both, write to one.
        subscribed = found.filter { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }
        let wanted = ProcessInfo.processInfo.environment["BOSECTL_LE_CHARACTERISTIC"] == "plain"
            ? [LESession.plainCharacteristic, LESession.secureCharacteristic]
            : [LESession.secureCharacteristic, LESession.plainCharacteristic]
        guard let chosen = wanted.lazy.compactMap({ uuid in found.first { $0.uuid == uuid } }).first
        else {
            failure = "the BMAP service has no known characteristic"
            event.signal()
            return
        }
        notes.append("using \(chosen.uuid == LESession.secureCharacteristic ? "the secure" : "the plain") characteristic")
        characteristic = chosen
        event.signal()
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?)
    {
        if let error { failure = "could not subscribe over LE: \(error.localizedDescription)" }
        notifying = characteristic.isNotifying
        event.signal()
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?)
    {
        guard let value = characteristic.value, !value.isEmpty else { return }
        let which = characteristic.uuid == LESession.secureCharacteristic ? "secure" : "plain"
        raw.append("\(which) <- \(Hex.encode([UInt8](value)))")
        guard let bytes = segments.feed([UInt8](value)) else { return }
        bytes.withUnsafeBytes { reader.append($0) }
        received.append(contentsOf: reader.drain())
        event.signal()
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?)
    {
        if let error { failure = "an LE write failed: \(error.localizedDescription)" }
        event.signal()
    }
}

public struct LEError: Error, CustomStringConvertible {
    public var description: String

    public init(_ description: String)
    {
        self.description = description
    }
}
