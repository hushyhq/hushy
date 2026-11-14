import Foundation

/// One on-device cleanup model Hushy can download (M4, `docs/product/MODEL-STRATEGY.md`): where
/// its files come from (a Hugging Face repo pinned to a commit), each file's exact size and
/// SHA-256, its licence, the system prompt it was trained for, and which Macs it suits.
///
/// Entries are data, checked into the repo: a fine-tuned model is a new entry (its own repo and
/// revision, `promptProfile: .compact`), not a new code path.
public struct LocalModelEntry: Identifiable, Equatable, Sendable {
    /// Which system prompt cleanup calls use — mirrors `MLXLanguageModel.PromptProfile`.
    /// `production` = the full instructions (zero-shot models); `compact` = the short prompt a
    /// model fine-tuned on `CompactCleanupPrompt` expects.
    public enum PromptProfile: String, Equatable, Sendable, CaseIterable {
        case production, compact, intent
    }

    public struct License: Equatable, Sendable {
        /// SPDX identifier.
        public let spdx: String
        /// The licence text shipped in the app bundle (`Resources/Licenses/<name>`), shown from
        /// Settings. Apache-2.0 requires the text to travel with the weights.
        public let bundledTextFile: String
        public let sourceURL: URL
    }

    /// The weights' provenance: repo + commit. `textOnly` is false for the mlx-community
    /// conversions, which keep Qwen3.5's vision tower (unused: 0.25 GB of the 0.8B download, ~0.75 GB of the 2B).
    public struct Source: Equatable, Sendable {
        public let repo: String
        public let revision: String
        public let textOnly: Bool
        public let note: String
    }

    public enum Role: Equatable, Sendable {
        case cleanupDefault, candidate
    }

    public let role: Role
    public let id: String
    /// What Settings shows ("Qwen3.5 2B · 6-bit").
    public let displayName: String
    public let parameterLabel: String
    public let bits: Int
    public let source: Source
    public let files: [DownloadableAsset.File]
    public let license: License
    public let promptProfile: PromptProfile
    /// Prompt-lookup speculation on (INFERENCE-OPTIMIZATION §2): same answers, 1.2–1.9× faster.
    public let speculation: Bool
    /// Measured resident memory with the prefix cache built (MB, M4 Pro).
    public let residentMegabytes: Int
    /// Macs with less RAM than this are never recommended it (an override shows a warning).
    public let minimumMemoryGB: Int
    /// Measured quality/latency, for the Settings detail line and the handbook.
    public let measured: String
    public let chipNotes: String
    /// Whether the model was trained on the one-line register note (`IntentRegister`) that follows the first line of the
    /// intent system prompt. Only such a model is sent the note; for every other model the prompt is exactly as it was,
    /// and the word-level tone pass (`ToneRegister`) still does the tone. True only for the 4B (round 10d), which was
    /// trained on the line; false for every other registered model.
    public let understandsRegisterLines: Bool
    /// Non-nil for a *sealed* entry: the same model as the plain entry `sealing.supersedes`, with its weights
    /// shipped as AES-256-GCM chunks (`SealedFormat`) that only Hushy's own process can open. The key comes
    /// from the account-gated key route and rests in the Keychain (`ModelKeyProvider`).
    public let sealing: Sealing?

    public struct Sealing: Equatable, Sendable {
        /// The id of the plain entry this one replaces: installed users move over by the normal handover
        /// (download this, verify it, switch, delete the plain files).
        public let supersedes: String
    }

    /// The model this entry delivers: itself, or for a sealed entry the plain entry it replaces. Two entries with
    /// one logical id are the same model, so tier rules and tests compare this, not `id`.
    public var logicalID: String { sealing?.supersedes ?? id }

    public init(
        id: String, displayName: String, parameterLabel: String, bits: Int, source: Source,
        files: [DownloadableAsset.File], license: License, promptProfile: PromptProfile,
        speculation: Bool, residentMegabytes: Int, minimumMemoryGB: Int,
        measured: String, chipNotes: String, role: Role = .candidate, understandsRegisterLines: Bool = false,
        sealing: Sealing? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.parameterLabel = parameterLabel
        self.bits = bits
        self.source = source
        self.files = files
        self.license = license
        self.promptProfile = promptProfile
        self.speculation = speculation
        self.residentMegabytes = residentMegabytes
        self.minimumMemoryGB = minimumMemoryGB
        self.measured = measured
        self.chipNotes = chipNotes
        self.role = role
        self.understandsRegisterLines = understandsRegisterLines
        self.sealing = sealing
    }

    /// This model, sealed: the files that are not weights stay as they are (the tokenizer and configs are
    /// public) under the new id, and the weights become `weights` (the part files `hushy-model-seal` printed).
    func sealed(as sealedID: String, weights: [(name: String, bytes: Int64, sha256: String)]) -> LocalModelEntry {
        let kept = files.filter { file in
            let name = file.relativePath
            return !name.hasSuffix(".safetensors") && name != "model.safetensors.index.json" && name != "reshard-manifest.json"
        }
        let moved = (kept.map { ($0.relativePath, $0.bytes, $0.sha256) } + weights.map { ($0.name, $0.bytes, $0.sha256) })
            .sorted { $0.0 < $1.0 }
            .map { DownloadableAsset.File(
                remoteURL: LocalModelEntry.hushyModelsURL(model: sealedID, path: $0.0),
                relativePath: $0.0, bytes: $0.1, sha256: $0.2) }
        return LocalModelEntry(
            id: sealedID, displayName: displayName, parameterLabel: parameterLabel, bits: bits, source: source, files: moved,
            license: license, promptProfile: promptProfile, speculation: speculation, residentMegabytes: residentMegabytes,
            minimumMemoryGB: minimumMemoryGB, measured: measured, chipNotes: chipNotes, role: role,
            understandsRegisterLines: understandsRegisterLines, sealing: Sealing(supersedes: id))
    }

    public var downloadBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    /// The optional, accept-to-start download the queue runs for this entry.
    public var asset: DownloadableAsset {
        DownloadableAsset(
            id: LocalModelEntry.assetIDPrefix + id, title: "Hushy local model", kind: .cleanupModel,
            importance: .optional, startPolicy: .whenAccepted, expectedBytes: downloadBytes, source: .files(files))
    }

    public static let assetIDPrefix = "cleanup-model:"

    /// The registry entry id behind a queue asset id, when it is a cleanup model.
    public static func entryID(forAssetID assetID: String) -> String? {
        assetID.hasPrefix(assetIDPrefix) ? String(assetID.dropFirst(assetIDPrefix.count)) : nil
    }

    public static func hushyModelsURL(model: String, path: String) -> URL {
        URL(string: "https://models.tryhushy.com/cleanup/\(model)/\(path)")!
    }

    /// `https://huggingface.co/<repo>/resolve/<revision>/<path>` — pinned by commit, so the
    /// bytes can't change under a SHA-256 that was computed once.
    public static func huggingFaceURL(repo: String, revision: String, path: String) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(path)")!
    }
}

/// The cleanup models Hushy knows how to download and run, and the RAM-tier rule that picks one.
///
/// Today's entries are the public mlx-community conversions (Apache-2.0), pinned by commit. Our
/// own text-only conversions (`scripts/finetune/convert_mlx.sh`) are ~0.75 GB smaller for the
/// 2B but need hosting we don't have yet; the fine-tuned models from the GPU box will replace
/// these entries (same shape, `promptProfile: .compact`). See DECISIONS 2026-09-27 "MLX cleanup
/// model in the app".
public enum ModelRegistry {
    public static let hushyCleanup4B = "hushy-cleanup-4b-r10d-6bit"
    public static let hushyCleanup2BIntent = "hushy-cleanup-2b-r5d2blr2-4bit"
    public static let hushyCleanup2B = "hushy-cleanup-2b-v5.4-4bit"
    public static let qwen4B4bit = "qwen3.5-4b-4bit-meeting"
    public static let qwen2B6bit = "qwen3.5-2b-6bit"
    public static let qwen2B4bit = "qwen3.5-2b-4bit"
    public static let qwen08B4bit = "qwen3.5-0.8b-4bit"

    static let qwenLicense = LocalModelEntry.License(
        spdx: "Apache-2.0", bundledTextFile: "Qwen3.5-LICENSE.txt",
        sourceURL: URL(string: "https://huggingface.co/Qwen/Qwen3.5-2B/blob/15852e8c16360a2fea060d615a32b45270f8a8fc/LICENSE")!)

    /// Files every Qwen3.5 mlx-community conversion shares (the tokenizer and chat template are
    /// byte-identical across the three repos).
    private static func qwenFiles(
        repo: String, revision: String, weights: (bytes: Int64, sha256: String),
        config: String, index: (bytes: Int64, sha256: String), configBytes: Int64 = 3_113
    ) -> [DownloadableAsset.File] {
        func file(_ path: String, _ bytes: Int64, _ sha256: String) -> DownloadableAsset.File {
            DownloadableAsset.File(
                remoteURL: LocalModelEntry.huggingFaceURL(repo: repo, revision: revision, path: path),
                relativePath: path, bytes: bytes, sha256: sha256)
        }
        return [
            file("config.json", configBytes, config),
            file("chat_template.jinja", 7_755, "273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80"),
            file("tokenizer_config.json", 1_139, "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182"),
            file("tokenizer.json", 19_989_343, "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
            file("model.safetensors.index.json", index.bytes, index.sha256),
            file("model.safetensors", weights.bytes, weights.sha256),
        ]
    }

    private static let plainEntries: [LocalModelEntry] = [
        LocalModelEntry(
            id: hushyCleanup4B, displayName: "Hushy cleanup model · 4B intent", parameterLabel: "4B", bits: 6,
            source: .init(repo: "tryhushy/hushy-cleanup-4b-r10d", revision: "r10d", textOnly: true,
                          note: "Round 10d fine-tune of Qwen3.5-4B (cleanup, tones, prompts); text-only, 6-bit group 64."),
            files: [
                ("chat_template.jinja", 7_756, "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715"),
                ("config.json", 3_057, "19db8609566c8cc709b5e9f1b168976f864ecf0ee3f4c40d2edb80c8aa5ce54a"),
                ("generation_config.json", 116, "62153eb6c69f2e1f426beaa8002b7186437e949c7588167085df14e10e9c0a73"),
                ("model-00001-of-00012.safetensors", 290_453_704, "624ce0db02c8a739e6922ba4c04220dd2c56f0caf44e817c5e1efd9398196866"),
                ("model-00002-of-00012.safetensors", 300_739_315, "914e0c6e0803aa9bf5888af3db22760498042d58af74ad81382d51ed706fc42a"),
                ("model-00003-of-00012.safetensors", 293_113_429, "04e79e1b8eb50d3777d62e67e8881b26a762c37226faec982a72c8f57c165190"),
                ("model-00004-of-00012.safetensors", 299_614_249, "0318af48aa30a885da3d2ed12dfa19e6dc4359d59b2a76dc373d5a8d96136195"),
                ("model-00005-of-00012.safetensors", 295_652_137, "cd01d9e7079da7561376e16f6910ace74ad8d5a92988d21b56fe835383b54735"),
                ("model-00006-of-00012.safetensors", 300_638_017, "faf74f403bce0b801857337bf9ec10c7aac67744bdd62fdd7acd673b6217f7fe"),
                ("model-00007-of-00012.safetensors", 287_709_947, "c6918b211c0dff4392e1984ea97aab18331c97878734d5b344e2f5e36a1acc1a"),
                ("model-00008-of-00012.safetensors", 295_648_201, "0aa114010ded6cae9ac8c268a0bfc39a728e439750c41b68ff386679e8e82584"),
                ("model-00009-of-00012.safetensors", 243_321_273, "c324fd89ce15c135ed1143e493e3a2a075007375ceaec227687e3af798ca8ae5"),
                ("model-00010-of-00012.safetensors", 303_037_600, "a443c1e8339783cdd14a3c89c48a2790b526d76e92a0b41514cbb2f57530967d"),
                ("model-00011-of-00012.safetensors", 291_424_568, "5fc9a7c085a7742f727f0eed6d7c0351b6646148de2df8dbd0ffaac7a1060b11"),
                ("model-00012-of-00012.safetensors", 217_081_257, "d0a82a41154a22cc8b741e69f8db1ad5c5225eefb06de87c373b7ea2de1b7556"),
                ("model.safetensors.index.json", 85_654, "16c77d1feafcb2b60ac1621f71dee02c994b241bf82c513578c5f7c3fc66b245"),
                ("reshard-manifest.json", 256, "a7601c8921928eecc3358900f351168833a1308adacf925dfb812ee97bdc2650"),
                ("tokenizer.json", 19_989_325, "06b9509352d2af50381ab2247e083b80d32d5c0aba91c272ca9ff729b6a0e523"),
                ("tokenizer_config.json", 1_161, "95c557768e6b88a7128befc7bfd3c7de50e5d51af9b8b33a9f4dee0e04f99679")
            ].map { file in
                DownloadableAsset.File(remoteURL: LocalModelEntry.hushyModelsURL(model: hushyCleanup4B, path: file.0),
                                       relativePath: file.0, bytes: file.1, sha256: file.2)
            },
            license: qwenLicense, promptProfile: .intent, speculation: false,
            residentMegabytes: 4_400, minimumMemoryGB: 24,
            measured: "Round 10d, full precision on the public sets: public 300 234, Disfl-QA 272/500, prompts 48/50; 6-bit through the app on an M4 Pro: see TRY-64.",
            chipNotes: "Default on Macs with 24 GB or more and a Pro, Max or Ultra chip (about 0.4 s median per cleanup on an M4 Pro); the 2B intent model answers while it downloads.",
            understandsRegisterLines: true),
        LocalModelEntry(
            id: hushyCleanup2BIntent, displayName: "Hushy cleanup model · 2B intent", parameterLabel: "2B", bits: 4,
            source: .init(repo: "tryhushy/hushy-cleanup-2b-r5d2blr2", revision: "r5d2blr2", textOnly: true,
                          note: "Arm D data on Qwen3.5-2B, 2 epochs at learning rate 2e-4; text-only, 4-bit group 64."),
            files: [
                ("chat_template.jinja", 7_755, "273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80"),
                ("config.json", 2_804, "92ede1d4c6a86fd4970cfbcac82bfcc2c628a85cb0015f147d4e557595a0eb04"),
                ("generation_config.json", 116, "62153eb6c69f2e1f426beaa8002b7186437e949c7588167085df14e10e9c0a73"),
                ("model-00001-of-00004.safetensors", 302_979_349, "1f8f29699c9c533888116edfdab7e2bcf3f3bbee4ab272ee1bdf2fdbc1631b6d"),
                ("model-00002-of-00004.safetensors", 300_179_403, "ba0629e2b999b75a3bced73d5b7a5abb3a2142301d20da120ca05ed09d29e172"),
                ("model-00003-of-00004.safetensors", 298_360_380, "121cf13b0d684d46f1f5021435f1e61071a3188f9e3a2c6d788c3c66a603cdd0"),
                ("model-00004-of-00004.safetensors", 157_884_831, "98bd2ee3d0513a8653606826211865ae365af2f99673067e09a0363ac8e18b4a"),
                ("model.safetensors.index.json", 64_184, "41436560e086e198f9dc170f7eb5f0135082cc1d47f6b0718b0ff26ed755ceba"),
                ("reshard-manifest.json", 61, "7dd59241bf039171979b520190e2f5f32e3ba60ebe7299a1e2c7e1d9c4281b22"),
                ("tokenizer.json", 19_989_325, "06b9509352d2af50381ab2247e083b80d32d5c0aba91c272ca9ff729b6a0e523"),
                ("tokenizer_config.json", 1_161, "95c557768e6b88a7128befc7bfd3c7de50e5d51af9b8b33a9f4dee0e04f99679")
            ].map { file in
                DownloadableAsset.File(remoteURL: LocalModelEntry.hushyModelsURL(model: hushyCleanup2BIntent, path: file.0),
                                       relativePath: file.0, bytes: file.1, sha256: file.2)
            },
            license: qwenLicense, promptProfile: .intent, speculation: false,
            residentMegabytes: 1_500, minimumMemoryGB: 16,
            measured: "Public 300 through the app: 234 exact (M4 Pro, total p50 324 ms, first token p50 53 ms); golden 56/68.",
            chipNotes: "Default on every other Mac with 16 GB or more; the stand-in while the 4B downloads on a 24 GB+ Pro/Max Mac, and the way back to a smaller model there."),
        /// Derived from Qwen3.5-2B (Apache-2.0); the licence and NOTICE travel with the weights.
        LocalModelEntry(
            id: hushyCleanup2B, displayName: "Hushy cleanup model · 2B", parameterLabel: "2B", bits: 4,
            source: .init(repo: "tryhushy/hushy-cleanup-2b-v5.4", revision: "v5.4", textOnly: true,
                          note: "Our text-only 4-bit conversion of the v5.4 fine-tune (1.01 GB); hosted at models.tryhushy.com."),
            files: [
                ("config.json", 2_804, "92ede1d4c6a86fd4970cfbcac82bfcc2c628a85cb0015f147d4e557595a0eb04"),
                ("chat_template.jinja", 7_755, "273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80"),
                ("tokenizer_config.json", 1_161, "95c557768e6b88a7128befc7bfd3c7de50e5d51af9b8b33a9f4dee0e04f99679"),
                ("tokenizer.json", 19_989_325, "06b9509352d2af50381ab2247e083b80d32d5c0aba91c272ca9ff729b6a0e523"),
                // Four shards under 300 MiB each (the R2 upload limit); the index names them.
                ("model.safetensors.index.json", 68_404, "dd59028c62dfa40a75858129924bdc3dd96f6df4355153f7259d30bd7fdbfd72"),
                ("model-00001-of-00004.safetensors", 293_497_134, "1891e9842036bdcf352d5491c605e8c50b9a1d9cd7542ad9e08b58964dcbaf53"),
                ("model-00002-of-00004.safetensors", 293_266_928, "3c03135db6744dd2e8d8d2a92607581459b014fc3c18d03322d6737e937f180a"),
                ("model-00003-of-00004.safetensors", 290_165_798, "20445d8107d1d62dba11ceeb0e83c2ae79f8a4d1dcd29418ebb8149a6a086a01"),
                ("model-00004-of-00004.safetensors", 182_474_051, "244d9aa934da3cccefede2480c83272cf6d7b6a5cfb3c19e5ffda8a84f4a5b88"),
            ].map { file in
                DownloadableAsset.File(remoteURL: LocalModelEntry.hushyModelsURL(model: hushyCleanup2B, path: file.0),
                                       relativePath: file.0, bytes: file.1, sha256: file.2)
            },
            license: qwenLicense, promptProfile: .compact, speculation: true,
            residentMegabytes: 1_500, minimumMemoryGB: 16,
            measured: "Blind held-out v2: Clean 63/88, Polished 67/88, negatives 30/30 and 29/30 — same as Apple FM; long p50 386 ms vs 1717 ms.",
            chipNotes: "Default on Apple silicon with more than 8 GB; while it downloads, Hushy uses its simpler fixes and the pill shows the download, and Apple Intelligence steps in only if it cannot answer in time.",
            role: .cleanupDefault),
        LocalModelEntry(
            id: qwen2B6bit, displayName: "Qwen3.5 2B · 6-bit", parameterLabel: "2B", bits: 6,
            source: .init(
                repo: "mlx-community/Qwen3.5-2B-6bit", revision: "ba2bcf03dd5b502646de7e32b003cf538f2ca4d6", textOnly: false,
                note: "Public conversion with the vision tower (2.21 GB); our text-only 6-bit is 1.46 GB once hosted."),
            files: qwenFiles(
                repo: "mlx-community/Qwen3.5-2B-6bit", revision: "ba2bcf03dd5b502646de7e32b003cf538f2ca4d6",
                weights: (2_192_591_075, "e2c78893f7cb9d1c176688861bb31614af7ee097ff5e6bbfc504b4230daef80b"),
                config: "67f7ede1bbee9d4bc5dc5250e3358e052937d1a8d30e22c5b4a54dff85addb5b",
                index: (81_722, "550563c429bb3db15685b92087f82271f4dec1e2441da01678f65142064b528e")),
            license: qwenLicense, promptProfile: .production, speculation: true,
            residentMegabytes: 1_480, minimumMemoryGB: 16,
            measured: "Zero-shot: cleanup-hybrid 63, Clean 57, Polished 60 (Apple 64/57/63); 15-word Clean 199/252 ms p50/p95 with speculation on an M4 Pro.",
            chipNotes: "Pro/Max chips (≥ 150 GB/s). On a base M1/M2 it is est. 0.3–0.6 s per call."),
        LocalModelEntry(
            id: qwen2B4bit, displayName: "Qwen3.5 2B · 4-bit", parameterLabel: "2B", bits: 4,
            source: .init(
                repo: "mlx-community/Qwen3.5-2B-4bit", revision: "674aaa7240b91e8012fcad5d791b7dfe5ba90207", textOnly: false,
                note: "Public conversion with the vision tower (1.74 GB); our text-only 4-bit is 1.01 GB once hosted."),
            files: qwenFiles(
                repo: "mlx-community/Qwen3.5-2B-4bit", revision: "674aaa7240b91e8012fcad5d791b7dfe5ba90207",
                weights: (1_722_271_785, "713fe7e5d3c3965f7106b0d0ee17615f7869c23c8d327996df8c1196fbcf07d5"),
                config: "beb7fc5a6e0405fe332821cf1a8ef7b69bb390a8c8933171647de5579debf949",
                index: (81_722, "8294c05cca7d53a6c33e3db2b379539bd296d054e0b689711b16b6ac93c7e49d")),
            license: qwenLicense, promptProfile: .production, speculation: true,
            residentMegabytes: 1_090, minimumMemoryGB: 16,
            measured: "Zero-shot: cleanup-hybrid 60, Clean 52, Polished 54; 15-word Clean 161/194 ms with speculation on an M4 Pro.",
            chipNotes: "The 16 GB base-chip opt-in (est. 0.3–0.5 s per call on M2/M4); Pro/Max fallback if 6-bit loses its edge after the fine-tune."),
        LocalModelEntry(
            id: qwen08B4bit, displayName: "Qwen3.5 0.8B · 4-bit", parameterLabel: "0.8B", bits: 4,
            source: .init(
                repo: "mlx-community/Qwen3.5-0.8B-4bit", revision: "da28692b5f139cb0ec58a356b437486b7dac7462", textOnly: false,
                note: "Public conversion with the vision tower (0.65 GB); our text-only 4-bit is 0.40 GB once hosted."),
            files: qwenFiles(
                repo: "mlx-community/Qwen3.5-0.8B-4bit", revision: "da28692b5f139cb0ec58a356b437486b7dac7462",
                weights: (625_229_487, "f5a0d9dd3efa73510542a8023d610ff26be2b4b020d181cfc4bedaa1fcc5dd9e"),
                config: "ba7770da23eae5ebd6827571f086e331956b33f4442a9e876fb4aa10969a6772",
                index: (71_473, "6e48f2fa5d6f033a6d77bf833abfa9698ca24d1715ecea4c67447bcfaee44650"), configBytes: 3_112),
            license: qwenLicense, promptProfile: .production, speculation: true,
            residentMegabytes: 580, minimumMemoryGB: 8,
            measured: "Zero-shot: cleanup-hybrid 58, Clean 50, Polished 47; 15-word Clean 75/85 ms with speculation on an M4 Pro.",
            chipNotes: "Every Mac; the 8 GB and base-chip default (est. M1 ≈ 200 ms, M2 ≈ 150 ms per 15-word call)."),
    ]

    public static let hushyCleanup4BSealed = "hushy-cleanup-4b-r10d-6bit-enc1"
    public static let hushyCleanup2BIntentSealed = "hushy-cleanup-2b-r5d2blr2-4bit-enc1"

    /// The sealed twins of the two Hushy-hosted intent models (`hushy-model-seal`, docs/engineering/SEALED-MODELS.md).
    /// Same model, same tokenizer and configs; the weights are `weights-*.hse` chunks. Which entry the app
    /// delivers is `ModelTierPolicy.sealedModelsAreDefault`.
    private static let sealedEntries: [LocalModelEntry] = [
        plain(hushyCleanup4B).sealed(as: hushyCleanup4BSealed, weights: [
            ("weights-00001-of-00012.hse", 285_213_204, "10a98ee13decad2c707df98d74aecf830bb888100fa21959fe8eb1343f6f99dd"),
            ("weights-00002-of-00012.hse", 285_213_204, "8e2536d75da1840d38ffbe9169b93439adb03d11617d5ecbf758e4dbb4615593"),
            ("weights-00003-of-00012.hse", 285_213_204, "7397197d8a92fe82580503f12ec981f2131f010cb4f781746d6825a9ab4b9c52"),
            ("weights-00004-of-00012.hse", 285_213_204, "fc86aa598c80f1d22264c5b8b052083a04e35e04f6df70707b44253419b348a4"),
            ("weights-00005-of-00012.hse", 285_213_204, "a22aff7ecde79c234c58a388d47813f9eb6ed8e3a447bc7a9bdfb4755815ce3d"),
            ("weights-00006-of-00012.hse", 285_213_204, "1b69fb9e42775ecd5bf571a9ae2c1b87f8753413da2f02d9e0d152e2579b331c"),
            ("weights-00007-of-00012.hse", 285_213_204, "5c6501afc0710a4d6bead9d091c85dea15046261ee279801ac6cd01477239dc9"),
            ("weights-00008-of-00012.hse", 285_213_204, "a06cb3eb670c810bbc00205a6467a4cf059d8f22eb629628a2e7b90d85605a88"),
            ("weights-00009-of-00012.hse", 285_213_204, "180a146f751180fe8c438a8cab72dcea3e68dd2c9577a2ae791f966925ec7e70"),
            ("weights-00010-of-00012.hse", 285_213_204, "197a90394d2e9525d82d8490c45fd8b8b5744634b88ba8e26b5fdd6609ed3b3e"),
            ("weights-00011-of-00012.hse", 285_213_204, "5ba2cc925ed4ac244e618881709f159f81f725f4256a15b213cab7794767b49f"),
            ("weights-00012-of-00012.hse", 281_096_372, "66a793fdb47ed9a3e0be9ab84171fa1d6fef6a3b99988f6048586a1184680570"),
        ]),
        plain(hushyCleanup2BIntent).sealed(as: hushyCleanup2BIntentSealed, weights: [
            ("weights-00001-of-00004.hse", 285_213_204, "00affda6f151c75769197b950c0d74c94ce1999b03b69e39f4e0964ed18a8feb"),
            ("weights-00002-of-00004.hse", 285_213_204, "a8b73d368ba88c3778ce8bb431ba9f52938055537bba29a08b16a01304d92e44"),
            ("weights-00003-of-00004.hse", 285_213_204, "afb1b5d6d33381c3fa58aa07eb9514bbaba95f72f803fa8ce8c8f25ac01dbec8"),
            ("weights-00004-of-00004.hse", 203_766_996, "081e4197e8a99d2bf67e76462a922ff206da1b67129ef6eaa4e1a6294583e021"),
        ]),
    ]

    private static func plain(_ id: String) -> LocalModelEntry { plainEntries.first { $0.id == id }! }

    public static let entries: [LocalModelEntry] = plainEntries + sealedEntries

    /// The entry that delivers `entry`'s model: its sealed twin when `sealed` is on and one is registered, else
    /// `entry` itself. A sealed entry is returned as it is.
    public static func delivered(_ entry: LocalModelEntry, sealed: Bool) -> LocalModelEntry {
        guard sealed, entry.sealing == nil else { return entry }
        return entries.first { $0.sealing?.supersedes == entry.id } ?? entry
    }

    /// The plain entry a sealed entry replaces; nil for a plain entry.
    public static func plainTwin(of entry: LocalModelEntry) -> LocalModelEntry? {
        entry.sealing.flatMap { self.entry(id: $0.supersedes) }
    }

    public static func entry(id: String) -> LocalModelEntry? {
        entries.first { $0.id == id }
    }

    /// Whether the registered model `id` is sent the register note. An unknown id is not.
    public static func understandsRegisterLines(id: String) -> Bool {
        entry(id: id)?.understandsRegisterLines ?? false
    }

    /// Where an entry's files live: `<support>/Models/<id>/` (under `HUSHY_HOME` in tests).
    public static func directory(for entry: LocalModelEntry, root: URL = AppPaths.supportDirectory) -> URL {
        root.appendingPathComponent("Models", isDirectory: true).appendingPathComponent(entry.id, isDirectory: true)
    }
}
