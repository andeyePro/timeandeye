// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Ambitick",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AmbitickCore", targets: ["AmbitickCore"])
    ],
    targets: [
        .target(name: "AmbitickCore"),
        // Check harness instead of a test target: the build Mac has Command
        // Line Tools only (no XCTest / Swift Testing). Run: swift run AmbitickCoreChecks
        .executableTarget(name: "AmbitickCoreChecks", dependencies: ["AmbitickCore"]),
    ]
)
