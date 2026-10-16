// Bose products known to speak BMAP, keyed by Bluetooth product id.

public struct Model: Sendable {
    public var productID: UInt16
    public var name: String
    public var codename: String
    /// Tested end to end with bosectl.
    public var verified: Bool
}

public enum Catalog {
    public static let models: [Model] = [
        Model(productID: 0x4082, name: "QuietComfort Ultra Headphones (2nd Gen)", codename: "wolverine", verified: true),
    ]

    public static func lookup(_ productID: UInt16) -> Model?
    {
        models.first { $0.productID == productID }
    }
}
