import Foundation
import Testing
@testable import MurmurCore

@Suite("Sealed model registry")
struct SealedModelRegistryTests {
    private static let sealedIDs = [ModelRegistry.hushyCleanup4BSealed, ModelRegistry.hushyCleanup2BIntentSealed]

    @Test("each sealed entry is its plain twin with the weights replaced by a complete set of part files")
    func twinsMirrorThePlainEntries() throws {
        for id in Self.sealedIDs {
            let sealed = try #require(ModelRegistry.entry(id: id))
            let plain = try #require(ModelRegistry.plainTwin(of: sealed))
            #expect(sealed.sealing?.supersedes == plain.id)
            #expect(sealed.logicalID == plain.id)
            #expect(plain.sealing == nil && plain.logicalID == plain.id)
            #expect(sealed.id == plain.id + "-enc1")
            for (name, value) in [("displayName", sealed.displayName == plain.displayName),
                                  ("profile", sealed.promptProfile == plain.promptProfile),
                                  ("memory", sealed.minimumMemoryGB == plain.minimumMemoryGB),
                                  ("register", sealed.understandsRegisterLines == plain.understandsRegisterLines),
                                  ("licence", sealed.license == plain.license), ("role", sealed.role == plain.role)] {
                #expect(value, "\(id) \(name)")
            }
            // The tokenizer and configs are the plain entry's own files, byte for byte.
            let isWeight: (DownloadableAsset.File) -> Bool = {
                $0.relativePath.hasSuffix(".safetensors") || $0.relativePath == "model.safetensors.index.json"
                    || $0.relativePath == "reshard-manifest.json"
            }
            let publicFiles = Dictionary(uniqueKeysWithValues: sealed.files.filter { SealedFormat.parsePartName($0.relativePath) == nil }
                .map { ($0.relativePath, [String($0.bytes), $0.sha256]) })
            let plainPublic = Dictionary(uniqueKeysWithValues: plain.files.filter { !isWeight($0) }.map { ($0.relativePath, [String($0.bytes), $0.sha256]) })
            #expect(publicFiles == plainPublic, "\(id)")
            #expect(!sealed.files.contains { $0.relativePath.hasSuffix(".safetensors") }, "no plain weights ship in a sealed entry")
            for file in sealed.files {
                #expect(file.remoteURL.absoluteString == "https://models.tryhushy.com/cleanup/\(id)/\(file.relativePath)")
            }
        }
    }

    @Test("the part files are numbered 1...N with no gap, full parts first, each under the 300 MB upload size")
    func partsAreComplete() throws {
        for id in Self.sealedIDs {
            let sealed = try #require(ModelRegistry.entry(id: id))
            let parts = sealed.files.compactMap { file in SealedFormat.parsePartName(file.relativePath).map { ($0, file) } }
                .sorted { $0.0.index < $1.0.index }
            #expect(!parts.isEmpty)
            let count = try #require(parts.first?.0.count)
            #expect(parts.map(\.0.index) == Array(1...count))
            #expect(parts.allSatisfy { $0.0.count == count })
            let full = Int64(SealedFormat.headerSize) + 17 * Int64(SealedFormat.defaultChunkSize + SealedFormat.nonceSize + SealedFormat.tagSize)
            for (position, part) in parts.enumerated() {
                #expect(part.1.bytes <= SealedFormat.defaultMaxFileBytes)
                if position < parts.count - 1 { #expect(part.1.bytes == full, "\(id) part \(position + 1)") }
            }
            // Whole records only: the stream length follows from the sizes and fits the layout the sealer used.
            let records = parts.reduce(Int64(0)) { $0 + $1.1.bytes - Int64(SealedFormat.headerSize) }
            let overhead = Int64(SealedFormat.nonceSize + SealedFormat.tagSize)
            let chunks = (records + Int64(SealedFormat.defaultChunkSize + Int(overhead)) - 1) / Int64(SealedFormat.defaultChunkSize + Int(overhead))
            let plainBytes = records - chunks * overhead
            let layout = try SealedLayout(totalPlain: plainBytes)
            #expect(layout.partCount == count, "\(id)")
            for (position, part) in parts.enumerated() { #expect(part.1.bytes == layout.fileBytes(ofPart: position), "\(id) \(position)") }
        }
    }

    @Test("ModelRegistry.delivered maps a plain entry to its sealed twin only when asked, and never maps twice")
    func delivery() throws {
        let plain4 = try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup4B))
        let sealed4 = try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup4BSealed))
        #expect(ModelRegistry.delivered(plain4, sealed: false).id == plain4.id)
        #expect(ModelRegistry.delivered(plain4, sealed: true).id == sealed4.id)
        #expect(ModelRegistry.delivered(sealed4, sealed: true).id == sealed4.id)
        // Entries with no twin are delivered as they are.
        let v54 = try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup2B))
        #expect(ModelRegistry.delivered(v54, sealed: true).id == v54.id)
    }

    @Test("with sealed delivery on the tier rule recommends the sealed twins, with it off nothing changes", arguments: [
        (16, MachineProfile.ChipClass.base, ModelRegistry.hushyCleanup2BIntent),
        (24, .base, ModelRegistry.hushyCleanup2BIntent),
        (24, .pro, ModelRegistry.hushyCleanup4B),
        (36, .max, ModelRegistry.hushyCleanup4B),
    ])
    func tierRule(memory: Int, chip: MachineProfile.ChipClass, logical: String) throws {
        let machine = MachineProfile(physicalMemoryGB: memory, chip: chip)
        #expect(ModelTierPolicy.recommendedEntryID(for: machine, sealed: false) == logical)
        #expect(ModelTierPolicy.recommendedEntryID(for: machine, sealed: true) == logical + "-enc1")
        let sealed = try #require(ModelTierPolicy.defaultIntentEntry(for: machine, sealed: true))
        #expect(sealed.sealing != nil)
        #expect(ModelTierPolicy.fit(sealed, on: machine) == .recommended, "a sealed twin fits exactly as its plain entry does")
        #expect(ModelTierPolicy.firstRunWritingDownloads(for: machine, sealed: true).allSatisfy { $0.sealing != nil })
        #expect(ModelTierPolicy.firstRunWritingDownloads(for: machine, sealed: false).allSatisfy { $0.sealing == nil })
    }

    @Test("the shipped default is plain until the roll-out switch is flipped by hand")
    func defaultIsPlainForNow() {
        #expect(ModelTierPolicy.sealedModelsAreDefault == false)
    }

    @Test("every sealed registry entry is allowlisted for download and has a key route in models-gate", .enabled(if: PrivateFiles.present("models-gate/src/allowlist.js"), "needs a private file: models-gate/src/allowlist.js"))
    func workerKnowsTheSealedModels() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("models-gate/src/allowlist.js"), encoding: .utf8)
        let block = try #require(text.components(separatedBy: "export const ENCRYPTED_MODELS").last)
        for id in Self.sealedIDs {
            #expect(block.contains("'\(id)'"), "\(id) is missing from ENCRYPTED_MODELS")
        }
        // The Worker secret for a model is named the way keys.js names it.
        for id in Self.sealedIDs {
            #expect(SealedFormat.workerSecretName(for: id) == "MODEL_KEY_" + id.uppercased().replacingOccurrences(of: "-", with: "_"))
        }
    }
}
