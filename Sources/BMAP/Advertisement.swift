// The Bluetooth LE advertisement Bose headphones send while they are on:
// which product they are and a few state flags, readable without connecting.

/// Manufacturer-specific data under Bose's company identifier.
public struct BoseAdvertisement: Equatable, Sendable {
    /// Bose's Bluetooth SIG company identifier, sent little-endian.
    public static let companyID: UInt16 = 0x009E

    /// The low 5 bits of the product byte plus 100, as format 0 encodes it;
    /// see Model.bleValue.
    public var productValue: Int
    /// The high 3 bits of the product byte.
    public var variant: UInt8
    public var flags: UInt8

    /// Seen as 0x07 on the cable and 0x0f in pairing mode. Bit 1 is said to
    /// mean a connection slot is free, but it stays set with two hosts
    /// linked, so only the two bits below are decoded.
    public var charging: Bool { flags & 0x01 != 0 }
    public var pairing: Bool { flags & 0x08 != 0 }

    public var model: Model? { Catalog.lookup(bleValue: productValue) }
    /// The variant is the colour, as in 0.3.
    public var color: String? { model?.color(variant) }

    /// True when the data is Bose's, whether or not its format is known.
    public static func isBose(_ data: [UInt8]) -> Bool
    {
        data.count >= 2 && UInt16(data[0]) | UInt16(data[1]) << 8 == companyID
    }

    /// `data` is the manufacturer data as CoreBluetooth reports it: the
    /// company identifier, then [format, product, flags, ...]. Only format 0
    /// is understood; anything else is nil rather than a guess.
    public static func parse(_ data: [UInt8]) -> BoseAdvertisement?
    {
        guard isBose(data), data.count >= 5, data[2] == 0 else { return nil }
        return BoseAdvertisement(productValue: 100 + Int(data[3] & 0x1F), variant: data[3] >> 5, flags: data[4])
    }
}
