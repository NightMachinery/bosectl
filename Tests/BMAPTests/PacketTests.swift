@testable import BMAP
import XCTest

final class PacketTests: XCTestCase {
    func testEncodesHeaderAndPayload()
    {
        XCTAssertEqual(Packet(Address(0, 5), .get).encoded(), [0x00, 0x05, 0x01, 0x00])
        XCTAssertEqual(Packet(Address(31, 3), .start, [0x02, 0x00]).encoded(), [0x1f, 0x03, 0x05, 0x02, 0x02, 0x00])
    }

    func testFlagsCarryPortAndDeviceID()
    {
        let p = Packet(Address(1, 1), .status, [], port: 2, deviceID: 1)
        XCTAssertEqual(p.flags, 0x63)
        var reader = PacketReader()
        reader.append(p.encoded())
        XCTAssertEqual(reader.next(), p)
    }

    func testReaderSplitsConcatenatedPackets()
    {
        // Firmware string reply followed by a STATUS for 31.3.
        var reader = PacketReader()
        reader.append(Hex.decode("0005031131302e31322e31322b67613932376339611f03030100")!)
        let packets = reader.drain()
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(String(decoding: packets[0].payload, as: UTF8.self), "10.12.12+ga927c9a")
        XCTAssertEqual(packets[1], Packet(Address(31, 3), .status, [0x00]))
        XCTAssertEqual(reader.pendingBytes, 0)
    }

    func testReaderWaitsForTheRestOfAPacket()
    {
        var reader = PacketReader()
        reader.append([0x02, 0x02, 0x03, 0x02, 0x28])
        XCTAssertNil(reader.next())
        reader.append([0x00])
        XCTAssertEqual(reader.next(), Packet(Address(2, 2), .status, [0x28, 0x00]))
    }

    func testReaderDropsBytesThatCannotStartAPacket()
    {
        var reader = PacketReader()
        // 0x0f is not an operator, so nothing buffered can be trusted.
        reader.append([0xaa, 0xbb, 0x0f, 0x00, 0x00, 0x05, 0x01, 0x00])
        XCTAssertNil(reader.next())
        XCTAssertEqual(reader.discarded, 8)
        // Later packets parse normally.
        reader.append([0x00, 0x05, 0x01, 0x00])
        XCTAssertEqual(reader.next()?.address, Address(0, 5))
    }

    func testErrorPacketsExposeTheirCode()
    {
        let p = Packet(Address(1, 5), .error, [0x05])
        XCTAssertEqual(p.errorCode, 5)
        XCTAssertTrue(p.description.contains("authentication"))
    }

    func testHexRoundTrip()
    {
        XCTAssertEqual(Hex.decode("1f 03:05-02"), [0x1f, 0x03, 0x05, 0x02])
        XCTAssertEqual(Hex.decode("0x1f0x03"), [0x1f, 0x03])
        XCTAssertNil(Hex.decode("1f0"))
        XCTAssertNil(Hex.decode("zz"))
        XCTAssertEqual(Hex.encode([0x00, 0xab, 0x10], separator: " "), "00 ab 10")
    }

    func testAddressParsing()
    {
        XCTAssertEqual(Address(parsing: "31.10"), Address(31, 10))
        XCTAssertNil(Address(parsing: "31"))
        XCTAssertNil(Address(parsing: "256.1"))
        XCTAssertEqual(Address(31, 10).description, "31.10")
    }
}
