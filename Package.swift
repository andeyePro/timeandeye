// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Ambitick",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AmbitickCore", targets: ["AmbitickCore"]),
        // The pro repo's executable wraps these two (plus its paid backends).
        .library(name: "AmbitickMac", targets: ["AmbitickMac"]),
        .library(name: "AmbitickUI", targets: ["AmbitickUI"]),
    ],
    targets: [
        .target(name: "AmbitickCore"),
        // macOS-only layer: SQLite journal, Keychain, sensors, app controller.
        .target(name: "AmbitickMac", dependencies: ["AmbitickCore"]),
        // The whole SwiftUI layer as a LIBRARY, so app flavours are thin
        // wrappers: Community (below) and the private Pro executable both
        // return AmbitickScenes.body(controller:).
        .target(name: "AmbitickUI", dependencies: ["AmbitickCore", "AmbitickMac"]),
        // The Community menu-bar app (wrapped into Ambitick.app by scripts/make-app.sh).
        .executableTarget(name: "AmbitickApp",
                          dependencies: ["AmbitickCore", "AmbitickMac", "AmbitickUI"]),
        // Check harness instead of a test target: the build Mac has Command
        // Line Tools only (no XCTest / Swift Testing). Run: swift run AmbitickCoreChecks
        .executableTarget(name: "AmbitickCoreChecks",
                          dependencies: ["AmbitickCore", "AmbitickMac"]),
        // Headless end-to-end against a REAL OpenProject as a test user:
        // swift run AmbitickIntegration <base-url> <key-file>
        .executableTarget(name: "AmbitickIntegration",
                          dependencies: ["AmbitickCore", "AmbitickMac"]),
    ]
)
