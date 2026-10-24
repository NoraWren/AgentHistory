// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentHistory",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentHistory", targets: ["AgentHistory"])
    ],
    targets: [
        .executableTarget(
            name: "AgentHistory",
            path: "Sources",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
