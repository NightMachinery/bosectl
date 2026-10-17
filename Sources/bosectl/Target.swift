// Global options, picking the headphones, and opening a BMAP session.

import ArgumentParser
import BMAP
import BMAPBluetooth
import Foundation

struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: ArgumentHelp("Target the paired device with this address.", valueName: "aa:bb:cc:dd:ee:ff"))
    var mac: String?

    @Option(name: .long, help: ArgumentHelp("Target the first paired device whose name contains this text.", valueName: "substr"))
    var device: String?

    @Flag(name: .long, help: "Print one JSON value on stdout.")
    var json = false

    @Option(name: .long, help: "Gray diagnostics on stderr: auto, always or never.")
    var color: ColorMode = .auto

    @Flag(name: .long, help: "Connect the headphones first if this Mac is not linked to them.")
    var autoConnect = false

    @Flag(name: .long, help: "Log every BMAP packet to stderr.")
    var trace = false

    @Option(name: .long, help: ArgumentHelp("Seconds to wait for each reply.", valueName: "seconds"))
    var timeout: Double = 3

    /// Experimental: BMAP over Bluetooth LE instead of the Classic channel.
    @Flag(name: .long, help: .hidden)
    var le = false

    func apply()
    {
        Output.json = json
        Output.configureColor(color)
        // Before anything lists paired devices; see LinkState.
        LinkState.prime(mac.map { [$0] } ?? [])
    }
}

extension ColorMode: ExpressibleByArgument {}

/// The headphones a command acts on.
struct Target {
    var device: PairedDevice

    var label: String { device.name.isEmpty ? device.address : device.name }

    /// --mac wins, then --device, then the first Bose device (connected ones
    /// first). Fails with a usage error when nothing matches.
    static func resolve(_ options: GlobalOptions) throws -> Target
    {
        let paired = Discovery.pairedDevices()
        if let mac = options.mac {
            let address = Discovery.normalizeAddress(mac)
            guard let device = paired.first(where: { $0.address == address }) else {
                throw Failure.usage("no paired device has address \(address) (see 'bosectl devices')")
            }
            return Target(device: device)
        }
        if let filter = options.device {
            guard let device = paired.first(where: { $0.name.range(of: filter, options: .caseInsensitive) != nil }) else {
                throw Failure.usage("no paired device name contains '\(filter)' (see 'bosectl devices')")
            }
            return Target(device: device)
        }
        let bose = paired.filter(\.looksLikeBose)
        guard let device = bose.first(where: \.isConnected) ?? bose.first else {
            throw Failure.usage("no paired Bose device found (pair the headphones in System Settings, or pass --mac)")
        }
        return Target(device: device)
    }

    var isLinked: Bool { Link.isConnected(device.address) }
}

/// Opens a session to the target and runs `body`. Never brings the link up
/// on its own: without --auto-connect a disconnected target fails at once
/// with exit status 3.
func withSession<T>(_ options: GlobalOptions, _ body: (Session, Target) throws -> T) throws -> T
{
    let target = try Target.resolve(options)
    if !target.isLinked {
        guard options.autoConnect else {
            throw Failure(
                "\(target.label) is not connected (run 'bosectl connect', or pass --auto-connect)",
                status: Exit.notConnected
            )
        }
        Output.note("connecting \(target.label)...")
        try Link.open(target.device.address)
    }

    // The channel can be briefly unavailable right after the link comes up or
    // after another client lets go of it, so opening is retried.
    let attempts = 3
    var lastError: Error?
    for attempt in 1 ... attempts {
        do {
            let session = try Session(address: target.device.address, timeout: max(options.timeout, 5))
            defer { session.close() }
            if options.trace {
                session.onTraffic = { outgoing, packet in
                    Output.trace((outgoing ? "-> " : "<- ") + packet.description)
                }
            }
            return try body(session, target)
        } catch let error as BluetoothError {
            lastError = error
            switch error {
            case .channelOpenFailed, .timeout, .closedByPeer:
                if attempt < attempts {
                    Output.note("\(error); retrying (\(attempt)/\(attempts - 1))")
                    Thread.sleep(forTimeInterval: 0.5 * Double(attempt))
                    continue
                }
            default:
                break
            }
            if case .channelOpenFailed = error {
                // What it usually is in practice, and the error code says nothing.
                throw Failure(
                    "\(error); another client may hold it: a running 'bosectl watch', "
                        + "or a linked phone (close the Bose app or turn off the phone's Bluetooth)"
                )
            }
            throw Failure(error.description)
        } catch let error as DeviceError {
            throw Failure(error.description)
        }
    }
    throw Failure(lastError.map { "\($0)" } ?? "could not reach \(target.label)")
}
