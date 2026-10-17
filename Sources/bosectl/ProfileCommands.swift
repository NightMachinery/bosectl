// Custom modes ("profiles"): the editable slots next to the four presets.

import ArgumentParser
import BMAP
import BMAPBluetooth
import Foundation

struct Profile: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create, change and delete custom modes.",
        discussion: "Custom modes live on the headphones, so every host and the Bose app see them.",
        subcommands: [ProfileList.self, ProfileSet.self, ProfileRemove.self],
        defaultSubcommand: ProfileList.self
    )
}

struct ProfileSet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Create a custom mode, or change one; unspecified settings are kept."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Custom mode name.")
    var name: String

    @Option(help: "Noise level, 0 (most cancellation) to 10.") var cnc: UInt8?
    @Option(help: "Noise cancellation: on or off.") var anc: String?
    @Option(help: "Wind block: on or off.") var wind: String?
    @Option(name: .customLong("auto-cnc"), help: "Automatic noise level: on or off.") var autoCNC: String?
    @Option(help: "Spatial audio: off, room or head.") var spatial: String?
    @Option(help: "Rename the mode.") var rename: String?
    @Flag(help: "Switch to the mode afterwards.") var activate = false

    func run() throws
    {
        global.apply()
        let anc = try self.anc.map { try parseSwitch($0, "--anc") }
        let wind = try self.wind.map { try parseSwitch($0, "--wind") }
        let autoCNC = try self.autoCNC.map { try parseSwitch($0, "--auto-cnc") }
        let spatial = try self.spatial.map { text -> Spatial in
            guard let s = Spatial.named(text) else { throw Failure.usage("--spatial takes off, room or head") }
            return s
        }
        let saved = try withHeadphones(global) { hp, _ -> ModeConfig in
            let mode = try hp.saveCustomMode(name) { mode in
                if let cnc { mode.cncLevel = cnc }
                if let anc { mode.ancEnabled = anc }
                if let wind { mode.windBlock = wind }
                if let autoCNC { mode.autoCNC = autoCNC }
                if let spatial { mode.spatial = spatial.rawValue }
                if let rename { mode.name = rename }
            }
            if activate { try hp.setMode(mode.index) }
            return mode
        }
        Output.emit(saved.json) {
            "\(saved.name) (slot \(saved.index)): cnc \(saved.cncLevel), anc \(onOff(saved.ancEnabled)), wind \(onOff(saved.windBlock)), spatial \(saved.spatialName)"
                + (saved.autoCNC ? ", auto cnc" : "")
        }
    }
}

struct ProfileRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Delete a custom mode.",
        aliases: ["delete"]
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Custom mode name.")
    var name: String

    func run() throws
    {
        global.apply()
        let slot = try withHeadphones(global) { hp, _ in try hp.deleteCustomMode(name) }
        Output.emit(.object([("deleted", .string(name)), ("index", .int(Int(slot)))])) { "deleted \(name) (slot \(slot))" }
    }
}
