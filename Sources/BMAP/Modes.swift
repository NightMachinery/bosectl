// Audio modes (block 31): the four presets and the editable custom slots,
// plus the live settings of whichever mode is active.

import Foundation

/// Spatial ("immersive") audio.
public enum Spatial: UInt8, CaseIterable, Sendable {
    case off = 0
    /// Fixed stage ("still").
    case room = 1
    /// Follows head movement ("motion").
    case head = 2

    public var name: String
    {
        switch self {
        case .off: return "off"
        case .room: return "room"
        case .head: return "head"
        }
    }

    public static func named(_ text: String) -> Spatial?
    {
        switch text.lowercased() {
        case "off", "0": return .off
        case "room", "still", "fixed", "1": return .room
        case "head", "motion", "tracking", "2": return .head
        default: return nil
        }
    }
}

/// One audio mode as stored on the headphones.
public struct ModeConfig: Equatable, Sendable {
    public var index: UInt8
    /// Voice prompt played when switching to the mode (two bytes).
    public var prompt: [UInt8]
    public var editable: Bool
    public var configured: Bool
    public var name: String
    /// 0 = most cancellation, 10 = most ambient.
    public var cncLevel: UInt8
    public var autoCNC: Bool
    public var spatial: UInt8
    public var windBlock: Bool
    public var ancEnabled: Bool

    /// A custom slot with no mode in it. Firmware marks a slot "configured"
    /// on its first write and never clears it, so the name is the only test.
    public var isEmpty: Bool
    {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        return editable && (n.isEmpty || n == "none")
    }

    /// Parses the 48-byte STATUS record of a GET or a mode listing:
    ///
    ///   [0] index  [1-2] prompt  [3] editable  [4] configured  [5] ?
    ///   [6-37] name (32 bytes, 0-terminated)  [38-41] ?
    ///   [42] cnc  [43] auto cnc  [44] spatial  [45] copy of [3]
    ///   [46] wind block  [47] anc
    ///
    /// and the 40-byte echo of a SETGET, which is the write layout below.
    public static func parse(_ payload: [UInt8]) throws -> ModeConfig
    {
        if payload.count >= 48 {
            return ModeConfig(
                index: payload[0], prompt: Array(payload[1 ... 2]),
                editable: payload[3] != 0, configured: payload[4] != 0,
                name: fixedString(payload[6 ..< 38]),
                cncLevel: payload[42], autoCNC: payload[43] != 0, spatial: payload[44],
                windBlock: payload[46] != 0, ancEnabled: payload[47] != 0
            )
        }
        if payload.count >= 40 {
            return ModeConfig(
                index: payload[0], prompt: Array(payload[1 ... 2]),
                editable: true, configured: true,
                name: fixedString(payload[3 ..< 35]),
                cncLevel: payload[35], autoCNC: payload[36] != 0, spatial: payload[37],
                windBlock: payload[38] != 0, ancEnabled: payload[39] != 0
            )
        }
        throw ParseError.tooShort(Function.modeConfig, payload.count, need: 40)
    }

    /// The 40-byte SETGET payload:
    ///
    ///   [0] index  [1-2] prompt  [3-34] name (32 bytes)
    ///   [35] cnc  [36] auto cnc  [37] spatial  [38] wind block  [39] anc
    public func build() -> [UInt8]
    {
        var out: [UInt8] = [index]
        out += (prompt + [0, 0]).prefix(2)
        out += fixedField(name, size: 32)
        out += [cncLevel, autoCNC ? 1 : 0, spatial, windBlock ? 1 : 0, ancEnabled ? 1 : 0]
        return out
    }

    /// What a deleted slot is written back to.
    public static func empty(index: UInt8) -> ModeConfig
    {
        ModeConfig(
            index: index, prompt: [0, 0], editable: true, configured: true, name: "None",
            cncLevel: 0, autoCNC: false, spatial: 0, windBlock: false, ancEnabled: false
        )
    }
}

/// The live settings of the active mode (31.10).
public struct AudioSettings: Equatable, Sendable {
    public var cncLevel: UInt8
    public var autoCNC: Bool
    public var spatial: UInt8
    public var windBlock: Bool
    public var ancEnabled: Bool

    /// [cnc, auto cnc, spatial, wind block, anc]; the SETGET payload is the same.
    public static func parse(_ payload: [UInt8]) throws -> AudioSettings
    {
        try require(payload, 5, Function.audioSettings)
        return AudioSettings(
            cncLevel: payload[0], autoCNC: payload[1] != 0, spatial: payload[2],
            windBlock: payload[3] != 0, ancEnabled: payload[4] != 0
        )
    }

    public func build() -> [UInt8]
    {
        [cncLevel, autoCNC ? 1 : 0, spatial, windBlock ? 1 : 0, ancEnabled ? 1 : 0]
    }
}

/// The preset modes of the QC Ultra 2 and the slots custom modes may use.
public enum Presets {
    public static let modes: [(name: String, index: UInt8, summary: String)] = [
        ("quiet", 0, "full noise cancellation"),
        ("aware", 1, "transparency"),
        ("immersion", 2, "spatial audio that follows your head"),
        ("cinema", 3, "spatial audio on a fixed stage"),
    ]

    public static let customSlots: ClosedRange<UInt8> = 4 ... 10

    public static func index(named name: String) -> UInt8?
    {
        modes.first { $0.name == name.lowercased() }?.index
    }

    public static func name(of index: UInt8) -> String?
    {
        modes.first { $0.index == index }?.name
    }
}
