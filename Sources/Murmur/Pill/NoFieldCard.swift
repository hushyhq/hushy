import MurmurCore
import SwiftUI

/// The not-pasted card: what was dictated when it could not be typed (no text field, a paste that
/// did not land, focus that moved, a ⌘V that could not be sent). It stacks on
/// the capsule like the answer card and takes the same surface, type sizes and motion, so it
/// reads as part of the pill. It never takes keyboard focus (the pill panel is non-activating);
/// ✕ and the pill's own timer dismiss it, and ⌃⌘C copies from the keyboard (not while the app
/// lock is on; the card's own Copy still works).
///
/// It shows every word. A short dictation is as tall as its lines; a long one scrolls inside
/// `textMaxHeight`, with a line under it saying so, and the card never grows past that.
struct NoFieldCard: View {
    static let width: CGFloat = 440
    /// The tallest the dictated text is drawn: six lines and part of a seventh, so a long
    /// dictation visibly runs on under the fold.
    static let textMaxHeight: CGFloat = 104
    /// The "Scroll to read all 124 words" line under a long dictation, and the gap above it.
    static let scrollCueHeight: CGFloat = 20
    /// Room the panel reserves above or below the capsule: padding, header, the tallest text,
    /// the button row and the shadow. The card draws only as tall as its text needs.
    static let panelHeight: CGFloat = 206
    /// The hint line under the reason (`NoFieldMode.hintLine`) and the gap above it.
    static let hintLineHeight: CGFloat = 16
    /// The room for one card: a card with a hint line is that much taller, the others are unchanged.
    static func panelHeight(for mode: NoFieldMode) -> CGFloat {
        panelHeight + (mode.hintLine == nil ? 0 : hintLineHeight)
    }

    let mode: NoFieldMode
    let text: String
    let onCopy: () -> Void
    let onDismiss: () -> Void
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                header
                if let hint = mode.hintLine {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            NoFieldWords(text: NoFieldText.display(text), wordCount: TextStats.wordCount(text))
            footerRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: Self.width, alignment: .leading)
        .background(
            ZStack {
                if !isSnapshot && !reduceTransparency { VisualEffectBlur() }
                Theme.pillSurface
            })
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(mode.accessibilityText)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "text.cursor")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            Text(mode.reasonLine)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            Spacer(minLength: 4)
            PillDismissButton(action: onDismiss)
        }
    }

    /// Not on the clipboard yet: the one lime Copy. Already there (the capsule under the card says
    /// so, `NoFieldFooter`): a quiet "Copy again", an unconfirmed paste included. No key hints: a
    /// floating surface carries its one action, and VoiceOver still names ⌃⌘V
    /// (`PillRecoveryAccessibility`).
    private var footerRow: some View {
        HStack(spacing: 6) {
            if mode.wasCopiedAutomatically {
                copyButton.buttonStyle(GhostPillButtonStyle())
            } else {
                copyButton.buttonStyle(PillButtonStyle())
            }
            Spacer(minLength: 8)
        }
        .padding(.top, 4)
    }

    private var copyButton: some View {
        Button(mode.copyButtonTitle, action: onCopy)
            .disabled(mode.afterCopy == nil)
            .accessibilityLabel(Self.copyAccessibilityLabel(mode))
            .help("Copy what you said to the clipboard")
    }

    static func copyAccessibilityLabel(_ mode: NoFieldMode) -> String {
        switch mode.copyButtonTitle {
        case "Copy": "Copy what you said"
        case "Copy again": "Copy what you said again"
        default: "Copied"
        }
    }
}

/// The dictated words on the card. All of them: a dictation that fits is drawn whole, and a longer
/// one scrolls inside `NoFieldCard.textMaxHeight` over a line that says how much there is.
struct NoFieldWords: View {
    let text: String
    let wordCount: Int
    @Environment(\.isSnapshot) private var isSnapshot

    static func scrollCue(words: Int) -> String { "Scroll to read all \(words) words" }

    var body: some View {
        ViewThatFits(in: .vertical) {
            words
            VStack(alignment: .leading, spacing: 4) {
                scrolling
                    .frame(height: NoFieldCard.textMaxHeight - NoFieldCard.scrollCueHeight)
                    .mask(Self.fade)
                Text(Self.scrollCue(words: wordCount))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .accessibilityHidden(true) // VoiceOver reads all the words without scrolling
            }
        }
        .frame(maxHeight: NoFieldCard.textMaxHeight, alignment: .top)
    }

    private var words: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.92))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            // One element VoiceOver reads whole, however much of it is scrolled into view.
            .accessibilityLabel("What you said")
            .accessibilityValue(text)
    }

    /// `ImageRenderer` draws nothing inside a `ScrollView`, so a snapshot shows the top of the
    /// text clipped at the same height.
    @ViewBuilder
    private var scrolling: some View {
        if isSnapshot {
            // An overlay pins the text to the top; a taller child of a fixed frame is centred.
            Color.clear.overlay(alignment: .top) { words }.clipped()
        } else {
            ScrollView(.vertical) { words }
        }
    }

    /// The last line fades out, so the text reads as continuing below.
    private static let fade = LinearGradient(
        stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
        startPoint: .top, endPoint: .bottom)
}

/// The capsule under (or over) the card: "Not typed" with the shortcut that copies the last
/// dictation; "Copied to clipboard" when the text went there as the dictation ended (said here,
/// once, and nowhere else on the card); "Copied" once a button put it there. While the app lock
/// is on copy last refuses, so the capsule keeps its reason and names no keys.
struct NoFieldFooter: View {
    let mode: NoFieldMode
    var isLocked = false

    var body: some View {
        HStack(spacing: 6) {
            if let label = mode.capsuleLabel {
                Image(systemName: "text.cursor")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text(label).foregroundStyle(.white.opacity(0.75))
                if mode.namesCopyLast(isLocked: isLocked) {
                    Text("·").foregroundStyle(.white.opacity(0.45))
                    HStack(spacing: 3) {
                        ForEach(ShortcutHelp.copyLastKeys, id: \.self) { KeyCap(label: $0) }
                        Text("copies").foregroundStyle(.white.opacity(0.45))
                    }
                }
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.phosphorFill)
                Text(mode.statusLine ?? "Copied").foregroundStyle(.white.opacity(0.85))
            }
        }
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
        .fixedSize()
    }
}
