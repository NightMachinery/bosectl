// Bose products known to speak BMAP, keyed by Bluetooth product id.

public struct Model: Sendable {
    public var productID: UInt16
    public var name: String
    public var codename: String
    /// Tested end to end with bosectl.
    public var verified: Bool
    /// Colour names by the variant byte of 0.3, where known.
    public var colors: [UInt8: String] = [:]

    public func color(_ variant: UInt8) -> String?
    {
        colors[variant]
    }
}

public enum Catalog {
    public static let models: [Model] = [
        // Headphones
        Model(productID: 0x400C, name: "QuietComfort 35", codename: "wolfcastle", verified: false),
        Model(productID: 0x4015, name: "Hearphones", codename: "stetson", verified: false),
        Model(productID: 0x4020, name: "QuietComfort 35 II", codename: "baywolf", verified: false),
        Model(productID: 0x4021, name: "ProFlight", codename: "atlas", verified: false),
        Model(productID: 0x4024, name: "Noise Cancelling Headphones 700", codename: "goodyear", verified: false),
        Model(productID: 0x402B, name: "Hearphones II", codename: "beanie", verified: false),
        Model(productID: 0x4039, name: "QuietComfort 45", codename: "duran", verified: false),
        Model(productID: 0x4066, name: "QuietComfort Ultra Headphones", codename: "lonestarr", verified: false),
        Model(productID: 0x4075, name: "QuietComfort Headphones", codename: "prince", verified: false),
        Model(
            productID: 0x4082, name: "QuietComfort Ultra Headphones (2nd Gen)", codename: "wolverine", verified: true,
            colors: [1: "Black", 2: "White Smoke", 3: "Driftwood Sand", 4: "Midnight Violet", 5: "Desert Gold"]
        ),
        Model(productID: 0x4083, name: "QuietComfort Headphones (2nd Gen)", codename: "", verified: false),
        // Earbuds
        Model(productID: 0x4012, name: "SoundSport", codename: "ice", verified: false),
        Model(productID: 0x4013, name: "SoundSport Pulse", codename: "flurry", verified: false),
        Model(productID: 0x4014, name: "QuietControl 30", codename: "powder", verified: false),
        Model(productID: 0x4018, name: "SoundSport Free", codename: "levi", verified: false),
        Model(productID: 0x402C, name: "Frames", codename: "celine", verified: false),
        Model(productID: 0x402D, name: "Sport Earbuds", codename: "revel", verified: false),
        Model(productID: 0x402F, name: "QuietComfort Earbuds", codename: "lando", verified: false),
        Model(productID: 0x403A, name: "Sport Open Earbuds", codename: "gwen", verified: false),
        Model(productID: 0x404C, name: "Frames (2nd Gen)", codename: "celine_ii", verified: false),
        Model(productID: 0x4060, name: "Frames Tempo", codename: "olivia", verified: false),
        Model(productID: 0x4061, name: "Frames", codename: "vedder", verified: false),
        Model(productID: 0x4062, name: "QuietComfort Ultra Earbuds (2nd Gen)", codename: "edith", verified: false),
        Model(productID: 0x4064, name: "QuietComfort Earbuds II", codename: "smalls", verified: false),
        Model(productID: 0x4068, name: "Ultra Open Earbuds", codename: "serena", verified: false),
        Model(productID: 0x4072, name: "QuietComfort Ultra Earbuds", codename: "scotty", verified: false),
        // Speakers
        Model(productID: 0x400A, name: "SoundLink (AE2)", codename: "isaac", verified: false),
        Model(productID: 0x400D, name: "SoundLink Color II", codename: "foreman", verified: false),
        Model(productID: 0x4010, name: "SoundLink Revolve", codename: "folgers", verified: false),
        Model(productID: 0x4011, name: "SoundLink Revolve+", codename: "harvey", verified: false),
        Model(productID: 0x4017, name: "SoundWear", codename: "kleos", verified: false),
        Model(productID: 0x4022, name: "SoundLink Micro", codename: "minnow", verified: false),
        Model(productID: 0x4085, name: "SoundLink Plus", codename: "troy", verified: false),
        Model(productID: 0xA211, name: "S1 Pro", codename: "chibi", verified: false),
        Model(productID: 0xBC58, name: "SoundLink Micro (2nd Gen)", codename: "billie", verified: false),
        Model(productID: 0xBC59, name: "SoundLink Flex", codename: "phelps", verified: false),
        Model(productID: 0xBC60, name: "SoundLink Flex (2nd Gen)", codename: "phelps_ii", verified: false),
        Model(productID: 0xBC61, name: "SoundLink Flex 2", codename: "mathers", verified: false),
        Model(productID: 0xBC63, name: "SoundLink Flex SE 2", codename: "stan", verified: false),
    ]

    public static func lookup(_ productID: UInt16) -> Model?
    {
        models.first { $0.productID == productID }
    }
}
