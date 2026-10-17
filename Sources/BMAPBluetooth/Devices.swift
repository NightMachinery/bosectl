// Paired-device discovery and the baseband link (connect / disconnect).
//
// The link layer is deliberately separate from BMAP sessions: opening an
// RFCOMM channel makes IOBluetooth bring the baseband link up on its own,
// which wakes the headphones and hands them the Mac's audio. Callers check
// `isConnected` first and only connect on an explicit request.

import Foundation
import IOBluetooth

/// Bluetooth SIG company identifier for Bose, as used in Device ID records.
public let boseBluetoothVendorID: UInt16 = 0x009E
/// USB vendor id, which Bose also uses as a Device ID vendor on some models.
public let boseUSBVendorID: UInt16 = 0x05A7

public struct PairedDevice: Sendable {
    public var name: String
    /// Lowercase, colon-separated.
    public var address: String
    public var isConnected: Bool
    public var vendorID: UInt16?
    public var productID: UInt16?

    /// Identified by the Device ID (PnP) record, falling back to the name for
    /// devices whose records macOS has not cached.
    public var looksLikeBose: Bool
    {
        if let vendorID {
            return vendorID == boseBluetoothVendorID || vendorID == boseUSBVendorID
        }
        return name.range(of: "bose", options: .caseInsensitive) != nil
    }
}

public enum Discovery {
    public static func pairedDevices() -> [PairedDevice]
    {
        LinkState.prime()
        LinkState.willEnumerate()
        // pairedDevices() can list the same device more than once.
        var seen = Set<String>()
        let devices = (IOBluetoothDevice.pairedDevices() ?? [])
            .compactMap { $0 as? IOBluetoothDevice }
            .map(describe)
            .filter { seen.insert($0.address).inserted }
        LinkState.enumerated(devices)
        return devices
    }

    /// This Mac's Bluetooth address, to recognise it among the headphones' hosts.
    public static func hostAddress() -> String?
    {
        IOBluetoothHostController.default()?.addressAsString().map(normalizeAddress)
    }

    public static func device(address: String) -> IOBluetoothDevice?
    {
        IOBluetoothDevice(addressString: normalizeAddress(address))
    }

    static func describe(_ device: IOBluetoothDevice) -> PairedDevice
    {
        let pnp = device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: 0x1200)) // PnPInformation
        func pnpValue(_ attribute: BluetoothSDPServiceAttributeID) -> UInt16?
        {
            guard let n = pnp?.getAttributeDataElement(attribute)?.getNumberValue() else { return nil }
            return n.uint16Value
        }
        let address = normalizeAddress(device.addressString ?? "")
        return PairedDevice(
            name: device.name ?? device.nameOrAddress ?? "",
            address: address,
            isConnected: LinkState.isConnected(address),
            vendorID: pnpValue(0x0201),
            productID: pnpValue(0x0202) ?? privateProductID(device)
        )
    }

    /// IOBluetoothDevice answers -productID, though the header does not
    /// declare it. Used only when no PnP record is cached.
    static func privateProductID(_ device: IOBluetoothDevice) -> UInt16?
    {
        guard device.responds(to: NSSelectorFromString("productID")) else { return nil }
        guard let n = device.value(forKey: "productID") as? NSNumber, n.intValue > 0 else { return nil }
        return n.uint16Value
    }

    /// The RFCOMM channel carrying BMAP, from the cached SDP records.
    ///
    /// Bose publishes BMAP as a plain Serial Port (0x1101) service; the
    /// 128-bit BMAP UUID other tools search for is not among the records
    /// macOS caches. getServiceRecord(for:) is no help either: it matched a
    /// Sony headset's records for that UUID, so the comparison is done here.
    static func bmapChannel(_ device: IOBluetoothDevice) -> UInt8?
    {
        let serialPort = Data([0x00, 0x00, 0x11, 0x01])
        for case let record as IOBluetoothSDPServiceRecord in device.services ?? [] {
            guard let classes = record.getAttributeDataElement(0x0001) else { continue } // ServiceClassIDList
            let uuids = (classes.getArrayValue() as? [IOBluetoothSDPDataElement] ?? [classes]).compactMap { $0.getUUIDValue() }
            guard uuids.contains(where: { ($0.getWithLength(4) as Data?) == serialPort }) else { continue }
            var channel: BluetoothRFCOMMChannelID = 0
            if record.getRFCOMMChannelID(&channel) == kIOReturnSuccess, channel != 0 {
                return channel
            }
        }
        return nil
    }

    /// "AA-BB-CC-DD-EE-FF" and "aabbccddeeff" both become "aa:bb:cc:dd:ee:ff".
    public static func normalizeAddress(_ address: String) -> String
    {
        let hex = address.lowercased().filter { $0.isHexDigit }
        guard hex.count == 12 else { return address.lowercased() }
        var parts: [String] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            parts.append(String(hex[index ..< next]))
            index = next
        }
        return parts.joined(separator: ":")
    }
}

public enum Link {
    public static func isConnected(_ address: String) -> Bool
    {
        LinkState.isConnected(Discovery.normalizeAddress(address))
    }

    /// Brings the baseband link up, paging the device for at most `timeout`
    /// seconds. macOS reconnects the audio profiles (A2DP/HFP) for a paired
    /// audio device on its own afterwards.
    ///
    /// The synchronous -openConnection pages for about 15 s when the device
    /// is off, so this uses the asynchronous call with a shorter page timeout.
    /// Success is taken from the completion status: isConnected() cannot be
    /// trusted once pairedDevices() has run (see LinkState).
    public static func open(_ address: String, timeout: TimeInterval = 8) throws
    {
        let address = Discovery.normalizeAddress(address)
        guard let device = Discovery.device(address: address) else {
            throw BluetoothError.deviceNotFound(address)
        }
        if isConnected(address) { return }

        let waiter = ConnectionWaiter()
        // Page timeout is in baseband slots of 0.625 ms.
        let slots = UInt16(clamping: Int(timeout / 0.000625))
        let status = device.openConnection(waiter, withPageTimeout: slots, authenticationRequired: false)
        guard status == kIOReturnSuccess else {
            throw BluetoothError.linkFailed(operation: "connect", status: status)
        }
        let deadline = Date().addingTimeInterval(timeout + 2)
        while waiter.status == nil, Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.05, true)
        }
        guard let result = waiter.status else {
            throw BluetoothError.unreachable(kIOReturnTimeout)
        }
        guard result == kIOReturnSuccess else {
            throw BluetoothError.unreachable(result)
        }
        LinkState.record(address, connected: true)
    }

    public static func close(_ address: String) throws
    {
        let address = Discovery.normalizeAddress(address)
        guard let device = Discovery.device(address: address) else {
            throw BluetoothError.deviceNotFound(address)
        }
        if !isConnected(address) { return }
        let status = device.closeConnection()
        guard status == kIOReturnSuccess else {
            throw BluetoothError.linkFailed(operation: "disconnect", status: status)
        }
        LinkState.record(address, connected: false)
    }
}

/// Whether this Mac's baseband link to a device is up.
///
/// IOBluetoothDevice.isConnected() is right until the process first calls
/// +pairedDevices. That call can list a device twice (seen with the QC Ultra
/// 2, on macOS 14.3), and it overwrites the shared device object's state with
/// "not connected" while the link is up; nothing later in the process
/// corrects it. So the state of every device seen in an earlier run is read
/// before the first enumeration, and devices never seen before are looked up
/// in system_profiler, which asks bluetoothd directly.
public enum LinkState {
    private static var snapshot: [String: Bool] = [:]
    private static var primed = false
    private static var profilerState: [String: Bool]?

    /// Reads the state of every known device. Runs once, and must run before
    /// anything calls +pairedDevices.
    public static func prime(_ extra: [String] = [])
    {
        for address in extra.map(Discovery.normalizeAddress) where snapshot[address] == nil {
            snapshot[address] = Discovery.device(address: address)?.isConnected()
        }
        guard !primed else { return }
        primed = true
        for address in KnownDevices.load() where snapshot[address] == nil {
            snapshot[address] = Discovery.device(address: address)?.isConnected()
        }
    }

    static func isConnected(_ address: String) -> Bool
    {
        if let state = snapshot[address] { return state }
        if !enumeratedOnce {
            // Nothing has disturbed the device objects yet.
            let state = Discovery.device(address: address)?.isConnected() ?? false
            snapshot[address] = state
            return state
        }
        let state = systemProfilerState()[address] ?? false
        snapshot[address] = state
        return state
    }

    static func record(_ address: String, connected: Bool)
    {
        snapshot[address] = connected
    }

    private static var enumeratedOnce = false

    /// From here on, isConnected() is unreliable.
    static func willEnumerate()
    {
        enumeratedOnce = true
    }

    /// Remembers the Bose devices just enumerated so later runs can snapshot
    /// them first.
    static func enumerated(_ devices: [PairedDevice])
    {
        KnownDevices.save(devices.filter(\.looksLikeBose).map(\.address))
    }

    /// Paired devices' connection state according to system_profiler.
    private static func systemProfilerState() -> [String: Bool]
    {
        if let profilerState { return profilerState }
        var result: [String: Bool] = [:]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let info = (root["SPBluetoothDataType"] as? [[String: Any]])?.first
            {
                for (key, connected) in [("device_connected", true), ("device_not_connected", false)] {
                    for entry in info[key] as? [[String: Any]] ?? [] {
                        for case let fields as [String: Any] in entry.values {
                            if let address = fields["device_address"] as? String {
                                result[Discovery.normalizeAddress(address)] = connected
                            }
                        }
                    }
                }
            }
        }
        profilerState = result
        return result
    }
}

/// Addresses of Bose devices seen before, kept in the user's cache directory.
/// Losing the file only costs one slower lookup.
enum KnownDevices {
    static var file: URL
    {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("bosectl/known-devices")
    }

    static func load() -> [String]
    {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    static func save(_ addresses: [String])
    {
        let known = Set(load())
        let all = known.union(addresses)
        guard all != known else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (all.sorted().joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}

/// Target of -openConnection:withPageTimeout:authenticationRequired:.
private final class ConnectionWaiter: NSObject {
    var status: IOReturn?

    @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn)
    {
        self.status = status
    }
}

public enum BluetoothError: Error, CustomStringConvertible {
    case deviceNotFound(String)
    case notConnected(String)
    case linkFailed(operation: String, status: IOReturn)
    case unreachable(IOReturn)
    case channelOpenFailed(channel: UInt8, status: IOReturn)
    case sdpFailed(IOReturn)
    case writeFailed(IOReturn)
    case timeout(String)
    case closedByPeer

    public var description: String
    {
        switch self {
        case .deviceNotFound(let address):
            return "no paired Bluetooth device with address \(address)"
        case .notConnected(let name):
            return "\(name) is not connected"
        case .linkFailed(let operation, let status):
            return "\(operation) failed (\(ioReturnName(status)))"
        case .unreachable(let status):
            return "the headphones did not answer; are they on and in range? (\(ioReturnName(status)))"
        case .channelOpenFailed(let channel, let status):
            return "could not open the BMAP channel (RFCOMM \(channel), \(ioReturnName(status)))"
        case .sdpFailed(let status):
            return "service discovery failed (\(ioReturnName(status)))"
        case .writeFailed(let status):
            return "write failed (\(ioReturnName(status)))"
        case .timeout(let what):
            return "timed out waiting for \(what)"
        case .closedByPeer:
            return "the headphones closed the BMAP channel"
        }
    }
}

func ioReturnName(_ status: IOReturn) -> String
{
    String(format: "IOReturn 0x%08x", UInt32(bitPattern: status))
}
