import Foundation
import Testing
@testable import MurmurCore

@Suite("Quick Look navigation")
struct QuickLookNavigationTests {
    private func dictation(_ id: Int64) -> TimelineEntry {
        .dictation(Dictation(id: id, createdAt: Date(), rawText: "d\(id)", text: "d\(id)", durationSeconds: 1, status: .inserted))
    }

    private func note(_ id: Int64) -> TimelineEntry {
        .note(Note(id: id, title: "n", status: .ready))
    }

    private func action(_ id: Int64) -> TimelineEntry {
        .action(ActionRecord(id: id, kind: .createEvent, title: "t", sourceText: ""))
    }

    /// Feed order (top to bottom): [d1, n1, d2] [a1] [d3, d4]
    private var groups: [TimelineGroup] {
        [
            TimelineGroup(day: Date(), appBundleID: nil, appName: "A", entries: [dictation(1), note(1), dictation(2)]),
            TimelineGroup(day: Date(), appBundleID: nil, appName: "Hushy", entries: [action(1)]),
            TimelineGroup(day: Date(), appBundleID: nil, appName: "B", entries: [dictation(3), dictation(4)]),
        ]
    }

    @Test("dictation order follows the feed, skipping notes and actions")
    func order() {
        #expect(QuickLookNavigation.dictationIDs(in: groups) == [1, 2, 3, 4])
    }

    @Test("next and previous step across groups")
    func stepping() {
        #expect(QuickLookNavigation.neighbor(of: 1, in: groups, direction: .next) == 2)
        #expect(QuickLookNavigation.neighbor(of: 2, in: groups, direction: .next) == 3)
        #expect(QuickLookNavigation.neighbor(of: 3, in: groups, direction: .previous) == 2)
    }

    @Test("stepping stops at either end")
    func ends() {
        #expect(QuickLookNavigation.neighbor(of: 4, in: groups, direction: .next) == nil)
        #expect(QuickLookNavigation.neighbor(of: 1, in: groups, direction: .previous) == nil)
    }

    @Test("a dictation no longer in the feed steps from the nearest end")
    func missingCurrent() {
        #expect(QuickLookNavigation.neighbor(of: 99, in: groups, direction: .next) == 1)
        #expect(QuickLookNavigation.neighbor(of: nil, in: groups, direction: .previous) == 4)
        #expect(QuickLookNavigation.neighbor(of: 1, inOrder: [], direction: .next) == nil)
    }
}

@Suite("Chat Markdown blocks")
struct ChatMarkdownTests {
    @Test("paragraphs, headings, lists and code split into blocks")
    func blocks() {
        let text = """
            ## Today
            You dictated **3** things.

            - Deck due *Friday*
              - ask Priya
            2. Standup at 10

            ```
            let x = 1
            ```
            """
        #expect(ChatMarkdown.blocks(from: text) == [
            .heading("Today"),
            .paragraph("You dictated **3** things."),
            .listItem(marker: "•", text: "Deck due *Friday*", depth: 0),
            .listItem(marker: "•", text: "ask Priya", depth: 1),
            .listItem(marker: "2.", text: "Standup at 10", depth: 0),
            .code("let x = 1"),
        ])
    }

    @Test("plain text is one paragraph; an unclosed fence still renders as code")
    func edgeCases() {
        #expect(ChatMarkdown.blocks(from: "Just one line.") == [.paragraph("Just one line.")])
        #expect(ChatMarkdown.blocks(from: "```\nhalf") == [.code("half")])
        #expect(ChatMarkdown.blocks(from: "#hashtag not a heading") == [.paragraph("#hashtag not a heading")])
        #expect(ChatMarkdown.blocks(from: "").isEmpty)
    }
}
