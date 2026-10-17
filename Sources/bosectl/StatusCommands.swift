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
                ("battery", battery?.json ?? .null),
                ("mode", .optional(modeName)),
                ("mode_index", .optional(modeIndex.map(Int.init))),
                ("noise", audio?.json ?? .null),
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
        Output.emit(battery.json) { battery.text }
    }
}

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Model, name, address and firmware."
    )

    @OptionGroup var global: GlobalOptions

    func run() throws
    {
        global.apply()
        let (target, name, firmware) = try withHeadphones(global) { hp, target in
            (target, try? hp.name(), try hp.firmwareVersion())
        }
        let model = target.device.productID.flatMap(Catalog.lookup)
        Output.emit(.object([
            ("model", .optional(model?.name)),
            ("codename", .optional(model?.codename)),
            ("product_id", target.device.productID.map { .string(String(format: "0x%04x", $0)) } ?? .null),
            ("name", .optional(name)),
            ("address", .string(target.device.address)),
            ("firmware", .string(firmware)),
        ])) {
            keyValueLines([
                ("model", model?.name ?? "unknown"),
                ("product id", target.device.productID.map { String(format: "0x%04x", $0) } ?? "unknown"),
                ("name", name ?? "unknown"),
                ("address", target.device.address),
                ("firmware", firmware),
            ])
        }
    }
}
