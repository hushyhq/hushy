import Testing
@testable import MurmurCore

@Suite("RetractionGuard")
struct RetractionGuardTests {
    @Test("rejects an answer that keeps the item in the list, detaching the reason", arguments: [
        ("Pick up milk and eggs, actually forget the eggs, we already have them.", "Pick up milk and eggs, we already have them."),
        ("We need apples, bananas, and oranges, no wait, skip the oranges, they're out of season anyway.",
         "We need apples, bananas, and oranges, they're out of season anyway."),
        ("Invite Tom and Priya to the meeting, actually not Tom, he's on vacation this week.",
         "Invite Tom and Priya to the meeting, he's on vacation this week."),
        ("Buy flour, sugar and butter, never mind the butter, because we still have a full stick in the fridge.",
         "Buy flour, sugar and butter, because we still have a full stick in the fridge."),
    ])
    func rejectsKeptItem(draft: String, answer: String) {
        let result = RetractionGuard.violation(answer: answer, draft: draft)
        #expect(result?.hasPrefix("reason detached") == true)
    }

    @Test("rejects dropping the item but keeping its reason (the reason would re-attach)")
    func rejectsDetachedReason() {
        let draft = "Call the electrician and the plumber, actually not the plumber, he already came by last week."
        let answer = "Call the electrician, he already came by last week."
        #expect(RetractionGuard.violation(answer: answer, draft: draft)?.hasPrefix("reason detached") == true)
    }

    @Test("accepts an explicit retraction that keeps the reason attached")
    func acceptsExplicitRetraction() {
        let draft = "Pick up milk and eggs, actually forget the eggs, we already have them."
        let answer = "Pick up milk. Forget the eggs, we already have them."
        #expect(RetractionGuard.violation(answer: answer, draft: draft) == nil)
    }

    @Test("rejects a reason-bearing retraction when the item remains in the active request")
    func rejectsActiveItemWithReason() {
        let draft = "Send the memorandum to Imani and Rafael, actually skip Rafael, Rafael moved teams last week."
        let answer = "Send the memorandum to Imani and Rafael. Skip Rafael, Rafael moved teams last week."
        #expect(RetractionGuard.violation(answer: answer, draft: draft)?.hasPrefix("kept retracted item") == true)
    }

    @Test("allows the item in the retraction and in a proper-name reason")
    func acceptsProperNameReason() {
        let draft = "Send the memorandum to Imani and Rafael, actually skip Rafael, Rafael moved teams last week."
        let answer = "Send the memorandum to Imani. Skip Rafael, Rafael moved teams last week."
        #expect(RetractionGuard.retractedItem(in: draft) == "Rafael")
        #expect(RetractionGuard.trailingClause(in: draft) == "Rafael moved teams last week")
        #expect(RetractionGuard.violation(answer: answer, draft: draft) == nil)
    }

    @Test("rejects an answer that drops the retracted item but also drops the trailing reason clause")
    func rejectsDroppedTrailingClause() {
        let draft = "The agenda covers budget, hiring and the roadmap, scratch hiring, we covered that yesterday in the standup."
        let answer = "The agenda covers budget and the roadmap. Scratch hiring."
        let result = RetractionGuard.violation(answer: answer, draft: draft)
        #expect(result?.hasPrefix("dropped trailing clause") == true)
    }

    @Test("does not fire when the draft has no retraction pattern")
    func noRetraction() {
        let draft = "Can you send me the notes by Friday?"
        let answer = "Can you send me the notes by Friday?"
        #expect(RetractionGuard.violation(answer: answer, draft: draft) == nil)
    }

    @Test("negated removal and cancellation instructions are not retractions", arguments: [
        "Do not remove the archive.",
        "Please don't skip the second review.",
        "Never forget the emergency contact.",
        "We must not accidentally cancel the reservation.",
        "You shouldn't drop the last column.",
        "Don't scratch the display.",
    ])
    func negatedInstruction(draft: String) {
        #expect(RetractionGuard.retractedItem(in: draft) == nil)
        #expect(RetractionGuard.violation(answer: draft, draft: draft) == nil)
        #expect(RetractionGuard.droppingBareRetraction(draft, draft: draft) == draft)
    }

    @Test("a retraction verb used as an ordinary verb is not a retraction", arguments: [
        "We should actually skip the Friday demo.",
        "The customer said they might cancel unless we offer a discount.",
        "Can we drop the second vendor to cut costs?",
        "I would remove the old banner and I would actually cancel the trial.",
        "Do you think to keep the team focused we should actually skip the Friday demo?",
        "Do you reckon to save money we should really cancel the second lease?",
    ])
    func ordinaryVerb(draft: String) {
        #expect(RetractionGuard.retractedItem(in: draft) == nil)
        #expect(RetractionGuard.violation(answer: draft, draft: draft) == nil)
    }

    @Test("a verb after a modal takes an item back when the item was named earlier in the dictation", arguments: [
        ("Bring pens and pencils, we should actually skip the pencils.", "pencils"),
        ("We ordered pizza and salad, then we might actually cancel the salad.", "salad"),
    ])
    func modalVerbOnANamedItem(draft: String, item: String) {
        #expect(RetractionGuard.retractedItem(in: draft) == item)
    }

    @Test("skips a negated cue and still finds a later real correction")
    func laterCorrection() {
        let draft = "Don't remove the cover. Bring pens and pencils, actually skip the pencils."
        #expect(RetractionGuard.retractedItem(in: draft) == "pencils")
        #expect(RetractionGuard.violation(answer: "Don't remove the cover. Bring pens.", draft: draft) == nil)
        #expect(RetractionGuard.violation(answer: draft, draft: draft)?.hasPrefix("kept retracted item") == true)
    }

    @Test("finds the retracted item across different retraction verbs", arguments: [
        ("Order a medium pizza and a salad, actually cancel the salad, everyone already ate lunch.", "salad"),
        ("Bring the charger and the adapter, no forget the adapter, the hotel has one and it's heavy anyway.", "adapter"),
        ("Send the report to Maria and to Devon, actually not Devon, he moved to a different team last month.", "Devon"),
        ("Grab plates, napkins and cups, no not the cups, we bought a big pack of those last weekend.", "cups"),
    ])
    func findsRetractedItem(draft: String, expectedItem: String) {
        let item = RetractionGuard.retractedItem(in: draft)
        #expect(item?.lowercased() == expectedItem.lowercased())
    }
}

@Suite("RetractionMerge")
struct RetractionMergeTests {
    @Test("drops the retracted item from a list and keeps the trailing reason clause", arguments: [
        ("We need apples, bananas, and oranges, no wait, skip the oranges, they're out of season anyway.",
         "We need apples and bananas. Skip the oranges, they're out of season anyway."),
        ("Bring the charger and the adapter, no forget the adapter, the hotel has one and it's heavy anyway.",
         "Bring the charger. Forget the adapter, the hotel has one and it's heavy anyway."),
        ("Send the report to Maria and to Devon, actually not Devon, he moved to a different team last month so it's not his area anymore.",
         "Send the report to Maria. Not Devon, he moved to a different team last month so it's not his area anymore."),
        ("Grab plates, napkins and cups, no not the cups, we bought a big pack of those last weekend.",
         "Grab plates and napkins. Not the cups, we bought a big pack of those last weekend."),
        ("Buy flour, sugar and butter, never mind the butter, because we still have a full stick in the fridge.",
         "Buy flour and sugar. Never mind the butter, because we still have a full stick in the fridge."),
    ])
    func merges(draft: String, expected: String) {
        #expect(RetractionMerge.apply(draft) == expected)
    }

    @Test("declines when there is no retraction pattern to merge")
    func declinesOrdinaryText() {
        #expect(RetractionMerge.apply("Can you send me the notes by Friday?") == nil)
    }
}

@Suite("CandidateRanker tie detection")
struct CandidateRankerTieTests {
    // Neither candidate contains a correction-cue word, so both have residue 0 — a genuine tie
    // between two differently-worded candidates, not a case the cheap heuristic can already
    // decide on its own (unlike a correction where one candidate still has "no"/"actually" left).
    let raw = "Set up the projector and dim the lights before the meeting starts."
    let rules = "Set up the projector and dim the lights before the meeting starts."
    let model = "Set up the projector, dim the lights before the meeting starts."

    @Test("a tie is only reported when residues match and the texts differ")
    func tieRequiresDifferingTextsAndEqualResidue() {
        #expect(CandidateRanker.isTie(raw: raw, rules: rules, model: model))
    }

    @Test("identical candidates are not a tie (nothing to break)")
    func identicalCandidatesAreNotATie() {
        #expect(!CandidateRanker.isTie(raw: raw, rules: rules, model: rules))
    }

    @Test("differing residue is not a tie — the heuristic already decides")
    func differingResidueIsNotATie() {
        let raw = "I need two carrots, two beans, no, just one carrot"
        #expect(!CandidateRanker.isTie(
            raw: raw, rules: "I need just one carrot",
            model: "I need two carrots, two beans, no, just one carrot."))
    }

    @Test("a missing rerank assessment leaves the default (prefer model) on a tie")
    func missingAssessmentDefaultsToModel() {
        #expect(CandidateRanker.prefersModel(raw: raw, rules: rules, model: model, assessment: nil))
    }

    @Test("a rerank assessment preferring rules overrides the tie default")
    func assessmentPreferringRulesOverrides() {
        #expect(!CandidateRanker.prefersModel(
            raw: raw, rules: rules, model: model,
            assessment: SmartCleaner.Assessment(prefers: .rules, droppedInformation: true)))
    }

    @Test("a rerank assessment preferring neither overrides the tie default")
    func assessmentPreferringNeitherOverrides() {
        #expect(!CandidateRanker.prefersModel(
            raw: raw, rules: rules, model: model,
            assessment: SmartCleaner.Assessment(prefers: .neither, droppedInformation: true)))
    }

    @Test("a rerank assessment preferring the model keeps the tie default")
    func assessmentPreferringModelKeepsDefault() {
        #expect(CandidateRanker.prefersModel(
            raw: raw, rules: rules, model: model,
            assessment: SmartCleaner.Assessment(prefers: .model, droppedInformation: false)))
    }

    @Test("a rerank assessment preferring both keeps the tie default")
    func assessmentPreferringBothKeepsDefault() {
        #expect(CandidateRanker.prefersModel(
            raw: raw, rules: rules, model: model,
            assessment: SmartCleaner.Assessment(prefers: .both, droppedInformation: false)))
    }
}
