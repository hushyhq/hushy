import MurmurCore
import SwiftUI

/// Voice-action practice, opened from Settings → Voice actions ("Practice a voice action"). It
/// was a numbered onboarding step until 2026-10-11; onboarding now ends at the first dictation
/// and this is an optional thing to try later. The key to press twice (Control by default) as a
/// key cap, with the held fn+⌃ chord as the alternative, one rehearsal — press it and say "Remind
/// me to stretch in 10 minutes" — that shows what the chip would say, then one line each for
/// Ask / Ask another AI / Summarize. The rehearsal is a sandbox: the chord listens and
/// transcribes for real (`VoiceActionsController.rehearsal`), but nothing is created, nothing
/// asks for Reminders access, and nothing counts against the Free allowance, so there is
/// nothing to clean up afterwards. The chip therefore says "Would add: …", has no Undo, and the
/// line under it says plainly that nothing was added.
enum VoiceActionRehearsal {
    static let prompt = "Remind me to stretch in 10 minutes"
    /// Settings → Voice actions: the row that opens the practice.
    static let settingsRowTitle = "Practice a voice action"
    static let settingsRowDetail = "Try one without doing anything real. Nothing is created."
    /// Shown in place of the prompt to press the key while dictation is not ready.
    static let notReadyLine = "The speech model is not ready yet. Come back here to practice once it is."
    /// Under the practice chip: nothing was created.
    static let practiceLine = "Practice only. Nothing was added to Reminders."
    /// What a real chip does, with the one undo number (`ActionUndoWindow`).
    static let realChipLine = "When it's real, the chip stays for \(ActionUndoWindow.seconds) seconds and Undo takes it back."

    enum Phase: String, Equatable {
        /// Waiting for the chord.
        case waiting
        /// The words came back and the practice chip is up.
        case heard
    }

    /// The practice chip for what was heard: "Would add: Stretch · in 10 minutes" for the prompt, or
    /// the task it did hear ("remind me to X in N minutes/hours"), or the words as a title when
    /// the sentence was something else entirely. Pure, so the step needs no model.
    static func chip(for transcript: String) -> DoneChipState {
        let words = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        var task = words
        for lead in ["remind me to ", "reminder to ", "remind me "] where task.lowercased().hasPrefix(lead) {
            task = String(task.dropFirst(lead.count))
            break
        }
        var detail: String?
        if let range = task.range(of: #" in (\d+|a|an|one|two|five|ten|fifteen|twenty|thirty) (minutes?|hours?|mins?)$"#,
                                  options: [.regularExpression, .caseInsensitive]) {
            detail = String(task[range]).trimmingCharacters(in: .whitespaces)
            task = String(task[..<range.lowerBound])
        }
        task = task.trimmingCharacters(in: .whitespaces)
        let title = task.isEmpty ? words : task.prefix(1).uppercased() + task.dropFirst()
        return DoneChipState(
            title: "Would add: \(title)", detail: detail, kind: .createReminder, undoRecordID: nil, isPractice: true)
    }
}

struct VoiceActionRehearsalView: View {
    enum Mode { case settings, onboarding }
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.snapshotActionRehearsal) private var snapshotPhase
    /// Closes the sheet the practice is shown in.
    var mode: Mode = .settings
    let onDone: () -> Void
    @State private var phase = VoiceActionRehearsal.Phase.waiting
    @State private var heard = ""

    /// With the sheet's padding this leaves about the 560 pt column the lines were laid out for in
    /// onboarding.
    static let sheetWidth: CGFloat = 640

    private static let kinds: [(symbol: String, title: String, example: String)] = [
        ("checkmark.circle", "Do something", "“Remind me to call Dana Friday at 9” · “Open Gmail” · “Add oat milk to the groceries list.”"),
        ("questionmark.bubble", "Ask about your own stuff", "“What's on my calendar tomorrow?” — answered from your notes, reminders and calendar."),
        ("arrow.up.forward.app", "Ask another AI", "“Ask Claude why the sky is blue” — opens Claude, ChatGPT or Perplexity with the question."),
        ("text.viewfinder", "Summarize this", "“Summarize this” — the front window, summarized on this Mac."),
    ]

    var body: some View {
        let phase = snapshotPhase ?? phase
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(mode == .onboarding ? "Try a voice action" : "Say what to do").font(Theme.Font.section)
            let key = model.settings.effectiveActionTrigger
            if mode == .onboarding {
                Text(OnboardingVoiceActionOffer.instruction(
                    dictation: model.settings.triggerKey, action: model.settings.actionTrigger))
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            } else {
            HStack(spacing: 6) {
                Text("Tap").foregroundStyle(Theme.textSecondary)
                KeyCap(label: key.keyCap, size: 12)
                Text("twice to talk hands-free, then say:").foregroundStyle(Theme.textSecondary)
            }
            .font(.system(size: 15))
            HStack(spacing: 6) {
                Text("Tap").foregroundStyle(Theme.textSecondary)
                KeyCap(label: key.keyCap, size: 11)
                Text("again to cancel. Or hold").foregroundStyle(Theme.textSecondary)
                ForEach(ActionHotkeyMonitor.chordKeys, id: \.self) { KeyCap(label: $0, size: 11) }
                Text("together.").foregroundStyle(Theme.textSecondary)
            }
            .font(.system(size: 12))
            }
            Text("“\(VoiceActionRehearsal.prompt).”")
                .font(.system(size: 22, design: .serif))
                .foregroundStyle(Theme.phosphor)
            rehearsalCard(phase)
            if mode == .settings {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(Self.kinds, id: \.title) { kind in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Image(systemName: kind.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.phosphor)
                            .frame(width: 16)
                        (Text(kind.title + ". ").foregroundStyle(Theme.textPrimary) + Text(kind.example).foregroundStyle(Theme.textSecondary))
                            .font(Theme.Font.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text("Practice here never creates anything.")
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
            if mode == .onboarding {
                Button("Close practice", action: onDone).buttonStyle(SecondaryButtonStyle())
            } else {
                Button("Done", action: onDone).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            guard !isSnapshot else { return }
            model.beginActionRehearsal { transcript in
                heard = transcript
                withAnimation(Theme.Motion.pop) { self.phase = .heard }
            }
        }
        .onDisappear { model.endActionRehearsal() }
    }

    /// The practice area: what to expect, then the demo chip once the words come back.
    @ViewBuilder
    private func rehearsalCard(_ phase: VoiceActionRehearsal.Phase) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            switch phase {
            case .waiting:
                if model.modelStatus.isReady || isSnapshot {
                    Label(mode == .onboarding ? "Waiting to hear your voice action…" : "Waiting for you to press \(model.settings.effectiveActionTrigger.phrase)… The pill lights up while it listens.", systemImage: "bolt")
                        .font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
                } else {
                    Label(VoiceActionRehearsal.notReadyLine, systemImage: "arrow.down.circle")
                        .font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
                }
            case .heard:
                let said = isSnapshot ? VoiceActionRehearsal.prompt : heard
                if mode == .onboarding {
                    Text(OnboardingVoiceActionOffer.practiceNotice)
                        .font(Theme.Font.emphasis).foregroundStyle(Theme.textPrimary)
                }
                Text("Heard: “\(said)”")
                    .font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
                practiceChip(VoiceActionRehearsal.chip(for: said))
                if mode == .settings { VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(VoiceActionRehearsal.practiceLine)
                        .font(Theme.Font.emphasis).foregroundStyle(Theme.textPrimary)
                    Text(VoiceActionRehearsal.realChipLine)
                        .font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
                }
                .fixedSize(horizontal: false, vertical: true) }
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(mode == .onboarding ? Color.clear : Theme.bgRaised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
            .strokeBorder(Theme.hairline, lineWidth: mode == .onboarding ? 0 : 1))
    }

    /// The done chip as the pill draws it, on a dark capsule, so the real one is recognisable.
    /// It is practice, so there is no Undo to press.
    private func practiceChip(_ chip: DoneChipState) -> some View {
        DoneChipRow(chip: chip, onUndo: {})
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Theme.pillSurface))
            .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
            .environment(\.colorScheme, .dark)
    }
}

extension VoiceActionRehearsalView {
    /// The practice as its Settings sheet frames it. Shared by the sheet and the snapshot captures
    /// (`ImageRenderer` cannot draw a presented sheet).
    @MainActor static func sheetContent(onDone: @escaping () -> Void) -> some View {
        VoiceActionRehearsalView(onDone: onDone)
            .padding(Theme.Space.xxl)
            .frame(width: sheetWidth)
    }

    @MainActor static func snapshotSheet(model: AppModel, phase: VoiceActionRehearsal.Phase) -> some View {
        sheetContent(onDone: {}).environment(model).environment(\.snapshotActionRehearsal, phase)
    }
}
