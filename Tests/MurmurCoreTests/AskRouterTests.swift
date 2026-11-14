import Foundation
import Testing
@testable import MurmurCore

/// Intent routing under the action chord: ask an AI, ask about your own stuff, summarize the
/// screen, or nothing (the Do path / plain dictation decides). Cases here are written from
/// scratch; `Evals/ask-routing-dev.json` is the separate measured set.
@Suite("AskRouter")
struct AskRouterTests {
    // MARK: Ask an AI

    @Test("ask <service> hands the question off", arguments: [
        ("ask claude why the sky is blue", AIHandoffLink.Service.claude, "why the sky is blue"),
        ("hey hushy ask chat gpt to write a haiku about rain", .chatgpt, "write a haiku about rain"),
        ("ask perplexity about the french revolution", .perplexity, "tell me about the french revolution"),
        ("ask gemini whether react or vue is better for a small team", .gemini, "whether react or vue is better for a small team"),
        ("okay so ask claude if postgres supports jsonb indexes", .claude, "whether postgres supports jsonb indexes"),
        ("search perplexity for best mechanical keyboards 2026", .perplexity, "best mechanical keyboards 2026"),
        ("can you ask chatgpt what a monad is", .chatgpt, "what a monad is"),
    ])
    func handoff(utterance: String, service: AIHandoffLink.Service, question: String) {
        #expect(AskRouter.route(utterance) == .askAI(service: service, question: question))
    }

    @Test("mentions of an AI are not hand-offs", arguments: [
        "i asked claude yesterday and it said the same thing",
        "she asked chatgpt about it and got nowhere",
        "we should ask claude about that at some point",
        "remind me to ask claude about the migration tomorrow",
        "ask claude",
        "the claude answer was wrong",
    ])
    func handoffNegatives(utterance: String) {
        if case .askAI = AskRouter.route(utterance) { Issue.record("\(utterance) routed to an AI") }
    }

    @Test("asking the team is not asking an AI")
    func askTeamIsNotHandoff() {
        #expect(AskRouter.route("ask the team whether friday works") == .none)
    }

    // MARK: Summarize this

    @Test("summarize this reads the screen", arguments: [
        ("summarize this", nil),
        ("summarise this page", nil),
        ("tldr this article", nil),
        ("give me the gist of this email", nil),
        ("what's this page about", nil),
        ("what does this say about pricing", "pricing"),
        ("summarize this thread focusing on the deadline", "the deadline"),
        ("hey hushy summarize what's on my screen", nil),
    ])
    func summarize(utterance: String, focus: String?) {
        #expect(AskRouter.route(utterance) == .summarizeScreen(focus: focus))
    }

    @Test("summarizing your own meeting is an own-stuff question, not a screen read")
    func summarizeOwnMeeting() {
        #expect(AskRouter.route("summarize my meeting with dana") == .askOwn(question: "summarize my meeting with dana"))
        #expect(AskRouter.route("summarize yesterday's standup") == .askOwn(question: "summarize yesterday's standup"))
    }

    @Test("a read that also asks to send goes to the Do path, never a read")
    func readNeverSends() {
        #expect(AskRouter.route("summarize this and email it to dana") == .none)
        #expect(AskRouter.route("what's on my calendar tomorrow and text it to priya") == .none)
    }

    // MARK: Ask about your own stuff

    @Test("questions about your own things", arguments: [
        "what groceries do i need this weekend",
        "what's on my calendar tomorrow",
        "what did we decide about pricing",
        "when is my dentist appointment",
        "do i have anything on friday",
        "show me my notes from yesterday",
        "what's on my to do list",
        "who did i say would own the migration",
        "how many meetings do i have today",
        "check my reminders for tonight",
        "what did priya say about the deck in our meeting",
        "remind me what we agreed with the vendor",
    ])
    func ownStuff(utterance: String) {
        #expect(AskRouter.route(utterance) == .askOwn(question: AskRouter.frame(utterance)))
    }

    @Test("questions about the world, hedges and reported speech are not own-stuff asks", arguments: [
        "what time is it",
        "what's the weather like",
        "what's the capital of france",
        "i wonder what's on my calendar",
        "i don't know what we decided about pricing",
        "he asked what's on my calendar",
        "my mom always asks what groceries we need",
        "what a day",
    ])
    func ownStuffNegatives(utterance: String) {
        #expect(AskRouter.route(utterance) == .none, "\(utterance)")
    }

    // MARK: Do and dictation stay untouched

    @Test("commands and dictation route to none", arguments: [
        "remind me to call the plumber tomorrow at nine",
        "add a dentist appointment tomorrow at three",
        "open slack",
        "text priya saying i'm running late",
        "so the thing about the migration is that we need more time",
        "",
    ])
    func doPath(utterance: String) {
        #expect(AskRouter.route(utterance) == .none)
    }

    @Test("the frame strips lead-ins and punctuation")
    func frame() {
        #expect(AskRouter.frame("Okay, so, hey Hushy: what’s on my calendar?") == "what's on my calendar")
        #expect(AskRouter.frame("please just ask Claude...") == "ask claude")
    }
}
