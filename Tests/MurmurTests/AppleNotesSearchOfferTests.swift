import Foundation
import MurmurCore
import Testing

@testable import Murmur

/// The answer card's "Search Apple Notes?" offer: it turns Apple Notes search on through
/// `AppleNotesToggle`, and when macOS or Notes refuses the setting stays off and the card says
/// why in `AppleNotesAccessNotice`'s words. Fake scripter and a private settings store only: no
/// AppleScript, no Automation prompt, no real Notes, no standard defaults.
@MainActor
@Suite("Search Apple Notes offer", .serialized, .timeLimit(.minutes(1)))
struct AppleNotesSearchOfferTests {
    private func freshSettings() -> AppSettings {
        let name = "app.hushy.tests.notesoffer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return AppSettings(defaults: defaults, calendarAuthorization: .denied)
    }

    private func refusal(_ number: Int) -> FakeAppleNotesScripter {
        FakeAppleNotesScripter(error: .init(number: number, message: "refused"))
    }

    private func failedCard() -> AnswerCardState {
        var card = AnswerCardState(
            question: "what groceries do i need",
            phase: .failure(.init(message: "I couldn't find a grocery list in your notes, reminders or calendar.", suggestion: "Search Apple Notes?")))
        card.thread = [AskTurn(question: "earlier", answer: "an answer")]
        return card
    }

    @Test("granted turns search on and reports granted")
    func granted() {
        let settings = freshSettings()
        let toggle = AppleNotesToggle()
        let result = toggle.turnOn(using: FakeAppleNotesScripter()) { settings.searchAppleNotes = $0 }
        #expect(result == .granted)
        #expect(settings.searchAppleNotes)
        #expect(toggle.problem == nil)
    }

    @Test("a refusal leaves search off and reports why", arguments: [
        (-1743, AppleNotesAccessResult.notPermitted), (-1712, .timedOut), (-600, .notesUnavailable), (-128, .other(-128)),
    ])
    func refused(number: Int, expected: AppleNotesAccessResult) {
        let settings = freshSettings()
        let toggle = AppleNotesToggle()
        let result = toggle.turnOn(using: refusal(number)) { settings.searchAppleNotes = $0 }
        #expect(result == expected)
        #expect(!settings.searchAppleNotes)
        #expect(toggle.problem == expected)
    }

    @Test("the refused card keeps the question and thread and states the refusal in the notice's words")
    func refusedCard() {
        let card = failedCard()
        for result in [AppleNotesAccessResult.notPermitted, .timedOut, .notesUnavailable, .other(-128)] {
            let shown = card.refusedNotesAccess(result)
            #expect(shown.question == card.question)
            #expect(shown.thread == card.thread)
            guard case .failure(let failure) = shown.phase else {
                Issue.record("expected the failure phase")
                continue
            }
            #expect(failure.message == result.message)
            #expect(failure.suggestion == "Try again")
        }
    }

    @Test("only a macOS refusal says it was blocked")
    func blockedWording() {
        func message(_ result: AppleNotesAccessResult) -> String {
            guard case .failure(let failure) = failedCard().refusedNotesAccess(result).phase else { return "" }
            return failure.message
        }
        #expect(message(.notPermitted).contains("macOS blocked it"))
        #expect(!message(.timedOut).contains("blocked"))
        #expect(!message(.notesUnavailable).contains("blocked"))
    }

    @Test("trying again after allowing it in System Settings turns search on")
    func tryAgain() {
        let settings = freshSettings()
        let toggle = AppleNotesToggle()
        let scripter = refusal(-1743)
        toggle.turnOn(using: scripter) { settings.searchAppleNotes = $0 }
        #expect(!settings.searchAppleNotes)
        scripter.error = nil
        let result = toggle.turnOn(using: scripter) { settings.searchAppleNotes = $0 }
        #expect(result.isGranted)
        #expect(settings.searchAppleNotes)
        #expect(scripter.sources.count == 2)
    }
}
