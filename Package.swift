// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MeshLab",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "MeshLab", targets: ["MeshLab"]),
        .library(name: "MeshLabCore", targets: ["MeshLabCore"]),
        .library(name: "MeshLabRender", targets: ["MeshLabRender"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/hakkabon/Swift-NumericCore.git",
            .upToNextMajor(from: "1.0.0")
        ),
    ],
    targets: [
        .target(
            name: "MeshLabCore",
            dependencies: [
                .product(name: "NumericCore", package: "Swift-NumericCore"),
                .product(name: "NumericCoreSparse", package: "Swift-NumericCore"),
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
            ]
        ),
        .target(
            name: "MeshLabRender",
            dependencies: ["MeshLabCore"],
            resources: [
                .copy("Shaders.metal"),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
        .target(
            name: "MeshLab",
            dependencies: ["MeshLabCore", "MeshLabRender"]
        ),
        .testTarget(
            name: "MeshLabCoreTests",
            dependencies: ["MeshLabCore"]
        ),
        .testTarget(
            name: "MeshLabRenderTests",
            dependencies: ["MeshLabCore", "MeshLabRender"]
        ),
    ]
)
