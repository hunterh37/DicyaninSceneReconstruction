// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DicyaninSceneReconstruction",
    platforms: [
        .visionOS(.v2)
    ],
    products: [
        .library(
            name: "DicyaninSceneReconstruction",
            targets: ["DicyaninSceneReconstruction"]
        )
    ],
    dependencies: [
        // Shared ARKit session — hosts both hand tracking and scene reconstruction
        // providers on one ARKitSession (Apple’s recommended single-session pattern).
        .package(url: "https://github.com/hunterh37/DicyaninARKitSession.git", from: "1.1.0")
    ],
    targets: [
        .target(
            name: "DicyaninSceneReconstruction",
            dependencies: ["DicyaninARKitSession"]
        ),
        .testTarget(
            name: "DicyaninSceneReconstructionTests",
            dependencies: ["DicyaninSceneReconstruction"]
        )
    ]
)
