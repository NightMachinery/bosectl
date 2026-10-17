// Protocol probing: send any packet and show what comes back.

import ArgumentParser
import BMAP
import BMAPBluetooth
import Foundation

struct Raw: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Send a raw BMAP packet and print every packet received.",
        discussion: """
        Either give a whole packet in hex ('01 05 01 00'), or an address and an
        operator with an optional hex payload ('1.5 get', '31.3 start 02').
        Packets for other functions that arrive meanwhile are printed too.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Hex packet, or ADDRESS OPERATOR [PAYLOAD].")
    var words: [String]

    @Option(name: .long, help: ArgumentHelp("Keep listening this many seconds after sending.", valueName: "seconds"))
    var listen: Double = 1

    func run() throws
    {
        global.apply()
        let packet = try parsePacket()
        let frames: [(Bool, Packet)] = try withChannel(global) { session, _ in
            var log: [(Bool, Packet)] = []
            let previous = session.onTraffic
            session.onTraffic = { outgoing, p in
                log.append((outgoing, p))
                previous?(outgoing, p)
            }
            try session.send(packet)
            _ = session.listen(for: listen)
            return log
        }
        Output.emit(.object([("frames", .array(frames.map { outgoing, p in
            .object([
                ("dir", .string(outgoing ? "tx" : "rx")),
                ("address", .string(p.address.description)),
                ("op", .string(p.op.name)),
                ("payload", .string(Hex.encode(p.payload))),
                ("hex", .string(Hex.encode(p.encoded()))),
            ])
        }))])) {
            frames.map { outgoing, p in (outgoing ? "-> " : "<- ") + p.description }.joined(separator: "\n")
        }
    }

    func parsePacket() throws -> Packet
    {
        // Accept '31.3 start 02' as one quoted argument too.
        let words = self.words.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        if let first = words.first, let address = Address(parsing: first) {
            guard words.count >= 2, let op = Operator.named(words[1]) else {
                throw Failure.usage("expected an operator after \(first): get, set, setget, start, ...")
            }
            guard let payload = Hex.decode(words.dropFirst(2).joined()) else {
                throw Failure.usage("payload is not valid hex")
            }
            return Packet(address, op, payload)
        }
        guard let bytes = Hex.decode(words.joined()) else {
            throw Failure.usage("not valid hex: \(words.joined(separator: " "))")
        }
        var reader = PacketReader()
        reader.append(bytes)
        guard let packet = reader.next(), reader.pendingBytes == 0 else {
            throw Failure.usage("not exactly one BMAP packet: \(Hex.encode(bytes, separator: " "))")
        }
        return packet
    }
}

extension Operator {
    static func named(_ name: String) -> Operator?
    {
        allCases.first { $0.name.lowercased() == name.lowercased() }
    }
}
