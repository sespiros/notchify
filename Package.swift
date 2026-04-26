// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "notchify",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "notchify-daemon", targets: ["notchify-daemon"]),
        .executable(name: "notchify", targets: ["notchify"]),
    ],
    targets: [
        .executableTarget(
            name: "notchify-daemon",
            path: "Sources/notchify-daemon"
        ),
        .executableTarget(
            name: "notchify",
            path: "Sources/notchify"
        ),
    ]
)
