// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Softspoke",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SoftspokeCore"),
        .executableTarget(name: "Softspoke", dependencies: ["SoftspokeCore"]),
        .executableTarget(name: "softspoke-selftest", dependencies: ["SoftspokeCore"]),
    ]
)
