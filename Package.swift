// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "open-apple-models",
    platforms: [.macOS("27.0"), .iOS("27.0"), .visionOS("27.0")],
    products: [
        // Core: runtime tools, steered tool loop, agents, JSON Schema → GenerationSchema.
        .library(name: "OpenAppleModels", targets: ["OpenAppleModels"]),
        // Game AI: NPC dialogue, decisions, world state, memory.
        .library(name: "OpenAppleModelsGame", targets: ["OpenAppleModelsGame"]),
        // OpenAI-compatible Chat Completions server with real tool calls.
        .library(name: "OpenAppleModelsServer", targets: ["OpenAppleModelsServer"]),
        // JSON-RPC protocol engine shared by the stdio CLI and the C ABI.
        .library(name: "OpenAppleModelsBridge", targets: ["OpenAppleModelsBridge"]),
        // C ABI for game engines (Unity, Godot, Unreal) and other languages.
        .library(name: "OpenAppleModelsFFI", type: .dynamic, targets: ["OpenAppleModelsFFI"]),
        // Deterministic scripted model for tests.
        .library(name: "OpenAppleModelsTesting", targets: ["OpenAppleModelsTesting"]),
        .executable(name: "oam", targets: ["oam"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "OpenAppleModels"),
        .target(name: "OpenAppleModelsGame", dependencies: ["OpenAppleModels"]),
        .target(name: "OpenAppleModelsServer", dependencies: ["OpenAppleModels"]),
        .target(name: "OpenAppleModelsBridge", dependencies: ["OpenAppleModels", "OpenAppleModelsGame", "OpenAppleModelsTesting"]),
        .target(name: "OpenAppleModelsFFI", dependencies: ["OpenAppleModelsBridge"]),
        .target(name: "OpenAppleModelsTesting", dependencies: ["OpenAppleModels"]),
        .executableTarget(
            name: "oam",
            dependencies: [
                "OpenAppleModels", "OpenAppleModelsGame", "OpenAppleModelsServer", "OpenAppleModelsBridge", "OpenAppleModelsTesting",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .testTarget(name: "OpenAppleModelsTests", dependencies: ["OpenAppleModels", "OpenAppleModelsTesting"]),
        .testTarget(name: "OpenAppleModelsGameTests", dependencies: ["OpenAppleModelsGame", "OpenAppleModelsTesting"]),
        .testTarget(name: "OpenAppleModelsServerTests", dependencies: ["OpenAppleModelsServer", "OpenAppleModelsTesting"]),
        .testTarget(name: "OpenAppleModelsBridgeTests", dependencies: ["OpenAppleModelsBridge", "OpenAppleModelsTesting"]),
    ]
)
