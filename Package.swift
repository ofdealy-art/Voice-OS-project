// swift-tools-version:5.9
import PackageDescription

// ScreenMate is split so that the majority of the logic lives in a target that
// does not depend on any Apple UI framework. `ScreenMateCore` builds (and its
// tests run) on any platform with a Swift toolchain, which keeps the provider,
// storage, redaction and state-machine logic genuinely unit-testable.
//
// `ScreenMateKit` and the `ScreenMate` executable need AppKit, ScreenCaptureKit,
// Speech, AVFoundation and Vision, so they are only declared when the manifest
// is evaluated on macOS.

var targets: [Target] = [
    .target(name: "ScreenMateCore"),
    .testTarget(
        name: "ScreenMateCoreTests",
        dependencies: ["ScreenMateCore"]
    ),
]

var products: [Product] = [
    .library(name: "ScreenMateCore", targets: ["ScreenMateCore"]),
]

#if os(macOS)
targets += [
    .target(
        name: "ScreenMateKit",
        dependencies: ["ScreenMateCore"]
    ),
    .executableTarget(
        name: "ScreenMate",
        dependencies: ["ScreenMateKit"]
    ),
    .testTarget(
        name: "ScreenMateKitTests",
        dependencies: ["ScreenMateKit"]
    ),
]
products += [
    .library(name: "ScreenMateKit", targets: ["ScreenMateKit"]),
    .executable(name: "ScreenMate", targets: ["ScreenMate"]),
]
#endif

let package = Package(
    name: "ScreenMate",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
