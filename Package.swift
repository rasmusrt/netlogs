// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Netlogs",
    // macOS 15 for the vectorized Charts API (LinePlot/AreaPlot, 15.0+).
    // Liquid Glass and concentric corners are macOS 26 and stay behind
    // #available in Sources/NetlogsApp/DesignSystem/LiquidGlass.swift.
    // Keep in step with LSMinimumSystemVersion in Support/Info.plist and with
    // MACOSX_DEPLOYMENT_TARGET in Netlogs.xcodeproj.
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NetlogsCore", targets: ["NetlogsCore"]),
        .executable(name: "netlogs-ping", targets: ["netlogs-ping"]),
        .executable(name: "NetlogsApp", targets: ["NetlogsApp"]),
    ],
    targets: [
        .target(
            name: "NetlogsCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "netlogs-ping",
            dependencies: ["NetlogsCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "NetlogsApp",
            dependencies: ["NetlogsCore"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                // Give the bare SwiftPM binary a bundle identity so it can run
                // as a "real" app (and so --selftest exercises that identity).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Support/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "NetlogsCoreTests",
            dependencies: ["NetlogsCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
