import Foundation
@testable import MurmurCore
import Testing

/// Answers every request with one reply, and keeps the prompts it was sent.
private final class AnswerModel: LanguageModel, @unchecked Sendable {
    private let reply: String
    private let lock = NSLock()
    private var sent: [String] = []

    init(kind: String = "edit", text: String) {
        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        reply = #"{"kind":"\#(kind)","text":"\#(escaped)"}"#
    }

    var prompts: [String] { lock.withLock { sent } }
    var identifier: String { "answer" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        lock.withLock { sent.append(prompt) }
        return reply
    }
}

@Suite("Restyle selection")
struct SelectionRestyleTests {
    private let note = "hey can u send me the file asap, i will not be in on friday"

    // MARK: The words the guard reads

    @Test("no style's instruction loosens a check", arguments: RestyleStyle.allCases)
    func instructionLoosensNothing(style: RestyleStyle) {
        let asked = VoiceEditGuard.Instruction(style.instruction)
        #expect(!asked.removes && !asked.translates && !asked.recases && !asked.renumbers && !asked.flipsPolarity)
    }

    // MARK: Outcomes

    @Test("a rewrite that keeps every fact replaces the text", arguments: RestyleStyle.allCases)
    func accepted(style: RestyleStyle) async {
        let rewrite = "Hi, could you please send me the file as soon as possible? I will not be in on Friday."
        let outcome = await SelectionRestyler.restyle(note, as: style, model: AnswerModel(text: rewrite))
        #expect(outcome == .rewritten(rewrite))
    }

    @Test("a rewrite that drops a negation keeps the original text", arguments: RestyleStyle.allCases)
    func droppedNegationKept(style: RestyleStyle) async {
        let outcome = await SelectionRestyler.restyle(
            note, as: style, model: AnswerModel(text: "Hi, could you please send me the file? I will be in on Friday."))
        #expect(outcome == .kept(.wouldChangeMeaning))
    }

    @Test("a rewrite that changes a number keeps the original text")
    func changedNumberKept() async {
        let outcome = await SelectionRestyler.restyle(
            "The review is at 3pm on Thursday.", as: .professional,
            model: AnswerModel(text: "The review is scheduled for 4pm on Thursday."))
        #expect(outcome == .kept(.wouldChangeMeaning))
    }

    @Test("a rewrite that is the text as it was is not an edit")
    func unchangedKept() async {
        let outcome = await SelectionRestyler.restyle(note, as: .refined, model: AnswerModel(text: note))
        #expect(outcome == .kept(.unchanged))
    }

    @Test("a model that reads the selection as new text, or says it cannot, or is missing, keeps the text")
    func modelRefusals() async {
        #expect(await SelectionRestyler.restyle(note, as: .casual, model: AnswerModel(kind: "dictation", text: "")) == .kept(.noAnswer))
        #expect(await SelectionRestyler.restyle(note, as: .casual, model: AnswerModel(kind: "cannot", text: "")) == .kept(.cannotDo))
        #expect(await SelectionRestyler.restyle(note, as: .casual, model: NullLanguageModel()) == .kept(.noAnswer))
    }

    // MARK: What the model is sent

    @Test("the register line goes to the model for a tone and for a prompt, and Refined sends none")
    func registerLines() async {
        for style in RestyleStyle.allCases {
            let model = AnswerModel(text: "Could you send me the file? I will not be in on Friday.")
            _ = await SelectionRestyler.restyle(note, as: style, model: model)
            let prompt = model.prompts.first ?? ""
            #expect(prompt.contains("Selected text:\n<<<\n\(note)\n>>>"), "the selection is data under its marks")
            #expect(prompt.contains("Spoken words: \(style.instruction)"))
            for register in IntentRegister.allCases {
                #expect(prompt.contains(register.line) == (style.register == register))
            }
        }
    }

    @Test("a voice edit without guidance is sent exactly what it always was")
    func plainVoiceEditPromptUnchanged() {
        let request = VoiceEditRequest(selection: "catch", instruction: "change catch to cache")
        #expect(VoiceEditor.prompt(for: request) == "Selected text:\n<<<\ncatch\n>>>\n\nSpoken words: change catch to cache")
    }

    // MARK: The Services table

    @Test("three items rewrite in place and two copy, each with its own message")
    func serviceTable() {
        let replacing = RestyleService.allCases.filter { $0.delivery == .replaceSelection }
        #expect(replacing == [.makeProfessional, .makeCasual, .cleanUp])
        #expect(RestyleService.allCases.filter { $0.delivery == .copyToClipboard } == [.copyAsProfessional, .copyAsPrompt])
        #expect(Set(RestyleService.allCases.map(\.message)).count == RestyleService.allCases.count)
        #expect(RestyleService.copyAsPrompt.style == .prompt)
        #expect(RestyleService.cleanUp.style == .refined)
    }

    @Test("every string a person reads is a bracketed placeholder", arguments: RestyleService.allCases)
    func placeholders(service: RestyleService) {
        #expect(service.menuTitle.hasPrefix("Hushy/["))
        #expect(service.menuTitle.hasSuffix("]"))
    }

    @Test("Info.plist declares exactly the Services the table lists")
    func infoPlistMatchesTable() throws {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Info.plist")
        let info = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        let services = try #require(info["NSServices"] as? [[String: Any]])
        #expect(services.count == RestyleService.allCases.count)
        for service in RestyleService.allCases {
            let entry = try #require(services.first { $0["NSMessage"] as? String == service.message }, "\(service.message) is declared")
            #expect((entry["NSMenuItem"] as? [String: String])?["default"] == service.menuTitle)
            #expect(entry["NSPortName"] as? String == info["CFBundleName"] as? String, "the port is the app's name")
            let sends = entry["NSSendTypes"] as? [String] ?? []
            #expect(sends.contains("NSStringPboardType") && sends.contains("public.utf8-plain-text"))
            let returns = entry["NSReturnTypes"] as? [String]
            // A copy item returns nothing, so it also appears for text a page or a PDF will not let anyone replace.
            #expect((returns != nil) == (service.delivery == .replaceSelection))
        }
    }
}
