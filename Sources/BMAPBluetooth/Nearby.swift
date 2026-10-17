// Listening for Bose advertisements over Bluetooth LE: which headphones are
// on and in range, without connecting to them or touching the Classic link.

import BMAP
import CoreBluetooth
import Foundation

public struct NearbyDevice: Sendable {
    /// CoreBluetooth's identifier for the device, stable on this Mac.
    /// macOS does not reveal LE addresses, so this is not the Classic one.
    public var identifier: UUID
    public var name: String?
    /// dBm; 127 when CoreBluetooth has no reading.
    public var rssi: Int
    /// As advertised, starting with the company identifier.
    public var data: [UInt8]

    public var advertisement: BoseAdvertisement? { BoseAdvertisement.parse(data) }
}

public enum Nearby {
    /// Listens for `duration` seconds and returns every Bose device heard,
    /// with its latest advertisement.
    public static func scan(for duration: TimeInterval) throws -> [NearbyDevice]
    {
        try Scanner().scan(for: duration)
    }
}

private final class Scanner: NSObject, CBCentralManagerDelegate {
    private let queue = DispatchQueue(label: "bosectl.nearby")
    private let settled = DispatchSemaphore(value: 0)
    private var central: CBCentralManager?
    // Touched only on `queue`.
    private var state = CBManagerState.unknown
    private var found: [UUID: NearbyDevice] = [:]

    func scan(for duration: TimeInterval) throws -> [NearbyDevice]
    {
        central = CBCentralManager(delegate: self, queue: queue)
        guard settled.wait(timeout: .now() + 5) == .success else {
            throw BluetoothError.timeout("Bluetooth LE to start")
        }
        let state = queue.sync { self.state }
        switch state {
        case .poweredOn: break
        case .unauthorized:
            throw NearbyError("this process may not use Bluetooth; grant the terminal Bluetooth access in System Settings")
        case .poweredOff: throw NearbyError("Bluetooth is off")
        case .unsupported: throw NearbyError("this Mac has no Bluetooth LE")
        default: throw NearbyError("Bluetooth LE is not available (state \(state.rawValue))")
        }
        queue.sync {
            // Duplicates keep the flags and signal strength current.
            central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
        Thread.sleep(forTimeInterval: duration)
        return queue.sync {
            central?.stopScan()
            return found.values.sorted { $0.rssi > $1.rssi }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager)
    {
        state = central.state
        if state != .unknown, state != .resetting { settled.signal() }
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi: NSNumber
    )
    {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              BoseAdvertisement.isBose([UInt8](data))
        else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        found[peripheral.identifier] = NearbyDevice(
            identifier: peripheral.identifier, name: name ?? found[peripheral.identifier]?.name,
            rssi: rssi.intValue, data: [UInt8](data)
        )
    }
}

public struct NearbyError: Error, CustomStringConvertible {
    public var description: String

    public init(_ description: String)
    {
        self.description = description
    }
}
