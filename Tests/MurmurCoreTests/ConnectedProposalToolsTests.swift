import Foundation
import GRDB
import Testing
@testable import MurmurCore

/// The connected `propose_*` tools (`propose_calendar_invite`, `propose_email_draft`,
/// `propose_message`, `propose_issue`) validate and acknowledge, and nothing else — on the MCP
/// server and in the Assistant's stream parser alike. No card, no execution, no side effect.
@Suite("Connected propose_* tools: validation")
struct ConnectedProposalValidationTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21

    private func iso(_ offset: TimeInterval) -> String {
        ProposalFields.isoFormatter().string(from: now.addingTimeInterval(offset))
    }

    private func json(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    // MARK: propose_calendar_invite

    @Test("an invite with attendees as emails, names, objects and “Name <email>” parses")
    func invite() throws {
        let invite = try ProposeCalendarInviteTool.validate([
            "title": " Roadmap sync\u{0007} ", "start": iso(86_400), "durationMinutes": 45,
            "attendees": ["dana@example.com", " Priya ", "Sam Lee <sam.lee@example.co.uk>", ["name": "Ana", "email": "ana@example.org"], ""],
            "notes": "Agenda:\n1. gates", "location": "Zoom", "calendarHint": "Work",
        ], sourceText: "set up a sync", now: now).get()
        #expect(invite.title == "Roadmap sync")
        #expect(invite.durationMinutes == 45)
        #expect(invite.attendees == [
            ProposedAttendee(email: "dana@example.com"), ProposedAttendee(name: "Priya"),
            ProposedAttendee(name: "Sam Lee", email: "sam.lee@example.co.uk"), ProposedAttendee(name: "Ana", email: "ana@example.org"),
        ])
        #expect(invite.attendees.map(\.display) == ["dana@example.com", "Priya", "Sam Lee <sam.lee@example.co.uk>", "Ana <ana@example.org>"])
        #expect(invite.notes == "Agenda:\n1. gates")
        #expect(invite.location == "Zoom")
        #expect(invite.calendarHint == "Work")
        #expect(invite.sourceText == "set up a sync")
        let single = try ProposeCalendarInviteTool.validate(["title": "1:1", "start": iso(3600), "attendees": "dana@example.com"], now: now).get()
        #expect(single.attendees == [ProposedAttendee(email: "dana@example.com")])
        #expect(single.durationMinutes == 30)
    }

    @Test("invites without a start, attendees or with a bad attendee are rejected", arguments: [
        #"{"title":"x","attendees":["a@b.co"]}"#,
        #"{"title":"x","start":"START","attendees":[]}"#,
        #"{"title":"x","start":"START","attendees":[""]}"#,
        #"{"title":"x","start":"START"}"#,
        #"{"title":"x","start":"START","attendees":["not an email@"]}"#,
        #"{"title":"x","start":"START","attendees":["dana@localhost"]}"#,
        #"{"title":"x","start":"START","attendees":["Dana <nope>"]}"#,
        #"{"title":"x","start":"START","attendees":[{"name":"dana@example.com"}]}"#,
        #"{"title":"x","start":"START","attendees":[{"email":"bad"}]}"#,
        #"{"title":"x","start":"START","attendees":[42]}"#,
        #"{"title":"x","start":"START","attendees":"a@b.co","durationMinutes":2}"#,
        #"{"title":"x","start":"2026-09-22","attendees":["a@b.co"]}"#,
        #"{"title":"x","start":"2026-09-10T10:00:00Z","attendees":["a@b.co"]}"#,
        #"{"title":"x","start":"2035-01-01T10:00:00Z","attendees":["a@b.co"]}"#,
        #"{"title":"","start":"START","attendees":["a@b.co"]}"#,
        #"{"title":"x","start":"START","attendees":["a@b.co"],"notes":"my password is hunter2!"}"#,
        #"{"title":"card 4111 1111 1111 1111","start":"START","attendees":["a@b.co"]}"#,
    ])
    func rejectsInvites(_ template: String) throws {
        let arguments = try json(template.replacingOccurrences(of: "START", with: iso(3600)))
        #expect(throws: ProposalValidationError.self) { try ProposeCalendarInviteTool.validate(arguments, now: now).get() }
    }

    @Test("too many attendees is rejected")
    func tooManyAttendees() {
        let many = (0..<51).map { "p\($0)@example.com" }
        let result = ProposeCalendarInviteTool.validate(["title": "x", "start": iso(3600), "attendees": many], now: now)
        #expect(throws: ProposalValidationError.self) { try result.get() }
    }

    // MARK: propose_email_draft

    @Test("an email draft with to, cc, subject, body and a reply-to id parses")
    func emailDraft() throws {
        let draft = try ProposeEmailDraftTool.validate([
            "to": ["dana@example.com", "priya+team@example.io"], "cc": "ops@example.com",
            "subject": "Deck on Monday", "body": "Hi Dana,\n\nI'll send the deck Monday.\n\nThanks",
            "replyToMessageId": "<CAF+abc123@mail.example.com>",
        ], sourceText: "reply to Dana", now: now).get()
        #expect(draft.to == ["dana@example.com", "priya+team@example.io"])
        #expect(draft.cc == ["ops@example.com"])
        #expect(draft.subject == "Deck on Monday")
        #expect(draft.body.hasPrefix("Hi Dana,\n\n"))
        #expect(draft.replyToMessageID == "<CAF+abc123@mail.example.com>")
        #expect(draft.sourceText == "reply to Dana")
        let plain = try ProposeEmailDraftTool.validate(["to": "dana@example.com", "subject": "Hi", "body": "Hello"], now: now).get()
        #expect(plain.cc.isEmpty)
        #expect(plain.replyToMessageID == nil)
    }

    @Test("email drafts with bad recipients, missing fields or secrets are rejected", arguments: [
        #"{"subject":"s","body":"b"}"#,
        #"{"to":[],"subject":"s","body":"b"}"#,
        #"{"to":["dana"],"subject":"s","body":"b"}"#,
        #"{"to":["dana@example"],"subject":"s","body":"b"}"#,
        #"{"to":["Dana <dana@example.com>"],"subject":"s","body":"b"}"#,
        #"{"to":["dana@example.com"],"cc":["nope"],"subject":"s","body":"b"}"#,
        #"{"to":["dana@example.com"],"cc":[1],"subject":"s","body":"b"}"#,
        #"{"to":["dana@example.com"],"body":"b"}"#,
        #"{"to":["dana@example.com"],"subject":"s"}"#,
        #"{"to":["dana@example.com"],"subject":"s","body":"   "}"#,
        #"{"to":["dana@example.com"],"subject":"s","body":"b","replyToMessageId":"has a space"}"#,
        #"{"to":["dana@example.com"],"subject":"s","body":"Here's my card 5555 5555 5555 4444, thanks"}"#,
        #"{"to":["dana@example.com"],"subject":"s","body":"password: hunter2"}"#,
        #"{"to":["dana@example.com"],"subject":"the key is sk_live_4eC39HqLyjWDarjtT1zdp7dc","body":"b"}"#,
    ])
    func rejectsEmailDrafts(_ input: String) throws {
        #expect(throws: ProposalValidationError.self) { try ProposeEmailDraftTool.validate(try json(input), now: now).get() }
    }

    @Test("length caps apply to subject, body and recipient count")
    func emailCaps() throws {
        let longSubject = String(repeating: "s", count: ProposalFields.maxSubjectLength + 1)
        #expect(throws: ProposalValidationError.self) {
            try ProposeEmailDraftTool.validate(["to": "a@b.co", "subject": longSubject, "body": "b"], now: now).get()
        }
        let longBody = String(repeating: "b", count: ProposalFields.maxBodyLength + 1)
        #expect(throws: ProposalValidationError.self) {
            try ProposeEmailDraftTool.validate(["to": "a@b.co", "subject": "s", "body": longBody], now: now).get()
        }
        let maxBody = String(repeating: "b", count: ProposalFields.maxBodyLength)
        #expect(try ProposeEmailDraftTool.validate(["to": "a@b.co", "subject": "s", "body": maxBody], now: now).get().body.count == ProposalFields.maxBodyLength)
        let many = (0..<51).map { "p\($0)@example.com" }
        #expect(throws: ProposalValidationError.self) {
            try ProposeEmailDraftTool.validate(["to": many, "subject": "s", "body": "b"], now: now).get()
        }
    }

    // MARK: propose_message

    @Test("a message with channel, recipient and text parses; the channel is normalised")
    func message() throws {
        let message = try ProposeMessageTool.validate(
            ["channel": " Slack ", "recipient": "#launch", "text": "Build is green \u{0007}✅"], sourceText: "tell the team", now: now).get()
        #expect(message.channel == "slack")
        #expect(message.recipient == "#launch")
        #expect(message.text == "Build is green ✅")
        #expect(message.sourceText == "tell the team")
    }

    @Test("messages missing a field, over the cap or carrying secrets are rejected", arguments: [
        ##"{"recipient":"#launch","text":"hi"}"##,
        #"{"channel":"slack","text":"hi"}"#,
        ##"{"channel":"slack","recipient":"#launch"}"##,
        ##"{"channel":"slack","recipient":"#launch","text":""}"##,
        ##"{"channel":["slack"],"recipient":"#launch","text":"hi"}"##,
        ##"{"channel":"slack","recipient":"#launch","text":"the wifi password is Sunny-Day-2026"}"##,
        ##"{"channel":"slack","recipient":"#launch","text":"your OTP is 482913"}"##,
    ])
    func rejectsMessages(_ input: String) throws {
        #expect(throws: ProposalValidationError.self) { try ProposeMessageTool.validate(try json(input), now: now).get() }
    }

    @Test("message text is capped")
    func messageCap() {
        let long = String(repeating: "m", count: ProposalFields.maxMessageLength + 1)
        #expect(throws: ProposalValidationError.self) {
            try ProposeMessageTool.validate(["channel": "slack", "recipient": "#x", "text": long], now: now).get()
        }
    }

    // MARK: propose_issue

    @Test("an issue with tracker, project, title, description and labels parses")
    func issue() throws {
        let issue = try ProposeIssueTool.validate([
            "tracker": "Linear", "project": "Hushy", "title": "Paste fails in Figma comments",
            "description": "Steps:\n1. dictate into a comment", "labels": ["bug", " paste ", ""],
        ], sourceText: "make a linear issue", now: now).get()
        #expect(issue.tracker == "linear")
        #expect(issue.project == "Hushy")
        #expect(issue.title == "Paste fails in Figma comments")
        #expect(issue.description == "Steps:\n1. dictate into a comment")
        #expect(issue.labels == ["bug", "paste"])
        #expect(issue.sourceText == "make a linear issue")
        let minimal = try ProposeIssueTool.validate(["tracker": "github", "project": "hushy/app", "title": "x"], now: now).get()
        #expect(minimal.description == nil)
        #expect(minimal.labels.isEmpty)
    }

    @Test("issues missing fields, with bad labels or secrets are rejected", arguments: [
        #"{"project":"p","title":"t"}"#,
        #"{"tracker":"linear","title":"t"}"#,
        #"{"tracker":"linear","project":"p"}"#,
        #"{"tracker":"linear","project":"p","title":"t","labels":"not-a-list-but-ok"}"#,
        #"{"tracker":"linear","project":"p","title":"t","labels":[1,2]}"#,
        #"{"tracker":"linear","project":"p","title":"t","labels":{"a":"b"}}"#,
        #"{"tracker":"linear","project":"p","title":"t","description":"repro with token: ghp_abcdefghijklmnopqrstuvwxyz1234"}"#,
        #"{"tracker":"linear","project":"p","title":"SSN 123-45-6789 leaks"}"#,
    ])
    func rejectsIssues(_ input: String) throws {
        let arguments = try json(input)
        let result = ProposeIssueTool.validate(arguments, now: now)
        if input.contains("not-a-list-but-ok") {
            // A single string is accepted as a one-item list.
            #expect(try result.get().labels == ["not-a-list-but-ok"])
        } else {
            #expect(throws: ProposalValidationError.self) { try result.get() }
        }
    }

    @Test("too many labels or a too-long label is rejected")
    func labelCaps() {
        let many = (0...ProposalFields.maxLabelCount).map { "l\($0)" }
        #expect(throws: ProposalValidationError.self) {
            try ProposeIssueTool.validate(["tracker": "linear", "project": "p", "title": "t", "labels": many], now: now).get()
        }
        let long = String(repeating: "l", count: ProposalFields.maxLabelLength + 1)
        #expect(throws: ProposalValidationError.self) {
            try ProposeIssueTool.validate(["tracker": "linear", "project": "p", "title": "t", "labels": [long]], now: now).get()
        }
    }

    // MARK: Shared pieces

    @Test("email format is conservative", arguments: [
        ("dana@example.com", true), ("priya+team@sub.example.io", true), ("o'neil@example.org", true),
        ("dana", false), ("dana@", false), ("@example.com", false), ("dana@example", false),
        ("dana@localhost", false), ("da na@example.com", false), (".dana@example.com", false),
        ("dana..lee@example.com", false), ("dana@-example.com", false), ("dana@example.c0m", false),
        ("Dana <dana@example.com>", false), ("dana@example.com,priya@example.com", false),
    ])
    func emailFormat(_ email: String, _ valid: Bool) {
        #expect(ProposalFields.isValidEmail(email) == valid, "\(email)")
    }

    @Test("the registry validates by bare tool name and knows nothing else")
    func registry() throws {
        #expect(ConnectedProposalTools.names == ["propose_calendar_invite", "propose_email_draft", "propose_message", "propose_issue"])
        #expect(ConnectedProposalTools.validate(tool: "propose_action", arguments: [:]) == nil)
        #expect(ConnectedProposalTools.validate(tool: "send_email", arguments: [:]) == nil)
        let proposal = try #require(ConnectedProposalTools.validate(
            tool: "propose_message", arguments: ["channel": "imessage", "recipient": "Dana", "text": "On my way"], sourceText: "text Dana")).get()
        guard case .message(let message) = proposal else {
            Issue.record("expected a message, got \(proposal)")
            return
        }
        #expect(message.channel == "imessage")
        #expect(proposal.toolName == "propose_message")
        #expect(proposal.sourceText == "text Dana")
        var relabelled = proposal
        relabelled.sourceText = "later"
        #expect(relabelled.sourceText == "later")
        #expect(relabelled.id == proposal.id)
        let failure = try #require(ConnectedProposalTools.validate(tool: "propose_issue", arguments: ["tracker": "jira"]))
        #expect(throws: ProposalValidationError.self) { try failure.get() }
    }

    @Test("summaries describe the proposal without claiming anything happened")
    func summaries() throws {
        let invite = try ProposeCalendarInviteTool.validate(["title": "Sync", "start": iso(3600), "attendees": ["dana@example.com"]], now: now).get()
        let email = try ProposeEmailDraftTool.validate(["to": "dana@example.com", "subject": "Deck", "body": "Monday"], now: now).get()
        let message = try ProposeMessageTool.validate(["channel": "slack", "recipient": "#launch", "text": "green"], now: now).get()
        let issue = try ProposeIssueTool.validate(["tracker": "linear", "project": "Hushy", "title": "Paste"], now: now).get()
        #expect(ConnectedProposalTools.summary(of: .calendarInvite(invite)).hasPrefix("invite “Sync” at "))
        #expect(ConnectedProposalTools.summary(of: .calendarInvite(invite)).hasSuffix(" for 30 min to dana@example.com"))
        #expect(ConnectedProposalTools.summary(of: .emailDraft(email)) == "email draft to dana@example.com “Deck”")
        #expect(ConnectedProposalTools.summary(of: .message(message)) == "slack message to #launch (5 characters)")
        #expect(ConnectedProposalTools.summary(of: .issue(issue)) == "linear issue in Hushy “Paste”")
    }

    @Test("proposals round-trip through Codable")
    func codable() throws {
        let invite = try ProposeCalendarInviteTool.validate(["title": "Sync", "start": iso(3600), "attendees": ["Priya", "dana@example.com"]], now: now).get()
        let proposal = ConnectedProposal.calendarInvite(invite)
        let data = try JSONEncoder().encode(proposal)
        #expect(try JSONDecoder().decode(ConnectedProposal.self, from: data) == proposal)
    }
}

/// The MCP server does not serve these tools (`MCPFailClosedTests`); the code that remains cannot send or run anything.
@Suite("Connected propose_* tools: no side effects")
struct ConnectedProposalServerTests {
    @Test("the tools and their shared validation never reference anything that could send or run")
    func noSideEffectDependencies() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = [
            "Sources/MurmurCore/Actions/ProposalFields.swift", "Sources/MurmurCore/Actions/SensitiveContentScreen.swift",
            "Sources/MurmurCore/Actions/ConnectedProposal.swift", "Sources/MurmurCore/Actions/ConnectedProposalTools.swift",
            "Sources/MurmurCore/Actions/ProposeCalendarInviteTool.swift", "Sources/MurmurCore/Actions/ProposeEmailDraftTool.swift",
            "Sources/MurmurCore/Actions/ProposeMessageTool.swift", "Sources/MurmurCore/Actions/ProposeIssueTool.swift",
            "Sources/MurmurCore/MCP/MCPServer.swift", "Sources/MurmurCore/MCP/ProposeActionTool.swift",
            "Sources/murmur-mcp/main.swift",
        ]
        let forbidden = [
            "import EventKit", "EKEventStore", "ActionExecutor", "ShortcutsActionBackend", "CalendarActionBackend",
            ".write {", "Process(", "URLSession", "NSWorkspace", "NSSharingService", "mailto:", "import AppKit",
        ]
        for file in files {
            // Code only: doc comments are allowed to explain what the tool doesn't do.
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for token in forbidden {
                #expect(!source.contains(token), "\(file) mentions \(token)")
            }
        }
    }
}

/// The Assistant side: the allow-list and runtime policy admit the tools, and the stream
/// parser turns a valid call into a `ConnectedProposal` carried on `AgentReply` (data only;
/// no card yet — see the TODO on `AgentReply.connectedProposals`).
@Suite("Connected propose_* tools: Assistant")
struct ConnectedProposalAssistantTests {
    private func line(_ tool: String, _ input: String) -> String {
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"Ready for you."},{"type":"tool_use","id":"t9","name":"\#(tool)","input":\#(input)}]}}"#
    }

    private func proposals(_ events: [AgentStreamEvent]) -> [ConnectedProposal] {
        events.compactMap { if case .connectedProposed(let proposal) = $0 { proposal } else { nil } }
    }

    @Test("the exact allow-list leaves out the four tools, and the runtime check refuses them")
    func allowList() {
        let allowed = ClaudeCodeCommand.allowedTools
        for name in ConnectedProposalTools.names {
            #expect(!allowed.contains("mcp__hushy__\(name)"))
        }
        #expect(allowed.count == 4 + MeetingMemoryTools.names.count)
        #expect(AgentToolPolicy.violations(in: allowed).isEmpty)
        #expect(AgentToolPolicy.violations(in: ["mcp__hushy__propose_email_draft"]) == ["mcp__hushy__propose_email_draft"])
        #expect(AgentToolPolicy.violations(in: ["mcp__hushy__propose_browser_task", "mcp__other__propose_message"])
            == ["mcp__hushy__propose_browser_task", "mcp__other__propose_message"])
        let arguments = ClaudeCodeCommand.arguments(mcpConfigPath: "/c", turn: AgentTurnOptions())
        let index = arguments.firstIndex(of: "--allowedTools").map { $0 + 1 }
        #expect(index.map { !arguments[$0].contains("mcp__hushy__propose_email_draft") } == true)
        #expect(ClaudeCodeCommand.connectedProposalTool(named: "mcp__hushy__propose_issue") == "propose_issue")
        #expect(ClaudeCodeCommand.connectedProposalTool(named: "mcp__hushy__propose_action") == nil)
        #expect(ClaudeCodeCommand.connectedProposalTool(named: "mcp__evil__propose_issue") == nil)
        #expect(ClaudeCodeCommand.connectedProposalTool(named: "propose_issue") == nil)
    }

    @Test("a valid propose_calendar_invite call is parsed into a ConnectedProposal with its values")
    func parsesInvite() throws {
        let start = ProposalFields.isoFormatter().string(from: Date().addingTimeInterval(7200))
        let events = AgentStreamParser.events(fromLine: line("mcp__hushy__propose_calendar_invite",
            #"{"title":"Roadmap sync","start":"\#(start)","durationMinutes":45,"attendees":["Priya","dana@example.com"],"location":"Zoom"}"#))
        #expect(events.count == 2)
        let parsed = try #require(proposals(events).first)
        guard case .calendarInvite(let invite) = parsed else {
            Issue.record("expected an invite, got \(parsed)")
            return
        }
        #expect(invite.title == "Roadmap sync")
        #expect(invite.durationMinutes == 45)
        #expect(invite.attendees == [ProposedAttendee(name: "Priya"), ProposedAttendee(email: "dana@example.com")])
        #expect(invite.location == "Zoom")
        #expect(invite.sourceText.isEmpty)
        var reply = AgentReply()
        for event in events { reply.apply(event) }
        #expect(reply.connectedProposals == [parsed])
        #expect(reply.proposedActions.isEmpty)
        #expect(reply.toolsUsed == ["mcp__hushy__propose_calendar_invite"])
        #expect(reply.activity == "Preparing something for you to confirm…")
    }

    @Test("email drafts, messages and issues are parsed with their values")
    func parsesOthers() throws {
        let email = try #require(proposals(AgentStreamParser.events(fromLine: line("mcp__hushy__propose_email_draft",
            #"{"to":["dana@example.com"],"cc":["ops@example.com"],"subject":"Deck on Monday","body":"I'll send it Monday.","replyToMessageId":"<abc@mail>"}"#))).first)
        guard case .emailDraft(let draft) = email else { Issue.record("expected a draft"); return }
        #expect(draft.to == ["dana@example.com"] && draft.cc == ["ops@example.com"])
        #expect(draft.subject == "Deck on Monday" && draft.body == "I'll send it Monday." && draft.replyToMessageID == "<abc@mail>")

        let message = try #require(proposals(AgentStreamParser.events(fromLine: line("mcp__hushy__propose_message",
            ##"{"channel":"Slack","recipient":"#launch","text":"Build is green"}"##))).first)
        guard case .message(let chat) = message else { Issue.record("expected a message"); return }
        #expect(chat.channel == "slack" && chat.recipient == "#launch" && chat.text == "Build is green")

        let issue = try #require(proposals(AgentStreamParser.events(fromLine: line("mcp__hushy__propose_issue",
            #"{"tracker":"linear","project":"Hushy","title":"Paste fails in Figma comments","labels":["bug"]}"#))).first)
        guard case .issue(let ticket) = issue else { Issue.record("expected an issue"); return }
        #expect(ticket.tracker == "linear" && ticket.project == "Hushy" && ticket.labels == ["bug"])
        #expect(ticket.title == "Paste fails in Figma comments" && ticket.description == nil)

        var reply = AgentReply()
        for event in [email, message, issue] { reply.apply(.connectedProposed(event)) }
        #expect(reply.connectedProposals.map(\.toolName) == ["propose_email_draft", "propose_message", "propose_issue"])
    }

    @Test("an invalid call, or the same name on another server, yields no proposal")
    func ignoresInvalid() {
        #expect(proposals(AgentStreamParser.events(fromLine: line("mcp__hushy__propose_email_draft", #"{"to":["dana"],"subject":"s","body":"b"}"#))).isEmpty)
        #expect(proposals(AgentStreamParser.events(fromLine: line("mcp__hushy__propose_message", ##"{"channel":"slack","recipient":"#x","text":"password: hunter2"}"##))).isEmpty)
        #expect(proposals(AgentStreamParser.events(fromLine: line("mcp__evil__propose_message", ##"{"channel":"slack","recipient":"#x","text":"hi"}"##))).isEmpty)
        #expect(proposals(AgentStreamParser.events(fromLine: line("mcp__hushy__propose_issue", #""not an object""#))).isEmpty)
        // The text block still arrives; only the proposal is dropped.
        #expect(AgentStreamParser.events(fromLine: line("mcp__hushy__propose_issue", #"{}"#)).count == 1)
    }

    @Test("tool summaries and activity labels cover the new tools")
    func labels() {
        #expect(AgentReply.toolSummary(["mcp__hushy__propose_calendar_invite", "mcp__hushy__propose_email_draft",
                                        "mcp__hushy__propose_message", "mcp__hushy__propose_issue", "mcp__hushy__propose_issue"])
            == "Proposed an invite · Drafted an email · Drafted a message · Proposed an issue")
        #expect(AgentReply.activityLabel(forTool: "mcp__hushy__propose_issue") == "Preparing something for you to confirm…")
    }
}
