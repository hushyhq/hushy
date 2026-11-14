import Testing
@testable import MurmurCore

/// `SpokenGrammar.mightNeedRepair` is the hybrid trigger for asking the on-device model to fix
/// plain spoken-grammar problems (false starts, dangling negated modals, mid-clause hedges, long
/// run-ons) that none of the existing `ModelHints` checks catch. Heavy on negatives: a
/// false-positive here costs one extra (budget-capped, fallback-safe) model call, but the real
/// risk this suite guards against is a detector so broad it fires on ordinary, already-fine
/// speech and pointlessly asks the model on every short dictation.
@Suite("SpokenGrammar")
struct SpokenGrammarTests {
    // MARK: - Dangling negated modal restart

    @Test("detects the product owner's example: dangling negated modal then restart")
    func detectsDanglingNegatedModalRestart() {
        let text = "Voice signatures also I think should be in free because if we are stating " +
            "labelling as free shouldn't, voice signature should automatically be free"
        #expect(SpokenGrammar.hasDanglingNegatedModalRestart(text))
        #expect(SpokenGrammar.mightNeedRepair(text))
    }

    @Test("detects a simple dangling 'wouldn't,' restart")
    func detectsSimpleDanglingModal() {
        #expect(SpokenGrammar.hasDanglingNegatedModalRestart("I wouldn't, actually I would go with the blue one"))
    }

    @Test("does not fire on an ordinary sentence with a negated modal and no restart")
    func noFalsePositiveOnPlainNegatedModal() {
        #expect(!SpokenGrammar.hasDanglingNegatedModalRestart("I shouldn't have said that, but I did."))
    }

    @Test("does not fire when a comma just separates two unrelated clauses")
    func noFalsePositiveOnUnrelatedClauses() {
        #expect(!SpokenGrammar.hasDanglingNegatedModalRestart("She can't come today, but she will tomorrow."))
    }

    @Test("does not fire on a negated modal followed by a genuinely different modal")
    func noFalsePositiveOnDifferentModal() {
        #expect(!SpokenGrammar.hasDanglingNegatedModalRestart("I shouldn't, could you check with Sam instead?"))
    }

    // MARK: - Mid-clause hedge

    @Test("detects 'I think' sitting mid-clause instead of at the front")
    func detectsMidClauseHedge() {
        #expect(SpokenGrammar.hasMidClauseHedge("Voice signatures also I think should be free."))
    }

    @Test("does not fire when the hedge already opens the sentence")
    func noFalsePositiveHedgeAtFront() {
        #expect(!SpokenGrammar.hasMidClauseHedge("I think we should go with the blue design."))
    }

    @Test("does not fire on a sentence with no hedge at all")
    func noFalsePositiveNoHedge() {
        #expect(!SpokenGrammar.hasMidClauseHedge("The report is due Friday and it needs to go to both managers."))
    }

    @Test("does not fire on 'I guess' at the very front")
    func noFalsePositiveGuessAtFront() {
        #expect(!SpokenGrammar.hasMidClauseHedge("I guess we can start without her."))
    }

    @Test("answers a long unpunctuated sentence with no hedge without backtracking")
    func longRunOnWithoutHedgeIsFast() {
        // A 14 h `murmur-eval grammar` run was found pinned inside this detector: the old
        // `\w+['’]?\w*` word shape let every word split ambiguously, and `{2,}` multiplied the
        // splits across the sentence, so a long run-on with no hedge backtracked exponentially.
        let sentence = Array(repeating: "the quarterly numbers came in above forecast", count: 8).joined(separator: " ")
        let start = ContinuousClock.now
        let hit = SpokenGrammar.hasMidClauseHedge(sentence)
        #expect(!hit)
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    // MARK: - Repeated subject restart

    @Test("detects a repeated multi-word subject restart across a comma")
    func detectsRepeatedSubjectRestart() {
        #expect(SpokenGrammar.hasRepeatedSubjectRestart("The quarterly report, the quarterly report needs another pass."))
    }

    @Test("does not fire on an ordinary two-item list")
    func noFalsePositiveOnList() {
        #expect(!SpokenGrammar.hasRepeatedSubjectRestart("Pick up milk and eggs, bread and butter."))
    }

    @Test("does not fire on two different short phrases separated by a comma")
    func noFalsePositiveDifferentPhrases() {
        #expect(!SpokenGrammar.hasRepeatedSubjectRestart("The budget review, the hiring plan needs work too."))
    }

    // MARK: - Long unpunctuated run-on

    @Test("detects a long run-on with no sentence-ending punctuation at all")
    func detectsLongRunOn() {
        let text = "we should launch before the holidays if the numbers hold up and the team " +
            "is ready and legal signs off and marketing has the assets done because otherwise " +
            "we lose the whole quarter and nobody wants that to happen to us this year"
        #expect(SpokenGrammar.isLongUnpunctuatedRunOn(text))
    }

    @Test("does not fire on a long sentence that already ends with punctuation")
    func noFalsePositiveLongButPunctuated() {
        let text = "We should launch before the holidays if the numbers hold up and the team " +
            "is ready and legal signs off and marketing has the assets done."
        #expect(!SpokenGrammar.isLongUnpunctuatedRunOn(text))
    }

    @Test("does not fire on a short unpunctuated fragment")
    func noFalsePositiveShortFragment() {
        #expect(!SpokenGrammar.isLongUnpunctuatedRunOn("thanks so much for the help today"))
    }

    // MARK: - mightNeedRepair negatives (already-fine, casual, questions, code-ish, names)

    @Test("does not flag already-grammatical, punctuated speech")
    func negativeAlreadyGrammatical() {
        #expect(!SpokenGrammar.mightNeedRepair("Can you send me the notes by Friday?"))
    }

    @Test("does not flag casual short messages")
    func negativeCasualMessage() {
        #expect(!SpokenGrammar.mightNeedRepair("hey can u grab lunch later, no rush just lmk"))
    }

    @Test("does not flag a plain question")
    func negativeQuestion() {
        #expect(!SpokenGrammar.mightNeedRepair("Is the meeting still at 3?"))
    }

    @Test("does not flag code-ish dictation")
    func negativeCodeIsh() {
        #expect(!SpokenGrammar.mightNeedRepair("The function returns null if the user isn't found in the cache."))
    }

    @Test("does not flag a name clarification")
    func negativeNameClarification() {
        #expect(!SpokenGrammar.mightNeedRepair("Kris with a K, not Chris, is joining the call."))
    }

    @Test("does not flag a short plain sentence")
    func negativeShortPlainSentence() {
        #expect(!SpokenGrammar.mightNeedRepair("Let's meet at 9 tomorrow."))
    }

    @Test("does not flag an ordinary two-item grocery list")
    func negativeGroceryList() {
        #expect(!SpokenGrammar.mightNeedRepair("Pick up milk and eggs on the way home."))
    }

    // MARK: - Multi-word phrase repeat (detection only)

    @Test("detects an exact multi-word phrase repeat")
    func detectsMultiWordPhraseRepeat() {
        #expect(SpokenGrammar.hasMultiWordPhraseRepeat("whether it's a it's it's a three second dictation"))
    }

    @Test("does not flag a single repeated word as a multi-word phrase repeat")
    func noFalsePositiveSingleWordRepeat() {
        // "very very" is a single repeated word, deliberately left ambiguous for the model,
        // not this detector (see `hasMultiWordPhraseRepeat`'s doc comment).
        #expect(!SpokenGrammar.hasMultiWordPhraseRepeat("it was very very cold yesterday"))
    }

    @Test("does not flag an ordinary sentence with no repeat")
    func noFalsePositiveNoRepeat() {
        #expect(!SpokenGrammar.hasMultiWordPhraseRepeat("we should launch the update next week"))
    }

    // MARK: - Orphan fragment in repeat (detection only)

    @Test("detects the orphan single-letter fragment shape")
    func detectsOrphanFragmentInRepeat() {
        #expect(SpokenGrammar.hasOrphanFragmentInRepeat("in the w in the above sentence"))
    }

    @Test("does not flag a real short word repeated as part of an ordinary phrase")
    func noFalsePositiveOrphanRealWord() {
        // "to" is a standalone word, never an orphan fragment.
        #expect(!SpokenGrammar.hasOrphanFragmentInRepeat("in the to in the meeting room"))
    }

    // MARK: - mightNeedRepair covers the coordinator-reported real failures

    @Test("flags the 3-second/40-second dictation example (filler + restart, no length floor)")
    func flagsShortDictationExample() {
        let text = "It is like 3-second dictation or is it like 40-second dictation What do you think"
        #expect(SpokenGrammar.mightNeedRepair(text))
    }

    @Test("flags the nested repeat-and-orphan-fragment example")
    func flagsNestedRepeatExample() {
        let text = "For example, in the w in the above sentence, I think it should have been it doesn't " +
            "matter whether it's a it's it's a three second dictation or a 40 second dictation."
        #expect(SpokenGrammar.mightNeedRepair(text))
    }

    // MARK: - Legitimate doubled-word negatives (must NOT be flagged as needing rules-level collapse;
    // these are exactly the "leave it to the model" cases per the product owner's direction)

    @Test("does not treat 'had had' as a multi-word phrase repeat")
    func negativeHadHad() {
        #expect(!SpokenGrammar.hasMultiWordPhraseRepeat("I had had enough of that conversation"))
    }

    @Test("does not treat 'that that' as a multi-word phrase repeat")
    func negativeThatThat() {
        #expect(!SpokenGrammar.hasMultiWordPhraseRepeat("I think that that is fine"))
    }

    @Test("does not treat 'bye bye' as a multi-word phrase repeat")
    func negativeByeBye() {
        #expect(!SpokenGrammar.hasMultiWordPhraseRepeat("we said bye bye and left"))
    }

    // MARK: - Deterministic fallback collapse (unambiguous patterns only)

    @Test("fallback collapses a strictly adjacent exact multi-word phrase repeat to one copy")
    func fallbackCollapsesPhraseRepeat() {
        // Strictly adjacent repeat with no extra words wedged in between.
        #expect(SpokenGrammar.collapseUnambiguousPhraseRepeat("let's ship the report the report today")
            == "let's ship the report today")
    }

    @Test("fallback does NOT collapse a nested/interleaved repeat like 'it's a it's it's a' — that shape is ambiguous enough to require the model, left as spoken when there is no fallback resolution for it")
    func fallbackLeavesNestedRepeatForModelOnly() {
        let text = "whether it's a it's it's a three second dictation"
        // The strict-adjacency fallback intentionally does not touch this: the repeat isn't a
        // clean "phrase phrase" doubling (there's an extra "it's" wedged in), so only the model
        // (given real sentence context) is trusted to resolve it — see the module doc.
        #expect(SpokenGrammar.collapseUnambiguousPhraseRepeat(text) == text)
    }

    @Test("fallback drops an orphan single-letter fragment inside a repeated lead-in")
    func fallbackDropsOrphanFragment() {
        let text = "in the w in the above sentence"
        let result = SpokenGrammar.dropOrphanFragmentInRepeat(text)
        #expect(result == "in the above sentence")
    }

    @Test("fallback leaves an ambiguous single-word repeat like 'very very' untouched")
    func fallbackLeavesAmbiguousRepeatAlone() {
        let text = "it was very very cold yesterday"
        #expect(SpokenGrammar.collapseUnambiguousDisfluency(text) == text)
    }

    @Test("fallback leaves 'that that' untouched")
    func fallbackLeavesThatThatAlone() {
        let text = "I think that that is fine"
        #expect(SpokenGrammar.collapseUnambiguousDisfluency(text) == text)
    }

    @Test("fallback leaves 'had had' untouched")
    func fallbackLeavesHadHadAlone() {
        let text = "I had had enough of that conversation"
        #expect(SpokenGrammar.collapseUnambiguousDisfluency(text) == text)
    }

    @Test("fallback leaves 'bye bye' untouched")
    func fallbackLeavesByeByeAlone() {
        let text = "we said bye bye and left"
        #expect(SpokenGrammar.collapseUnambiguousDisfluency(text) == text)
    }

    @Test("fallback resolves the unambiguous orphan-fragment part of the nested example, and leaves the ambiguous nested phrase repeat as spoken (model-only)")
    func fallbackResolvesNestedExample() {
        let text = "For example, in the w in the above sentence, I think it should have been it doesn't " +
            "matter whether it's a it's it's a three second dictation or a 40 second dictation."
        let result = SpokenGrammar.collapseUnambiguousDisfluency(text)
        #expect(!result.contains("in the w in the"))
        #expect(result.contains("in the above sentence"))
        // The nested "it's a it's it's a" repeat is left alone by the fallback — only the model
        // (which was already asked, per `mightNeedRepair`, and only falls through to this
        // fallback when unavailable/timed out/rejected) is trusted to resolve it.
        #expect(result.contains("it's a it's it's a"))
    }

    // MARK: - Discourse-marker overuse

    @Test("detects three repeats of the same discourse marker in one sentence")
    func detectsRepeatedDiscourseMarker() {
        #expect(SpokenGrammar.hasRepeatedDiscourseMarker("So actually we should actually probably actually do X."))
    }

    @Test("detects two repeats of a discourse marker")
    func detectsTwoRepeats() {
        #expect(SpokenGrammar.hasRepeatedDiscourseMarker("Basically the whole team is basically on board."))
    }

    @Test("does not flag a single use of a discourse marker")
    func noFalsePositiveSingleMarker() {
        #expect(!SpokenGrammar.hasRepeatedDiscourseMarker("I actually disagree with that plan."))
    }

    @Test("does not flag different discourse markers used once each")
    func noFalsePositiveDifferentMarkers() {
        #expect(!SpokenGrammar.hasRepeatedDiscourseMarker("So basically we just need to ship it."))
    }

    @Test("does not flag a sentence with no discourse markers at all")
    func noFalsePositiveNoMarkers() {
        #expect(!SpokenGrammar.hasRepeatedDiscourseMarker("The report is due Friday."))
    }

    @Test("mightHaveDisfluencyResidue picks up repeated discourse markers")
    func mightNeedRepairPicksUpDiscourseMarkers() {
        #expect(SpokenGrammar.mightHaveDisfluencyResidue("So actually we should actually probably actually do X."))
    }

    // MARK: - Discourse-marker fallback (unambiguous: 3+ exact repeats only)

    @Test("fallback collapses three repeats of the same marker down to two occurrences (drops the 3rd+)")
    func fallbackCollapsesThreeRepeats() {
        let result = SpokenGrammar.collapseRepeatedDiscourseMarkers("So actually we should actually probably actually do X.")
        // Only the first two "actually"s (and the "so") survive; the 3rd "actually" is dropped —
        // `collapseRepeatedDiscourseMarkers` only ever drops the 3rd-and-later occurrence of a
        // marker (see its doc comment: two occurrences alone isn't confidently a disfluency), so
        // the result still has two "actually"s, not one.
        let occurrences = result.components(separatedBy: "actually").count - 1
        #expect(occurrences == 2)
    }

    @Test("fallback leaves two repeats of a marker untouched — not confidently a disfluency on its own")
    func fallbackLeavesTwoRepeatsAlone() {
        let text = "Actually, I actually like it."
        #expect(SpokenGrammar.collapseRepeatedDiscourseMarkers(text) == text)
    }

    @Test("fallback leaves a single meaningful discourse marker untouched")
    func fallbackLeavesSingleMarkerAlone() {
        let text = "I actually disagree with that plan."
        #expect(SpokenGrammar.collapseRepeatedDiscourseMarkers(text) == text)
    }

    @Test("fallback leaves a sentence with no discourse markers completely unchanged")
    func fallbackLeavesPlainSentenceAlone() {
        let text = "The report is due Friday."
        #expect(SpokenGrammar.collapseRepeatedDiscourseMarkers(text) == text)
    }
}
