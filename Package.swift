// swift-tools-version: 5.10
import PackageDescription

// Camera rendering styles: film, CCD and other digital cameras.
// Shared engine and offline tool only. No macOS application sources or targets.
let package = Package(
    name: "Lumera",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ImagingCore", targets: ["ImagingCore"]),
        .library(name: "ImageRendering", targets: ["ImageRendering"]),
        .library(name: "ImagingRuntime", targets: ["ImagingRuntime"]),
        .library(name: "ImageAnalysis", targets: ["ImageAnalysis"]),
        .executable(name: "ccdlab", targets: ["ImagingCLI"])
    ],
    targets: [
        .target(name: "ImagingCore"),
        .target(name: "ImageRendering", dependencies: ["ImagingCore"], resources: [.copy("Resources")]),
        .target(name: "ImagingRuntime", dependencies: ["ImagingCore", "ImageRendering"]),
        .target(name: "ImageAnalysis", dependencies: ["ImagingCore", "ImageRendering"], resources: [.copy("StyleGeneration/Fixtures")]),
        .executableTarget(name: "ImagingCLI", dependencies: ["ImagingCore", "ImageRendering", "ImageAnalysis", "ImagingRuntime"]),
        .testTarget(name: "ImagingCoreTests", dependencies: ["ImagingCore"]),
        .testTarget(name: "ImagingRuntimeTests", dependencies: ["ImagingCore", "ImageRendering", "ImagingRuntime", "ImageAnalysis"]),
        .testTarget(name: "ImageRenderingTests", dependencies: ["ImagingCore", "ImageRendering"]),
        .testTarget(name: "DesktopContractTests", dependencies: ["ImagingCore", "ImageRendering", "ImageAnalysis"]),
        .testTarget(name: "LumeraTests", dependencies: ["ImagingCore", "ImageRendering", "ImageAnalysis"])
    ]
)
