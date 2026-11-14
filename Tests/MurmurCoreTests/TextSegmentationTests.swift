import Testing
@testable import MurmurCore

@Suite("TextSegmentation")
struct TextSegmentationTests {
    @Test("short text returns a single tail group")
    func shortTextSingleGroup() {
        let text = "Can you send me the report by Friday?"
        let groups = TextSegmentation.groups(text)
        #expect(groups.count == 1)
        #expect(groups[0].text == text)
        #expect(groups[0].isTail)
        #expect(groups[0].index == 0)
    }

    @Test("a single very long sentence is split by RunOnChunker so every piece can reach the model")
    func singleLongSentenceIsChunked() {
        // Changed 2026-09-26 (dictation robustness): an 80-word sentence used to stay one group
        // and was then skipped as "too long for model budget".
        let words = (0..<80).map { "word\($0)" }.joined(separator: " ")
        let text = words + "."
        let groups = TextSegmentation.groups(text)
        #expect(groups.count >= 2)
        #expect(TextSegmentation.join(groups.map(\.text)) == text)
        #expect(groups.allSatisfy { TextStats.wordCount($0.text) <= RunOnChunker.hardCapWords + 5 })
    }

    @Test("text at or under the segment threshold stays one group")
    func sentenceAtThresholdStaysOneGroup() {
        let text = (0..<TextSegmentation.segmentThresholdWords).map { "word\($0)" }.joined(separator: " ") + "."
        #expect(TextSegmentation.groups(text).count == 1)
    }

    @Test("long multi-sentence text splits into multiple groups near the target size")
    func longTextSplitsIntoGroups() {
        // 10 sentences of 8 words each = 80 words total, comfortably over maxGroupWords (40).
        let sentence = "This is a sentence with eight words."
        let text = Array(repeating: sentence, count: 10).joined(separator: " ")
        let groups = TextSegmentation.groups(text)
        #expect(groups.count > 1)
        // Every group should be within a reasonable band of the target (allowing the last group
        // to be shorter, since it's whatever sentences are left over).
        for group in groups.dropLast() {
            let wordCount = TextStats.wordCount(group.text)
            #expect(wordCount >= TextSegmentation.minGroupWords)
            #expect(wordCount <= TextSegmentation.maxGroupWords)
        }
        #expect(groups.last?.isTail == true)
        #expect(groups.dropLast().allSatisfy { !$0.isTail })
    }

    @Test("groups are indexed sequentially from zero")
    func groupsIndexedSequentially() {
        let sentence = "This is a sentence with eight words."
        let text = Array(repeating: sentence, count: 10).joined(separator: " ")
        let groups = TextSegmentation.groups(text)
        #expect(groups.map(\.index) == Array(0..<groups.count))
    }

    @Test("a correction cue's sentence stays with the sentence before it even if that overflows the target")
    func correctionWindowStaysTogether() {
        // Build a group that's already near the max, then follow it with a correction sentence
        // that must not be split into its own group.
        let filler = Array(repeating: "word", count: 38).joined(separator: " ")
        let text = filler + ". No, I meant something else entirely."
        let groups = TextSegmentation.groups(text)
        // The correction sentence ("No, I meant...") must appear in the same group as the
        // filler sentence before it, not split off on its own.
        let groupContainingCorrection = groups.first { $0.text.contains("No, I meant") }
        #expect(groupContainingCorrection != nil)
        #expect(groupContainingCorrection?.text.contains("word word") == true)
    }

    @Test("startsCorrectionWindow recognizes a leading correction cue", arguments: [
        "No, I mean the other one.",
        "Actually, scratch that.",
        "Wait, forget the eggs.",
        "Sorry, that's wrong.",
    ])
    func startsCorrectionWindowPositive(sentence: String) {
        #expect(TextSegmentation.startsCorrectionWindow(sentence))
    }

    @Test("startsCorrectionWindow ignores an ordinary sentence with no leading cue", arguments: [
        "This is a normal sentence.",
        "We need to ship this by Friday.",
        "I actually really enjoyed the talk.",
    ])
    func startsCorrectionWindowNegative(sentence: String) {
        #expect(!TextSegmentation.startsCorrectionWindow(sentence))
    }

    @Test("join re-assembles cleaned group texts with single spaces")
    func joinReassembles() {
        let joined = TextSegmentation.join(["First sentence.", "Second sentence.", "Third sentence."])
        #expect(joined == "First sentence. Second sentence. Third sentence.")
    }

    @Test("join skips empty groups")
    func joinSkipsEmpty() {
        let joined = TextSegmentation.join(["First sentence.", "", "  ", "Second sentence."])
        #expect(joined == "First sentence. Second sentence.")
    }

    @Test("join preserves line and paragraph breaks at group edges")
    func joinPreservesExplicitBreaks() {
        #expect(TextSegmentation.join(["First line.\n", "Second line."]) == "First line.\nSecond line.")
        #expect(TextSegmentation.join(["Intro.\n\n", "Billing starts Monday."]) == "Intro.\n\nBilling starts Monday.")
    }

    @Test("stitch preserves an explicit paragraph boundary at a group seam")
    func stitchPreservesParagraphBoundary() {
        let groups = [
            TextSegmentation.Group(text: "The trial ends on Friday.", index: 0, isTail: false),
            TextSegmentation.Group(text: "Billing starts Monday.", index: 1, isTail: true),
        ]
        #expect(TextSegmentation.stitch(["The trial ends on Friday.\n\n", "Billing starts Monday."], groups: groups)
            == "The trial ends on Friday.\n\nBilling starts Monday.")
    }

    @Test("contract paragraph flags require a completed sentence and a capitalized next piece")
    func stitchParagraphSeamChecks() {
        let groups = [
            TextSegmentation.Group(text: "The proposal is ready.", index: 0, isTail: false),
            TextSegmentation.Group(text: "Review begins tomorrow.", index: 1, isTail: true),
        ]
        let flags = [false, true]
        #expect(TextSegmentation.stitch(["The proposal is ready.\u{201D}", "Review begins tomorrow."], groups: groups, newParagraphs: flags)
            == "The proposal is ready.\u{201D}\n\nReview begins tomorrow.")
        #expect(TextSegmentation.stitch(["The proposal is ready", "Review begins tomorrow."], groups: groups, newParagraphs: flags)
            == "The proposal is ready Review begins tomorrow.")
        #expect(TextSegmentation.stitch(["The proposal is ready.", "review begins tomorrow."], groups: groups, newParagraphs: flags)
            == "The proposal is ready. review begins tomorrow.")
    }

    @Test("empty text produces no groups")
    func emptyTextNoGroups() {
        #expect(TextSegmentation.groups("").isEmpty)
    }

    @Test("groups round-trip to the original text when re-joined with a space")
    func groupsRoundTrip() {
        let sentence = "This is a sentence with eight words."
        let text = Array(repeating: sentence, count: 12).joined(separator: " ")
        let groups = TextSegmentation.groups(text)
        let rejoined = TextSegmentation.join(groups.map(\.text))
        // Word-for-word identical modulo whitespace normalization (each group already had
        // single-space-joined sentences).
        #expect(rejoined == text)
    }
}
