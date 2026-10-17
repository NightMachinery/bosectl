// Device settings: each command prints the setting, or changes it when given
// a value and prints what the headphones confirmed.

import ArgumentParser
import BMAP
import BMAPBluetooth
import Foundation

struct EQ: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eq",
        abstract: "Show or set the equalizer: bass, mid and treble, -10 to 10 each.",
        discussion: "'bosectl eq 3 0 -2' sets all three bands; 'bosectl eq flat' resets them; 'bosectl eq --bass 4' sets one."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "BASS MID TREBLE, or 'flat'.")
    var values: [String] = []

    @Option(help: "Set the bass band only.") var bass: Int?
    @Option(help: "Set the mid band only.") var mid: Int?
    @Option(help: "Set the treble band only.") var treble: Int?

    func run() throws
    {
        global.apply()
        var changes: [(EQBand.ID, Int)] = []
        if values == ["flat"] {
            changes = EQBand.ID.allCases.map { ($0, 0) }
        } else if !values.isEmpty {
            let numbers = values.compactMap { Int($0) }
            guard numbers.count == 3, values.count == 3 else {
                throw Failure.usage("give three values (bass mid treble), or 'flat'")
            }
            changes = zip(EQBand.ID.allCases, numbers).map { ($0, $1) }
        }
        if let bass { changes.append((.bass, bass)) }
        if let mid { changes.append((.mid, mid)) }
        if let treble { changes.append((.treble, treble)) }
        if let bad = changes.first(where: { !(-10 ... 10).contains($0.1) }) {
            throw Failure.usage("\(bad.0.name) must be -10 to 10, not \(bad.1)")
        }

        let bands = try withHeadphones(global) { hp, _ -> [EQBand] in
            for (band, value) in changes {
                try hp.setEQ(band, value)
            }
            return try hp.eq()
        }
        Output.emit(.object([("eq", .array(bands.map(\.json)))])) {
            bands.map { "\($0.name) \(signed($0.value))" }.joined(separator: ", ")
        }
    }
}

struct Name: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or set the headphones' Bluetooth name (at most 31 bytes)."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "New name.")
    var name: [String] = []

    func run() throws
    {
        global.apply()
        let wanted = name.isEmpty ? nil : name.joined(separator: " ")
        let current = try withHeadphones(global) { hp, _ -> String in
            if let wanted { try hp.setName(wanted) }
            return try hp.name()
        }
        Output.emit(.object([("name", .string(current))])) { current }
    }
}

struct SidetoneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sidetone",
        abstract: "Show or set how much of your own voice you hear on calls: off, low, medium or high."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "off, low, medium or high.")
    var level: String?

    func run() throws
    {
        global.apply()
        let wanted = try level.map { text -> Sidetone in
            let key = text.lowercased() == "med" ? "medium" : text.lowercased()
            guard let s = Sidetone.allCases.first(where: { $0.name == key }) else {
                throw Failure.usage("sidetone takes off, low, medium or high")
            }
            return s
        }
        let current = try withHeadphones(global) { hp, _ -> Sidetone in
            if let wanted { try hp.setSidetone(wanted) }
            return try hp.sidetone()
        }
        Output.emit(.object([("sidetone", .string(current.name))])) { current.name }
    }
}

struct Multipoint: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or toggle multipoint (staying connected to two hosts at once)."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "on or off.")
    var state: String?

    func run() throws
    {
        global.apply()
        let wanted = try state.map { try parseSwitch($0, "multipoint") }
        let current = try withHeadphones(global) { hp, _ -> Bool in
            if let wanted { try hp.setMultipoint(wanted) }
            return try hp.multipoint()
        }
        Output.emit(.object([("multipoint", .bool(current))])) { onOff(current) }
    }
}

/// A setting that is a single on/off byte.
protocol FlagSetting {
    static var name: String { get }
    static var key: String { get }
    static var address: Address { get }
    static var summary: String { get }
}

struct FlagCommand<S: FlagSetting>: ParsableCommand {
    static var configuration: CommandConfiguration
    {
        CommandConfiguration(commandName: S.name, abstract: S.summary)
    }

    @OptionGroup var global: GlobalOptions

    @Argument(help: "on or off.")
    var state: String?

    func run() throws
    {
        global.apply()
        let wanted = try state.map { try parseSwitch($0, S.name) }
        let current = try withHeadphones(global) { hp, _ -> Bool in
            if let wanted { try hp.setFlag(S.address, wanted) }
            return try hp.flag(S.address)
        }
        Output.emit(.object([(S.key, .bool(current))])) { onOff(current) }
    }
}

enum AutoPauseSetting: FlagSetting {
    static let name = "auto-pause"
    static let key = "auto_pause"
    static let address = Function.autoPause
    static let summary = "Show or toggle pausing playback when you take the headphones off."
}

enum AutoAnswerSetting: FlagSetting {
    static let name = "auto-answer"
    static let key = "auto_answer"
    static let address = Function.autoAnswer
    static let summary = "Show or toggle answering calls when you put the headphones on."
}

struct Prompts: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or toggle voice prompts, and set their language.",
        discussion: "Languages: " + VoicePrompts.languages.sorted { $0.key < $1.key }.map(\.value).joined(separator: ", ") + "."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "on or off.")
    var state: String?

    @Option(help: "Prompt language, by name (e.g. 'US English') or number.")
    var language: String?

    func run() throws
    {
        global.apply()
        let wanted = try state.map { try parseSwitch($0, "prompts") }
        let languageID = try language.map { text -> UInt8 in
            if let n = UInt8(text), VoicePrompts.languages[n] != nil { return n }
            guard let match = VoicePrompts.languages.first(where: { $0.value.lowercased() == text.lowercased() }) else {
                throw Failure.usage("unknown language '\(text)' (see 'bosectl prompts --help')")
            }
            return match.key
        }
        let current = try withHeadphones(global) { hp, _ -> VoicePrompts in
            var prompts = try hp.voicePrompts()
            if wanted != nil || languageID != nil {
                if let wanted { prompts.enabled = wanted }
                if let languageID { prompts.language = languageID }
                try hp.setVoicePrompts(prompts)
                prompts = try hp.voicePrompts()
            }
            return prompts
        }
        Output.emit(.object([("enabled", .bool(current.enabled)), ("language", .string(current.languageName))])) {
            "\(onOff(current.enabled)) (\(current.languageName))"
        }
    }
}

struct Buttons: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or remap the shortcut button.",
        discussion: "'bosectl buttons set ACTION' remaps it; the actions this model accepts are listed by 'bosectl buttons'."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "'set ACTION' to remap.")
    var words: [String] = []

    func run() throws
    {
        global.apply()
        var action: UInt8?
        if !words.isEmpty {
            guard words.count == 2, words[0] == "set" else { throw Failure.usage("usage: bosectl buttons [set ACTION]") }
            guard let id = ButtonMapping.action(named: words[1]) ?? UInt8(words[1]) else {
                throw Failure.usage("unknown action '\(words[1])' (see 'bosectl buttons')")
            }
            action = id
        }
        let mapping = try withHeadphones(global) { hp, _ -> ButtonMapping in
            var mapping = try hp.buttons()
            if let action {
                guard mapping.supported.isEmpty || mapping.supported.contains(action) else {
                    throw Failure.usage("this button does not accept \(ButtonMapping.actionName(action)) (it accepts \(mapping.supported.map(ButtonMapping.actionName).joined(separator: ", ")))")
                }
                mapping.action = action
                try hp.setButton(mapping)
                mapping = try hp.buttons()
            }
            return mapping
        }
        Output.emit(.object([
            ("button", .string(mapping.buttonName)),
            ("event", .string(mapping.eventName)),
            ("action", .string(mapping.actionName)),
            ("supported", .array(mapping.supported.map { .string(ButtonMapping.actionName($0)) })),
        ])) {
            keyValueLines([
                ("button", mapping.buttonName),
                ("event", mapping.eventName),
                ("action", mapping.actionName),
                ("accepts", mapping.supported.map(ButtonMapping.actionName).joined(separator: ", ")),
            ])
        }
    }
}
