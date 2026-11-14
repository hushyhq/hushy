import MurmurCore
import SwiftUI

/// "Try it now" as a conversation: Hushy asks a question, the person double-taps their key and
/// answers out loud, and the reply lands in the message field like it would in any chat app. When
/// the dictation is saved the field's words move up into a sent bubble, with what was heard under
/// it, so the cleanup is visible without a second card. The field is a real text view and the paste
/// is the real paste: nothing here is simulated.
struct OnboardingPracticeChat: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    /// The dictation made on this step, once there is one.
    let latest: Dictation?
    let triggerGlyph: String
    let isSnapshot: Bool

    static let question = "Welcome to Hushy. When should we meet, and what should I bring?"

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .bottom, spacing: Theme.Space.s) {
                avatar
                bubble(Self.question, incoming: true)
                Spacer(minLength: 48)
            }
            if let latest {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack {
                        Spacer(minLength: 48)
                        bubble(latest.text, incoming: false)
                    }
                    Text("Heard: \u{201C}\(latest.rawText)\u{201D}")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.trailing, 4)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                // A suggested reply, like a chat app's: a messy sentence that shows the cleanup.
                HStack {
                    Spacer(minLength: 48)
                    Text(OnboardingCopy.tryItSuggestion)
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .overlay(Capsule().strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                }
            }
            composer
        }
        .padding(Theme.Space.l)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous).fill(Theme.bgRaised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .shadow(color: Theme.cardShadow.opacity(Theme.cardShadowOpacity), radius: 18, y: 8)
    }

    private var avatar: some View {
        Circle().fill(Theme.phosphorFill)
            .frame(width: 26, height: 26)
            .overlay(Text("h").font(.system(size: 13, weight: .semibold, design: .serif)).foregroundStyle(Theme.onPhosphor))
            .accessibilityHidden(true)
    }

    private func bubble(_ words: String, incoming: Bool) -> some View {
        Text(words)
            .font(.system(size: 14))
            .foregroundStyle(Theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 14, bottomLeadingRadius: incoming ? 4 : 14,
                    bottomTrailingRadius: incoming ? 14 : 4, topTrailingRadius: 14, style: .continuous)
                    .fill(incoming ? Theme.selection : Theme.phosphorTint))
            .accessibilityLabel(incoming ? "Hushy: \(words)" : "You: \(words)")
    }

    @ViewBuilder private var composer: some View {
        let placeholder = OnboardingCopy.practicePlaceholder(triggerGlyph: triggerGlyph)
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        Group {
            if isSnapshot {
                SnapshotTextField(text, placeholder: placeholder)
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            } else {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder).font(.system(size: 14)).foregroundStyle(Theme.textTertiary)
                            .padding(.leading, 5).allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .focused(focused)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 20, maxHeight: 64)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(shape.fill(Theme.bgBase))
        // The accent ring says the field is the one the paste lands in.
        .overlay(shape.strokeBorder(isReady ? Theme.phosphor.opacity(0.7) : Theme.hairline, lineWidth: isReady ? 1.5 : 1))
        .animation(Theme.Motion.fade, value: isReady)
        .padding(.top, Theme.Space.xs)
    }

    private var isReady: Bool {
        latest == nil && (isSnapshot || focused.wrappedValue)
    }
}
