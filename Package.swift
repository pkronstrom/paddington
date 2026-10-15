// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "padctl",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "padctl", targets: ["padctl"]),
               .executable(name: "padbeat", targets: ["padbeat"])],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        .target(name: "PadctlCore", dependencies: ["TOMLKit"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "PadctlMac", dependencies: ["PadctlCore"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "padctl", dependencies: ["PadctlCore", "PadctlMac"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        // padbeat: a minimal stand-alone MIDI → sample player (no padctl code); padctl only writes its note map
        .executableTarget(name: "padbeat", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "PadctlCoreTests", dependencies: ["PadctlCore"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
