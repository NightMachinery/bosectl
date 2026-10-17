// bosectl: observe and control Bose headphones (QuietComfort Ultra 2nd Gen and
// other BMAP devices) from the macOS command line.

import ArgumentParser
import Foundation

let version = "0.2.0"

struct Bosectl: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bosectl",
        abstract: "Control Bose headphones from macOS over the BMAP protocol.",
        discussion: """
        Commands never connect the headphones on their own: if this Mac is not
        linked to them, a command fails at once with exit status 3. Run
        'bosectl connect' first, or pass --auto-connect.

        Exit status: 0 ok, 1 failure, 2 usage error, 3 not connected.
        """,
        version: version,
        subcommands: [
            Status.self, BatteryCommand.self, Info.self,
            Mode.self, Modes.self, Profile.self, FavoritesCommand.self,
            PresetShortcut<QuietPreset>.self, PresetShortcut<AwarePreset>.self,
            PresetShortcut<ImmersionPreset>.self, PresetShortcut<CinemaPreset>.self,
            CNC.self, ANC.self, Wind.self, SpatialCommand.self,
            EQ.self, Name.self, SidetoneCommand.self, Multipoint.self,
            FlagCommand<AutoPauseSetting>.self, FlagCommand<AutoAnswerSetting>.self,
            Prompts.self, Buttons.self,
            VolumeCommand.self, Media.self,
            Source.self, Hosts.self, Pair.self, PowerOff.self,
            Devices.self, LinkCommand.self, Connect.self, Disconnect.self,
            Apply.self, NearbyCommand.self,
            Watch.self, Dump.self, Raw.self,
        ]
    )
}

/// ArgumentParser only accepts a subcommand's options after its name; move
/// global options given before the subcommand ('bosectl --json status') to
/// after it.
func hoistGlobalOptions(_ args: [String]) -> [String]
{
    let flags: Set<String> = ["--json", "--auto-connect", "--trace", "--le"]
    let valued: Set<String> = ["--mac", "--device", "--color", "--timeout"]
    var leading: [String] = []
    var i = 0
    while i < args.count {
        let arg = args[i]
        let name = arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg
        if flags.contains(arg) || (valued.contains(name) && arg.contains("=")) {
            leading.append(arg)
            i += 1
        } else if valued.contains(arg), i + 1 < args.count {
            leading.append(contentsOf: args[i ... i + 1])
            i += 2
        } else {
            break
        }
    }
    guard !leading.isEmpty, i < args.count else { return args }
    // Insert after the subcommand path (the words that are not options).
    var j = i
    while j < args.count, !args[j].hasPrefix("-"), Bosectl.isSubcommandPath(Array(args[i ... j])) {
        j += 1
    }
    return Array(args[i ..< j]) + leading + Array(args[j...])
}

extension Bosectl {
    /// True if `words` name a subcommand, e.g. ["mode"] or ["profile", "list"].
    static func isSubcommandPath(_ words: [String]) -> Bool
    {
        var command: ParsableCommand.Type = Bosectl.self
        for word in words {
            guard let next = command.configuration.subcommands.first(where: {
                $0._commandName == word || $0.configuration.aliases.contains(word)
            }) else { return false }
            command = next
        }
        return true
    }
}

// ArgumentParser exits 64 on a usage error; sonyctl's convention is 2, and
// our own failures carry their status.
do {
    var command = try Bosectl.parseAsRoot(hoistGlobalOptions(Array(CommandLine.arguments.dropFirst())))
    try command.run()
} catch let failure as Failure {
    Output.error("bosectl: \(failure.message)")
    exit(failure.status)
} catch {
    let code = Bosectl.exitCode(for: error)
    let message = Bosectl.fullMessage(for: error)
    if code == .success {
        if !message.isEmpty { print(message) }
        exit(Exit.ok)
    }
    if let exitCode = error as? ExitCode {
        exit(exitCode.rawValue)
    }
    if !message.isEmpty { Output.error(message) }
    exit(code == .validationFailure ? Exit.usage : code.rawValue)
}
