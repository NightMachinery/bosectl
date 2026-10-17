// nearby: which Bose headphones are on and in range, without connecting.

import ArgumentParser
import BMAP
import BMAPBluetooth
import Foundation

struct NearbyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nearby",
        abstract: "List Bose headphones that are on and in range, from their Bluetooth LE advertisements.",
        discussion: """
            Nothing connects: this listens for the advertisements the headphones send while \
            they are on, whether or not they are linked to anything. Exit 0 if any were \
            heard, 3 if none.
            """
    )

    @OptionGroup var global: GlobalOptions

    @Option(help: ArgumentHelp("Seconds to listen.", valueName: "seconds"))
    var duration: Double = 3

    func run() throws
    {
        global.apply()
        let devices: [NearbyDevice]
        do { devices = try Nearby.scan(for: duration) }
        catch { throw Failure("\(error)") }
        guard !devices.isEmpty else {
            throw Failure("no Bose headphones heard nearby", status: Exit.notConnected)
        }
        Output.emit(.array(devices.map(\.json))) { devices.map(\.text).joined(separator: "\n") }
    }
}

extension NearbyDevice {
    var json: JSON
    {
        var fields: [(String, JSON)] = [
            ("id", .string(identifier.uuidString)),
            ("name", .optional(name)),
            ("rssi", rssi == 127 ? .null : .int(rssi)),
        ]
        if let ad = advertisement {
            fields += [
                ("model", .optional(ad.model?.name)),
                ("product_value", .int(ad.productValue)),
                ("variant", .int(Int(ad.variant))),
                ("color", .optional(ad.color)),
                ("charging", .bool(ad.charging)),
                ("pairing", .bool(ad.pairing)),
                ("flags", .string(Hex.encode([ad.flags]))),
            ]
        }
        fields.append(("data", .string(Hex.encode(data))))
        return .object(fields)
    }

    var text: String
    {
        guard let ad = advertisement else {
            return "Bose device, advertisement not understood: \(Hex.encode(data))"
        }
        var parts = [ad.model?.name ?? "Bose product \(ad.productValue)"]
        if let color = ad.color { parts.append(color) }
        if let name { parts.append("\"\(name)\"") }
        if rssi != 127 { parts.append("\(rssi) dBm") }
        let states = [(ad.charging, "charging"), (ad.pairing, "pairing")].filter(\.0).map(\.1)
        if !states.isEmpty { parts.append(states.joined(separator: ", ")) }
        return parts.joined(separator: "  ")
    }
}
