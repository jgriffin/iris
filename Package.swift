// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Iris",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "Iris", targets: ["Iris"])],
    targets: [
        .target(
            name: "Iris",
            exclude: [
                "Overlay/box-rendering.html",
                "Overlay/quad-rendering.html",
                "Overlay/skeleton-rendering.html",
            ]
        ),
        .testTarget(
            name: "IrisTests",
            dependencies: ["Iris"],
            // Exclude the `.mlpackage` from automatic resource discovery so
            // the `.process("Fixtures")` rule doesn't claim it (which would
            // flatten the bundle, dumping `model.mlmodel` / `weight.bin`
            // loose). The explicit `.copy` rule below re-adds it intact.
            exclude: ["Fixtures/yolo12n.mlpackage"],
            resources: [
                // `.copy` (not `.process`) preserves the `.mlpackage` as a
                // locatable bundle directory so
                // `Bundle.module.url(forResource:withExtension:"mlpackage")`
                // resolves. The rest of Fixtures (video clips) is processed.
                .copy("Fixtures/yolo12n.mlpackage"),
                .process("Fixtures"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
