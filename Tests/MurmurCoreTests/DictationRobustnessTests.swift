import Testing
@testable import MurmurCore

/// Rules and guards added for dictation robustness (2026-09-26): hedge "like" before quantities,
/// English casing, fragment stutters, the model triggers, and the meaning-preserving guards.
@Suite("Dictation robustness rules and guards")
struct DictationRobustnessTests {
    private func clean(_ text: String) -> String {
        TextCleaner(options: CleanupOptions(level: .clean)).clean(text).text
    }

    // MARK: Hedge "like"

    @Test("drops hedge like before a quantity", arguments: [
        ("i spent like two hours on it", "I spent two hours on it."),
        ("it fails on files over like 2 gigs", "It fails on files over 2 gigs."),
        ("is it like more than two seconds", "Is it more than two seconds?"),
        ("it takes like five or six seconds to paste", "It takes five or six seconds to paste."),
        ("um yeah so like the build is green", "Yeah so the build is green."),
    ])
    func dropsHedgeLike(input: String, expected: String) {
        #expect(clean(input) == expected)
    }

    @Test("keeps verb and comparison like", arguments: [
        "I'd like two coffees please.",
        "We like 3 of the new icons.",
        "It looks like 2 people signed up.",
        "Numbers like 5 and 7 are prime.",
        "I would like 5 more minutes.",
        "Yeah, like that one.",
        "They don't like two of the colors.",
    ])
    func keepsVerbLike(text: String) {
        #expect(clean(text) == text)
    }

    // MARK: English casing

    @Test("capitalizes I, weekdays and months", arguments: [
        ("i think i'm right and i've checked", "I think I'm right and I've checked"),
        ("see you on monday", "see you on Monday"),
        ("the date should be march 3rd", "the date should be March 3rd"),
        ("we may ship in may 12", "we may ship in May 12"),
    ])
    func casing(input: String, expected: String) {
        #expect(EnglishCasing.apply(input) == expected)
    }

    @Test("leaves non-pronoun i and other words alone", arguments: [
        "i.e. the first one", "the iPhone and iOS", "item i of the list is x", "we march on", "it may rain",
        "path/i/file", "email@i.com",
    ])
    func casingNegatives(text: String) {
        let expected = text == "item i of the list is x" ? "item I of the list is x" : text
        #expect(EnglishCasing.apply(text) == expected)
    }

    // MARK: Fragment stutters

    @Test("drops a fragment that follows a real short word")
    func fragmentAfterShortWord() {
        // A lone letter is left for the model (it can be a label, "plan b"); a two-letter fragment is still removed.
        #expect(clean("can we m make the font a little bigger") == "Can we m make the font a little bigger?")
        #expect(clean("the whole layout sh shifts to the left") == "The whole layout shifts to the left.")
    }

    // MARK: Triggers

    @Test("hedge fillers trigger the model", arguments: [
        "So basically we need to fix the login.",
        "We need to like fix the login.",
        "Maybe we could like hide the word count.",
        "I just want it faster you know.",
    ])
    func hedgeTriggers(text: String) {
        #expect(SpokenGrammar.hasHedgeFiller(text))
    }

    @Test("verb and comparison like, and you know + clause, don't trigger", arguments: [
        "I like the new icon.",
        "It looks like rain.",
        "We would like a refund.",
        "You know what I mean.",
        "Things like that happen.",
        "Do you know the answer?",
    ])
    func hedgeNonTriggers(text: String) {
        #expect(!SpokenGrammar.hasHedgeFiller(text))
    }

    @Test("an unpunctuated stretch of 14+ words lacks sentence punctuation")
    func unpunctuated() {
        #expect(SpokenGrammar.lacksSentencePunctuation("the pill looks great the waveform is too big though and the timer should move"))
        #expect(!SpokenGrammar.lacksSentencePunctuation("The pill looks great. The waveform is too big, though, and the timer should move."))
        #expect(!SpokenGrammar.lacksSentencePunctuation("we shipped the update last night"))
    }

    // MARK: LegitRepeatGuard (narrowed to the closed legit set)

    @Test("rejects collapsing or rewording a legitimate double", arguments: [
        ("Okay, bye bye, talk soon.", "Okay, talk soon."),
        ("The demo went so so but they asked for more.", "The demo went well but they asked for more."),
        ("He said that that approach would not scale.", "He said the approach would not scale."),
        ("It was very very cold.", "It was very cold."),
    ])
    func rejectsLegitCollapse(draft: String, answer: String) {
        #expect(LegitRepeatGuard.violation(answer: answer, draft: draft) != nil)
    }

    @Test("allows removing a stutter or doubled discourse marker", arguments: [
        ("Actually actually the export works.", "Actually, the export works."),
        ("It it fails on big files.", "It fails on big files."),
        ("So so we should ship it.", "So we should ship it."),
        ("The demo went so so but they asked for more.", "The demo went so-so, but they asked for more."),
    ])
    func allowsStutterRemoval(draft: String, answer: String) {
        #expect(LegitRepeatGuard.violation(answer: answer, draft: draft) == nil)
    }

    // MARK: MeaningfulMarkerGuard

    @Test("rejects dropping a contrastive actually, a clarification lead-in or an admission", arguments: [
        ("I thought it was broken, but it actually works.", "I thought it was broken, but it works."),
        ("What I mean is that the sidebar should remember its width.", "The sidebar should remember its width."),
        ("I was wrong, it was my network.", "It was my network."),
        ("We asked the contractor to actually fix the leak before the weekend.",
         "We asked the contractor to fix the leak before the weekend."),
    ])
    func rejectsMeaningDrop(draft: String, answer: String) {
        #expect(MeaningfulMarkerGuard.violation(answer: answer, draft: draft) != nil)
    }

    @Test("allows pruning habitual actually and a correction actually", arguments: [
        ("So actually we should actually move it actually.", "We should move it."),
        ("Ship it Monday, actually no, Tuesday.", "Ship it Tuesday."),
        ("I actually disagree.", "I actually disagree."),
    ])
    func allowsHabitualActually(draft: String, answer: String) {
        #expect(MeaningfulMarkerGuard.violation(answer: answer, draft: draft) == nil)
    }

    // MARK: DisfluencyOnlyGuard (.clean)

    @Test("rejects a clean answer that drops or invents content", arguments: [
        ("Honestly I just want the pill to fade out faster after pasting you know.", "Honestly I just want the pill to fade out faster after you know."),
        ("It was fine again so I don't know what's going on and I think we need logs.", "It was fine again so I think we need logs."),
        ("For example in the second paragraph it should have been different.", "For example in the above sentence it should have been different."),
    ])
    func rejectsContentChange(draft: String, answer: String) {
        #expect(DisfluencyOnlyGuard.violation(answer: answer, raw: draft, draft: draft) != nil)
    }

    @Test("allows removing fillers, repeats and an abandoned restart", arguments: [
        ("So basically we need to like fix the login.", "We need to fix the login."),
        ("I was going to I wanted to ask about timestamps.", "I wanted to ask about timestamps."),
        ("Because that would be that would feel hostile.", "Because that would feel hostile."),
        ("It takes like two seconds.", "It takes 2 seconds."),
        ("Invite Sam and Jordan, actually not Jordan, just Sam.", "Invite Sam."),
    ])
    func allowsDisfluencyRemoval(draft: String, answer: String) {
        #expect(DisfluencyOnlyGuard.violation(answer: answer, raw: draft, draft: draft) == nil)
    }

    // MARK: CriticalTokenGuard negation

    @Test("counts -n't contractions as negations")
    func contractionNegation() {
        #expect(CriticalTokenGuard.negationCount(in: "I don't know and it isn't ready") == 2)
        #expect(CriticalTokenGuard.violation(answer: "I know what's going on.", draft: "I don't know what's going on.") == "dropped negation")
    }

    @Test("a negation abandoned in a restart may go, but not every negation")
    func negatedRestart() {
        let draft = "I think we should not we should never load the whole file."
        #expect(CriticalTokenGuard.violation(answer: "I think we should never load the whole file.", draft: draft) == nil)
        #expect(CriticalTokenGuard.violation(answer: "I think we should load the whole file.", draft: draft) == "dropped negation")
    }

    @Test("I-contractions are not treated as names")
    func pronounContractionNotAName() {
        #expect(CriticalTokenGuard.violation(answer: "Tomorrow I will pair on it.", draft: "Tomorrow I'll pair on it.") == nil)
    }
}

@Suite("Polished drop tolerance")
struct PolishedDropToleranceTests {
    @Test("inflection and one or two reconstructed words are fine at polished")
    func allowed() {
        #expect(DisfluencyOnlyGuard.violation(answer: "Last week we released the patch and customers reported fewer crashes.",
                                              raw: "", draft: "Last week we release the patch and the customers reports fewer crashes.",
                                              grammarRepair: true) == nil)
    }

    @Test("a dropped hedge, stance word, number or three content words is rejected at polished", arguments: [
        ("The design also I think needs another pass.", "The design also needs another pass."),
        ("Maybe we just need to refine the models.", "Refining the models."),
        ("It takes 45 seconds to load the app.", "It takes seconds to load the app."),
        ("We drove to the coast and saw whales near the harbor.", "We drove to the coast."),
    ])
    func rejected(draft: String, answer: String) {
        #expect(DisfluencyOnlyGuard.violation(answer: answer, raw: draft, draft: draft, grammarRepair: true) != nil)
    }
}

@Suite("Bare retraction echo")
struct BareRetractionEchoTests {
    @Test("drops a reason-less echo of the retraction the answer already resolved")
    func dropsEcho() {
        let draft = "Let's bring tomato, potato, no, forget about tomato. Just bring potato and ketchup."
        #expect(RetractionGuard.droppingBareRetraction("Let's bring potato and ketchup. Forget about tomato.", draft: draft)
            == "Let's bring potato and ketchup.")
    }

    @Test("keeps a retraction that carries a reason, and answers without an echo")
    func keepsReasoned() {
        let draft = "Pick up milk and eggs, actually forget the eggs, we already have them."
        let answer = "Pick up milk. Forget the eggs, we already have them."
        #expect(RetractionGuard.droppingBareRetraction(answer, draft: draft) == answer)
        #expect(RetractionGuard.droppingBareRetraction("Ship it today.", draft: "Ship it today.") == "Ship it today.")
    }
}
