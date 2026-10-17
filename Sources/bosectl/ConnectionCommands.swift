// What the headphones play from, where they route audio, and power.

import ArgumentParser
import BMAP
import BMAPBluetooth
import Foundation

struct Source: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show which host the headphones are playing from."
    )

    @OptionGroup var global: GlobalOptions

    func run() throws
    {
        global.apply()
        let source = try withHeadphones(global) { hp, _ in try hp.source() }
        let thisMac = source.address == global.mac.map(Discovery.normalizeAddress) || source.address == hostAddress()
        Output.emit(.object([
            ("source", .string(source.kindName)),
            ("address", .optional(source.address)),
            ("this_mac", .bool(thisMac)),
        ])) {
            var line = source.kindName
            if let address = source.address { line += " \(address)" }
            if thisMac { line += " (this Mac)" }
            return line
        }
    }
}

func hostAddress() -> String? { Discovery.hostAddress() }

struct Route: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Move audio to another host the headphones are connected to.",
        discussion: "Give the host's Bluetooth address, or 'here' for this Mac."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Host address, or 'here'.")
    var host: String

    func run() throws
    {
        global.apply()
        let text = host == "here" ? (hostAddress() ?? "") : host
        guard let bytes = parseAddress(text) else {
            throw Failure.usage("not a Bluetooth address: \(host)")
        }
        try withHeadphones(global) { hp, _ in try hp.route(to: bytes) }
        Output.emit(.object([("routed_to", .string(formatAddress(bytes)))])) { "routed to \(formatAddress(bytes))" }
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
