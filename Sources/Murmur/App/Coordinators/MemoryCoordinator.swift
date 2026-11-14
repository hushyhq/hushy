import Foundation
import MurmurCore

/// Holds one prepared snapshot. A slow preparation simply misses this dictation.
@MainActor
final class MemoryCoordinator {
    /// Why a dictation did or did not get a block: one fixed word for the log, never any text.
    enum Reason: String, Sendable {
        case ok
        case paused
        /// Preparation had not finished when recognition did.
        case slow
        /// The folder could not be read.
        case unreadable
        /// The one-time copy of learned words failed; what was already in the folder was still read.
        case importFailed = "import-failed"
        /// Nothing was prepared for this dictation.
        case notPrepared = "not-prepared"
    }

    struct Shadow {
        let block: PersonBlock?
        let prepareMs: Int
        let finishMs: Int
        let ready: Bool
        let reason: Reason
        /// The person's words as they were at key-down, for the pill's name offer; nil when memory
        /// was not read in time or is paused, and then nothing is offered.
        var index: MemoryIndex?
    }

    private enum Preparation {
        case none
        case running
        case ready(PersonBlockAssembler.Prepared, importFailed: Bool)
        case unreadable
    }

    /// The lines the last finished dictation was given, for the pane to show later. In memory
    /// only: never written to disk, never logged.
    private(set) var lastUsed: (block: PersonBlock, at: Date)?

    private let memory: MemoryStore
    private var preparation = Preparation.none
    private var generation = UUID()
    private var prepareMilliseconds = 0

    init(memory: MemoryStore = .shared()) { self.memory = memory }

    func cancel() {
        generation = UUID()
        preparation = .none
        prepareMilliseconds = 0
    }

    /// Reads memory for this dictation; whether memory is used is the Pause switch's business
    /// alone. `copiesLearnedWords` is "Learn from my edits": with it off a dictation writes
    /// nothing to the folder, so the one-time copy of learned words waits. `editLife` is how long
    /// the person chose to keep their changes: older ones are removed here, paused or not.
    /// Returns at once; the task is handed back only so a test can wait for it.
    @discardableResult
    func prepare(app: String, history: Store, copiesLearnedWords: Bool, editLife: MemoryLife = .never) -> Task<Void, Never> {
        cancel()
        preparation = .running
        let current = generation
        let began = Date()
        return Task {
            var importFailed = false
            if copiesLearnedWords {
                do { try await memory.importLegacy(from: history) } catch { importFailed = true }
            }
            _ = try? await memory.prune(editLife)
            let result = try? await PersonBlockAssembler.prepare(memory: memory, history: history, app: app)
            guard generation == current else { return }
            preparation = result.map { .ready($0, importFailed: importFailed) } ?? .unreadable
            prepareMilliseconds = Int(Date().timeIntervalSince(began) * 1_000)
        }
    }

    /// In memory only, on the main actor: recall works from keys the index already holds, about a
    /// millisecond for an ordinary dictation (see `RecallKeys`).
    func finish(transcript: String) -> Shadow {
        let begin = Date()
        var prepared: PersonBlockAssembler.Prepared?
        var reason = Reason.notPrepared
        switch preparation {
        case .none: break
        case .running: reason = .slow
        case .unreadable: reason = .unreadable
        case .ready(let snapshot, let importFailed):
            prepared = snapshot
            reason = snapshot.paused ? .paused : (importFailed ? .importFailed : .ok)
        }
        let block = PersonBlockAssembler.finish(prepared, transcript: transcript)
        lastUsed = block.map { ($0, begin) }
        let shadow = Shadow(block: block, prepareMs: prepareMilliseconds,
                            finishMs: Int(Date().timeIntervalSince(begin) * 1_000), ready: prepared != nil, reason: reason,
                            index: prepared.flatMap { $0.paused ? nil : $0.index })
        cancel()
        return shadow
    }
}
