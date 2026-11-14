import AppKit
import MurmurCore
import SwiftUI

/// Snapshot captures for naming speakers by voice (all `voices-*`): the consent line and its states,
/// a pending "Is this Dana?" question, a speaker named by a confirmed match, the rename field with
/// attendee choices, and the remembered-voices list. Everything is built from plain values with invented
/// names: no audio, no models, no stored voice. The chip's context menu itself (the "Remember …'s voice…"
/// item) is an NSMenu, which `ImageRenderer` cannot draw. Fast loop: `HUSHY_SNAPSHOT_ONLY=voices-`.
@MainActor
enum VoicesSnapshots {
    typealias Capture = LearnedSnapshots.Capture

    private static let size = CGSize(width: 640, height: 150)

    static func render(model: AppModel, size listSize: CGSize, capture: Capture) async {
        await renderTurns(model: model, capture: capture)
        await renderList(model: model, size: listSize, capture: capture)
    }

    private static func speaker(
        _ label: String, name: String? = nil, voiceId: Int64? = nil, suggested: Int64? = nil
    ) -> NoteSpeaker {
        NoteSpeaker(
            id: 7, noteId: 1, label: label, displayName: name, voiceId: voiceId,
            suggestedVoiceId: suggested, suggestedSimilarity: suggested == nil ? nil : 0.82)
    }

    private static let line = "Okay, so the rollout moves to the first week of March and I will own the checklist."

    private static func row(
        _ speaker: NoteSpeaker, voice: SpeakerVoiceAccess = SpeakerVoiceAccess(), suggested: String? = nil,
        renaming: Bool = false, choices: [String] = []
    ) -> AnyView {
        let entry = NoteSegmentWithSpeaker(
            segment: NoteSegment(id: 1, noteId: 1, speakerId: 7, startTime: 0, endTime: 8, text: line, ordinal: 0),
            speaker: speaker)
        return AnyView(
            SpeakerTurnRow(
                entry: entry, youDisplayName: "Alex", otherSpeakers: [], isRenaming: renaming,
                renameText: .constant(speaker.displayName ?? ""), onStartRename: { _ in }, onCommitRename: { _ in },
                onCancelRename: {}, onMerge: { _, _ in }, onConfirmVoiceSuggestion: { _ in },
                onDismissVoiceSuggestion: { _ in }, suggestedVoiceName: suggested, nameSuggestions: choices,
                voice: voice, onPickSuggestion: { _, _ in })
            .padding(Theme.Space.xl)
            .background(Theme.bgBase))
    }

    private static func renderTurns(model: AppModel, capture: Capture) async {
        let named = speaker("Speaker 2", name: "Dana")
        func access(_ flow: RememberVoiceFlow) -> SpeakerVoiceAccess {
            SpeakerVoiceAccess(availability: .available, flow: flow)
        }
        await capture(row(named, voice: access(.asking)), "voices-consent", size, true)
        await capture(row(named, voice: access(.working)), "voices-working", size, true)
        let linked = speaker("Speaker 2", name: "Dana", voiceId: 3)
        await capture(row(linked, voice: SpeakerVoiceAccess(flow: .remembered)), "voices-remembered", size, true)
        let tooShort = RememberVoiceFlow.declined(SpeakerVoiceSampling.tooLittleMessage)
        await capture(row(named, voice: access(tooShort)), "voices-declined", size, true)
        await capture(row(speaker("Speaker 3", suggested: 3), suggested: "Dana"), "voices-suggestion", size, true)
        await capture(row(linked), "voices-applied", size, true)
        await capture(
            row(speaker("Speaker 4"), renaming: true, choices: ["Dana Whitfield", "Marcus Oyelaran", "Priya Raman"]),
            "voices-rename-choices", CGSize(width: 640, height: 190), true)
    }

    private static func renderList(model: AppModel, size: CGSize, capture: Capture) async {
        let now = Date()
        let voices = [
            Voice(id: 1, name: "Alex", isYou: true, encryptedEmbedding: Data(), sampleCount: 6, updatedAt: now),
            Voice(id: 2, name: "Dana Whitfield", encryptedEmbedding: Data(), sampleCount: 3,
                  updatedAt: now.addingTimeInterval(-3 * 86_400)),
            Voice(id: 3, name: "Marcus Oyelaran", encryptedEmbedding: Data(), sampleCount: 1,
                  updatedAt: now.addingTimeInterval(-9 * 86_400)),
        ]
        let list = { (items: [Voice]) in
            AnyView(VoicesListView(voices: items).environment(model).padding(Theme.Space.xl).background(Theme.bgBase))
        }
        await capture(list(voices), "voices-list", CGSize(width: 720, height: 460), true)
        await capture(list([]), "voices-list-empty", CGSize(width: 720, height: 300), true)
    }
}
