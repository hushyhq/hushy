import Foundation
import Testing
@testable import MurmurCore

@Suite("Style habits are offered on evidence")
struct StyleHabitEvidenceTests {
    private let start = Date(timeIntervalSince1970: 1_900_000_000)
    private let day: TimeInterval = 86_400
    private let slack = "com.tinyspeck.slackmacgap"
    private let teams = "com.microsoft.teams2"
    private let mail = "com.apple.mail"

    private func greetingDropped(_ id: Int64, _ app: String, at offset: TimeInterval) -> CorrectionCapture {
        CorrectionCapture(dictationID: id, appBundleID: app, capturedAt: start.addingTimeInterval(offset),
                          events: [CorrectionEvent(kind: .formatting, before: StyleEditSignals.greetingMarker, after: "")])
    }

    private func fold(_ captures: [CorrectionCapture], existing: [LearnedItem] = [],
                      kept: @escaping (String) -> [EvidenceCell] = { _ in [] }) -> [LearnedItem] {
        var items = existing
        for capture in captures {
            for item in Learner.observe(capture, existing: items, knownTerms: [], styleKept: kept) {
                items.removeAll { $0.identity == item.identity }
                items.append(item)
            }
        }
        return items
    }

    private func item(_ items: [LearnedItem], _ app: String) -> LearnedItem? {
        items.first { $0.appBundleID == app && $0.key == "format:noGreeting" }
    }

    @Test func threeEditsAreOfferedTwoAreNot() {
        let two = fold([greetingDropped(1, slack, at: 0), greetingDropped(2, slack, at: day)])
        #expect(item(two, slack)?.isReadySuggestion == false)
        let three = fold([greetingDropped(1, slack, at: 0), greetingDropped(2, slack, at: day), greetingDropped(3, slack, at: 2 * day)])
        let offered = item(three, slack)
        #expect(offered?.isReadySuggestion == true)
        #expect(offered?.status == .candidate)
        #expect(PreferenceHints.from(three, bundleID: slack).isEmpty)
    }

    @Test func oldEditsFade() {
        let spread = fold([greetingDropped(1, slack, at: 0), greetingDropped(2, slack, at: 90 * day), greetingDropped(3, slack, at: 91 * day)])
        #expect(item(spread, slack)?.isReadySuggestion == false)
    }

    @Test func weeklyEditsAreOffered() {
        let weekly = fold([greetingDropped(1, slack, at: 0), greetingDropped(2, slack, at: 7 * day), greetingDropped(3, slack, at: 14 * day)])
        #expect(item(weekly, slack)?.isReadySuggestion == true)
    }

    @Test func aLaterEditNeverWithdrawsAnOffer() {
        let ready = (1...3).map { greetingDropped(Int64($0), slack, at: Double($0) * 3_600) }
        let items = fold(ready + [greetingDropped(4, slack, at: 60 * day)])
        #expect(item(items, slack)?.isReadySuggestion == true)
    }

    @Test func whatAppsOfAnotherKindLeaveAloneDoesNotHoldAnAppBack() {
        let mailKeepsGreetings: (String) -> [EvidenceCell] = { _ in [EvidenceCell(app: self.mail, kept: 40, updatedAt: self.start)] }
        let items = fold((1...3).map { greetingDropped(Int64($0), slack, at: Double($0) * 3_600) }, kept: mailKeepsGreetings)
        #expect(item(items, slack)?.isReadySuggestion == true)
        let teamsKeepsGreetings: (String) -> [EvidenceCell] = { _ in [EvidenceCell(app: self.teams, kept: 40, updatedAt: self.start)] }
        let held = fold((1...3).map { greetingDropped(Int64($0), slack, at: Double($0) * 3_600) }, kept: teamsKeepsGreetings)
        #expect(item(held, slack)?.isReadySuggestion == false)
    }

    @Test func aHabitTheyUsuallyLeaveIsNotOffered() {
        let kept: (String) -> [EvidenceCell] = { key in
            key == "format:noGreeting" ? [EvidenceCell(app: self.slack, kept: 4, updatedAt: self.start)] : []
        }
        let items = fold((1...3).map { greetingDropped(Int64($0), slack, at: Double($0) * 3_600) }, kept: kept)
        #expect(item(items, slack)?.isReadySuggestion == false)
    }

    @Test func anAppOfTheSameKindBringsTheOfferOneEditNearer() {
        let slackThree = (1...3).map { greetingDropped(Int64($0), slack, at: Double($0) * 3_600) }
        let withTeams = fold(slackThree + [greetingDropped(10, teams, at: day), greetingDropped(11, teams, at: day + 3_600)])
        #expect(item(withTeams, teams)?.isReadySuggestion == true)
        let withMail = fold(slackThree + [greetingDropped(20, mail, at: day), greetingDropped(21, mail, at: day + 3_600)])
        #expect(item(withMail, mail)?.isReadySuggestion == false)
    }

    @Test func otherAppsAloneNeverMakeTheOffer() {
        let slackMany = (1...12).map { greetingDropped(Int64($0), slack, at: Double($0) * 3_600) }
        let items = fold(slackMany + [greetingDropped(30, teams, at: day)])
        #expect(item(items, teams)?.isReadySuggestion == false)
    }

    @Test func aDismissalInAnotherAppCountsAgainst() {
        let own = EvidenceCell(app: teams, edits: 3, updatedAt: start)
        let plain = StyleHabitEvidence.probability(app: teams, cells: [own, EvidenceCell(app: slack, edits: 3, updatedAt: start)])
        let dismissed = Learner.styleCells(
            key: "format:noGreeting",
            items: [LearnedItem(kind: .styleSignal, key: "format:noGreeting", value: "format:noGreeting", appBundleID: slack, status: .forgotten)],
            kept: [], now: start, halfLife: LearningPolicy.standard.styleHalfLife)
        let against = StyleHabitEvidence.probability(app: teams, cells: [own] + dismissed)
        #expect(StyleHabitEvidence.probability(app: teams, cells: [own]) >= LearningPolicy.standard.styleOfferProbability)
        #expect(against < plain)
        #expect(against < LearningPolicy.standard.styleOfferProbability)
    }

    @Test func theEarlierRuleStillHoldsWithEvidenceOff() {
        var items: [LearnedItem] = []
        for capture in [greetingDropped(1, slack, at: 0), greetingDropped(2, slack, at: day), greetingDropped(3, slack, at: 2 * day)] {
            items = Learner.observe(capture, existing: items, knownTerms: [], policy: .editsOnly,
                                    styleKept: { _ in [EvidenceCell(app: self.slack, kept: 9, updatedAt: self.start)] })
        }
        #expect(item(items, slack)?.isReadySuggestion == true)
    }

    @Test func whatEachHabitLooksForInHushysText() {
        #expect(StyleHabitEvidence.shows("format:noGreeting", in: "Hi Sam, the build is green."))
        #expect(!StyleHabitEvidence.shows("format:noGreeting", in: "The build is green, hi to the team."))
        #expect(StyleHabitEvidence.shows("format:droppedTerminalPeriod", in: "The build is green."))
        #expect(!StyleHabitEvidence.shows("format:droppedTerminalPeriod", in: "Is the build green?"))
        #expect(StyleHabitEvidence.shows("format:noExclamation", in: "The build is green!"))
        #expect(StyleHabitEvidence.shows("format:lowercased", in: "The build is green"))
        #expect(!StyleHabitEvidence.shows("format:lowercased", in: "the build is green"))
        #expect(StyleHabitEvidence.shows("format:signOff:,", in: "See you soon. Thanks!"))
        #expect(!StyleHabitEvidence.shows("format:signOff:,", in: "See you soon. Thanks,"))
        #expect(!StyleHabitEvidence.shows("keep:actually", in: "Actually the build is green."))
    }

    @Test func historyRowsLeftAloneHoldAnOfferBack() throws {
        let store = try Store()
        for index in 0..<4 {
            let row = try store.save(Dictation(createdAt: start.addingTimeInterval(Double(index) * 3_600), rawText: "",
                                               text: "The release notes are ready for review.", appBundleID: slack, durationSeconds: 1))
            try store.setEditState(.kept, forDictation: try #require(row.id))
        }
        let captures = (1...3).map { index in
            CorrectionCapture(dictationID: Int64(100 + index), appBundleID: slack, capturedAt: start.addingTimeInterval(day + Double(index) * 3_600),
                              events: [CorrectionEvent(kind: .formatting, before: "ready.", after: "ready")])
        }
        for capture in captures { try store.recordCorrections(capture) }
        let held = try #require(try store.learnedItems().first { $0.key == "format:droppedTerminalPeriod" })
        #expect(held.status == .candidate)
        #expect(!held.isReadySuggestion)

        let empty = try Store()
        for capture in captures { try empty.recordCorrections(capture) }
        let offered = try #require(try empty.learnedItems().first { $0.key == "format:droppedTerminalPeriod" })
        #expect(offered.isReadySuggestion)
    }
}
