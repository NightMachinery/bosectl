@testable import BMAP
import XCTest

final class LESegmentsTests: XCTestCase {
    func testShortPacketsGoInOneSegmentWithHeaderZero()
    {
        XCTAssertEqual(LESegments.split([0x02, 0x02, 0x01, 0x00]), [[0x00, 0x02, 0x02, 0x01, 0x00]])
    }

    func testLongPacketsAreNumbered()
    {
        // A 40-byte mode record plus its 4-byte header: 44 bytes, 3 segments.
        let packet = [UInt8](0 ..< 44)
        let segments = LESegments.split(packet)
        XCTAssertEqual(segments.map(\.first), [0x20, 0x21, 0x22])
        XCTAssertEqual(segments.map(\.count), [20, 20, 7])
        var joiner = LESegments.Reassembler()
        XCTAssertNil(joiner.feed(segments[0]))
        XCTAssertNil(joiner.feed(segments[1]))
        XCTAssertEqual(joiner.feed(segments[2]), packet)
    }

    func testAReplyAsTheHeadphonesSentIt()
    {
        // The battery over LE: header 0, then 2.2 STATUS [50, ff, ff, 00].
        var joiner = LESegments.Reassembler()
        let bytes = joiner.feed([0x00, 0x02, 0x02, 0x03, 0x04, 0x32, 0xff, 0xff, 0x00])
        XCTAssertEqual(bytes, [0x02, 0x02, 0x03, 0x04, 0x32, 0xff, 0xff, 0x00])
    }

    func testAMissingSegmentDropsThePacket()
    {
        let segments = LESegments.split([UInt8](0 ..< 44))
        var joiner = LESegments.Reassembler()
        XCTAssertNil(joiner.feed(segments[0]))
        XCTAssertNil(joiner.feed(segments[2]))
    }
}
