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

    @Flag(name: .long, help: "Use Bluetooth LE for the control channel, not the Classic one.")
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

/// Opens the control channel and runs `body`: the Classic RFCOMM channel, or
/// Bluetooth LE with --le or when another client holds the Classic one. Never
/// brings the link up on its own: without --auto-connect a disconnected target
/// fails at once with exit status 3, and LE is not tried.
func withChannel<T>(_ options: GlobalOptions, _ body: (any ControlChannel, Target) throws -> T) throws -> T
{
    do {
        if options.le { return try withLESession(options, body) }
        do {
            return try withSession(options) { try body($0, $1) }
        } catch let busy as ChannelBusy {
            // A refusal takes the stack about 5 s to report, so rather than
            // ask again at once, try LE (1 to 2 s), and the Classic channel
            // once more only if LE fails: the refusal is sometimes brief.
            Output.note("\(busy.error); trying Bluetooth LE")
            do {
                return try withLESession(options, body)
            } catch let unreachable as LEUnreachable {
                Output.note("Bluetooth LE did not work (\(unreachable.reason)); trying the Classic channel again")
                do {
                    return try withSession(options) { try body($0, $1) }
                } catch let again as ChannelBusy {
                    throw Failure(
                        "\(again.error), and Bluetooth LE did not work either; "
                            + "another client may hold the channel: a running 'bosectl watch', "
                            + "or a linked phone (close the Bose app or turn off the phone's Bluetooth)"
                    )
                }
            }
        }
    } catch let unreachable as LEUnreachable {
        throw Failure("over Bluetooth LE: \(unreachable.reason)")
    }
}

/// The Classic channel would not open, though the link is up. No request
/// was sent on it, so trying another way cannot repeat one.
private struct ChannelBusy: Error {
    var error: BluetoothError
}

/// Connecting over Bluetooth LE failed, before any request.
private struct LEUnreachable: Error {
    var reason: String
}

/// BMAP over Bluetooth LE. It needs no Classic link and never takes the Mac's
/// audio.
private func withLESession<T>(_ options: GlobalOptions, _ body: (any ControlChannel, Target) throws -> T) throws -> T
{
    let target = try Target.resolve(options)
    let session: LESession
    do {
        session = try LESession(
            name: target.device.name.isEmpty ? nil : target.device.name,
            onNote: options.trace ? { Output.trace("LE: " + $0) } : nil
        )
    } catch {
        throw LEUnreachable(reason: "\(error)")
    }
    defer { session.close() }
    if options.trace {
        session.onTraffic = { outgoing, packet in Output.trace((outgoing ? "-> " : "<- ") + packet.description) }
        session.onRaw = { Output.trace("LE raw: " + $0) }
    }
    do {
        return try body(session, target)
    } catch let error as BluetoothError {
        throw Failure("over Bluetooth LE: \(error)")
    } catch let error as LEError {
        throw Failure("over Bluetooth LE: \(error)")
    } catch let error as DeviceError {
        throw Failure(error.description)
    }
}

/// The Classic RFCOMM channel.
private func withSession<T>(_ options: GlobalOptions, _ body: (Session, Target) throws -> T) throws -> T
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

    // The channel can be briefly unavailable right after the link comes up,
    // so opening is retried. A refused open is left to withChannel.
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
            case .channelOpenFailed:
                throw ChannelBusy(error: error)
            case .timeout, .closedByPeer:
                if attempt < attempts {
                    Output.note("\(error); retrying (\(attempt)/\(attempts - 1))")
                    Thread.sleep(forTimeInterval: 0.5 * Double(attempt))
                    continue
                }
            default:
                break
            }
            throw Failure(error.description)
        } catch let error as DeviceError {
            throw Failure(error.description)
        }
    }
    throw Failure(lastError.map { "\($0)" } ?? "could not reach \(target.label)")
}
