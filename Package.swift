// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "notchify",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "notchify-daemon", targets: ["notchify-daemon"]),
        .executable(name: "notchify", targets: ["notchify"]),
        .executable(name: "notchify-recipes", targets: ["notchify-recipes"]),
    ],
    targets: [
        .executableTarget(
            name: "notchify-daemon",
            path: "Sources/notchify-daemon",
            exclude: ["Focus/README.md"]
        ),
        .executableTarget(
            name: "notchify",
            path: "Sources/notchify",
            exclude: ["Focus/README.md"]
        ),
        .executableTarget(
            name: "notchify-recipes",
            path: "Sources/notchify-recipes"
        ),
    ]
)
