import Foundation
import GRDB
import Testing
@testable import MurmurCore

private let day: TimeInterval = 86_400
private let start = Date(timeIntervalSince1970: 1_800_000_000)
/// The shipped behaviour: a term that meets its threshold activates by itself and is announced with Undo.
private let auto = LearningPolicy(autoActivateTerms: true)
/// The kill switch (`FeatureFlags.autoActivateLearnedTerms` stored false): a term waits for the person's confirm.
private let suggestOnly = LearningPolicy(autoActivateTerms: false)

private func termCapture(_ id: Int64, _ before: String, _ after: String, at offset: TimeInterval) -> CorrectionCapture {
    CorrectionCapture(dictationID: id, appBundleID: "com.apple.mail", capturedAt: start.addingTimeInterval(offset),
                      events: [CorrectionEvent(kind: .asrTerm, before: before, after: after)])
}

/// Folds captures in order, like the Store does, and returns the final items.
private func fold(_ captures: [CorrectionCapture], known: Set<String> = [], hearings: [String: Set<String>] = [:], policy: LearningPolicy = .standard) -> [LearnedItem] {
    var items: [LearnedItem] = []
    for capture in captures {
        let changed = Learner.observe(capture, existing: items, knownTerms: known, knownHearings: hearings, policy: policy)
        let ids = Set(changed.map(\.identity))
        items = items.filter { !ids.contains($0.identity) } + changed
    }
    return items
}

@Suite("Learning · thresholds")
struct LearnerThresholdTests {
    @Test("one edit activates a noncommon spelling correction to Hushy's pasted text unless the kill switch is on")
    func oneEditSpellingPolicy() throws {
        let capture = try #require(CorrectionCapture.derive(
            inserted: "Please send Pria today.", raw: "Please send Pria today.",
            fieldValue: "Please send Priya today.", context: LearningContext(appBundleID: "com.apple.mail"),
            dictationID: 1, now: start))
        #expect(capture.events.contains { $0.kind == .asrTerm && $0.before == "Pria" && $0.after == "Priya" })
        #expect(fold([capture], policy: auto).first?.status == .active)
        #expect(fold([capture], policy: .standard).first?.status == .active)
        #expect(fold([capture], policy: suggestOnly).first?.status == .candidate)
        #expect(fold([termCapture(2, "form", "from", at: 0)], policy: auto).first?.status == .candidate)
    }

    @Test("one-edit spelling excludes alternate names, vowel substitutions, and existing field text")
    func oneEditBoundaries() throws {
        func capture(_ inserted: String, _ field: String) throws -> CorrectionCapture {
            try #require(CorrectionCapture.derive(
                inserted: inserted, raw: inserted, fieldValue: field,
                context: LearningContext(appBundleID: "com.apple.mail", elapsed: 12),
                dictationID: 1, now: start))
        }
        let sara = try capture("Send the deck to Sara before the meeting tomorrow.",
                               "Send the deck to Sarah before the meeting tomorrow.")
        #expect(fold([sara], policy: auto).first?.status == .candidate)
        let zoraeda = try capture("Please loop in Zoraeda on the thread.",
                                  "Please loop in Zoraida on the thread.")
        #expect(fold([zoraeda], policy: auto).first?.status == .candidate)
        let existing = try capture("Please send Pria today.", "Priya wrote earlier. Please send Priya today.")
        #expect(fold([existing], policy: auto).first?.status == .candidate)
        #expect(CorrectionCapture.derive(inserted: "Please send Pria today.", raw: "Please send Pria today.",
                                         fieldValue: "Please send Priya today.",
                                         context: LearningContext(appBundleID: "com.apple.mail", elapsed: 61),
                                         dictationID: 2, now: start) == nil)
    }

    @Test("different-phonetics term still needs two edits")
    func wholeWordNeedsTwo() {
        let once = fold([termCapture(1, "Karthik", "Priya", at: 0)], policy: auto)
        #expect(once.first?.status == .candidate)
        let twice = fold([termCapture(1, "Karthik", "Priya", at: 0),
                          termCapture(2, "Karthik", "Priya", at: day)], policy: auto)
        #expect(twice.first?.status == .active)
    }
    @Test("the default policy activates a term by itself; the kill switch keeps it a suggestion until confirmed")
    func autoActivatesByDefault() throws {
        #expect(LearningPolicy.standard.autoActivateTerms)
        #expect(LearningPolicy().autoActivateTerms)
        let once = fold([termCapture(1, "Pria", "Priya", at: 0)])
        #expect(once.first?.status == .candidate)
        let twice = fold([termCapture(1, "Karthik", "Priya", at: 0), termCapture(2, "Karthik", "Priya", at: day)])
        let active = try #require(twice.first)
        #expect(active.status == .active)
        #expect(active.announced == false)
        #expect(LearnedPersonalization.dictionaryEntries(from: twice).map(\.term) == ["Priya"])
    }

    @Test("with the kill switch on, a term stays a suggestion until confirmed")
    func suggestOnlyWhenSwitchedOff() throws {
        #expect(suggestOnly.autoActivateTerms == false)
        let once = fold([termCapture(1, "Pria", "Priya", at: 0)], policy: suggestOnly)
        #expect(once.first?.status == .candidate)
        #expect(once.first?.announced == false)
        let twice = fold([termCapture(1, "Pria", "Priya", at: 0), termCapture(2, "Preeya", "Priya", at: 3 * day),
                          termCapture(3, "Pria", "Priya", at: 4 * day)], policy: suggestOnly)
        let item = try #require(twice.first)
        #expect(item.status == .candidate)
        #expect(item.confidence == 1)
        #expect(LearnedPersonalization.dictionaryEntries(from: twice).isEmpty)
        let confirmed = Learner.confirm(item, now: start.addingTimeInterval(5 * day))
        #expect(confirmed.status == .active)
        #expect(LearnedPersonalization.dictionaryEntries(from: [confirmed]).map(\.term) == ["Priya"])
    }

    @Test("forgetting an auto-activated term stops it and the same edits never teach it again")
    func forgetStaysForgotten() throws {
        let twice = fold([termCapture(1, "Karthik", "Priya", at: 0), termCapture(2, "Karthik", "Priya", at: day)])
        let forgotten = Learner.forget(try #require(twice.first))
        #expect(forgotten.status == .forgotten)
        #expect(LearnedPersonalization.dictionaryEntries(from: [forgotten]).isEmpty)
        let again = Learner.observe(termCapture(3, "Karthik", "Priya", at: 2 * day), existing: [forgotten], knownTerms: [])
        #expect(again.isEmpty)
    }

    @Test("ready suggestions are listed before fresh ones")
    func readyFirst() {
        let ready = fold([termCapture(1, "Karthik", "Priya", at: 0), termCapture(2, "Karthik", "Priya", at: day)], policy: suggestOnly)[0]
        let fresh = fold([termCapture(3, "cube cuddle", "Kubernetes", at: 5 * day)], policy: suggestOnly)[0]
        #expect(LearnedPersonalization.suggestions([fresh, ready]).map(\.value) == ["Priya", "Kubernetes"])
    }

    @Test("with auto-activation on, one edit makes a candidate; a second within 14 days activates it")
    func twoWithinWindow() throws {
        let once = fold([termCapture(1, "Karthik", "Priya", at: 0)], policy: auto)
        #expect(once.first?.status == .candidate)
        #expect(once.first?.confidence == 0.5)
        let twice = fold([termCapture(1, "Karthik", "Priya", at: 0), termCapture(2, "Karthik", "Priya", at: 3 * day)], policy: auto)
        let item = try #require(twice.first)
        #expect(item.status == .active)
        #expect(item.confidence == 1)
        #expect(item.heardAs == ["Karthik"])
        #expect(item.sourceDictationIDs == [1, 2])
        #expect(item.announced == false)
        #expect(item.activatedAt == start.addingTimeInterval(3 * day))
    }

    @Test("two edits more than 14 days apart stay a candidate")
    func outsideWindow() {
        let items = fold([termCapture(1, "Karthik", "Priya", at: 0), termCapture(2, "Karthik", "Priya", at: 20 * day)], policy: auto)
        #expect(items.first?.status == .candidate)
        #expect(items.first?.observations == 2)
    }

    @Test("the same dictation observed twice counts once")
    func sameDictation() {
        let items = fold([termCapture(1, "Karthik", "Priya", at: 0), termCapture(1, "Karthik", "Priya", at: 30)], policy: auto)
        #expect(items.first?.status == .candidate)
        #expect(items.first?.observations == 1)
    }

    @Test("a hearing the user's Dictionary entry already lists is not learned again")
    func knownTerms() {
        #expect(fold([termCapture(1, "Pria", "Priya", at: 0)], known: ["priya"], hearings: ["priya": ["pria"]]).isEmpty)
        #expect(fold([termCapture(1, "Pria", "Priya", at: 0)], known: ["priya"], hearings: ["priya": [Learner.listedKey("PRIA ")]]).isEmpty)
    }

    @Test("a new hearing of a term already in the Dictionary is learned")
    func knownTermNewHearing() {
        let items = fold([termCapture(1, "Preeya", "Priya", at: 0)], known: ["priya"], hearings: ["priya": ["pria"]])
        #expect(items.map(\.key) == ["priya"])
        #expect(items.first?.heardAs == ["Preeya"])
    }

    @Test("confirming a suggestion activates it without a second edit")
    func confirm() {
        let candidate = fold([termCapture(1, "Kubernetis", "Kubernetes", at: 0)])[0]
        let confirmed = Learner.confirm(candidate, now: start)
        #expect(confirmed.status == .active)
        #expect(confirmed.confirmed)
        #expect(confirmed.confidence == 1)
        #expect(confirmed.announced) // the user just said yes; no notice needed
    }

    @Test("style signals need three observations in 30 days and are per app")
    func styleSignals() {
        func lower(_ id: Int64, _ app: String, _ offset: TimeInterval) -> CorrectionCapture {
            CorrectionCapture(dictationID: id, appBundleID: app, capturedAt: start.addingTimeInterval(offset),
                              events: [CorrectionEvent(kind: .formatting, before: "Hey,", after: "hey,")])
        }
        let slack = "com.tinyspeck.slackmacgap"
        let two = fold([lower(1, slack, 0), lower(2, slack, day)])
        #expect(two.first?.status == .candidate)
        let three = fold([lower(1, slack, 0), lower(2, slack, day), lower(3, "com.apple.mail", 2 * day), lower(4, slack, 3 * day)])
        #expect(three.first { $0.appBundleID == slack }?.isReadySuggestion == true)
        #expect(three.first { $0.appBundleID == "com.apple.mail" }?.status == .candidate)
        let accepted = three.map { $0.appBundleID == slack ? Learner.confirm($0, now: start) : $0 }
        let hints = PreferenceHints.from(accepted, bundleID: slack)
        #expect(hints.prefersLowercase)
        #expect(!hints.promptLines.isEmpty)
        #expect(PreferenceHints.from(three, bundleID: "com.apple.mail").isEmpty)
    }

    @Test("over- and under-edits become keep/drop hints")
    func keepDrop() {
        let app = "com.apple.Notes"
        let captures = (1...3).map { index in
            CorrectionCapture(dictationID: Int64(index), appBundleID: app, capturedAt: start.addingTimeInterval(Double(index) * day),
                              events: [CorrectionEvent(kind: .cleanupOverEdit, before: "", after: "actually"),
                                       CorrectionEvent(kind: .cleanupUnderEdit, before: "like", after: "")])
        }
        let hints = PreferenceHints.from(fold(captures).map { Learner.confirm($0, now: start) }, bundleID: app)
        #expect(hints.keepWords == ["actually"])
        #expect(hints.dropWords == ["like"])
    }
}

@Suite("Learning · forget and undo")
struct LearnerForgetTests {
    @Test("forget drops evidence, keeps a tombstone, and blocks re-learning")
    func forget() {
        let active = fold([termCapture(1, "Pria", "Priya", at: 0), termCapture(2, "Pria", "Priya", at: day)], policy: auto)[0]
        let forgotten = Learner.forget(active)
        #expect(forgotten.status == .forgotten)
        #expect(forgotten.heardAs.isEmpty && forgotten.sourceDictationIDs.isEmpty && forgotten.observedAt.isEmpty)
        let again = Learner.observe(termCapture(3, "Pria", "Priya", at: 2 * day), existing: [forgotten], knownTerms: [])
        #expect(again.isEmpty)
    }

    @Test("forgotten and candidate terms never reach the personalizer")
    func personalizerExcludes() {
        let active = fold([termCapture(1, "Pria", "Priya", at: 0), termCapture(2, "Pria", "Priya", at: day)], policy: auto)[0]
        let candidate = fold([termCapture(3, "cube cuddle", "Kubernetes", at: 0)])[0]
        let entries = LearnedPersonalization.dictionaryEntries(from: [active, candidate, Learner.forget(candidate)])
        #expect(entries.map(\.term) == ["Priya"])
        #expect(entries.first?.soundsLike == ["Pria"])
        #expect(LearnedPersonalization.dictionaryEntries(from: [Learner.forget(active)]).isEmpty)
    }

    @Test("a taught hearing made only of ordinary words is text-replaced too")
    func ordinaryWordAliases() {
        let item = LearnedItem(kind: .term, key: "kubectl", value: "kubectl", heardAs: ["cube cuddle"], status: .active)
        let entries = LearnedPersonalization.dictionaryEntries(from: [item])
        #expect(entries.first?.term == "kubectl")
        #expect(entries.first?.soundsLike == ["cube cuddle"])
    }

    @Test("a hearing identical to the term, or empty, is not an alias")
    func degenerateAliases() {
        let item = LearnedItem(kind: .term, key: "kubectl", value: "kubectl", heardAs: ["KUBECTL", " ", ""], status: .active)
        #expect(LearnedPersonalization.dictionaryEntries(from: [item]).first?.soundsLike == [])
    }

    @Test("user entries win over learned ones, and learned replacements apply")
    func personalizerMerge() {
        let learned = LearnedItem(kind: .term, key: "priya", value: "Priya", heardAs: ["Pria"], status: .active)
        let user = DictionaryEntry(term: "PRIYA")
        let merged = LearnedPersonalization.personalizer(dictionary: [user], snippets: [], learned: [learned])
        #expect(merged.dictionary.map(\.term) == ["PRIYA"])
        let applied = LearnedPersonalization.personalizer(dictionary: [], snippets: [], learned: [learned])
        #expect(applied.apply("Send it to Pria today.").text == "Send it to Priya today.")
    }

    @Test("unannounced lists newly active terms; suggestions lists candidates")
    func uiLists() {
        let active = fold([termCapture(1, "Pria", "Priya", at: 0), termCapture(2, "Pria", "Priya", at: day)], policy: auto)[0]
        let candidate = fold([termCapture(3, "cube cuddle", "Kubernetes", at: 0)])[0]
        #expect(LearnedPersonalization.unannounced([active, candidate]).map(\.value) == ["Priya"])
        #expect(LearnedPersonalization.suggestions([active, candidate]).map(\.value) == ["Kubernetes"])
    }
}

@Suite("Learning · store and migration")
struct LearnedItemStoreTests {
    @Test("v14 migrates an existing v13 database without touching its rows")
    func migrationFromV13() throws {
        let queue = try DatabaseQueue()
        try Store.migrator.migrate(queue, upTo: "v13-entitlements")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO dictation (createdAt, rawText, text, durationSeconds, wordCount, latencyMs, status)
                VALUES (?, 'um hi', 'Hi', 1, 1, 10, 'inserted')
                """, arguments: [Date()])
        }
        try Store.migrator.migrate(queue)
        let (hasTable, dictations, learned) = try queue.read { db in
            (try db.tableExists("learnedItem"), try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dictation"),
             try LearnedItem.fetchCount(db))
        }
        #expect(hasTable)
        #expect(dictations == 1)
        #expect(learned == 0)
    }

    @Test("recording captures activates on the second edit and reports it once")
    func recordAndActivate() throws {
        let store = try Store()
        #expect(try store.recordCorrections(termCapture(1, "Karthik", "Priya", at: 0), policy: auto).isEmpty)
        let activated = try store.recordCorrections(termCapture(2, "Karthik", "Priya", at: day), policy: auto)
        #expect(activated.map(\.value) == ["Priya"])
        #expect(try store.recordCorrections(termCapture(3, "Karthik", "Priya", at: 2 * day), policy: auto).isEmpty)
        let items = try store.learnedItems()
        #expect(items.count == 1)
        #expect(items[0].observations == 3)
    }

    @Test("by default the store activates a term on the second edit; with the kill switch it never does, and confirm does")
    func recordDefaultsAndSuggestOnly() throws {
        let byDefault = try Store()
        #expect(try byDefault.recordCorrections(termCapture(1, "Karthik", "Priya", at: 0)).isEmpty)
        #expect(try byDefault.recordCorrections(termCapture(2, "Karthik", "Priya", at: day)).map(\.value) == ["Priya"])

        let store = try Store()
        for (index, offset) in [0, day, 2 * day].enumerated() {
            #expect(try store.recordCorrections(termCapture(Int64(index + 1), "Pria", "Priya", at: offset), policy: suggestOnly).isEmpty)
        }
        let item = try #require(try store.learnedItems().first)
        #expect(item.isReadySuggestion)
        #expect(try store.confirmLearnedItem(id: try #require(item.id))?.status == .active)
    }

    @Test("a hearing the user's own dictionary entry lists is not learned at record time; a new one is")
    func dictionaryCoversListedHearing() throws {
        let store = try Store()
        try store.save(DictionaryEntry(term: "Priya", soundsLike: ["Pria"]))
        _ = try store.recordCorrections(termCapture(1, "pria", "Priya", at: 0))
        #expect(try store.learnedItems().isEmpty)
        _ = try store.recordCorrections(termCapture(2, "Preeya", "Priya", at: 0))
        #expect(try store.learnedItems().map(\.heardAs) == [["Preeya"]])
    }

    @Test("confirm, forget, acknowledge and delete-all round-trip")
    func actions() throws {
        let store = try Store()
        _ = try store.recordCorrections(termCapture(1, "Kubernetis", "Kubernetes", at: 0))
        let id = try #require(try store.learnedItems().first?.id)
        #expect(try store.confirmLearnedItem(id: id)?.status == .active)
        try store.markLearnedItemsAnnounced(ids: [id])
        #expect(try store.learnedItems().first?.announced == true)
        #expect(try store.forgetLearnedItem(id: id)?.status == .forgotten)
        _ = try store.recordCorrections(termCapture(2, "Kubernetis", "Kubernetes", at: day))
        #expect(try store.learnedItems().first?.status == .forgotten)
        try store.deleteAllLearnedItems()
        #expect(try store.learnedItems().isEmpty)
    }

    @Test("the unique identity index keeps one row per term and per app signal")
    func uniqueIdentity() throws {
        let store = try Store()
        func insert(_ item: LearnedItem) throws {
            try store.writer.write { db in
                var copy = item
                try copy.insert(db)
            }
        }
        try insert(LearnedItem(kind: .term, key: "priya", value: "Priya"))
        #expect(throws: (any Error).self) { try insert(LearnedItem(kind: .term, key: "priya", value: "Priya")) }
        try insert(LearnedItem(kind: .styleSignal, key: "format:lowercased", value: "format:lowercased", appBundleID: "a"))
        try insert(LearnedItem(kind: .styleSignal, key: "format:lowercased", value: "format:lowercased", appBundleID: "b"))
        #expect(try store.learnedItems().count == 3)
    }
}

@Suite("Learning · protected terms")
struct ProtectedTermGuardTests {
    @Test("dropping or respelling a protected term is rejected; other edits pass")
    func guardTerms() {
        let draft = "So Priya said the Kubernetes cluster is ready."
        #expect(ProtectedTermGuard.violation(answer: "Pria said the Kubernetes cluster is ready.", draft: draft, terms: ["Priya"]) != nil)
        #expect(ProtectedTermGuard.violation(answer: "Priya said the cluster is ready.", draft: draft, terms: ["Kubernetes"]) != nil)
        #expect(ProtectedTermGuard.violation(answer: "Priya said the Kubernetes cluster is ready.", draft: draft, terms: ["Priya", "Kubernetes"]) == nil)
        #expect(ProtectedTermGuard.violation(answer: "Anything at all.", draft: "No terms here.", terms: ["Priya"]) == nil)
    }

    @Test("a heard variant must survive as itself or as its term; other edits pass")
    func guardAliases() {
        let alias = [ProtectedTermGuard.Alias(heard: "diarisation", term: "diarization")]
        let draft = "We should add diarisation to the notes."
        #expect(ProtectedTermGuard.violation(answer: "We should add diary station to the notes.", draft: draft, terms: [], aliases: alias) != nil)
        #expect(ProtectedTermGuard.violation(answer: "We should add the notes.", draft: draft, terms: [], aliases: alias) != nil)
        #expect(ProtectedTermGuard.violation(answer: "We should add diarisation to the notes.", draft: draft, terms: [], aliases: alias) == nil)
        #expect(ProtectedTermGuard.violation(answer: "We should add diarization to the notes.", draft: draft, terms: [], aliases: alias) == nil)
        #expect(ProtectedTermGuard.violation(answer: "Anything at all.", draft: "No variant here.", terms: [], aliases: alias) == nil)
    }

    @Test("a Dictionary entry exposes only its real heard-as spellings")
    func personalizerAliases() {
        let personalizer = Personalizer(dictionary: [
            DictionaryEntry(term: "diarization", soundsLike: ["diarisation", "", "Diarization"]),
            DictionaryEntry(term: "Kubernetes"),
        ])
        #expect(personalizer.heardAliases == [ProtectedTermGuard.Alias(heard: "diarisation", term: "diarization")])
    }
}

/// Always answers with a fixed cleaned text.
private struct FixedAnswerModel: LanguageModel {
    let text: String
    var identifier: String { "fixed" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["text": text])
        return String(decoding: data, as: UTF8.self)
    }
}

@Suite("Learning · protected terms in SmartCleaner")
struct ProtectedTermCleanupTests {
    private let raw = "kubectl said the cluster is ready and we can ship it today"
    private let answer = "Kubectl said the cluster is ready and we can ship it today."

    @Test("a model rewrite that respells a dictionary/learned term falls back to rules")
    func rejected() async {
        let cleaner = SmartCleaner(model: FixedAnswerModel(text: "Cube cuddle said the cluster is ready and we can ship it today."))
        let personalizer = Personalizer(dictionary: [DictionaryEntry(term: "kubectl")])
        let output = await cleaner.clean(raw, options: CleanupOptions(level: .polished), personalizer: personalizer)
        #expect(!output.usedModel)
        #expect(output.rejection == "changed protected term")
        #expect(output.text.lowercased().contains("kubectl"))
    }

    @Test("without the term protected, the same kind of rewrite is not blocked by this guard")
    func unprotected() async {
        let cleaner = SmartCleaner(model: FixedAnswerModel(text: answer))
        let output = await cleaner.clean(raw, options: CleanupOptions(level: .polished))
        #expect(output.rejection != "changed protected term")
    }
}

@Suite("Learning · the heard variant survives cleanup so the learned spelling can replace it")
struct ProtectedVariantCleanupTests {
    private let raw = "we should add diarisation to the notes and ping the team tomorrow"
    private let personalizer = Personalizer(dictionary: [DictionaryEntry(term: "diarization", soundsLike: ["diarisation"])])

    @Test("a rewrite that respells the heard variant is dropped, so the learned replacement still lands")
    func rewrittenVariantFallsBackToRules() async {
        let cleaner = SmartCleaner(model: FixedAnswerModel(text: "We should add diary station to the notes and ping the team tomorrow."))
        let output = await cleaner.clean(raw, options: CleanupOptions(level: .polished), personalizer: personalizer)
        #expect(output.rejection == "changed protected term")
        #expect(output.text.contains("diarization"))
    }

    @Test("a rewrite that already uses the learned spelling is not blocked")
    func rewriteToTheTermIsKept() async {
        let cleaner = SmartCleaner(model: FixedAnswerModel(text: "We should add diarization to the notes and ping the team tomorrow."))
        let output = await cleaner.clean(raw, options: CleanupOptions(level: .polished), personalizer: personalizer)
        #expect(output.rejection != "changed protected term")
        #expect(output.text.contains("diarization"))
    }

    @Test("a rewrite that leaves the heard variant alone is not blocked")
    func rewriteKeepingTheVariantIsKept() async {
        let cleaner = SmartCleaner(model: FixedAnswerModel(text: "We should add diarisation to the notes and ping the team tomorrow."))
        let output = await cleaner.clean(raw, options: CleanupOptions(level: .polished), personalizer: personalizer)
        #expect(output.rejection != "changed protected term")
        #expect(output.text.contains("diarization"))
    }
}
