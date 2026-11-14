import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// Every erase path leaves no pack state file (screen sightings, pack choices) on disk, and a rebuild or a late
/// sighting cannot write it back. Temp folders and an in-memory store only; the real app folder is never touched.
@Suite("Personal lexicon: erasing the pack state")
@MainActor
struct LexiconEraseTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-lexicon-\(UUID().uuidString)", isDirectory: true)
    private var url: URL { folder.appendingPathComponent("lexicon-packs.json") }
    /// Pack names a screen could show: three distinct NBA players.
    private let screen = ["Victor Wembanyama", "Giannis Antetokounmpo", "Shai Gilgeous-Alexander"]

    private func setUp(enabled: @escaping @MainActor () -> Bool = { true }) throws -> (Library, LexiconCoordinator) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = try Store()
        let library = Library(store: store)
        let coordinator = LexiconCoordinator(store: store, keeper: PackStateKeeper(file: PackStateFile(url: url)), isEnabled: enabled)
        library.onLexiconErase = { _ = coordinator.eraseScreenEvidence() }
        return (library, coordinator)
    }

    private func recordSighting(_ coordinator: LexiconCoordinator) async {
        coordinator.recordScreen(screen)
        await coordinator.waitUntilIdle()
    }

    @Test("Erase dictation history removes the pack state file")
    func eraseHistory() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (library, coordinator) = try setUp()
        await recordSighting(coordinator)
        #expect(FileManager.default.fileExists(atPath: url.path))
        library.eraseDictationHistory()
        await coordinator.waitUntilIdle()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Delete learning data removes the pack state file")
    func deleteLearning() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (library, coordinator) = try setUp()
        await recordSighting(coordinator)
        #expect(FileManager.default.fileExists(atPath: url.path))
        await library.deleteAllLearningData(memory: MemoryStore(root: folder.appendingPathComponent("Memory"))).value
        await coordinator.waitUntilIdle()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("switching the lexicon off removes the pack state file and keeps no new sightings")
    func switchedOff() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        var enabled = true
        let (_, coordinator) = try setUp(enabled: { enabled })
        await recordSighting(coordinator)
        #expect(FileManager.default.fileExists(atPath: url.path))
        enabled = false
        coordinator.eraseScreenEvidence()
        await coordinator.waitUntilIdle()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        await recordSighting(coordinator)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(coordinator.snapshot.boostTerms().isEmpty)
    }

    @Test("a sighting read before an erase does not write the evidence back")
    func lateSightingAfterErase() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let keeper = PackStateKeeper(file: PackStateFile(url: url))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(await keeper.recordScreen(screen, epoch: 0))
        await keeper.eraseAll(epoch: 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(await !keeper.recordScreen(screen, epoch: 0))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(await keeper.recordScreen(screen, epoch: 1))
    }

    @Test("the erase finishes before the rebuild that follows it reads the state")
    func eraseThenRebuild() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (_, coordinator) = try setUp()
        await recordSighting(coordinator)
        coordinator.recordScreen(["Luka Dončić", "Nikola Jokić", "Joel Embiid"])
        coordinator.eraseScreenEvidence()
        await coordinator.waitUntilIdle()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(coordinator.snapshot.activations.allSatisfy { $0.evidenceHits == 0 })
    }
}
