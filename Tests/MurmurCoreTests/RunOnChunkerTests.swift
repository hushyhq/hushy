import Testing
@testable import MurmurCore

@Suite("RunOnChunker and run-on segmentation")
struct RunOnChunkerTests {
    let sidebar = "so right now the sidebar basically shows every project right and i think that's actually kind of too much because like when you have twenty projects it just becomes a wall of text so maybe we should basically only show the pinned ones by default and then like have a show all button at the bottom"

    @Test("a sentence at or under the hard cap is never split")
    func shortSentenceUnsplit() {
        let text = (0..<RunOnChunker.hardCapWords).map { "word\($0)" }.joined(separator: " ")
        #expect(RunOnChunker.split(text) == [text])
    }

    @Test("a long run-on splits into pieces within bounds that round-trip exactly")
    func splitsWithinBounds() {
        let pieces = RunOnChunker.split(sidebar)
        #expect(pieces.count >= 2)
        #expect(pieces.joined(separator: " ") == sidebar)
        for piece in pieces.dropLast() {
            let words = TextStats.wordCount(piece)
            #expect(words >= RunOnChunker.minPieceWords)
            #expect(words <= RunOnChunker.hardCapWords)
        }
    }

    @Test("prefers a discourse restart as the cut point")
    func cutsAtDiscourseRestart() {
        let pieces = RunOnChunker.split(sidebar)
        let boundaryStarts: Set<String> = ["so", "and", "because", "but", "maybe", "then", "i", "what", "okay"]
        #expect(pieces.dropFirst().allSatisfy { boundaryStarts.contains(String($0.split(separator: " ")[0])) })
    }

    @Test("cuts before a direct question start")
    func cutsBeforeQuestion() {
        let text = "the thing where it resets your scroll position every time you switch tabs is just bad and it happens in the history view and the notes view too what do you think we can do about that should we remember the position"
        let pieces = RunOnChunker.split(text)
        #expect(pieces.count >= 2)
        // The question phrase is never cut apart.
        #expect(pieces.contains { $0.contains("what do you think") })
        let short = "we tested the build on the old laptop and the new one this morning with the team what do you think we should do next about the flaky tests"
        #expect(RunOnChunker.split(short).contains { $0.hasPrefix("what do you think") })
    }

    @Test("never separates a correction from what it corrects")
    func keepsCorrectionTogether() {
        let text = "let's move the launch to the twelfth and tell the whole team about it today no wait the nineteenth because the design review got pushed and we need at least a week after that to fix whatever they find so yeah"
        for piece in RunOnChunker.split(text) {
            // The cue and the item it replaces stay in one piece.
            if piece.contains("no wait") { #expect(piece.contains("twelfth") && piece.contains("nineteenth")) }
        }
    }

    @Test("with no boundary word at all, falls back to the hard cap and never strands a stub")
    func hardCapFallback() {
        let text = (0..<83).map { "word\($0)" }.joined(separator: " ")
        let pieces = RunOnChunker.split(text)
        #expect(pieces.joined(separator: " ") == text)
        #expect(pieces.allSatisfy { TextStats.wordCount($0) <= RunOnChunker.hardCapWords + 6 })
        #expect(TextStats.wordCount(pieces.last!) >= 3)
    }

    @Test("earlier pieces are stable as more of the run-on is confirmed")
    func prefixStable() {
        let words = (sidebar + " " + sidebar).split(separator: " ").map(String.init)
        var previous: [String] = []
        for count in stride(from: 41, through: words.count, by: 1) {
            let pieces = RunOnChunker.split(words.prefix(count).joined(separator: " "))
            // Every piece that was closed (not last) before must still be there unchanged, unless
            // the stub-merge exception applied to the piece right before the tail.
            for (index, piece) in previous.dropLast(2).enumerated() {
                #expect(pieces[index] == piece)
            }
            previous = pieces
        }
    }

    @Test("TextSegmentation gives each run-on piece its own group, marked as continuing a sentence")
    func segmentationUsesPieces() {
        let groups = TextSegmentation.groups(sidebar)
        #expect(groups.count >= 2)
        #expect(groups[0].continuesSentence == false)
        #expect(groups.dropFirst().allSatisfy { $0.continuesSentence })
        #expect(TextSegmentation.join(groups.map(\.text)) == sidebar)
    }

    @Test("punctuated text keeps sentence grouping and never marks a group as continuing")
    func punctuatedUnaffected() {
        let text = Array(repeating: "This is a sentence with eight words.", count: 10).joined(separator: " ")
        #expect(TextSegmentation.groups(text).allSatisfy { !$0.continuesSentence })
    }

    @Test("stitch joins a continuation seam with a comma and keeps a restart seam a sentence break")
    func stitchSeams() {
        // Changed 2026-09-28 (seam punctuation): `stitch` now reads each group's raw text to
        // tell a boundary-word cut from a hard-cap cut, so the fixture carries real raw text.
        let groups = [
            TextSegmentation.Group(text: "the sidebar shows every project and i think that's too much", index: 0, isTail: false),
            TextSegmentation.Group(text: "because when you have twenty projects it's a wall of text", index: 1, isTail: false,
                                   continuesSentence: true),
            TextSegmentation.Group(text: "so maybe we should only show pinned ones", index: 2, isTail: true, continuesSentence: true),
        ]
        let stitched = TextSegmentation.stitch(
            ["The sidebar shows every project and I think that's too much.", "Because when you have 20 projects it's a wall of text.", "So maybe we should only show pinned ones."],
            groups: groups)
        #expect(stitched == "The sidebar shows every project and I think that's too much, because when you have 20 projects it's a wall of text. So maybe we should only show pinned ones.")
    }

    @Test("stitch never touches a seam between two real sentences or a question")
    func stitchLeavesRealSentences() {
        let groups = [
            TextSegmentation.Group(text: "a", index: 0, isTail: false),
            TextSegmentation.Group(text: "b", index: 1, isTail: true, continuesSentence: true),
        ]
        #expect(TextSegmentation.stitch(["Is it ready?", "And when will it ship?"], groups: groups) == "Is it ready? And when will it ship?")
        let sentenceGroups = [
            TextSegmentation.Group(text: "a", index: 0, isTail: false),
            TextSegmentation.Group(text: "b", index: 1, isTail: true),
        ]
        #expect(TextSegmentation.stitch(["It works.", "Because we fixed it."], groups: sentenceGroups) == "It works. Because we fixed it.")
    }
}
