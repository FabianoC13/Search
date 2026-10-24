// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Search",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Search",
            dependencies: ["CChromium"],
            path: "Sources/Search",
            // Same reasoning as the canvas app next door: the whole interface is
            // main-thread by nature, and Swift 6's strict isolation buys nothing
            // here but ceremony.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Chromium, through CEF's C API: the framework itself is never linked,
        // only opened at run time from the add-on (Sources/Search/Chromium).
        // CEF_API_VERSION is the one pin: the C structures' layout follows it,
        // and the add-on's framework must report the same hash for it.
        // chromium.sh reads it from here.
        .target(
            name: "CChromium",
            path: "Sources/CChromium",
            exclude: ["cef/LICENSE.txt"],
            cSettings: [
                .headerSearchPath("cef"),
                .define("CEF_API_VERSION", to: "CEF_API_VERSION_15600")
            ],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        // One page through the C layer and nothing of Search's: a window,
        // example.com, the callbacks logged, Chromium stopped (chromium.sh test).
        .executableTarget(
            name: "ChromiumSmoke",
            dependencies: ["CChromium"],
            path: "Tests/ChromiumSmoke"
        ),
        .testTarget(
            name: "SearchTests",
            dependencies: ["Search"],
            path: "Tests/SearchTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
