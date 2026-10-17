// Function addresses, grouped by function block, as used by the
// QuietComfort Ultra Headphones (2nd Gen). Other models reuse most of them.

public enum Function {
    // Block 0: product info
    public static let bmapVersion = Address(0, 1)
    /// [product id hi, lo, variant (colour)]
    public static let productID = Address(0, 3)
    public static let firmwareVersion = Address(0, 5)
    public static let serialNumber = Address(0, 7)
    public static let modelName = Address(0, 15)

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

    // Block 4: device management (the hosts the headphones remember)
    public static let connectHost = Address(4, 1)
    public static let disconnectHost = Address(4, 2)
    public static let hosts = Address(4, 4)
    public static let hostInfo = Address(4, 5)
    public static let pairingMode = Address(4, 8)
    /// The address of the host asking.
    public static let ownAddress = Address(4, 9)

    // Block 5: audio management
    public static let source = Address(5, 1)
    public static let media = Address(5, 3)
    public static let codec = Address(5, 4)
    public static let volume = Address(5, 5)

    // Block 7: control
    public static let power = Address(7, 4)

    // Block 18: authentication (its GETs are open)
    public static let codename = Address(18, 12)
    public static let platform = Address(18, 13)

    // Block 31: audio modes
    public static let allModes = Address(31, 1)
    public static let currentMode = Address(31, 3)
    public static let defaultMode = Address(31, 4)
    public static let modeConfig = Address(31, 6)
    public static let favorites = Address(31, 8)
    public static let audioSettings = Address(31, 10)
}
