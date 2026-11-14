import Foundation
import MurmurCore
import os

/// Keeps the personal lexicon current for dictation, always off the hot path: History, learning or a screen
/// sighting asks for a rebuild, the rebuild reads the database and the pack state file in the background, and the
/// finished `LexiconSnapshot` is handed to `onChange` on the main actor. A dictation only ever reads that snapshot.
///
/// Every write to the pack state (a sighting, a choice, an erase) and every rebuild runs one after another on one
/// chain, so a rebuild cannot race an erase. An erase also starts a new epoch: a sighting read before the erase
/// that arrives after it is dropped instead of writing the evidence back.
@MainActor
final class LexiconCoordinator {
    private let store: Store
    private let keeper: PackStateKeeper
    private let isEnabled: @MainActor () -> Bool
    private var pending: Task<Void, Never>?
    private var chain: Task<Void, Never>?
    /// Raised by every erase; a sighting carries the epoch it was read in.
    private var epoch = 0
    private(set) var snapshot = LexiconSnapshot.empty
    var onChange: ((LexiconSnapshot) -> Void)?
    private nonisolated static let log = Logger(subsystem: "app.hushy", category: "lexicon")
    /// History changes come in bursts (a dictation is saved, then its edit state); one rebuild covers a burst.
    static let debounce: Duration = .seconds(2)

    init(store: Store, keeper: PackStateKeeper = PackStateKeeper(), isEnabled: @escaping @MainActor () -> Bool) {
        self.store = store
        self.keeper = keeper
        self.isEnabled = isEnabled
    }

    func scheduleRebuild() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.enqueue { await $0.rebuild() }
        }
    }

    /// The screen terms one dictation read: which pack names they hold is kept (indices only), the terms are not.
    func recordScreen(_ terms: [String]) {
        guard isEnabled(), !terms.isEmpty else { return }
        let read = epoch
        enqueue { coordinator in
            if await coordinator.keeper.recordScreen(terms, epoch: read) { coordinator.scheduleRebuild() }
        }
    }

    func setChoice(_ choice: PackChoice, forPack id: String) {
        enqueue { coordinator in
            await coordinator.keeper.setChoice(choice, forPack: id)
            await coordinator.rebuild()
        }
    }

    /// Erases every screen sighting and pack choice (the pack state file), then rebuilds from what is left. History
    /// evidence is never stored, so erasing History erases it. Called by "Erase dictation history", "Delete learning
    /// data", and when the lexicon is switched off.
    @discardableResult
    func eraseScreenEvidence() -> Task<Void, Never> {
        pending?.cancel()
        epoch += 1
        let next = epoch
        return enqueue { coordinator in
            await coordinator.keeper.eraseAll(epoch: next)
            await coordinator.rebuild()
        }
    }

    /// Resolves once every queued write and rebuild has finished (tests, and callers that must see the result).
    func waitUntilIdle() async {
        while let current = chain {
            await current.value
            if chain == current { return }
        }
    }

    @discardableResult
    private func enqueue(_ work: @escaping @MainActor (LexiconCoordinator) async -> Void) -> Task<Void, Never> {
        let previous = chain
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
        }
        chain = task
        return task
    }

    private func rebuild() async {
        guard isEnabled() else {
            // Switched off ("Learn from my edits" or the kill switch): nothing learned is kept, nothing is boosted.
            epoch += 1
            await keeper.eraseAll(epoch: epoch)
            publish(.empty)
            return
        }
        let store = store
        let keeper = keeper
        let built: LexiconSnapshot? = await Task.detached(priority: .utility) {
            do {
                var inputs = try store.lexiconInputs()
                inputs.packState = await keeper.current
                return PersonalLexicon.build(inputs)
            } catch {
                Self.log.error("lexicon rebuild failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }.value
        guard let built else { return }
        // Counts only: how many terms, which packs are on.
        let active = built.activePacks.map(\.id).joined(separator: ",")
        Self.log.notice("lexicon rebuilt: terms=\(built.terms.count) boost=\(built.boostTerms().count) packs=[\(active, privacy: .public)]")
        publish(built)
    }

    private func publish(_ built: LexiconSnapshot) {
        guard built != snapshot else { return }
        snapshot = built
        onChange?(built)
    }
}
