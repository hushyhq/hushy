import MurmurCore
import SwiftUI

/// The optional "while it downloads" steps. `OnboardingPacing` inserts them before "Try it" only
/// when the speech model would otherwise make the user wait; each one does something real
/// (nothing here is a progress bar in disguise) and each is skippable from the bottom bar.
struct WaitingStepView: View {
    let step: OnboardingStep
    let onContinue: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.s) {
                Eyebrow("While the speech model downloads")
                Spacer(minLength: 0)
            }
            content
            Button("Continue", action: onContinue)
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .padding(.top, Theme.Space.xs)
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .micCheck: MicCheckStep()
        case .dictionary: DictionaryWordsStep()
        case .writingStyle: WritingStyleStep()
        case .privacy: PrivacyStep()
        default: EmptyView()
        }
    }
}

private struct WaitingHeader: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(title).font(Theme.Font.section)
            Text(message).font(.system(size: 15)).foregroundStyle(Theme.textSecondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A fuller version of the Microphone step's meter: pick the input, see it move.
private struct MicCheckStep: View {
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            WaitingHeader(
                title: "Check your microphone",
                message: "Say a sentence at your normal volume. If the bars barely move, pick another input.")
            MicCheck(isSnapshot: isSnapshot)
        }
    }
}

/// Names and words the user says often, saved to the Dictionary (the same store Settings →
/// Voice & style edits), so the first dictation already spells them right.
private struct DictionaryWordsStep: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var draft = ""
    @State private var problem: String?
    static let maximumLength = 60

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            WaitingHeader(
                title: "Names Hushy should know",
                message: "People, products, places — anything you'd hate to see misspelled. Hushy uses them from your first dictation. Stored on this Mac only.")
            HStack(spacing: Theme.Space.s) {
                if isSnapshot {
                    SnapshotTextField(draft, placeholder: "e.g. Priya, Figma, Kubernetes")
                        .padding(.horizontal, Theme.Space.m).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.bgRaised))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.hairline, lineWidth: 1))
                } else {
                    TextField("e.g. Priya, Figma, Kubernetes", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                }
                Button("Add", action: add).buttonStyle(SecondaryButtonStyle())
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .frame(maxWidth: 440)
            if let problem {
                Text(problem).font(Theme.Font.caption).foregroundStyle(Theme.warning)
            }
            let terms = model.library.dictionary.prefix(12).map(\.term)
            if !terms.isEmpty {
                FlowChips(items: terms)
            }
        }
    }

    /// Accepts one or several comma-separated words; skips blanks, over-long entries and ones
    /// already in the Dictionary (case-insensitive).
    private func add() {
        let existing = Set(model.library.dictionary.map { $0.term.lowercased() })
        let candidates = draft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let tooLong = candidates.filter { $0.count > Self.maximumLength }
        var seen = existing
        for term in candidates where term.count <= Self.maximumLength && !seen.contains(term.lowercased()) {
            seen.insert(term.lowercased())
            do {
                _ = try model.store.save(DictionaryEntry(term: term))
            } catch {
                problem = "Couldn't save “\(term)”. Try again, or add it later in Settings."
                return
            }
        }
        problem = tooLong.isEmpty ? nil : "Words longer than \(Self.maximumLength) characters were skipped."
        draft = ""
    }
}

/// Added words as quiet ink chips.
private struct FlowChips: View {
    let items: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(Theme.Font.caption).foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.bgRaised))
                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}

/// How what you say should read: the tone, taught by one sentence written four ways
/// (`ToneExamples`). Changeable any time from the menu bar.
private struct WritingStyleStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            WaitingHeader(title: ToneCopy.onboardingTitle, message: ToneCopy.onboardingMessage(spoken: ToneExamples.spoken))
            VStack(spacing: Theme.Space.s) {
                ForEach(ToneChoice.allCases) { choice in
                    StyleChoice(choice: choice, isSelected: settings.toneSettings.choice == choice) {
                        withAnimation(Theme.Motion.snappy) { settings.toneSettings.choice = choice }
                    }
                }
            }
            if !settings.toneSettings.isAsSpoken {
                ToneKindsView(includeEmpty: false, limit: ToneKinds.compactLimit)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private struct StyleChoice: View {
        let choice: ToneChoice
        let isSelected: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 14)).foregroundStyle(isSelected ? Theme.phosphor : Theme.textTertiary)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(choice.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text(ToneExamples.shortText(for: choice))
                            .font(.system(size: 13, design: .serif)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Space.m).padding(.vertical, 9)
                .frame(maxWidth: 520, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(isSelected ? Theme.bgRaised : (hovering ? Theme.bgRaised.opacity(0.6) : .clear)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(isSelected ? Theme.phosphor.opacity(0.6) : Theme.hairline, lineWidth: isSelected ? 1.5 : 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Theme.Motion.hover, value: hovering)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}

/// What stays on the Mac, in one screen. Every line is true of this build: the audio is
/// transcribed on-device; history is a local SQLite file; the automatic network use is this
/// model download, app updates and the daily count; anything that would leave the Mac is opt-in and marked with ↗.
private struct PrivacyStep: View {
    private let rows: [(symbol: String, title: String, detail: String)] = [
        ("waveform", "Your voice stays here",
         "Speech is turned into text on this Mac's Neural Engine. Audio is never uploaded."),
        ("tray.full", "Your words stay here",
         FeatureFlags.meetings
            ? "History, notes and your Dictionary live in a local database you can search, export or delete."
            : "History and your Dictionary live in a local database you can search, export or delete."),
        ("arrow.down.circle", "Downloads, not uploads",
         "By itself Hushy only fetches its speech model (the download on the left) and app updates, apart from the daily count below. Usage numbers are counts and timings, never your words, and stay off unless you turn them on."),
        ("number", "A daily count", DailyCountDisclosure.onboardingLine),
        ("arrow.up.right", "Anything that leaves is marked",
         FeatureFlags.meetings
            ? "The Assistant and connected apps only send what you ask, and show ↗ with the destination first."
            : "Connected apps only send what you ask, and show ↗ with the destination first."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            WaitingHeader(title: "What stays on this Mac", message: "Hushy is private by default. Here is exactly what that means.")
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ForEach(rows, id: \.title) { row in
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        Image(systemName: row.symbol)
                            .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.bgRaised))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                            Text(row.detail).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
        }
    }
}
