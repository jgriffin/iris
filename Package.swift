// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Iris",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "Iris", targets: ["Iris"])],
    targets: [
        .target(name: "Iris"),
        .testTarget(
            name: "IrisTests",
            dependencies: ["Iris"],
            resources: [.process("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
