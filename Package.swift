// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Safarium",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SafariumCore", targets: ["SafariumCore"]),
        .library(name: "SafariumContainers", targets: ["SafariumContainers"]),
        .library(name: "SafariumForgeCore", targets: ["SafariumForgeCore"]),
        .library(name: "SafariumPrism", targets: ["SafariumPrism"]),
        // In-process 2D raster library with a flat C ABI (cv2 replacement for Python via ctypes).
        .library(name: "SafariumRaster", type: .dynamic, targets: ["SafariumRaster"]),
        .executable(name: "safarium-cdp", targets: ["safarium-cdp"]),
        .executable(name: "safarium-bench", targets: ["safarium-bench"]),
        .executable(name: "safarium-regions", targets: ["safarium-regions"]),
        .executable(name: "safarium-html", targets: ["safarium-html"]),
        .executable(name: "safarium-media", targets: ["safarium-media"]),
        .executable(name: "safarium-forge", targets: ["safarium-forge"]),
    ],
    targets: [
        .target(
            name: "SafariumCore",
            resources: [.copy("Resources/clock.js")]
        ),
        .target(
            name: "SafariumRasterC",
            cSettings: [.unsafeFlags(["-O3"])]
        ),
        .target(
            name: "SafariumRaster",
            dependencies: ["SafariumRasterC"],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
            ]
        ),
        .target(
            name: "SafariumContainers",
            dependencies: ["SafariumCore"]
        ),
        .target(
            name: "SafariumForgeCore",
            dependencies: ["SafariumCore", "SafariumContainers"]
        ),
        .target(
            name: "SafariumPrism",
            dependencies: ["SafariumCore", "SafariumContainers", "SafariumForgeCore"]
        ),
        .testTarget(
            name: "SafariumCoreTests",
            dependencies: ["SafariumCore"]
        ),
        .testTarget(
            name: "SafariumContainersTests",
            dependencies: ["SafariumCore", "SafariumContainers"]
        ),
        .testTarget(
            name: "SafariumForgeTests",
            dependencies: ["SafariumCore", "SafariumContainers", "SafariumForgeCore", "SafariumPrism"]
        ),
        .testTarget(
            name: "SafariumPrismTests",
            dependencies: ["SafariumCore", "SafariumContainers", "SafariumForgeCore", "SafariumPrism"]
        ),
        .testTarget(
            name: "SafariumProbeTests",
            dependencies: ["SafariumCore"]
        ),
        .executableTarget(
            name: "safarium-cdp",
            dependencies: ["SafariumCore"]
        ),
        .executableTarget(
            name: "safarium-bench",
            dependencies: ["SafariumCore"]
        ),
        .executableTarget(
            name: "safarium-regions",
            dependencies: ["SafariumCore"]
        ),
        .executableTarget(
            name: "safarium-html",
            dependencies: ["SafariumCore"]
        ),
        .executableTarget(
            name: "safarium-media",
            dependencies: ["SafariumCore"]
        ),
        .executableTarget(
            name: "safarium-forge",
            dependencies: ["SafariumCore", "SafariumContainers", "SafariumForgeCore", "SafariumPrism"]
        ),
        .testTarget(
            name: "SafariumCDPTests",
            dependencies: ["safarium-cdp"]
        ),
    ]
)
