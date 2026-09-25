// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacSuperpowers",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacSuperpowers", targets: ["MacSuperpowers"]),
        .executable(name: "MacSuperpowersMonitorAgent", targets: ["MacSuperpowersMonitorAgent"])
    ],
    targets: [
        .target(name: "CSystemMonitor", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .target(name: "MonitorCore", dependencies: ["CSystemMonitor"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "MacSuperpowers", dependencies: ["MonitorCore"], resources: [.process("Resources")]),
        .executableTarget(name: "MacSuperpowersMonitorAgent", dependencies: ["MonitorCore"]),
        .testTarget(name: "MacSuperpowersTests", dependencies: ["MacSuperpowers", "MonitorCore"])
    ]
)
