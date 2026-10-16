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
        // pairedDevices() can list the same device more than once.
        var seen = Set<String>()
        return (IOBluetoothDevice.pairedDevices() ?? [])
            .compactMap { $0 as? IOBluetoothDevice }
            .map(describe)
            .filter { seen.insert($0.address).inserted }
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
        return PairedDevice(
            name: device.name ?? device.nameOrAddress ?? "",
            address: normalizeAddress(device.addressString ?? ""),
            isConnected: device.isConnected(),
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
        Discovery.device(address: address)?.isConnected() ?? false
    }

    /// Brings the baseband link up, paging the device for at most `timeout`
    /// seconds. macOS reconnects the audio profiles (A2DP/HFP) for a paired
    /// audio device on its own afterwards.
    ///
    /// The synchronous -openConnection pages for about 15 s when the device
    /// is off, and has been seen to report success for a link that was gone
    /// a moment later, so this uses the asynchronous call and then checks
    /// that the link is really up.
    public static func open(_ address: String, timeout: TimeInterval = 8) throws
    {
        guard let device = Discovery.device(address: address) else {
            throw BluetoothError.deviceNotFound(address)
        }
        if device.isConnected() { return }

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
        if let result = waiter.status, result != kIOReturnSuccess {
            throw BluetoothError.unreachable(result)
        }
        guard device.isConnected() else {
            throw BluetoothError.unreachable(waiter.status ?? kIOReturnTimeout)
        }
    }

    public static func close(_ address: String) throws
    {
        guard let device = Discovery.device(address: address) else {
            throw BluetoothError.deviceNotFound(address)
        }
        if !device.isConnected() { return }
        let status = device.closeConnection()
        guard status == kIOReturnSuccess else {
            throw BluetoothError.linkFailed(operation: "disconnect", status: status)
        }
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
