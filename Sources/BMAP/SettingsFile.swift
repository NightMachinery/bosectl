// A settings file for 'bosectl apply': JSON in the shape 'bosectl --json
// status' prints. A saved status applies as it is, and a hand-written file
// names only what it changes: {"mode": "aware", "volume": 8}.

import Foundation

public struct SettingsFile: Equatable, Sendable {
    /// A mode by name, or an index as text.
    public var mode: String?
    public var cncLevel: UInt8?
    public var autoCNC: Bool?
    public var anc: Bool?
    public var windBlock: Bool?
    public var spatial: Spatial?
    public var volume: Int?
    public var eq: [EQBand.ID: Int] = [:]
    public var sidetone: Sidetone?
    public var multipoint: Bool?
    public var autoPause: Bool?
    public var autoAnswer: Bool?
    public var name: String?

    public init() {}

    public var changesNoise: Bool
    {
        cncLevel != nil || autoCNC != nil || anc != nil || windBlock != nil || spatial != nil
    }

    /// What status reports and no write can change. Skipped, so that a saved
    /// status applies without editing. Voice prompts belong here because this
    /// firmware ignores writes to them.
    public static let readOnly: Set<String> = [
        "model", "address", "firmware", "batteries", "playing_from", "voice_prompts", "mode_index",
    ]

    /// Checks the whole file, so nothing is sent unless every value is valid.
    public static func parse(_ data: Data) throws -> SettingsFile
    {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw UsageError("a settings file is one JSON object")
        }
        var file = SettingsFile()
        for (key, value) in root {
            switch key {
            case "mode":
                file.mode = try string(value, key)
            case "noise":
                try file.parseNoise(value)
            case "volume":
                // status prints {"level": 11, "max": 31}; a bare number is easier to write.
                let level = (value as? [String: Any]).map { $0["level"] as Any } ?? value
                file.volume = try integer(level, key, 0 ... 255)
            case "eq":
                file.eq = try parseEQ(value)
            case "sidetone":
                let text = try string(value, key)
                guard let level = Sidetone.allCases.first(where: { $0.name == text.lowercased() }) else {
                    throw UsageError("sidetone is off, low, medium or high, not '\(text)'")
                }
                file.sidetone = level
            case "multipoint": file.multipoint = try bool(value, key)
            case "auto_pause": file.autoPause = try bool(value, key)
            case "auto_answer": file.autoAnswer = try bool(value, key)
            case "name": file.name = try string(value, key)
            default:
                guard readOnly.contains(key) else { throw UsageError("unknown setting '\(key)'") }
            }
        }
        // A saved status names its mode both ways; the index is only a fallback.
        if file.mode == nil, let index = root["mode_index"], !(index is NSNull) {
            file.mode = String(try integer(index, "mode_index", 0 ... 254))
        }
        return file
    }

    private mutating func parseNoise(_ value: Any) throws
    {
        guard let noise = value as? [String: Any] else { throw UsageError("noise is an object") }
        for (key, field) in noise {
            let name = "noise.\(key)"
            switch key {
            case "cnc_level": cncLevel = UInt8(try SettingsFile.integer(field, name, 0 ... 10))
            case "auto_cnc": autoCNC = try SettingsFile.bool(field, name)
            case "anc": anc = try SettingsFile.bool(field, name)
            case "wind_block": windBlock = try SettingsFile.bool(field, name)
            case "spatial":
                let text = try SettingsFile.string(field, name)
                guard let mode = Spatial.named(text) else {
                    throw UsageError("\(name) is off, room or head, not '\(text)'")
                }
                spatial = mode
            default: throw UsageError("unknown setting '\(name)'")
            }
        }
    }

    /// status prints a list of {"band", "value", "min", "max"}; an object
    /// such as {"bass": 3} is easier to write. Both work.
    private static func parseEQ(_ value: Any) throws -> [EQBand.ID: Int]
    {
        var pairs: [(String, Any)] = []
        if let bands = value as? [[String: Any]] {
            pairs = try bands.map { band in
                guard let name = band["band"] as? String, let level = band["value"] else {
                    throw UsageError("each eq band needs a band and a value")
                }
                return (name, level)
            }
        } else if let bands = value as? [String: Any] {
            pairs = bands.map { ($0.key, $0.value) }
        } else {
            throw UsageError("eq is an object such as {\"bass\": 3} or the list status prints")
        }
        var eq: [EQBand.ID: Int] = [:]
        for (name, level) in pairs {
            guard let band = EQBand.ID.allCases.first(where: { $0.name == name.lowercased() }) else {
                throw UsageError("eq has bass, mid and treble, not '\(name)'")
            }
            eq[band] = try integer(level, "eq.\(band.name)", -10 ... 10)
        }
        return eq
    }

    private static func string(_ value: Any, _ key: String) throws -> String
    {
        guard let text = value as? String else { throw UsageError("\(key) is a string") }
        return text
    }

    private static func bool(_ value: Any, _ key: String) throws -> Bool
    {
        guard let number = value as? NSNumber, isBoolean(number) else { throw UsageError("\(key) is true or false") }
        return number.boolValue
    }

    private static func integer(_ value: Any, _ key: String, _ range: ClosedRange<Int>) throws -> Int
    {
        guard let number = value as? NSNumber, !isBoolean(number), let whole = Int(exactly: number.doubleValue),
              range.contains(whole)
        else {
            throw UsageError("\(key) is a whole number from \(range.lowerBound) to \(range.upperBound)")
        }
        return whole
    }

    /// JSON true and 1 both arrive as NSNumber; only the CFBoolean is a boolean.
    private static func isBoolean(_ number: NSNumber) -> Bool
    {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
