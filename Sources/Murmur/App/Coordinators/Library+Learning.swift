import Foundation
import GRDB
import MurmurCore
import os

/// UI-facing API for the learn-from-corrections loop. Views read these properties (kept live
/// by `Library`'s database observation) and call these actions; nothing here touches the hot
/// path. Documented for the design agent in `docs/design/HANDOFF-learned-items.md`.
extension Library {
    func resolveBackwardTermReview(_ item: LearnedItem, forget: Bool) {
        guard let id = item.id else { return }
        run("review learned term") { try store.resolveBackwardTermReview(id: id, forget: forget) }
    }

    func forgetKeepHeard(_ entry: KeepHeardEntry) {
        guard let id = entry.id else { return }
        run("forget keep as heard") { _ = try store.forgetKeepHeard(id: id) }
    }

    func restoreKeepHeard(_ entry: KeepHeardEntry) {
        run("restore keep as heard") { try store.restoreKeepHeard(entry) }
    }

    /// Terms that just became active by themselves and haven't been shown yet — the notice
    /// "Learned from your edits: Priya, Kubernetes · Undo". Call `acknowledgeLearned` once shown.
    /// Always empty while `FeatureFlags.autoActivateLearnedTerms` is off (it defaults on): terms
    /// are then suggest-only and only `confirmLearned` puts them into use.
    var newlyLearnedTerms: [LearnedItem] { LearnedPersonalization.unannounced(learnedItems) }

    /// Terms awaiting the user's yes ("Add Kubernetes to your dictionary?" in History). Ready
    /// ones (`isReadySuggestion`: fixed 2+ times in 14 days) first.
    var learnedSuggestions: [LearnedItem] { LearnedPersonalization.suggestions(learnedItems) }

    /// Active learned terms and style signals, for the Voice & style screen's "Learned" list.
    var activeLearnedItems: [LearnedItem] { learnedItems.filter { $0.status == .active } }

    /// What the user's edits say about their style in one app (hint only; not applied).
    func preferenceHints(forBundleID bundleID: String?) -> PreferenceHints {
        PreferenceHints.from(learnedItems, bundleID: bundleID)
    }

    /// The user tapped "Add" on a suggestion: active now, no second edit needed.
    func confirmLearned(_ item: LearnedItem) {
        guard let id = item.id else { return }
        run("confirm learned item") { try store.confirmLearnedItem(id: id) }
    }

    /// "Undo" on the notice, or "Forget" in the list: stops using it and deletes its evidence;
    /// the same edits won't teach it again.
    func forgetLearned(_ item: LearnedItem) {
        guard let id = item.id else { return }
        run("forget learned item") { try store.forgetLearnedItem(id: id) }
    }

    /// The notice for these items has been shown.
    func acknowledgeLearned(_ items: [LearnedItem]) {
        let ids = items.compactMap(\.id)
        run("acknowledge learned items") { try store.markLearnedItemsAnnounced(ids: ids) }
    }

    /// "Delete learning data" (Settings → Privacy & data): removes every learned item,
    /// forgotten tombstones included, and from Memory everything Hushy learned and every change
    /// it kept (whatever the memory flag says now: the files may be from when it was on). What
    /// the person typed or changed in Memory stays. The rows are read before they go, because
    /// they say which words in Memory were copied from them.
    @discardableResult
    func deleteAllLearningData(memory: MemoryStore = .shared()) -> Task<Void, Never> {
        let imported = (try? MemoryStore.importedWords(in: store)) ?? []
        run("delete learning data") { try store.deleteAllLearnedItems() }
        onLexiconErase?()
        let task = Task {
            do {
                try await memory.forgetLearned(imported: imported)
            } catch {
                Logger(subsystem: "app.hushy", category: "learning")
                    .error("delete learned memory failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        learningDeletion = task
        return task
    }

    /// "Undo" on a row the user just decided (Add, ✕, Forget): writes the item back exactly as
    /// it was before that tap (status, evidence and provenance), so Undo is a true undo rather
    /// than a second decision. A row that no longer exists (Delete learning data ran in
    /// between) is left alone.
    func restoreLearned(_ snapshot: LearnedItem) {
        guard let id = snapshot.id else { return }
        run("restore learned item") {
            try store.writer.write { db in
                guard try LearnedItem.fetchOne(db, key: id) != nil else { return }
                let copy = snapshot
                try copy.update(db)
            }
        }
    }

    private func run(_ action: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            Logger(subsystem: "app.hushy", category: "learning")
                .error("\(action, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
