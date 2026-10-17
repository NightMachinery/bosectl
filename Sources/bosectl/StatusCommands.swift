// Read-only overviews: status, battery, info.

import ArgumentParser
import BMAP
import BMAPBluetooth
import Foundation

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show model, battery, mode and every setting, in one session."
    )

    @OptionGroup var global: GlobalOptions

    func run() throws
    {
        global.apply()
        try withHeadphones(global) { hp, target -> Void in
            // Each read stands alone: one the firmware rejects leaves its
            // field null instead of failing the whole report.
            let model = target.device.productID.flatMap(Catalog.lookup)?.name
            let name = try? hp.name()
            let firmware = try? hp.firmwareVersion()
            let battery = try? hp.battery()
            // A failed read and "no mode active" both leave the index nil;
            // only the second has a name.
            let modeRead = Result { try hp.currentModeIndex() }
            let modeIndex = (try? modeRead.get()) ?? nil
            let modeName = (try? modeRead.get()).map { hp.modeName(index: $0) }
            let audio = try? hp.audioSettings()
            let volume = try? hp.volume()
            let playing = try? hp.playingFrom()
            let eq = try? hp.eq()
            let multipoint = try? hp.multipoint()
            let sidetone = try? hp.sidetone()
            let autoPause = try? hp.flag(Function.autoPause)
            let autoAnswer = try? hp.flag(Function.autoAnswer)
            let prompts = try? hp.voicePrompts()

            let fields: [(String, JSON)] = [
                ("model", .optional(model)),
                ("name", .optional(name)),
                ("address", .string(target.device.address)),
                ("firmware", .optional(firmware)),
                ("batteries", .array(battery.map { [$0.partJSON] } ?? [])),
                ("mode", .optional(modeName)),
                ("mode_index", .optional(modeIndex.map(Int.init))),
                ("noise", audio?.json ?? .null),
                ("volume", volume?.json ?? .null),
                ("playing_from", playing.map { .array($0.map(\.json)) } ?? .null),
                ("eq", eq.map { .array($0.map(\.json)) } ?? .null),
                ("multipoint", .optional(multipoint)),
                ("sidetone", .optional(sidetone?.name)),
                ("auto_pause", .optional(autoPause)),
                ("auto_answer", .optional(autoAnswer)),
                ("voice_prompts", prompts?.json ?? .null),
            ]
            Output.emit(.object(fields)) {
                var rows: [(String, String)] = []
                rows.append(("model", model ?? "unknown"))
                if let name { rows.append(("name", name)) }
                if let firmware { rows.append(("firmware", firmware)) }
                rows.append(("battery", battery?.text ?? "NA"))
                if let modeName { rows.append(("mode", modeName == "none" ? "none (noise cancellation off)" : modeName)) }
                if let audio { rows.append(("noise", audio.text)) }
                if let volume { rows.append(("volume", volume.text)) }
                if let playing { rows.append(("playing from", playing.isEmpty ? "nothing" : playing.map(\.label).joined(separator: ", "))) }
                if let eq { rows.append(("eq", eq.map { "\($0.name) \(signed($0.value))" }.joined(separator: ", "))) }
                if let multipoint { rows.append(("multipoint", onOff(multipoint))) }
                if let sidetone { rows.append(("sidetone", sidetone.name)) }
                if let autoPause { rows.append(("auto pause", onOff(autoPause))) }
                if let autoAnswer { rows.append(("auto answer", onOff(autoAnswer))) }
                if let prompts { rows.append(("voice prompts", prompts.text)) }
                return keyValueLines(rows)
            }
        }
    }
}

struct BatteryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "battery",
        abstract: "Battery level, or NA when the headphones report none."
    )

    @OptionGroup var global: GlobalOptions

    func run() throws
    {
        global.apply()
        let battery = try withHeadphones(global) { hp, _ in try hp.battery() }
        Output.emit(battery.json) { "battery: \(battery.text)" }
    }
}

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Model, colour, name, address, firmware and serial number."
    )

    @OptionGroup var global: GlobalOptions

    func run() throws
    {
        global.apply()
        let info = try withHeadphones(global) { hp, target in
            (
                target: target,
                product: try? hp.productID(),
                modelName: try? hp.string(Function.modelName),
                codename: try? hp.string(Function.codename),
                platform: try? hp.string(Function.platform),
                name: try? hp.name(),
                firmware: try hp.firmwareVersion(),
                serial: try? hp.string(Function.serialNumber),
                bmap: try? hp.string(Function.bmapVersion)
            )
        }
        let productID = info.product?.id ?? info.target.device.productID
        let model = productID.flatMap(Catalog.lookup)
        let color = info.product.flatMap { p in model?.color(p.variant) }
        let hexID = productID.map { String(format: "0x%04x", $0) }
        Output.emit(.object([
            ("model", .optional(model?.name ?? info.modelName)),
            ("model_name", .optional(info.modelName)),
            ("codename", .optional(info.codename ?? model?.codename)),
            ("platform", .optional(info.platform)),
            ("product_id", .optional(hexID)),
            ("variant", .optional(info.product.map { Int($0.variant) })),
            ("color", .optional(color)),
            ("name", .optional(info.name)),
            ("address", .string(info.target.device.address)),
            ("firmware", .string(info.firmware)),
            ("serial", .optional(info.serial)),
            ("bmap_version", .optional(info.bmap)),
        ])) {
            var rows: [(String, String)] = [("model", model?.name ?? info.modelName ?? "unknown")]
            if let color { rows.append(("color", color)) }
            rows.append(("product id", [hexID, info.codename ?? model?.codename, info.platform].compactMap { $0 }.joined(separator: ", ")))
            rows.append(("name", info.name ?? "unknown"))
            rows.append(("address", info.target.device.address))
            rows.append(("firmware", info.firmware))
            if let serial = info.serial { rows.append(("serial", serial)) }
            if let bmap = info.bmap { rows.append(("bmap", bmap)) }
            return keyValueLines(rows)
        }
    }
}
