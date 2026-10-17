// Audio modes and the live noise settings of the active mode.

import ArgumentParser
import BMAP
import BMAPBluetooth
import Foundation

struct Mode: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the current mode, or switch to one by name or index.",
        discussion: "Presets: quiet, aware, immersion, cinema. Custom modes go by their name (see 'bosectl modes')."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Mode to switch to.")
    var mode: String?

    @Flag(name: .long, help: "Have the headphones announce the new mode.")
    var announce = false

    func run() throws
    {
        global.apply()
        try switchMode(global, to: mode, announce: announce)
    }
}

/// Prints the current mode, switching first when `name` is given.
func switchMode(_ global: GlobalOptions, to name: String?, announce: Bool) throws
{
    let (index, modeName) = try withHeadphones(global) { hp, _ -> (UInt8, String) in
        if let name {
            let index = try hp.resolveMode(name)
            try hp.setMode(index, announce: announce)
            return (index, hp.currentModeName(index: index))
        }
        let index = try hp.currentModeIndex()
        return (index, hp.currentModeName(index: index))
    }
    Output.emit(.object([("mode", .string(modeName)), ("index", .int(Int(index)))])) { modeName }
}

/// `bosectl quiet` and friends: shortcuts for `bosectl mode NAME`.
struct PresetShortcut<P: PresetName>: ParsableCommand {
    static var configuration: CommandConfiguration
    {
        CommandConfiguration(commandName: P.name, abstract: "Switch to the \(P.name) mode (\(P.summary)).")
    }

    @OptionGroup var global: GlobalOptions

    @Flag(name: .long, help: "Have the headphones announce the new mode.")
    var announce = false

    func run() throws
    {
        global.apply()
        try switchMode(global, to: P.name, announce: announce)
    }
}

protocol PresetName {
    static var name: String { get }
}

extension PresetName {
    static var summary: String { Presets.modes.first { $0.name == name }?.summary ?? "" }
}

enum QuietPreset: PresetName { static let name = "quiet" }
enum AwarePreset: PresetName { static let name = "aware" }
enum ImmersionPreset: PresetName { static let name = "immersion" }
enum CinemaPreset: PresetName { static let name = "cinema" }

struct Modes: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List every mode slot: the presets and the custom modes."
    )

    @OptionGroup var global: GlobalOptions

    @Flag(name: .long, help: "Include empty custom slots.")
    var all = false

    func run() throws
    {
        global.apply()
        try listModes(global, all: all)
    }
}

struct ProfileList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List every mode slot: the presets and the custom modes."
    )

    @OptionGroup var global: GlobalOptions

    @Flag(name: .long, help: "Include empty custom slots.")
    var all = false

    func run() throws
    {
        global.apply()
        try listModes(global, all: all)
    }
}

func listModes(_ global: GlobalOptions, all: Bool) throws
{
    let (modes, current) = try withHeadphones(global) { hp, _ in
        (try hp.modes(), try? hp.currentModeIndex())
    }
    let shown = modes.filter { all || !$0.isEmpty }
    Output.emit(.object([
        ("current", .optional(current.map(Int.init))),
        ("modes", .array(shown.map(\.json))),
    ])) {
        shown.map { m in
            let marker = m.index == current ? "*" : " "
            let kind = m.editable ? (m.isEmpty ? "empty " : "custom") : "preset"
            var line = "\(marker) \(m.index < 10 ? " " : "")\(m.index)  \(kind)  \(m.displayName)"
            if !m.isEmpty {
                line += "  (cnc \(m.cncLevel), anc \(onOff(m.ancEnabled)), wind \(onOff(m.windBlock)), spatial \(m.spatialName))"
            }
            return line
        }.joined(separator: "\n")
    }
}

// MARK: Live noise settings (31.10)

/// Reads the active mode's settings, applies `change` when given, and prints
/// the result.
func audioSettingsCommand(_ global: GlobalOptions, _ change: ((inout AudioSettings) -> Void)?) throws
{
    let settings = try withHeadphones(global) { hp, _ in
        if let change { return try hp.updateAudioSettings(change) }
        return try hp.audioSettings()
    }
    Output.emit(settings.json) { settings.text }
}

struct CNC: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cnc",
        abstract: "Show or set the noise level of the active mode: 0 cancels most, 10 lets most in."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Level, 0 to 10.")
    var level: UInt8?

    func validate() throws
    {
        if let level, level > 10 { throw ValidationError("the level must be 0 to 10") }
    }

    func run() throws
    {
        global.apply()
        try audioSettingsCommand(global, level.map { level in { $0.cncLevel = level } })
    }
}

struct ANC: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "anc",
        abstract: "Show or toggle noise cancellation in the active mode."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "on or off.")
    var state: String?

    func run() throws
    {
        global.apply()
        let on = try state.map { try parseSwitch($0, "anc") }
        try audioSettingsCommand(global, on.map { on in { $0.ancEnabled = on } })
    }
}

struct Wind: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or toggle wind block in the active mode."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "on or off.")
    var state: String?

    func run() throws
    {
        global.apply()
        let on = try state.map { try parseSwitch($0, "wind") }
        try audioSettingsCommand(global, on.map { on in { $0.windBlock = on } })
    }
}

struct AutoCNC: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auto-cnc",
        abstract: "Show or toggle automatic noise level (ActiveSense) in the active mode."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "on or off.")
    var state: String?

    func run() throws
    {
        global.apply()
        let on = try state.map { try parseSwitch($0, "auto-cnc") }
        try audioSettingsCommand(global, on.map { on in { $0.autoCNC = on } })
    }
}

struct SpatialCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spatial",
        abstract: "Show or set spatial audio in the active mode: off, room (fixed stage) or head (follows your head)."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "off, room or head.")
    var mode: String?

    func run() throws
    {
        global.apply()
        let spatial = try mode.map { text -> Spatial in
            guard let s = Spatial.named(text) else { throw Failure.usage("spatial takes off, room or head") }
            return s
        }
        try audioSettingsCommand(global, spatial.map { s in { $0.spatial = s.rawValue } })
    }
}
