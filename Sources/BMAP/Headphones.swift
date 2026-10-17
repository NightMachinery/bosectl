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

    /// Throws `NotApplied` unless the echo of a write shows the new value:
    /// some firmware acknowledges writes it then ignores.
    func confirm(_ applied: Bool, _ address: Address) throws
    {
        if !applied { throw NotApplied(address: address) }
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
        try string(Function.firmwareVersion)
    }

    /// An ASCII or UTF-8 reply as a string.
    public func string(_ address: Address) throws -> String
    {
        fixedString(try get(address)[...])
    }

    public func productID() throws -> ProductID
    {
        try ProductID.parse(get(Function.productID))
    }

    /// The Bluetooth name. The reply starts with one flags byte.
    public func name() throws -> String
    {
        fixedString(try get(Function.productName).dropFirst())
    }

    public static let maxNameBytes = 30

    public func setName(_ name: String) throws
    {
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, bytes.count <= Headphones.maxNameBytes else {
            throw UsageError("a name must be 1 to \(Headphones.maxNameBytes) bytes of UTF-8")
        }
        let echo = try setGet(Function.productName, bytes)
        try confirm(fixedString(echo.dropFirst()) == name, Function.productName)
    }

    // MARK: Battery

    /// The level and, where the model reports it, whether it is charging.
    public func battery() throws -> Battery
    {
        var battery = Battery.parse(try get(Function.battery))
        // A model without 2.5 still has a level to report.
        battery.charger = try? charger()
        return battery
    }

    /// Whether a charging cable is connected.
    public func charger() throws -> Bool
    {
        let p = try get(Function.charger)
        try require(p, 1, Function.charger)
        return p[0] != 0
    }

    // MARK: Settings block

    public func voicePrompts() throws -> VoicePrompts
    {
        try VoicePrompts.parse(get(Function.voicePrompts))
    }

    /// Firmware 10.12.12 acknowledges these writes without applying them, so
    /// this throws `NotApplied` there.
    @discardableResult
    public func setVoicePrompts(_ prompts: VoicePrompts) throws -> VoicePrompts
    {
        let echoed = try VoicePrompts.parse(setGet(Function.voicePrompts, prompts.build()))
        try confirm(echoed.writable == prompts.writable, Function.voicePrompts)
        return echoed
    }

    public func eq() throws -> [EQBand]
    {
        EQBand.parseAll(try get(Function.eq))
    }

    public func setEQ(_ band: EQBand.ID, _ value: Int) throws
    {
        guard (-10 ... 10).contains(value) else { throw UsageError("EQ values range from -10 to 10") }
        let echo = EQBand.parseAll(try setGet(Function.eq, EQBand.build(band, value)))
        try confirm(echo.first { $0.id == band.rawValue }?.value == value, Function.eq)
    }

    public func buttons() throws -> ButtonMapping
    {
        try ButtonMapping.parse(get(Function.buttons))
    }

    public func setButton(_ mapping: ButtonMapping) throws
    {
        let echo = try ButtonMapping.parse(setGet(Function.buttons, mapping.build()))
        try confirm(echo.action == mapping.action, Function.buttons)
    }

    /// Bit 0 of the reply; the other bits are fixed capability flags (on
    /// reads 0x07, off 0x06).
    public func multipoint() throws -> Bool
    {
        let p = try get(Function.multipoint)
        try require(p, 1, Function.multipoint)
        return p[0] & 0x01 != 0
    }

    /// Flips bit 0 and writes the capability bits back unchanged.
    public func setMultipoint(_ on: Bool) throws
    {
        let p = try get(Function.multipoint)
        try require(p, 1, Function.multipoint)
        let echo = try setGet(Function.multipoint, [on ? p[0] | 0x01 : p[0] & ~0x01])
        try confirm(echo.first.map { $0 & 0x01 != 0 } == on, Function.multipoint)
    }

    public func sidetone() throws -> Sidetone
    {
        try Sidetone.parse(get(Function.sidetone))
    }

    public func setSidetone(_ level: Sidetone) throws
    {
        try confirm(Sidetone.parse(setGet(Function.sidetone, level.build())) == level, Function.sidetone)
    }

    public func flag(_ address: Address) throws -> Bool
    {
        let p = try get(address)
        try require(p, 1, address)
        return p[0] != 0
    }

    public func setFlag(_ address: Address, _ on: Bool) throws
    {
        let echo = try setGet(address, [on ? 1 : 0])
        try confirm(echo.first.map { $0 != 0 } == on, address)
    }

    // MARK: Audio modes

    /// The active mode's index, or nil when no mode is active (the reply is
    /// 0xFF), which leaves noise cancellation off.
    public func currentModeIndex() throws -> UInt8?
    {
        let p = try get(Function.currentMode)
        try require(p, 1, Function.currentMode)
        return p[0] == Presets.noMode ? nil : p[0]
    }

    /// Every mode slot, presets and custom, in index order. START 31.1 makes
    /// the headphones report all of block 31, one 31.6 record per slot.
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

    /// One mode slot.
    public func mode(at index: UInt8) throws -> ModeConfig
    {
        try ModeConfig.parse(get(Function.modeConfig, [index]))
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
        let echo = try ModeConfig.parse(setGet(Function.modeConfig, mode.build()))
        try confirm(echo.build() == mode.build(), Function.modeConfig)
        return echo
    }

    /// Changes the noise settings of the active mode by rewriting its record.
    /// Only custom modes can change: the presets are fixed. Returns the record
    /// the headphones confirmed.
    @discardableResult
    public func updateActiveMode(_ change: (inout ModeConfig) -> Void) throws -> ModeConfig
    {
        guard let index = try currentModeIndex() else {
            throw UsageError("no mode is active; switch to one first (bosectl mode NAME)")
        }
        let before = try mode(at: index)
        var after = before
        change(&after)
        if after == before { return before }
        guard before.editable else {
            let name = Presets.name(of: index) ?? "mode \(index)"
            throw UsageError(
                "\(name) is a preset, and presets are fixed; make a custom mode instead "
                    + "(bosectl profile set NAME --cnc LEVEL --activate)"
            )
        }
        if after.cncLevel != before.cncLevel {
            guard before.levelEditable else { throw UsageError("this mode's noise level is fixed") }
        }
        if after.spatial != before.spatial, !before.spatialEditable {
            throw UsageError("this mode's spatial audio is fixed")
        }
        try validate(after)
        return try writeMode(after)
    }

    private func validate(_ mode: ModeConfig) throws
    {
        guard (0 ... 10).contains(mode.cncLevel) else { throw UsageError("the noise level must be 0 to 10") }
        guard !mode.name.isEmpty, Array(mode.name.utf8).count <= 31 else {
            throw UsageError("a mode name must be 1 to 31 bytes of UTF-8")
        }
    }

    public func audioSettings() throws -> AudioSettings
    {
        try AudioSettings.parse(get(Function.audioSettings))
    }

    public func favorites() throws -> Favorites
    {
        try Favorites.parse(get(Function.favorites))
    }

    @discardableResult
    public func setFavorites(_ favorites: Favorites) throws -> Favorites
    {
        let echo = try Favorites.parse(setGet(Function.favorites, favorites.build()))
        try confirm(echo.indices == favorites.indices, Function.favorites)
        return echo
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
            guard let empty = all.first(where: \.isEmpty) else {
                throw UsageError("every custom slot is taken; delete a custom mode first")
            }
            // A new mode starts from what Quiet does, keeping the slot's own
            // prompt bytes.
            mode = empty
            mode.name = wanted
            mode.cncLevel = 0
            mode.autoCNC = false
            mode.spatial = Spatial.off.rawValue
            mode.windBlock = false
            mode.ancEnabled = true
        }
        let previousName = mode.name
        change(&mode)
        if mode.name.lowercased() != previousName.lowercased() {
            try refusePresetName(mode.name, all)
            if all.contains(where: { $0.index != mode.index && !$0.isEmpty && $0.name.lowercased() == mode.name.lowercased() }) {
                throw UsageError("a mode named '\(mode.name)' already exists")
            }
        }
        try validate(mode)
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
        var empty = ModeConfig.empty(index: mode.index)
        empty.prompt = mode.prompt
        try writeMode(empty)
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

    // MARK: Audio

    public func volume() throws -> Volume
    {
        try Volume.parse(get(Function.volume))
    }

    @discardableResult
    public func setVolume(_ level: Int) throws -> Volume
    {
        let current = try volume()
        guard (0 ... current.max).contains(level) else {
            throw UsageError("the volume must be 0 to \(current.max)")
        }
        let echo = try Volume.parse(setGet(Function.volume, [UInt8(level)]))
        try confirm(echo.level == level, Function.volume)
        return echo
    }

    /// Asks the playing host to play, pause, skip and so on. Returns false
    /// when there was nothing to act on: the headphones answer "invalid data"
    /// to a pause with nothing playing, though the payload is a fixed byte.
    @discardableResult
    public func media(_ action: MediaAction) throws -> Bool
    {
        do {
            try start(Function.media, [action.rawValue])
            return true
        } catch let error as DeviceError where error.code == DeviceErrorCode.invalidData.rawValue {
            return false
        }
    }

    /// Pauses what is playing, or plays what is not. BMAP has neither a
    /// toggle nor a readable play state, so this pauses first and plays only
    /// if there was nothing to pause. Returns the action that took effect, or
    /// nil when neither did.
    public func toggleMedia() throws -> MediaAction?
    {
        if try media(.pause) { return .pause }
        return try media(.play) ? .play : nil
    }

    public func source() throws -> AudioSource
    {
        try AudioSource.parse(get(Function.source))
    }

    // MARK: Hosts

    /// The addresses of the hosts the headphones remember.
    public func hostAddresses() throws -> [String]
    {
        try parseHostList(get(Function.hosts))
    }

    public func hostInfo(_ address: String) throws -> HostInfo
    {
        guard let bytes = parseAddress(address) else { throw UsageError("'\(address)' is not a Bluetooth address") }
        return try HostInfo.parse(get(Function.hostInfo, bytes))
    }

    /// The address of the host asking (this Mac).
    public func ownAddress() throws -> String
    {
        let p = try get(Function.ownAddress)
        try require(p, 6, Function.ownAddress)
        return formatAddress(p.prefix(6))
    }

    /// Every remembered host, linked or not.
    public func hosts() throws -> [RememberedHost]
    {
        let me = try? ownAddress()
        let playing = Set((try? source())?.addresses ?? [])
        return try hostAddresses().map { address in
            let info = try? hostInfo(address)
            return RememberedHost(
                address: address, name: info?.name ?? "", connected: info?.connected ?? false,
                playing: playing.contains(address), isSelf: address == me
            )
        }
    }

    /// The hosts the headphones are playing from (usually one).
    public func playingFrom() throws -> [RememberedHost]
    {
        let me = try? ownAddress()
        return try source().addresses.map { address in
            let info = try? hostInfo(address)
            return RememberedHost(address: address, name: info?.name ?? "", connected: true, playing: true, isSelf: address == me)
        }
    }

    /// Asks the headphones to page a remembered host. They acknowledge at
    /// once and connect in the background, which can take 15 s for a host
    /// that is asleep, and never report the outcome.
    public func connectHost(_ address: String) throws
    {
        guard let bytes = parseAddress(address) else { throw UsageError("'\(address)' is not a Bluetooth address") }
        try start(Function.connectHost, [0x00] + bytes, collect: .acknowledged)
    }

    /// Drops the link to one host. The host stays paired.
    public func disconnectHost(_ address: String) throws
    {
        guard let bytes = parseAddress(address) else { throw UsageError("'\(address)' is not a Bluetooth address") }
        try start(Function.disconnectHost, bytes, collect: .acknowledged)
    }

    // MARK: Notifications

    /// Asks the headphones to report changes to these function blocks on
    /// this channel, as STATUS packets. They report nothing until asked.
    public func subscribe(blocks: [UInt8]) throws
    {
        let mask = blocks.reduce(UInt32(0)) { $0 | 1 << UInt32($1) }
        let bytes = (0 ..< 4).map { UInt8(truncatingIfNeeded: mask >> (8 * (3 - $0))) }
        try setGet(Function.notifyBlocks, [0x01] + bytes)
    }

    // MARK: Pairing and power

    /// Whether the headphones are discoverable for pairing.
    public func pairingMode() throws -> Bool
    {
        let p = try get(Function.pairingMode)
        try require(p, 1, Function.pairingMode)
        return p[0] != 0
    }

    /// Enters or leaves pairing mode. Entering it drops the second of two
    /// linked hosts, to make room. The RESULT is [state, 1].
    public func setPairingMode(_ on: Bool) throws
    {
        let answers = try start(Function.pairingMode, [on ? 0x01 : 0x00])
        if let state = answers.last(where: { $0.op == .result })?.payload.first {
            try confirm((state != 0) == on, Function.pairingMode)
        }
    }

    public func powerOff() throws
    {
        try start(Function.power, [0x00])
    }
}

/// The battery reply. The QC Ultra 2 sends its level in the first byte, and
/// nothing about charging; that comes from 2.5.
public struct Battery: Equatable, Sendable {
    /// nil when the headphones report no reading (0xFF).
    public var percent: Int?
    public var raw: [UInt8]
    /// Whether a charging cable is connected; nil when unread.
    public var charger: Bool? = nil

    public enum Charging: String, Sendable {
        case unknown, no, yes, complete
    }

    /// The cable says power is there, not that the cell is filling, so a
    /// full battery on the cable counts as complete.
    public var charging: Charging
    {
        guard let charger else { return .unknown }
        guard charger else { return .no }
        return percent == 100 ? .complete : .yes
    }

    public static func parse(_ payload: [UInt8]) -> Battery
    {
        guard let level = payload.first, level <= 100 else {
            return Battery(percent: nil, raw: payload)
        }
        return Battery(percent: Int(level), raw: payload)
    }
}

/// The headphones acknowledged a write but report the old value.
public struct NotApplied: Error, CustomStringConvertible {
    public var address: Address

    public var description: String
    {
        "the headphones accepted the write to \(address) but did not apply it (this firmware may not support the change)"
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
