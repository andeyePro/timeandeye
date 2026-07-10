// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "timeandeye",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "timeandeyeCore", targets: ["timeandeyeCore"]),
        // The pro repo's executable wraps these two (plus its paid backends).
        .library(name: "timeandeyeMac", targets: ["timeandeyeMac"]),
        .library(name: "timeandeyeUI", targets: ["timeandeyeUI"]),
        .library(name: "timeandeyeStore", targets: ["timeandeyeStore"]),
        .library(name: "timeandeyePhone", targets: ["timeandeyePhone"]),
        // The shared andeye look (colours, type scale, eye-mark renderer) —
        // SwiftUI-only, no AppKit, so sibling apps (a sibling andeye app etc.) consume
        // theme without the macOS app deps. Surface contract: the cross-repo note.
        .library(name: "timeandeyeTheme", targets: ["timeandeyeTheme"]),
    ],
    targets: [
        .target(name: "timeandeyeCore"),
        // Platform-NEUTRAL persistence + sync transport: SQLite replica,
        // CloudKit pipe, key file store. macOS AND iOS build on this.
        .target(name: "timeandeyeStore", dependencies: ["timeandeyeCore"]),
        // The iOS app's engine (manual tracking, pick list, export) —
        // UI-framework-free, so the CLT-only Mac loop compile-guards and
        // checks it; only the SwiftUI shell in ios/ needs Xcode.
        .target(name: "timeandeyePhone", dependencies: ["timeandeyeCore", "timeandeyeStore"]),
        // macOS-only layer: sensors, app controller, menu-bar glue.
        // (Theme dep = the brand-mark geometry AndeyeLogoImage renders.)
        .target(name: "timeandeyeMac",
                dependencies: ["timeandeyeCore", "timeandeyeStore", "timeandeyeTheme"]),
        // Shared brand look (mark geometry + SwiftUI styling). A LEAF on
        // purpose — no engine dependency, so sibling andeye apps that only
        // want the brand take just this target (2026-07-10 relocation).
        .target(name: "timeandeyeTheme"),
        // The whole SwiftUI layer as a LIBRARY, so app flavours are thin
        // wrappers: Community (below) and the private Pro executable both
        // return AndeyeScenes.body(controller:).
        .target(name: "timeandeyeUI",
                dependencies: ["timeandeyeCore", "timeandeyeMac", "timeandeyeTheme"]),
        // The Community menu-bar app (wrapped into timeandeye.app by scripts/make-app.sh).
        .executableTarget(name: "timeandeyeApp",
                          dependencies: ["timeandeyeCore", "timeandeyeMac", "timeandeyeUI"]),
        // Check harness instead of a test target: the build Mac has Command
        // Line Tools only (no XCTest / Swift Testing). Run: swift run timeandeyeChecks
        .executableTarget(name: "timeandeyeChecks",
                          dependencies: ["timeandeyeCore", "timeandeyeMac",
                                         "timeandeyePhone", "timeandeyeTheme"]),
        // Headless end-to-end against a REAL OpenProject as a test user:
        // swift run timeandeyeIntegration <base-url> <key-file>
        .executableTarget(name: "timeandeyeIntegration",
                          dependencies: ["timeandeyeCore", "timeandeyeMac"]),
    ]
)
