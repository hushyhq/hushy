// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Murmur", targets: ["Murmur"]),
        .executable(name: "murmur-mcp", targets: ["murmur-mcp"]),
        .executable(name: "murmur-bench", targets: ["murmur-bench"]),
        .executable(name: "murmur-eval", targets: ["murmur-eval"]),
        .library(name: "MurmurCore", targets: ["MurmurCore"]),
        .library(name: "HushyModelsApple", targets: ["HushyModelsApple"]),
        .library(name: "HushyModelsMLX", targets: ["HushyModelsMLX"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // Auto-updates (gate 13). Inert until Info.plist carries a real SUFeedURL/SUPublicEDKey;
        // see docs/guide/RELEASE.md and Sources/Murmur/System/UpdateChecker.swift.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
        // MLX cleanup backend (M2, docs/product/MODEL-STRATEGY.md). Pinned exactly: a model
        // runtime changes numerics, so upgrades are deliberate (re-run the MLX evals). All MIT /
        // Apache-2.0 — see DECISIONS 2026-09-27 "MLX adapter". mlx-swift-lm is pinned to a main
        // commit because `MLXGuidedGeneration` (XGrammar) is not in a tagged release yet (3.31.4
        // predates it); move to the first 3.32 tag that contains it.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.6"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", revision: "ee673d6a71d76e67b532dc7eaf91d92edc3bb8bb"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.4"),
    ],
    targets: [
        .target(
            name: "MurmurCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            // Lexicon/Packs holds the pack JSON records; the binary carries them in DomainPackData.swift.
            exclude: ["README.md", "Lexicon/Packs"]
        ),
        // `LanguageModel` adapter for Apple's Foundation Models — the only target that imports
        // FoundationModels (MurmurCore stays model-agnostic; see docs/product/MODEL-STRATEGY.md M1).
        .target(name: "HushyModelsApple", dependencies: ["MurmurCore"]),
        // `LanguageModel` adapter for an open model run locally with MLX (M2). The app links it for
        // the opt-in "Hushy local model" cleanup backend (M4–M6); build-app.sh bundles mlx.metallib.
        .target(
            name: "HushyModelsMLX",
            dependencies: [
                "MurmurCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXGuidedGeneration", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        // EVAL-ONLY: `LanguageModel` over an OpenAI-compatible server on the CUDA box
        // (`murmur-eval --backend remote`). Never a dependency of the app or of anything it links —
        // `RemoteBackendIsolationTests` fails the build's tests if it becomes one. Not a product.
        .target(name: "HushyModelsRemote", dependencies: ["MurmurCore", "HushyModelsMLX"]),
        // One Objective-C class: catches an Objective-C exception and returns it as an error.
        // Swift cannot, and AVFAudio raises them while audio devices change (see HushyObjC.h).
        .target(name: "HushyObjC"),
        .executableTarget(
            name: "Murmur",
            dependencies: [
                "MurmurCore",
                "HushyObjC",
                "HushyModelsApple",
                "HushyModelsMLX",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            exclude: ["README.md"]
        ),
        .executableTarget(name: "murmur-mcp", dependencies: ["MurmurCore"], exclude: ["README.md"]),
        // Founder-only invite-code generator (`scripts/invite-codes`). Not a product; build-app.sh
        // only copies Murmur and murmur-mcp into the bundle. See docs/guide/INVITES.md.
        .executableTarget(name: "hushy-invites", dependencies: ["MurmurCore"]),
        // Build tool: seals a model folder's weights (AES-256-GCM chunks) into a new model id, for upload to the model
        // host. Not shipped; see docs/engineering/SEALED-MODELS.md.
        .executableTarget(name: "hushy-model-seal", dependencies: ["MurmurCore"]),
        // Accessibility reach probe (docs/product/SCREEN-CONTEXT-PLAN.md): counts of the text reachable in one app's window,
        // never the text. Run by the founder on their own apps; not shipped in the app bundle.
        .executableTarget(name: "hushy-ax-probe", dependencies: ["MurmurCore"]),
        .executableTarget(
            name: "murmur-bench",
            dependencies: ["MurmurCore", .product(name: "FluidAudio", package: "FluidAudio")],
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "murmur-eval",
            dependencies: [
                "MurmurCore", "HushyModelsApple", "HushyModelsMLX", "HushyModelsRemote",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            exclude: ["README.md"]
        ),
        // Fixtures are read by file path (`#filePath` or the repo-relative path), not via Bundle.module,
        // so they stay out of the bundle and are excluded from the target.
        .testTarget(name: "MurmurCoreTests", dependencies: ["MurmurCore"], exclude: ["Fixtures"]),
        .testTarget(name: "HushyModelsAppleTests", dependencies: ["HushyModelsApple", "MurmurCore"]),
        .testTarget(
            name: "HushyModelsMLXTests",
            dependencies: ["HushyModelsMLX", "MurmurCore", .product(name: "MLXGuidedGeneration", package: "mlx-swift-lm")]
        ),
        .testTarget(name: "HushyModelsRemoteTests", dependencies: ["HushyModelsRemote", "HushyModelsMLX", "MurmurCore"]),
        .testTarget(name: "MurmurEvalTests", dependencies: ["murmur-eval"]),
        .testTarget(name: "MurmurTests", dependencies: ["Murmur"]),
    ]
)
