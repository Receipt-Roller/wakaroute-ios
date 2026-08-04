// swift-tools-version: 6.0
import PackageDescription

// Core logic lives here rather than in the app target so it can be built and
// tested from the command line without booting a simulator. macOS is listed
// only to keep `swift test` fast; the app itself ships iOS.
let package = Package(
    name: "WakaRouteKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WakaRouteKit", targets: ["WakaRouteKit"])
    ],
    targets: [
        // The prerequisite graph ships as data rather than code so it can be
        // reviewed as a curriculum decision, and later served from
        // wakaroute.com without touching the parser (t-1fa7220).
        .target(name: "WakaRouteKit", resources: [.process("Resources")]),
        .testTarget(name: "WakaRouteKitTests", dependencies: ["WakaRouteKit"])
    ]
)
