import Foundation
import Testing
@testable import MurmurCore

/// Invented text only. The rule is a layout step: it may turn a space between two sentences into a blank line and change
/// nothing else, so every test that lays text out also checks that the words and their order are untouched.
@Suite("Paragraph layout for long dictations", .timeLimit(.minutes(1)))
struct ParagraphLayoutTests {
    /// About 125 words with three topic turns, two of them opened by a discourse cue.
    static let cued = """
        I finished the first pass on the vendor contract this morning. The payment terms look fine, and the liability section \
        matches what legal asked for. The only open item is the renewal clause, which still says ninety days instead of sixty. \
        I will send that back to them today. Also, the new hire starts on Monday and I have not booked her laptop yet. \
        Facilities said the desk is ready, but IT needs two days to set up the accounts. Can you ping Marcus and ask him to \
        prioritize it? The third thing is the offsite. We have the venue, but the caterer wants a final headcount by Friday. \
        Please send me your numbers tonight so I can confirm. I will also need the dietary list from everyone on your team \
        before the weekend.
        """

    /// About 130 words about one subject, with no discourse cue anywhere.
    static let wall = """
        The kitchen renovation is going slowly. The contractor found old wiring behind the north wall last week. He says it \
        has to be replaced before we close the walls. That adds about two weeks to the schedule and roughly three thousand \
        dollars. I called the electrician we used for the garage. He can come on Tuesday and give us a quote. The cabinets are \
        sitting in the garage under tarps. We picked the oak ones with the brass handles. The delivery company wants them out \
        of the warehouse by the end of the month. We have to decide where they go if the kitchen is not ready. My brother \
        offered his basement. It is dry and there is plenty of room, but the stairs are narrow. We may have to take the doors \
        off first.
        """

    private func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }

    private func paragraphs(_ text: String) -> [String] { text.components(separatedBy: "\n\n") }

    // MARK: - What it does

    @Test("a long dictation breaks at the sentences that open a new topic")
    func breaksAtCues() {
        let laid = ParagraphLayout.apply(Self.cued)
        let parts = paragraphs(laid)
        #expect(parts.count >= 2 && parts.count <= 3)
        #expect(parts.contains { $0.hasPrefix("Also, the new hire") })
        #expect(parts.contains { $0.hasPrefix("The third thing is the offsite") })
    }

    @Test("a long block with no cue still gets a break, near the middle and not before a sentence that leans on the last")
    func splitsAWall() {
        let laid = ParagraphLayout.apply(Self.wall)
        let parts = paragraphs(laid)
        #expect(parts.count >= 2)
        for part in parts.dropFirst() {
            #expect(Regex.firstMatch(part, "^(?:it|this|that|they|and|but|so|because|which)\\b") == nil)
        }
    }

    @Test("only whitespace between sentences changes: the same words in the same order")
    func keepsEveryWord() {
        for text in [Self.cued, Self.wall] {
            let laid = ParagraphLayout.apply(text)
            #expect(words(laid) == words(text))
            #expect(laid.replacingOccurrences(of: "\n\n", with: " ") == text)
        }
    }

    @Test("a break is only ever between two sentences")
    func neverInsideASentence() {
        for text in [Self.cued, Self.wall] {
            let laid = ParagraphLayout.apply(text)
            for part in paragraphs(laid) {
                #expect(part.last.map { ".!?".contains($0) } == true)
                #expect(part.first.map { $0.isUppercase || $0.isNumber } == true)
            }
        }
    }

    @Test("no paragraph is a stub: each has two sentences and at least 22 words")
    func noStubs() {
        for text in [Self.cued, Self.wall] {
            for part in paragraphs(ParagraphLayout.apply(text)) {
                #expect(words(part).count >= ParagraphLayout.minimumParagraphWords)
                #expect(ParagraphLayout.sentences(in: part).count >= ParagraphLayout.minimumParagraphSentences)
            }
        }
    }

    @Test("a title or a time abbreviation is not the end of a sentence")
    func abbreviationsAreNotBoundaries() {
        let text = Self.cued.replacingOccurrences(of: "ask him to prioritize it", with: "ask Dr. Patel to move it to 5 p.m. Thursday")
        let laid = ParagraphLayout.apply(text)
        #expect(!laid.contains("Dr.\n\n") && !laid.contains("p.m.\n\n"))
        #expect(laid.replacingOccurrences(of: "\n\n", with: " ") == text)
    }

    @Test("breaks are not piled up: at most one per 45 words")
    func fewBreaks() {
        let long = [Self.cued, Self.wall, Self.cued, Self.wall].joined(separator: " ")
        let laid = ParagraphLayout.apply(long)
        let breaks = paragraphs(laid).count - 1
        #expect(breaks >= 1)
        #expect(breaks <= words(long).count / ParagraphLayout.wordsPerBreak)
    }

    @Test("laying out twice gives the same text")
    func idempotent() {
        for text in [Self.cued, Self.wall] {
            let once = ParagraphLayout.apply(text)
            #expect(ParagraphLayout.apply(once) == once)
        }
    }

    // MARK: - What it leaves alone

    @Test("a dictation under 100 words is never touched")
    func shortStaysShort() {
        let short = "Also, the new hire starts on Monday. The third thing is the offsite. Please send me your numbers tonight."
        #expect(ParagraphLayout.apply(short) == short)
        let ninetyNine = Array(repeating: "Alpha beta gamma delta.", count: 24).joined(separator: " ") + " One two three."
        #expect(words(ninetyNine).count == 99 && ParagraphLayout.apply(ninetyNine) == ninetyNine)
    }

    @Test("text that already has any line break is left exactly as it is: a list, a spoken new paragraph, the model's own")
    func existingBreaksWin() {
        let withParagraph = Self.cued.replacingOccurrences(of: "Also, the new hire", with: "\n\nAlso, the new hire")
        let withList = Self.cued + "\n- laptop\n- badge\n- desk"
        let withLine = Self.cued.replacingOccurrences(of: "Please send", with: "\nPlease send")
        for text in [withParagraph, withList, withLine] {
            #expect(ParagraphLayout.apply(text) == text)
        }
    }

    @Test("text that is not prose in English is left alone: As spoken, code, another language")
    func appliesOnlyToCleanedEnglishProse() {
        var verbatim = CleanupOptions(level: .verbatim)
        #expect(ParagraphLayout.apply(Self.cued, options: verbatim) == Self.cued)
        verbatim.level = .clean
        #expect(ParagraphLayout.apply(Self.cued, options: verbatim) != Self.cued)
        var code = CleanupOptions(level: .polished)
        code.isCodeContext = true
        #expect(ParagraphLayout.apply(Self.cued, options: code) == Self.cued)
        let german = CleanupOptions(level: .polished, detectedLanguage: "de")
        #expect(ParagraphLayout.apply(Self.cued, options: german) == Self.cued)
        #expect(ParagraphLayout.apply(Self.cued, options: CleanupOptions(level: .polished)) != Self.cued)
    }

    @Test("a chat app gets the same layout: the text is pasted, never typed, so a blank line cannot send it")
    func chatAppGetsParagraphsToo() {
        var chat = CleanupOptions(level: .polished)
        chat.isCasualContext = true
        #expect(ParagraphLayout.apply(Self.cued, options: chat) == ParagraphLayout.apply(Self.cued))
    }

    @Test("the style and tone steps that run after it keep the paragraphs and the words")
    func stylesKeepTheBreaks() {
        let laid = ParagraphLayout.apply("Hi Marcus, " + Self.cued)
        let breaks = laid.components(separatedBy: "\n\n").count - 1
        #expect(breaks >= 1)
        for context in [StyleContext.email, .workMessages, .personalMessages, .other] {
            let styled = StyleFormatter.apply(.formal, to: laid, in: context)
            #expect(words(styled).count >= words(laid).count - 1)
            #expect(styled.components(separatedBy: "\n\n").count - 1 >= breaks)
            let toned = ToneRegister.apply(.professional, to: laid, in: context)
            #expect(toned.components(separatedBy: "\n\n").count - 1 >= breaks)
        }
    }

    // MARK: - Through the cleaner

    @Test("the rules draft of a long dictation is laid out, which is what a refused model answer falls back to")
    func cleanerLaysOutTheRulesDraft() async {
        let flat = await SmartCleaner(laysOutParagraphs: false).clean(Self.cued, options: CleanupOptions(level: .clean), strategy: .rules)
        #expect(!flat.text.contains("\n"))
        let output = await SmartCleaner().clean(Self.cued, options: CleanupOptions(level: .clean), strategy: .rules)
        #expect(output.text.contains("\n\n"))
        #expect(words(output.text) == words(flat.text))
        let verbatim = await SmartCleaner().clean(Self.cued, options: CleanupOptions(level: .verbatim), strategy: .rules)
        #expect(!verbatim.text.contains("\n"))
    }

    @Test("a model answer without breaks is laid out; a model answer with its own breaks is kept")
    func cleanerKeepsTheModelsOwnBreaks() async {
        let spoken = Self.cued
        let polished = CleanupOptions(level: .polished)
        let plain = await SmartCleaner(model: BlockModel(answer: Self.cued), health: ModelHealth())
            .clean(spoken, options: polished, strategy: .model)
        #expect(plain.text.contains("\n\n") || !plain.usedModel)
        let own = Self.cued.replacingOccurrences(of: "I will send that back", with: "\n\nI will send that back")
        let kept = await SmartCleaner(model: BlockModel(answer: own), health: ModelHealth())
            .clean(spoken, options: polished, strategy: .model)
        if kept.usedModel { #expect(kept.text.components(separatedBy: "\n\n").count == 2) }
    }
}

private struct BlockModel: LanguageModel {
    let answer: String
    var identifier: String { "synthetic-block" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        String(decoding: try JSONEncoder().encode(["text": answer]), as: UTF8.self)
    }
}
