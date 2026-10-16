// Commands that act on pairing and the baseband link, not on BMAP.

import ArgumentParser
import BMAP
import BMAPBluetooth
import Foundation

struct Devices: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List paired Bluetooth devices, marking the Bose ones."
    )

    @OptionGroup var global: GlobalOptions

    @Flag(name: .long, help: "List every paired device, not just Bose ones.")
    var all = false

    func run() throws
    {
        global.apply()
        let devices = Discovery.pairedDevices().filter { all || $0.looksLikeBose }
        Output.emit(.object([("devices", .array(devices.map(\.json)))])) {
            if devices.isEmpty { return all ? "no paired devices" : "no paired Bose devices (try --all)" }
            return devices.map { d in
                var line = "\(d.address)  \(d.isConnected ? "connected    " : "not connected")  \(d.name)"
                if let pid = d.productID, let model = Catalog.lookup(pid) {
                    line += "  (\(model.name))"
                }
                return line
            }.joined(separator: "\n")
        }
    }
}

extension PairedDevice {
    var json: JSON
    {
        .object([
            ("name", .string(name)),
            ("address", .string(address)),
            ("connected", .bool(isConnected)),
            ("bose", .bool(looksLikeBose)),
            ("product_id", productID.map { .string(String(format: "0x%04x", $0)) } ?? .null),
            ("model", .optional(productID.flatMap { Catalog.lookup($0)?.name })),
        ])
    }
}

struct LinkState: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "link",
        abstract: "Is this Mac linked to the headphones? Exit 0 if so, 3 if not."
    )

    @OptionGroup var global: GlobalOptions

    func run() throws
    {
        global.apply()
        let target = try Target.resolve(global)
        let linked = target.isLinked
        Output.emit(.object([("device", .string(target.label)), ("connected", .bool(linked))])) {
            "\(target.label): \(linked ? "connected" : "not connected")"
        }
        if !linked { throw ExitCode(Exit.notConnected) }
    }
}

struct Connect: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Link this Mac to the headphones (does not affect their other hosts)."
    )

    @OptionGroup var global: GlobalOptions

    func run() throws
    {
        global.apply()
        let target = try Target.resolve(global)
        let was = target.isLinked
        if !was {
            do { try Link.open(target.device.address) }
            catch { throw Failure("\(error)") }
        }
        Output.emit(.object([("device", .string(target.label)), ("connected", .bool(true)), ("changed", .bool(!was))])) {
            was ? "\(target.label): already connected" : "\(target.label): connected"
        }
    }
}

struct Disconnect: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Drop this Mac's link only; the headphones stay paired and keep their other hosts."
    )

    @OptionGroup var global: GlobalOptions

    func run() throws
    {
        global.apply()
        let target = try Target.resolve(global)
        let was = target.isLinked
        if was {
            do { try Link.close(target.device.address) }
            catch { throw Failure("\(error)") }
        }
        Output.emit(.object([("device", .string(target.label)), ("connected", .bool(false)), ("changed", .bool(was))])) {
            was ? "\(target.label): disconnected" : "\(target.label): already disconnected"
        }
    }
}
