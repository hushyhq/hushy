import Foundation
import Testing
@testable import MurmurCore

/// Long dictations are cut into groups, cleaned group by group, then stitched back together
/// (`RunOnChunker`, `TextSegmentation.stitch`). Two seam bugs showed up on every backend in the
/// long-golden eval (2026-09-28): doubled punctuation where cleaned groups meet (",." / ",,"),
/// and a spoken number cut in half ("two hundred | and twenty five" → "200, and 25").
@Suite("Group seams: number phrases and seam punctuation")
struct GroupSeamTests {
    // MARK: - Cuts never split a number, date or time phrase

    /// Spoken number/date/time phrases a cut must never land inside.
    static let phrases = [
        "two hundred and twenty five",
        "one thousand two hundred",
        "twenty-five hundred",
        "three point five",
        "March twenty first",
        "the twenty first of March",
        "four fifteen",
        "nine thirty pm",
        "forty five percent",
        "four oh five",
    ]

    /// Places `phrase` at every offset around the first and second cut of a run-on with no
    /// boundary words (so the chunker falls back to its hard cap), and around a weak "and".
    @Test("a run-on is never cut inside a number, date or time phrase", arguments: phrases)
    func neverSplitsNumberPhrase(phrase: String) {
        for offset in 4...(2 * RunOnChunker.hardCapWords + 2) {
            let before = (0..<offset).map { "filler\($0)" }
            let after = (0..<40).map { "tail\($0)" }
            let text = (before + [phrase] + after).joined(separator: " ")
            let pieces = RunOnChunker.split(text)
            #expect(pieces.joined(separator: " ") == text)
            #expect(pieces.contains { $0.contains(phrase) },
                    "cut inside \"\(phrase)\" at offset \(offset): \(pieces.map { $0.suffix(40) })")
        }
    }

    @Test("the long-golden fitness log keeps 225 in one piece")
    func fitnessLogNumberStaysWhole() {
        let sentence = "Felt pretty strong on the deadlifts today, hit a new personal best of, like, two hundred and twenty five pounds for five reps, which is up from two ten last month."
        #expect(RunOnChunker.split(sentence).contains { $0.contains("two hundred and twenty five pounds") })
    }

    @Test("a number phrase does not stop the chunker cutting at a real boundary elsewhere")
    func numberPhraseStillAllowsOtherCuts() {
        let text = "we spent two hundred and twenty five dollars on the venue and the catering came in way over what anyone expected so we need to talk about the budget before the next event because it keeps growing"
        let pieces = RunOnChunker.split(text)
        #expect(pieces.count >= 2)
        #expect(pieces.contains { $0.contains("two hundred and twenty five dollars") })
    }

    // MARK: - Seam punctuation

    /// Two groups where the second continues the first's spoken sentence.
    func midSentence(_ rawPrevious: String, _ rawNext: String) -> [TextSegmentation.Group] {
        [
            TextSegmentation.Group(text: rawPrevious, index: 0, isTail: false),
            TextSegmentation.Group(text: rawNext, index: 1, isTail: true, continuesSentence: true),
        ]
    }

    /// Two groups that are separate sentences in the raw text.
    func sentences(_ rawPrevious: String, _ rawNext: String) -> [TextSegmentation.Group] {
        [
            TextSegmentation.Group(text: rawPrevious, index: 0, isTail: false),
            TextSegmentation.Group(text: rawNext, index: 1, isTail: true),
        ]
    }

    /// Letters and digits of every word, in order: the seam fix may only change punctuation
    /// and the case of the next group's first letter.
    func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { LegitDoubles.key(String($0)) }.filter { !$0.isEmpty }
    }

    func expectWordsUnchanged(_ stitched: String, _ cleaned: [String]) {
        #expect(words(stitched) == words(cleaned.joined(separator: " ")))
    }

    struct SeamCase: Sendable, CustomTestStringConvertible {
        let name: String
        let raw: [String]
        let cleaned: [String]
        let continues: Bool
        let expected: String
        var testDescription: String { name }
    }

    static let seamCases: [SeamCase] = [
        SeamCase(name: ",. after a raw comma, before a restart word",
                 raw: ["workout log for today did forty five minutes of cardio mostly on the bike,", "then moved to weights"],
                 cleaned: ["Workout log for today, did 45 minutes of cardio mostly on the bike,.", "Then moved to weights."],
                 continues: true,
                 expected: "Workout log for today, did 45 minutes of cardio mostly on the bike, then moved to weights."),
        SeamCase(name: ",, after a raw comma, before a continuation word",
                 raw: ["the tests fail maybe one in five runs,", "and we haven't found why"],
                 cleaned: ["The tests fail maybe one in five runs,.", "And we haven't found why."],
                 continues: true,
                 expected: "The tests fail maybe one in five runs, and we haven't found why."),
        SeamCase(name: ",? after a raw comma the group cleanup read as a question",
                 raw: ["should we ship it on friday,", "or wait until monday"],
                 cleaned: ["Should we ship it on Friday,?", "Or wait until Monday?"],
                 continues: true,
                 expected: "Should we ship it on Friday, or wait until Monday?"),
        SeamCase(name: "?, between two sentences",
                 raw: ["is the build ready?", "we ship at noon."],
                 cleaned: ["Is the build ready?,", "We ship at noon."],
                 continues: false,
                 expected: "Is the build ready? We ship at noon."),
        SeamCase(name: "., between two sentences",
                 raw: ["it works.", "ship it."],
                 cleaned: ["It works.,", "Ship it."],
                 continues: false,
                 expected: "It works. Ship it."),
        SeamCase(name: "a group opening with stray punctuation",
                 raw: ["we left the office early,", "and then we went home"],
                 cleaned: ["We left the office early,", ", and then we went home."],
                 continues: true,
                 expected: "We left the office early, and then we went home."),
        SeamCase(name: "a closing quote at the seam",
                 raw: ["she said \"ship it,\"", "and then she left"],
                 cleaned: ["She said \"ship it,\".", "And then she left."],
                 continues: true,
                 expected: "She said \"ship it,\" and then she left."),
        SeamCase(name: "a closing parenthesis after a raw comma",
                 raw: ["we'll use the old build (the one from tuesday),", "then retest everything"],
                 cleaned: ["We'll use the old build (the one from Tuesday),.", "Then retest everything."],
                 continues: true,
                 expected: "We'll use the old build (the one from Tuesday), then retest everything."),
        SeamCase(name: "a closing parenthesis before a continuation word",
                 raw: ["we'll use the old build (the one from tuesday)", "and then retest everything"],
                 cleaned: ["We'll use the old build (the one from Tuesday).", "And then retest everything."],
                 continues: true,
                 expected: "We'll use the old build (the one from Tuesday), and then retest everything."),
        SeamCase(name: "a hard-cap cut with no boundary word joins without a sentence break",
                 raw: ["my left knee was bothering me a bit might need to dial back the weight", "next session and focus more on form"],
                 cleaned: ["My left knee was bothering me a bit, might need to dial back the weight.", "Next session and focus more on form."],
                 continues: true,
                 expected: "My left knee was bothering me a bit, might need to dial back the weight next session and focus more on form."),
        SeamCase(name: "a discourse restart stays a sentence break",
                 raw: ["it just becomes a wall of text", "so maybe we should only show pinned ones"],
                 cleaned: ["It just becomes a wall of text.", "So maybe we should only show pinned ones."],
                 continues: true,
                 expected: "It just becomes a wall of text. So maybe we should only show pinned ones."),
        SeamCase(name: "a capitalised name after a raw comma keeps its capital",
                 raw: ["we talked to the whole team yesterday,", "Sarah said it's fine"],
                 cleaned: ["We talked to the whole team yesterday,.", "Sarah said it's fine."],
                 continues: true,
                 expected: "We talked to the whole team yesterday, Sarah said it's fine."),
        SeamCase(name: "a formatted list before a continuing group is left alone",
                 raw: ["shopping list milk eggs", "and then we went home"],
                 cleaned: ["Shopping list:\n- Milk\n- Eggs", "And then we went home."],
                 continues: true,
                 expected: "Shopping list:\n- Milk\n- Eggs And then we went home."),
        SeamCase(name: "a list item ending in doubled punctuation",
                 raw: ["shopping list milk eggs,", "we went home."],
                 cleaned: ["Shopping list:\n- Milk\n- Eggs,.", "We went home."],
                 continues: false,
                 expected: "Shopping list:\n- Milk\n- Eggs. We went home."),
    ]

    @Test("seam punctuation is normalised deterministically without touching the words", arguments: seamCases)
    func seamPunctuation(_ seam: SeamCase) {
        let groups = seam.continues ? midSentence(seam.raw[0], seam.raw[1]) : sentences(seam.raw[0], seam.raw[1])
        let stitched = TextSegmentation.stitch(seam.cleaned, groups: groups)
        #expect(stitched == seam.expected)
        expectWordsUnchanged(stitched, seam.cleaned)
    }

    // MARK: - End to end (rules only, segmented path)

    static let doubledPunctuation = "[,;:.!?][,;:!?]|[,;:!?]\\."

    @Test("the long-golden fitness log comes out with no seam artefacts")
    func fitnessLogEndToEnd() async {
        let raw = "Workout log for today, did forty five minutes of cardio, um, mostly on the bike, then moved to weights and did three sets of squats, three sets of deadlifts, and, uh, two sets of overhead press. Felt pretty strong on the deadlifts today, hit a new personal best of, like, two hundred and twenty five pounds for five reps, which is up from two ten last month. The squats felt a little off though, my left knee was bothering me a bit on the way down, might need to dial back the weight next session and focus more on form. Overall a solid workout, planning to do a rest day tomorrow and then hit legs again on Thursday"
        let output = await SmartCleaner(model: NullLanguageModel()).clean(raw, options: CleanupOptions(), strategy: .hybrid)
        #expect(output.groupSources.count > 1)
        #expect(output.text.contains("225 pounds"))
        #expect(output.text.contains("on the bike, then moved"))
        #expect(output.text.contains("the weight next session"))
        #expect(output.text.range(of: Self.doubledPunctuation, options: .regularExpression) == nil, "\(output.text)")
    }

    @Test("a comma-heavy run-on joins with single commas at every seam")
    func commaRunOnEndToEnd() async {
        let raw = "So the analytics setup is a mess right now, we have events going to Amplitude, Mixpanel and PostHog, and I think we should consolidate onto one of them, probably PostHog since it's self-hostable, and then we can finally trust the numbers we show the board, but first we need to audit which events actually matter, because half of them were added for experiments that ended months ago, and nobody cleaned them up afterwards"
        let output = await SmartCleaner(model: NullLanguageModel()).clean(raw, options: CleanupOptions(), strategy: .hybrid)
        #expect(output.groupSources.count > 1)
        #expect(output.text.range(of: Self.doubledPunctuation, options: .regularExpression) == nil, "\(output.text)")
        #expect(output.text.contains("PostHog, and I think"))
    }
}
