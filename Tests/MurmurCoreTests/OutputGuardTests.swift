import Testing
@testable import MurmurCore

@Suite("OutputGuard")
struct OutputGuardTests {
    @Test("accepts an unchanged time converted in the rules draft")
    func acceptsConvertedTime() {
        let raw = "Please arrive at four twenty tomorrow."
        let draft = InverseTextNormalizer.apply(raw)
        #expect(draft == "Please arrive at 4:20 tomorrow.")
        if case .rejected(let reason) = OutputGuard.check("Please arrive at 4:20 tomorrow.", raw: raw, draft: draft) {
            Issue.record("expected converted time to be accepted: \(reason)")
        }
    }
    @Test("rejects a rewrite that drops a negation present in the draft")
    func dropsNegation() {
        let raw = "I will not approve this request."
        let draft = "I will not approve this request."
        let answer = "I will approve this request."
        let result = OutputGuard.check(answer, raw: raw, draft: draft)
        #expect(result == .rejected("dropped negation"))
    }

    @Test("rejects a rewrite that adds a negation absent from the draft")
    func addsNegation() {
        let raw = "I will approve this request."
        let draft = "I will approve this request."
        let answer = "I will not approve this request."
        let result = OutputGuard.check(answer, raw: raw, draft: draft)
        #expect(result == .rejected("added negation"))
    }

    @Test("accepts a negation change when the draft carries a correction cue")
    func negationChangeWithCorrectionCue() {
        let raw = "Approve this request, no, actually do not approve it."
        let draft = "Approve this request, no, actually do not approve it."
        let answer = "Do not approve this request."
        let result = OutputGuard.check(answer, raw: raw, draft: draft)
        if case .rejected = result {
            Issue.record("expected acceptance when a correction cue explains the negation change")
        }
    }

    @Test("rejects a rewrite that changes a digit sequence present in the draft")
    func changesDigits() {
        let raw = "Call me at 5pm on the 12th."
        let draft = "Call me at 5pm on the 12th."
        let answer = "Call me at 5pm on the 15th."
        let result = OutputGuard.check(answer, raw: raw, draft: draft)
        #expect(result == .rejected("changed digits"))
    }

    @Test("rejects a rewrite that changes a capitalized name present in the draft")
    func changesName() {
        let raw = "Send it to Sarah tomorrow."
        let draft = "Send it to Sarah tomorrow."
        let answer = "Send it to Karen tomorrow."
        let result = OutputGuard.check(answer, raw: raw, draft: draft)
        #expect(result == .rejected("changed name"))
    }

    @Test("accepts a digit or name change when the draft has an explicit self-correction")
    func digitChangeWithSelfCorrection() {
        let raw = "Call me at 3, no, 4."
        let draft = "Call me at 3, no, 4."
        let answer = "Call me at 4."
        let result = OutputGuard.check(answer, raw: raw, draft: draft)
        if case .rejected = result {
            Issue.record("expected acceptance when the draft itself carries the correction")
        }
    }

    @Test("accepts an ordinary rewrite with no negation, digit or name changes")
    func ordinaryAcceptance() {
        let raw = "Can you uh send me the notes by Friday?"
        let draft = "Can you send me the notes by Friday?"
        let answer = "Can you send me the notes by Friday?"
        let result = OutputGuard.check(answer, raw: raw, draft: draft)
        if case .rejected = result {
            Issue.record("expected an ordinary cleanup rewrite to be accepted")
        }
    }

    // MARK: - CriticalTokenGuard sees ITN-normalized digits in the draft

    /// `TextCleaner` runs `InverseTextNormalizer` before the model is ever consulted, so by the
    /// time `CriticalTokenGuard` compares digits, the draft already reads "25" rather than
    /// "twenty-five". This means a model rewrite can't quietly swap the number back to words (or
    /// to a different number) without tripping the "changed digits" guard — the guard would
    /// otherwise never have seen a digit to compare against.
    @Test("the guard catches a model rewrite that changes an ITN-converted digit")
    func catchesChangedITNDigit() {
        let cleaner = TextCleaner()
        let draft = cleaner.clean("Set the timer for twenty-five minutes.").text
        #expect(draft == "Set the timer for 25 minutes.")
        let answer = "Set the timer for 30 minutes."
        let result = OutputGuard.check(answer, raw: "Set the timer for twenty-five minutes.", draft: draft)
        #expect(result == .rejected("changed digits"))
    }

    @Test("the guard allows a rewrite that keeps the ITN-converted digit unchanged")
    func allowsUnchangedITNDigit() {
        let cleaner = TextCleaner()
        let draft = cleaner.clean("Um, set the timer for twenty-five minutes.").text
        let answer = "Set the timer for 25 minutes."
        let result = OutputGuard.check(answer, raw: "Um, set the timer for twenty-five minutes.", draft: draft)
        if case .rejected = result {
            Issue.record("expected acceptance: the digit 25 is unchanged from the ITN-converted draft")
        }
    }

    // MARK: - Grammar-repair function-word allowance

    @Test("under .grammarRepair, allows an inserted article that fixes agreement, without counting against the invented budget")
    func allowsInsertedArticleForAgreementFix() {
        let raw = "The reports is due Friday and it need to go to both manager."
        let draft = raw
        let answer = "The report is due Friday and it needs to go to both managers."
        let result = OutputGuard.check(answer, raw: raw, draft: draft, profile: .grammarRepair)
        if case .rejected(let reason) = result {
            Issue.record("expected acceptance of an agreement fix, got rejection: \(reason)")
        }
    }

    @Test("under .grammarRepair, allows a run-on split into two sentences that repeats a free subject pronoun")
    func allowsRunOnSplitWithRepeatedPronoun() {
        let raw = "We should launch before the holidays if the numbers hold up and the team is ready " +
            "and legal signs off and marketing has the assets done because otherwise we lose the quarter"
        let draft = raw
        let answer = "We should launch before the holidays if the numbers hold up and the team is ready. " +
            "Legal needs to sign off and marketing needs the assets done, or we lose the quarter."
        let result = OutputGuard.check(answer, raw: raw, draft: draft, profile: .grammarRepair)
        if case .rejected(let reason) = result {
            Issue.record("expected acceptance of a run-on split using only free function words, got: \(reason)")
        }
    }

    @Test("under .disfluencyOnly (the default, used by .clean), the same agreement fix is rejected — that level never touches grammar")
    func disfluencyOnlyRejectsAgreementFix() {
        let raw = "The reports is due Friday and it need to go to both manager."
        let draft = raw
        let answer = "The report is due Friday and it needs to go to both managers."
        let result = OutputGuard.check(answer, raw: raw, draft: draft)
        guard case .rejected = result else {
            Issue.record("expected .disfluencyOnly to reject a grammar/agreement fix it was never asked to make")
            return
        }
    }

    @Test("under .disfluencyOnly, the same run-on split is rejected — splitting/restructuring is a .polished-only allowance")
    func disfluencyOnlyRejectsRunOnSplit() {
        let raw = "We should launch before the holidays if the numbers hold up and the team is ready " +
            "and legal signs off and marketing has the assets done because otherwise we lose the quarter"
        let draft = raw
        let answer = "We should launch before the holidays if the numbers hold up and the team is ready. " +
            "Legal needs to sign off and marketing needs the assets done, or we lose the quarter."
        let result = OutputGuard.check(answer, raw: raw, draft: draft, profile: .disfluencyOnly)
        guard case .rejected = result else {
            Issue.record("expected .disfluencyOnly to reject a grammar restructure it was never asked to make")
            return
        }
    }

    @Test("still rejects a rewrite that invents a real content word under .grammarRepair, even alongside free function words")
    func rejectsInventedContentWordDespiteFreeWords() {
        let raw = "The report is due Friday."
        let draft = raw
        let answer = "The report and the budget summary is due Friday and Monday."
        let result = OutputGuard.check(answer, raw: raw, draft: draft, profile: .grammarRepair)
        guard case .rejected = result else {
            Issue.record("expected rejection: 'budget', 'summary' and 'monday' are invented content words")
            return
        }
    }

    @Test("still rejects a rewrite that drops a content word under .grammarRepair, even when only free words are added")
    func rejectsDroppedContentWordDespiteFreeWords() {
        let raw = "Send the invoice and the receipt to Sarah by Friday."
        let draft = raw
        // Drops "receipt" and "Friday" — real content — while only adding free function words.
        let answer = "Send the invoice to Sarah."
        let result = OutputGuard.check(answer, raw: raw, draft: draft, profile: .grammarRepair)
        guard case .rejected = result else {
            Issue.record("expected rejection: dropped content words 'receipt' and 'friday'")
            return
        }
    }

    @Test("free function words are still bounded by the dropped-too-much floor under .grammarRepair")
    func freeWordsDoNotBypassDroppedTooMuchFloor() {
        let raw = "Please review the quarterly budget report and send feedback to the whole finance team by Friday."
        let draft = raw
        let answer = "The."
        let result = OutputGuard.check(answer, raw: raw, draft: draft, profile: .grammarRepair)
        #expect(result == .rejected("dropped too much"))
    }

    // MARK: - LegitRepeatGuard (collapsing a legitimate doubled word)

    @Test("rejects a rewrite that collapses 'very very' to a single 'very'")
    func rejectsCollapsedVeryVery() {
        let raw = "It was very very cold yesterday."
        let draft = raw
        let answer = "It was very cold yesterday."
        let result = OutputGuard.check(answer, raw: raw, draft: draft, profile: .grammarRepair)
        guard case .rejected(let reason) = result, reason.contains("very") else {
            Issue.record("expected rejection for collapsing a legitimate 'very very' doubling, got \(result)")
            return
        }
    }

    @Test("rejects a rewrite that collapses 'that that' to a single 'that'")
    func rejectsCollapsedThatThat() {
        let raw = "I think that that is fine."
        let draft = raw
        let answer = "I think that is fine."
        let result = OutputGuard.check(answer, raw: raw, draft: draft, profile: .grammarRepair)
        guard case .rejected = result else {
            Issue.record("expected rejection for collapsing a legitimate 'that that' doubling")
            return
        }
    }

    @Test("accepts a rewrite that keeps 'very very' unchanged")
    func acceptsUnchangedVeryVery() {
        let raw = "It was very very cold yesterday."
        let draft = raw
        let answer = "It was very very cold yesterday."
        let result = OutputGuard.check(answer, raw: raw, draft: draft, profile: .grammarRepair)
        if case .rejected(let reason) = result {
            Issue.record("expected acceptance: the doubling was preserved, got rejection: \(reason)")
        }
    }

    @Test("does not false-positive on a word that legitimately appears twice in different places")
    func noFalsePositiveOnUnrelatedRepeat() {
        // "the" appears twice but never doubled adjacently in either draft or answer.
        let raw = "Send the report to the manager by Friday."
        let draft = raw
        let answer = "Send the report to the manager by Friday, please."
        let result = OutputGuard.check(answer, raw: raw, draft: draft, profile: .grammarRepair)
        if case .rejected(let reason) = result, reason.contains("collapsed a legitimate doubled word") {
            Issue.record("false positive: 'the' was never doubled adjacently, got: \(reason)")
        }
    }

    @Test("still rejects a genuine disfluency collapse of an ambiguous repeat only when it's truly a doubling, not when the word appears once naturally elsewhere")
    func noFalsePositiveOnSingleOccurrenceWord() {
        let raw = "It was cold yesterday."
        let draft = raw
        let answer = "It was very cold yesterday."
        // This should be caught by the invented-word check, not LegitRepeatGuard (there's no
        // doubling in the draft to begin with).
        let result = OutputGuard.check(answer, raw: raw, draft: draft, profile: .grammarRepair)
        if case .rejected(let reason) = result, reason.contains("collapsed a legitimate doubled word") {
            Issue.record("LegitRepeatGuard should not fire when the draft never had a doubling: \(reason)")
        }
    }

    // MARK: - CriticalTokenGuard connective-swap check

    @Test("rejects a rewrite that swaps 'but' for 'and'")
    func rejectsSwappedConnective() {
        let raw = "The design is done but the docs are missing."
        let draft = raw
        let answer = "The design is done and the docs are missing."
        let result = OutputGuard.check(answer, raw: raw, draft: draft, profile: .grammarRepair)
        guard case .rejected(let reason) = result, reason.contains("changed connective") else {
            Issue.record("expected rejection for swapping 'but' to 'and', got \(result)")
            return
        }
    }

    @Test("accepts a rewrite that keeps the same connective")
    func acceptsUnchangedConnective() {
        let raw = "The design is done but the docs are missing."
        let draft = raw
        let answer = "The design is done, but the docs are missing."
        let result = OutputGuard.check(answer, raw: raw, draft: draft, profile: .grammarRepair)
        if case .rejected(let reason) = result {
            Issue.record("expected acceptance: the connective 'but' is unchanged, got: \(reason)")
        }
    }

    @Test("does not reject a run-on split that legitimately drops a connecting word at the new sentence boundary")
    func acceptsRunOnSplitDroppingConnective() {
        let raw = "We should ship it and the team agrees and the timeline works."
        let draft = raw
        // Splitting into two sentences drops one "and" at the boundary — a count change, not a
        // swap, so it must not be rejected by the connective guard.
        let answer = "We should ship it. The team agrees and the timeline works."
        let result = OutputGuard.check(answer, raw: raw, draft: draft, profile: .grammarRepair)
        if case .rejected(let reason) = result, reason.contains("changed connective") {
            Issue.record("a count change from splitting a run-on must not be flagged as a connective swap: \(reason)")
        }
    }

    @Test("accepts a connective change when the draft carries a correction cue")
    func acceptsConnectiveChangeWithCorrectionCue() {
        let raw = "Ship it Monday, no, actually ship it but hold the announcement."
        let draft = raw
        let answer = "Ship it and hold the announcement."
        let result = OutputGuard.check(answer, raw: raw, draft: draft, profile: .grammarRepair)
        if case .rejected(let reason) = result, reason.contains("changed connective") {
            Issue.record("expected the correction-cue carve-out to allow this connective change, got: \(reason)")
        }
    }

    // MARK: - WholeClauseRetractionGuard

    @Test("rejects a rewrite that keeps a whole clause retracted with 'never mind'")
    func rejectsKeptWholeClauseRetraction() {
        let raw = "Call the plumber about the sink, actually never mind, it stopped leaking on its own this morning."
        let draft = raw
        let answer = "Call the plumber about the sink. It stopped leaking on its own this morning."
        let result = OutputGuard.check(answer, raw: raw, draft: draft)
        guard case .rejected(let reason) = result, reason.contains("kept retracted clause") else {
            Issue.record("expected rejection for keeping the retracted 'call the plumber' clause, got \(result)")
            return
        }
    }

    @Test("accepts a rewrite that correctly drops the whole retracted clause")
    func acceptsDroppedWholeClauseRetraction() {
        let raw = "Call the plumber about the sink, actually never mind, it stopped leaking on its own this morning."
        let draft = raw
        let answer = "Never mind, it stopped leaking on its own this morning."
        let result = OutputGuard.check(answer, raw: raw, draft: draft)
        if case .rejected(let reason) = result, reason.contains("kept retracted clause") {
            Issue.record("expected acceptance: the retracted clause was correctly dropped, got: \(reason)")
        }
    }

    @Test("does not confuse words repeated across shorter clauses with a retained retracted clause")
    func wholeClauseRetractionRequiresOrderedSpan() {
        let draft = "Review the launch plan, actually never mind, the plan is already under review."
        let answer = "Never mind. The launch plan is already under review."
        #expect(WholeClauseRetractionGuard.violation(answer: answer, draft: draft) == nil)
    }

    @Test("does not fire when the draft has no 'never mind' retraction")
    func noFalsePositiveWithoutNeverMind() {
        let raw = "Call the plumber about the sink, it's been leaking for a week."
        let draft = raw
        let answer = "Call the plumber about the sink, it's been leaking for a week."
        let result = OutputGuard.check(answer, raw: raw, draft: draft)
        if case .rejected(let reason) = result, reason.contains("kept retracted clause") {
            Issue.record("false positive: there is no 'never mind' retraction here, got: \(reason)")
        }
    }

    @Test("WholeClauseRetractionGuard.merge drops the retracted leading clause and the never-mind cue")
    func wholeClauseMergeDropsRetractedClause() {
        let draft = "Call the plumber about the sink, actually never mind, it stopped leaking on its own this morning."
        let merged = WholeClauseRetractionGuard.merge(draft)
        #expect(merged == "It stopped leaking on its own this morning.")
    }

    @Test("WholeClauseRetractionGuard.merge returns nil when there is no never-mind retraction")
    func wholeClauseMergeReturnsNilWithoutRetraction() {
        let draft = "Call the plumber about the sink, it's been leaking for a week."
        #expect(WholeClauseRetractionGuard.merge(draft) == nil)
    }

    @Test("WholeClauseRetractionGuard.merge leaves the single-item 'never mind the X' shape alone")
    func wholeClauseMergeIgnoresSingleItemRetraction() {
        let draft = "Buy flour, sugar and butter, never mind the butter, because we still have a full stick in the fridge."
        #expect(WholeClauseRetractionGuard.merge(draft) == nil)
    }

    // MARK: - SmartCleaner.rulesFallback (model rejected or timed out)

    @Test("a timed-out model call still resolves a whole-clause 'never mind' retraction")
    func timeoutFallsBackToWholeClauseMerge() {
        let draft = "Call the plumber about the sink, actually never mind, it stopped leaking on its own this morning."
        let text = SmartCleaner.rulesFallback(reason: "timeout or model error", draft: draft)
        #expect(text == "It stopped leaking on its own this morning.")
    }

    @Test("a timed-out model call resolves a single-item retraction with RetractionMerge, not the whole-clause merge")
    func timeoutPrefersSingleItemMerge() {
        let draft = "Buy flour, sugar and butter, never mind the butter, because we still have a full stick in the fridge."
        let text = SmartCleaner.rulesFallback(reason: "timeout or model error", draft: draft)
        // `RetractionMerge` owns this shape (it drops "butter" from the list); the whole-clause
        // merge must not strip through "never mind the" and leave "The butter, because…".
        #expect(text.lowercased().hasPrefix("buy flour"))
        #expect(!text.hasPrefix("The butter"))
        #expect(text.contains("full stick in the fridge"))
    }

    @Test("a guard rejection with no retraction shape leaves the draft as the rules wrote it")
    func otherRejectionKeepsDraft() {
        let draft = "The report is due Friday and it needs to go to both managers."
        #expect(SmartCleaner.rulesFallback(reason: "changed an unmarked word", draft: draft) == draft)
    }
}
