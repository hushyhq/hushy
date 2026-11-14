import Foundation
@testable import MurmurCore
import Testing

@Suite("Voice edit")
struct VoiceEditTests {
    private let email = "Hi Dana, I can't make the 3pm review on Thursday. Could we move it to Friday at 10?"

    // MARK: Router

    @Test("instructions over a selection ask the model", arguments: [
        "make this shorter", "Please make it more professional", "fix the grammar", "change catch to cache",
        "turn this into bullet points", "shorter", "more casual please", "Hushy, rewrite this to sound friendlier",
        "can you translate it to Spanish", "in bullet points",
    ])
    func instructionsAskTheModel(spoken: String) {
        #expect(VoiceEditRouter.signals(spoken: spoken, selection: "We should catch the results.").mightBeInstruction)
    }

    @Test("plain dictation over a selection skips the model", arguments: [
        "Thanks Dana, Friday at ten works for me.",
        "Make sure the doors are locked before you leave.",
        "Change of plans, we're meeting at the cafe instead.",
        "I'll send the deck over tonight.",
        "Please find attached the signed contract.",
    ])
    func dictationSkipsTheModel(spoken: String) {
        #expect(!VoiceEditRouter.signals(spoken: spoken, selection: email).mightBeInstruction)
    }

    @Test("long speech is never an instruction")
    func longSpeech() {
        let spoken = "Change the plan so that " + Array(repeating: "we all meet", count: 12).joined(separator: " ")
        #expect(!VoiceEditRouter.signals(spoken: spoken, selection: email).mightBeInstruction)
    }

    @Test("a word quoted from the selection ties the words to it")
    func quotesSelection() {
        let signals = VoiceEditRouter.signals(spoken: "change Thursday to Wednesday", selection: email)
        #expect(signals.quotesSelection)
        #expect(signals.rulesAnswer == .instruction)
    }

    // MARK: Guard

    @Test("a shorter rewrite that keeps every fact is accepted")
    func keepsFacts() {
        let edited = "Dana, I can't make Thursday's 3pm review. Could we do Friday at 10?"
        #expect(VoiceEditGuard.check(edited: edited, original: email, instruction: "make this shorter") == .accepted(edited))
    }

    @Test("a changed number is declined")
    func changedNumber() {
        let edited = "Hi Dana, I can't make the 4pm review on Thursday. Could we move it to Friday at 10?"
        #expect(VoiceEditGuard.check(edited: edited, original: email, instruction: "fix the grammar")
            == .declined(.wouldChangeMeaning, reason: "changed number"))
    }

    @Test("a number the instruction names may change")
    func askedNumber() {
        let edited = "Hi Dana, I can't make the 4pm review on Thursday. Could we move it to Friday at 10?"
        #expect(VoiceEditGuard.check(edited: edited, original: email, instruction: "change 3 to 4") == .accepted(edited))
    }

    @Test("a dropped negation is declined, a negation in other words is not")
    func negation() {
        let dropped = "Hi Dana, I can make the 3pm review on Thursday. Could we move it to Friday at 10?"
        #expect(VoiceEditGuard.check(edited: dropped, original: email, instruction: "more professional")
            == .declined(.wouldChangeMeaning, reason: "dropped negation"))
        let reworded = "Hi Dana, I am unable to attend the 3pm review on Thursday. Could we move it to Friday at 10?"
        #expect(VoiceEditGuard.check(edited: reworded, original: email, instruction: "more professional") == .accepted(reworded))
    }

    @Test("a dropped name is declined unless the instruction names it")
    func names() {
        let dropped = "Hi, I can't make the 3pm review on Thursday. Could we move it to Friday at 10?"
        #expect(VoiceEditGuard.check(edited: dropped, original: email, instruction: "more casual")
            == .declined(.wouldChangeMeaning, reason: "dropped name"))
        let renamed = "Hi Sam, I can't make the 3pm review on Thursday. Could we move it to Friday at 10?"
        #expect(VoiceEditGuard.check(edited: renamed, original: email, instruction: "change Dana to Sam") == .accepted(renamed))
    }

    @Test("the same text back is unchanged, not an edit")
    func unchanged() {
        #expect(VoiceEditGuard.check(edited: " " + email, original: email, instruction: "fix the grammar")
            == .declined(.unchanged, reason: "unchanged"))
    }

    @Test("the selection's outer whitespace survives the edit")
    func whitespace() {
        #expect(VoiceEditGuard.check(edited: "cache", original: " catch\n", instruction: "change catch to cache") == .accepted(" cache\n"))
    }

    @Test("thousands separators do not count as a changed number")
    func thousands() {
        let original = "The invoice is €4,217 and due on the 12th."
        let edited = "Invoice: €4217, due the 12th."
        #expect(VoiceEditGuard.check(edited: edited, original: original, instruction: "make this shorter") == .accepted(edited))
    }

    @Test("a change of case is a change, and times or separators written differently are the same number")
    func caseAndNumberForms() {
        let room = "The meeting is at 2pm in room 4B."
        let caps = "THE MEETING IS AT 2PM IN ROOM 4B."
        #expect(VoiceEditGuard.check(edited: caps, original: room, instruction: "make it all caps") == .accepted(caps))
        let deploy = "new eta is tomorrow 9am, budget 48,500"
        let tidy = "The new ETA is tomorrow at 9:00 AM, with a budget of 48.500."
        #expect(VoiceEditGuard.check(edited: tidy, original: deploy, instruction: "fix the grammar") == .accepted(tidy))
        #expect(VoiceEditGuard.numbers(in: "churn fell from 6.2% to 4.8%") == ["6.2", "4.8"])
    }

    @Test("the prompt's marks are taken off an answer that copied them")
    func unwrapsMarks() {
        #expect(VoiceEditor.unwrapped("<<<\nBonjour\n>>>") == "Bonjour")
        #expect(VoiceEditor.unwrapped("a\nb") == "a\nb")
    }

    // MARK: Model answers

    @Test("the model's kind decides the outcome")
    func kinds() {
        let request = VoiceEditRequest(selection: email, instruction: "make this shorter")
        #expect(VoiceEditor.interpret(.init(kind: "dictation", text: ""), request: request).outcome == .dictation)
        #expect(VoiceEditor.interpret(.init(kind: "cannot", text: ""), request: request).outcome == .declined(.cannotDo))
        let short = "Dana, can't make Thursday 3pm. Friday at 10?"
        #expect(VoiceEditor.interpret(.init(kind: "edit", text: short), request: request).outcome == .edited(short))
    }

    @Test("an unavailable model leaves the selection")
    func noModel() async {
        let outcome = await VoiceEditor.edit(.init(selection: email, instruction: "shorter"), model: NullLanguageModel())
        #expect(outcome == .declined(.noAnswer))
    }

    // MARK: Shapes and flag

    @Test("an empty or huge selection is not editable")
    func selection() {
        #expect(SelectedText(text: "  \n") == nil)
        #expect(SelectedText(text: String(repeating: "a", count: SelectedText.maxCharacters + 1)) == nil)
        #expect(SelectedText(text: "catch")?.text == "catch")
    }

    @Test("undo is offered only inside its window")
    func undoWindow() {
        let made = Date(timeIntervalSince1970: 1_000)
        let undo = VoiceEditUndo(original: "a", replacement: "b", bundleID: nil, processID: 1, madeAt: made)
        #expect(undo.isOpen(at: made.addingTimeInterval(5)))
        #expect(!undo.isOpen(at: made.addingTimeInterval(11)))
    }

    @Test("the flag: a test build turns it on, a stored false turns it off there, a release build is always off")
    func flag() {
        #expect(FeatureFlags.voiceEditEnabled(stored: false, testFeatures: "voice-edit", debug: true) == false)
        #expect(FeatureFlags.voiceEditEnabled(stored: nil, testFeatures: "x, voice-edit", debug: false))
        #expect(!FeatureFlags.voiceEditEnabled(stored: nil, testFeatures: "", debug: false))
        #expect(FeatureFlags.voiceEditEnabled(stored: nil, testFeatures: nil, debug: true))
        #expect(!FeatureFlags.voiceEditEnabled(stored: true, testFeatures: nil, debug: false), "a stored key never opens a release")
        #expect(!FeatureFlags.voiceEditEnabled(stored: true, testFeatures: "voice-editor", debug: false))
    }
}
