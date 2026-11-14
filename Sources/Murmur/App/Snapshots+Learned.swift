import AppKit
import GRDB
import MurmurCore
import SwiftUI

/// Snapshot fixtures and captures for the learn-from-corrections surfaces (all `learned-*`):
/// the History suggestion (pending, added, dismissed, and the quiet row marker), Voice & style's
/// "Learned from your edits" list (full, a forgotten row, learning paused, empty), and the
/// Today notice (flag on, after Undo, flag off), and Today's habit question (`home-habit-offer`).
/// Kept in its own file so other agents' snapshot additions don't conflict with it. Fast loop: `HUSHY_SNAPSHOT_ONLY=learned-`.
@MainActor
enum LearnedSnapshots {
    /// Row ids the captures need, from `seed`.
    struct Seeded {
        let suggestionDictationID: Int64
        let dictationIDs: DictationIDs
    }

    struct DictationIDs {
        let slackToday: Int64
        let notesYesterday: Int64
        let notesToday: Int64
    }

    /// Dictations whose words Hushy misheard (and the user then fixed), plus learned items in
    /// every state. Runs once, before the database observations start.
    static func seed(into store: Store, settings: AppSettings) -> Seeded? {
        let now = Date()
        let slack = "com.tinyspeck.slackmacgap"
        let notes = "com.apple.Notes"
        guard
            let notesYesterday = try? store.save(Dictation(
                createdAt: now.addingTimeInterval(-86_400 - 3_600), rawText: "pria said the q3 numbers look good",
                text: "Pria said the Q3 numbers look good.", appBundleID: notes, appName: "Notes",
                durationSeconds: 2.6, latencyMs: 170, status: .inserted)).id,
            let notesToday = try? store.save(Dictation(
                createdAt: now.addingTimeInterval(-2_400),
                rawText: "move the cooper net ease upgrade after the post grass migration",
                text: "Move the cooper net ease upgrade after the post grass migration.", appBundleID: notes,
                appName: "Notes", durationSeconds: 3.8, latencyMs: 190, status: .inserted)).id,
            let slackToday = try? store.save(Dictation(
                createdAt: now.addingTimeInterval(-300), rawText: "can you loop in pria on the deck review before friday",
                text: "Can you loop in Pria on the deck review before Friday?", appBundleID: slack, appName: "Slack",
                durationSeconds: 3.1, latencyMs: 160, status: .inserted)).id
        else { return nil }
        let ids = DictationIDs(slackToday: slackToday, notesYesterday: notesYesterday, notesToday: notesToday)
        seedItems(into: store, ids: ids, now: now)
        settings.learningExcludedApps = ["com.apple.MobileSMS"]
        return Seeded(suggestionDictationID: slackToday, dictationIDs: ids)
    }

    /// The learned items alone, so the empty-state capture can delete and re-create them.
    static func seedItems(into store: Store, ids: DictationIDs, now: Date = Date()) {
        let yesterday = now.addingTimeInterval(-86_400 - 3_600)
        let items: [LearnedItem] = [
            // Ready: fixed twice ("Pria" → "Priya"), waiting for ✓ in History.
            LearnedItem(
                kind: .term, key: "priya", value: "Priya", heardAs: ["Pria"], observations: 2, confidence: 1,
                sourceDictationIDs: [ids.notesYesterday, ids.slackToday], observedAt: [yesterday, now.addingTimeInterval(-240)],
                createdAt: yesterday, lastSeenAt: now.addingTimeInterval(-240)),
            // Seen once: listed in Voice & style with a quiet Add, never surfaced in History.
            LearnedItem(
                kind: .term, key: "okta", value: "Okta", heardAs: ["octa"], observations: 1, confidence: 0.5,
                sourceDictationIDs: [ids.notesToday], observedAt: [now.addingTimeInterval(-2_300)],
                createdAt: now.addingTimeInterval(-2_300), lastSeenAt: now.addingTimeInterval(-2_300)),
            // In use by themselves today (auto-activation, the flag-on path): the Today notice.
            LearnedItem(
                kind: .term, key: "kubernetes", value: "Kubernetes", heardAs: ["cooper net ease"], status: .active,
                observations: 2, confidence: 1, sourceDictationIDs: [ids.notesYesterday, ids.notesToday],
                observedAt: [yesterday, now.addingTimeInterval(-2_200)], createdAt: yesterday,
                lastSeenAt: now.addingTimeInterval(-2_200), activatedAt: now.addingTimeInterval(-2_200)),
            LearnedItem(
                kind: .term, key: "postgres", value: "Postgres", heardAs: ["post grass"], status: .active,
                observations: 2, confidence: 1, sourceDictationIDs: [ids.slackToday, ids.notesToday],
                observedAt: [now.addingTimeInterval(-2_600), now.addingTimeInterval(-2_150)],
                createdAt: now.addingTimeInterval(-2_600), lastSeenAt: now.addingTimeInterval(-2_150),
                activatedAt: now.addingTimeInterval(-2_150)),
            // Added by the user from a suggestion three days ago.
            LearnedItem(
                kind: .term, key: "grafana", value: "Grafana", heardAs: ["Graphana"], status: .active, observations: 1,
                confirmed: true, confidence: 1, sourceDictationIDs: [ids.notesYesterday], observedAt: [yesterday],
                createdAt: now.addingTimeInterval(-4 * 86_400), lastSeenAt: now.addingTimeInterval(-3 * 86_400),
                activatedAt: now.addingTimeInterval(-3 * 86_400), announced: true),
            // Per-app habits (hints only).
            LearnedItem(
                kind: .styleSignal, key: "format:lowercased", value: "format:lowercased",
                appBundleID: "com.tinyspeck.slackmacgap", status: .active, observations: 3, confidence: 1,
                createdAt: now.addingTimeInterval(-9 * 86_400), lastSeenAt: now.addingTimeInterval(-86_400),
                activatedAt: now.addingTimeInterval(-86_400), announced: true),
            LearnedItem(
                kind: .styleSignal, key: "keep:actually", value: "keep:actually", appBundleID: "com.apple.Notes",
                status: .active, observations: 3, confidence: 1, createdAt: now.addingTimeInterval(-12 * 86_400),
                lastSeenAt: now.addingTimeInterval(-2 * 86_400), activatedAt: now.addingTimeInterval(-2 * 86_400),
                announced: true),
            // Forgotten tombstone: never shown anywhere.
            LearnedItem(kind: .term, key: "figgy", value: "Figgy", status: .forgotten, announced: true),
        ]
        _ = try? store.writer.write { db in
            for item in items {
                var copy = item
                try copy.insert(db)
            }
        }
    }

    typealias Capture = @MainActor (_ view: AnyView, _ name: String, _ size: CGSize, _ fixedSize: Bool) async -> Void

    /// Every learned surface in one color scheme. `capture` is `Snapshots.capture` bound to the
    /// scheme and output directory.
    static func render(model: AppModel, seeded: Seeded, size: CGSize, capture: Capture) async {
        await renderHistory(model: model, seeded: seeded, size: size, capture: capture)
        await renderCards(model: model, seeded: seeded, capture: capture)
        await renderVoiceStyle(model: model, seeded: seeded, size: size, capture: capture)
        await renderNotice(model: model, size: size, capture: capture)
        await renderHabitOffer(model: model, seeded: seeded, capture: capture)
    }

    private static func page(_ model: AppModel, historyDetail: Int64? = nil, tab: VoiceAndStyleView.Tab? = nil) -> AnyView {
        AnyView(MainView().environment(model)
            .environment(\.snapshotHistoryDetailID, historyDetail)
            .environment(\.snapshotVoiceStyleTab, tab))
    }

    private static func renderHistory(model: AppModel, seeded: Seeded, size: CGSize, capture: Capture) async {
        model.section = .history
        let id = seeded.suggestionDictationID
        await capture(page(model, historyDetail: id), "learned-history-suggestion", size, false)
        guard let priya = item("priya", in: model) else { return }
        // Through the real path: ✓ Add writes the store, the observation delivers, the row reads
        // "Added · Undo"; then Undo restores it.
        model.learned.add(priya, from: .history)
        await settle()
        await capture(page(model, historyDetail: id), "learned-history-added", size, false)
        model.learned.undo(priya.id ?? -1)
        await settle()
    }

    /// The card alone in each state, at the detail pane's measure.
    private static func renderCards(model: AppModel, seeded: Seeded, capture: Capture) async {
        guard let priya = item("priya", in: model) else { return }
        let states: [(String, LearnedReview.Outcome?)] = [("pending", nil), ("added", .added), ("dismissed", .dismissed)]
        for (name, outcome) in states {
            let card = LearnedSuggestionCardContent(
                rows: [LearnedReview.Row(item: priya, outcome: outcome)], onAdd: { _ in }, onDismiss: { _ in }, onUndo: { _ in })
                .padding(Theme.Space.xl)
                .background(Theme.bgBase)
                .environment(model)
            await capture(AnyView(card), "learned-card-\(name)", CGSize(width: 600, height: 150), true)
        }
        // A suggestion Hushy has no mishearing for (typed-back term) reads without the arrow.
        var plain = priya
        plain.heardAs = []
        plain.value = "Ada"
        plain.observations = 3
        let card = LearnedSuggestionCardContent(
            rows: [LearnedReview.Row(item: plain, outcome: nil)], onAdd: { _ in }, onDismiss: { _ in }, onUndo: { _ in })
            .padding(Theme.Space.xl)
            .background(Theme.bgBase)
        await capture(AnyView(card), "learned-card-no-heard-as", CGSize(width: 600, height: 150), true)
    }

    private static func renderVoiceStyle(model: AppModel, seeded: Seeded, size: CGSize, capture: Capture) async {
        model.section = .style
        await capture(page(model, tab: .dictionary), "learned-voice-style", size, false)

        if let kubernetes = item("kubernetes", in: model), let okta = item("okta", in: model) {
            model.learned.forget(kubernetes, from: .list)
            model.learned.add(okta, from: .list)
            await settle()
            await capture(page(model, tab: .dictionary), "learned-voice-style-decided", size, false)
            model.learned.undo(kubernetes.id ?? -1)
            model.learned.undo(okta.id ?? -1)
            await settle()
        }

        model.settings.learnFromEdits = false
        await capture(page(model, tab: .dictionary), "learned-voice-style-paused", size, false)
        model.settings.learnFromEdits = true

        try? model.store.deleteAllLearnedItems()
        await settle()
        await capture(page(model, tab: .dictionary), "learned-voice-style-empty", size, false)
        seedItems(into: model.store, ids: seeded.dictationIDs)
        await settle()
    }

    private static func renderNotice(model: AppModel, size: CGSize, capture: Capture) async {
        model.section = .home
        let flag = model.learned.isAutoActivateEnabled
        // Flag off (the shipped default): no notice, even with auto-activated terms present.
        model.learned.isAutoActivateEnabled = { false }
        await capture(page(model), "learned-home-flag-off", size, false)
        model.learned.isAutoActivateEnabled = { true }
        await capture(page(model), "learned-home-notice", size, false)
        if let notice = model.learned.notice(items: model.library.learnedItems) {
            model.learned.undoNotice(notice)
            await settle()
            await capture(page(model), "learned-home-notice-undone", size, false)
            if let undone = model.learned.notice(items: model.library.learnedItems) {
                model.learned.redoNotice(undone)
            }
            await settle()
        }
        model.learned.isAutoActivateEnabled = flag
    }

    private static func insert(_ item: LearnedItem, into store: Store) {
        _ = try? store.writer.write { db in
            var copy = item
            try copy.insert(db)
        }
    }

    /// Today with one ready habit waiting for an answer, on the same fixture feed as `home-today-few`.
    private static func renderHabitOffer(model: AppModel, seeded: Seeded, capture: Capture) async {
        let now = Date()
        let habit = LearnedItem(
            kind: .styleSignal, key: "format:noGreeting", value: "format:noGreeting",
            appBundleID: "com.tinyspeck.slackmacgap", observations: 4, confidence: 1,
            createdAt: now.addingTimeInterval(-6 * 86_400), lastSeenAt: now.addingTimeInterval(-3_600))
        insert(habit, into: model.store)
        await settle()
        let calendar = Calendar.current
        let feed = HomeFixtures.feed(
            calendar: calendar, today: .few,
            expansion: HomeExpansion(day: calendar.startOfDay(for: HomeFixtures.now(calendar))))
        model.section = .home
        let page = AnyView(MainView().environment(model).environment(\.snapshotHomeFeed, feed))
        await capture(page, "home-habit-offer", CGSize(width: 1320, height: 2000), false)
        try? model.store.deleteAllLearnedItems()
        seedItems(into: model.store, ids: seeded.dictationIDs)
        await settle()
    }

    private static func item(_ key: String, in model: AppModel) -> LearnedItem? {
        model.library.learnedItems.first { $0.key == key }
    }

    /// Lets the database observation deliver a write before the next capture.
    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(400))
    }
}
