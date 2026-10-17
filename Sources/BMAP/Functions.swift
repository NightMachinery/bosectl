// Function addresses, grouped by function block, as used by the
// QuietComfort Ultra Headphones (2nd Gen). Other models reuse most of them.

public enum Function {
    // Block 0: product info
    public static let bmapVersion = Address(0, 1)
    public static let firmwareVersion = Address(0, 5)
    public static let serialNumber = Address(0, 7)

    // Block 1: settings
    public static let productName = Address(1, 2)
    public static let voicePrompts = Address(1, 3)
    /// Read-only on this model; noise control lives in block 31.
    public static let cnc = Address(1, 5)
    public static let eq = Address(1, 7)
    public static let buttons = Address(1, 9)
    public static let multipoint = Address(1, 10)
    public static let sidetone = Address(1, 11)
    public static let autoPause = Address(1, 24)
    public static let autoAnswer = Address(1, 27)

    // Block 2: status
    public static let battery = Address(2, 2)

    // Block 4: device management
    public static let pairingMode = Address(4, 8)

    // Block 5: audio management
    public static let source = Address(5, 1)

    // Block 7: power
    public static let power = Address(7, 4)

    // Block 31: audio modes
    public static let allModes = Address(31, 1)
    public static let currentMode = Address(31, 3)
    public static let defaultMode = Address(31, 4)
    public static let modeConfig = Address(31, 6)
    public static let favorites = Address(31, 8)
    public static let audioSettings = Address(31, 10)
}
