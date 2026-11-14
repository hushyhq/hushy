import Foundation
import Testing
@testable import MurmurCore

/// A word the person taught ("I heard X, I meant Y") is applied next time even when X is an
/// ordinary English word, while an untaught Dictionary term still never swallows one.
/// Invented words only.
private let day: TimeInterval = 86_400
private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let auto = LearningPolicy(autoActivateTerms: true)

private func capture(_ id: Int64, heard: String, meant: String, at offset: TimeInterval = 0) -> CorrectionCapture {
    CorrectionCapture(dictationID: id, appBundleID: "com.apple.mail", capturedAt: start.addingTimeInterval(offset),
                      events: [CorrectionEvent(kind: .asrTerm, before: heard, after: meant)])
}

/// Folds captures in order, like the Store does.
private func fold(_ captures: [CorrectionCapture], policy: LearningPolicy = auto) -> [LearnedItem] {
    var items: [LearnedItem] = []
    for capture in captures {
        let changed = Learner.observe(capture, existing: items, knownTerms: [], policy: policy)
        let ids = Set(changed.map(\.identity))
        items = items.filter { !ids.contains($0.identity) } + changed
    }
    return items
}

/// An active learned term taught twice ("mark it" was wrong, "Markit" is right).
private func taught(heard: String, meant: String) -> [LearnedItem] {
    fold([capture(1, heard: heard, meant: meant), capture(2, heard: heard, meant: meant, at: day)])
}

private func learnedPersonalizer(_ items: [LearnedItem]) -> Personalizer {
    LearnedPersonalization.personalizer(dictionary: [], snippets: [], learned: items)
}

private struct FixedTranscriber: Transcriber {
    let text: String
    func transcribe(_ samples: [Float]) async throws -> String { text }
}

@Suite("Taught word wins")
struct TaughtWordTests {
    // The ordinary-word boundary these tests use is the Mac's real word list through the
    // production `LearningLexicon`; the guard test below injects its own set.

    @Test("fixing ordinary words into a new name is captured as a taught pair")
    func captureTeachesPair() throws {
        let common: Set<String> = ["please", "open", "mark", "it", "for", "me", "today", "and", "send", "the", "notes"]
        let inserted = "Please open mark it for me today and send the notes."
        let edited = "Please open Markit for me today and send the notes."
        let capture = try #require(CorrectionCapture.derive(
            inserted: inserted, raw: inserted, fieldValue: edited,
            context: LearningContext(appBundleID: "com.tinyspeck.slackmacgap"), dictationID: 1,
            isCommonWord: { common.contains($0) }))
        #expect(capture.events.map(\.kind) == [.asrTerm])
        #expect(capture.events.first?.before == "mark it")
        #expect(capture.events.first?.after == "Markit")
    }

    @Test("a taught pair over ordinary words is applied")
    func taughtPairOverOrdinaryWords() throws {
        let items = taught(heard: "mark it", meant: "Markit")
        let item = try #require(items.first)
        #expect(item.status == .active)
        let entries = LearnedPersonalization.dictionaryEntries(from: items)
        #expect(entries.map(\.term) == ["Markit"])
        #expect(entries.first?.soundsLike == ["mark it"])
        let personalizer = learnedPersonalizer(items)
        #expect(personalizer.apply("Please open mark it for me.").text == "Please open Markit for me.")
        #expect(personalizer.apply("Mark it is ready.").text == "Markit is ready.")
    }

    @Test("a taught single ordinary word is applied")
    func taughtSingleOrdinaryWord() {
        let items = taught(heard: "glimmer", meant: "Glimmr")
        #expect(learnedPersonalizer(items).apply("Open the glimmer dashboard.").text == "Open the Glimmr dashboard.")
    }

    @Test("a taught pair survives the whole pipeline, not just the personalizer")
    func taughtPairThroughPipeline() async throws {
        let items = taught(heard: "mark it", meant: "Markit")
        let pipeline = DictationPipeline(transcriber: FixedTranscriber(text: "please open mark it today"))
        let settings = PipelineSettings(personalizer: learnedPersonalizer(items))
        let result = try await pipeline.run(samples: [Float](repeating: 0, count: 16_000), settings: settings)
        #expect(result.text.contains("Markit"))
        #expect(!result.text.lowercased().contains("mark it"))
    }

    @Test("the taught heard-as phrase is protected from a model rewrite, like any alias")
    func taughtPairIsProtectedFromRewrite() {
        let personalizer = learnedPersonalizer(taught(heard: "mark it", meant: "Markit"))
        #expect(personalizer.heardAliases == [ProtectedTermGuard.Alias(heard: "mark it", term: "Markit")])
    }

    @Test("an untaught Dictionary term still does not swallow an ordinary word")
    func untaughtTermStillGuarded() {
        let common: Set<String> = ["please", "open", "mark", "it", "today"]
        // The recogniser's boost turned "mark it" into the bare Dictionary term; the guard reverts it.
        let guarded = BoostGuard.filter(
            original: "please open mark it today", boosted: "please open Markit today", terms: ["Markit"]) { common.contains($0) }
        #expect(guarded == "please open mark it today")
        // And a bare Dictionary entry carries no heard-as phrase, so nothing rewrites the text afterwards.
        let bare = Personalizer(dictionary: [DictionaryEntry(term: "Markit")])
        #expect(bare.apply("please open mark it today").text == "please open mark it today")
    }

    @Test("a suggestion nobody confirmed is not applied")
    func candidateNotApplied() throws {
        let candidates = fold([capture(1, heard: "mark it", meant: "Markit")], policy: .standard)
        #expect(candidates.first?.status == .candidate)
        #expect(LearnedPersonalization.dictionaryEntries(from: candidates).isEmpty)
        #expect(learnedPersonalizer(candidates).apply("open mark it").text == "open mark it")
    }

    @Test("a suggestion the person confirmed is applied at once")
    func confirmedApplied() throws {
        let candidate = try #require(fold([capture(1, heard: "mark it", meant: "Markit")], policy: .standard).first)
        let confirmed = Learner.confirm(candidate, now: start)
        #expect(learnedPersonalizer([confirmed]).apply("open mark it").text == "open Markit")
    }

    @Test("forgetting the taught item restores the old behaviour")
    func forgettingRestores() throws {
        let items = taught(heard: "mark it", meant: "Markit")
        let item = try #require(items.first)
        #expect(learnedPersonalizer([item]).apply("open mark it").text == "open Markit")
        let forgotten = Learner.forget(item)
        #expect(LearnedPersonalization.dictionaryEntries(from: [forgotten]).isEmpty)
        #expect(learnedPersonalizer([forgotten]).apply("open mark it").text == "open mark it")
        // The same edit never teaches it again.
        let again = Learner.observe(capture(3, heard: "mark it", meant: "Markit", at: 2 * day), existing: [forgotten], knownTerms: [])
        #expect(again.isEmpty)
    }

    @Test("a Dictionary entry's own heard-as phrase keeps winning over a learned one")
    func userEntryWins() {
        let user = DictionaryEntry(term: "MARKIT", soundsLike: ["mark it"])
        let personalizer = LearnedPersonalization.personalizer(
            dictionary: [user], snippets: [], learned: taught(heard: "mark it", meant: "Markit"))
        #expect(personalizer.apply("open mark it").text == "open MARKIT")
    }
}

/// The person added the name to their Dictionary first, then corrected ordinary words to it.
@Suite("Taught word wins · name already in the Dictionary")
struct TaughtWordKnownTermTests {
    private func foldKnown(
        _ captures: [CorrectionCapture], hearings: [String: Set<String>] = [:], policy: LearningPolicy = auto
    ) -> [LearnedItem] {
        var items: [LearnedItem] = []
        for capture in captures {
            let changed = Learner.observe(
                capture, existing: items, knownTerms: ["markit"], knownHearings: hearings, policy: policy)
            let ids = Set(changed.map(\.identity))
            items = items.filter { !ids.contains($0.identity) } + changed
        }
        return items
    }

    private func taughtKnown() -> [LearnedItem] {
        foldKnown([capture(1, heard: "mark it", meant: "Markit"), capture(2, heard: "mark it", meant: "Markit", at: day)])
    }

    @Test("the correction is learned with the usual rules, not discarded")
    func learnedWithUsualRules() throws {
        let once = foldKnown([capture(1, heard: "mark it", meant: "Markit")], policy: .standard)
        #expect(once.first?.status == .candidate)
        #expect(once.first?.heardAs == ["mark it"])
        let confirmed = Learner.confirm(try #require(once.first), now: start)
        #expect(confirmed.status == .active)
        let repeated = taughtKnown()
        #expect(repeated.first?.status == .active)
        #expect(repeated.first?.observations == 2)
    }

    @Test("a hearing the person's own entry already lists is not learned")
    func coveredHearingNotLearned() {
        #expect(foldKnown([capture(1, heard: "Mark It", meant: "Markit")], hearings: ["markit": ["mark it"]]).isEmpty)
    }

    @Test("the learned phrase is applied alongside the person's bare entry, which is not rewritten")
    func appliedAlongsideUserEntry() {
        let user = DictionaryEntry(term: "Markit")
        let personalizer = LearnedPersonalization.personalizer(dictionary: [user], snippets: [], learned: taughtKnown())
        #expect(personalizer.apply("please open mark it today").text == "please open Markit today")
        #expect(personalizer.dictionary.count == 1)
        #expect(personalizer.dictionary.first?.term == "Markit")
        #expect(personalizer.dictionary.first?.soundsLike == ["mark it"])
        #expect(user.soundsLike.isEmpty)
        #expect(personalizer.heardAliases == [ProtectedTermGuard.Alias(heard: "mark it", term: "Markit")])
    }

    @Test("the person's own sounds-like phrases keep working, and come first")
    func userPhrasesKeepWorking() {
        let user = DictionaryEntry(term: "Markit", soundsLike: ["marquee it"])
        let personalizer = LearnedPersonalization.personalizer(dictionary: [user], snippets: [], learned: taughtKnown())
        #expect(personalizer.dictionary.first?.soundsLike == ["marquee it", "mark it"])
        #expect(personalizer.apply("open marquee it and mark it").text == "open Markit and Markit")
    }

    @Test("a phrase another Dictionary entry claims stays with that entry")
    func personsEntryWinsOnDisagreement() {
        let markit = DictionaryEntry(term: "Markit")
        let other = DictionaryEntry(term: "Marquee", soundsLike: ["mark it"])
        let personalizer = LearnedPersonalization.personalizer(dictionary: [markit, other], snippets: [], learned: taughtKnown())
        #expect(personalizer.dictionary.first { $0.term == "Markit" }?.soundsLike == [])
        #expect(personalizer.apply("open mark it").text == "open Marquee")
    }

    @Test("the person's spelling of the term wins over the learned capitalisation")
    func caseInsensitiveTermMatch() {
        let user = DictionaryEntry(term: "MARKIT")
        let personalizer = LearnedPersonalization.personalizer(dictionary: [user], snippets: [], learned: taughtKnown())
        #expect(personalizer.dictionary.map(\.term) == ["MARKIT"])
        #expect(personalizer.apply("open mark it").text == "open MARKIT")
    }

    @Test("an unconfirmed suggestion is not applied; forgetting removes it again")
    func candidateAndForget() {
        let user = DictionaryEntry(term: "Markit")
        let candidate = foldKnown([capture(1, heard: "mark it", meant: "Markit")], policy: .standard)
        let before = LearnedPersonalization.personalizer(dictionary: [user], snippets: [], learned: candidate)
        #expect(before.apply("open mark it").text == "open mark it")
        let forgotten = taughtKnown().map(Learner.forget)
        let after = LearnedPersonalization.personalizer(dictionary: [user], snippets: [], learned: forgotten)
        #expect(after.dictionary == [user])
        #expect(after.apply("open mark it").text == "open mark it")
    }

    @Test("through the store: add the name, correct it twice, and the phrase applies")
    func throughTheStore() throws {
        let store = try Store()
        _ = try store.save(DictionaryEntry(term: "Markit"))
        _ = try store.recordCorrections(capture(1, heard: "mark it", meant: "Markit"), policy: auto)
        let activated = try store.recordCorrections(capture(2, heard: "mark it", meant: "Markit", at: day), policy: auto)
        #expect(activated.map(\.value) == ["Markit"])
        let dictionary = try store.dictionary()
        #expect(dictionary.count == 1 && dictionary[0].soundsLike.isEmpty)
        let personalizer = LearnedPersonalization.personalizer(
            dictionary: dictionary, snippets: [], learned: try store.learnedItems())
        #expect(personalizer.apply("open mark it").text == "open Markit")
        // Once the person's own entry lists the phrase, the same edit is not learned again.
        var listed = dictionary[0]
        listed.soundsLike = ["mark it"]
        _ = try store.save(listed)
        #expect(try store.recordCorrections(capture(3, heard: "mark it", meant: "Markit", at: 2 * day), policy: auto).isEmpty)
        #expect(try store.learnedItems().first?.observations == 2)
    }
}
