@testable import BMAP
import XCTest

final class SettingsFileTests: XCTestCase {
    func parse(_ json: String) throws -> SettingsFile
    {
        try SettingsFile.parse(Data(json.utf8))
    }

    func testASavedStatusAppliesAsItIs()
    {
        // What 'bosectl --json status' printed, with the identifiers replaced.
        let file = try? parse("""
            {"model":"QuietComfort Ultra Headphones (2nd Gen)","name":"Studio",
             "address":"00:11:22:33:44:55","firmware":"10.12.12",
             "batteries":[{"part":"battery","level_percent":50,"charging":"yes"}],
             "mode":"quiet","mode_index":0,
             "noise":{"cnc_level":0,"auto_cnc":false,"anc":true,"wind_block":false,"spatial":"off"},
             "volume":{"level":11,"max":31},
             "playing_from":[{"address":"00:11:22:33:44:66","name":"Laptop","connected":true}],
             "eq":[{"band":"bass","value":0,"min":-10,"max":10},{"band":"mid","value":0,"min":-10,"max":10},
                   {"band":"treble","value":-2,"min":-10,"max":10}],
             "multipoint":true,"sidetone":"medium","auto_pause":true,"auto_answer":false,
             "voice_prompts":{"language":"US English","announce_connections":false,"announce_battery":false}}
            """)
        XCTAssertEqual(file?.mode, "quiet")
        XCTAssertEqual(file?.cncLevel, 0)
        XCTAssertEqual(file?.spatial, .off)
        XCTAssertEqual(file?.volume, 11)
        XCTAssertEqual(file?.eq, [.bass: 0, .mid: 0, .treble: -2])
        XCTAssertEqual(file?.sidetone, .medium)
        XCTAssertEqual(file?.autoAnswer, false)
        XCTAssertEqual(file?.name, "Studio")
    }

    func testAHandWrittenFileNamesOnlyWhatItChanges()
    {
        let file = try? parse(#"{"mode": "aware", "volume": 8, "eq": {"bass": 3}}"#)
        XCTAssertEqual(file?.mode, "aware")
        XCTAssertEqual(file?.volume, 8)
        XCTAssertEqual(file?.eq, [.bass: 3])
        XCTAssertNil(file?.sidetone)
        XCTAssertEqual(file?.changesNoise, false)
    }

    func testTheModeIndexIsOnlyAFallback()
    {
        XCTAssertEqual(try? parse(#"{"mode_index": 4}"#).mode, "4")
        XCTAssertEqual(try? parse(#"{"mode": "cinema", "mode_index": 3}"#).mode, "cinema")
        XCTAssertNil(try? parse(#"{"mode_index": null}"#).mode)
    }

    func testBadValuesAreRefusedBeforeAnythingIsSent()
    {
        for json in [
            #"{"volum": 8}"#,  // a typo
            #"{"volume": true}"#,  // JSON true arrives as NSNumber 1
            #"{"multipoint": 1}"#,
            #"{"sidetone": "loud"}"#,
            #"{"eq": {"bass": 11}}"#,
            #"{"eq": {"sub": 1}}"#,
            #"{"noise": {"cnc_level": 2.5}}"#,
            #"{"noise": {"spatial": "everywhere"}}"#,
            #"["mode", "quiet"]"#,
        ] {
            XCTAssertThrowsError(try parse(json), json)
        }
    }
}
