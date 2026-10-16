// BMAP framing, shared by every Bose device that speaks it.
//
//   [block, function, flags, length, payload...]
//   flags = deviceID << 6 | port << 4 | operator
//
// A "function" is addressed by the pair (block, function), written "31.3".

import Foundation

/// What a packet asks for or reports. Requests use set/get/setGet/start; the
/// device answers with status/result/error, and may send status unprompted.
public enum Operator: UInt8, CaseIterable, Sendable {
    case set = 0
    case get = 1
    case setGet = 2
    case status = 3
    case error = 4
    case start = 5
    case result = 6
    case processing = 7

    public var name: String {
        switch self {
        case .set: return "SET"
        case .get: return "GET"
        case .setGet: return "SETGET"
        case .status: return "STATUS"
        case .error: return "ERROR"
        case .start: return "START"
        case .result: return "RESULT"
        case .processing: return "PROCESSING"
        }
    }
}

/// The (block, function) pair a packet is about.
public struct Address: Hashable, Sendable, CustomStringConvertible {
    public var block: UInt8
    public var function: UInt8

    public init(_ block: UInt8, _ function: UInt8)
    {
        self.block = block
        self.function = function
    }

    public var description: String { "\(block).\(function)" }

    /// Parses "31.3".
    public init?(parsing text: String)
    {
        let parts = text.split(separator: ".")
        guard parts.count == 2, let b = UInt8(parts[0]), let f = UInt8(parts[1]) else { return nil }
        self.init(b, f)
    }
}

/// The payload byte of an ERROR packet.
public enum DeviceErrorCode: UInt8, Sendable {
    case unknown = 0
    case length = 1
    case checksum = 2
    case blockNotSupported = 3
    case functionNotSupported = 4
    case operatorNotSupported = 5   // also what an unauthenticated SET gets
    case invalidData = 6
    case dataUnavailable = 7
    case runtime = 8
    case timeout = 9
    case invalidState = 10
    case invalidTransition = 15
    case insecureTransport = 20

    public var name: String {
        switch self {
        case .unknown: return "unknown"
        case .length: return "bad length"
        case .checksum: return "bad checksum"
        case .blockNotSupported: return "function block not supported"
        case .functionNotSupported: return "function not supported"
        case .operatorNotSupported: return "operator not supported (needs authentication)"
        case .invalidData: return "invalid data"
        case .dataUnavailable: return "data unavailable"
        case .runtime: return "runtime error"
        case .timeout: return "device timeout"
        case .invalidState: return "invalid state"
        case .invalidTransition: return "invalid transition"
        case .insecureTransport: return "insecure transport"
        }
    }

    public static func describe(_ raw: UInt8) -> String
    {
        DeviceErrorCode(rawValue: raw)?.name ?? "error \(raw)"
    }
}

public struct Packet: Equatable, Sendable, CustomStringConvertible {
    public var address: Address
    public var op: Operator
    public var port: UInt8 = 0      // 2 bits
    public var deviceID: UInt8 = 0  // 2 bits
    public var payload: [UInt8]

    public init(_ address: Address, _ op: Operator, _ payload: [UInt8] = [], port: UInt8 = 0, deviceID: UInt8 = 0)
    {
        self.address = address
        self.op = op
        self.payload = payload
        self.port = port
        self.deviceID = deviceID
    }

    public static let headerSize = 4
    public static let maxPayload = 255

    public var flags: UInt8 { (deviceID & 0x3) << 6 | (port & 0x3) << 4 | op.rawValue }

    public func encoded() -> [UInt8]
    {
        precondition(payload.count <= Packet.maxPayload, "BMAP payload over 255 bytes")
        return [address.block, address.function, flags, UInt8(payload.count)] + payload
    }

    /// For an ERROR packet, the device's error code.
    public var errorCode: UInt8? { op == .error ? payload.first : nil }

    public var description: String
    {
        var s = "[\(address)] \(op.name)"
        if let code = errorCode {
            s += " \(DeviceErrorCode.describe(code))"
        }
        if !payload.isEmpty {
            s += " " + Hex.encode(payload)
        }
        return s
    }
}

/// Splits a byte stream into packets. RFCOMM delivers bytes in arbitrary
/// chunks: one read can hold several packets, or part of one.
public struct PacketReader: Sendable {
    private var buffer: [UInt8] = []
    /// Bytes dropped while resynchronising after garbage.
    public private(set) var discarded = 0

    public init() {}

    public mutating func append<S: Sequence>(_ bytes: S) where S.Element == UInt8
    {
        buffer.append(contentsOf: bytes)
    }

    /// The next complete packet, or nil when more bytes are needed.
    public mutating func next() -> Packet?
    {
        while buffer.count >= Packet.headerSize {
            guard let op = Operator(rawValue: buffer[2] & 0x0F) else {
                // Not a header we understand. BMAP has no sync marker, so
                // sliding forward byte by byte would only find false headers;
                // RFCOMM is reliable and ordered, so drop what we have.
                discarded += buffer.count
                buffer.removeAll()
                return nil
            }
            let length = Int(buffer[3])
            guard buffer.count >= Packet.headerSize + length else { return nil }
            let packet = Packet(
                Address(buffer[0], buffer[1]), op,
                Array(buffer[Packet.headerSize ..< Packet.headerSize + length]),
                port: (buffer[2] >> 4) & 0x3,
                deviceID: (buffer[2] >> 6) & 0x3
            )
            buffer.removeFirst(Packet.headerSize + length)
            return packet
        }
        return nil
    }

    /// Every complete packet currently buffered.
    public mutating func drain() -> [Packet]
    {
        var out: [Packet] = []
        while let p = next() {
            out.append(p)
        }
        return out
    }

    public var pendingBytes: Int { buffer.count }
}

public enum Hex {
    public static func encode<C: Collection>(_ bytes: C, separator: String = "") -> String where C.Element == UInt8
    {
        bytes.map { byte in
            let s = String(byte, radix: 16)
            return byte < 0x10 ? "0" + s : s
        }.joined(separator: separator)
    }

    /// Accepts "1f03", "1f 03", "1f:03" and "0x1f 0x03".
    public static func decode(_ text: String) -> [UInt8]?
    {
        var digits = text.lowercased()
        digits = digits.replacingOccurrences(of: "0x", with: "")
        digits.removeAll { $0 == " " || $0 == ":" || $0 == "-" || $0 == "," }
        guard digits.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index ..< next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}
