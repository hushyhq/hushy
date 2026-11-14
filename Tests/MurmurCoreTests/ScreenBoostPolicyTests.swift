import Testing
@testable import MurmurCore

@Suite("ScreenBoostPolicy")
struct ScreenBoostPolicyTests {
    @Test("UI labels and ordinary words are not boosted")
    func dropsUILabels() {
        for label in ["Next", "Done", "Cancel", "Text", "Paste", "text", "paste"] {
            #expect(!ScreenBoostPolicy.shouldBoost(label))
        }
    }

    @Test("product and person names are boosted")
    func keepsNames() {
        #expect(ScreenBoostPolicy.shouldBoost("Claude"))
        // A name that is also an English word comes from installed app names or the Dictionary, not the screen.
        #expect(!ScreenBoostPolicy.shouldBoost("Notion"))
        #expect(ScreenBoostPolicy.shouldBoost("VS Code"))
        #expect(ScreenBoostPolicy.shouldBoost("Siobhan"))
    }

    @Test("window merge drops chrome labels")
    func mergedFilters() {
        let merged = WindowContextPolicy.merged(
            fieldTerms: ["Claude"],
            windowTerms: ["Next", "Paste", "Supabase", "Text"])
        #expect(merged.contains("Claude"))
        #expect(merged.contains("Supabase"))
        #expect(!merged.contains("Next"))
        #expect(!merged.contains("Paste"))
        #expect(!merged.contains("Text"))
    }
}

@Suite("DraftCommonWordGuard")
struct DraftCommonWordGuardTests {
    @Test("restores common words the draft had after a label boost")
    func restoresFromDraft() {
        let vocabulary = VocabularyContext(terms: [
            VocabularyTerm(text: "Next"), VocabularyTerm(text: "Text"),
        ])
        let outcome = DraftCommonWordGuard.reconcile(
            draft: "paste the text into the text box",
            release: "paste the Next into the Next box",
            vocabulary: vocabulary)
        #expect(outcome.repairs >= 2)
        #expect(outcome.text == "paste the text into the text box")
    }

    @Test("a capital letter the release pass added is not undone")
    func caseOnlyDifference() {
        let outcome = DraftCommonWordGuard.reconcile(
            draft: "the meeting moved to nine", release: "The meeting moved to nine", vocabulary: .empty)
        #expect(outcome.text == "The meeting moved to nine")
        #expect(outcome.disagreements == 0)
    }

    @Test("a name the hints rightly supplied is kept")
    func keepsRealName() {
        let vocabulary = VocabularyContext(terms: [VocabularyTerm(text: "Claude")])
        let outcome = DraftCommonWordGuard.reconcile(
            draft: "ask clot about it", release: "ask Claude about it", vocabulary: vocabulary)
        #expect(outcome.text == "ask Claude about it")
    }

    @Test("leaves release text when draft is missing")
    func noDraft() {
        let outcome = DraftCommonWordGuard.reconcile(
            draft: nil, release: "hello world", vocabulary: .empty)
        #expect(outcome.text == "hello world")
        #expect(outcome.repairs == 0)
    }

    @Test("restores a label swap inside a draft that is only the last few seconds")
    func restoresInsideLongerRelease() {
        let outcome = DraftCommonWordGuard.reconcile(
            draft: "paste the text",
            release: "please remember to paste the Next",
            vocabulary: .empty)
        #expect(outcome.repairs == 1)
        #expect(outcome.text == "please remember to paste the text")
    }

    @Test("joined installed names and aligned UI labels both restore in a clipped window")
    func installedNamesAndLabels() {
        let outcome = DraftCommonWordGuard.reconcile(
            draft: "save the text edit history and paste the text",
            release: "please save the TextEdit history and paste the Next.",
            vocabulary: .empty,
            installedApps: [.init(bundleID: "test.TextEdit", name: "TextEdit")])
        #expect(outcome.text == "please save the text edit history and paste the text.")
        #expect(outcome.repairs == 2)
    }

    @Test("does not slide the draft across a label the release inserted")
    func doesNotShiftWords() {
        let outcome = DraftCommonWordGuard.reconcile(
            draft: "paste the text please",
            release: "paste Next the text",
            vocabulary: .empty)
        #expect(outcome.repairs == 0)
        #expect(outcome.text == "paste Next the text")
    }

    @Test("restores the label inside a clipped draft window")
    func restoresClippedWindow() {
        let outcome = DraftCommonWordGuard.reconcile(
            draft: "the text",
            release: "paste the Next",
            vocabulary: .empty)
        #expect(outcome.repairs == 1)
        #expect(outcome.text == "paste the text")
    }

    @Test("restores the aligned label without sliding the other words")
    func restoresAlignedLabelOnly() {
        let outcome = DraftCommonWordGuard.reconcile(
            draft: "the text is fine now",
            release: "send the Next is fine",
            vocabulary: .empty)
        #expect(outcome.repairs == 1)
        #expect(outcome.text == "send the text is fine")
    }

    @Test("keeps the period on the release word it restores")
    func keepsReleasePunctuation() {
        let outcome = DraftCommonWordGuard.reconcile(
            draft: "paste the text",
            release: "paste the Next.",
            vocabulary: .empty)
        #expect(outcome.text == "paste the text.")
    }

    @Test("keeps a hinted name when the draft window is shorter than the release")
    func keepsNameInLongerRelease() {
        let vocabulary = VocabularyContext(terms: [VocabularyTerm(text: "Claude")])
        let outcome = DraftCommonWordGuard.reconcile(
            draft: "ask clot about it",
            release: "yesterday I asked Claude about it",
            vocabulary: vocabulary)
        #expect(outcome.text == "yesterday I asked Claude about it")
        #expect(outcome.repairs == 0)
    }
}

@Suite("ContextSpellingFixer ordinary words")
struct ContextSpellingFixerOrdinaryWordTests {
    @Test("does not rewrite a common word to a capitalized UI label on screen")
    func noCommonToLabel() {
        let terms = ["Next", "Done", "Claude"]
        #expect(ContextSpellingFixer.fix("paste the text here", terms: terms) == "paste the text here")
    }
}
