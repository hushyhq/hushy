import AppKit
import MurmurCore
import SwiftUI

/// The word a `.nameOffer` row offers. Kept in `PillModel.nameOffer`, outside the pill's state.
struct NameOffer: Equatable {
    /// The word as the recogniser wrote it and Hushy pasted it.
    let heard: String
    /// The word as it will be added: `heard`, until the person corrects it.
    var spelling: String { didSet { editedAt = Date() } }
    /// When the spelling was last typed in, so the row is not cleared under someone's fingers.
    private(set) var editedAt: Date?

    init(heard: String) {
        self.heard = heard
        spelling = heard
    }

    /// The longest spelling the field takes.
    static let spellingLimit = 40

    /// The corrected spelling, tidied; nil when the field is blank.
    var word: String? {
        let tidy = spelling.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return tidy.isEmpty ? nil : String(tidy.prefix(Self.spellingLimit))
    }

    /// What the recogniser wrote, kept with the word when the person spelled it differently (a
    /// change of capitals alone is the same word).
    var heardAs: String? {
        guard let word, MemoryIndex.key(word) != MemoryIndex.key(heard) else { return nil }
        return heard
    }
}

/// Where a name offer is: offered, opened so the spelling can be corrected, or added.
enum NameOfferPhase: Equatable {
    case offered
    case editing
    case added
}

/// What became of one offer.
enum NameOfferAnswer: Equatable {
    case add(word: String, heardAs: String?)
    /// ✕, or esc while correcting.
    case dismissed
    /// Nobody touched it: it timed out, or the next thing the pill showed replaced it.
    case ignored
}

/// The words on the row. An offer, never a verdict: Hushy does not know the word is wrong.
enum NameOfferWording {
    static let offer = "Remember"
    static let editing = "Remember as"
    static let added = "Added"
    static let addHelp = "Add to your words, so Hushy writes it this way"
    static let openHelp = "Correct the spelling first"
    static let dismissHelp = "Not now"
    static func heardNote(_ heard: String) -> String { "heard \u{201C}\(heard)\u{201D}" }
    /// VoiceOver, per phase. The word is the one word the row already shows.
    static func accessibility(_ phase: NameOfferPhase, offer: NameOffer?) -> String {
        guard let offer else { return "Pasted" }
        switch phase {
        case .offered: return "Pasted. Hushy can add \(offer.heard) to your words."
        case .editing: return "Pasted. Correct the spelling of \(offer.heard), then add it."
        case .added: return "Added \(offer.word ?? offer.heard) to your words."
        }
    }
}

extension PillState {
    /// The offer's phase, or nil for every other state.
    var nameOfferPhase: NameOfferPhase? {
        if case .nameOffer(let phase, _, _) = self { return phase }
        return nil
    }

    /// The offer waits five seconds, the added line a moment; an open spelling field waits longer,
    /// and none of them goes while the pointer is on the pill (`selfDismissDecision`).
    static let nameOfferDelay: Duration = .seconds(5)
    static let nameEditingDelay: Duration = .seconds(20)
    static let nameAddedDelay: Duration = .milliseconds(1_600)
}

extension PillModel {
    /// The spelling field is open: the one time the pill's panel may hold the keyboard.
    var isEditingName: Bool { state.nameOfferPhase == .editing && nameOffer != nil }

    /// A letter went into the spelling field in the last few seconds.
    var isTypingName: Bool {
        guard isEditingName, let edited = nameOffer?.editedAt else { return false }
        return Date().timeIntervalSince(edited) < Self.nameTypingGrace
    }

    static let nameTypingGrace: TimeInterval = 6

    /// Shows Done with an offer to add `word`. `answer` is called once, with what became of it.
    func present(nameOffer word: String, words: Int, usedContext: Bool, answer: @escaping (NameOfferAnswer) -> Void) {
        let earlier = onNameOfferAnswer
        nameOffer = NameOffer(heard: word)
        onNameOfferAnswer = answer
        state = .nameOffer(.offered, words: words, usedContext: usedContext)
        earlier?(.ignored)
    }

    /// The arrow: the row opens so the spelling can be corrected.
    func openNameOffer() {
        guard case .nameOffer(.offered, let words, let usedContext) = state, nameOffer != nil else { return }
        state = .nameOffer(.editing, words: words, usedContext: usedContext)
    }

    /// The tick (and Return in the spelling field): add the word as it is spelled now.
    func acceptNameOffer() {
        guard case .nameOffer(let phase, let words, let usedContext) = state, phase != .added,
              let offer = nameOffer, let word = offer.word else { return }
        let answer = onNameOfferAnswer
        onNameOfferAnswer = nil
        state = .nameOffer(.added, words: words, usedContext: usedContext)
        answer?(.add(word: word, heardAs: offer.heardAs))
    }

    /// ✕ (and esc in the spelling field).
    func dismissNameOffer() {
        guard state.nameOfferPhase != nil else { return }
        let answer = onNameOfferAnswer
        onNameOfferAnswer = nil
        state = .idle
        answer?(.dismissed)
    }

    /// Called on every change of state. The word and its callback go with the row, whatever
    /// replaced it; an offer that leaves the pill unanswered was ignored.
    func nameOfferEnded(from oldValue: PillState) {
        guard state.nameOfferPhase == nil, nameOffer != nil || onNameOfferAnswer != nil else { return }
        let answer = onNameOfferAnswer
        nameOffer = nil
        onNameOfferAnswer = nil
        answer?(.ignored)
    }
}

extension PillPanel {
    /// Hands the keyboard back to the app being typed into once the spelling field has closed.
    /// A panel gives up the keyboard only by leaving the screen or by another window taking it,
    /// so it steps out for an instant; `PillCoordinator.apply` orders it straight back in.
    func releaseKeyboardUnlessEditing() {
        guard isKeyWindow, !model.isEditingName else { return }
        orderOut(nil)
    }

    /// The keyboard went elsewhere while the spelling was open (a click in another window): the
    /// offer closes, so a row that looks like it is taking letters never sits there taking none.
    func keyboardLeft() {
        if model.isEditingName { model.state = .idle }
    }
}

/// Done, with the offer beside it in the same capsule: the lime ✓ exactly as Done draws it, a
/// hairline, then the word. Offered: the word on a chip with an arrow, a tick that adds it, ✕.
/// Opened: the same row with the word in a field. Added: one line, then the pill rests.
struct PillNameOfferRow: View {
    let phase: NameOfferPhase
    let words: Int
    let usedContext: Bool
    @Bindable var model: PillModel
    @Environment(\.isSnapshot) private var isSnapshot

    /// The widest a word is drawn; a longer one ends in an ellipsis (the field scrolls).
    static let wordWidth: CGFloat = 150

    var body: some View {
        HStack(spacing: 8) {
            PillDoneRow(words: words, usedContext: usedContext, asHeard: false, notSent: false)
            if let offer = model.nameOffer {
                Rectangle().fill(.white.opacity(0.16)).frame(width: 1, height: 14)
                switch phase {
                case .offered: offered(offer)
                case .editing: editing(offer)
                case .added: added(offer)
                }
            }
        }
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
        .fixedSize()
    }

    @ViewBuilder
    private func offered(_ offer: NameOffer) -> some View {
        Text(NameOfferWording.offer).foregroundStyle(.white.opacity(0.6))
        Button { model.openNameOffer() } label: {
            HStack(spacing: 5) {
                Text(offer.heard)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .truncationMode(.tail)
                    .frame(maxWidth: Self.wordWidth)
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(.white.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.96))
        .help(NameOfferWording.openHelp)
        .accessibilityLabel("Correct the spelling of \(offer.heard)")
        buttons(canAdd: true, quiet: true)
    }

    @ViewBuilder
    private func editing(_ offer: NameOffer) -> some View {
        Text(NameOfferWording.editing).foregroundStyle(.white.opacity(0.6))
        spellingField(offer)
            .padding(.horizontal, 8)
            .frame(width: Self.fieldWidth(for: offer.spelling), height: 20)
            .background(Capsule().fill(.white.opacity(0.1)))
            .overlay(Capsule().strokeBorder(Theme.phosphorFill.opacity(0.7), lineWidth: 1))
        if offer.heardAs != nil {
            Text(NameOfferWording.heardNote(offer.heard))
                .foregroundStyle(.white.opacity(0.5))
                .truncationMode(.tail)
                .frame(maxWidth: 110)
        }
        buttons(canAdd: offer.word != nil, quiet: false)
    }

    @ViewBuilder
    private func added(_ offer: NameOffer) -> some View {
        Text(NameOfferWording.added).foregroundStyle(.white.opacity(0.6))
        Text(offer.word ?? offer.heard)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .truncationMode(.tail)
            .frame(maxWidth: Self.wordWidth)
    }

    /// The tick that adds, then ✕, as on the pill's other rows. While the offer only sits there
    /// the tick is quiet, lime ink on a grey disc, so Done's ✓ stays the one bright mark; once the
    /// person has opened the word it is the filled lime tick of a row's next step.
    @ViewBuilder
    private func buttons(canAdd: Bool, quiet: Bool) -> some View {
        Button { model.acceptNameOffer() } label: {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(quiet ? Theme.phosphorFill : Theme.onPhosphor)
                .frame(width: 20, height: 20)
                .background(Circle().fill(quiet ? AnyShapeStyle(.white.opacity(0.14)) : AnyShapeStyle(Theme.phosphorFill)))
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .opacity(canAdd ? 1 : 0.35)
        .disabled(!canAdd)
        .help(NameOfferWording.addHelp)
        .accessibilityLabel("Add to your words")
        .padding(.leading, 2)
        PillDismissButton { model.dismissNameOffer() }
            .help(NameOfferWording.dismissHelp)
    }

    /// A still image cannot draw a text field, so it draws the same words and a caret.
    @ViewBuilder
    private func spellingField(_ offer: NameOffer) -> some View {
        if isSnapshot {
            HStack(spacing: 1) {
                Text(offer.spelling).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                Rectangle().fill(Theme.phosphorFill).frame(width: 1, height: 12)
                Spacer(minLength: 0)
            }
        } else {
            NameSpellingField(
                text: Binding(get: { model.nameOffer?.spelling ?? "" }, set: { model.nameOffer?.spelling = $0 }),
                onCommit: { model.acceptNameOffer() }, onCancel: { model.dismissNameOffer() })
        }
    }

    /// Wide enough for the word and a few more letters, within the row's limit.
    static func fieldWidth(for spelling: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let width = (spelling as NSString).size(withAttributes: [.font: font]).width
        return min(max(width + 40, 84), wordWidth + 16)
    }
}

/// The one text field the pill has. It takes the keyboard when it appears, which the panel allows
/// only while the spelling is being corrected (`PillPanel.canBecomeKey`). Return adds, esc closes.
struct NameSpellingField: NSViewRepresentable {
    @Binding var text: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = KeyTakingTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 11, weight: .semibold)
        field.textColor = .white
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.lineBreakMode = .byClipping
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Spelling")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NameSpellingField

        init(_ parent: NameSpellingField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let limited = String(field.stringValue.prefix(NameOffer.spellingLimit))
            if limited != field.stringValue { field.stringValue = limited }
            parent.text = limited
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): parent.onCommit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }
}

/// Asks its window for the keyboard once it is in one, with the caret after the last letter: the
/// usual correction adds or changes a letter, it does not retype the word.
private final class KeyTakingTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in
            // A panel that may not hold the keyboard (a test's) is left alone.
            guard let self, self.window === window, window.canBecomeKey else { return }
            window.makeKey()
            guard window.makeFirstResponder(self) else { return }
            self.currentEditor()?.selectedRange = NSRange(location: self.stringValue.utf16.count, length: 0)
        }
    }
}
