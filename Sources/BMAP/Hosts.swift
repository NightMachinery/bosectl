// The hosts the headphones remember (block 4) and what they play (block 5).

import Foundation

// MARK: Remembered hosts (4.4, 4.5)

/// One host the headphones are paired with.
public struct HostInfo: Equatable, Sendable {
    public var address: String
    /// Bit 0: linked now. The other bits are not decoded.
    public var status: UInt8
    public var name: String

    public var connected: Bool { status & 0x01 != 0 }

    /// GET reply: [address (6), status, ?, ?, name (to the end)].
    public static func parse(_ payload: [UInt8]) throws -> HostInfo
    {
        try require(payload, 7, Function.hostInfo)
        return HostInfo(
            address: formatAddress(payload[0 ..< 6]),
            status: payload[6],
            name: payload.count > 9 ? fixedString(payload[9...]) : ""
        )
    }
}

/// A remembered host, put together from 4.4, 4.5, 4.9 and 5.1.
public struct RememberedHost: Equatable, Sendable {
    public var address: String
    public var name: String
    public var connected: Bool
    /// The headphones play from it.
    public var playing: Bool
    /// The host asking: this Mac.
    public var isSelf: Bool
}

/// The 4.4 reply: one byte, then the addresses of the remembered hosts. The
/// order is not stable between reads, so nothing may be keyed on a position.
public func parseHostList(_ payload: [UInt8]) throws -> [String]
{
    try require(payload, 1, Function.hosts)
    return splitAddresses(payload.dropFirst())
}

/// Whole six-byte addresses in `bytes`, in order.
func splitAddresses(_ bytes: ArraySlice<UInt8>) -> [String]
{
    stride(from: bytes.startIndex, to: bytes.endIndex - 5, by: 6).map { formatAddress(bytes[$0 ..< $0 + 6]) }
}

// MARK: Audio source (5.1)

/// Who the headphones are playing from.
///
/// The reply is [?, ?, n, address...]. Read one way, byte 2 is the source
/// kind (1 Bluetooth, 2 aux); read the other, it counts the addresses that
/// follow. A Bluetooth source with one host fits both, so the decoder takes
/// every whole address that follows.
public struct AudioSource: Equatable, Sendable {
    public var kind: UInt8
    public var addresses: [String]

    public static func parse(_ payload: [UInt8]) throws -> AudioSource
    {
        try require(payload, 3, Function.source)
        return AudioSource(kind: payload[2], addresses: splitAddresses(payload.dropFirst(3)))
    }

    public var kindName: String
    {
        switch kind {
        case 0: return "none"
        case 1 where !addresses.isEmpty: return "bluetooth"
        case 2 where addresses.isEmpty: return "aux"
        default: return addresses.isEmpty ? "source \(kind)" : "bluetooth"
        }
    }
}

// MARK: Volume (5.5)

public struct Volume: Equatable, Sendable {
    public var level: Int
    public var max: Int

    /// GET and SETGET reply: [max, level].
    public static func parse(_ payload: [UInt8]) throws -> Volume
    {
        try require(payload, 2, Function.volume)
        return Volume(level: Int(payload[1]), max: Int(payload[0]))
    }
}

// MARK: Media control (5.3)

/// What a START on 5.3 asks the playing host to do. A GET returns a mask of
/// the supported actions, bit n for action n.
public enum MediaAction: UInt8, CaseIterable, Sendable {
    case stop = 0, play = 1, pause = 2, next = 3, previous = 4

    public var name: String
    {
        switch self {
        case .stop: return "stop"
        case .play: return "play"
        case .pause: return "pause"
        case .next: return "next"
        case .previous: return "previous"
        }
    }

    public static func named(_ text: String) -> MediaAction?
    {
        switch text.lowercased() {
        case "prev", "back": return .previous
        case "skip", "forward": return .next
        default: return allCases.first { $0.name == text.lowercased() }
        }
    }
}

// MARK: Favorites (31.8)

/// The modes the headphones' mode button cycles through.
public struct Favorites: Equatable, Sendable {
    /// How many mode slots the mask covers.
    public var slots: Int
    public var indices: Set<UInt8>

    /// [slot count, mask...]. The mask's last byte holds modes 0 to 7, the
    /// byte before it 8 to 15, and so on.
    public static func parse(_ payload: [UInt8]) throws -> Favorites
    {
        try require(payload, 1, Function.favorites)
        let mask = Array(payload.dropFirst())
        var indices: Set<UInt8> = []
        for (position, byte) in mask.reversed().enumerated() {
            for bit in 0 ..< 8 where byte & (1 << bit) != 0 {
                indices.insert(UInt8(position * 8 + bit))
            }
        }
        return Favorites(slots: Int(payload[0]), indices: indices)
    }

    public func build() -> [UInt8]
    {
        var mask = [UInt8](repeating: 0, count: (slots + 7) / 8)
        for index in indices where Int(index) < slots {
            mask[mask.count - 1 - Int(index) / 8] |= 1 << (index % 8)
        }
        return [UInt8(slots)] + mask
    }
}

// MARK: Product id (0.3)

public struct ProductID: Equatable, Sendable {
    public var id: UInt16
    /// The colour, for models whose variants are known.
    public var variant: UInt8

    /// [id hi, id lo, variant].
    public static func parse(_ payload: [UInt8]) throws -> ProductID
    {
        try require(payload, 3, Function.productID)
        return ProductID(id: UInt16(payload[0]) << 8 | UInt16(payload[1]), variant: payload[2])
    }
}
