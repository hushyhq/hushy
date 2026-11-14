import AppKit
import Carbon.HIToolbox
import MurmurCore
import Testing
@testable import Murmur

/// Answers every voice edit with the same rewrite.
struct VoiceEditRewriteModel: LanguageModel {
    let rewrite: String
    var identifier: String { "rewrite" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        #"{"kind":"edit","text":"\#(rewrite)"}"#
    }
}

/// The focused field and the person at the keyboard, for the controller's real delivery path (`TextInserter.deliver`,
/// `TargetedDelivery`, `ClipboardPaster`): what is selected now, a private pasteboard, and a key poster that records
/// ⌘V and the text the pasteboard held when it went out, instead of posting it. Focus stays on the target.
@MainActor
final class VoiceEditDesk {
    var selectedNow: SelectedText?
    /// What the person selects once the edit is staged on the clipboard, after every earlier look.
    var selectedOnceStaged: SelectedText??
    var sinceLastInput: Duration = .seconds(60)
    /// The pasteboard's text at each ⌘V.
    private(set) var pasted: [String] = []
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("app.hushy.tests.voice-edit.\(UUID().uuidString)"))
    private var paster: ClipboardPaster!

    init(selectedNow: SelectedText?) {
        self.selectedNow = selectedNow
        paster = ClipboardPaster(pasteboard: pasteboard, postKey: { [unowned self] key, flags in
            if key == CGKeyCode(kVK_ANSI_V), flags.contains(.maskCommand) {
                self.pasted.append(self.pasteboard.string(forType: .string) ?? "")
            }
            return true
        }, restoreDelay: .milliseconds(20))
        pasteboard.clearContents()
        pasteboard.setString("the person's clipboard", forType: .string)
    }

    isolated deinit { pasteboard.releaseGlobally() }

    /// The clipboard now, when it holds something other than what the person had.
    var copied: String? {
        let text = pasteboard.string(forType: .string)
        return text == "the person's clipboard" ? nil : text
    }

    var field: VoiceEditController.Field {
        VoiceEditController.Field(
            selection: { [unowned self] _ in
                if let changed = self.selectedOnceStaged, self.copied != nil { return changed }
                return self.selectedNow
            },
            focus: { _ in .unchanged },
            paster: paster,
            sinceLastInput: { [unowned self] in self.sinceLastInput })
    }
}

@MainActor
@Suite("Voice edit pastes only over the selection it read")
struct VoiceEditSelectionRecheckTests {
    static let original = SelectedText(text: "We should catch the results.", location: 12)!
    static let rewrite = "We should cache the results."

    private func run(
        selection: SelectedText = original, selectedNow: SelectedText?, configure: (VoiceEditDesk) -> Void = { _ in }
    ) async -> (VoiceEditController.Handling, VoiceEditDesk, PillModel) {
        let desk = VoiceEditDesk(selectedNow: selectedNow)
        configure(desk)
        let pill = PillModel()
        let controller = VoiceEditController(model: VoiceEditRewriteModel(rewrite: Self.rewrite), pill: pill, field: desk.field)
        let handling = await controller.handle(
            spoken: "change catch to cache", selection: selection, target: .fieldForTests, isCancelled: { false })
        return (handling, desk, pill)
    }

    @Test("the same text at the same place is replaced")
    func samePasted() async {
        let (handling, field, pill) = await run(selectedNow: Self.original)
        #expect(handling == .finished(.pasted))
        #expect(field.pasted == [Self.rewrite], "⌘V went out with the edit staged")
        #expect(pill.state == .voiceEdit(.edited(canUndo: true)))
    }

    @Test("a different selection, the same text elsewhere, or no selection is never pasted over", arguments: [
        SelectedText(text: "Another sentence entirely.", location: 12),
        SelectedText(text: "We should catch the results.", location: 40),
        nil,
    ])
    func changedCopied(now: SelectedText?) async {
        let (handling, field, pill) = await run(selectedNow: now)
        #expect(handling == .finished(.copied))
        #expect(field.pasted.isEmpty, "no ⌘V")
        #expect(field.copied == Self.rewrite, "the edit is on the clipboard")
        #expect(pill.state == .voiceEdit(.copiedInstead))
    }

    @Test("a selection changed while the edit was being staged on the clipboard is checked again right before ⌘V, and never pasted over")
    func changedDuringPaste() async {
        let (handling, field, pill) = await run(selectedNow: Self.original) {
            $0.selectedOnceStaged = .some(SelectedText(text: "Another sentence entirely.", location: 12))
        }
        #expect(handling == .finished(.copied))
        #expect(field.pasted.isEmpty, "no ⌘V over the new selection")
        #expect(field.copied == Self.rewrite, "the staged edit stays on the clipboard to paste by hand")
        #expect(pill.state == .voiceEdit(.copiedInstead))
    }

    @Test("a selection whose place in the field cannot be read is never replaced, even with the same text: it could be another copy of it")
    func unknownPlaceCopied() async {
        let unplaced = SelectedText(text: Self.original.text)!
        let (handling, field, pill) = await run(selection: unplaced, selectedNow: unplaced)
        #expect(handling == .finished(.copied))
        #expect(field.pasted.isEmpty, "no ⌘V")
        #expect(field.copied == Self.rewrite, "the edit is on the clipboard")
        #expect(pill.state == .voiceEdit(.copiedInstead))
    }

    @Test("a click or key press so recent the field may not have handled it yet holds the paste back")
    func inputInFlight() async {
        let (handling, field, _) = await run(selectedNow: Self.original) { $0.sinceLastInput = .zero }
        #expect(handling == .finished(.copied))
        #expect(field.pasted.isEmpty)
        #expect(field.copied == Self.rewrite)
    }

    @Test("the key press that ended the dictation, before the edit was asked for, does not hold it back")
    func earlierKeyDoesNotHold() async {
        let (handling, field, _) = await run(selectedNow: Self.original) { $0.sinceLastInput = .seconds(5) }
        #expect(handling == .finished(.pasted))
        #expect(field.pasted == [Self.rewrite])
    }

    @Test("the pill says so in one pill-sized line")
    func copiedLine() {
        let chip = VoiceEditChip.copiedInstead
        #expect(chip.line == "Selection changed · edit copied")
        #expect(!chip.canUndo)
        #expect(PillState.voiceEdit(chip).selfDismissDelay != nil)
        #expect(PillPanel.size(for: .voiceEdit(chip)) == PillPanel.size(for: .voiceEdit(.declined(.noAnswer))))
    }
}
