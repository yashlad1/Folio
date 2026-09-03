// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Folio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Folio",
            path: "Sources/Folio",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FolioTests",
            dependencies: ["Folio"],
            path: "Tests/FolioTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
