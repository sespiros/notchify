// swift-tools-version:5.9
import PackageDescription

// The `notchify` CLI used to be a Swift target here; it's now a
// Go module under `cmd/notchify/` (built by scripts/package.sh and
// flake.nix). Swift targets are only the macOS-native daemon and
// the recipes installer; everything else is portable Go.
let package = Package(
    name: "notchify",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "notchify-daemon", targets: ["notchify-daemon"]),
        .executable(name: "notchify-recipes", targets: ["notchify-recipes"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "notchify-daemon",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/notchify-daemon",
            exclude: ["Focus/README.md"]
        ),
        .executableTarget(
            name: "notchify-recipes",
            path: "Sources/notchify-recipes"
        ),
        .testTarget(
            name: "notchify-daemonTests",
            dependencies: ["notchify-daemon"],
            path: "Tests/notchify-daemonTests"
        ),
    ]
)
