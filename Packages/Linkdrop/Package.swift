// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Linkdrop",
    // Deliberately far below the app that first needed this. A share client is
    // the least platform-specific thing in a screenshot tool -- URLSession, the
    // Keychain and ImageIO have all been stable for a decade -- and pinning it
    // to the host app's macOS 26 floor would make it unusable to everyone else
    // for no technical reason.
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "Linkdrop", targets: ["Linkdrop"])
    ],
    targets: [
        .target(
            name: "Linkdrop",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // No network in the test target. Everything that needs a server is an
        // integration test in the host app, run against a local `wrangler dev`.
        .testTarget(
            name: "LinkdropTests",
            dependencies: ["Linkdrop"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
