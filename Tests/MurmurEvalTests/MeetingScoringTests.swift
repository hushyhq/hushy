import Foundation
import Testing

@testable import murmur_eval

@Suite("Meeting digest scoring")
struct MeetingScoringTests {
    static func item(_ id: String, owner: String? = nil, kind: String? = nil, terms: [[String]], due: [String]? = nil,
                     staleDue: [String]? = nil, final: String? = nil, quartile: Int = 1) -> MeetingGolden.Item {
        MeetingGolden.Item(id: id, owner: owner, kind: kind, terms: terms, dueTerms: due, staleDueTerms: staleDue, final: final,
                           position: Double(quartile) / 4 - 0.1, quartile: quartile, lastTenMinutes: quartile == 4)
    }

    static let meeting = MeetingGolden.Meeting(
        id: "m", title: "t", minutes: 20, style: "names",
        people: [.init(name: "Marcus", label: "Marcus"), .init(name: "Leo", label: "Leo"), .init(name: "You", label: "You")],
        words: 100, transcript: "Marcus: I'll fix the login crash.\nLeo: ok\nYou: I'll set up the tag.",
        actionItems: [
            item("a1", owner: "Marcus", terms: [["crash"], ["login"]], due: ["wednesday"], quartile: 1),
            item("a3", owner: "You", terms: [["tag"]], quartile: 2),
            item("a4", owner: "Marcus", terms: [["alert"]], due: ["tomorrow"], quartile: 4),
        ],
        superseded: [item("x1", owner: "Leo", kind: "reassigned", terms: [["alert"]], final: "a4", quartile: 4)],
        decisions: [item("d1", terms: [["19"], ["release"]], quartile: 3)],
        distractors: [item("t1", terms: [["mechanic"]])])

    @Test("owner and task both count; a wrong owner is task-only; quartiles and dues are tracked")
    func actions() {
        let score = MeetingScoring.score(
            meeting: Self.meeting, summary: "- Crash rate\n- Decided: The release moves to the 19th",
            actionItems: ["Marcus: Fix the login crash — Wednesday", "You: Set up the sync-bug tag", "Leo: Set up the Slack alert", "Leo: Take the car to the mechanic"],
            transcript: Self.meeting.transcript)
        #expect(score.actionsFound == 2)
        #expect(score.actionTasksFound == 3)
        #expect(score.predictedMatchingGold == 3)
        #expect(score.smallTalkItems == 1)
        #expect(score.decisionsFound == 1)
        #expect(score.quartileFound == [1, 1, 1, 0])
        #expect(score.duesRight == 1 && score.duesChecked == 1)
        // Leo still has the alert: the reassignment was not applied, and that item is stale.
        #expect(score.correctionsApplied == 0)
        #expect(score.staleItems == 1)
    }

    @Test("a reassignment applied: the new owner has it and nobody else does")
    func reassignment() {
        let score = MeetingScoring.score(
            meeting: Self.meeting, summary: "", actionItems: ["Marcus: Set up the Slack crash alert — tomorrow"],
            transcript: Self.meeting.transcript)
        #expect(score.correctionsApplied == 1)
        #expect(score.staleItems == 0)
    }

    @Test("owners: stated owner parsing and hallucination")
    func owners() {
        #expect(MeetingScoring.statedOwner("Priya: Send the deck") == "Priya")
        #expect(MeetingScoring.statedOwner("Priya to send the deck") == "Priya")
        #expect(MeetingScoring.statedOwner("Send the deck to Priya") == nil)
        #expect(MeetingScoring.isHallucinated(owner: "Jessica", transcript: Self.meeting.transcript))
        #expect(!MeetingScoring.isHallucinated(owner: "Marcus", transcript: Self.meeting.transcript))
        #expect(!MeetingScoring.isHallucinated(owner: "Team", transcript: Self.meeting.transcript))
    }

    @Test("plain transcript drops only known speaker labels")
    func plain() {
        #expect(Self.meeting.plainTranscript == "I'll fix the login crash. ok I'll set up the tag.")
    }
}
