import Testing
@testable import MurmurCore

/// Founder P0 item 8: "dictation" was transcribed as "rotation".
///
/// Every count-based bound in `OutputGuard`/`DisfluencyOnlyGuard` lets a one-for-one content-word
/// swap through: `OutputGuard`'s invented-word budget allows two new words, `.clean` allows one
/// added content word, and `.polished` tolerates two dropped ones — so a model answer that drops
/// one spoken content word and adds one unrelated one stayed under every threshold. On the paths
/// that reach the guards without ASR confidences (vocabulary-boosted results, some segmented
/// cleanups, text-only) `UnmarkedWordGuard` — the only guard that pairs a changed word with its
/// confidence — never runs either, so nothing rejected the swap.
///
/// These tests pin the fix (a substitution is rejected at both levels) and, just as importantly,
/// the rewrites that must keep working: disfluency removal, garbled-word reconstruction, an
/// agreement fix, a lone added word, and the documented confidence-marked correction.
@Suite("OutputGuard content substitution")
struct ContentSubstitutionTests {
    /// Stand-in for `/usr/share/dict/words` so these assertions don't depend on the machine's
    /// dictionary: "dictation"/"rotation" are words the speaker said coherently, "prduct"/"meting"
    /// are recogniser garble (never in the list), and an empty set disables the check entirely.
    private static let dictionary: Set<String> = [
        "start", "dictation", "rotation", "meeting", "the", "report", "fix", "page", "product",
        "send", "invoice", "receipt", "friday", "sarah", "we", "need", "to", "is", "due", "now",
        "details", "are", "in", "second", "paragraph", "above", "sentence", "morning",
    ]

    private var knownWords: Set<String> { Self.dictionary }

    // MARK: - The fix: a content word may not be swapped for a different one

    @Test(".polished rejects 'dictation' -> 'rotation' when no ASR confidence is available")
    func polishedRejectsSwapWithoutConfidences() {
        let raw = "Start dictation now."
        let answer = "Start rotation now."
        let result = OutputGuard.check(
            answer, raw: raw, draft: raw, lowConfidenceWords: nil,
            profile: .grammarRepair, knownWords: knownWords
        )
        guard case .rejected(let reason) = result else {
            Issue.record("expected rejection: the model replaced a word the speaker said, got \(result)")
            return
        }
        #expect(reason.hasPrefix("replaced content words"))
        #expect(reason.contains("dictation"))
    }

    @Test(".clean rejects the same swap")
    func cleanRejectsSwap() {
        let raw = "Start dictation now."
        let answer = "Start rotation now."
        let result = OutputGuard.check(
            answer, raw: raw, draft: raw, lowConfidenceWords: nil,
            profile: .disfluencyOnly, knownWords: knownWords
        )
        guard case .rejected(let reason) = result else {
            Issue.record("expected rejection at .clean, got \(result)")
            return
        }
        #expect(reason.hasPrefix("replaced content words"))
    }

    @Test("a low-confidence word may be corrected, but not replaced by an unrelated word")
    func lowConfidenceWordMayNotBeSwapped() {
        // Before the fix this was accepted: `UnmarkedWordGuard` skips a marked word and
        // `DisfluencyOnlyGuard`'s low-confidence excuse removed the drop, leaving one added word
        // (legal) and no dropped word (legal) — the swap itself was never checked.
        let raw = "Start dictation now."
        let answer = "Start rotation now."
        let result = OutputGuard.check(
            answer, raw: raw, draft: raw, lowConfidenceWords: ["dictation"],
            profile: .disfluencyOnly, knownWords: knownWords
        )
        guard case .rejected(let reason) = result else {
            Issue.record("expected rejection: a marked word is corrected, never reworded, got \(result)")
            return
        }
        #expect(reason.hasPrefix("replaced content words"))
    }

    @Test("a prompt-example leak that drops an ordinal is refused")
    func promptLeakIsRejected() {
        let raw = "Details are in the second paragraph."
        let answer = "Details are in the above sentence."
        let result = OutputGuard.check(
            answer, raw: raw, draft: raw, lowConfidenceWords: nil,
            profile: .grammarRepair, knownWords: knownWords
        )
        guard case .rejected(let reason) = result else {
            Issue.record("expected rejection: 'second paragraph' -> 'above sentence' rewrites content, got \(result)")
            return
        }
        #expect(reason == "changed digits" || reason.hasPrefix("replaced content words"))
    }

    // MARK: - Negative cases: legitimate rewrites must be untouched

    @Test(".polished still reconstructs a garbled (non-word) draft word")
    func garbledWordReconstructionStillAllowed() {
        let raw = "We need to fix the prduct page."
        let answer = "We need to fix the product page."
        let result = OutputGuard.check(
            answer, raw: raw, draft: raw, lowConfidenceWords: nil,
            profile: .grammarRepair, knownWords: knownWords
        )
        if case .rejected(let reason) = result {
            Issue.record("expected acceptance: 'prduct' is recogniser garble, not a word the speaker said, got: \(reason)")
        }
    }

    @Test("a confidence-marked misrecognition is still corrected to the near-identical word")
    func markedCorrectionStillAllowed() {
        let raw = "The meting is at three tomorrow."
        let answer = "The meeting is at three tomorrow."
        let result = OutputGuard.check(
            answer, raw: raw, draft: raw, lowConfidenceWords: ["meting"],
            profile: .disfluencyOnly, knownWords: knownWords
        )
        if case .rejected(let reason) = result {
            Issue.record("expected acceptance: 'meting' -> 'meeting' is the correction this path exists for, got: \(reason)")
        }
    }

    @Test(".clean still removes disfluency around the word that must survive")
    func disfluencyRemovalStillAllowed() {
        let raw = "So um basically start dictation now"
        let draft = "Start dictation now."
        let answer = "Start dictation now."
        let result = OutputGuard.check(
            answer, raw: raw, draft: draft, lowConfidenceWords: nil,
            profile: .disfluencyOnly, knownWords: knownWords
        )
        if case .rejected(let reason) = result {
            Issue.record("expected acceptance: filler removal adds no content word, got: \(reason)")
        }
    }

    @Test(".polished still fixes agreement while the sentence keeps its content words")
    func agreementFixStillAllowed() {
        let raw = "The reports is due Friday and it need to go to both manager."
        let answer = "The report is due Friday and it needs to go to both managers."
        let result = OutputGuard.check(
            answer, raw: raw, draft: raw, lowConfidenceWords: nil,
            profile: .grammarRepair, knownWords: knownWords
        )
        if case .rejected(let reason) = result {
            Issue.record("expected acceptance of an agreement fix, got: \(reason)")
        }
    }

    @Test("a lone added content word (no drop) is still inside the invented-word budget")
    func loneAdditionStillAllowed() {
        let raw = "The report is due Friday."
        let answer = "The report is due Friday morning."
        let result = OutputGuard.check(
            answer, raw: raw, draft: raw, lowConfidenceWords: nil,
            profile: .grammarRepair, knownWords: knownWords
        )
        if case .rejected(let reason) = result {
            Issue.record("expected acceptance: one added word with nothing dropped is embellishment, not a swap, got: \(reason)")
        }
    }

    @Test("an empty word list disables the check instead of guessing")
    func emptyDictionaryDegradesToPreviousBehaviour() {
        let raw = "Start dictation now."
        let answer = "Start rotation now."
        let result = OutputGuard.check(
            answer, raw: raw, draft: raw, lowConfidenceWords: nil,
            profile: .grammarRepair, knownWords: []
        )
        if case .rejected(let reason) = result, reason.hasPrefix("replaced content words") {
            Issue.record("without a word list the check must not fire, got: \(reason)")
        }
    }

    // MARK: - The rule itself

    @Test("substituted() separates a swap from a repair")
    func substitutedRule() {
        let words = Self.dictionary
        #expect(DisfluencyOnlyGuard.substituted(dropped: ["dictation"], added: ["rotation"], knownWords: words) == ["dictation"])
        #expect(DisfluencyOnlyGuard.substituted(dropped: ["prduct"], added: ["product"], knownWords: words) == nil)
        #expect(DisfluencyOnlyGuard.substituted(dropped: ["meting"], added: ["meeting"], knownWords: words) == nil)
        // An inflection shares its root, so it is a repair of the same word.
        #expect(DisfluencyOnlyGuard.substituted(dropped: ["manager"], added: ["managers"], knownWords: words) == nil)
        #expect(DisfluencyOnlyGuard.substituted(dropped: ["dictation"], added: ["rotation"], knownWords: []) == nil)
    }

    @Test("the default word list is the system dictionary the app warms at startup")
    func defaultWordListIsWired() throws {
        try #require(!BoostGuard.systemWords.isEmpty)
        let raw = "Start dictation now."
        let answer = "Start rotation now."
        let result = OutputGuard.check(answer, raw: raw, draft: raw, profile: .grammarRepair)
        guard case .rejected(let reason) = result else {
            Issue.record("expected rejection with the default system word list, got \(result)")
            return
        }
        #expect(reason.hasPrefix("replaced content words"))
    }
}
