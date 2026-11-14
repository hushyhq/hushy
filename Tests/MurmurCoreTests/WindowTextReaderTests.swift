import CoreGraphics
import Foundation
import Testing
@testable import MurmurCore

/// A fake Accessibility tree. `reads` records every text request, so a test can show that a skipped element's text was
/// never even asked for.
private final class FakeNode: WindowTextNode {
    var role: String?
    var subrole: String?
    var frame: CGRect?
    let label: String?
    var kids: [FakeNode] = []
    weak var parent: FakeNode?
    nonisolated(unsafe) static var reads: [String] = []

    init(_ role: String?, text: String? = nil, frame: CGRect? = nil, subrole: String? = nil, _ kids: [FakeNode] = []) {
        self.role = role; self.label = text; self.frame = frame; self.subrole = subrole; self.kids = kids
        kids.forEach { $0.parent = self }
    }

    var identity: AnyHashable { ObjectIdentifier(self) }
    func text() -> String? { if let label { Self.reads.append(label) }; return label }
    func parentNode() -> (any WindowTextNode)? { parent }
    func childNodes() -> [any WindowTextNode] { kids }
}

private struct Clock { var now = 0; var step = 0; mutating func read() -> Int { defer { now += step }; return now } }

/// A chat window: a sidebar of other conversations on the left, the conversation and its text box in the middle, an
/// artifact panel on the right, and a footer under the text box.
private struct ChatWindow {
    let composer = FakeNode("AXTextArea", text: "my half-written reply", frame: CGRect(x: 300, y: 700, width: 500, height: 60))
    let window: FakeNode

    init(messages: [String], extra: [FakeNode] = []) {
        let rows = messages.enumerated().map { index, text in
            FakeNode("AXStaticText", text: text, frame: CGRect(x: 310, y: 10 + index * 22, width: 480, height: 18))
        }
        let sidebar = FakeNode("AXGroup", frame: CGRect(x: 0, y: 0, width: 250, height: 800), [
            FakeNode("AXList", frame: CGRect(x: 0, y: 0, width: 250, height: 800), [
                FakeNode("AXStaticText", text: "Quarterly budget with Zebulon", frame: CGRect(x: 10, y: 20, width: 230, height: 20)),
                FakeNode("AXStaticText", text: "Trip to Reykjavik", frame: CGRect(x: 10, y: 60, width: 230, height: 20)),
            ]),
        ])
        let scroll = FakeNode("AXScrollArea", frame: CGRect(x: 300, y: 0, width: 500, height: 690), rows)
        let footer = FakeNode("AXStaticText", text: "Verify answers before relying on them", frame: CGRect(x: 300, y: 770, width: 500, height: 20))
        let main = FakeNode("AXGroup", frame: CGRect(x: 300, y: 0, width: 500, height: 800), [scroll, composer, footer] + extra)
        let panel = FakeNode("AXGroup", frame: CGRect(x: 850, y: 0, width: 350, height: 800), [
            FakeNode("AXStaticText", text: "Artifact: pricing table draft", frame: CGRect(x: 860, y: 20, width: 330, height: 20)),
        ])
        window = FakeNode("AXWindow", frame: CGRect(x: 0, y: 0, width: 1200, height: 800), [sidebar, main, panel])
    }

    func read(_ budget: WindowTextReader.Budget = .init(), step: Int = 0) -> WindowTextReader.Result {
        FakeNode.reads = []
        var clock = Clock(step: step)
        return WindowTextReader.read(from: composer, budget: budget, elapsedMilliseconds: { clock.read() })
    }
}

@Suite("WindowTextReader", .serialized)
struct WindowTextReaderTests {
    @Test("terminal reader uses only the focused visible grid")
    func terminalVisibleGrid() {
        let scrollback = FakeNode("AXStaticText", text: "private scrollback", frame: CGRect(x: 0, y: 0, width: 200, height: 20))
        let grid = FakeNode("AXTextArea", text: "PromptRouter.swift", frame: CGRect(x: 0, y: 20, width: 200, height: 200))
        _ = FakeNode("AXWindow", frame: CGRect(x: 0, y: 0, width: 200, height: 220), [scrollback, grid])
        FakeNode.reads = []
        let result = WindowTextReader.readVisibleTerminal(from: grid)
        #expect(result.text == "PromptRouter.swift")
        #expect(FakeNode.reads == ["PromptRouter.swift"])
    }

    @Test("reads the conversation above the text box, oldest first, and nothing from the sidebar, the side panel or the footer")
    func conversationOnly() {
        let chat = ChatWindow(messages: ["Can you look at pstack?", "It installs as a plugin.", "Which version?"])
        let result = chat.read()
        #expect(result.text == "Can you look at pstack?\nIt installs as a plugin.\nWhich version?")
        for other in ["Quarterly budget with Zebulon", "Trip to Reykjavik", "Artifact: pricing table draft",
                      "Verify answers before relying on them", "my half-written reply"] {
            #expect(!result.text.contains(other))
            #expect(!FakeNode.reads.contains(other), "\(other) was read although it is outside the rule")
        }
    }

    @Test("the newest messages survive the character cap, and the string ends with the nearest one")
    func newestFirstUnderTheCap() {
        let messages = (0..<30).map { "message \($0) " + String(repeating: "x", count: 190) }
        let chat = ChatWindow(messages: messages)
        let result = chat.read()
        #expect(result.characters <= 4_000)
        #expect(result.text.hasSuffix(messages[29]))
        #expect(result.text.contains("message 12 "))
        #expect(!result.text.contains("message 0 "))
        #expect(result.text.range(of: "message 28 ")!.lowerBound < result.text.range(of: "message 29 ")!.lowerBound)
    }

    @Test("an element without a position contributes no text when the text box's position is known")
    func unplacedTextIsSkipped() {
        let chat = ChatWindow(messages: ["placed one"], extra: [FakeNode("AXStaticText", text: "unplaced stray text")])
        let result = chat.read()
        #expect(result.text == "placed one")
        #expect(!result.text.contains("unplaced"))
    }

    @Test("toolbars, tab groups, menus and search fields are skipped with everything under them")
    func excludedRoles() {
        let toolbar = FakeNode("AXToolbar", frame: CGRect(x: 300, y: 5, width: 500, height: 20), [
            FakeNode("AXStaticText", text: "toolbar caption", frame: CGRect(x: 310, y: 5, width: 100, height: 10))])
        let search = FakeNode("AXSearchField", text: "search words", frame: CGRect(x: 310, y: 30, width: 100, height: 10))
        let chat = ChatWindow(messages: ["a real message"], extra: [toolbar, search])
        #expect(chat.read().text == "a real message")
        #expect(!FakeNode.reads.contains("toolbar caption"))
        #expect(!FakeNode.reads.contains("search words"))
    }

    @Test("a secure field's text is never requested")
    func secureFieldsAreNeverRead() {
        let secure = FakeNode("AXTextField", text: "hunter2", frame: CGRect(x: 310, y: 640, width: 200, height: 20), subrole: "AXSecureTextField")
        let chat = ChatWindow(messages: ["hello"], extra: [secure])
        #expect(chat.read().text == "hello")
        #expect(!FakeNode.reads.contains("hunter2"))
    }

    @Test("it goes outward only as far as needed: a container with enough text ends the climb")
    func nearestContainerEndsTheClimb() {
        let composer = FakeNode("AXTextArea", frame: CGRect(x: 0, y: 500, width: 400, height: 40))
        let long = String(repeating: "word ", count: 60)
        let near = FakeNode("AXStaticText", text: long, frame: CGRect(x: 0, y: 100, width: 400, height: 40))
        let far = FakeNode("AXStaticText", text: "outer text beyond the container", frame: CGRect(x: 0, y: 10, width: 400, height: 20))
        let inner = FakeNode("AXGroup", frame: CGRect(x: 0, y: 0, width: 400, height: 600), [near, composer])
        let window = FakeNode("AXWindow", frame: CGRect(x: 0, y: 0, width: 400, height: 700), [far, inner]); defer { withExtendedLifetime(window) {} }
        FakeNode.reads = []
        var clock = Clock()
        let result = WindowTextReader.read(from: composer, elapsedMilliseconds: { clock.read() })
        #expect(result.text == long.trimmingCharacters(in: .whitespaces))
        #expect(result.levelsAscended == 1)
        #expect(!FakeNode.reads.contains("outer text beyond the container"))
    }

    @Test("with little text in the nearest container it climbs, and stops at the window")
    func climbsToTheWindow() {
        let composer = FakeNode("AXTextArea", frame: CGRect(x: 0, y: 500, width: 400, height: 40))
        let short = FakeNode("AXStaticText", text: "short", frame: CGRect(x: 0, y: 100, width: 400, height: 40))
        let outer = FakeNode("AXStaticText", text: "outer message", frame: CGRect(x: 0, y: 10, width: 400, height: 20))
        let inner = FakeNode("AXGroup", frame: CGRect(x: 0, y: 0, width: 400, height: 600), [short, composer])
        let window = FakeNode("AXWindow", frame: CGRect(x: 0, y: 0, width: 400, height: 700), [outer, inner]); defer { withExtendedLifetime(window) {} }
        var clock = Clock()
        let result = WindowTextReader.read(from: composer, elapsedMilliseconds: { clock.read() })
        #expect(result.text == "outer message\nshort")
        #expect(result.levelsAscended == 2)
    }

    @Test("it stops at the time limit and returns what it found")
    func timeLimit() {
        let messages = (0..<20).map { "message \($0)" }
        let chat = ChatWindow(messages: messages)
        // 50 ms a read: the first reads cover the start of the climb, then the budget is gone.
        let result = chat.read(.init(), step: 50)
        #expect(result.stoppedBy == .timeLimit)
        #expect(result.nodesVisited < 8)
    }

    @Test("a repeated line is kept once, at its nearest place")
    func duplicates() {
        let chat = ChatWindow(messages: ["same", "other", "same"])
        #expect(chat.read().text == "other\nsame")
    }

    @Test("without a position for the text box, the roles still apply and order falls back to last-first")
    func noFocusFrame() {
        let composer = FakeNode("AXTextArea")
        let a = FakeNode("AXStaticText", text: "first")
        let b = FakeNode("AXStaticText", text: "second")
        let menu = FakeNode("AXMenu", text: "menu text")
        let window = FakeNode("AXWindow", [a, b, menu, composer]); defer { withExtendedLifetime(window) {} }
        var clock = Clock()
        let result = WindowTextReader.read(from: composer, elapsedMilliseconds: { clock.read() })
        #expect(result.text == "first\nsecond")
    }

    @Test("browsers are left to the field reader")
    func browsers() {
        for id in ["com.apple.Safari", "com.google.Chrome", "com.google.Chrome.canary", "company.thebrowser.Browser",
                   "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser", "org.chromium.Chromium", "com.vivaldi.Vivaldi"] {
            #expect(WindowContextPolicy.isBrowser(id), "\(id)")
        }
        for id in ["com.anthropic.claudefordesktop", "com.tinyspeck.slackmacgap", "com.apple.mail", "com.apple.TextEdit"] {
            #expect(!WindowContextPolicy.isBrowser(id), "\(id)")
        }
        #expect(!WindowContextPolicy.isBrowser(nil))
    }

    @Test("window terms follow the field's, without duplicates")
    func merging() {
        let merged = WindowContextPolicy.merged(fieldTerms: ["Priya", "pstack"], windowTerms: ["PSTACK", "Annalyse", "priya"])
        #expect(merged == ["Priya", "pstack", "Annalyse"])
        let many = (0..<60).map { "term\($0)" }
        #expect(WindowContextPolicy.merged(fieldTerms: ["a1"], windowTerms: many).count == WindowContextPolicy.maxMergedTerms)
    }
}
