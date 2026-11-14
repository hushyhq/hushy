import Testing
@testable import MurmurCore

@Suite("WordConfidenceAggregator")
struct WordConfidenceAggregatorTests {
    /// Boundary marker matching FluidAudio's SentencePiece convention (`▁` prefixes a new word).
    static func isStart(_ token: String) -> Bool { token.hasPrefix("▁") }
    static func strip(_ token: String) -> String { token.hasPrefix("▁") ? String(token.dropFirst()) : token }

    @Test("aggregates sub-word pieces into one word with the minimum confidence")
    func minimumOverPieces() {
        // "confidence" -> ["▁conf", "id", "ence"], the middle piece least confident.
        let result = WordConfidenceAggregator.aggregate(
            pieces: ["▁conf", "id", "ence"], confidences: [0.9, 0.4, 0.95],
            isWordStart: Self.isStart, stripBoundary: Self.strip)
        #expect(result.count == 1)
        #expect(result[0].word == "confidence")
        #expect(result[0].confidence == 0.4)
    }

    @Test("keeps separate words separate")
    func multipleWords() {
        let result = WordConfidenceAggregator.aggregate(
            pieces: ["▁the", "▁meting", "▁is", "▁at", "▁3"], confidences: [0.99, 0.3, 0.98, 0.97, 0.9],
            isWordStart: Self.isStart, stripBoundary: Self.strip)
        #expect(result.map(\.word) == ["the", "meting", "is", "at", "3"])
        #expect(result[1].confidence == 0.3)
    }

    @Test("empty input produces no words")
    func emptyInput() {
        let result = WordConfidenceAggregator.aggregate(
            pieces: [], confidences: [], isWordStart: Self.isStart, stripBoundary: Self.strip)
        #expect(result.isEmpty)
    }

    @Test("mismatched pieces/confidences counts produce no words rather than crashing")
    func mismatchedCounts() {
        let result = WordConfidenceAggregator.aggregate(
            pieces: ["▁a", "b"], confidences: [0.5], isWordStart: Self.isStart, stripBoundary: Self.strip)
        #expect(result.isEmpty)
    }
}

@Suite("WordTimingAggregator")
struct WordTimingAggregatorTests {
    static func isStart(_ token: String) -> Bool { token.hasPrefix("▁") }
    static func strip(_ token: String) -> String { token.hasPrefix("▁") ? String(token.dropFirst()) : token }

    @Test("a word's start is its first piece's start and its end is its last piece's end")
    func spansFirstToLastPiece() {
        // "confidence" -> ["▁conf" 0.0-0.2, "id" 0.2-0.3, "ence" 0.3-0.5]
        let result = WordTimingAggregator.aggregate(
            pieces: ["▁conf", "id", "ence"], startTimes: [0.0, 0.2, 0.3], endTimes: [0.2, 0.3, 0.5],
            isWordStart: Self.isStart, stripBoundary: Self.strip)
        #expect(result.count == 1)
        #expect(result[0].word == "confidence")
        #expect(result[0].start == 0.0)
        #expect(result[0].end == 0.5)
    }

    @Test("keeps separate words separate with their own spans")
    func multipleWordsSeparateSpans() {
        let result = WordTimingAggregator.aggregate(
            pieces: ["▁the", "▁meeting"], startTimes: [0.0, 0.5], endTimes: [0.4, 1.0],
            isWordStart: Self.isStart, stripBoundary: Self.strip)
        #expect(result.map(\.word) == ["the", "meeting"])
        #expect(result[0].start == 0.0 && result[0].end == 0.4)
        #expect(result[1].start == 0.5 && result[1].end == 1.0)
    }

    @Test("empty input produces no timings")
    func emptyInput() {
        let result = WordTimingAggregator.aggregate(
            pieces: [], startTimes: [], endTimes: [], isWordStart: Self.isStart, stripBoundary: Self.strip)
        #expect(result.isEmpty)
    }

    @Test("mismatched array counts produce no timings rather than crashing")
    func mismatchedCounts() {
        let result = WordTimingAggregator.aggregate(
            pieces: ["▁a", "b"], startTimes: [0.0], endTimes: [0.1, 0.2],
            isWordStart: Self.isStart, stripBoundary: Self.strip)
        #expect(result.isEmpty)
    }
}

@Suite("ConfidenceSpans")
struct ConfidenceSpansTests {
    @Test("marks a low-confidence word and strips markers back out")
    func markAndStrip() {
        let draft = "The meeting is at 3 pm"
        let marked = ConfidenceSpans.mark(draft, lowConfidenceWords: ["meeting"])
        #expect(marked == "The ⟦meeting⟧ is at 3 pm")
        #expect(ConfidenceSpans.strip(marked) == draft)
    }

    @Test("marking with no low-confidence words returns the draft unchanged")
    func noWordsToMark() {
        let draft = "Send it to Sarah tomorrow."
        #expect(ConfidenceSpans.mark(draft, lowConfidenceWords: []) == draft)
    }

    @Test("low-confidence words survive rules unchanged and are re-aligned onto the draft")
    func realignsAcrossUnchangedWords() {
        let raw = "the meting is at 3 pm"
        let confidences = [
            WordConfidence(word: "the", confidence: 0.99),
            WordConfidence(word: "meting", confidence: 0.2),
            WordConfidence(word: "is", confidence: 0.95),
            WordConfidence(word: "at", confidence: 0.97),
            WordConfidence(word: "3", confidence: 0.9),
            WordConfidence(word: "pm", confidence: 0.92),
        ]
        // Draft identical to raw here (no rules applicable) — the word should carry over as-is.
        let marked = ConfidenceSpans.lowConfidenceWords(in: raw, raw: raw, confidences: confidences)
        #expect(marked.contains("meting"))
        #expect(marked.count == 1)
    }

    @Test("a raw word deleted by rules contributes no low-confidence marker to the draft")
    func deletedWordDropsOut() {
        // "um" is a filler rules remove; even at low confidence it can't be marked because it's
        // no longer present in the draft to wrap.
        let raw = "um the meeting is at 3 pm"
        let draft = "the meeting is at 3 pm"
        let confidences = [
            WordConfidence(word: "um", confidence: 0.1),
            WordConfidence(word: "the", confidence: 0.99),
            WordConfidence(word: "meeting", confidence: 0.98),
            WordConfidence(word: "is", confidence: 0.95),
            WordConfidence(word: "at", confidence: 0.97),
            WordConfidence(word: "3", confidence: 0.9),
            WordConfidence(word: "pm", confidence: 0.92),
        ]
        let marked = ConfidenceSpans.lowConfidenceWords(in: draft, raw: raw, confidences: confidences)
        #expect(marked.isEmpty)
    }

    @Test("no confidences below threshold marks nothing")
    func allHighConfidence() {
        let text = "Send it to Sarah tomorrow"
        let confidences = text.split(separator: " ").map { WordConfidence(word: String($0), confidence: 0.98) }
        let marked = ConfidenceSpans.lowConfidenceWords(in: text, raw: text, confidences: confidences)
        #expect(marked.isEmpty)
    }
}

@Suite("UnmarkedWordGuard")
struct UnmarkedWordGuardTests {
    @Test("rejects a model edit to a word that was not marked low-confidence")
    func rejectsUnmarkedEdit() {
        let draft = "Send it to Sarah tomorrow."
        let answer = "Send it to Karen tomorrow."
        // "sarah" was high confidence (not in the low-confidence set), so changing it is rejected.
        let result = UnmarkedWordGuard.violation(answer: answer, draft: draft, lowConfidenceWords: ["meeting"])
        #expect(result != nil)
    }

    @Test("accepts a model edit to a word that was marked low-confidence")
    func acceptsMarkedEdit() {
        let draft = "The meting is at 3 pm."
        let answer = "The meeting is at 3 pm."
        let result = UnmarkedWordGuard.violation(answer: answer, draft: draft, lowConfidenceWords: ["meting"])
        #expect(result == nil)
    }

    @Test("accepts any edit when the draft itself carries a correction cue")
    func correctionCueAllowsAnyEdit() {
        let draft = "Send it to Sarah, no, actually Karen."
        let answer = "Send it to Karen."
        let result = UnmarkedWordGuard.violation(answer: answer, draft: draft, lowConfidenceWords: [])
        #expect(result == nil)
    }

    @Test("no violation when the model makes no changes at all")
    func noChangeNoViolation() {
        let draft = "Send it to Sarah tomorrow."
        let result = UnmarkedWordGuard.violation(answer: draft, draft: draft, lowConfidenceWords: [])
        #expect(result == nil)
    }

    @Test("deleting confidently heard fillers, stutters and restarts is not a changed word")
    func deletionsAllowed() {
        // Before 2026-09-26 every one of these was rejected whenever ASR confidences were
        // supplied — i.e. on every production dictation.
        #expect(UnmarkedWordGuard.violation(answer: "We need to fix the login.", draft: "So basically we need to like fix the login.", lowConfidenceWords: []) == nil)
        #expect(UnmarkedWordGuard.violation(answer: "It's a three second thing.", draft: "It's it's a three second thing.", lowConfidenceWords: []) == nil)
        #expect(UnmarkedWordGuard.violation(answer: "It takes 2 seconds.", draft: "It takes like two seconds.", lowConfidenceWords: []) == nil)
    }

    @Test("a substitution of a confident word is still rejected, deletion or not elsewhere")
    func substitutionStillRejected() {
        #expect(UnmarkedWordGuard.violation(answer: "We need to repair the login.", draft: "So basically we need to like fix the login.", lowConfidenceWords: []) != nil)
    }

    @Test("at polished, an agreement fix or added article is not a changed word; a new content word is")
    func polishedGrammarFix() {
        let draft = "The reports is due and it need to go to both manager."
        #expect(UnmarkedWordGuard.violation(answer: "The report is due and it needs to go to both managers.", draft: draft, lowConfidenceWords: [], allowGrammarRepair: true) == nil)
        #expect(UnmarkedWordGuard.violation(answer: "The report is due and it needs to go to both directors.", draft: draft, lowConfidenceWords: [], allowGrammarRepair: true) != nil)
        #expect(UnmarkedWordGuard.violation(answer: "The report is due and it needs to go to both managers.", draft: draft, lowConfidenceWords: [], allowGrammarRepair: false) != nil)
    }

    @Test("list formatting is exempt even though it drops high-confidence connective words")
    func listFormattingExempt() {
        // Turning a spoken enumeration into a list necessarily drops "and"/commas that were
        // heard at full confidence — this is instructions rule 3 (list formatting), not the
        // model silently rewriting content, so it must not trip the guard.
        let draft = "The steps are install the app, grant permissions, and hold the key."
        let answer = "The steps are:\n- Install the app\n- Grant permissions\n- Hold the key"
        let result = UnmarkedWordGuard.violation(answer: answer, draft: draft, lowConfidenceWords: [])
        #expect(result == nil)
    }
}

@Suite("OutputGuard with confidences")
struct OutputGuardConfidenceTests {
    @Test("OutputGuard rejects an edit to an unmarked word when confidences are supplied")
    func rejectsUnmarkedWordChange() {
        // Not a name/digit/negation, so this exercises UnmarkedWordGuard specifically rather
        // than being caught first by CriticalTokenGuard's narrower checks.
        let raw = "The meeting is at three tomorrow."
        let draft = "The meeting is at three tomorrow."
        let answer = "The gathering is at three tomorrow."
        let result = OutputGuard.check(answer, raw: raw, draft: draft, lowConfidenceWords: [])
        #expect(result == .rejected("changed unmarked word: meeting"))
    }

    @Test("OutputGuard accepts an edit to a marked low-confidence word")
    func acceptsMarkedWordChange() {
        let raw = "The meting is at three tomorrow."
        let draft = "The meting is at three tomorrow."
        let answer = "The meeting is at three tomorrow."
        let result = OutputGuard.check(answer, raw: raw, draft: draft, lowConfidenceWords: ["meting"])
        if case .rejected = result {
            Issue.record("expected acceptance: 'meting' was marked low confidence")
        }
    }

    @Test("OutputGuard behaves exactly as before when confidences are nil (no ASR confidence)")
    func nilConfidencesUnaffected() {
        let raw = "Send it to Sarah tomorrow."
        let draft = "Send it to Sarah tomorrow."
        let answer = "Send it to Karen tomorrow."
        // Without confidences supplied, the unmarked-word guard must not fire — this is the
        // backwards-compatibility contract: text-only/no-confidence requests are unaffected.
        let result = OutputGuard.check(answer, raw: raw, draft: draft, lowConfidenceWords: nil)
        #expect(result == .rejected("changed name"))
    }
}
