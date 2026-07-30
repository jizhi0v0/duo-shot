// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DuoShot",
    platforms: [.macOS(.v26)],
    targets: [
        // One ObjC file, existing only because Swift cannot @catch. Compiled into
        // the same binary, so it adds no nested code for `make sign` to handle.
        .target(name: "ObjCException", path: "Sources/ObjCException"),
        .executableTarget(
            name: "DuoShot",
            dependencies: ["ObjCException"],
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
