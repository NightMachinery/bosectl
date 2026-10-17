@testable import BMAP
import XCTest

/// Answers requests from a script and records what was sent.
final class FakeDevice: Requester {
    var replies: [Address: [Packet]] = [:]
    var sent: [Packet] = []
    /// Answer every SETGET with its own payload, as a device that applies it.
    var echoWrites = false

    func request(_ packet: Packet, accept: Set<Address>, collect: Collect, timeout: TimeInterval) throws -> [Packet]
    {
        sent.append(packet)
        if echoWrites, packet.op == .setGet {
            return [Packet(packet.address, .status, packet.payload)]
        }
        var collector = AnswerCollector(request: packet, accept: accept, collect: collect)
        for reply in replies[packet.address] ?? [] {
            _ = try collector.feed(reply)
            if collector.done { break }
        }
        return collector.answers
    }

    func reply(_ address: Address, _ op: Operator = .status, _ payload: [UInt8])
    {
        replies[address, default: []].append(Packet(address, op, payload))
    }
}

/// Answers each request with the next operator in `answers`, an ERROR being
/// "invalid data". FakeDevice gives every request to an address the same
/// replies; media actions need a different answer per request.
final class ScriptedMedia: Requester {
    var answers: [Operator]
    var sent: [Packet] = []

    init(answers: [Operator])
    {
        self.answers = answers
    }

    func request(_ packet: Packet, accept: Set<Address>, collect: Collect, timeout: TimeInterval) throws -> [Packet]
    {
        sent.append(packet)
        let op = answers.removeFirst()
        let payload = op == .error ? [DeviceErrorCode.invalidData.rawValue] : []
        var collector = AnswerCollector(request: packet, accept: accept, collect: collect)
        _ = try collector.feed(Packet(packet.address, op, payload))
        return collector.answers
    }
}

/// A 48-byte mode record as the headphones list it.
func modeRecord(
    index: UInt8, name: String, editable: Bool, cnc: UInt8 = 0, wind: Bool = false, anc: Bool = true, favorite: Bool = false
) -> [UInt8]
{
    var p = [UInt8](repeating: 0, count: 48)
    p[0] = index
    p[3] = editable ? 1 : 0
    p[5] = favorite ? 1 : 0
    p.replaceSubrange(6 ..< 38, with: fixedField(name, size: 32))
    p[41] = editable ? 0x1d : 0x00 // what the QC Ultra 2 reports
    p[42] = cnc
    p[45] = editable ? 1 : 0 // mirrors the editable flag; not wind block
    p[46] = wind ? 1 : 0
    p[47] = anc ? 1 : 0
    return p
}

final class HeadphonesTests: XCTestCase {
    func testListsModesFromTheRecordsThatFollowStart()
    {
        let fake = FakeDevice()
        fake.reply(Function.modeConfig, .status, modeRecord(index: 1, name: "Aware", editable: false, cnc: 10))
        fake.reply(Function.modeConfig, .status, modeRecord(index: 0, name: "Quiet", editable: false))
        fake.reply(Function.modeConfig, .status, modeRecord(index: 4, name: "Commute", editable: true, cnc: 3, wind: true))
        fake.reply(Function.modeConfig, .status, modeRecord(index: 5, name: "None", editable: true))
        // The listing is answered on 31.6; the RESULT on 31.1 ends it.
        fake.replies[Function.allModes] = fake.replies[Function.modeConfig]! + [Packet(Function.allModes, .result)]

        let modes = try! Headphones(fake).modes()
        XCTAssertEqual(modes.map(\.index), [0, 1, 4, 5])
        XCTAssertEqual(fake.sent, [Packet(Function.allModes, .start)])
        XCTAssertEqual(modes[2].name, "Commute")
        XCTAssertEqual(modes[2].cncLevel, 3)
        XCTAssertTrue(modes[2].windBlock)
        XCTAssertFalse(modes[2].isEmpty)
        XCTAssertTrue(modes[3].isEmpty)
        XCTAssertFalse(modes[0].editable)
    }

    func testWindBlockIsByte46NotTheEditableCopyAt45()
    {
        let mode = try! ModeConfig.parse(modeRecord(index: 4, name: "None", editable: true, wind: false))
        XCTAssertTrue(mode.editable)
        XCTAssertFalse(mode.windBlock)
    }

    func testParsesARecordCapturedFromTheHeadphones()
    {
        // Aware, as a QC Ultra 2 on firmware 10.12.12 lists it.
        let aware = try! ModeConfig.parse(Hex.decode(
            "0100020000014177617265000000000000000000000000000000000000000000000000000000000000020a0100000001"
        )!)
        XCTAssertEqual(aware.index, 1)
        XCTAssertEqual(aware.name, "Aware")
        XCTAssertFalse(aware.editable)
        XCTAssertTrue(aware.favorite)
        XCTAssertEqual(aware.cncLevel, 10)
        XCTAssertFalse(aware.levelEditable)
        let empty = try! ModeConfig.parse(Hex.decode(
            "0400000100004e6f6e65000000000000000000000000000000000000000000000000000000000000001d0a0000010001"
        )!)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(empty.levelEditable)
        XCTAssertTrue(empty.spatialEditable)
        XCTAssertFalse(empty.windBlock)
        XCTAssertEqual(empty.settings, ModeConfig.empty(index: 4).settings)
    }

    func testModeRecordRoundTripsThroughTheWriteLayout()
    {
        let mode = ModeConfig(
            index: 6, prompt: [0, 13], editable: true, favorite: false, name: "Focus",
            cncLevel: 2, autoCNC: true, spatial: Spatial.head.rawValue, windBlock: true, ancEnabled: false,
            mutability: nil
        )
        let payload = mode.build()
        XCTAssertEqual(payload.count, 40)
        XCTAssertEqual(try ModeConfig.parse(payload), mode)
    }

    func testLongNamesAreCutAtACharacterBoundary()
    {
        let field = fixedField(String(repeating: "é", count: 20), size: 32)
        XCTAssertEqual(field.count, 32)
        XCTAssertEqual(field[31], 0)
        XCTAssertEqual(fixedString(field), String(repeating: "é", count: 15))
    }

    func testMultipointIsBitZeroAndKeepsTheOtherBits()
    {
        let fake = FakeDevice()
        fake.reply(Function.multipoint, .status, [0x06])
        fake.echoWrites = true
        let hp = Headphones(fake)
        XCTAssertFalse(try hp.multipoint())
        try! hp.setMultipoint(true)
        XCTAssertEqual(fake.sent.last, Packet(Function.multipoint, .setGet, [0x07]))
    }

    func testBatteryWithoutAReadingIsNil()
    {
        XCTAssertEqual(Battery.parse([0x28]).percent, 40)
        XCTAssertNil(Battery.parse([0xff]).percent)
        XCTAssertNil(Battery.parse([]).percent)
    }

    func testChargingComesFromTheChargerFunction()
    {
        // Captured on the cable and off it: the battery reply is the same.
        let charging = FakeDevice()
        charging.reply(Function.battery, .status, [0x14, 0xff, 0xff, 0x00])
        charging.reply(Function.charger, .status, [0x01])
        XCTAssertEqual(try Headphones(charging).battery().charging, .yes)

        let unplugged = FakeDevice()
        unplugged.reply(Function.battery, .status, [0x14, 0xff, 0xff, 0x00])
        unplugged.reply(Function.charger, .status, [0x00])
        XCTAssertEqual(try Headphones(unplugged).battery().charging, .no)

        var full = Battery.parse([0x64, 0xff, 0xff, 0x00])
        full.charger = true
        XCTAssertEqual(full.charging, .complete)

        // A model without 2.5 still reports its level.
        let older = FakeDevice()
        older.reply(Function.battery, .status, [0x28])
        older.reply(Function.charger, .error, [0x04])
        let battery = try? Headphones(older).battery()
        XCTAssertEqual(battery?.percent, 40)
        XCTAssertEqual(battery?.charging, .unknown)
    }

    func testErrorRepliesThrow()
    {
        let fake = FakeDevice()
        fake.reply(Function.modeConfig, .error, [0x08])
        XCTAssertThrowsError(try Headphones(fake).writeMode(.empty(index: 0))) { error in
            XCTAssertEqual((error as? DeviceError)?.code, 8)
        }
    }

    func testMediaWithNothingPlayingIsNotAnError()
    {
        let fake = FakeDevice()
        fake.reply(Function.media, .error, [0x06])
        XCTAssertEqual(try Headphones(fake).media(.pause), false)

        let busy = FakeDevice()
        busy.reply(Function.media, .error, [0x05])
        XCTAssertThrowsError(try Headphones(busy).media(.pause))

        let playing = FakeDevice()
        playing.reply(Function.media, .result, [])
        XCTAssertEqual(try Headphones(playing).media(.pause), true)
        XCTAssertEqual(playing.sent.first?.payload, [0x02])
    }

    func testPairingModeOnAndOff()
    {
        // Captured: entering answers PROCESSING, then RESULT [state, 1].
        let entering = FakeDevice()
        entering.reply(Function.pairingMode, .processing, [])
        entering.reply(Function.pairingMode, .result, [0x01, 0x01])
        XCTAssertNoThrow(try Headphones(entering).setPairingMode(true))
        XCTAssertEqual(entering.sent, [Packet(Function.pairingMode, .start, [0x01])])

        let leaving = FakeDevice()
        leaving.reply(Function.pairingMode, .result, [0x00, 0x01])
        XCTAssertNoThrow(try Headphones(leaving).setPairingMode(false))
        XCTAssertEqual(leaving.sent.first?.payload, [0x00])

        let stuck = FakeDevice()
        stuck.reply(Function.pairingMode, .result, [0x01, 0x01])
        XCTAssertThrowsError(try Headphones(stuck).setPairingMode(false))
    }

    func testToggleMediaPausesFirstAndPlaysOnlyIfNothingWasPlaying()
    {
        let playing = FakeDevice()
        playing.reply(Function.media, .result, [])
        XCTAssertEqual(try Headphones(playing).toggleMedia(), .pause)
        XCTAssertEqual(playing.sent.map(\.payload), [[0x02]])

        // The pause finds nothing playing; the play that follows succeeds.
        let paused = ScriptedMedia(answers: [.error, .result])
        XCTAssertEqual(try Headphones(paused).toggleMedia(), .play)
        XCTAssertEqual(paused.sent.map(\.payload), [[0x02], [0x01]])

        let idle = ScriptedMedia(answers: [.error, .error])
        XCTAssertNil(try Headphones(idle).toggleMedia())
    }

    func testSettingsPayloads()
    {
        XCTAssertEqual(EQBand.build(.treble, -2), [0xfe, 2])
        XCTAssertEqual(EQBand.parseAll([0xf6, 0x0a, 0xfd, 0, 0xf6, 0x0a, 0x00, 1]).map(\.value), [-3, 0])
        let prompts = try! VoicePrompts.parse(Hex.decode("41000081020001")!)
        XCTAssertEqual(prompts.languageName, "US English")
        XCTAssertFalse(prompts.announceConnections)
        XCTAssertEqual(prompts.announceBattery, true)
        XCTAssertTrue(prompts.defaultLanguage)
        XCTAssertEqual(prompts.build(), [0x01, 0x01])
        XCTAssertEqual(try Sidetone.parse([1, 2]), .medium)
        XCTAssertEqual(try Sidetone.parse([1, 3, 0x0f]), .low)
        XCTAssertEqual(Sidetone.low.build(), [1, 3])
        let source = try! AudioSource.parse([0, 0x0f, 1, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])
        XCTAssertEqual(source.addresses, ["aa:bb:cc:dd:ee:ff"])
        XCTAssertEqual(source.kindName, "bluetooth")
        XCTAssertEqual(try AudioSource.parse([0, 0x0f, 0]).kindName, "none")
        // The shortcut button of a QC Ultra 2, set to the voice assistant.
        let buttons = try! ButtonMapping.parse(Hex.decode("8009010009400200000000")!)
        XCTAssertEqual(buttons.action, 1)
        XCTAssertEqual(buttons.supported, [1, 14, 16, 19])
        XCTAssertEqual(try ButtonMapping.parse([0x80, 0x09, 0x0e]).supported, [])
    }

    func testIgnoredWritesAreReported()
    {
        let fake = FakeDevice()
        fake.reply(Function.voicePrompts, .status, Hex.decode("41000081020000")!)
        let hp = Headphones(fake)
        var prompts = try! hp.voicePrompts()
        prompts.announceConnections = true
        XCTAssertThrowsError(try hp.setVoicePrompts(prompts)) { XCTAssertTrue($0 is NotApplied) }
    }

    func testFavoritesMaskIsByteReversed()
    {
        let three = try! Favorites.parse([0x0b, 0x00, 0x07])
        XCTAssertEqual(three.indices, [0, 1, 2])
        XCTAssertEqual(three.build(), [0x0b, 0x00, 0x07])
        let wide = try! Favorites.parse([0x0b, 0x04, 0x01])
        XCTAssertEqual(wide.indices, [0, 10])
        XCTAssertEqual(wide.build(), [0x0b, 0x04, 0x01])
    }

    func testHostPayloads()
    {
        let info = try! HostInfo.parse([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x03, 0x01, 0x03] + Array("Laptop".utf8))
        XCTAssertEqual(info.address, "aa:bb:cc:dd:ee:ff")
        XCTAssertTrue(info.connected)
        XCTAssertEqual(info.name, "Laptop")
        XCTAssertFalse(try HostInfo.parse([1, 2, 3, 4, 5, 6, 0x00, 0x02, 0x03]).connected)
        XCTAssertEqual(
            try parseHostList([0x03, 1, 2, 3, 4, 5, 6, 0xa, 0xb, 0xc, 0xd, 0xe, 0xf]),
            ["01:02:03:04:05:06", "0a:0b:0c:0d:0e:0f"]
        )
        XCTAssertEqual(try Volume.parse([0x1f, 0x0b]), Volume(level: 11, max: 31))
        XCTAssertEqual(try ProductID.parse([0x40, 0x82, 0x04]), ProductID(id: 0x4082, variant: 4))
    }

    func testAcknowledgedRequestsEndOnProcessing()
    {
        let fake = FakeDevice()
        fake.reply(Function.connectHost, .processing, [])
        try! Headphones(fake).connectHost("aa:bb:cc:dd:ee:ff")
        XCTAssertEqual(fake.sent, [Packet(Function.connectHost, .start, [0, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])])
    }
}
