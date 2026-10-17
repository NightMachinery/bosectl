// Volume and media keys.

import ArgumentParser
import BMAP
import BMAPBluetooth
import Foundation

extension Volume {
    var json: JSON { .object([("level", .int(level)), ("max", .int(max))]) }
    var text: String { "\(level)/\(max)" }
}

struct VolumeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "volume",
        abstract: "Show or set the headphones' volume.",
        discussion: """
        'bosectl volume 12' sets a level; 'bosectl volume up' and 'bosectl
        volume down' step by one, or by the number given ('volume up 3').
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "A level, or up or down.")
    var level: String?

    @Argument(help: "Steps for up and down.")
    var step: Int = 1

    func run() throws
    {
        global.apply()
        enum Change { case to(Int), by(Int) }
        let change: Change?
        switch level?.lowercased() {
        case nil: change = nil
        case "up", "+": change = .by(step)
        case "down", "-": change = .by(-step)
        case let text?:
            guard let value = Int(text) else { throw Failure.usage("volume takes a level, up or down, not '\(text)'") }
            change = .to(value)
        }
        let volume = try withHeadphones(global) { hp, _ -> Volume in
            switch change {
            case nil:
                return try hp.volume()
            case .to(let value)?:
                return try hp.setVolume(value)
            case .by(let delta)?:
                let current = try hp.volume()
                return try hp.setVolume(min(current.max, max(0, current.level + delta)))
            }
        }
        Output.emit(volume.json) { volume.text }
    }
}

struct Media: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Send play, pause, toggle, next, previous or stop to the host the headphones play from.",
        discussion: """
            The headphones pass the action on to the host, as their own buttons do. \
            Pausing or stopping with nothing playing succeeds and changes nothing. \
            toggle pauses what is playing and plays otherwise.
            """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "play, pause, toggle, next, previous (prev) or stop.")
    var action: String

    func run() throws
    {
        global.apply()
        if ["toggle", "play-pause"].contains(self.action.lowercased()) {
            return try toggle()
        }
        guard let action = MediaAction.named(action) else {
            throw Failure.usage("media takes play, pause, toggle, next, previous or stop, not '\(self.action)'")
        }
        let applied = try withHeadphones(global) { hp, _ in try hp.media(action) }
        // Pausing or stopping what is not playing already has the outcome a
        // script asked for; anything else had nothing to act on.
        guard applied || action == .pause || action == .stop else {
            throw Failure("nothing to \(action.name): the host is not playing anything")
        }
        Output.emit(.object([("media", .string(action.name)), ("applied", .bool(applied))])) {
            applied ? action.name : "\(action.name): nothing playing"
        }
    }

    private func toggle() throws
    {
        guard let sent = try withHeadphones(global, { hp, _ in try hp.toggleMedia() }) else {
            throw Failure("nothing to toggle: the host has nothing to play or pause")
        }
        Output.emit(.object([("media", .string("toggle")), ("applied", .bool(true)), ("sent", .string(sent.name))])) {
            sent.name
        }
    }
}
