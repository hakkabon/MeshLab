// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MeshLab",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "MeshLab", targets: ["MeshLab"]),
        .library(name: "MeshLabCore", targets: ["MeshLabCore"]),
        .library(name: "MeshLabRender", targets: ["MeshLabRender"]),
        .executable(name: "MeshLabApp", targets: ["MeshLabApp"]),
        .executable(name: "MeshLabBenchmarks", targets: ["MeshLabBenchmarks"]),
        .executable(name: "MeshLabSweep", targets: ["MeshLabSweep"]),
        .executable(name: "MeshLabValidate", targets: ["MeshLabValidate"]),
    ],
    dependencies: [
        // NumericCore is the numerical substrate. See
        // docs/decisions/0002-dependency-and-release-policy.md. Always consume
        // a released 1.x tag; never a branch or local path.
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
                .product(name: "NumericCoreOptimization", package: "Swift-NumericCore"),
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
        .executableTarget(
            name: "MeshLabApp",
            dependencies: ["MeshLab"],
            path: "Sources/MeshLabApp"
        ),
        .executableTarget(
            name: "MeshLabBenchmarks",
            dependencies: ["MeshLabCore", "MeshLabRender"],
            path: "Benchmarks/MeshLabBenchmarks"
        ),
        .executableTarget(
            name: "MeshLabSweep",
            dependencies: ["MeshLabCore"],
            path: "Sources/MeshLabSweep"
        ),
        .executableTarget(
            name: "MeshLabValidate",
            dependencies: ["MeshLabCore"],
            path: "Sources/MeshLabValidate"
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
