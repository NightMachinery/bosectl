// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "bosectl",
    platforms: [.macOS(.v11)],
    products: [
        .executable(name: "bosectl", targets: ["bosectl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // Wire format, function catalog, payload parsers and builders.
        // Pure Swift with no I/O, so it is fully testable offline.
        .target(name: "BMAP"),
        // IOBluetooth: paired-device discovery, link state, RFCOMM sessions.
        // CoreBluetooth: listening for advertisements.
        .target(
            name: "BMAPBluetooth",
            dependencies: ["BMAP"],
            linkerSettings: [.linkedFramework("IOBluetooth"), .linkedFramework("CoreBluetooth")]
        ),
        .executableTarget(
            name: "bosectl",
            dependencies: [
                "BMAP",
                "BMAPBluetooth",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "BMAPTests", dependencies: ["BMAP"]),
    ]
)
