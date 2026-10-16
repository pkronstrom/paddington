// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "paddington",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "paddington", targets: ["paddington"]),
               .executable(name: "padbeat", targets: ["padbeat"])],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        .target(name: "PaddingtonCore", dependencies: ["TOMLKit"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "PaddingtonMac", dependencies: ["PaddingtonCore"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "paddington", dependencies: ["PaddingtonCore", "PaddingtonMac"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        // padbeat: a minimal stand-alone MIDI → sample player (no paddington code); paddington only writes its note map
        .executableTarget(name: "padbeat", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "PaddingtonCoreTests", dependencies: ["PaddingtonCore"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
