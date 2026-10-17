// A typed API over one BMAP session.
//
// Reads use GET. Writes use SETGET (write, then echo the new value) or START
// (trigger an action): the headphones accept both without authentication on
// the settings and audio-mode blocks, while plain SET needs a key exchange
// with Bose's cloud and is never used here.

import Foundation

public final class Headphones {
    public let requester: Requester
    public var timeout: TimeInterval

    public init(_ requester: Requester, timeout: TimeInterval = 3)
    {
        self.requester = requester
        self.timeout = timeout
    }

    // MARK: Primitives

    /// The STATUS payload of a GET.
    public func get(_ address: Address, _ payload: [UInt8] = []) throws -> [UInt8]
    {
        try status(of: requester.request(Packet(address, .get, payload), accept: [], collect: .one, timeout: timeout), address)
    }

    /// Writes with SETGET and returns the echoed STATUS payload.
    @discardableResult
    public func setGet(_ address: Address, _ payload: [UInt8]) throws -> [UInt8]
    {
        try status(of: requester.request(Packet(address, .setGet, payload), accept: [], collect: .one, timeout: timeout), address)
    }

    /// Triggers an action with START.
    @discardableResult
    public func start(_ address: Address, _ payload: [UInt8] = [], accept: Set<Address> = [], collect: Collect = .one) throws -> [Packet]
    {
        try requester.request(Packet(address, .start, payload), accept: accept, collect: collect, timeout: timeout)
    }

    private func status(of answers: [Packet], _ address: Address) throws -> [UInt8]
    {
        guard let reply = answers.last(where: { $0.address == address }) else {
            throw ParseError.malformed(address, "no reply")
        }
        return reply.payload
    }

    // MARK: Product info

    public func firmwareVersion() throws -> String
    {
        String(decoding: try get(Function.firmwareVersion), as: UTF8.self)
    }

    /// The Bluetooth name. The reply starts with one flags byte.
    public func name() throws -> String
    {
        fixedString(try get(Function.productName).dropFirst())
    }

    public static let maxNameBytes = 31

    public func setName(_ name: String) throws
    {
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, bytes.count <= Headphones.maxNameBytes else {
            throw UsageError("a name must be 1 to \(Headphones.maxNameBytes) bytes of UTF-8")
        }
        try setGet(Function.productName, bytes)
    }

    // MARK: Battery

    public func battery() throws -> Battery
    {
        Battery.parse(try get(Function.battery))
    }

    // MARK: Settings block

    public func voicePrompts() throws -> VoicePrompts
    {
        try VoicePrompts.parse(get(Function.voicePrompts))
    }

    public func setVoicePrompts(_ prompts: VoicePrompts) throws
    {
        try setGet(Function.voicePrompts, prompts.build())
    }

    /// The active mode's noise level, 0 (most cancellation) to `max`.
    public func cnc() throws -> (level: Int, max: Int)
    {
        // [steps, current, ...]: steps counts the positions, so max = steps - 1.
        let p = try get(Function.cnc)
        try require(p, 2, Function.cnc)
        return (Int(p[1]), max(0, Int(p[0]) - 1))
    }

    public func eq() throws -> [EQBand]
    {
        EQBand.parseAll(try get(Function.eq))
    }

    public func setEQ(_ band: EQBand.ID, _ value: Int) throws
    {
        guard (-10 ... 10).contains(value) else { throw UsageError("EQ values range from -10 to 10") }
        try setGet(Function.eq, EQBand.build(band, value))
    }

    public func buttons() throws -> ButtonMapping
    {
        try ButtonMapping.parse(get(Function.buttons))
    }

    public func setButton(_ mapping: ButtonMapping) throws
    {
        try setGet(Function.buttons, mapping.build())
    }

    /// Bit 1 of the first byte.
    public func multipoint() throws -> Bool
    {
        let p = try get(Function.multipoint)
        try require(p, 1, Function.multipoint)
        return p[0] & 0x02 != 0
    }

    public func setMultipoint(_ on: Bool) throws
    {
        try setGet(Function.multipoint, [on ? 1 : 0])
    }

    public func sidetone() throws -> Sidetone
    {
        try Sidetone.parse(get(Function.sidetone))
    }

    public func setSidetone(_ level: Sidetone) throws
    {
        try setGet(Function.sidetone, level.build())
    }

    public func flag(_ address: Address) throws -> Bool
    {
        let p = try get(address)
        try require(p, 1, address)
        return p[0] != 0
    }

    public func setFlag(_ address: Address, _ on: Bool) throws
    {
        try setGet(address, [on ? 1 : 0])
    }

    // MARK: Audio modes

    public func currentModeIndex() throws -> UInt8
    {
        let p = try get(Function.currentMode)
        try require(p, 1, Function.currentMode)
        return p[0]
    }

    /// Every mode slot, presets and custom, in index order. START 31.1 makes
    /// the headphones send one 31.6 record per slot.
    public func modes() throws -> [ModeConfig]
    {
        let answers = try start(Function.allModes, accept: [Function.modeConfig], collect: .all(quiet: 0.4))
        var byIndex: [UInt8: ModeConfig] = [:]
        for packet in answers where packet.address == Function.modeConfig && packet.op == .status {
            if let mode = try? ModeConfig.parse(packet.payload) {
                byIndex[mode.index] = mode
            }
        }
        return byIndex.keys.sorted().compactMap { byIndex[$0] }
    }

    /// Switches mode. `announce` makes the headphones speak the mode's name.
    public func setMode(_ index: UInt8, announce: Bool = false) throws
    {
        try start(Function.currentMode, [index, announce ? 1 : 0])
    }

    /// Writes one mode slot and returns the record the headphones echo.
    @discardableResult
    public func writeMode(_ mode: ModeConfig) throws -> ModeConfig
    {
        try ModeConfig.parse(setGet(Function.modeConfig, mode.build()))
    }

    // MARK: Custom modes

    /// Creates the custom mode `name` in the first empty slot, or updates it
    /// if it exists; `change` edits the stored settings. Returns the record
    /// the headphones confirmed.
    @discardableResult
    public func saveCustomMode(_ name: String, change: (inout ModeConfig) -> Void) throws -> ModeConfig
    {
        let all = try modes()
        let wanted = name.trimmingCharacters(in: .whitespaces)
        var mode: ModeConfig
        if let existing = all.first(where: { $0.editable && !$0.isEmpty && $0.name.lowercased() == wanted.lowercased() }) {
            mode = existing
        } else {
            try refusePresetName(wanted, all)
            guard let slot = all.first(where: \.isEmpty)?.index
                ?? Presets.customSlots.first(where: { i in !all.contains { $0.index == i } })
            else {
                throw UsageError("all \(Presets.customSlots.count) custom slots are taken; delete a custom mode first")
            }
            // A new mode starts from what Quiet does.
            mode = ModeConfig(
                index: slot, prompt: [0, 0], editable: true, configured: true, name: wanted,
                cncLevel: 0, autoCNC: false, spatial: Spatial.off.rawValue, windBlock: false, ancEnabled: true
            )
        }
        let previousName = mode.name
        change(&mode)
        if mode.name.lowercased() != previousName.lowercased() {
            try refusePresetName(mode.name, all)
            if all.contains(where: { $0.index != mode.index && !$0.isEmpty && $0.name.lowercased() == mode.name.lowercased() }) {
                throw UsageError("a mode named '\(mode.name)' already exists")
            }
        }
        guard (0 ... 10).contains(mode.cncLevel) else { throw UsageError("the noise level must be 0 to 10") }
        guard !mode.name.isEmpty, Array(mode.name.utf8).count <= 31 else {
            throw UsageError("a mode name must be 1 to 31 bytes of UTF-8")
        }
        return try writeMode(mode)
    }

    /// Empties the custom mode's slot.
    public func deleteCustomMode(_ name: String) throws -> UInt8
    {
        let all = try modes()
        guard let mode = all.first(where: { $0.editable && !$0.isEmpty && $0.name.lowercased() == name.lowercased() }) else {
            if all.contains(where: { !$0.editable && $0.displayNameForMatching == name.lowercased() }) {
                throw UsageError("'\(name)' is a preset and cannot be deleted")
            }
            throw UsageError("no custom mode named '\(name)'")
        }
        try writeMode(.empty(index: mode.index))
        return mode.index
    }

    /// Switching resolves preset names first, so a custom mode named like a
    /// preset could never be selected by name.
    private func refusePresetName(_ name: String, _ all: [ModeConfig]) throws
    {
        let lowered = name.lowercased()
        if Presets.index(named: lowered) != nil || all.contains(where: { !$0.editable && $0.displayNameForMatching == lowered }) {
            throw UsageError("'\(name)' is a preset's name; choose another")
        }
    }

    public func audioSettings() throws -> AudioSettings
    {
        try AudioSettings.parse(get(Function.audioSettings))
    }

    /// Changes the live settings of the active mode, keeping the rest.
    @discardableResult
    public func updateAudioSettings(_ change: (inout AudioSettings) -> Void) throws -> AudioSettings
    {
        var settings = try audioSettings()
        change(&settings)
        return try AudioSettings.parse(setGet(Function.audioSettings, settings.build()))
    }

    // MARK: Connections and power

    public func source() throws -> AudioSource
    {
        try AudioSource.parse(get(Function.source))
    }

    /// Moves the audio to another host the headphones are connected to.
    public func route(to address: [UInt8]) throws
    {
        // 0x82: route "up" to the given host.
        try start(Function.routing, [0x82] + address)
    }

    public func enterPairingMode() throws
    {
        try start(Function.pairingMode, [0x01])
    }

    public func powerOff() throws
    {
        try start(Function.power, [0x00])
    }
}

/// The battery reply. The QC Ultra 2 sends its level in the first byte.
public struct Battery: Equatable, Sendable {
    /// nil when the headphones report no reading (0xFF).
    public var percent: Int?
    public var raw: [UInt8]

    public static func parse(_ payload: [UInt8]) -> Battery
    {
        guard let level = payload.first, level <= 100 else {
            return Battery(percent: nil, raw: payload)
        }
        return Battery(percent: Int(level), raw: payload)
    }
}

/// A request the headphones would reject anyway, caught before sending.
public struct UsageError: Error, CustomStringConvertible {
    public var description: String

    public init(_ description: String)
    {
        self.description = description
    }
}
