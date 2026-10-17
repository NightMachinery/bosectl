@testable import BMAP
import XCTest

/// Answers requests from a script and records what was sent.
final class FakeDevice: Requester {
    var replies: [Address: [Packet]] = [:]
    var sent: [Packet] = []

    func request(_ packet: Packet, accept: Set<Address>, collect: Collect, timeout: TimeInterval) throws -> [Packet]
    {
        sent.append(packet)
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

/// A 48-byte mode record as the headphones list it.
func modeRecord(index: UInt8, name: String, editable: Bool, cnc: UInt8 = 0, wind: Bool = false, anc: Bool = true) -> [UInt8]
{
    var p = [UInt8](repeating: 0, count: 48)
    p[0] = index
    p[3] = editable ? 1 : 0
    p[4] = 1
    p.replaceSubrange(6 ..< 38, with: fixedField(name, size: 32))
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

    func testModeRecordRoundTripsThroughTheWriteLayout()
    {
        let mode = ModeConfig(
            index: 6, prompt: [0, 13], editable: true, configured: true, name: "Focus",
            cncLevel: 2, autoCNC: true, spatial: Spatial.head.rawValue, windBlock: true, ancEnabled: false
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

    func testAudioSettingsUpdateKeepsTheOtherFields()
    {
        let fake = FakeDevice()
        fake.reply(Function.audioSettings, .status, [3, 0, 1, 1, 1])
        let hp = Headphones(fake)
        _ = try? hp.updateAudioSettings { $0.cncLevel = 7 }
        XCTAssertEqual(fake.sent.last, Packet(Function.audioSettings, .setGet, [7, 0, 1, 1, 1]))
    }

    func testBatteryWithoutAReadingIsNil()
    {
        XCTAssertEqual(Battery.parse([0x28]).percent, 40)
        XCTAssertNil(Battery.parse([0xff]).percent)
        XCTAssertNil(Battery.parse([]).percent)
    }

    func testErrorRepliesThrow()
    {
        let fake = FakeDevice()
        fake.reply(Function.modeConfig, .error, [0x08])
        XCTAssertThrowsError(try Headphones(fake).writeMode(.empty(index: 0))) { error in
            XCTAssertEqual((error as? DeviceError)?.code, 8)
        }
    }

    func testSettingsPayloads()
    {
        XCTAssertEqual(EQBand.build(.treble, -2), [0xfe, 2])
        XCTAssertEqual(EQBand.parseAll([0xf6, 0x0a, 0xfd, 0, 0xf6, 0x0a, 0x00, 1]).map(\.value), [-3, 0])
        XCTAssertEqual(try VoicePrompts.parse([0x21]), VoicePrompts(enabled: true, language: 1))
        XCTAssertEqual(VoicePrompts(enabled: false, language: 4).build(), [0x04])
        XCTAssertEqual(try Sidetone.parse([1, 2]), .medium)
        XCTAssertEqual(Sidetone.low.build(), [1, 3])
        let source = try! AudioSource.parse([0, 3, 1, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])
        XCTAssertEqual(source.address, "aa:bb:cc:dd:ee:ff")
        XCTAssertEqual(source.kindName, "bluetooth")
        let buttons = try! ButtonMapping.parse([0x80, 0x04, 0x02, 0b0000_0110, 0, 0x02, 0])
        XCTAssertEqual(buttons.supported, [1, 2, 17])
    }

    func testCNCReadsLevelAndRange()
    {
        let fake = FakeDevice()
        fake.reply(Function.cnc, .status, [11, 4, 1])
        let cnc = try! Headphones(fake).cnc()
        XCTAssertEqual(cnc.level, 4)
        XCTAssertEqual(cnc.max, 10)
    }
}
