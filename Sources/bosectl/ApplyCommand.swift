// apply: set many things at once from a settings file.

import ArgumentParser
import BMAP
import Foundation

struct Apply: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Apply a settings file: JSON in the shape 'bosectl --json status' prints.",
        discussion: """
            Only the settings the file names are touched, so a file can be as small as \
            {"mode": "aware", "volume": 8}. A saved status applies as it is: what no write \
            can change (battery, firmware, hosts, voice prompts) is skipped. The whole \
            file is checked before anything is sent, and settings that already match are \
            left alone.

            Save the current settings:  bosectl --json status > desk.json
            Restore them later:         bosectl apply desk.json
            """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: ArgumentHelp("The settings file, or - for standard input.", valueName: "file"))
    var path: String

    func run() throws
    {
        global.apply()
        let data: Data
        do {
            data = path == "-"
                ? FileHandle.standardInput.readDataToEndOfFile()
                : try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw Failure("cannot read \(path): \(error.localizedDescription)")
        }
        let file: SettingsFile
        do { file = try SettingsFile.parse(data) }
        catch let error as UsageError { throw Failure.usage("\(path): \(error.description)") }

        let results = try withHeadphones(global) { hp, _ in try hp.apply(file) }
        Output.emit(.object(results.map { ($0.key, .object([("value", .string($0.value)), ("changed", .bool($0.changed))])) })) {
            results.map { "\($0.key): \($0.value)" + ($0.changed ? "" : " (unchanged)") }.joined(separator: "\n")
        }
    }
}

struct Applied {
    var key: String
    var value: String
    var changed: Bool
}

extension Headphones {
    /// Mode first, since the noise settings belong to whichever mode is
    /// active; each setting is read first and written only if it differs.
    func apply(_ file: SettingsFile) throws -> [Applied]
    {
        var done: [Applied] = []
        if let text = file.mode {
            let index = try resolveMode(text)
            let changed = try currentModeIndex() != index
            if changed { try setMode(index) }
            done.append(Applied(key: "mode", value: modeName(index: index), changed: changed))
        }
        if file.changesNoise {
            var changed = false
            let mode = try updateActiveMode { mode in
                let before = mode
                if let level = file.cncLevel, level != mode.cncLevel { mode.setNoiseLevel(level, anc: file.anc) }
                if let anc = file.anc { mode.ancEnabled = anc }
                if let auto = file.autoCNC { mode.autoCNC = auto }
                if let wind = file.windBlock { mode.windBlock = wind }
                if let spatial = file.spatial { mode.spatial = spatial.rawValue }
                changed = mode != before
            }
            done.append(Applied(key: "noise", value: mode.settings.text, changed: changed))
        }
        if let level = file.volume {
            let changed = try volume().level != level
            if changed { try setVolume(level) }
            done.append(Applied(key: "volume", value: "\(level)", changed: changed))
        }
        if !file.eq.isEmpty {
            let current = try eq()
            let bands = file.eq.sorted { $0.key.rawValue < $1.key.rawValue }
            var changed = false
            for (band, value) in bands where current.first(where: { $0.id == band.rawValue })?.value != value {
                try setEQ(band, value)
                changed = true
            }
            let text = bands.map { "\($0.key.name) \(signed($0.value))" }.joined(separator: ", ")
            done.append(Applied(key: "eq", value: text, changed: changed))
        }
        if let level = file.sidetone {
            let changed = try sidetone() != level
            if changed { try setSidetone(level) }
            done.append(Applied(key: "sidetone", value: level.name, changed: changed))
        }
        if let on = file.multipoint {
            let changed = try multipoint() != on
            if changed { try setMultipoint(on) }
            done.append(Applied(key: "multipoint", value: on ? "on" : "off", changed: changed))
        }
        for (key, address, wanted) in [
            ("auto_pause", Function.autoPause, file.autoPause), ("auto_answer", Function.autoAnswer, file.autoAnswer),
        ] {
            guard let on = wanted else { continue }
            let changed = try flag(address) != on
            if changed { try setFlag(address, on) }
            done.append(Applied(key: key, value: on ? "on" : "off", changed: changed))
        }
        if let wanted = file.name {
            let changed = try name() != wanted
            if changed { try setName(wanted) }
            done.append(Applied(key: "name", value: wanted, changed: changed))
        }
        return done
    }
}
