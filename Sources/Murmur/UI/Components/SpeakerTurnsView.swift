import MurmurCore
import SwiftUI

/// Renders a note's diarized transcript as speaker turns with colored, clickable name chips —
/// the free-tier "Speaker labels" UI (Pro is only the cross-note voice-signature matching layer
/// on top; see `SpeakerTurnRow`'s voice-suggestion banner). Click a chip to rename that speaker
/// everywhere in the note; a chip's menu offers "Merge with…" for the common
/// diarization-over-segmentation fix. See docs/research/speaker-labeling.md §3.2/§2.5.
struct SpeakerTurnsView: View {
    let noteId: Int64
    let segments: [NoteSegmentWithSpeaker]
    let youDisplayName: String
    /// Extra names offered as one-tap choices in the rename field, on top of the note's calendar
    /// attendees (`Store.nameSuggestions(forNote:)`). Choices only: a name is applied when tapped.
    var nameSuggestions: [String] = []
    @Environment(AppModel.self) private var model
    /// The speaker id currently in a rename text field, or nil when none is being edited.
    @State private var renamingSpeakerId: Int64?
    @State private var renameText = ""
    /// Which speakers' menus offer "Remember <name>'s voice" (checked against the note's audio on disk).
    @State private var voiceAvailability: [Int64: RememberVoiceAvailability] = [:]
    /// The note's calendar attendees, read once when the transcript appears; empty if not linked to a meeting.
    @State private var attendeeNames: [String] = []

    /// Distinct speakers appearing in `segments`, in first-appearance order — the merge menu's
    /// "Merge with…" list excludes the speaker itself.
    private var distinctSpeakers: [NoteSpeaker] {
        var seen = Set<Int64>()
        var ordered: [NoteSpeaker] = []
        for entry in segments {
            guard let speaker = entry.speaker, let id = speaker.id, !seen.contains(id) else { continue }
            seen.insert(id)
            ordered.append(speaker)
        }
        return ordered
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            ForEach(segments) { entry in
                row(for: entry)
            }
        }
        .transition(.opacity)
        .task(id: noteId) {
            attendeeNames = (try? model.store.nameSuggestions(forNote: noteId)) ?? []
        }
        .task(id: availabilityKey) {
            voiceAvailability = model.speakerVoices.availability(of: distinctSpeakers, noteId: noteId)
        }
    }


    private func row(for entry: NoteSegmentWithSpeaker) -> some View {
        let others: [NoteSpeaker] = entry.speaker.map { speaker in
            distinctSpeakers.filter { $0.id != speaker.id }
        } ?? []
        return SpeakerTurnRow(
            entry: entry, youDisplayName: youDisplayName, otherSpeakers: others,
            isRenaming: renamingSpeakerId == entry.speaker?.id, renameText: $renameText,
            onStartRename: startRename, onCommitRename: commitRename,
            onCancelRename: { renamingSpeakerId = nil },
            onMerge: merge, onConfirmVoiceSuggestion: confirmSuggestion,
            onDismissVoiceSuggestion: dismissSuggestion,
            suggestedVoiceName: suggestedVoiceName(for: entry.speaker),
            nameSuggestions: nameChoices, voice: voiceAccess(for: entry.speaker),
            onPickSuggestion: pickSuggestion)
    }

    private var nameChoices: [String] {
        var seen = Set<String>()
        return (nameSuggestions + attendeeNames).filter { seen.insert($0).inserted }
    }

    private func startRename(_ speaker: NoteSpeaker) {
        renamingSpeakerId = speaker.id
        renameText = speaker.displayLabel
    }

    private func commitRename(_ speaker: NoteSpeaker) {
        guard let id = speaker.id else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { model.library.renameSpeaker(id: id, to: trimmed) }
        renamingSpeakerId = nil
    }

    /// A one-tap suggested name is an explicit choice by the user, so it renames like typing it would.
    private func pickSuggestion(_ speaker: NoteSpeaker, _ name: String) {
        guard let id = speaker.id else { return }
        model.library.renameSpeaker(id: id, to: name)
        renamingSpeakerId = nil
    }

    private func merge(_ source: NoteSpeaker, _ target: NoteSpeaker) {
        guard let sourceId = source.id, let targetId = target.id else { return }
        model.library.mergeSpeakers(sourceId: sourceId, intoTargetId: targetId)
    }

    private func confirmSuggestion(_ speaker: NoteSpeaker) {
        guard let id = speaker.id,
              let voiceId = model.library.confirmSpeakerVoiceSuggestion(speakerId: id) else { return }
        Task { await model.speakerVoices.reinforce(speakerId: id, voiceId: voiceId) }
    }

    private func dismissSuggestion(_ speaker: NoteSpeaker) {
        guard let id = speaker.id else { return }
        model.library.dismissSpeakerVoiceSuggestion(speakerId: id)
    }

    private func suggestedVoiceName(for speaker: NoteSpeaker?) -> String? {
        guard let voiceId = speaker?.suggestedVoiceId else { return nil }
        return model.library.voices().first { $0.id == voiceId }?.name
    }

    /// Changes whenever a rename or link could change what the chip menu should offer.
    private var availabilityKey: [String] {
        distinctSpeakers.map { "\($0.id ?? 0)|\($0.displayName ?? "")|\($0.voiceId ?? 0)" }
    }

    private func voiceAccess(for speaker: NoteSpeaker?) -> SpeakerVoiceAccess {
        guard let speaker, let id = speaker.id else { return SpeakerVoiceAccess() }
        let controller = model.speakerVoices
        return SpeakerVoiceAccess(
            availability: voiceAvailability[id] ?? .hidden,
            flow: controller.flow(for: id),
            onRequest: { controller.request(speakerId: id) },
            onRemember: { Task { await controller.confirm(speakerId: id) } },
            onCancel: { controller.cancel(speakerId: id) })
    }
}

/// One speaker turn: a colored, clickable name chip (or an inline rename field while editing)
/// plus the turn's text, and — when a voice-signature match is pending — a quiet "Is this Dana?"
/// suggestion banner (Pro; see `Store.suggestSpeakerVoice`'s "suggest, never auto-name" contract).
struct SpeakerTurnRow: View {
    let entry: NoteSegmentWithSpeaker
    let youDisplayName: String
    let otherSpeakers: [NoteSpeaker]
    let isRenaming: Bool
    @Binding var renameText: String
    let onStartRename: (NoteSpeaker) -> Void
    let onCommitRename: (NoteSpeaker) -> Void
    let onCancelRename: () -> Void
    let onMerge: (_ source: NoteSpeaker, _ target: NoteSpeaker) -> Void
    let onConfirmVoiceSuggestion: (NoteSpeaker) -> Void
    let onDismissVoiceSuggestion: (NoteSpeaker) -> Void
    let suggestedVoiceName: String?
    let nameSuggestions: [String]
    let voice: SpeakerVoiceAccess
    let onPickSuggestion: (NoteSpeaker, String) -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let speaker = entry.speaker {
                if isRenaming {
                    TextField("Speaker name", text: $renameText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .focused($fieldFocused)
                        .onSubmit { onCommitRename(speaker) }
                        .onExitCommand { onCancelRename() }
                        .onAppear { fieldFocused = true }
                        .frame(maxWidth: 220, alignment: .leading)
                    NameSuggestionRow(names: nameSuggestions) { onPickSuggestion(speaker, $0) }
                } else {
                    HStack(spacing: 6) {
                        SpeakerChip(speaker: speaker, youDisplayName: youDisplayName) { onStartRename(speaker) }
                        if speaker.voiceId != nil {
                            Image(systemName: "waveform")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                                .help("Hushy remembers this voice")
                                .accessibilityLabel("Voice remembered")
                        }
                    }
                        .contextMenu {
                            Button("Rename…") { onStartRename(speaker) }
                            rememberVoiceItem(for: speaker)
                            if !otherSpeakers.isEmpty {
                                Menu("Merge with…") {
                                    ForEach(otherSpeakers) { other in
                                        Button(other.displayLabel) { onMerge(speaker, other) }
                                    }
                                }
                            }
                        }
                }
                RememberVoiceRow(
                    name: speaker.displayLabel, flow: voice.flow,
                    onRemember: voice.onRemember, onCancel: voice.onCancel)
                if let suggestedVoiceName {
                    VoiceSuggestionBanner(
                        speakerLabel: speaker.displayLabel, suggestedName: suggestedVoiceName,
                        onConfirm: { onConfirmVoiceSuggestion(speaker) },
                        onDismiss: { onDismissVoiceSuggestion(speaker) })
                }
            } else {
                Text("Unknown speaker")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.4)
            }
            Text(entry.segment.text)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(5)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SpeakerTurnRow {
    /// The chip-menu item for learning this speaker's voice: absent unless it can work, and an
    /// explained, disabled item when the note's recording is gone.
    @ViewBuilder
    fileprivate func rememberVoiceItem(for speaker: NoteSpeaker) -> some View {
        switch voice.availability {
        case .available:
            Button("Remember \(speaker.displayLabel)'s voice…") { voice.onRequest() }
        case .audioGone:
            Button("Can't remember this voice: recording deleted") {}
                .disabled(true)
                .help(RememberVoiceAvailability.audioGoneMessage)
        case .hidden:
            EmptyView()
        }
    }
}

/// A colored, clickable name chip for one speaker. "You" (a mic-channel speaker, or a speaker
/// linked to the enrolled `isYou` voice) renders in phosphor rather than the rotating palette, so
/// the note owner is always visually distinct from meeting counterparties.
struct SpeakerChip: View {
    let speaker: NoteSpeaker
    let youDisplayName: String
    var action: (() -> Void)?

    private var isYou: Bool { speaker.label == "You" || speaker.displayName == youDisplayName }

    private var color: Color {
        guard !isYou, let id = speaker.id else { return Theme.phosphor }
        let index = SpeakerColorAssignment.colorIndex(forSpeakerId: id, paletteSize: Theme.speakerColors.count)
        return Theme.speakerColors[index]
    }

    var body: some View {
        Button(action: { action?() }) {
            Text(speaker.displayLabel)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(color.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .help("Click to rename")
    }
}

/// The Pro voice-signature match banner: "Is this Dana?" with Confirm/Not them controls. Per
/// docs/research/speaker-labeling.md §2.6, this is the *only* place a remembered voice's name is
/// ever surfaced, and it is always a question, never an assertion.
private struct VoiceSuggestionBanner: View {
    let speakerLabel: String
    let suggestedName: String
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            Text("Is this \(suggestedName)?")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Button("Yes", action: onConfirm)
                .buttonStyle(.link)
                .font(.system(size: 12, weight: .medium))
            Button("Not them", action: onDismiss)
                .buttonStyle(.link)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bgSunken))
    }
}
