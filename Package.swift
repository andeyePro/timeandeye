// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "andeyeTT",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "andeyeTTCore", targets: ["andeyeTTCore"]),
        // The pro repo's executable wraps these two (plus its paid backends).
        .library(name: "andeyeTTMac", targets: ["andeyeTTMac"]),
        .library(name: "andeyeTTUI", targets: ["andeyeTTUI"]),
        .library(name: "andeyeTTStore", targets: ["andeyeTTStore"]),
        .library(name: "andeyeTTPhone", targets: ["andeyeTTPhone"]),
    ],
    targets: [
        .target(name: "andeyeTTCore"),
        // Platform-NEUTRAL persistence + sync transport: SQLite replica,
        // CloudKit pipe, key file store. macOS AND iOS build on this.
        .target(name: "andeyeTTStore", dependencies: ["andeyeTTCore"]),
        // The iOS app's engine (manual tracking, pick list, export) —
        // UI-framework-free, so the CLT-only Mac loop compile-guards and
        // checks it; only the SwiftUI shell in ios/ needs Xcode.
        .target(name: "andeyeTTPhone", dependencies: ["andeyeTTCore", "andeyeTTStore"]),
        // macOS-only layer: sensors, app controller, menu-bar glue.
        .target(name: "andeyeTTMac", dependencies: ["andeyeTTCore", "andeyeTTStore"]),
        // The whole SwiftUI layer as a LIBRARY, so app flavours are thin
        // wrappers: Community (below) and the private Pro executable both
        // return AndeyeScenes.body(controller:).
        .target(name: "andeyeTTUI", dependencies: ["andeyeTTCore", "andeyeTTMac"]),
        // The Community menu-bar app (wrapped into timeandeye.app by scripts/make-app.sh).
        .executableTarget(name: "andeyeApp",
                          dependencies: ["andeyeTTCore", "andeyeTTMac", "andeyeTTUI"]),
        // Check harness instead of a test target: the build Mac has Command
        // Line Tools only (no XCTest / Swift Testing). Run: swift run andeyeTTChecks
        .executableTarget(name: "andeyeTTChecks",
                          dependencies: ["andeyeTTCore", "andeyeTTMac", "andeyeTTPhone"]),
        // Headless end-to-end against a REAL OpenProject as a test user:
        // swift run andeyeTTIntegration <base-url> <key-file>
        .executableTarget(name: "andeyeTTIntegration",
                          dependencies: ["andeyeTTCore", "andeyeTTMac"]),
    ]
)
