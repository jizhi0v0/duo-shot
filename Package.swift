// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DuoShot",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Local path, and it stays local until it earns its own repository.
        // Pure Swift with no resources, so it links straight into the executable
        // and `make bundle`'s "no nested code" rule is untouched.
        .package(path: "Packages/Linkdrop")
    ],
    targets: [
        // One ObjC file, existing only because Swift cannot @catch. Compiled into
        // the same binary, so it adds no nested code for `make sign` to handle.
        .target(name: "ObjCException", path: "Sources/ObjCException"),
        // The command line's wire format: what the app (the server) and the
        // `duoshot` tool (the client) both have to agree on, and nothing more —
        // the client's code is not linked into the app. No default isolation.
        .target(
            name: "DuoShotCLIWire",
            path: "Sources/DuoShotCLIWire",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        // The client, `duoshot`. A standalone tool, signed with its own
        // identifier and kept *outside* DuoShot.app (Makefile: build/duoshot,
        // ~/.local/bin/duoshot) — see Sources/DuoShotCLIWire/CLIWire.swift for
        // why. Not named "duoshot" here: SwiftPM puts every product in one
        // directory, and on a case-insensitive volume that is the same file as
        // "DuoShot".
        .executableTarget(
            name: "duoshot-cli",
            dependencies: ["DuoShotCLIWire"],
            path: "Sources/duoshot-cli",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        .executableTarget(
            name: "DuoShot",
            dependencies: [
                "ObjCException",
                "DuoShotCLIWire",
                .product(name: "Linkdrop", package: "Linkdrop"),
            ],
            path: "Sources/DuoShot",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // SE-0466: the module is ~90% AppKit, so MainActor is the right default.
                // It makes the exceptions (SCKBridge, ImageEncoder) visible instead of
                // burying them in a sea of @MainActor annotations.
                .defaultIsolation(MainActor.self),
                // SE-0461: `nonisolated async func` runs on the caller's executor, which is
                // what lets a non-Sendable SCContentFilter reach SCKBridge without crossing
                // an isolation region. Leaving main now requires an explicit @concurrent.
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        )
    ]
)
