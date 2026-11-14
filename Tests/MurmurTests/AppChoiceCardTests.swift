import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// "Did you mean…": the card that offers the closest installed apps when none was a sure match.
@Suite("Did you mean… card")
@MainActor
struct AppChoiceCardTests {
    private func choice(_ apps: [String] = ["Slack", "Flush", "Notion"]) -> ActionConfirmationCardState {
        ActionConfirmationCardState(choosingAmong: apps, heard: "flask", sourceText: "open flask")
    }

    @Test("one open-app row per candidate, in the order given, naming the app as installed")
    func rows() {
        let card = choice()
        #expect(card.isChoice)
        #expect(card.rows.map(\.action.appName) == ["Slack", "Flush", "Notion"])
        #expect(card.rows.allSatisfy { $0.action.kind == .openLink && $0.status == .pending })
        #expect(card.rows.map(\.action.title) == ["Open Slack", "Open Flush", "Open Notion"])
    }

    @Test("never more rows than the matcher's limit")
    func capped() {
        let card = choice(["A1", "B2", "C3", "D4", "E5"])
        #expect(card.rows.count == AppNameMatcher.maxSuggestions)
    }

    @Test("the first row says what was heard; with several rows the others stay plain")
    func hints() {
        let card = choice()
        #expect(card.rows[0].hint == "Heard \u{201C}flask\u{201D}")
        #expect(card.rows.dropFirst().allSatisfy { $0.hint == nil })
    }

    @Test("a single candidate's line says it is the closest match, not a sure one")
    func singleHint() {
        let card = choice(["Slack"])
        #expect(card.rows[0].hint == "Heard \u{201C}flask\u{201D} \u{00B7} closest match")
    }

    @Test("an ordinary card is not a choice and Return still confirms every pending row")
    func ordinaryCard() {
        let actions = ["Slack", "Notion"].map {
            ProposedAction(kind: .openLink, title: "Open \($0)", appName: $0, sourceText: "x")
        }
        let card = ActionConfirmationCardState(actions: actions)
        #expect(!card.isChoice)
        #expect(card.rowsToConfirmWithReturn.count == 2)
    }

    @Test("Return on a choice card opens only the closest row")
    func returnOpensFirst() {
        let card = choice()
        #expect(card.rowsToConfirmWithReturn.map(\.action.appName) == ["Slack"])
    }

    @Test("Return skips a row that is no longer pending")
    func returnSkipsResolved() {
        var card = choice()
        card.rows[0].status = .cancelled
        #expect(card.rowsToConfirmWithReturn.map(\.action.appName) == ["Flush"])
    }

    @Test("opening one alternative cancels the others, so the card closes")
    func settleChoice() {
        var card = choice()
        let picked = card.rows[1]
        card.rows[1].status = .succeeded(undoToken: nil)
        card.settleChoice(afterOpening: picked.id)
        #expect(card.rows[0].status == .cancelled)
        #expect(card.rows[2].status == .cancelled)
        #expect(card.allResolved)
    }

    @Test("settling does nothing on an ordinary card")
    func settleOrdinary() {
        let actions = ["Slack", "Notion"].map {
            ProposedAction(kind: .openLink, title: "Open \($0)", appName: $0, sourceText: "x")
        }
        var card = ActionConfirmationCardState(actions: actions)
        card.rows[0].status = .succeeded(undoToken: nil)
        card.settleChoice(afterOpening: card.rows[0].id)
        #expect(card.rows[1].status == .pending)
    }

    @Test("the controller turns closest-apps into a choice card, and nothing else")
    func controllerBuildsChoice() {
        let action = ProposedAction(kind: .openLink, title: "Open flask", appName: "flask", sourceText: "open flask")
        let built = VoiceActionsController.choiceCard(
            for: .closestApps(heard: "flask", apps: ["Slack", "Flush"]), action: action)
        #expect(built?.rows.map(\.action.appName) == ["Slack", "Flush"])
        #expect(built?.rows.first?.action.sourceText == "open flask")
        #expect(VoiceActionsController.choiceCard(for: .notFound("flask"), action: action) == nil)
        #expect(VoiceActionsController.choiceCard(for: .closestApps(heard: "x", apps: []), action: action) == nil)
    }

    @Test("the plain-text message names what was heard and the closest apps")
    func message() {
        let text = VoiceActionsController.message(for: .closestApps(heard: "flask", apps: ["Slack", "Flush"]))
        #expect(text == "Couldn't find \"flask\". Closest: Slack, Flush")
    }

    @Test("the footer of a choice never says \"all\": Return opens the closest row only")
    func footerWording() {
        let choice = ActionCardFooter.wording(count: 3, isChoice: true)
        #expect(choice == .init(title: "Pick one", confirmText: "Open first", cancelText: "Dismiss all"))
        let ordinary = ActionCardFooter.wording(count: 3, isChoice: false)
        #expect(ordinary == .init(title: "3 actions", confirmText: "Confirm all", cancelText: "Dismiss all"))
    }

    @Test("VoiceOver reads a choice as alternatives, not as actions that will all run")
    func accessibility() {
        #expect(ActionConfirmationCard.accessibilityText(count: 3, isChoice: true) == "3 close matches to choose from")
        #expect(ActionConfirmationCard.accessibilityText(count: 1, isChoice: true) == "1 close match to confirm")
        let pill = PillModel()
        pill.state = .actionConfirm(choice())
        #expect(pill.accessibilityLabel == "3 close matches to choose from")
        pill.state = .actionConfirm(choice(["Wendy"]))
        #expect(pill.accessibilityLabel == "1 close match to confirm")
    }
}
