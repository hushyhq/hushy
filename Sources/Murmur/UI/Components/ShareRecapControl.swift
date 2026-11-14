import AppKit
import MurmurCore
import SwiftUI

/// "Share recap" in the note header: send colleagues what was decided and who does what, without
/// the transcript unless the box in the menu is ticked. Three ways out, none of which uploads
/// anything: the macOS share sheet (Mail, Messages, Slack, AirDrop, Notes … whatever the Mac
/// offers), a copy to the clipboard, and a new message in the user's mail app with no recipient.
/// Hushy never sends a message itself. The recap text is built by `MeetingRecap`.
struct ShareRecapControl: View {
    @Environment(AppModel.self) private var model
    let note: Note
    /// Off every time a note opens: the transcript only goes out when the user ticks it here.
    @State private var includeTranscript = false
    @State private var feedback: ShareRecapFeedback?
    @State private var anchor = ShareAnchor()

    var body: some View {
        if note.status == .ready {
            HStack(spacing: Theme.Space.xs) {
                if let feedback { ShareRecapFeedbackLabel(feedback: feedback) }
                Menu {
                    Button("Share…", systemImage: "square.and.arrow.up") { share() }.disabled(!hasRecap)
                    Button("Copy recap", systemImage: "doc.on.doc") { copy() }.disabled(!hasRecap)
                    Button("Email draft", systemImage: "envelope") { emailDraft() }.disabled(!hasRecap)
                    Divider()
                    Toggle("Include transcript", isOn: $includeTranscript)
                } label: {
                    ShareRecapLabel(isEnabled: hasRecap)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .background(ShareAnchorView(anchor: anchor))
                .help(hasRecap ? "Share the summary and action items. The transcript stays out unless you include it."
                               : "This note has no summary or action items to share yet.")
            }
        }
    }

    /// Whether anything would be shared with the current switch; checked without reading speakers.
    private var hasRecap: Bool { MeetingRecap.make(from: note, includeTranscript: includeTranscript) != nil }

    private func makeRecap() -> MeetingRecap? {
        let segments = note.id.flatMap { try? model.store.noteSegments(noteId: $0) } ?? []
        // Names show only where the note itself shows speakers (a Pro feature).
        let speakers = Entitlements.has(.speakerLabels) ? MeetingRecap.speakers(in: segments) : []
        let done = note.id.flatMap { model.library.doneActionItemsByNote[$0] } ?? []
        let turns = note.id.flatMap { try? model.store.transcript(noteId: $0) }
        return MeetingRecap.make(
            from: note, turns: turns, speakers: speakers, ownerName: model.settings.userName, doneItems: done,
            includeTranscript: includeTranscript)
    }

    private func report(_ new: ShareRecapFeedback) {
        withAnimation(Theme.fade) { feedback = new }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(Theme.fade) { if feedback == new { feedback = nil } }
        }
    }

    private func share() {
        guard let recap = makeRecap() else { return report(.nothingToShare) }
        anchor.present(recap)
    }

    private func copy() {
        guard let recap = makeRecap() else { return report(.nothingToShare) }
        RecapPasteboard.write(recap)
        report(.copied)
    }

    private func emailDraft() {
        guard let recap = makeRecap() else { return report(.nothingToShare) }
        report(RecapMailDraft.open(recap))
    }
}

/// What the control says after an action, in a line that clears itself.
enum ShareRecapFeedback: Equatable {
    case copied, draftOpened, copiedForDraft, noMailApp, nothingToShare

    var text: String {
        switch self {
        case .copied: "Copied"
        case .draftOpened: "Draft opened"
        case .copiedForDraft: "Too long for a draft: copied, paste it in"
        case .noMailApp: "No mail app found"
        case .nothingToShare: "Nothing to share yet"
        }
    }

    var isProblem: Bool { self == .noMailApp || self == .nothingToShare }
}

struct ShareRecapFeedbackLabel: View {
    let feedback: ShareRecapFeedback

    var body: some View {
        Label(feedback.text, systemImage: feedback.isProblem ? "exclamationmark.circle" : "checkmark")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(feedback.isProblem ? Theme.warning : Theme.success)
            .transition(.opacity)
    }
}

/// The closed control: a quiet text + icon chip like the other note actions.
struct ShareRecapLabel: View {
    var isEnabled = true
    @State private var hovering = false

    var body: some View {
        Label("Share recap", systemImage: "text.badge.checkmark")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(hovering && isEnabled ? Theme.textPrimary : Theme.textSecondary)
            .opacity(isEnabled ? 1 : 0.55)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(hovering && isEnabled ? Theme.selection : .clear))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(Theme.fade, value: hovering)
    }
}
