import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The learn-from-corrections view model: which suggestion History shows, what ✓ Add, ✕,
/// Forget and Undo write, the Today notice's flag gating, and the learning settings.
@Suite("Learned review")
@MainActor
struct LearnedReviewTests {
    /// Records every write the view model asks for, instead of touching a database.
    final class Writes {
        var confirmed: [LearnedItem] = []
        var forgotten: [LearnedItem] = []
        var restored: [LearnedItem] = []
        var acknowledged: [[LearnedItem]] = []
        var deletedAll = 0

        var actions: LearnedReview.Actions {
            LearnedReview.Actions(
                confirm: { self.confirmed.append($0) }, forget: { self.forgotten.append($0) },
                restore: { self.restored.append($0) }, acknowledge: { self.acknowledged.append($0) },
                deleteAll: { self.deletedAll += 1 })
        }
    }

    private let now = Date(timeIntervalSinceReferenceDate: 812_000_000)

    private func term(
        _ id: Int64, _ value: String, heard: [String] = [], status: LearnedItem.Status = .candidate,
        observations: Int = 2, confidence: Double = 1, sources: [Int64] = [], confirmed: Bool = false,
        activatedAt: Date? = nil, announced: Bool = false
    ) -> LearnedItem {
        LearnedItem(
            id: id, kind: .term, key: value.lowercased(), value: value, heardAs: heard, status: status,
            observations: observations, confirmed: confirmed, confidence: confidence, sourceDictationIDs: sources,
            createdAt: now.addingTimeInterval(Double(-id)), lastSeenAt: now.addingTimeInterval(Double(-id)),
            activatedAt: activatedAt, announced: announced)
    }

    private func review(_ writes: Writes, autoActivate: Bool = false) -> LearnedReview {
        let review = LearnedReview(actions: writes.actions)
        review.isAutoActivateEnabled = { autoActivate }
        return review
    }

    @Test("a ready habit is offered once; Use confirms, dismissal prevents another offer")
    func habitConsent() {
        let writes = Writes()
        let review = review(writes)
        let habit = LearnedItem(id: 80, kind: .styleSignal, key: "format:noGreeting", value: "format:noGreeting",
                                appBundleID: "app.mail", observations: 3, confidence: 1)
        #expect(review.sections(items: [habit]).habits.map(\.item.id) == [80])
        #expect(PreferenceHints.from([habit], bundleID: "app.mail").isEmpty)
        #expect(LearnedPresentation.canUseHabit(habit))
        let filler = LearnedItem(kind: .styleSignal, key: "keep:actually", value: "keep:actually")
        #expect(!LearnedPresentation.canUseHabit(filler))
        review.add(habit, from: .list)
        #expect(writes.confirmed == [habit])
        #expect(review.sections(items: [Learner.confirm(habit)]).habits.first?.outcome == .added)
        review.undo(80)
        #expect(writes.restored == [habit])
        review.dismiss(habit, from: .list)
        #expect(writes.forgotten == [habit])
        #expect(self.review(Writes()).sections(items: [Learner.forget(habit)]).habits.isEmpty)
    }

    @Test("Today asks about one ready habit once, keeps it on screen until answered, and applies nothing first")
    func todayAsksAboutAHabitOnce() throws {
        let writes = Writes()
        let review = review(writes)
        func habit(_ id: Int64, _ key: String, confidence: Double = 1, announced: Bool = false) -> LearnedItem {
            LearnedItem(id: id, kind: .styleSignal, key: key, value: key, appBundleID: "app.mail", observations: 3,
                        confidence: confidence, lastSeenAt: now.addingTimeInterval(Double(id)), announced: announced)
        }
        let greeting = habit(1, "format:noGreeting")
        let period = habit(2, "format:droppedTerminalPeriod")
        let unripe = habit(3, "format:noExclamation", confidence: 0.6)
        let filler = habit(4, "keep:actually")
        let items = [period, greeting, unripe, filler]
        #expect(review.habitOffer(items: items)?.item.id == 1)

        review.markOffered(greeting)
        #expect(writes.acknowledged.map { $0.map(\.id) } == [[1]])
        let afterMarking = items.map { $0.id == 1 ? habit(1, "format:noGreeting", announced: true) : $0 }
        #expect(review.habitOffer(items: afterMarking)?.item.id == 1)
        #expect(writes.confirmed.isEmpty)
        #expect(PreferenceHints.from(afterMarking, bundleID: "app.mail").isEmpty)

        review.add(afterMarking[1], from: .offer)
        #expect(writes.confirmed.map(\.id) == [1])
        #expect(review.habitOffer(items: afterMarking)?.outcome == .added)

        review.undo(1)
        #expect(writes.restored.map(\.announced) == [true])

        let nextSession = self.review(Writes())
        #expect(nextSession.habitOffer(items: afterMarking)?.item.id == 2)
        let allAsked = afterMarking.map { $0.id == 2 ? habit(2, "format:droppedTerminalPeriod", announced: true) : $0 }
        #expect(nextSession.habitOffer(items: allAsked) == nil)
    }

    // MARK: Which suggestion shows

    @Test("History shows only ready suggestions whose latest fix came from this dictation")
    func historyShowsReadySuggestionForItsDictation() {
        let priya = term(1, "Priya", heard: ["Pria"], sources: [10, 20])
        let okta = term(2, "Okta", observations: 1, confidence: 0.5, sources: [20])
        let older = term(3, "Grafana", sources: [20, 30])
        let active = term(4, "Kubernetes", status: .active, sources: [20])
        let style = LearnedItem(id: 5, kind: .styleSignal, key: "format:lowercased", value: "format:lowercased",
                                appBundleID: "com.slack", sourceDictationIDs: [20])
        let items = [priya, okta, older, active, style]
        let review = review(Writes())

        #expect(review.historyRows(forDictation: 20, items: items).map(\.item.value) == ["Priya"])
        #expect(review.historyRows(forDictation: 30, items: items).map(\.item.value) == ["Grafana"])
        #expect(review.historyRows(forDictation: 10, items: items).isEmpty, "only the most recent source carries it")
        #expect(review.rowMarker(forDictation: 20, items: items) == .suggestion("Priya"))
        #expect(review.rowMarker(forDictation: 99, items: items) == nil)
    }

    // MARK: Confirm and Undo

    @Test("✓ Add confirms, the row reads Added, and Undo restores the exact item")
    func addThenUndo() {
        let writes = Writes()
        let review = review(writes)
        let priya = term(1, "Priya", heard: ["Pria"], sources: [10, 20])

        review.add(priya, from: .history)
        #expect(writes.confirmed == [priya])
        // The store now holds it as active; the row keeps its place and reads "Added".
        var active = priya
        active.status = .active
        active.confirmed = true
        let rows = review.historyRows(forDictation: 20, items: [active])
        #expect(rows.map(\.outcome) == [.added])
        #expect(review.rowMarker(forDictation: 20, items: [active]) == .added("Priya"))

        review.undo(1)
        #expect(writes.restored == [priya], "Undo writes back the item as it was before ✓")
        #expect(review.resolutions.isEmpty)
        #expect(review.historyRows(forDictation: 20, items: [priya]).map(\.isPending) == [true])
    }

    @Test("✕ forgets the suggestion and says so on the row; Undo brings it back")
    func dismissThenUndo() {
        let writes = Writes()
        let review = review(writes)
        let priya = term(1, "Priya", sources: [20])

        review.dismiss(priya, from: .history)
        #expect(writes.forgotten == [priya])
        #expect(writes.confirmed.isEmpty)
        var tombstone = priya
        tombstone.status = .forgotten
        tombstone.sourceDictationIDs = []
        #expect(review.historyRows(forDictation: 20, items: [tombstone]).map(\.outcome) == [.dismissed])
        #expect(review.rowMarker(forDictation: 20, items: [tombstone]) == nil, "nothing left to act on")

        review.undo(1)
        #expect(writes.restored == [priya])
    }

    @Test("a second decision on a row keeps the first 'before', so Undo returns to the start")
    func secondDecisionKeepsOriginal() {
        let writes = Writes()
        let review = review(writes)
        let priya = term(1, "Priya", sources: [20])
        var active = priya
        active.status = .active
        review.add(priya, from: .list)
        review.forget(active, from: .list)
        review.undo(1)
        #expect(writes.restored == [priya])
    }

    @Test("Undo with no decision does nothing")
    func undoWithoutDecision() {
        let writes = Writes()
        review(writes).undo(42)
        #expect(writes.restored.isEmpty)
    }

    @Test("a decision shows its Undo only on the surface where it was made")
    func decisionsStayOnTheirHost() {
        let review = review(Writes())
        let priya = term(1, "Priya", sources: [20])
        var active = priya
        active.status = .active
        active.confirmed = true
        review.add(priya, from: .list)
        #expect(review.historyRows(forDictation: 20, items: [active]).isEmpty)
        let sections = review.sections(items: [active])
        #expect(sections.suggestions.map(\.outcome) == [.added], "stays where it was decided")
        #expect(sections.inUse.isEmpty)
    }

    // MARK: Voice & style list

    @Test("the list groups suggestions (ready first), terms in use and habits, hiding tombstones")
    func sections() {
        let once = term(1, "Okta", observations: 1, confidence: 0.5)
        let ready = term(2, "Priya")
        let inUse = term(3, "Kubernetes", status: .active)
        let gone = term(4, "Figgy", status: .forgotten)
        let habit = LearnedItem(id: 5, kind: .styleSignal, key: "keep:actually", value: "keep:actually",
                                appBundleID: "com.apple.Notes", status: .active)
        let unripeHabit = LearnedItem(id: 6, kind: .styleSignal, key: "drop:like", value: "drop:like",
                                      appBundleID: "com.apple.Notes")
        let sections = review(Writes()).sections(items: [once, ready, inUse, gone, habit, unripeHabit])
        #expect(sections.suggestions.map(\.item.value) == ["Priya", "Okta"])
        #expect(sections.inUse.map(\.item.value) == ["Kubernetes"])
        #expect(sections.habits.map(\.item.key) == ["keep:actually"])
        #expect(!sections.isEmpty)
        #expect(review(Writes()).sections(items: [gone]).isEmpty)
    }

    @Test("Forget in the list forgets and leaves an Undo row where the item was")
    func forgetInList() {
        let writes = Writes()
        let review = review(writes)
        let kube = term(3, "Kubernetes", status: .active)
        review.forget(kube, from: .list)
        var tombstone = kube
        tombstone.status = .forgotten
        let sections = review.sections(items: [tombstone])
        #expect(writes.forgotten == [kube])
        #expect(sections.inUse.map(\.outcome) == [.forgotten])
    }

    @Test("Delete learning data clears every pending Undo and deletes everything")
    func deleteAll() {
        let writes = Writes()
        let review = review(writes)
        review.add(term(1, "Priya"), from: .history)
        review.deleteAllLearningData()
        #expect(writes.deletedAll == 1)
        #expect(review.resolutions.isEmpty)
    }

    // MARK: Today notice and the flag

    @Test("the auto-activation flag ships on (every flag defaults on, 2026-09-28)")
    func flagDefaultsOn() {
        let suite = "learned-review-flags-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let previous = FeatureFlags.source
        FeatureFlags.source = defaults
        defer {
            FeatureFlags.source = previous
            defaults.removePersistentDomain(forName: suite)
        }
        #expect(FeatureFlags.autoActivateLearnedTerms)
        #expect(LearningPolicy.current.autoActivateTerms)
    }

    @Test("with the flag off there is no notice, even for terms that activated themselves")
    func noticeGatedByFlag() {
        let auto = term(1, "Kubernetes", status: .active, activatedAt: now.addingTimeInterval(-60))
        #expect(review(Writes(), autoActivate: false).notice(items: [auto], now: now) == nil)
        let notice = review(Writes(), autoActivate: true).notice(items: [auto], now: now)
        #expect(notice?.learned.map(\.value) == ["Kubernetes"])
    }

    @Test("the notice lists only terms Hushy started using by itself today")
    func noticeTerms() {
        let calendar = Calendar(identifier: .gregorian)
        let today = term(1, "Kubernetes", status: .active, activatedAt: now.addingTimeInterval(-60))
        let second = term(2, "Postgres", status: .active, activatedAt: now.addingTimeInterval(-30))
        let confirmed = term(3, "Priya", status: .active, confirmed: true, activatedAt: now.addingTimeInterval(-10))
        let yesterday = term(4, "Grafana", status: .active, activatedAt: now.addingTimeInterval(-2 * 86_400))
        let candidate = term(5, "Okta")
        let notice = review(Writes(), autoActivate: true)
            .notice(items: [second, confirmed, yesterday, candidate, today], now: now, calendar: calendar)
        #expect(notice?.learned.map(\.value) == ["Kubernetes", "Postgres"], "oldest first")
        #expect(LearnedPresentation.noticeText(notice?.learned ?? []) == "Learned from your edits: Kubernetes, Postgres")
    }

    @Test("showing the notice acknowledges only terms not yet announced")
    func acknowledge() {
        let writes = Writes()
        let review = review(writes, autoActivate: true)
        let fresh = term(1, "Kubernetes", status: .active, activatedAt: now.addingTimeInterval(-60))
        let seen = term(2, "Postgres", status: .active, activatedAt: now.addingTimeInterval(-30), announced: true)
        let notice = review.notice(items: [fresh, seen], now: now)!
        review.acknowledge(notice)
        #expect(writes.acknowledged == [[fresh]])
        review.acknowledge(LearnedReview.Notice(learned: [seen], forgotten: []))
        #expect(writes.acknowledged.count == 1, "nothing new to acknowledge")
    }

    @Test("Undo on the notice forgets every listed term; Undo again puts them back")
    func noticeUndoAndRedo() {
        let writes = Writes()
        let review = review(writes, autoActivate: true)
        let kube = term(1, "Kubernetes", status: .active, activatedAt: now.addingTimeInterval(-60))
        let pg = term(2, "Postgres", status: .active, activatedAt: now.addingTimeInterval(-30))
        let notice = review.notice(items: [kube, pg], now: now)!
        review.undoNotice(notice)
        #expect(writes.forgotten == [kube, pg])

        var goneKube = kube
        goneKube.status = .forgotten
        var gonePg = pg
        gonePg.status = .forgotten
        let after = review.notice(items: [goneKube, gonePg], now: now)
        #expect(after?.learned.isEmpty == true)
        #expect(after?.forgotten.map(\.value) == ["Kubernetes", "Postgres"])

        review.redoNotice(after!)
        #expect(Set(writes.restored.map(\.value)) == ["Kubernetes", "Postgres"])
        #expect(review.resolutions.isEmpty)
    }

    // MARK: Settings

    @Test("Learn from my edits is on by default and a toggle persists")
    func learnToggle() {
        let name = "hushy-test-learning-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.learnFromEdits)
        settings.learnFromEdits = false
        #expect(AppSettings(defaults: defaults).learnFromEdits == false)
        settings.learnFromEdits = true
        #expect(AppSettings(defaults: defaults).learnFromEdits)
    }

    @Test("excluding and re-including apps persists, ignoring blanks and duplicates")
    func exclusions() {
        let name = "hushy-test-learning-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.learningExcludedApps.isEmpty)
        LearningExclusions.exclude("com.tinyspeck.slackmacgap", in: settings)
        LearningExclusions.exclude(" com.tinyspeck.slackmacgap ", in: settings)
        LearningExclusions.exclude("  ", in: settings)
        LearningExclusions.exclude("com.apple.MobileSMS", in: settings)
        #expect(AppSettings(defaults: defaults).learningExcludedApps == ["com.tinyspeck.slackmacgap", "com.apple.MobileSMS"])
        LearningExclusions.include("com.tinyspeck.slackmacgap", in: settings)
        LearningExclusions.include("com.not.there", in: settings)
        #expect(AppSettings(defaults: defaults).learningExcludedApps == ["com.apple.MobileSMS"])
    }
}
