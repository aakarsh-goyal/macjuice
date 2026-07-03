// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacJuice",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "MacJuice",
            path: "Sources/MacJuice",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
