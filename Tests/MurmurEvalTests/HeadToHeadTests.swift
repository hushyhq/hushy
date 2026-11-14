import Foundation
import Testing

@testable import murmur_eval

@Suite("Head-to-head blinding")
struct HeadToHeadBlindingTests {
    private func pairs(_ count: Int) -> [HeadToHeadPair] {
        (1...count).map {
            HeadToHeadPair(id: "p-\($0)", hushyOutput: "hushy \($0)", otherOutput: "other \($0)", otherName: "Wispr Flow")
        }
    }

    @Test func sameSeedGivesSameAssignmentAndOrder() {
        let first = HeadToHeadBlinding.blind(pairs(40), seed: 7)
        let second = HeadToHeadBlinding.blind(pairs(40), seed: 7)
        #expect(first == second)
    }

    @Test func differentSeedsGiveDifferentAssignments() {
        let first = HeadToHeadBlinding.blind(pairs(40), seed: 7)
        let second = HeadToHeadBlinding.blind(pairs(40), seed: 8)
        #expect(first != second)
    }

    @Test func assignmentIsRoughlyBalancedAndEveryPairSurvives() {
        let blinded = HeadToHeadBlinding.blind(pairs(200), seed: 42)
        #expect(Set(blinded.map(\.id)).count == 200)
        let hushyFirst = blinded.filter(\.hushyIsA).count
        #expect(hushyFirst > 70 && hushyFirst < 130, "hushy-is-A count \(hushyFirst) is not a plausible coin flip")
        #expect(blinded.map(\.id) != pairs(200).map(\.id), "pair order should be shuffled, not the input order")
    }

    @Test func blindedTextsMatchTheAssignedSide() {
        for pair in HeadToHeadBlinding.blind(pairs(20), seed: 1) {
            let number = pair.id.dropFirst(2)
            if pair.hushyIsA {
                #expect(pair.a == "hushy \(number)" && pair.b == "other \(number)")
            } else {
                #expect(pair.a == "other \(number)" && pair.b == "hushy \(number)")
            }
        }
    }

    @Test func unblindingMapsChoicesBackToProductsInBothOrientations() {
        let hushyFirst = BlindedPair(id: "x", a: "h", b: "o", hushyIsA: true)
        #expect(hushyFirst.unblind(.a) == .hushy)
        #expect(hushyFirst.unblind(.b) == .other)
        #expect(hushyFirst.unblind(.tie) == .tie)
        let otherFirst = BlindedPair(id: "x", a: "o", b: "h", hushyIsA: false)
        #expect(otherFirst.unblind(.a) == .other)
        #expect(otherFirst.unblind(.b) == .hushy)
        #expect(otherFirst.unblind(.tie) == .tie)
    }

    @Test func reviewFormNeverNamesTheProductsOrLeaksTheKey() {
        let blinded = HeadToHeadBlinding.blind(pairs(5), seed: 3)
        let html = HeadToHeadReviewForm.render(blinded, seed: 3)
        #expect(!html.contains("Wispr"))
        #expect(!html.contains("hushyIsA"))
        #expect(html.contains("seed \(3)"))
        for pair in blinded {
            #expect(html.contains(HeadToHeadReviewForm.escape(pair.a)))
            #expect(html.contains(HeadToHeadReviewForm.escape(pair.b)))
            #expect(html.contains("data-id=\"\(pair.id)\""))
        }
        #expect(!html.contains("<script src"), "the form must be self-contained, no network")
        #expect(!html.contains("http://") && !html.contains("https://"))
    }

    @Test func reviewFormEscapesHTMLInOutputs() {
        let pair = HeadToHeadPair(id: "p", hushyOutput: "<b>bold</b> & \"quoted\"", otherOutput: "plain", otherName: "X")
        let html = HeadToHeadReviewForm.render(HeadToHeadBlinding.blind([pair]), seed: 1)
        #expect(html.contains("&lt;b&gt;bold&lt;/b&gt; &amp; &quot;quoted&quot;"))
        #expect(!html.contains("<b>bold</b>"))
    }
}

@Suite("Head-to-head votes")
struct HeadToHeadVotesTests {
    private let pairs = [
        HeadToHeadPair(id: "p-1", hushyOutput: "h1", otherOutput: "o1", otherName: "W"),
        HeadToHeadPair(id: "p-2", hushyOutput: "h2", otherOutput: "o2", otherName: "W"),
    ]

    @Test func votesUnblindThroughTheSameSeed() throws {
        let blinded = HeadToHeadBlinding.blind(pairs, seed: 11)
        // Vote "A" on every pair: the preference must be Hushy exactly where Hushy was A.
        let file = HeadToHeadVoteFile(reviewer: "RK", seed: 11, votes: blinded.map { .init(id: $0.id, choice: .a) })
        let unblinded = try HeadToHeadVotes.unblind(file, fileName: "votes.json", blinded: blinded, seed: 11)
        for pair in blinded {
            #expect(unblinded.preferences[pair.id] == (pair.hushyIsA ? .hushy : .other))
        }
    }

    @Test func seedMismatchIsAnError() {
        let blinded = HeadToHeadBlinding.blind(pairs, seed: 11)
        let file = HeadToHeadVoteFile(reviewer: "RK", seed: 12, votes: [.init(id: "p-1", choice: .a)])
        #expect(throws: HeadToHeadVotes.LoadError.seedMismatch(file: "v.json", fileSeed: 12, runSeed: 11)) {
            try HeadToHeadVotes.unblind(file, fileName: "v.json", blinded: blinded, seed: 11)
        }
    }

    @Test func unknownPairIsAnError() {
        let blinded = HeadToHeadBlinding.blind(pairs, seed: 11)
        let file = HeadToHeadVoteFile(reviewer: "RK", seed: 11, votes: [.init(id: "p-9", choice: .tie)])
        #expect(throws: HeadToHeadVotes.LoadError.unknownPair(file: "v.json", id: "p-9")) {
            try HeadToHeadVotes.unblind(file, fileName: "v.json", blinded: blinded, seed: 11)
        }
    }

    @Test func voteFileRoundTripsThroughTheFormsJSONShape() throws {
        let json = #"{"reviewer":"AB","seed":42,"votes":[{"id":"p-1","choice":"A"},{"id":"p-2","choice":"tie"}]}"#
        let file = try JSONDecoder().decode(HeadToHeadVoteFile.self, from: Data(json.utf8))
        #expect(file.votes == [.init(id: "p-1", choice: .a), .init(id: "p-2", choice: .tie)])
    }
}

@Suite("Head-to-head scoring")
struct HeadToHeadScoringTests {
    @Test func editDistanceIsWordLevelAndCaseInsensitive() {
        let pair = HeadToHeadPair(id: "p", hushyOutput: "Send it to Priya by Friday.", otherOutput: "send it to priya on friday", otherName: "W")
        let score = HeadToHeadScoring.score(pair)
        #expect(score.editDistance == 1)
        #expect(abs(score.editRate - 1.0 / 6.0) < 0.001)
    }

    @Test func flagsNumbersNamesAndNegationsPresentOnOneSideOnly() {
        let lost = HeadToHeadScoring.lostContent(
            hushy: "Tell Priya the total is $1,250, not 1,500.",
            other: "Tell the total is 1,250.")
        #expect(lost.numbersOnlyInHushy == ["1", "500"])
        #expect(lost.numbersOnlyInOther.isEmpty)
        #expect(lost.namesOnlyInHushy == ["Priya"])
        #expect(lost.negationsOnlyInHushy == ["not"])
        #expect(lost.negationMismatch)
    }

    @Test func spelledAndDigitNumbersCompareEqual() {
        let lost = HeadToHeadScoring.lostContent(hushy: "Call Sam about the 3 tickets.", other: "Call Sam about the three tickets.")
        #expect(!lost.hasAny)
    }

    @Test func sentenceInitialCapitalsAreNotNames() {
        #expect(HeadToHeadScoring.names(in: "Tomorrow we ship. Later I call Dana.") == ["Dana"])
        #expect(HeadToHeadScoring.names(in: "I think Alex and I agree.") == ["Alex"])
    }

    @Test func contractedNegationsCount() {
        let lost = HeadToHeadScoring.lostContent(hushy: "Don't merge yet.", other: "Do merge yet.")
        #expect(lost.negationsOnlyInHushy == ["don't"])
    }

    @Test func tallyPercentagesAndTies() {
        let tally = HeadToHeadScoring.Tally.of([.hushy, .hushy, .other, .tie])
        #expect(tally.total == 4)
        #expect(abs(tally.hushyPreferredOfDecisive - 2.0 / 3.0) < 0.001)
        #expect(abs(tally.hushyPreferredWithTiesAsHalf - 2.5 / 4.0) < 0.001)
        #expect(tally.tieRate == 0.25)
        #expect(HeadToHeadScoring.Tally.of([]).hushyPreferredOfDecisive == 0)
    }

    @Test func majorityNeedsAStrictWinner() {
        #expect(HeadToHeadScoring.majority([.hushy, .hushy, .other]) == .hushy)
        #expect(HeadToHeadScoring.majority([.other, .other, .tie]) == .other)
        #expect(HeadToHeadScoring.majority([.hushy, .other, .tie]) == .tie)
        #expect(HeadToHeadScoring.majority([.hushy, .other]) == .tie)
        #expect(HeadToHeadScoring.majority([]) == nil)
    }
}

@Suite("Head-to-head template")
struct HeadToHeadTemplateTests {
    @Test func planHasTheGateMix() {
        let slots = HeadToHeadTemplate.plan(count: 100)
        #expect(slots.count == 100)
        #expect(slots.filter(\.isLong).count == 20)
        let byStyle = Dictionary(grouping: slots, by: \.style).mapValues(\.count)
        #expect(byStyle[.work] == 30 && byStyle[.email] == 25 && byStyle[.chat] == 25 && byStyle[.notes] == 20)
        #expect(Set(slots.map(\.id)).count == 100)
    }

    @Test func renderedTemplateParsesBackWithEmptySlots() {
        let text = HeadToHeadTemplate.render(slots: HeadToHeadTemplate.plan(count: 3), product: "Hushy")
        let parsed = HeadToHeadTemplate.parse(text)
        #expect(parsed.outputs.isEmpty)
        #expect(parsed.emptySlots == ["p-001", "p-002", "p-003"])
    }

    @Test func filledSlotsParseAndCuesAreIgnored() {
        let text = """
            # Head-to-head dictation — Hushy
            ## p-001 · work · short (10–40 s)
            <!-- a cue -->
            First paragraph, line one.
            Second line.

            ## p-002 · chat · LONG (over 60 s)
            <!-- another
                 multi-line cue -->

            ## p-003
            Third.
            """
        let parsed = HeadToHeadTemplate.parse(text)
        #expect(parsed.outputs["p-001"] == "First paragraph, line one.\nSecond line.")
        #expect(parsed.outputs["p-003"] == "Third.")
        #expect(parsed.emptySlots == ["p-002"])
    }

    @Test func buildJoinsOnIdAndReportsOneSidedSlots() {
        let hushy = HeadToHeadTemplate.Parsed(outputs: ["p-001": "h1", "p-002": "h2"], emptySlots: ["p-003"])
        let other = HeadToHeadTemplate.Parsed(outputs: ["p-001": "o1", "p-003": "o3"], emptySlots: ["p-002"])
        let result = HeadToHeadTemplate.build(hushy: hushy, other: other, otherName: "Wispr Flow")
        #expect(result.pairs == [HeadToHeadPair(id: "p-001", hushyOutput: "h1", otherOutput: "o1", otherName: "Wispr Flow")])
        #expect(result.missingOther == ["p-002"])
        #expect(result.missingHushy == ["p-003"])
    }

    @Test func pairsFileValidationRejectsDuplicatesAndBlanks() {
        let duplicate = [
            HeadToHeadPair(id: "p", hushyOutput: "a", otherOutput: "b", otherName: "W"),
            HeadToHeadPair(id: "p", hushyOutput: "a", otherOutput: "b", otherName: "W"),
        ]
        #expect(throws: HeadToHeadPairs.LoadError.duplicateIDs(["p"])) { try HeadToHeadPairs.validate(duplicate) }
        let blank = [HeadToHeadPair(id: "q", hushyOutput: "  ", otherOutput: "b", otherName: "W")]
        #expect(throws: HeadToHeadPairs.LoadError.blankOutput("q")) { try HeadToHeadPairs.validate(blank) }
        #expect(throws: HeadToHeadPairs.LoadError.empty) { try HeadToHeadPairs.validate([]) }
    }
}

@Suite("Head-to-head judge")
struct HeadToHeadJudgeTests {
    private func blinded(_ count: Int) -> [BlindedPair] {
        (1...count).map { BlindedPair(id: "p-\($0)", a: "a \($0)", b: "b \($0)", hushyIsA: $0.isMultiple(of: 2)) }
    }

    @Test func parsesPositionNumberedVerdictsOntoTheBatch() throws {
        let batch = blinded(2)
        let text = #"{"verdicts":[{"pair":1,"winner":"B","reasoning":"cleaner"},{"pair":2,"winner":"tie"}]}"#
        let verdicts = try HeadToHeadJudge.parse(text, batch: batch)
        #expect(verdicts == [
            .init(id: "p-1", choice: .b, reasoning: "cleaner"),
            .init(id: "p-2", choice: .tie, reasoning: ""),
        ])
    }

    @Test func rejectsWrongCountAndUnknownWinner() {
        let batch = blinded(2)
        #expect(throws: HeadToHeadJudge.ParseError.wrongCount(expected: 2, got: 1)) {
            try HeadToHeadJudge.parse(#"{"verdicts":[{"pair":1,"winner":"A"}]}"#, batch: batch)
        }
        #expect(throws: HeadToHeadJudge.ParseError.self) {
            try HeadToHeadJudge.parse(#"{"verdicts":[{"pair":1,"winner":"C"},{"pair":2,"winner":"A"}]}"#, batch: batch)
        }
        #expect(throws: HeadToHeadJudge.ParseError.noJSON) { try HeadToHeadJudge.parse("no json here", batch: batch) }
    }

    @Test func promptHidesProductsAndLabelsPairsByPosition() {
        let prompt = HeadToHeadJudge.prompt(for: blinded(2))
        #expect(prompt.contains("Pair 1") && prompt.contains("Pair 2"))
        #expect(prompt.contains("Output A:\na 1") && prompt.contains("Output B:\nb 2"))
        #expect(!prompt.lowercased().contains("hushy") && !prompt.lowercased().contains("wispr"))
    }

    @Test func batchesTwoPairsPerCallAndRespectsTheCallBudget() async throws {
        let dir = try CLIJudgeFakeScripts.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = try CLIJudgeFakeScripts.makeFakeCodex(
            in: dir, messageText: #"{"verdicts":[{"pair":1,"winner":"A"},{"pair":2,"winner":"B"}]}"#)
        let backend = CodexCLIJudge(model: "gpt-6-luna", executableURL: fake, cache: nil, timeout: 20)
        let judge = HeadToHeadJudge(backend: backend, maxCalls: 2, cacheDirectory: dir.appendingPathComponent("cache"))

        let outcome = await judge.judge(blinded(6))

        #expect(outcome.callsMade == 2)
        #expect(outcome.callsFailed == 0)
        #expect(outcome.verdicts.count == 4)
        #expect(outcome.unjudgedForBudget == ["p-5", "p-6"])
        #expect(outcome.skippedReason == nil)
        // Position 1 -> A, position 2 -> B, per batch.
        #expect(outcome.verdicts.map(\.choice) == [.a, .b, .a, .b])
        let argv = CLIJudgeFakeScripts.readLines(dir.appendingPathComponent("argv.log").path)
        #expect(argv.filter { $0 == "exec" }.count == 2, "exactly one codex exec per call")
        #expect(argv.contains("read-only"))
        #expect(!argv.contains { $0.contains("Pair 1") }, "the prompt must go via stdin, never argv")
        let stdin = CLIJudgeFakeScripts.readFile(dir.appendingPathComponent("stdin.log").path)
        #expect(stdin.contains("Output A"))
    }

    @Test func budgetIsClampedToSixtyCalls() {
        let backend = CodexCLIJudge(model: "m", executableURL: URL(fileURLWithPath: "/bin/true"), cache: nil)
        #expect(HeadToHeadJudge(backend: backend, maxCalls: 500).pairBudget == 120)
        #expect(HeadToHeadJudge(backend: backend, maxCalls: 10).pairBudget == 20)
    }

    @Test func oddBatchGetsASingleVerdictAndAnUnparseableAnswerIsRetriedThenCounted() async throws {
        let dir = try CLIJudgeFakeScripts.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = try CLIJudgeFakeScripts.makeFakeCodex(in: dir, messageText: "sorry, I can't decide")
        let backend = CodexCLIJudge(model: "gpt-6-luna", executableURL: fake, cache: nil, timeout: 20)
        let judge = HeadToHeadJudge(backend: backend, maxCalls: 5, cacheDirectory: nil)

        let outcome = await judge.judge(blinded(1))

        #expect(outcome.callsMade == 1)
        #expect(outcome.callsFailed == 1)
        #expect(outcome.verdicts.isEmpty)
        let argv = CLIJudgeFakeScripts.readLines(dir.appendingPathComponent("argv.log").path)
        #expect(argv.filter { $0 == "exec" }.count == 2, "one retry after bad JSON, then give up")
    }
}
