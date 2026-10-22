// swift-tools-version: 6.0
//
// Built with the Command Line Tools alone — no Xcode project. scripts/build-app.sh
// compiles each architecture separately, merges them with lipo and assembles
// the .app bundle by hand.

import PackageDescription

let package = Package(
    name: "Silent Route",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SilentRoute", targets: ["SilentRouteApp"]),
        .executable(name: "SilentRouteHelper", targets: ["SilentRouteHelper"]),
        .executable(name: "sroute", targets: ["sroute"]),
    ],
    targets: [
        // Model, link parser, config generators, validation. No I/O, no
        // global state: everything here is a pure function of its input.
        .target(
            name: "VPNCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Code that touches the system: running sing-box, probing servers.
        // Shared by the CLI, the app and (later) the helper.
        .target(
            name: "VPNRuntime",
            dependencies: ["VPNCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The helper's logic: state machine and its system interfaces. Tested
        // with fakes; the LaunchDaemon executable is a thin shell around it.
        .target(
            name: "VPNHelperKit",
            dependencies: ["VPNCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "VPNHelperKitTests",
            dependencies: ["VPNHelperKit", "VPNCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Messages between the app/CLI and the helper, and the XPC client.
        .target(
            name: "VPNIPC",
            dependencies: ["VPNCore", "VPNRuntime"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The root LaunchDaemon.
        .executableTarget(
            name: "SilentRouteHelper",
            dependencies: ["VPNCore", "VPNHelperKit", "VPNIPC", "VPNRuntime"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "sroute",
            dependencies: ["VPNCore", "VPNRuntime", "VPNIPC", "VPNHelperKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Everything the app shows: model, menu bar, window. A library so the
        // snapshot tool can render the same views with a fake helper.
        .target(
            name: "SilentRouteUI",
            dependencies: ["VPNCore", "VPNIPC", "VPNRuntime"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "SilentRouteApp",
            dependencies: ["SilentRouteUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Development tool: renders the UI offscreen to PNGs (light and dark,
        // several states) for layout review. Not shipped.
        .executableTarget(
            name: "ui-snapshots",
            dependencies: ["SilentRouteUI", "VPNCore", "VPNIPC"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SilentRouteUITests",
            dependencies: ["SilentRouteUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "VPNCoreTests",
            dependencies: ["VPNCore"],
            exclude: ["golden"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
