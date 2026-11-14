import Foundation
import Synchronization
import Testing
@testable import MurmurCore

private struct NoSpeech: Transcriber {
    func transcribe(_ samples: [Float]) async throws -> String { "" }
}

/// Answers `registerAnswer` to a call that carries a register line and `plainAnswer` to one that does not, and remembers
/// which kind each call was.
private final class RegisterScriptedModel: LanguageModel, Sendable {
    let registerAnswer: String
    let plainAnswer: String
    private let seen = Mutex<[Bool]>([])
    init(registerAnswer: String, plainAnswer: String) {
        self.registerAnswer = registerAnswer
        self.plainAnswer = plainAnswer
    }
    /// For each call, whether it carried a register line.
    var callsWithRegister: [Bool] { seen.withLock { $0 } }
    var identifier: String { "register-scripted" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        let hasRegister = IntentRegister.detecting(in: instructions) != nil
        seen.withLock { $0.append(hasRegister) }
        return String(decoding: try JSONEncoder().encode(["text": hasRegister ? registerAnswer : plainAnswer]), as: UTF8.self)
    }
}

@Suite("Register-aware rewrite bound and the plain second ask", .timeLimit(.minutes(2)))
struct RegisterRewriteBoundTests {
    private let mail = "com.apple.mail"
    private let slack = "com.tinyspeck.slackmacgap"

    // MARK: The bound

    private func account(_ answer: String, _ spoken: String) -> RewriteAccount {
        RewriteAccount.measure(answer, against: spoken)
    }

    private let followUp = "hi marcus just following up on my email from last week um did you get a chance to look at the proposal let me know if you need anything from me"
    private let followUpReworded = "Hi Marcus, I wanted to follow up on my email from last week. Have you had a chance to review the proposal? Please let me know if you need anything further from me."
    private let pushBack = "hey tom i need to push back on the scope here um three weeks isn't realistic for all of this can we cut the reporting module and ship that in phase two"
    private let pushBackReworded = "Hi Tom, I'd like to push back on the scope. Three weeks isn't realistic for everything included. Could we cut the reporting module and ship it in phase two?"

    @Test("without a register the bound is the plain one, whatever the numbers")
    func plainBoundUnchanged() {
        let measured = account(followUpReworded, followUp)
        #expect(!measured.isRewrite)
        #expect(!measured.isRewrite(under: nil))
        let faithful = account("Hi Marcus, just following up on my email from last week.", followUp)
        #expect(faithful.isRewrite == faithful.isRewrite(under: nil))
    }

    @Test("a faithful diplomatic rewording of a full sentence or two passes under every register and fails the plain bound")
    func faithfulRewordingPasses() {
        let cases: [(String, String)] = [
            (followUp, followUpReworded),
            (pushBack, pushBackReworded),
            ("hi priya thanks for reaching out unfortunately i can't join the call on thursday i'm traveling but i'd love to reschedule for next week",
             "Hi Priya, thank you for getting in touch. Unfortunately, I won't be able to join the call on Thursday as I'm traveling, but I would be glad to reschedule for next week."),
        ]
        for (spoken, reworded) in cases {
            let measured = account(reworded, spoken)
            #expect(!measured.isRewrite, "\(spoken)")
            #expect(measured.inOrderLetters >= RewriteAccount.registerMinimumKeptLetters, "\(spoken)")
            for register in IntentRegister.allCases { #expect(measured.isRewrite(under: register), "\(register) \(spoken)") }
        }
    }

    @Test("a reply to a short question or request keeps too little to pass under any register")
    func shortRepliesStayRefused() {
        let cases: [(String, String)] = [
            ("sure", "I would be happy to do that."),
            ("no", "I do not agree with your statement."),
            ("tonight", "I would like to spend the evening with you."),
            ("can you share this chart", "Sure, I can share the chart with you right now."),
            ("why", "Please explain why you are asking this question."),
            ("could you find those boxes for me", "Yes, I will look for the boxes and let you know."),
        ]
        for (spoken, reply) in cases {
            let measured = account(reply, spoken)
            #expect(!measured.isRewrite, "\(spoken)")
            for register in IntentRegister.allCases { #expect(!measured.isRewrite(under: register), "\(register) \(spoken)") }
        }
    }

    @Test("a model's own first clause for a dictation that lost its start stays refused, however well it reads")
    func clippedStartStaysRefused() {
        // Measured on the never-answer-long set with Professional: these keep 24 to 47 letters of what was said.
        let cases: [(String, String)] = [
            ("ticket to the printer room by the end of the day on friday",
             "I would like to request a ticket to the printer room by the end of the day on Friday."),
            ("the trip we talked about last week because the client keeps asking about it",
             "I would like to schedule the trip we discussed last week, as the client has been asking about it repeatedly."),
            ("new office when you have a free minute this week",
             "I would like to meet with you in the new office when you have a free minute this week."),
            ("thing on monday morning since the deadline moved up", "I will take care of it on Monday morning, since the deadline has moved up."),
        ]
        for (spoken, invented) in cases {
            let measured = account(invented, spoken)
            #expect(measured.inOrderLetters < RewriteAccount.registerMinimumKeptLetters, "\(spoken)")
            for register in IntentRegister.allCases { #expect(!measured.isRewrite(under: register), "\(register) \(spoken)") }
        }
    }

    @Test("a long answer that keeps the dictation but buries it in text of its own fails under every register")
    func buriedDictationStaysRefused() {
        let spoken = "can you move the invoice to the shared drive before the meeting tomorrow afternoon and send me the link to it"
        let reply = spoken + ". Yes, of course, I would be delighted to do that for you, and I will confirm by message as soon as "
            + "the whole thing has been completely finished, checked twice, filed away properly, backed up and shared with the "
            + "rest of the people on the team, who will be notified as well."
        let measured = account(reply, spoken)
        #expect(measured.inOrderLetters >= RewriteAccount.registerMinimumKeptLetters)
        for register in IntentRegister.allCases { #expect(!measured.isRewrite(under: register), "\(register)") }
    }

    @Test("the looser bound is four, the floor sixty, and a register never makes the check stricter")
    func constantsAndMonotonic() {
        #expect(RewriteAccount.registerLooseness == 4)
        #expect(RewriteAccount.registerMinimumKeptLetters == 60)
        for (spoken, text) in [(followUp, followUp), (pushBack, "Tom, can we cut the reporting module?"), ("a b", "a b c d e f g")] {
            let measured = account(text, spoken)
            if measured.isRewrite { for register in IntentRegister.allCases { #expect(measured.isRewrite(under: register)) } }
        }
    }

    // MARK: Through the cleaner and the pipeline

    private func run(
        spoken: String, registerAnswer: String, plainAnswer: String, bundleID: String, tones: ToneSettings = .standard,
        registerLines: Bool = true
    ) async -> (result: PipelineResult, calls: [Bool]) {
        let model = RegisterScriptedModel(registerAnswer: registerAnswer, plainAnswer: plainAnswer)
        let cleaner = SmartCleaner(model: model, health: ModelHealth(), wholeTranscript: { true }, registerLines: { registerLines })
        let mode = Mode.builtIns(userName: "")[0].resolvingAppCleanupLevel(tones.dictationLevel)
        let settings = PipelineSettings.forDictation(
            cleanup: CleanupOptions(level: tones.dictationLevel), tone: tones, mode: mode,
            category: AppCategory.classify(bundleID: bundleID), bundleID: bundleID, windowTitle: nil)
        let result = await DictationPipeline(transcriber: NoSpeech(), cleaner: cleaner).clean(spoken, settings: settings)
        return (result, model.callsWithRegister)
    }


    @Test("a faithful rewording is taken from the first ask under a register, with no second ask")
    func rewordingTaken() async {
        let run = await run(spoken: followUp, registerAnswer: followUpReworded, plainAnswer: "NOT USED", bundleID: mail)
        #expect(run.result.usedModel)
        #expect(run.result.text.contains("I wanted to follow up"), "\(run.result.text)")
        #expect(run.calls == [true])
        #expect(!(run.result.groups.first?.registerDropped ?? true))
    }

    @Test("a Professional answer that rewords a phrase and keeps every fact is pasted, not the plain answer")
    func phraseRewordingPasted() async {
        let run = await run(
            spoken: "this report is a mess, redo it by tomorrow",
            registerAnswer: "This report is in poor shape; please redo it by tomorrow.",
            plainAnswer: "This report is a mess. Redo it by tomorrow.", bundleID: mail)
        #expect(run.calls == [true])
        #expect(run.result.usedModel)
        #expect(run.result.text.contains("in poor shape"), "\(run.result.text)")
        #expect(run.result.groups.first?.registerDropped == false)
    }

    @Test("the same rewording is refused as before when no register was sent")
    func rewordingRefusedWithoutRegister() async {
        let run = await run(spoken: followUp, registerAnswer: followUpReworded, plainAnswer: followUpReworded, bundleID: mail,
                            registerLines: false)
        #expect(!run.result.usedModel)
        #expect(run.calls == [false])
    }

    @Test("a register answer a value check refuses is asked again without the line, and the plain answer is used")
    func plainSecondAsk() async {
        let spoken = "Um, we do not know the price yet, it is twenty dollars."
        let run = await run(
            spoken: spoken, registerAnswer: "We cannot confirm the price yet; it is thirty dollars.",
            plainAnswer: "We do not know the price yet, it is $20.", bundleID: mail)
        #expect(run.calls == [true, false])
        #expect(run.result.usedModel)
        #expect(run.result.text.contains("$20"), "\(run.result.text)")
        #expect(run.result.groups.first?.registerDropped == true)
        #expect(run.result.groups.first?.plainRetryMs != nil)
        // The plain answer was not written in the register, so the tone's word-level pass applies to it.
        #expect(run.result.text.contains("do not know"), "\(run.result.text)")
    }

    @Test("an answer that keeps less than the floor and promises what was not said is asked again plainly, and the plain answer is used")
    func belowFloorGoesPlain() async {
        let spoken = "hi priya really great meeting you yesterday i'd love an intro to your head of product if you're up for it"
        let plain = "Hi Priya, really great meeting you yesterday. I'd love an intro to your head of product if you're up for it."
        let run = await run(
            spoken: spoken,
            registerAnswer: "Hi Priya, it was a pleasure meeting you yesterday. I will send you an introduction to our head of product.",
            plainAnswer: plain, bundleID: mail)
        #expect(run.calls == [true, false])
        #expect(run.result.usedModel)
        #expect(run.result.groups.first?.registerDropped == true)
        #expect(run.result.text.contains("eally great meeting you"), "\(run.result.text)")
    }

    @Test("when the plain answer is refused too, the rules draft is delivered")
    func bothRefused() async {
        let spoken = "Um, we do not know the price yet, it is twenty dollars."
        let run = await run(spoken: spoken, registerAnswer: "We cannot confirm the price; it is thirty dollars.",
                            plainAnswer: "We do not know the price yet, it is thirty dollars.", bundleID: mail)
        #expect(run.calls == [true, false])
        #expect(!run.result.usedModel)
        #expect(run.result.text.contains("twenty") || run.result.text.contains("20"), "\(run.result.text)")
    }

    @Test("a reply to a question is delivered by neither ask: the rules draft is")
    func neverAnswerHolds() async {
        let spoken = "can you share this chart"
        for bundle in [mail, "com.apple.MobileSMS", "com.anthropic.claudefordesktop"] {
            let tones = bundle == "com.apple.MobileSMS" ? ToneSettings(defaultTone: .casual) : ToneSettings.standard
            let run = await run(spoken: spoken, registerAnswer: "Sure, I can share the chart with you right now.",
                                plainAnswer: "Sure, I can share the chart with you right now.", bundleID: bundle, tones: tones)
            #expect(!run.result.usedModel, "\(bundle)")
            #expect(!run.result.text.lowercased().contains("sure"), "\(bundle) \(run.result.text)")
        }
    }

    @Test("with no register (Default tone) a refused answer is not asked again")
    func defaultToneAsksOnce() async {
        let spoken = "Um, we do not know the price yet, it is twenty dollars."
        let run = await run(spoken: spoken, registerAnswer: "x", plainAnswer: "We cannot confirm the price; it is thirty dollars.",
                            bundleID: slack)
        #expect(run.calls == [false])
        #expect(!run.result.usedModel)
        #expect(run.result.groups.first?.registerDropped == false)
    }

    @Test("with the capability off no line is sent and a refused answer is not asked again")
    func capabilityOffAsksOnce() async {
        let spoken = "Um, we do not know the price yet, it is twenty dollars."
        let run = await run(spoken: spoken, registerAnswer: "x", plainAnswer: "We cannot confirm the price; it is thirty dollars.",
                            bundleID: mail, registerLines: false)
        #expect(run.calls == [false])
        #expect(!run.result.usedModel)
    }
}
