@testable import BMAP
import XCTest

/// Mode slots held in memory, answering like the headphones do.
final class SimulatedModes: Requester {
    var modes: [UInt8: [UInt8]] = [:]
    var writes: [ModeConfig] = []

    init()
    {
        for (name, index, _) in Presets.modes {
            modes[index] = modeRecord(index: index, name: name.capitalized, editable: false)
        }
        for slot in Presets.customSlots {
            modes[slot] = modeRecord(index: slot, name: "None", editable: true)
        }
    }

    func request(_ packet: Packet, accept: Set<Address>, collect: Collect, timeout: TimeInterval) throws -> [Packet]
    {
        var replies: [Packet] = []
        switch (packet.address, packet.op) {
        case (Function.allModes, .start):
            replies = modes.keys.sorted().map { Packet(Function.modeConfig, .status, modes[$0]!) }
            replies.append(Packet(Function.allModes, .result))
        case (Function.modeConfig, .setGet):
            let mode = try ModeConfig.parse(packet.payload)
            guard Presets.customSlots.contains(mode.index) else {
                replies = [Packet(Function.modeConfig, .error, [DeviceErrorCode.runtime.rawValue])]
                break
            }
            writes.append(mode)
            modes[mode.index] = modeRecord(index: mode.index, name: mode.name, editable: true, cnc: mode.cncLevel, wind: mode.windBlock, anc: mode.ancEnabled)
            replies = [Packet(Function.modeConfig, .status, packet.payload)]
        default:
            replies = [Packet(packet.address, .error, [DeviceErrorCode.functionNotSupported.rawValue])]
        }
        var collector = AnswerCollector(request: packet, accept: accept, collect: collect)
        for reply in replies {
            _ = try collector.feed(reply)
            if collector.done { break }
        }
        return collector.answers
    }
}

final class CustomModeTests: XCTestCase {
    func testCreatesInTheFirstEmptySlot()
    {
        let device = SimulatedModes()
        let saved = try! Headphones(device).saveCustomMode("Commute") { $0.cncLevel = 4 }
        XCTAssertEqual(saved.index, 4)
        XCTAssertEqual(saved.name, "Commute")
        XCTAssertEqual(saved.cncLevel, 4)
        XCTAssertTrue(saved.ancEnabled)
    }

    func testUpdatesAnExistingModeKeepingOtherSettings()
    {
        let device = SimulatedModes()
        let hp = Headphones(device)
        _ = try! hp.saveCustomMode("Commute") { $0.cncLevel = 4; $0.windBlock = true }
        let updated = try! hp.saveCustomMode("commute") { $0.cncLevel = 6 }
        XCTAssertEqual(updated.index, 4)
        XCTAssertEqual(updated.cncLevel, 6)
        XCTAssertTrue(updated.windBlock)
        XCTAssertEqual(try! hp.modes().filter { !$0.isEmpty && $0.editable }.count, 1)
    }

    func testRefusesPresetNames()
    {
        let hp = Headphones(SimulatedModes())
        XCTAssertThrowsError(try hp.saveCustomMode("Aware") { _ in }) { error in
            XCTAssertTrue(error is UsageError)
        }
        _ = try! hp.saveCustomMode("Commute") { _ in }
        XCTAssertThrowsError(try hp.saveCustomMode("Commute") { $0.name = "Quiet" })
    }

    func testDeletingEmptiesTheSlot()
    {
        let device = SimulatedModes()
        let hp = Headphones(device)
        _ = try! hp.saveCustomMode("Commute") { _ in }
        XCTAssertEqual(try hp.deleteCustomMode("COMMUTE"), 4)
        XCTAssertTrue(try! hp.modes().first { $0.index == 4 }!.isEmpty)
        XCTAssertThrowsError(try hp.deleteCustomMode("quiet"))
        XCTAssertThrowsError(try hp.deleteCustomMode("nothing"))
    }

    func testFullSlotsAreReported()
    {
        let hp = Headphones(SimulatedModes())
        for i in 0 ..< Presets.customSlots.count {
            _ = try! hp.saveCustomMode("Mode \(i)") { _ in }
        }
        XCTAssertThrowsError(try hp.saveCustomMode("One more") { _ in })
    }
}
