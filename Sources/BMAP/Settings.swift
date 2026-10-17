// Payload layouts of the settings functions, decoded into value types.
// Each type parses the STATUS payload a GET returns and builds the payload a
// SETGET takes. Offsets are documented in docs/protocol.org.

import Foundation

public enum ParseError: Error, CustomStringConvertible {
    case tooShort(Address, Int, need: Int)
    case malformed(Address, String)

    public var description: String
    {
        switch self {
        case .tooShort(let address, let got, let need):
            return "reply to \(address) is \(got) bytes, expected at least \(need)"
        case .malformed(let address, let why):
            return "reply to \(address) is malformed: \(why)"
        }
    }
}

func require(_ payload: [UInt8], _ count: Int, _ address: Address) throws
{
    if payload.count < count {
        throw ParseError.tooShort(address, payload.count, need: count)
    }
}

extension Int8 {
    init(bmap byte: UInt8) { self.init(bitPattern: byte) }
}

/// A 0-terminated string in a fixed-size field.
func fixedString<C: Collection>(_ bytes: C) -> String where C.Element == UInt8
{
    let content = bytes.prefix { $0 != 0 }
    return String(decoding: content, as: UTF8.self)
}

/// Encodes `text` into a `size`-byte, 0-terminated, 0-padded field, cutting
/// it at a character boundary if it does not fit.
func fixedField(_ text: String, size: Int) -> [UInt8]
{
    var bytes: [UInt8] = []
    for character in text {
        let encoded = Array(String(character).utf8)
        if bytes.count + encoded.count > size - 1 { break }
        bytes += encoded
    }
    return bytes + [UInt8](repeating: 0, count: size - bytes.count)
}

// MARK: Equalizer (1.7)

public struct EQBand: Equatable, Sendable {
    public enum ID: UInt8, CaseIterable, Sendable {
        case bass = 0, mid = 1, treble = 2

        public var name: String
        {
            switch self {
            case .bass: return "bass"
            case .mid: return "mid"
            case .treble: return "treble"
            }
        }
    }

    public var id: UInt8
    public var min: Int
    public var max: Int
    public var value: Int

    public var name: String { ID(rawValue: id)?.name ?? "band\(id)" }

    /// GET reply: one [min, max, current, band id] group per band, signed.
    public static func parseAll(_ payload: [UInt8]) -> [EQBand]
    {
        stride(from: 0, to: payload.count - 3, by: 4).map { i in
            EQBand(
                id: payload[i + 3],
                min: Int(Int8(bmap: payload[i])),
                max: Int(Int8(bmap: payload[i + 1])),
                value: Int(Int8(bmap: payload[i + 2]))
            )
        }
    }

    /// SETGET payload for one band: [value, band id].
    public static func build(_ band: ID, _ value: Int) -> [UInt8]
    {
        [UInt8(bitPattern: Int8(clamping: value)), band.rawValue]
    }
}

// MARK: Voice prompts (1.3)

public struct VoicePrompts: Equatable, Sendable {
    public var language: UInt8
    /// Name a host when it connects (byte 0, bit 5).
    public var announceConnections: Bool
    /// Say the battery level at power-on (byte 6), when the reply has it.
    public var announceBattery: Bool?
    /// The language is the factory default (byte 0, bit 6); read only.
    public var defaultLanguage: Bool

    public static let languages: [UInt8: String] = [
        0: "UK English", 1: "US English", 2: "French", 3: "Italian", 4: "German",
        5: "EU Spanish", 6: "MX Spanish", 7: "BR Portuguese", 8: "Mandarin",
        9: "Korean", 10: "Russian", 11: "Polish", 12: "Hebrew", 13: "Turkish",
        14: "Dutch", 15: "Japanese", 16: "Cantonese", 17: "Arabic", 18: "Swedish",
        19: "Danish", 20: "Norwegian", 21: "Finnish", 22: "Hindi",
    ]

    public var languageName: String { VoicePrompts.languages[language] ?? "language \(language)" }

    /// GET reply, 7 bytes on the QC Ultra 2: [flags and language, ?, ?, ?,
    /// ?, ?, battery announcement]. Byte 0: bits 0-4 language, bit 5
    /// connection announcements, bit 6 default language.
    public static func parse(_ payload: [UInt8]) throws -> VoicePrompts
    {
        try require(payload, 1, Function.voicePrompts)
        return VoicePrompts(
            language: payload[0] & 0x1F,
            announceConnections: payload[0] & 0x20 != 0,
            announceBattery: payload.count >= 7 ? payload[6] != 0 : nil,
            defaultLanguage: payload[0] & 0x40 != 0
        )
    }

    /// SETGET payload: [connection announcements (bit 5) | language, battery
    /// announcement].
    public func build() -> [UInt8]
    {
        [(announceConnections ? 0x20 : 0) | (language & 0x1F), announceBattery == true ? 1 : 0]
    }

    /// The fields a write sets.
    var writable: [UInt8] { build() }
}

// MARK: Sidetone (1.11)

public enum Sidetone: UInt8, CaseIterable, Sendable {
    case off = 0, high = 1, medium = 2, low = 3

    public var name: String
    {
        switch self {
        case .off: return "off"
        case .high: return "high"
        case .medium: return "medium"
        case .low: return "low"
        }
    }

    /// GET reply: [flags, level].
    public static func parse(_ payload: [UInt8]) throws -> Sidetone
    {
        try require(payload, 2, Function.sidetone)
        guard let level = Sidetone(rawValue: payload[1]) else {
            throw ParseError.malformed(Function.sidetone, "level \(payload[1])")
        }
        return level
    }

    /// SETGET payload: [persist, level].
    public func build() -> [UInt8] { [1, rawValue] }
}

// MARK: Buttons (1.9)

public struct ButtonMapping: Equatable, Sendable {
    public var button: UInt8
    public var event: UInt8
    public var action: UInt8
    /// Actions the firmware accepts for this button, from the capability bitmap.
    public var supported: [UInt8]

    public static let buttonNames: [UInt8: String] = [
        0: "distal-cnc", 1: "reserved", 2: "vpa", 3: "right-shortcut",
        4: "left-shortcut", 16: "action", 128: "shortcut",
    ]

    public static let eventNames: [UInt8: String] = [
        1: "rising-edge", 2: "falling-edge", 3: "short-press", 4: "single-press",
        5: "press-and-hold", 6: "double-press", 7: "double-press-hold", 8: "triple-press",
        9: "long-press", 10: "very-long-press", 11: "very-very-long-press",
        12: "very-very-very-long-press",
    ]

    public static let actionNames: [UInt8: String] = [
        0: "not-configured", 1: "vpa", 2: "anc", 3: "battery-level", 4: "play-pause",
        5: "increase-cnc", 6: "decrease-cnc", 7: "toggle-wake-word", 8: "switch-device",
        9: "conversation-mode", 10: "track-forward", 11: "track-back",
        12: "fetch-notifications", 13: "wind-mode", 14: "disabled",
        15: "client-interaction", 16: "spotify-go", 17: "modes-carousel",
        19: "spatial-audio-mode", 20: "line-in-switch", 21: "linking",
    ]

    public var buttonName: String { ButtonMapping.buttonNames[button] ?? "button \(button)" }
    public var eventName: String { ButtonMapping.eventNames[event] ?? "event \(event)" }
    public var actionName: String { ButtonMapping.actionName(action) }

    public static func actionName(_ id: UInt8) -> String { actionNames[id] ?? "action \(id)" }

    public static func action(named name: String) -> UInt8?
    {
        let key = name.lowercased().replacingOccurrences(of: "_", with: "-")
        return actionNames.first { $0.value == key }?.key
    }

    /// GET reply: [button, event, action, supported (big-endian u32), ...];
    /// bit n of `supported` means action n is accepted. (Reading the four
    /// bytes as one little-endian bitmap gives actions the Bose app never
    /// offers, and leaves out the one configured.)
    public static func parse(_ payload: [UInt8]) throws -> ButtonMapping
    {
        try require(payload, 3, Function.buttons)
        let maskBytes = Array(payload.dropFirst(3).prefix(4))
        let mask = maskBytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } << (8 * UInt32(4 - maskBytes.count))
        let supported = (0 ..< 32).filter { mask & (1 << $0) != 0 }.map(UInt8.init)
        return ButtonMapping(button: payload[0], event: payload[1], action: payload[2], supported: supported)
    }

    /// SETGET payload: [button, event, action].
    public func build() -> [UInt8] { [button, event, action] }
}

// MARK: Audio source (5.1)

public struct AudioSource: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        case none = 0, bluetooth = 1, auxiliary = 2
    }

    public var kind: UInt8
    /// The source host, for Bluetooth sources.
    public var address: String?

    public var kindName: String
    {
        guard let known = Kind(rawValue: kind) else { return "source \(kind)" }
        switch known {
        case .none: return "none"
        case .bluetooth: return "bluetooth"
        case .auxiliary: return "aux"
        }
    }

    /// GET reply: [supported (2 bytes), active kind, address (6 bytes)].
    public static func parse(_ payload: [UInt8]) throws -> AudioSource
    {
        try require(payload, 3, Function.source)
        var address: String?
        if payload[2] == Kind.bluetooth.rawValue, payload.count >= 9 {
            address = formatAddress(payload[3 ..< 9])
        }
        return AudioSource(kind: payload[2], address: address)
    }
}

/// Six address bytes as "aa:bb:cc:dd:ee:ff".
public func formatAddress<C: Collection>(_ bytes: C) -> String where C.Element == UInt8
{
    Hex.encode(bytes, separator: ":")
}

/// "aa:bb:cc:dd:ee:ff" (or with dashes, or bare) as six bytes.
public func parseAddress(_ text: String) -> [UInt8]?
{
    guard let bytes = Hex.decode(text), bytes.count == 6 else { return nil }
    return bytes
}
