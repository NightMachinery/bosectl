@testable import BMAP
import XCTest

final class AdvertisementTests: XCTestCase {
    func testDecodesTheQCUltra2Advertisement()
    {
        // As a QC Ultra 2 advertised it on the cable; the trailing six bytes,
        // not decoded, are zeroed here.
        let ad = BoseAdvertisement.parse([0x9e, 0x00, 0x00, 0x8c, 0x07, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(ad?.productValue, 112)
        XCTAssertEqual(ad?.model?.codename, "wolverine")
        XCTAssertEqual(ad?.color, "Midnight Violet")
        XCTAssertEqual(ad?.charging, true)
        XCTAssertEqual(ad?.pairing, false)
        XCTAssertEqual(BoseAdvertisement.parse([0x9e, 0x00, 0x00, 0x8c, 0x0f])?.pairing, true)
    }

    func testOnlyFormatZeroIsDecoded()
    {
        XCTAssertTrue(BoseAdvertisement.isBose([0x9e, 0x00, 0x01, 0x8c, 0x07]))
        XCTAssertNil(BoseAdvertisement.parse([0x9e, 0x00, 0x01, 0x8c, 0x07]))
        XCTAssertFalse(BoseAdvertisement.isBose([0x4c, 0x00, 0x00, 0x8c, 0x07]))
        XCTAssertNil(BoseAdvertisement.parse([0x9e, 0x00, 0x00]))
    }
}
