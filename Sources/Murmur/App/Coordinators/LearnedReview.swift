import Foundation
import MurmurCore
import Observation

/// The view model behind every learn-from-corrections surface: the History suggestion, the
/// Voice & style "Learned from your edits" list and the Today notice.
///
/// It owns one piece of state, the decisions made this session (`resolutions`). A decided row
/// keeps its place and reads "Added · Undo" (or "Won't suggest … again · Undo") on the surface
/// where the user decided it, which is where Undo lives (ACTIONS-IA §4: no toasts). Everything
/// else is derived from `Library.learnedItems`, which the database observation keeps live.
/// Writes go through `Actions`, so tests drive it with fakes and no database.
@MainActor
@Observable
final class LearnedReview {
    enum Outcome: Equatable, Sendable {
        /// ✓ Add on a suggestion.
        case added
        /// ✕ on a suggestion: don't suggest this again.
        case dismissed
        /// Forget on something in use, or Undo on the Today notice.
        case forgotten
    }

    /// Where the decision was made. The "· Undo" line only shows there.
    enum Host: Equatable, Sendable {
        case history, list, notice, offer
    }

    struct Resolution: Equatable, Sendable {
        /// The item exactly as it was before the tap; Undo writes this back.
        let before: LearnedItem
        let outcome: Outcome
        let host: Host
    }

    /// One row on a surface: the item as it should be described, plus its decision, if any.
    struct Row: Identifiable, Equatable {
        let item: LearnedItem
        let outcome: Outcome?
        var id: Int64 { item.id ?? -1 }
        var isPending: Bool { outcome == nil }
    }

    /// The Voice & style list: suggestions, terms in use, and per-app habits.
    struct Sections: Equatable {
        var suggestions: [Row] = []
        var inUse: [Row] = []
        var habits: [Row] = []
        var isEmpty: Bool { suggestions.isEmpty && inUse.isEmpty && habits.isEmpty }
    }

    /// The Today line: terms learned today by themselves, or the ones the user just undid.
    struct Notice: Equatable {
        let learned: [LearnedItem]
        let forgotten: [LearnedItem]
    }

    /// The marker a History list row carries: quiet, and only when there is something to act on.
    enum RowMarker: Equatable {
        case suggestion(String)
        case added(String)
    }

    /// The writes a decision makes. `live(_:)` binds them to `Library`.
    struct Actions {
        var confirm: (LearnedItem) -> Void
        var forget: (LearnedItem) -> Void
        var restore: (LearnedItem) -> Void
        var acknowledge: ([LearnedItem]) -> Void
        var deleteAll: () -> Void
    }

    private(set) var resolutions: [Int64: Resolution] = [:]
    /// The habit Today asked about this session. It stays on screen after it is marked offered, until decided.
    private(set) var offeredHabitID: Int64?
    /// Whether auto-activation (and so the Today notice) is on. Defaults to the feature flag
    /// (on unless switched off); snapshots and tests override it.
    @ObservationIgnored var isAutoActivateEnabled: () -> Bool = { FeatureFlags.autoActivateLearnedTerms }
    @ObservationIgnored private let actions: Actions

    init(actions: Actions) {
        self.actions = actions
    }

    convenience init(library: Library) {
        self.init(actions: .live(library))
    }

    // MARK: Decisions

    func add(_ item: LearnedItem, from host: Host) {
        decide(item, .added, host) { actions.confirm($0) }
    }

    func dismiss(_ item: LearnedItem, from host: Host) {
        decide(item, .dismissed, host) { actions.forget($0) }
    }

    func forget(_ item: LearnedItem, from host: Host) {
        decide(item, .forgotten, host) { actions.forget($0) }
    }

    /// Undo on a decided row: puts the item back exactly as it was and clears the decision.
    func undo(_ itemID: Int64) {
        guard let resolution = resolutions.removeValue(forKey: itemID) else { return }
        var before = resolution.before
        if resolution.host == .offer { before.announced = true }
        actions.restore(before)
    }

    /// Undo on the Today notice: stop using every term it lists.
    func undoNotice(_ notice: Notice) {
        for item in notice.learned { forget(item, from: .notice) }
    }

    /// Undo on the "Forgot …" notice line: put every term back.
    func redoNotice(_ notice: Notice) {
        for item in notice.forgotten { if let id = item.id { undo(id) } }
    }

    /// The notice has been on screen: mark its terms announced so no other surface repeats it.
    func acknowledge(_ notice: Notice) {
        let unannounced = notice.learned.filter { !$0.announced }
        guard !unannounced.isEmpty else { return }
        actions.acknowledge(unannounced)
    }

    /// The habit question has been on screen: it is never asked on Today again, whatever the answer.
    func markOffered(_ item: LearnedItem) {
        guard let id = item.id, offeredHabitID != id else { return }
        offeredHabitID = id
        if !item.announced { actions.acknowledge([item]) }
    }

    func deleteAllLearningData() {
        resolutions = [:]
        offeredHabitID = nil
        actions.deleteAll()
    }

    private func decide(_ item: LearnedItem, _ outcome: Outcome, _ host: Host, write: (LearnedItem) -> Void) {
        guard let id = item.id else { return }
        // A second decision on the same row keeps the original "before", so Undo always
        // returns to the state the user first saw.
        let before = resolutions[id]?.before ?? item
        resolutions[id] = Resolution(before: before, outcome: outcome, host: host)
        write(item)
    }

    // MARK: Derived surfaces

    /// History's suggestion card for one dictation: its ready suggestions, plus any the user
    /// decided here this session (so the row reads "Added · Undo" instead of vanishing).
    func historyRows(forDictation dictationID: Int64, items: [LearnedItem]) -> [Row] {
        let decided = resolutions.values
            .filter { $0.host == .history && $0.before.sourceDictationIDs.last == dictationID }
            .map { Row(item: $0.before, outcome: $0.outcome) }
        let pending = LearnedPresentation.historySuggestions(forDictation: dictationID, in: items)
            .filter { $0.id.map { resolutions[$0] == nil } ?? false }
            .map { Row(item: $0, outcome: nil) }
        return (pending + decided).sorted { lhs, rhs in
            (lhs.item.createdAt, lhs.id) < (rhs.item.createdAt, rhs.id)
        }
    }

    /// The quiet marker on History's list row for a dictation.
    func rowMarker(forDictation dictationID: Int64, items: [LearnedItem]) -> RowMarker? {
        let rows = historyRows(forDictation: dictationID, items: items)
        if let pending = rows.first(where: \.isPending) { return .suggestion(pending.item.value) }
        if let added = rows.first(where: { $0.outcome == .added }) { return .added(added.item.value) }
        return nil
    }

    /// The Voice & style list. Decided rows stay where they were decided; everything else is
    /// grouped by what it is now. Forgotten tombstones and not-yet-active style signals are hidden.
    func sections(items: [LearnedItem]) -> Sections {
        var sections = Sections()
        for item in items {
            guard let id = item.id else { continue }
            if let resolution = resolutions[id], resolution.host == .list {
                place(Row(item: resolution.before, outcome: resolution.outcome), basedOn: resolution.before, in: &sections)
            } else if item.status != .forgotten {
                place(Row(item: item, outcome: nil), basedOn: item, in: &sections)
            }
        }
        sections.suggestions.sort { lhs, rhs in
            lhs.item.isReadySuggestion != rhs.item.isReadySuggestion
                ? lhs.item.isReadySuggestion : lhs.item.lastSeenAt > rhs.item.lastSeenAt
        }
        return sections
    }

    private func place(_ row: Row, basedOn item: LearnedItem, in sections: inout Sections) {
        switch (item.kind, item.status) {
        case (.term, .candidate): sections.suggestions.append(row)
        case (.term, .active): sections.inUse.append(row)
        case (.styleSignal, .active): sections.habits.append(row)
        case (.styleSignal, .candidate) where item.isReadySuggestion: sections.habits.append(row)
        default: break
        }
    }

    /// Today's one habit question, or the answer given to it this session.
    func habitOffer(items: [LearnedItem]) -> Row? {
        if let decided = resolutions.values.first(where: { $0.host == .offer }) {
            return Row(item: decided.before, outcome: decided.outcome)
        }
        if let id = offeredHabitID, let item = items.first(where: { $0.id == id }), LearnedPresentation.isOfferableHabit(item) {
            return Row(item: item, outcome: nil)
        }
        return LearnedPresentation.habitOffers(in: items).first.map { Row(item: $0, outcome: nil) }
    }

    /// The Today notice, or nil when there is nothing to say (always nil while the flag is off).
    func notice(items: [LearnedItem], now: Date = Date(), calendar: Calendar = .current) -> Notice? {
        let isOn = isAutoActivateEnabled()
        guard isOn else { return nil }
        let learned = LearnedPresentation.noticeTerms(in: items, isAutoActivateOn: isOn, now: now, calendar: calendar)
            .filter { $0.id.map { resolutions[$0] == nil } ?? false }
        let forgotten = resolutions.values
            .filter { $0.host == .notice && $0.outcome == .forgotten }
            .map(\.before)
            .sorted { ($0.activatedAt ?? $0.lastSeenAt) < ($1.activatedAt ?? $1.lastSeenAt) }
        guard !learned.isEmpty || !forgotten.isEmpty else { return nil }
        return Notice(learned: learned, forgotten: forgotten)
    }
}

extension LearnedReview.Actions {
    @MainActor
    static func live(_ library: Library, memory: MemoryStore = .shared()) -> Self {
        Self(
            confirm: { [weak library] in library?.confirmLearned($0) },
            forget: { [weak library] in library?.forgetLearned($0) },
            restore: { [weak library] in library?.restoreLearned($0) },
            acknowledge: { [weak library] in library?.acknowledgeLearned($0) },
            deleteAll: { [weak library] in library?.deleteAllLearningData(memory: memory) })
    }
}

/// "Don't learn in these apps": the one place the exclusion list is edited, so the Voice &
/// style picker and tests share the same rules. Settings flow one way (UI → `AppSettings`);
/// `EditWatcher` reads the set at each capture.
@MainActor
enum LearningExclusions {
    static func exclude(_ bundleID: String, in settings: AppSettings) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !settings.learningExcludedApps.contains(trimmed) else { return }
        settings.learningExcludedApps = settings.learningExcludedApps.union([trimmed])
    }

    static func include(_ bundleID: String, in settings: AppSettings) {
        guard settings.learningExcludedApps.contains(bundleID) else { return }
        settings.learningExcludedApps = settings.learningExcludedApps.subtracting([bundleID])
    }
}
