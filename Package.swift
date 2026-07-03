// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "andeyeTT",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "AndeyeTTCore", targets: ["AndeyeTTCore"]),
        // The pro repo's executable wraps these two (plus its paid backends).
        .library(name: "AndeyeTTMac", targets: ["AndeyeTTMac"]),
        .library(name: "AndeyeTTUI", targets: ["AndeyeTTUI"]),
        .library(name: "AndeyeTTStore", targets: ["AndeyeTTStore"]),
        .library(name: "AndeyeTTPhone", targets: ["AndeyeTTPhone"]),
    ],
    targets: [
        .target(name: "AndeyeTTCore"),
        // Platform-NEUTRAL persistence + sync transport: SQLite replica,
        // CloudKit pipe, key file store. macOS AND iOS build on this.
        .target(name: "AndeyeTTStore", dependencies: ["AndeyeTTCore"]),
        // The iOS app's engine (manual tracking, pick list, export) —
        // UI-framework-free, so the CLT-only Mac loop compile-guards and
        // checks it; only the SwiftUI shell in ios/ needs Xcode.
        .target(name: "AndeyeTTPhone", dependencies: ["AndeyeTTCore", "AndeyeTTStore"]),
        // macOS-only layer: sensors, app controller, menu-bar glue.
        .target(name: "AndeyeTTMac", dependencies: ["AndeyeTTCore", "AndeyeTTStore"]),
        // The whole SwiftUI layer as a LIBRARY, so app flavours are thin
        // wrappers: Community (below) and the private Pro executable both
        // return AndeyeScenes.body(controller:).
        .target(name: "AndeyeTTUI", dependencies: ["AndeyeTTCore", "AndeyeTTMac"]),
        // The Community menu-bar app (wrapped into andeye.app by scripts/make-app.sh).
        .executableTarget(name: "AndeyeApp",
                          dependencies: ["AndeyeTTCore", "AndeyeTTMac", "AndeyeTTUI"]),
        // Check harness instead of a test target: the build Mac has Command
        // Line Tools only (no XCTest / Swift Testing). Run: swift run AndeyeTTChecks
        .executableTarget(name: "AndeyeTTChecks",
                          dependencies: ["AndeyeTTCore", "AndeyeTTMac", "AndeyeTTPhone"]),
        // Headless end-to-end against a REAL OpenProject as a test user:
        // swift run AndeyeTTIntegration <base-url> <key-file>
        .executableTarget(name: "AndeyeTTIntegration",
                          dependencies: ["AndeyeTTCore", "AndeyeTTMac"]),
    ]
)
