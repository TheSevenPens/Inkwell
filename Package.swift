// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Inkwell",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Inkwell",
            path: "Sources/Inkwell",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
