import Foundation
import Testing
@testable import MurmurCore

/// M4: every registry entry is pinned, hashed and licensed; M5: the RAM-tier rule.
@Suite("Model registry")
struct ModelRegistryTests {
    private static func isHex(_ text: String, length: Int) -> Bool {
        text.count == length && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    @Test("ids are unique and every entry has a pinned revision, files with SHA-256 and sizes")
    func entriesArePinnedAndHashed() throws {
        let ids = ModelRegistry.entries.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ModelRegistry.entries.count == 8, "six plain entries and the sealed twins of the two Hushy-hosted intent models")
        for entry in ModelRegistry.entries {
            #expect(entry.logicalID == ModelRegistry.hushyCleanup2B ? entry.source.revision == "v5.4"
                : (entry.logicalID == ModelRegistry.hushyCleanup4B ? entry.source.revision == "r10d"
                    : entry.logicalID == ModelRegistry.hushyCleanup2BIntent ? entry.source.revision == "r5d2blr2"
                    : Self.isHex(entry.source.revision, length: 40)), "\(entry.id) revision")
            #expect(!entry.files.isEmpty)
            #expect(Set(entry.files.map(\.relativePath)).count == entry.files.count)
            for file in entry.files {
                #expect(Self.isHex(file.sha256, length: 64), "\(entry.id)/\(file.relativePath) sha256")
                #expect(file.bytes > 0)
                // Pinned by commit, never a moving branch.
                if entry.id == ModelRegistry.hushyCleanup2B || entry.promptProfile == .intent {
                    #expect(file.remoteURL.absoluteString == "https://models.tryhushy.com/cleanup/\(entry.id)/\(file.relativePath)")
                } else {
                    #expect(file.remoteURL.absoluteString
                        == "https://huggingface.co/\(entry.source.repo)/resolve/\(entry.source.revision)/\(file.relativePath)")
                }
            }
            #expect(entry.downloadBytes == entry.files.reduce(0) { $0 + $1.bytes })
        }
    }

    @Test("the promoted v5.4 conversion has exactly six pinned R2 files")
    func promotedFiles() throws {
        let entry = try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup2B))
        let expected: [String: (Int64, String)] = [
            "config.json": (2_804, "92ede1d4c6a86fd4970cfbcac82bfcc2c628a85cb0015f147d4e557595a0eb04"),
            "chat_template.jinja": (7_755, "273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80"),
            "tokenizer_config.json": (1_161, "95c557768e6b88a7128befc7bfd3c7de50e5d51af9b8b33a9f4dee0e04f99679"),
            "tokenizer.json": (19_989_325, "06b9509352d2af50381ab2247e083b80d32d5c0aba91c272ca9ff729b6a0e523"),
            "model.safetensors.index.json": (68_404, "dd59028c62dfa40a75858129924bdc3dd96f6df4355153f7259d30bd7fdbfd72"),
            "model-00001-of-00004.safetensors": (293_497_134, "1891e9842036bdcf352d5491c605e8c50b9a1d9cd7542ad9e08b58964dcbaf53"),
            "model-00002-of-00004.safetensors": (293_266_928, "3c03135db6744dd2e8d8d2a92607581459b014fc3c18d03322d6737e937f180a"),
            "model-00003-of-00004.safetensors": (290_165_798, "20445d8107d1d62dba11ceeb0e83c2ae79f8a4d1dcd29418ebb8149a6a086a01"),
            "model-00004-of-00004.safetensors": (182_474_051, "244d9aa934da3cccefede2480c83272cf6d7b6a5cfb3c19e5ffda8a84f4a5b88"),
        ]
        #expect(entry.files.count == 9)
        for file in entry.files {
            let pinned = try #require(expected[file.relativePath])
            #expect(file.bytes == pinned.0)
            #expect(file.sha256 == pinned.1)
            #expect(file.remoteURL.absoluteString.hasPrefix("https://models.tryhushy.com/cleanup/hushy-cleanup-2b-v5.4-4bit/"))
        }
        #expect(entry.downloadBytes == 1_079_473_360)
        #expect(entry.promptProfile == .compact)
        #expect(entry.role == .cleanupDefault)
        #expect(ModelRegistry.entries.filter { $0.role == .cleanupDefault }.count == 1)
    }

    @Test("the 4B intent model is optional, 24 GB minimum, and every hosted shard fits the upload limit")
    func intentEntry() throws {
        let entry = try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup4B))
        #expect(entry.promptProfile == .intent)
        #expect(entry.role == .candidate)
        #expect(entry.bits == 6)
        #expect(entry.minimumMemoryGB == 24)
        #expect(entry.residentMegabytes == 4_400)
        #expect(entry.license == ModelRegistry.entry(id: ModelRegistry.hushyCleanup2B)?.license)
        #expect(entry.files.filter { $0.relativePath.hasSuffix(".safetensors") }.count == 12)
        #expect(entry.files.allSatisfy { !$0.relativePath.hasSuffix(".safetensors") || $0.bytes <= 290 * 1_048_576 })
    }

    @Test("2B intent conversion pins every file and follows the 4B intent entry shape")
    func twoBIntentEntry() throws {
        let entry = try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup2BIntent))
        let fourB = try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup4B))
        let expected: [String: (Int64, String)] = [
            "chat_template.jinja": (7_755, "273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80"),
            "config.json": (2_804, "92ede1d4c6a86fd4970cfbcac82bfcc2c628a85cb0015f147d4e557595a0eb04"),
            "generation_config.json": (116, "62153eb6c69f2e1f426beaa8002b7186437e949c7588167085df14e10e9c0a73"),
            "model-00001-of-00004.safetensors": (302_979_349, "1f8f29699c9c533888116edfdab7e2bcf3f3bbee4ab272ee1bdf2fdbc1631b6d"),
            "model-00002-of-00004.safetensors": (300_179_403, "ba0629e2b999b75a3bced73d5b7a5abb3a2142301d20da120ca05ed09d29e172"),
            "model-00003-of-00004.safetensors": (298_360_380, "121cf13b0d684d46f1f5021435f1e61071a3188f9e3a2c6d788c3c66a603cdd0"),
            "model-00004-of-00004.safetensors": (157_884_831, "98bd2ee3d0513a8653606826211865ae365af2f99673067e09a0363ac8e18b4a"),
            "model.safetensors.index.json": (64_184, "41436560e086e198f9dc170f7eb5f0135082cc1d47f6b0718b0ff26ed755ceba"),
            "reshard-manifest.json": (61, "7dd59241bf039171979b520190e2f5f32e3ba60ebe7299a1e2c7e1d9c4281b22"),
            "tokenizer.json": (19_989_325, "06b9509352d2af50381ab2247e083b80d32d5c0aba91c272ca9ff729b6a0e523"),
            "tokenizer_config.json": (1_161, "95c557768e6b88a7128befc7bfd3c7de50e5d51af9b8b33a9f4dee0e04f99679"),
        ]
        #expect(entry.files.count == expected.count)
        for file in entry.files {
            let pinned = try #require(expected[file.relativePath])
            #expect(file.bytes == pinned.0)
            #expect(file.sha256 == pinned.1)
        }
        let supportingFiles = Set(entry.files.filter { !$0.relativePath.hasSuffix(".safetensors") }.map(\.relativePath))
        #expect(supportingFiles == Set(fourB.files.filter { !$0.relativePath.hasSuffix(".safetensors") }.map(\.relativePath)))
        #expect(entry.files.filter { $0.relativePath.hasSuffix(".safetensors") }.count == 4)
        #expect(entry.files.allSatisfy { !$0.relativePath.hasSuffix(".safetensors") || $0.bytes <= 290 * 1_048_576 })
        #expect(entry.promptProfile == fourB.promptProfile)
        #expect(entry.speculation == fourB.speculation)
        #expect(entry.role == fourB.role)
        #expect(entry.source.textOnly && fourB.source.textOnly)
        #expect(entry.license == fourB.license)
        #expect(entry.minimumMemoryGB == 16)
        #expect(entry.residentMegabytes == 1_500)
    }

    @Test("every entry carries the files the MLX loader needs")
    func requiredFiles() {
        for entry in ModelRegistry.entries {
            let paths = Set(entry.files.map(\.relativePath))
            for required in ["config.json", "tokenizer.json", "tokenizer_config.json", "chat_template.jinja"] {
                #expect(paths.contains(required), "\(entry.id) lacks \(required)")
            }
            // Weights: one model.safetensors, or an index plus its shards (R2 caps uploads near 300 MiB).
            let shards = paths.filter { $0.hasPrefix("model-") && $0.hasSuffix(".safetensors") }
            let sealedParts = paths.filter { SealedFormat.parsePartName($0) != nil }
            let hasWeights = paths.contains("model.safetensors")
                || (paths.contains("model.safetensors.index.json") && !shards.isEmpty)
                || (entry.sealing != nil && !sealedParts.isEmpty)
            #expect(hasWeights, "\(entry.id) lacks weights")
        }
    }

    @Test("licences are Apache-2.0 and the licence text ships in the repo")
    func licenses() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for entry in ModelRegistry.entries {
            #expect(entry.license.spdx == "Apache-2.0")
            let text = try String(
                contentsOf: root.appendingPathComponent("Resources/Licenses/\(entry.license.bundledTextFile)"), encoding: .utf8)
            #expect(text.contains("Apache License"))
            #expect(text.contains("Version 2.0"))
        }
    }

    @Test("entries are prompt-profiled, speculative, sized for their tier, and queue as accept-to-start cleanup assets")
    func entryShape() {
        for entry in ModelRegistry.entries {
            let expectedProfile: LocalModelEntry.PromptProfile = entry.logicalID == ModelRegistry.hushyCleanup4B || entry.logicalID == ModelRegistry.hushyCleanup2BIntent
                ? .intent : (entry.role == .cleanupDefault ? .compact : .production)
            #expect(entry.promptProfile == expectedProfile)
            #expect(entry.speculation == (entry.promptProfile != .intent))
            #expect(entry.residentMegabytes > 0)
            let asset = entry.asset
            #expect(asset.kind == .cleanupModel)
            #expect(asset.importance == .optional)
            #expect(asset.startPolicy == .whenAccepted)
            #expect(asset.expectedBytes == entry.downloadBytes)
            #expect(LocalModelEntry.entryID(forAssetID: asset.id) == entry.id)
        }
        #expect(ModelRegistry.entry(id: ModelRegistry.qwen08B4bit)?.minimumMemoryGB == 8)
        #expect(ModelRegistry.entry(id: ModelRegistry.qwen2B6bit)?.minimumMemoryGB == 16)
        #expect(LocalModelEntry.entryID(forAssetID: "speech-model") == nil)
    }

    @Test("models live under <support>/Models/<id>")
    func directory() throws {
        let entry = try #require(ModelRegistry.entry(id: ModelRegistry.qwen08B4bit))
        let root = URL(fileURLWithPath: "/tmp/hushy-test-root")
        #expect(ModelRegistry.directory(for: entry, root: root).path == "/tmp/hushy-test-root/Models/qwen3.5-0.8b-4bit")
    }
}

@Suite("Model tier policy")
struct ModelTierPolicyTests {
    @Test("intent default switch selects models by memory and chip", arguments: [
        (8, MachineProfile.ChipClass.base, ModelRegistry.qwen08B4bit, ModelRegistry.qwen08B4bit),
        (16, .base, ModelRegistry.hushyCleanup2B, ModelRegistry.hushyCleanup2BIntent),
        (16, .pro, ModelRegistry.hushyCleanup2B, ModelRegistry.hushyCleanup2BIntent),
        (24, .base, ModelRegistry.hushyCleanup2B, ModelRegistry.hushyCleanup2BIntent),
        (24, .pro, ModelRegistry.hushyCleanup2B, ModelRegistry.hushyCleanup4B),
        (24, .max, ModelRegistry.hushyCleanup2B, ModelRegistry.hushyCleanup4B),
        (32, .ultra, ModelRegistry.hushyCleanup2B, ModelRegistry.hushyCleanup4B),
        (18, .max, ModelRegistry.hushyCleanup2B, ModelRegistry.hushyCleanup2BIntent),
        (24, .unknown, ModelRegistry.qwen08B4bit, ModelRegistry.qwen08B4bit),
    ])
    func intentDefaultSwitch(memory: Int, chip: MachineProfile.ChipClass, old: String, intent: String) {
        let machine = MachineProfile(physicalMemoryGB: memory, chip: chip)
        #expect(ModelTierPolicy.recommended(for: machine, useIntentModels: false).id == old)
        #expect(ModelTierPolicy.recommended(for: machine, useIntentModels: true).id == intent)
    }

    @Test("the 4B is the default only on 24 GB+ Pro/Max/Ultra Macs; the way back to the 2B stays", arguments: [
        (8, MachineProfile.ChipClass.base, nil as String?, nil as String?),
        (8, .pro, nil, nil),
        (16, .base, ModelRegistry.hushyCleanup2BIntent, ModelRegistry.hushyCleanup2BIntent),
        (16, .pro, ModelRegistry.hushyCleanup2BIntent, ModelRegistry.hushyCleanup2BIntent),
        (24, .base, ModelRegistry.hushyCleanup2BIntent, ModelRegistry.hushyCleanup2BIntent),
        (24, .pro, ModelRegistry.hushyCleanup4B, ModelRegistry.hushyCleanup2BIntent),
        (24, .max, ModelRegistry.hushyCleanup4B, ModelRegistry.hushyCleanup2BIntent),
        (48, .ultra, ModelRegistry.hushyCleanup4B, ModelRegistry.hushyCleanup2BIntent),
        (24, .unknown, nil, nil),
    ])
    func defaultIntentEntry(memory: Int, chip: MachineProfile.ChipClass, expected: String?, expectedWith2BPreferred: String?) {
        let machine = MachineProfile(physicalMemoryGB: memory, chip: chip)
        #expect(ModelTierPolicy.defaultIntentEntry(for: machine)?.id == expected)
        #expect(ModelTierPolicy.defaultIntentEntry(for: machine, prefer2B: true)?.id == expectedWith2BPreferred)
        #expect(ModelTierPolicy.intentEntry(for: machine)?.id == expected)
        #expect(ModelTierPolicy.qualifiesFor4BIntent(machine) == (expected == ModelRegistry.hushyCleanup4B))
    }

    @Test("on a 4B Mac the 2B intent model is an override with a reason; preferring the 2B makes it the recommendation")
    func fitOnFourBMac() throws {
        let machine = MachineProfile(physicalMemoryGB: 24, chip: .pro)
        let four = try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup4B))
        let two = try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup2BIntent))
        #expect(ModelTierPolicy.fit(four, on: machine) == .recommended)
        guard case .override(let warning) = ModelTierPolicy.fit(two, on: machine) else {
            Issue.record("expected an override"); return
        }
        #expect(warning.contains("4B"))
        #expect(ModelTierPolicy.fit(two, on: machine, prefer2B: true) == .recommended)
        // A 16 GB Mac cannot take the 4B as a recommendation, and its warning is about memory.
        let small = MachineProfile(physicalMemoryGB: 16, chip: .pro)
        guard case .override(let memoryWarning) = ModelTierPolicy.fit(four, on: small) else {
            Issue.record("expected an override"); return
        }
        #expect(memoryWarning.contains("16 GB"))
        #expect(four.chipNotes.contains("24 GB"))
        #expect(!four.chipNotes.contains("off by default") && !two.chipNotes.contains("off by default"))
    }

    @Test("a fresh install's writing downloads follow the Mac: none under 16 GB, the 2B, or the 2B then the 4B", arguments: [
        (8, MachineProfile.ChipClass.base, [String]()),
        (16, .base, [ModelRegistry.hushyCleanup2BIntent]),
        (16, .pro, [ModelRegistry.hushyCleanup2BIntent]),
        (24, .base, [ModelRegistry.hushyCleanup2BIntent]),
        (24, .pro, [ModelRegistry.hushyCleanup2BIntent, ModelRegistry.hushyCleanup4B]),
        (64, .max, [ModelRegistry.hushyCleanup2BIntent, ModelRegistry.hushyCleanup4B]),
    ])
    func firstRunWritingDownloads(memory: Int, chip: MachineProfile.ChipClass, expected: [String]) {
        let machine = MachineProfile(physicalMemoryGB: memory, chip: chip)
        #expect(ModelTierPolicy.firstRunWritingDownloads(for: machine).map(\.id) == expected)
    }

    @Test("prefer2B keeps a Pro/Max Mac on the 2B alone, and the sizes are the registry's")
    func firstRunWritingDownloadSizes() {
        let machine = MachineProfile(physicalMemoryGB: 36, chip: .pro)
        #expect(ModelTierPolicy.firstRunWritingDownloads(for: machine, prefer2B: true).map(\.id)
            == [ModelRegistry.hushyCleanup2BIntent])
        let total = ModelTierPolicy.firstRunWritingDownloads(for: machine).reduce(Int64(0)) { $0 + $1.downloadBytes }
        // About 1.08 GB (2B) plus about 3.44 GB (4B).
        #expect(total > 4_400_000_000 && total < 4_650_000_000, "got \(total)")
    }

    @Test("RAM tier × chip → recommended model", arguments: [
        (8, MachineProfile.ChipClass.base, ModelRegistry.qwen08B4bit),
        (8, .pro, ModelRegistry.qwen08B4bit),
        (16, .base, ModelRegistry.hushyCleanup2BIntent),
        (24, .unknown, ModelRegistry.qwen08B4bit),
        (16, .pro, ModelRegistry.hushyCleanup2BIntent),
        (24, .base, ModelRegistry.hushyCleanup2BIntent),
        (24, .pro, ModelRegistry.hushyCleanup4B),
        (36, .max, ModelRegistry.hushyCleanup4B),
        (64, .ultra, ModelRegistry.hushyCleanup4B),
    ])
    func recommendation(memory: Int, chip: MachineProfile.ChipClass, expected: String) {
        let machine = MachineProfile(physicalMemoryGB: memory, chip: chip)
        #expect(ModelTierPolicy.recommendedEntryID(for: machine) == expected)
        #expect(ModelTierPolicy.recommended(for: machine).id == expected)
        #expect(ModelTierPolicy.fit(ModelTierPolicy.recommended(for: machine), on: machine) == .recommended)
    }

    @Test("promotion requires Apple silicon above the 8 GB tier")
    func promotion() throws {
        for (memory, chip, expected) in [
            (8, MachineProfile.ChipClass.base, false), (16, .base, true),
            (16, .pro, true), (24, .max, true), (32, .unknown, false),
        ] {
            let machine = MachineProfile(physicalMemoryGB: memory, chip: chip)
            #expect(ModelTierPolicy.promotedEntry(for: machine)?.id == (expected ? ModelRegistry.hushyCleanup2B : nil))
        }
        let base = MachineProfile(physicalMemoryGB: 16, chip: .base)
        // The intent 2B is the default now; the old promoted model is no longer the recommendation.
        let entry = try #require(ModelTierPolicy.promotedEntry(for: base))
        #expect(ModelTierPolicy.fit(entry, on: base) != .recommended)
        #expect(ModelTierPolicy.fit(ModelTierPolicy.recommended(for: base), on: base) == .recommended)
    }

    @Test("overrides are allowed with a warning that names the cost")
    func overrideWarnings() throws {
        let small = MachineProfile(physicalMemoryGB: 8, chip: .base)
        let big2B = try #require(ModelRegistry.entry(id: ModelRegistry.qwen2B6bit))
        guard case .override(let memoryWarning) = ModelTierPolicy.fit(big2B, on: small) else {
            Issue.record("2B on 8 GB must warn"); return
        }
        #expect(memoryWarning.contains("8 GB"))

        let baseChip = MachineProfile(physicalMemoryGB: 16, chip: .base)
        let q4 = try #require(ModelRegistry.entry(id: ModelRegistry.qwen2B4bit))
        guard case .override = ModelTierPolicy.fit(q4, on: baseChip) else {
            Issue.record("unpromoted 2B remains an override"); return
        }

        let pro = MachineProfile(physicalMemoryGB: 24, chip: .pro)
        let small08 = try #require(ModelRegistry.entry(id: ModelRegistry.qwen08B4bit))
        guard case .override = ModelTierPolicy.fit(small08, on: pro) else {
            Issue.record("0.8B on a Pro is an override"); return
        }
    }

    @Test("chip class from the CPU brand string")
    func chipClass() {
        #expect(MachineProfile.chipClass(brand: "Apple M1") == .base)
        #expect(MachineProfile.chipClass(brand: "Apple M4 Pro") == .pro)
        #expect(MachineProfile.chipClass(brand: "Apple M2 Max") == .max)
        #expect(MachineProfile.chipClass(brand: "Apple M1 Ultra") == .ultra)
        #expect(MachineProfile.chipClass(brand: "Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz") == .unknown)
        #expect(MachineProfile.chipClass(brand: "") == .unknown)
        #expect(MachineProfile.current().physicalMemoryGB > 0)
    }

    @Test("idle unload after 120 s on ≤ 8 GB only")
    func idlePolicy() {
        #expect(ModelTierPolicy.idleUnloadSeconds(for: MachineProfile(physicalMemoryGB: 8, chip: .base)) == 120)
        #expect(ModelTierPolicy.idleUnloadSeconds(for: MachineProfile(physicalMemoryGB: 16, chip: .base)) == nil)
    }

    @Test("guidance names the download and the resident memory")
    func guidance() throws {
        let entry = try #require(ModelRegistry.entry(id: ModelRegistry.qwen08B4bit))
        #expect(ModelTierPolicy.guidance(for: entry) == "645 MB download · about 580 MB of memory while loaded")
    }
}
