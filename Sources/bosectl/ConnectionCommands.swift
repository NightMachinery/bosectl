// The hosts the headphones remember, what they play from, pairing and power.

import ArgumentParser
import BMAP
import BMAPBluetooth
import Foundation

extension RememberedHost {
    /// The name, or the address when the headphones report none.
    var label: String
    {
        let base = name.isEmpty ? address : name
        return isSelf ? "\(base) (this Mac)" : base
    }

    var json: JSON
    {
        .object([
            ("address", .string(address)),
            ("name", .string(name)),
            ("connected", .bool(connected)),
            ("playing", .bool(playing)),
            ("this_mac", .bool(isSelf)),
        ])
    }
}

struct Source: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show which host the headphones are playing from."
    )

    @OptionGroup var global: GlobalOptions

    func run() throws
    {
        global.apply()
        let hosts = try withHeadphones(global) { hp, _ in try hp.playingFrom() }
        Output.emit(.object([("playing_from", .array(hosts.map(\.json)))])) {
            hosts.isEmpty ? "nothing" : hosts.map { "\($0.address)  \($0.label)" }.joined(separator: "\n")
        }
    }
}

struct Hosts: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List, connect and disconnect the hosts the headphones remember.",
        discussion: """
        The headphones keep a list of the hosts (phones, computers) paired with
        them and stay linked to at most two at once. These commands act on the
        headphones' side of those links, so they reach hosts other than this
        Mac. For this Mac's own link, use 'bosectl connect' and 'bosectl
        disconnect'.
        """,
        subcommands: [HostsList.self, HostsConnect.self, HostsDisconnect.self],
        defaultSubcommand: HostsList.self
    )
}

struct HostsList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the remembered hosts: which are linked, and which is playing."
    )

    @OptionGroup var global: GlobalOptions

    func run() throws
    {
        global.apply()
        let hosts = try withHeadphones(global) { hp, _ in try hp.hosts() }
        Output.emit(.object([("hosts", .array(hosts.map(\.json)))])) {
            if hosts.isEmpty { return "no remembered hosts" }
            return hosts.map { h in
                let state = h.playing ? "playing  " : h.connected ? "connected" : "         "
                return "\(h.address)  \(state)  \(h.label)"
            }.joined(separator: "\n")
        }
    }
}

/// Finds a remembered host by address, name substring, or "here".
func resolveHost(_ text: String, in hosts: [RememberedHost]) throws -> RememberedHost
{
    if ["here", "this", "self"].contains(text.lowercased()), let me = hosts.first(where: \.isSelf) {
        return me
    }
    if parseAddress(text) != nil {
        let address = Discovery.normalizeAddress(text)
        if let host = hosts.first(where: { $0.address == address }) { return host }
        throw Failure.usage("the headphones do not remember \(address) (see 'bosectl hosts')")
    }
    let matches = hosts.filter { $0.name.range(of: text, options: .caseInsensitive) != nil }
    guard let host = matches.first else {
        throw Failure.usage("no remembered host's name contains '\(text)' (see 'bosectl hosts')")
    }
    if matches.count > 1 {
        throw Failure.usage("'\(text)' matches \(matches.map(\.label).joined(separator: ", ")); give an address")
    }
    return host
}

/// Polls the host's link state until it is `connected` or `wait` runs out.
func awaitHost(_ hp: Headphones, _ address: String, connected: Bool, wait: Double) -> Bool
{
    let end = Date().addingTimeInterval(wait)
    repeat {
        if let info = try? hp.hostInfo(address), info.connected == connected { return true }
        Thread.sleep(forTimeInterval: 0.5)
    } while Date() < end
    return false
}

struct HostsConnect: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "connect",
        abstract: "Have the headphones connect to a remembered host.",
        discussion: """
        The host must be in range with Bluetooth on. If two hosts are linked
        already, the headphones drop one to make room.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Host address or part of its name.")
    var host: String

    @Option(help: ArgumentHelp("Seconds to wait for the link; 0 returns once the headphones accept the request.", valueName: "seconds"))
    var wait: Double = 15

    func run() throws
    {
        global.apply()
        let (host, was, now) = try withHeadphones(global) { hp, _ -> (RememberedHost, Bool, Bool) in
            let host = try resolveHost(self.host, in: hp.hosts())
            if host.isSelf { throw Failure.usage("that is this Mac; it is connected already") }
            if host.connected { return (host, true, true) }
            try hp.connectHost(host.address)
            var after = host
            after.connected = wait > 0 && awaitHost(hp, host.address, connected: true, wait: wait)
            return (after, false, after.connected)
        }
        Output.emit(.object([
            ("host", host.json), ("connected", .bool(now)), ("changed", .bool(!was && now)),
            ("requested", .bool(!was)),
        ])) {
            if was { return "\(host.label): already connected" }
            if wait == 0 { return "\(host.label): connection requested" }
            return now ? "\(host.label): connected" : "\(host.label): not connected after \(Int(wait)) s"
        }
        if !was, wait > 0, !now { throw ExitCode(Exit.failure) }
    }
}

struct HostsDisconnect: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disconnect",
        abstract: "Have the headphones drop their link to a host; it stays paired."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Host address or part of its name.")
    var host: String

    func run() throws
    {
        global.apply()
        let (host, was, gone) = try withHeadphones(global) { hp, _ -> (RememberedHost, Bool, Bool) in
            let host = try resolveHost(self.host, in: hp.hosts())
            // macOS pages straight back, and the command would cut its own
            // channel; 'bosectl disconnect' drops the link from this side.
            if host.isSelf { throw Failure.usage("that is this Mac; use 'bosectl disconnect'") }
            if !host.connected { return (host, false, true) }
            try hp.disconnectHost(host.address)
            var after = host
            after.connected = !awaitHost(hp, host.address, connected: false, wait: 5)
            after.playing = after.playing && after.connected
            return (after, true, !after.connected)
        }
        Output.emit(.object([("host", host.json), ("connected", .bool(!gone)), ("changed", .bool(was && gone))])) {
            if !was { return "\(host.label): already disconnected" }
            return gone ? "\(host.label): disconnected" : "\(host.label): still connected"
        }
        if was, !gone { throw ExitCode(Exit.failure) }
    }
}

struct Pair: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Put the headphones in pairing mode so another device can pair."
    )

    @OptionGroup var global: GlobalOptions

    func run() throws
    {
        global.apply()
        try withHeadphones(global) { hp, _ in try hp.enterPairingMode() }
        Output.emit(.object([("pairing", .bool(true))])) { "pairing mode on" }
    }
}

struct PowerOff: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "power-off",
        abstract: "Turn the headphones off. Nothing can turn them back on remotely.",
        aliases: ["off"]
    )

    @OptionGroup var global: GlobalOptions

    func run() throws
    {
        global.apply()
        try withHeadphones(global) { hp, _ in try hp.powerOff() }
        Output.emit(.object([("power", .string("off"))])) { "powering off" }
    }
}
