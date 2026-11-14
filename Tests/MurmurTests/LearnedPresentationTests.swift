import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The words the learned surfaces read. Raw keys (`format:lowercased`) must never reach the UI.
@Suite("Learned presentation")
struct LearnedPresentationTests {
    private func term(_ value: String, heard: [String] = [], observations: Int = 2, sources: [Int64] = [],
                      status: LearnedItem.Status = .candidate, confirmed: Bool = false) -> LearnedItem {
        LearnedItem(id: 1, kind: .term, key: value.lowercased(), value: value, heardAs: heard, status: status,
                    observations: observations, confirmed: confirmed, confidence: 1, sourceDictationIDs: sources)
    }

    @Test("counts read as words")
    func times() {
        #expect(LearnedPresentation.times(1) == "once")
        #expect(LearnedPresentation.times(2) == "twice")
        #expect(LearnedPresentation.times(4) == "4 times")
    }

    @Test("the suggestion names what was heard, the fix and the count")
    func suggestionCopy() {
        let priya = term("Priya", heard: ["Preeya", "Pria"])
        #expect(LearnedPresentation.correctionClause(priya) == "You corrected “Pria” → “Priya” twice.")
        #expect(LearnedPresentation.suggestionSentence(priya)
                == "You corrected “Pria” to “Priya” twice. Add Priya to your dictionary?")
        #expect(LearnedPresentation.addedLine(priya) == "Added Priya to your dictionary")
        #expect(LearnedPresentation.dismissedLine(priya) == "Won't suggest Priya again")
    }

    @Test("a hearing that only differs in case isn't shown as a mishearing")
    func caseOnlyHearing() {
        let item = term("Ada", heard: ["ada"], observations: 3)
        #expect(LearnedPresentation.heardAs(item) == nil)
        #expect(LearnedPresentation.correctionClause(item) == "You corrected “Ada” 3 times.")
    }

    @Test("provenance: heard as, how it got here, and the source apps (distinct, newest first)")
    func provenance() {
        let names: [Int64: String] = [1: "Notes", 2: "Slack", 3: "Notes"]
        let suggestion = term("Priya", heard: ["Pria"], sources: [1, 2, 3])
        #expect(LearnedPresentation.provenance(suggestion, appNames: names) == "heard as “Pria” · fixed twice · Notes, Slack")
        let learned = term("Kubernetes", heard: ["cooper net ease"], sources: [2], status: .active)
        #expect(LearnedPresentation.provenance(learned, appNames: names) == "heard as “cooper net ease” · learned after 2 fixes · Slack")
        let added = term("Grafana", observations: 1, sources: [99], status: .active, confirmed: true)
        #expect(LearnedPresentation.provenance(added, appNames: names) == "added by you")
    }

    @Test("style signals become sentences; unknown keys are not shown")
    func styleSentences() {
        func signal(_ key: String) -> LearnedItem {
            LearnedItem(kind: .styleSignal, key: key, value: key, appBundleID: "com.tinyspeck.slackmacgap", status: .active)
        }
        #expect(LearnedPresentation.styleSentence(signal("format:lowercased"), appName: "Slack") == "In Slack you usually write in lowercase")
        #expect(LearnedPresentation.styleSentence(signal("format:droppedTerminalPeriod"), appName: "Slack") == "In Slack you leave off the final period")
        #expect(LearnedPresentation.styleSentence(signal("keep:actually"), appName: "Notes") == "In Notes you keep “actually”")
        #expect(LearnedPresentation.styleSentence(signal("drop:like"), appName: "Notes") == "In Notes you delete “like”")
        #expect(LearnedPresentation.styleSentence(signal("format:somethingNew"), appName: "Notes") == nil)
        #expect(LearnedPresentation.styleSentence(term("Priya"), appName: "Notes") == nil)
    }

    @Test("the exclusion shortlist is recent apps, minus Hushy and apps already excluded")
    func exclusionCandidates() {
        let dictations = [
            Dictation(rawText: "a", text: "a", appBundleID: "com.tinyspeck.slackmacgap", appName: "Slack", durationSeconds: 1),
            Dictation(rawText: "b", text: "b", appBundleID: Insights.ownBundleID, appName: "Hushy", durationSeconds: 1),
            Dictation(rawText: "c", text: "c", appBundleID: "com.apple.Notes", appName: "Notes", durationSeconds: 1),
            Dictation(rawText: "d", text: "d", appBundleID: "com.tinyspeck.slackmacgap", appName: "Slack", durationSeconds: 1),
            Dictation(rawText: "e", text: "e", appBundleID: "com.apple.MobileSMS", appName: "Messages", durationSeconds: 1),
            Dictation(rawText: "f", text: "f", appBundleID: nil, appName: nil, durationSeconds: 1),
        ]
        let choices = LearnedPresentation.exclusionCandidates(dictations: dictations, excluded: ["com.apple.MobileSMS"])
        #expect(choices.map(\.name) == ["Slack", "Notes"])
    }
}
