// Helpers shared by the BMAP commands.

import ArgumentParser
import BMAP
import BMAPBluetooth
import Foundation

/// Runs `body` with a typed API over a fresh session, turning protocol
/// errors into failures.
func withHeadphones<T>(_ options: GlobalOptions, _ body: (Headphones, Target) throws -> T) throws -> T
{
    try withSession(options) { session, target in
        let headphones = Headphones(session, timeout: options.timeout)
        do {
            return try body(headphones, target)
        } catch let error as UsageError {
            throw Failure.usage(error.description)
        } catch let error as ParseError {
            throw Failure(error.description)
        } catch let error as NotApplied {
            throw Failure(error.description)
        }
    }
}

/// on/off, true/false, yes/no, 1/0.
func parseSwitch(_ text: String, _ what: String) throws -> Bool
{
    switch text.lowercased() {
    case "on", "true", "yes", "1", "enable", "enabled": return true
    case "off", "false", "no", "0", "disable", "disabled": return false
    default: throw Failure.usage("\(what) takes on or off, not '\(text)'")
    }
}

func onOff(_ value: Bool) -> String { value ? "on" : "off" }

/// "  key: value" lines with the values aligned.
func keyValueLines(_ rows: [(String, String)]) -> String
{
    let width = rows.map(\.0.count).max() ?? 0
    return rows.map { key, value in
        key + ":" + String(repeating: " ", count: width - key.count + 1) + value
    }.joined(separator: "\n")
}

func signed(_ value: Int) -> String { value > 0 ? "+\(value)" : "\(value)" }

extension Battery {
    /// sonyctl's shape, so one consumer reads both tools: a list of parts,
    /// each with a level (null when there is no reading) and a charging
    /// state. The headphones are a single part, and which byte says they
    /// are charging is not known yet.
    var json: JSON { .object([("batteries", .array([partJSON]))]) }

    var partJSON: JSON
    {
        .object([("part", .string("battery")), ("level_percent", .optional(percent)), ("charging", .string("unknown"))])
    }

    var text: String { percent.map { "\($0)%" } ?? "NA" }
}

extension VoicePrompts {
    var json: JSON
    {
        .object([
            ("language", .string(languageName)),
            ("announce_connections", .bool(announceConnections)),
            ("announce_battery", .optional(announceBattery)),
        ])
    }

    var text: String
    {
        var parts = [languageName]
        if announceConnections { parts.append("connections") }
        if announceBattery == true { parts.append("battery") }
        return parts.joined(separator: ", ")
    }
}

extension EQBand {
    var json: JSON
    {
        .object([("band", .string(name)), ("value", .int(value)), ("min", .int(min)), ("max", .int(max))])
    }
}

extension AudioSettings {
    var spatialName: String { Spatial(rawValue: spatial)?.name ?? "spatial \(spatial)" }

    var json: JSON
    {
        .object([
            ("cnc_level", .int(Int(cncLevel))),
            ("auto_cnc", .bool(autoCNC)),
            ("anc", .bool(ancEnabled)),
            ("wind_block", .bool(windBlock)),
            ("spatial", .string(spatialName)),
        ])
    }

    var text: String
    {
        "cnc \(cncLevel)/10, anc \(onOff(ancEnabled)), wind block \(onOff(windBlock)), spatial \(spatialName)"
            + (autoCNC ? ", auto cnc" : "")
    }
}

extension ModeConfig {
    /// Preset names are fixed; custom slots carry their own.
    var displayName: String
    {
        if !editable, let preset = Presets.name(of: index) { return preset }
        return name
    }

    var spatialName: String { Spatial(rawValue: spatial)?.name ?? "spatial \(spatial)" }

    var json: JSON
    {
        .object([
            ("index", .int(Int(index))),
            ("name", .string(displayName)),
            ("preset", .bool(!editable)),
            ("empty", .bool(isEmpty)),
            ("favorite", .bool(favorite)),
            ("cnc_level", .int(Int(cncLevel))),
            ("auto_cnc", .bool(autoCNC)),
            ("anc", .bool(ancEnabled)),
            ("wind_block", .bool(windBlock)),
            ("spatial", .string(spatialName)),
        ])
    }
}

extension Headphones {
    /// A mode's name: a preset name, the custom slot's own name, or "none"
    /// when no mode is active.
    func modeName(index: UInt8?) -> String
    {
        guard let index else { return "none" }
        if let preset = Presets.name(of: index) { return preset }
        if let mode = try? mode(at: index) { return mode.displayName }
        return "mode \(index)"
    }

    /// Finds a mode by preset name, custom name (case-insensitive) or index.
    func resolveMode(_ text: String) throws -> UInt8
    {
        if let index = Presets.index(named: text) { return index }
        let all = try modes()
        return try resolveMode(text, in: all)
    }

    func resolveMode(_ text: String, in all: [ModeConfig]) throws -> UInt8
    {
        if let index = Presets.index(named: text) { return index }
        if let mode = all.first(where: { !$0.isEmpty && $0.displayName.lowercased() == text.lowercased() }) {
            return mode.index
        }
        if let index = UInt8(text), all.contains(where: { $0.index == index && !$0.isEmpty }) {
            return index
        }
        let names = all.filter { !$0.isEmpty }.map(\.displayName)
        throw Failure.usage("no mode named '\(text)' (modes: \(names.joined(separator: ", ")))")
    }
}
