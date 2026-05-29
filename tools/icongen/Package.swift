// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "icongen",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "icongen",
            path: "Sources/icongen"
        )
    ]
)
