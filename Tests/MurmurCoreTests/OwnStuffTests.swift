import Foundation
import Synchronization
import Testing
@testable import MurmurCore

/// Retrieval, grounding and the answerer end to end with a scripted model and fixture sources.
@Suite("Own stuff: retrieval, grounding, answers")
struct OwnStuffTests {
    /// Monday 2026-09-28 12:00 in Los Angeles.
    static let context = DateContext(
        now: ProposalFields.parseISO8601("2026-09-28T12:00:00-07:00")!, timeZone: TimeZone(identifier: "America/Los_Angeles")!)

    static func day(_ iso: String) -> Date { ProposalFields.parseISO8601(iso)! }

    static let groceries = OwnStuffItem(
        id: "note-1", kind: .note, title: "Groceries", body: "oat milk\neggs\nsourdough\ncoffee beans",
        date: day("2026-09-26T09:00:00-07:00"))
    static let pricing = OwnStuffItem(
        id: "note-2", kind: .note, title: "Pricing sync", body: "We decided on $10 a month and $80 a year. No lifetime plan. Dana owns the pricing page.",
        date: day("2026-09-24T15:00:00-07:00"))
    static let tuesday = OwnStuffItem(
        id: "cal-2026-09-29", kind: .calendarDay, title: "Tuesday", body: "9:00 Standup\n14:00 Dentist",
        date: day("2026-09-29T00:00:00-07:00"))

    struct FixtureSource: OwnStuffSource {
        let name = "fixture"
        let items: [OwnStuffItem]
        func search(_ query: OwnStuffQuery) async -> [OwnStuffItem] { items }
    }

    // MARK: Retrieval

    @Test("keywords drop stop words and share a stem between groceries and grocery")
    func keywords() {
        #expect(OwnStuffRetriever.keywords(in: "what groceries do I need this weekend") == ["groceri", "weekend"])
        #expect(OwnStuffRetriever.keywords(in: "what did we decide about pricing?") == ["decide", "pricing"])
        #expect(OwnStuffRetriever.singular("grocery") == "groceri")
    }

    @Test("the grocery question ranks the groceries note first; pricing ranks the pricing note")
    func ranking() {
        let all = [Self.pricing, Self.groceries, Self.tuesday]
        let grocery = OwnStuffQuery(question: "what groceries do i need this weekend", context: Self.context)
        #expect(OwnStuffRetriever.rank(all, for: grocery).first?.id == "note-1")
        let pricing = OwnStuffQuery(question: "what did we decide about pricing", context: Self.context)
        #expect(OwnStuffRetriever.rank(all, for: pricing).map(\.id) == ["note-2"])
    }

    @Test("a day question keeps that calendar day even without keyword hits")
    func dateWindow() {
        let query = OwnStuffQuery(question: "what's on my calendar tomorrow", context: Self.context)
        #expect(query.dateWindow?.start == Self.context.calendar.startOfDay(for: Self.day("2026-09-29T12:00:00-07:00")))
        #expect(OwnStuffRetriever.rank([Self.groceries, Self.tuesday], for: query).first?.id == "cal-2026-09-29")
        let weekend = OwnStuffQuery(question: "anything this weekend", context: Self.context)
        #expect(weekend.dateWindow?.start == Self.context.calendar.startOfDay(for: Self.day("2026-10-03T12:00:00-07:00")))
    }

    @Test("nothing matching returns nothing, not the most recent thing")
    func noMatch() {
        let query = OwnStuffQuery(question: "what did the plumber quote", context: Self.context)
        #expect(OwnStuffRetriever.rank([Self.groceries, Self.pricing], for: query).isEmpty)
    }

    // MARK: Grounding

    @Test("items the source doesn't contain are dropped; a bad source index is refused")
    func grounding() {
        let grounded = AnswerGrounding.groundedItems(["Oat milk", "eggs", "bananas", "Coffee beans"], in: Self.groceries)
        #expect(grounded == ["Oat milk", "eggs", "Coffee beans"])
        let invented = OwnStuffModelAnswer(answer: "You need bananas.", sourceIndex: 3, items: ["bananas"])
        #expect(AnswerGrounding.verify(invented, sources: [Self.groceries]).isFailure)
        let none = OwnStuffModelAnswer(answer: "", sourceIndex: 0, items: [])
        #expect(AnswerGrounding.verify(none, sources: [Self.groceries]).isFailure)
    }

    // MARK: The answerer

    @Test("an answer cites the source and lists only what it contains")
    func answerGrounded() async throws {
        let model = ScriptedAnswerModel(json: #"{"answer":"You need four things.","sourceIndex":1,"items":["oat milk","eggs","bananas","sourdough","coffee beans"]}"#)
        let answerer = OwnStuffAnswerer(sources: [FixtureSource(items: [Self.groceries, Self.pricing])], model: model)
        let answer = try await answerer.answer("what groceries do i need this weekend", context: Self.context).get()
        #expect(answer.source.id == "note-1")
        #expect(answer.items == ["oat milk", "eggs", "sourdough", "coffee beans"])
        #expect(answer.text == "You need four things.")
        #expect(!answer.isExtractive)
        #expect(model.lastPrompt?.contains("Source 1: your note 'Groceries' (Sep 26)") == true)
        #expect(model.lastPrompt?.contains("Question: what groceries do i need this weekend") == true)
    }

    @Test("a follow-up carries the thread into the prompt")
    func followUpThread() async {
        let model = ScriptedAnswerModel(json: #"{"answer":"Dana owns the pricing page.","sourceIndex":1,"items":[]}"#)
        let answerer = OwnStuffAnswerer(sources: [FixtureSource(items: [Self.pricing])], model: model)
        let thread = [AskTurn(question: "what did we decide about pricing", answer: "$10 a month and $80 a year.")]
        _ = await answerer.answer("who owns the pricing page", thread: thread, context: Self.context)
        #expect(model.lastPrompt?.contains("Earlier in this thread:\nQ: what did we decide about pricing") == true)
    }

    @Test("no match is a plain not-found with a next place to look")
    func notFound() async {
        let model = ScriptedAnswerModel(json: "{}")
        let answerer = OwnStuffAnswerer(sources: [FixtureSource(items: [Self.pricing])], model: model)
        let result = await answerer.answer("what groceries do i need", context: Self.context)
        #expect(result == .failure(.notFound(message: "I couldn't find anything about groceri in your notes, reminders or calendar.", suggestion: "Search Apple Notes?")))
        #expect(model.callCount == 0)
    }

    @Test("without a model the card quotes the best source instead of inventing")
    func extractiveFallback() async throws {
        let answerer = OwnStuffAnswerer(sources: [FixtureSource(items: [Self.groceries])], model: NullLanguageModel())
        let answer = try await answerer.answer("groceries", context: Self.context).get()
        #expect(answer.isExtractive)
        #expect(answer.items == ["oat milk", "eggs", "sourdough", "coffee beans"])
    }

    @Test("the model saying no source answers it is reported, not papered over")
    func sourcesDontSay() async {
        let model = ScriptedAnswerModel(json: #"{"answer":"","sourceIndex":0,"items":[]}"#)
        let answerer = OwnStuffAnswerer(sources: [FixtureSource(items: [Self.groceries])], model: model)
        let result = await answerer.answer("groceries", context: Self.context)
        #expect(result == .failure(.sourcesDontSay(message: "Your notes don't say. I looked at 1 source.")))
    }

    // MARK: Summarize this

    @Test("short text is one call; the result is text only")
    func summarizeShort() async throws {
        let model = ScriptedAnswerModel(json: #"{"gist":"A note about pricing.","points":["$10 a month","No lifetime plan"]}"#)
        let summarizer = ScreenSummarizer(model: model)
        let text = Array(repeating: "We decided on ten dollars a month and eighty a year with no lifetime plan at all.", count: 4).joined(separator: "\n")
        let summary = try await summarizer.summarize(text).get()
        #expect(summary.gist == "A note about pricing.")
        #expect(summary.points.count == 2)
        #expect(model.callCount == 1)
    }

    @Test("too little text and an unavailable model fail plainly")
    func summarizeFailures() async {
        let summarizer = ScreenSummarizer(model: ScriptedAnswerModel(json: "{}"))
        #expect(await summarizer.summarize("just a few words here") == .failure(.tooShort))
        #expect(await summarizer.summarize("") == .failure(.nothingToRead))
        let words = Array(repeating: "one two three four five six seven eight nine ten", count: 5).joined(separator: " ")
        #expect(await ScreenSummarizer(model: NullLanguageModel()).summarize(words) == .failure(.modelUnavailable))
    }

    @Test("window chrome (short lines) is dropped before summarizing")
    func cleaned() {
        #expect(ScreenSummarizer.cleaned("File\nEdit\nA real sentence with several words in it.\nOK") == "A real sentence with several words in it.")
    }
}

extension Result {
    var isFailure: Bool { if case .failure = self { true } else { false } }
}

final class ScriptedAnswerModel: LanguageModel {
    private let json: String
    private let state = Mutex<[String]>([])

    init(json: String) { self.json = json }

    var callCount: Int { state.withLock { $0.count } }
    var lastPrompt: String? { state.withLock { $0.last } }
    var identifier: String { "scripted" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}

    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        state.withLock { $0.append(prompt) }
        return json
    }
}
