import Foundation
import Testing
@testable import MurmurCore

@Suite("OpenCommandParser and AI hand-off links")
struct OpenCommandParserTests {
    static let context = DateContext(
        now: ProposalFields.parseISO8601("2026-09-28T12:00:00-07:00")!, timeZone: TimeZone(identifier: "America/Los_Angeles")!)

    private func link(_ utterance: String) -> DeepLinkBuilder.Link? {
        if case .link(let link)? = OpenCommandParser.parse(utterance, context: Self.context) { return link }
        return nil
    }

    @Test("open <app> names the app; open gmail is a link")
    func apps() {
        #expect(OpenCommandParser.parse("open slack") == .app(name: "Slack"))
        #expect(OpenCommandParser.parse("open chrome") == .app(name: "Chrome"))
        #expect(OpenCommandParser.parse("open anti gravity") == .app(name: "Anti Gravity"))
        #expect(OpenCommandParser.parse("open cloud") == .aiService(.claude))
        #expect(OpenCommandParser.parse("open chat gbt") == .aiService(.chatgpt))
        #expect(OpenCommandParser.parse("open perplexity") == .aiService(.perplexity))
        #expect(OpenCommandParser.parse("open gemini") == .aiService(.gemini))
        #expect(OpenCommandParser.parse("switch to visual studio code") == .app(name: "Visual Studio Code"))
        #expect(OpenCommandParser.parse("okay open up figma") == .app(name: "Figma"))
        #expect(link("open gmail")?.url.absoluteString == "https://mail.google.com/mail/u/0/")
        #expect(OpenCommandParser.parse("open my calendar") == .app(name: "Calendar"))
    }

    @Test("searches go to fixed hosts with the query encoded")
    func searches() {
        #expect(link("search gmail for invoice dana")?.url.absoluteString == "https://mail.google.com/mail/u/0/#search/invoice%20dana")
        #expect(link("search youtube for lo fi beats")?.url.host == "www.youtube.com")
        #expect(link("google best pizza in oakland")?.url.absoluteString == "https://www.google.com/search?q=best%20pizza%20in%20oakland")
        #expect(link("search for how to tie a tie")?.url.host == "www.google.com")
        // Spoken text carries no "&": punctuation is dropped before the query is built.
        #expect(link("look up cheap flights to lisbon & back")?.url.absoluteString == "https://www.google.com/search?q=cheap%20flights%20to%20lisbon%20back")
    }

    @Test("calendar days and directions")
    func calendarAndMaps() {
        #expect(link("show google calendar tomorrow")?.url.absoluteString == "https://calendar.google.com/calendar/u/0/r/day/2026/9/29")
        #expect(link("open my calendar for friday")?.url.path == "/calendar/u/0/r/day/2026/10/2")
        #expect(link("directions to the ferry building")?.url.query?.contains("destination=the%20ferry%20building") == true)
    }

    @Test("github repos need owner slash repo and stay on github.com")
    func github() {
        #expect(link("open github issues for anthropics slash claude-code")?.url.absoluteString == "https://github.com/anthropics/claude-code/issues")
        #expect(link("open the pull requests on github for acme/site")?.url.path == "/acme/site/pulls")
        #expect(OpenCommandParser.parse("open github for evil.com/x/y") == nil)
    }

    @Test("spoken domains are screened; unspoken hosts never open")
    func spokenDomains() {
        #expect(link("open example dot com")?.url.absoluteString == "https://example.com")
        #expect(link("go to github dot com slash apple")?.url.absoluteString == "https://github.com/apple")
        #expect(OpenCommandParser.parse("take a note saying open evil.com") == nil)
    }

    @Test("nothing to open is nil, never a guess")
    func nothing() {
        #expect(OpenCommandParser.parse("remind me to open the window") == nil)
        #expect(OpenCommandParser.parse("open") == nil)
        #expect(OpenCommandParser.parse("so i opened slack and nothing happened") == nil)
    }

    @Test("a tools-v1 open_app call resolves through the same builder")
    func toolCall() {
        let call = ToolCall(tool: "open_app", arguments: [
            "target": .string("gmail"), "service": .string("gmail"), "action": .string("search"), "query": .string("invoice dana"),
        ])
        guard case .link(let link)? = OpenCommandParser.resolve(call: call, utterance: "search gmail for invoice dana") else {
            Issue.record("expected a link")
            return
        }
        #expect(link.url.host == "mail.google.com")
        #expect(OpenCommandParser.resolve(call: ToolCall(tool: "open_app", arguments: ["target": .string("Chrome")]), utterance: "open chrome") == .app(name: "Chrome"))
        #expect(OpenCommandParser.resolve(call: ToolCall(tool: "open_app", arguments: ["target": .string("Open Chrome")]), utterance: "open chrome") == .app(name: "Chrome"))
        #expect(OpenCommandParser.resolve(call: ToolCall(tool: "open_app", arguments: ["target": .string("Open the app ChatGPT")]), utterance: "open chat gpt") == .aiService(.chatgpt))
        #expect(OpenCommandParser.resolve(call: ToolCall(tool: "create_reminder"), utterance: "x") == nil)
    }

    @Test("AI hand-off links use fixed templates and encode the question fully")
    func handoffLinks() throws {
        let claude = try #require(AIHandoffLink.build(service: .claude, question: "why is the sky blue?"))
        #expect(claude.url.absoluteString == "https://claude.ai/new?q=why%20is%20the%20sky%20blue%3F")
        #expect(claude.summary == "Ask Claude")
        let chatgpt = try #require(AIHandoffLink.build(service: .chatgpt, question: "a & b = c"))
        #expect(chatgpt.url.absoluteString == "https://chatgpt.com/?q=a%20%26%20b%20%3D%20c")
        #expect(AIHandoffLink.build(service: .perplexity, question: "x")?.url.host == "www.perplexity.ai")
        #expect(AIHandoffLink.build(service: .gemini, question: "x")?.url.absoluteString == "https://www.google.com/search?udm=50&q=x")
        #expect(AIHandoffLink.build(service: .claude, question: "  ") == nil)
        #expect(AIHandoffLink.Service.named("chat gpt") == .chatgpt)
        #expect(AIHandoffLink.Service.named("siri") == nil)
    }

    @Test("fillers and polite lead-ins change nothing, whether the words come from the speech path or a tool call's target")
    func fillersAreInvisible() {
        let bare: [(phrase: String, spoken: [String])] = [
            ("go to gmail.com", ["Uh, can you go to gmail.com?", "uh can you go to gmail.com", "okay so uh go to gmail.com", "Can you please go to gmail.com"]),
            ("open slack", ["Uh, can you open slack", "um could you please open slack", "can you uh open slack"]),
        ]
        for (phrase, spokenForms) in bare {
            let expected = OpenCommandParser.parse(phrase, context: Self.context)
            #expect(expected != nil)
            for spoken in spokenForms {
                #expect(OpenCommandParser.parse(spoken, context: Self.context) == expected, "speech path: \(spoken)")
                // A tool caller that puts the whole phrase in `target`.
                let call = ToolCall(tool: "open_app", arguments: ["target": .string(spoken)])
                #expect(OpenCommandParser.resolve(call: call, utterance: spoken, context: Self.context) == expected, "tool target: \(spoken)")
            }
        }
        // A real app whose name starts with a filler word is still an app.
        #expect(OpenCommandParser.parse("open quick look") == .app(name: "Quick Look"))
        let quick = ToolCall(tool: "open_app", arguments: ["target": .string("Quick Look")])
        #expect(OpenCommandParser.resolve(call: quick, utterance: "open quick look") == .app(name: "Quick Look"))
    }
}
