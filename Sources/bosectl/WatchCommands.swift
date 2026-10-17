// Event streams and protocol dumps.

import ArgumentParser
import BMAP
import BMAPBluetooth
import Foundation

struct Watch: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the headphones' notifications as they happen, one JSON object per line.",
        discussion: """
        The headphones report changes made elsewhere (the buttons, the Bose app,
        another host) on the open channel. This keeps the channel open and
        prints each report, decoded where the layout is known. It holds the
        control channel for as long as it runs.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Option(help: ArgumentHelp("Stop after this many seconds (default: run until interrupted).", valueName: "seconds"))
    var duration: Double?

    func run() throws
    {
        global.apply()
        try withSession(global) { session, _ in
            let previous = session.onTraffic
            session.onTraffic = { outgoing, packet in
                previous?(outgoing, packet)
                guard !outgoing else { return }
                print(eventJSON(packet).serialized())
                fflush(stdout)
            }
            let end = duration.map { Date().addingTimeInterval($0) } ?? .distantFuture
            while Date() < end {
                _ = session.listen(for: min(1, end.timeIntervalSinceNow))
                if session.isClosed {
                    throw Failure("the headphones closed the channel")
                }
            }
        }
    }
}

/// A received packet as JSON, with a decoded `value` where the layout is known.
func eventJSON(_ packet: Packet) -> JSON
{
    var fields: [(String, JSON)] = [
        ("time", .string(ISO8601DateFormatter().string(from: Date()))),
        ("address", .string(packet.address.description)),
        ("op", .string(packet.op.name)),
    ]
    if let (name, value) = decode(packet) {
        fields.append(("event", .string(name)))
        fields.append(("value", value))
    }
    fields.append(("payload", .string(Hex.encode(packet.payload))))
    return .object(fields)
}

private func decode(_ packet: Packet) -> (String, JSON)?
{
    guard packet.op == .status else { return nil }
    let p = packet.payload
    switch packet.address {
    case Function.battery:
        return ("battery", Battery.parse(p).json)
    case Function.currentMode:
        guard let index = p.first else { return nil }
        if index == Presets.noMode { return ("mode", .object([("index", .null), ("preset", .null)])) }
        return ("mode", .object([("index", .int(Int(index))), ("preset", .optional(Presets.name(of: index)))]))
    case Function.audioSettings:
        return (try? AudioSettings.parse(p)).map { ("noise", $0.json) }
    case Function.modeConfig:
        return (try? ModeConfig.parse(p)).map { ("mode_config", $0.json) }
    case Function.eq:
        return ("eq", .array(EQBand.parseAll(p).map(\.json)))
    case Function.source:
        return (try? AudioSource.parse(p)).map { ("source", .object([("source", .string($0.kindName)), ("address", .optional($0.address))])) }
    case Function.multipoint:
        return p.first.map { ("multipoint", .bool($0 & 0x01 != 0)) }
    case Function.autoPause:
        return p.first.map { ("auto_pause", .bool($0 != 0)) }
    case Function.autoAnswer:
        return p.first.map { ("auto_answer", .bool($0 != 0)) }
    case Function.sidetone:
        return (try? Sidetone.parse(p)).map { ("sidetone", .string($0.name)) }
    case Function.voicePrompts:
        return (try? VoicePrompts.parse(p)).map { ("voice_prompts", $0.json) }
    default:
        return nil
    }
}

struct Dump: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "GET every known function and print the raw replies (for protocol work).",
        discussion: "With --block N, GET functions 0 to 63 of that block instead, to find unmapped ones. GET only reads."
    )

    @OptionGroup var global: GlobalOptions

    @Option(help: "Probe every function of this block.")
    var block: UInt8?

    static let known: [(String, Address)] = [
        ("bmap version", Function.bmapVersion), ("firmware", Function.firmwareVersion),
        ("serial", Function.serialNumber), ("name", Function.productName),
        ("voice prompts", Function.voicePrompts), ("cnc", Function.cnc), ("eq", Function.eq),
        ("buttons", Function.buttons), ("multipoint", Function.multipoint),
        ("sidetone", Function.sidetone), ("auto pause", Function.autoPause),
        ("auto answer", Function.autoAnswer), ("battery", Function.battery),
        ("source", Function.source), ("current mode", Function.currentMode),
        ("favorites", Function.favorites),
        ("audio settings", Function.audioSettings),
    ]

    func run() throws
    {
        global.apply()
        let targets: [(String, Address)] = block.map { b in (0 ..< 64).map { ("", Address(b, UInt8($0))) } } ?? Dump.known
        let rows = try withHeadphones(global) { hp, _ -> [(String, Address, String, String)] in
            // Unmapped functions often never answer; don't wait 3 s on each.
            if block != nil { hp.timeout = min(hp.timeout, 1) }
            return targets.map { label, address in
                do {
                    let payload = try hp.get(address)
                    return (label, address, "ok", Hex.encode(payload, separator: " "))
                } catch let error as DeviceError {
                    return (label, address, "error", DeviceErrorCode.describe(error.code))
                } catch {
                    return (label, address, "error", "\(error)")
                }
            }
        }
        // A block probe only lists what answered.
        let shown = block == nil ? rows : rows.filter { $0.2 == "ok" }
        Output.emit(.array(shown.map { label, address, status, data in
            .object([
                ("name", label.isEmpty ? .null : .string(label)),
                ("address", .string(address.description)),
                ("status", .string(status)),
                (status == "ok" ? "payload" : "error", .string(data)),
            ])
        })) {
            shown.map { label, address, status, data in
                let head = "\(address)".padding(toLength: 6, withPad: " ", startingAt: 0)
                let name = label.padding(toLength: 15, withPad: " ", startingAt: 0)
                return "\(head) \(name) \(status == "ok" ? data : "(\(data))")"
            }.joined(separator: "\n")
        }
    }
}
