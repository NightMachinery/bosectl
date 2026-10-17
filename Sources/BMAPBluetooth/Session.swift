// One BMAP session over an RFCOMM channel.
//
// IOBluetooth delivers channel events to the run loop of the thread that
// opened the channel, so a session lives on one thread (the main thread in
// the CLI) and waits by spinning that run loop in short slices. Nothing here
// sleeps for a fixed time: every wait ends as soon as its condition holds.

import BMAP
import Foundation
import IOBluetooth

public final class Session: NSObject, IOBluetoothRFCOMMChannelDelegate, Requester {
    public let address: String
    public private(set) var channelID: UInt8 = 0

    private let device: IOBluetoothDevice
    private var channel: IOBluetoothRFCOMMChannel?
    private var reader = PacketReader()
    private var received: [Packet] = []
    private var openStatus: IOReturn?
    private var sdpStatus: IOReturn?
    private var closed = false

    /// Every packet sent and received, in order, for --trace and `raw`.
    public var onTraffic: ((_ outgoing: Bool, _ packet: Packet) -> Void)?
    /// Packets that arrived without answering a pending request.
    public private(set) var notifications: [Packet] = []

    public static let defaultChannel: UInt8 = 2

    /// Opens the BMAP channel. The caller must already have checked that the
    /// baseband link is up (see `Link`); opening RFCOMM would otherwise bring
    /// it up implicitly.
    public init(address: String, timeout: TimeInterval = 5) throws
    {
        self.address = Discovery.normalizeAddress(address)
        guard let device = Discovery.device(address: self.address) else {
            throw BluetoothError.deviceNotFound(self.address)
        }
        self.device = device
        super.init()
        channelID = try resolveChannel(timeout: timeout)
        try openChannel(timeout: timeout)
    }

    deinit {
        close()
    }

    public func close()
    {
        guard let channel else { return }
        channel.setDelegate(nil)
        channel.close()
        self.channel = nil
    }

    // MARK: Requests

    public func request(_ packet: Packet, accept: Set<Address>, collect: Collect, timeout: TimeInterval) throws -> [Packet]
    {
        notifications.append(contentsOf: received)
        received.removeAll()
        try write(packet)

        var collector = AnswerCollector(request: packet, accept: accept, collect: collect)
        var deadline = Date().addingTimeInterval(timeout)
        while true {
            while !received.isEmpty {
                let p = received.removeFirst()
                switch try collector.feed(p) {
                case .unrelated:
                    notifications.append(p)
                case .progress:
                    if collector.done { return collector.answers }
                    if case .all(let quiet) = collect, !collector.answers.isEmpty {
                        deadline = Date().addingTimeInterval(quiet)
                    } else {
                        deadline = Date().addingTimeInterval(timeout)
                    }
                }
            }
            if closed {
                throw BluetoothError.closedByPeer
            }
            if Date() >= deadline {
                if case .all = collect, !collector.answers.isEmpty { return collector.answers }
                throw BluetoothError.timeout("a reply to \(packet.address) \(packet.op.name)")
            }
            pump(until: deadline)
        }
    }

    /// Sends without waiting for an answer.
    public func send(_ packet: Packet) throws
    {
        try write(packet)
    }

    /// Collects every packet that arrives within `duration`.
    public func listen(for duration: TimeInterval) -> [Packet]
    {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline, !closed {
            pump(until: deadline)
        }
        let out = notifications + received
        notifications.removeAll()
        received.removeAll()
        return out
    }

    // MARK: Channel plumbing

    private func write(_ packet: Packet) throws
    {
        guard let channel, !closed else { throw BluetoothError.closedByPeer }
        var bytes = packet.encoded()
        onTraffic?(true, packet)
        let status = bytes.withUnsafeMutableBytes { buffer in
            channel.writeSync(buffer.baseAddress, length: UInt16(buffer.count))
        }
        guard status == kIOReturnSuccess else { throw BluetoothError.writeFailed(status) }
    }

    /// Runs the run loop once, for at most 50 ms or until `deadline`.
    private func pump(until deadline: Date)
    {
        let slice = min(0.05, max(0.001, deadline.timeIntervalSinceNow))
        CFRunLoopRunInMode(.defaultMode, slice, true)
    }

    private func resolveChannel(timeout: TimeInterval) throws -> UInt8
    {
        if let id = cachedChannel() { return id }
        // No cached record: ask the device. Completion arrives through
        // sdpQueryComplete(_:status:).
        sdpStatus = nil
        let status = device.performSDPQuery(self)
        if status == kIOReturnSuccess {
            let deadline = Date().addingTimeInterval(timeout)
            while sdpStatus == nil, Date() < deadline {
                pump(until: deadline)
            }
        }
        return cachedChannel() ?? Session.defaultChannel
    }

    private func cachedChannel() -> UInt8?
    {
        Discovery.bmapChannel(device)
    }

    private func openChannel(timeout: TimeInterval) throws
    {
        var opened: IOBluetoothRFCOMMChannel?
        openStatus = nil
        let status = device.openRFCOMMChannelSync(&opened, withChannelID: channelID, delegate: self)
        guard status == kIOReturnSuccess, let opened else {
            throw BluetoothError.channelOpenFailed(channel: channelID, status: status)
        }
        channel = opened
        // The sync call normally returns with the channel open; wait for the
        // delegate in case it has not reported yet.
        let deadline = Date().addingTimeInterval(timeout)
        while openStatus == nil, !opened.isOpen(), Date() < deadline {
            pump(until: deadline)
        }
        if let openStatus, openStatus != kIOReturnSuccess {
            close()
            throw BluetoothError.channelOpenFailed(channel: channelID, status: openStatus)
        }
        guard opened.isOpen() else {
            close()
            throw BluetoothError.timeout("the BMAP channel to open")
        }
    }

    // MARK: IOBluetooth delegate callbacks

    @objc public func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn)
    {
        sdpStatus = status
    }

    public func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn)
    {
        openStatus = error
    }

    public func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int)
    {
        guard let dataPointer, dataLength > 0 else { return }
        reader.append(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        for packet in reader.drain() {
            onTraffic?(false, packet)
            received.append(packet)
        }
    }

    public func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!)
    {
        closed = true
    }
}
