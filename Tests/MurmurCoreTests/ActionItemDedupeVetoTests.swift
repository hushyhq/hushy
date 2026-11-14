import Foundation
import Testing
@testable import MurmurCore

/// Meeting action items are merged across chunk overlap by word overlap. Word overlap alone merged
/// different tasks that share most words and silently lost one (algorithms audit 2026-10-26, B9: 2 of 8
/// different pairs merged). Two items are never merged when they differ in a name, a number, a date or a
/// time, or end on different things. Invented text only.
@Suite("Action item duplicate veto")
struct ActionItemDedupeVetoTests {
    /// Different tasks that share most of their words.
    private static let differentPairs: [(String, String)] = [
        ("Call the vendor about pricing", "Call the vendor about shipping"),
        ("Pay the invoice from Acme", "Pay the invoice from Globex"),
        ("Order 10 laptops for the new team", "Order 12 laptops for the new team"),
        ("Order two laptops for the new team", "Order three laptops for the new team"),
        ("Email Priya the budget draft", "Email Marcus the budget draft"),
        ("Schedule the review for Monday", "Schedule the review for Tuesday"),
        ("Book the room for 3 pm", "Book the room for 3 am"),
        ("Write the Q3 report for the board", "Write the Q4 report for the board"),
    ]

    /// The same task said twice (the overlap between two chunks reads it again).
    private static let samePairs: [(String, String)] = [
        ("Send the onboarding mockups to Marcus", "Send onboarding mockups to Marcus"),
        ("Inventory the legacy cron jobs", "Inventory the legacy cron jobs."),
        ("Write the test plan for the 19th release", "Write test plan for the 19th release"),
        ("Draft the apology email to Dana", "Draft the apology email to Dana today"),
        ("Book the room for 3 pm", "Book the room for 3 pm Friday"),
    ]

    @Test("different tasks that share most words are not the same item", arguments: differentPairs)
    func differentTasksAreNotSimilar(_ pair: (String, String)) {
        #expect(!NoteDigestMerge.similar(pair.0, pair.1))
        #expect(!NoteDigestMerge.similar(pair.1, pair.0))
    }

    @Test("the same task said twice still merges", arguments: samePairs)
    func sameTaskStillSimilar(_ pair: (String, String)) {
        #expect(NoteDigestMerge.similar(pair.0, pair.1))
        #expect(NoteDigestMerge.similar(pair.1, pair.0))
    }

    @Test("a later part keeps both different tasks instead of replacing the earlier one")
    func candidatesKeepDifferentTasks() {
        for (first, second) in Self.differentPairs {
            let parts = [
                MeetingPartNotes(decisions: [], actionItems: [DigestActionItem(owner: "Dana", task: first, due: "")], changes: [], keyPoints: []),
                MeetingPartNotes(decisions: [], actionItems: [DigestActionItem(owner: "Dana", task: second, due: "")], changes: [], keyPoints: []),
            ]
            #expect(NoteDigestMerge.candidates(parts).map(\.item.task) == [first, second], "\(first) / \(second)")
            #expect(NoteDigestMerge.dedupedAcrossOverlap(parts)[1].actionItems.map(\.task) == [second], "\(first) / \(second)")
            #expect(NoteDigestMerge.uniqueItems(parts.flatMap(\.actionItems)).map(\.task) == [first, second], "\(first) / \(second)")
        }
    }

    @Test("a later part still replaces the earlier version of the same task")
    func candidatesStillReplaceSameTask() {
        for (first, second) in Self.samePairs {
            let parts = [
                MeetingPartNotes(decisions: [], actionItems: [DigestActionItem(owner: "Dana", task: first, due: "")], changes: [], keyPoints: []),
                MeetingPartNotes(decisions: [], actionItems: [DigestActionItem(owner: "Leo", task: second, due: "Friday")], changes: [], keyPoints: []),
            ]
            #expect(NoteDigestMerge.candidates(parts).map(\.item.task) == [second], "\(first) / \(second)")
        }
    }

    @Test("a drop needs a really similar item: a different name or number is not evidence")
    func dropEvidenceRespectsTheVeto() {
        let parts = [
            MeetingPartNotes(decisions: [], actionItems: [
                DigestActionItem(owner: "Omar", task: "Pay the invoice from Acme", due: ""),
                DigestActionItem(owner: "Omar", task: "Pay the invoice from Globex", due: ""),
            ], changes: [], keyPoints: []),
        ]
        let merge = MeetingMerge(title: "t", keyPoints: [], decisions: [], dropItems: [1], updates: [])
        #expect(NoteDigestMerge.apply(merge, to: parts).actionItems.count == 2)
    }

    @Test("a name that is only title-cased in one line is not a different name")
    func titleCaseIsNotAName() {
        #expect(NoteDigestMerge.similar("Send The Deck To Legal", "Send the deck to legal"))
    }

    @Test("a possessive is the same name")
    func possessiveIsTheSameName() {
        #expect(NoteDigestMerge.similar("Review Priya's budget draft", "Review the budget draft from Priya"))
    }
}
