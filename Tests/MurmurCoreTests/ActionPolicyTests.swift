import Foundation
import Testing
@testable import MurmurCore

/// The one trust policy: which actions act first with undo, which keep the card, what may
/// press ⏎, and how "Ask before doing" bends it (founder decisions, 2026-09-28).
@Suite("ActionPolicy")
struct ActionPolicyTests {
    typealias Class = ActionPolicy.ActionClass

    @Test("safe local actions act first when the parse is certain", arguments: [
        Class.reminder, .timer, .ownEvent, .note, .addToList, .openApp, .openLink, .webSearch, .aiHandoff,
    ])
    func tierOneActsFirst(actionClass: Class) {
        #expect(ActionPolicy.tier(for: actionClass) == .actFirst)
    }

    @Test("anything that reaches people, deletes, runs automation or goes through the agent keeps the card", arguments: [
        Class.draftEmail, .draftMessage, .post, .invite, .deleteOrOverwrite, .connected, .shortcut,
    ])
    func tierTwoConfirms(actionClass: Class) {
        #expect(ActionPolicy.tier(for: actionClass) == .confirmFirst)
    }

    @Test("an uncertain parse puts a Tier-1 action on the card")
    func uncertainFallsToCard() {
        #expect(ActionPolicy.tier(for: .reminder, confidence: .uncertain("vague date")) == .confirmFirst)
        #expect(ActionPolicy.tier(for: .openLink, confidence: .uncertain("x")) == .confirmFirst)
    }

    @Test("Ask before doing: Always puts every action on the card, even certain Tier-1 ones")
    func alwaysAsks() {
        for actionClass in ActionPolicy.tierOne {
            #expect(ActionPolicy.tier(for: actionClass, setting: .always) == .confirmFirst)
        }
    }

    @Test("Ask before doing: Never skips the card for what Hushy does itself, but not for the agent or a Shortcut")
    func neverStillGuardsAgent() {
        #expect(ActionPolicy.tier(for: .reminder, confidence: .uncertain("x"), setting: .never) == .actFirst)
        #expect(ActionPolicy.tier(for: .connected, setting: .never) == .confirmFirst)
        #expect(ActionPolicy.tier(for: .shortcut, setting: .never) == .confirmFirst)
    }

    @Test("a Shortcut gets the card under every setting and every confidence")
    func shortcutAlwaysConfirms() {
        for setting in ActionPolicy.AskBeforeDoing.allCases {
            #expect(ActionPolicy.tier(for: .shortcut, setting: setting) == .confirmFirst)
            #expect(ActionPolicy.tier(for: .shortcut, confidence: .certain, setting: setting) == .confirmFirst)
            #expect(ActionPolicy.tier(for: .shortcut, confidence: .uncertain("x"), setting: setting) == .confirmFirst)
        }
        #expect(ActionPolicy.alwaysConfirm.contains(.shortcut))
    }

    @Test("read-only answers never get a card under any setting")
    func readOnlyNeverCards() {
        for setting in ActionPolicy.AskBeforeDoing.allCases {
            #expect(ActionPolicy.tier(for: .askOwn, setting: setting) == .actFirst)
            #expect(ActionPolicy.tier(for: .summarizeScreen, setting: setting) == .actFirst)
        }
    }

    // MARK: The submit rule

    @Test("lookups submit by themselves", arguments: [Class.openLink, .webSearch, .openApp])
    func lookupsAutoSubmit(actionClass: Class) {
        #expect(ActionPolicy.submit(for: actionClass) == .autoSubmit)
        #expect(ActionPolicy.mayPressReturn(for: actionClass))
    }

    @Test("AI hand-offs stay fill-only at the class level until a service is verified")
    func aiHandoffClassSubmit() {
        #expect(ActionPolicy.submit(for: .aiHandoff) == .draftOnly)
        #expect(!ActionPolicy.mayPressReturn(for: .aiHandoff))
    }

    @Test("anything that sends to people stays a draft, never ⏎", arguments: [
        Class.draftEmail, .draftMessage, .post, .invite, .connected,
    ])
    func peopleStayDrafts(actionClass: Class) {
        #expect(ActionPolicy.submit(for: actionClass) == .draftOnly)
        #expect(!ActionPolicy.mayPressReturn(for: actionClass))
    }

    @Test("dictation and on-device creates never press ⏎")
    func dictationNeverSubmits() {
        for actionClass in [Class.dictation, .reminder, .ownEvent, .note, .askOwn, .summarizeScreen, .shortcut] {
            #expect(ActionPolicy.submit(for: actionClass) == .never)
        }
    }

    @Test("the no-send rule is independent of the setting: Never still never sends")
    func neverKeepsNoSend() {
        #expect(ActionPolicy.submit(for: .draftMessage) == .draftOnly)
        #expect(ActionPolicy.tier(for: .draftMessage, setting: .never) == .actFirst)
        // Acting first on a draft means filling it in; `submit` says ⏎ is still withheld.
        #expect(!ActionPolicy.mayPressReturn(for: .draftMessage))
    }

    // MARK: Classifying proposed actions

    @Test("a reminder with a list is add-to-list; an AI link is a hand-off; a bare open is an app")
    func classifies() {
        #expect(ActionPolicy.actionClass(of: ProposedAction(kind: .createReminder, title: "milk", sourceText: "")) == .reminder)
        #expect(ActionPolicy.actionClass(of: ProposedAction(kind: .createReminder, title: "milk", listName: "Groceries", sourceText: "")) == .addToList)
        #expect(ActionPolicy.actionClass(of: ProposedAction(kind: .createEvent, title: "Dentist", sourceText: "")) == .ownEvent)
        #expect(ActionPolicy.actionClass(of: ProposedAction(kind: .runShortcut, title: "Focus", sourceText: "")) == .shortcut)
        #expect(ActionPolicy.actionClass(of: ProposedAction(kind: .openLink, title: "Slack", sourceText: "")) == .openApp)
        let claude = AIHandoffLink.build(service: .claude, question: "why is the sky blue")!.url.absoluteString
        #expect(ActionPolicy.actionClass(of: ProposedAction(kind: .openLink, title: "Ask Claude", url: claude, sourceText: "")) == .aiHandoff)
        #expect(ActionPolicy.actionClass(of: ProposedAction(kind: .openLink, title: "Open GitHub", url: "https://github.com/a/b", sourceText: "")) == .openLink)
    }

    // MARK: Dispatch

    @Test("one certain reminder acts now; a Shortcut, an uncertain parse, Always, or two actions go on the card")
    func dispatch() {
        let reminder = ProposedAction(kind: .createReminder, title: "Call Dana", sourceText: "remind me to call dana")
        #expect(ActionDispatch.plan([reminder], utterance: "remind me to call dana", setting: .risky) == .actNow(reminder))
        #expect(ActionDispatch.plan([reminder], utterance: "remind me to call dana", setting: .always) == .card([reminder]))
        let shortcut = ProposedAction(kind: .runShortcut, title: "Focus", shortcutName: "Focus", sourceText: "run focus")
        #expect(ActionDispatch.plan([shortcut], utterance: "run focus", setting: .risky) == .card([shortcut]))
        #expect(ActionDispatch.plan([shortcut], utterance: "run focus", setting: .never) == .card([shortcut]))
        #expect(ActionDispatch.plan([shortcut], utterance: "run focus", setting: .always) == .card([shortcut]))
        let undated = ProposedAction(kind: .createEvent, title: "Dentist", sourceText: "dentist")
        #expect(ActionDispatch.plan([undated], utterance: "dentist", setting: .risky) == .card([undated]))
        #expect(ActionDispatch.plan([reminder, reminder], utterance: "x", setting: .risky) == .card([reminder, reminder]))
        #expect(ActionDispatch.plan([], utterance: "x", setting: .never) == .card([]))
    }

    @Test("an event with no start time goes on the card under every setting, so the card can ask for the time")
    func undatedEventAlwaysCards() {
        let undated = ProposedAction(kind: .createEvent, title: "Dentist", sourceText: "dentist")
        for setting in ActionPolicy.AskBeforeDoing.allCases {
            #expect(ActionDispatch.plan([undated], utterance: "add dentist", setting: setting) == .card([undated]))
        }
        let dated = ProposedAction(kind: .createEvent, title: "Dentist", start: Date(), end: Date().addingTimeInterval(1800), sourceText: "dentist")
        #expect(ActionDispatch.plan([dated], utterance: "add dentist", setting: .never) == .actNow(dated))
    }

    @Test("the done chip's line names what happened")
    func doneTitles() {
        #expect(ActionDispatch.doneTitle(for: ProposedAction(kind: .createReminder, title: "Call Dana", sourceText: "")) == "Added: Call Dana")
        #expect(ActionDispatch.doneTitle(for: ProposedAction(kind: .openLink, title: "Open Gmail", url: "https://mail.google.com/", sourceText: "")) == "Opened: Gmail")
        let claude = AIHandoffLink.build(service: .claude, question: "x")!.url.absoluteString
        #expect(ActionDispatch.doneTitle(for: ProposedAction(kind: .openLink, title: "Ask Claude", url: claude, sourceText: ""))
            == "Opened in Claude — press ↩")
    }

    // MARK: Confidence

    @Test("an event without a date, or a vague date, is uncertain; a plain one is certain")
    func confidence() {
        let now = Date()
        let certain = ProposedAction(kind: .createEvent, title: "Dentist", start: now, dateSourcePhrase: "tomorrow at 3", sourceText: "")
        #expect(ActionConfidence.assess(certain, utterance: "dentist tomorrow at 3") == .certain)
        let undated = ProposedAction(kind: .createEvent, title: "Dentist", sourceText: "")
        #expect(ActionConfidence.assess(undated, utterance: "dentist") == .uncertain("no date"))
        let vague = ProposedAction(kind: .createReminder, title: "Call Dana", start: now, dateSourcePhrase: "sometime next week", sourceText: "")
        #expect(ActionConfidence.assess(vague, utterance: "remind me to call dana sometime next week") == .uncertain("vague date \"sometime next week\""))
        let missedTime = ProposedAction(kind: .createReminder, title: "Call Dana", sourceText: "")
        #expect(ActionConfidence.assess(missedTime, utterance: "remind me to call dana on tuesday") == .uncertain("date not understood"))
        let noTime = ProposedAction(kind: .createReminder, title: "Buy oat milk", sourceText: "")
        #expect(ActionConfidence.assess(noTime, utterance: "remind me to buy oat milk") == .certain)
    }
}
