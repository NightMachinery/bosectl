// Request/response exchange, independent of the transport.

import Foundation

/// How a request decides it has its answer.
public enum Collect: Sendable {
    /// The first STATUS or RESULT for the request's address.
    case one
    /// The first PROCESSING, STATUS or RESULT for the request's address. For
    /// actions the device carries out after acknowledging them, without
    /// reporting when they finish.
    case acknowledged
    /// Every accepted packet until a RESULT for the request's address, or
    /// until nothing has arrived for `quiet` seconds. For requests the device
    /// answers with a series of packets, such as listing all modes.
    case all(quiet: TimeInterval)
}

/// Something that can send a BMAP request and wait for its answer: the
/// RFCOMM session in production, a scripted fake in tests.
public protocol Requester: AnyObject {
    /// Sends `packet` and returns the answers. Packets for `packet.address`
    /// are always accepted; `accept` adds addresses whose packets belong to
    /// the answer too (31.1 answers with 31.6 records). An ERROR answer
    /// throws `DeviceError`.
    func request(_ packet: Packet, accept: Set<Address>, collect: Collect, timeout: TimeInterval) throws -> [Packet]
}

/// The device answered a request with an ERROR packet.
public struct DeviceError: Error, CustomStringConvertible {
    public var request: Packet
    public var response: Packet

    public init(request: Packet, response: Packet)
    {
        self.request = request
        self.response = response
    }

    public var code: UInt8 { response.errorCode ?? 0 }

    public var description: String
    {
        "the headphones rejected \(request.address) \(request.op.name): \(DeviceErrorCode.describe(code))"
    }
}

/// Decides, packet by packet, whether a request is answered. Shared by every
/// transport so they all end a request the same way.
public struct AnswerCollector {
    public let request: Packet
    public let accept: Set<Address>
    public let collect: Collect
    public private(set) var answers: [Packet] = []
    public private(set) var done = false

    public init(request: Packet, accept: Set<Address>, collect: Collect)
    {
        self.request = request
        self.accept = accept.union([request.address])
        self.collect = collect
    }

    public enum Verdict {
        /// Not part of this answer; the caller keeps it as a notification.
        case unrelated
        /// Part of the answer, or a PROCESSING acknowledgement: restart the
        /// reply timeout (and the quiet timer, for `.all`).
        case progress
    }

    /// Feeds one received packet. Throws on an ERROR for the request.
    public mutating func feed(_ packet: Packet) throws -> Verdict
    {
        guard accept.contains(packet.address) else { return .unrelated }
        if packet.address == request.address {
            switch packet.op {
            case .processing:
                if case .acknowledged = collect {
                    answers.append(packet)
                    done = true
                }
                return .progress
            case .error:
                throw DeviceError(request: request, response: packet)
            case .result:
                answers.append(packet)
                done = true
                return .progress
            default:
                break
            }
        } else if packet.op == .error {
            // An error about a related function belongs to this request too.
            throw DeviceError(request: request, response: packet)
        }
        // Our own request echoed back would be a transport bug; ignore it.
        guard packet.op == .status || packet.op == .result else { return .unrelated }
        answers.append(packet)
        switch collect {
        case .one, .acknowledged:
            if packet.address == request.address { done = true }
        case .all:
            break
        }
        return .progress
    }
}
