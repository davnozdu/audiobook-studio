// swift-tools-version: 6.2
import PackageDescription
import Foundation
let coreOnly = Context.environment["STUDIO_CORE_ONLY"] == "1"
let package = Package(name: "StudioNative", platforms: [.macOS(.v14)], products: coreOnly ? [] : [
    .executable(name: "StudioEngine", targets: ["StudioEngine"])
], dependencies: coreOnly ? [] : [
    .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.32.3"),
    .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.32.3"),
    .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.8.1"),
    .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.1.6"),
    .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "244458d7b61e54ff135073ddc9ed76782bb20758")
], targets: [
    .target(name: "StudioCore"),
    .target(name: "StudioRemote"),
    ] + (coreOnly ? [] : [ .executableTarget(name: "StudioEngine", dependencies: ["StudioCore", .product(name: "MLX", package: "mlx-swift"), .product(name: "MLXRandom", package: "mlx-swift"), .product(name: "MLXLMCommon", package: "mlx-swift-lm"), .product(name: "MLXAudioTTS", package: "mlx-audio-swift"), .product(name: "MLXAudioCore", package: "mlx-audio-swift")])
    ]) + [.testTarget(name: "StudioCoreTests", dependencies: ["StudioCore"]), .testTarget(name: "StudioRemoteTests", dependencies: ["StudioRemote"])], swiftLanguageModes: [.v5])
