import MurmurCore
import SwiftUI

/// Everything the live screen shows, as a value: the app builds it from `NoteRecorder` every
/// second, snapshots build it from a fixture.
struct LiveMeetingState {
    var note: Note
    var startedAt: Date
    var capture: MeetingCapture
    var progress: MeetingTranscriptProgress
    var turns: [NoteRecorder.LiveTurn]
    var jots: [MeetingJot]
    var consent: MeetingConsent?

    @MainActor
    static func from(_ recorder: NoteRecorder, jots: [MeetingJot], consent: MeetingConsent?, now: Date) -> LiveMeetingState? {
        guard let note = recorder.activeNote else { return nil }
        let startedAt = note.createdAt
        return LiveMeetingState(
            note: note, startedAt: startedAt,
            capture: recorder.capture ?? MeetingCapture(startedAt: startedAt, isCapturingCall: recorder.isCapturingSystemAudio),
            progress: MeetingTranscriptProgress(
                recordedSeconds: now.timeIntervalSince(startedAt), transcribedSeconds: recorder.transcribedSeconds,
                chunkSeconds: NoteRecorder.chunkSeconds),
            turns: recorder.liveTurns, jots: jots, consent: consent)
    }
}

/// During the meeting. The page is a notepad, as in Granola: the person writes what only they
/// noticed, and each line is stamped with its moment. Around it, quietly: a dark instrument strip
/// that says the recording is on and both sides are coming through, the one-tap way to tell the
/// others, and the transcript as it is written down (wet ink until the page is made).
struct MeetingLiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    let state: LiveMeetingState
    /// Fixed for snapshots; nil means the real clock.
    var now: Date?
    @State private var draft = ""
    @FocusState private var notepadFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            MeetingInstrumentStrip(state: state, now: now)
            if let warning = state.capture.warning(now: now ?? Date()) {
                MeetingCaptureWarning(warning: warning)
            }
            HStack(alignment: .top, spacing: 0) {
                notepad
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Rectangle().fill(Theme.hairline).frame(width: 0.5)
                MeetingLiveTranscript(state: state, now: now)
                    .frame(width: 320)
            }
        }
        .background(Theme.bgBase)
        .onAppear { notepadFocused = true }
    }

    private var notepad: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.note.title).font(.system(size: 30, weight: .regular, design: .serif)).foregroundStyle(Theme.textPrimary)
                Text("Write only what you want to remember. Hushy hears the rest.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            }
            MeetingConsentBar(noteId: state.note.id, consent: state.consent)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(state.jots) { jot in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        AuthorMark(author: .you)
                        if jot.isQuestion || jot.isDecision {
                            Text(jot.isQuestion ? "?" : "!").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.phosphor)
                        }
                        Text(jot.shownText).font(.system(size: 15)).foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let at = jot.atSeconds {
                            Text(MeetingMoment.clock(at)).font(.system(size: 11, design: .monospaced).monospacedDigit())
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                field
            }
            Spacer(minLength: 0)
            Text("Tip: start a line with “?” for a question, “!” for a decision. Lines stay yours; Hushy never rewrites them.")
                .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, Theme.Space.xxl + 8)
        .padding(.top, Theme.Space.xl)
        .padding(.bottom, Theme.Space.l)
    }

    @ViewBuilder
    private var field: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            RoundedRectangle(cornerRadius: 1).fill(Theme.hairlineStrong).frame(width: 3, height: 14)
            if isSnapshot {
                SnapshotTextField(draft, placeholder: "Type a note and press Return…", font: .system(size: 15))
            } else {
                TextField("Type a note and press Return…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($notepadFocused)
                    .onSubmit(keepLine)
            }
        }
    }

    private func keepLine() {
        guard let id = state.note.id else { return }
        model.meetings.addJot(noteId: id, text: draft, atSeconds: model.recorder.elapsedSeconds)
        draft = ""
    }
}

/// The always-dark strip across the top while recording: the live dot and clock, both sides of
/// the call with whether each is heard, and Stop. Dark in both themes, like the pill: it is the
/// instrument, not the page.
private struct MeetingInstrumentStrip: View {
    @Environment(AppModel.self) private var model
    let state: LiveMeetingState
    let now: Date?

    var body: some View {
        if let now {
            content(now: now)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in content(now: context.date) }
        }
    }

    private func content(now: Date) -> some View {
        HStack(spacing: Theme.Space.l) {
            HStack(spacing: 8) {
                Circle().fill(Theme.phosphorFill).frame(width: 9, height: 9)
                    .shadow(color: Theme.phosphorFill.opacity(0.8), radius: 5)
                Text("Recording").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(MeetingMoment.clock(now.timeIntervalSince(state.startedAt)))
                    .font(.system(size: 13, design: .monospaced).monospacedDigit()).foregroundStyle(.white.opacity(0.8))
            }
            Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 16)
            CaptureSideBadge(title: "You", signal: state.capture.signal(.microphone, now: now))
            CaptureSideBadge(title: "Call", signal: state.capture.signal(.call, now: now))
            Spacer()
            Text("On this Mac only").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            Button("Stop") { model.toggleNoteRecording() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(".", modifiers: .command)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, 40)
        .padding(.bottom, Theme.Space.m)
        .background(Color(hex: 0x111317))
        .environment(\.colorScheme, .dark)
    }
}

private struct MeetingCaptureWarning: View {
    let warning: MeetingCapture.Warning

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(warning.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(warning.detail).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.m)
        .background(Theme.warning.opacity(0.12))
    }
}

/// The transcript as it is written down, both sides, raw (wet ink). It says how far it has got
/// instead of pretending to be live to the second.
private struct MeetingLiveTranscript: View {
    @Environment(\.isSnapshot) private var isSnapshot
    let state: LiveMeetingState
    let now: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Eyebrow("Transcript")
                Spacer()
                if let now { progress(now) } else {
                    TimelineView(.periodic(from: .now, by: 1)) { progress($0.date) }
                }
            }
            if state.turns.isEmpty {
                Text("The first lines appear about 30 seconds in. Each part is written down on your Mac as you go.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            }
            turnList
        }
        .padding(Theme.Space.l)
        .padding(.top, Theme.Space.s)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bgSunken.opacity(0.35))
    }

    private func progress(_ date: Date) -> some View {
        let progress = MeetingTranscriptProgress(
            recordedSeconds: date.timeIntervalSince(state.startedAt), transcribedSeconds: state.progress.transcribedSeconds,
            chunkSeconds: state.progress.chunkSeconds)
        return Text(progress.line).font(.system(size: 11)).foregroundStyle(Theme.working)
    }

    @ViewBuilder
    private var turnList: some View {
        let list = VStack(alignment: .leading, spacing: Theme.Space.m) {
            ForEach(state.turns.suffix(isSnapshot ? 6 : 200)) { turn in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(turn.side == .you ? "You" : "Call").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(turn.side == .you ? Theme.textPrimary : Theme.speakerColors[0])
                        Text(MeetingMoment.clock(turn.startSeconds)).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Text(turn.text).font(.system(size: 13)).foregroundStyle(Theme.textTertiary).lineSpacing(3)
                }
                .id(turn.id)
            }
        }
        if isSnapshot {
            list
        } else {
            ScrollViewReader { proxy in
                ScrollView { list.frame(maxWidth: .infinity, alignment: .leading) }
                    .onChange(of: state.turns.count) { _, _ in
                        if let last = state.turns.last { withAnimation(Theme.settle) { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
            }
        }
    }
}

/// "Tell them": the second half of consent. One tap copies a short, true notice for the meeting
/// chat; or the person says it and taps that. The choice is kept with the meeting.
struct MeetingConsentBar: View {
    @Environment(AppModel.self) private var model
    let noteId: Int64?
    let consent: MeetingConsent?

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: consent == nil ? "person.wave.2" : "checkmark.seal.fill")
                .font(.system(size: 13))
                .foregroundStyle(consent == nil ? Theme.phosphor : Theme.success)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(consent?.summary ?? "Let the others know you're recording")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text(consent == nil ? "A line for the chat saying it stays on your Mac and trains nothing."
                         : "Kept with this meeting.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                }
                if consent == nil { actions }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.m)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(consent == nil ? Theme.phosphorTint : Theme.bgSunken.opacity(0.6)))
    }

    private var actions: some View {
        HStack(spacing: Theme.Space.s) {
            if model.meetings.noticeCopied {
                Text("Copied. Paste it in the chat, then").font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                Button("I pasted it") {
                    if let noteId { model.meetings.recordConsent(noteId: noteId, method: .chatMessage) }
                }
                .buttonStyle(PrimaryButtonStyle())
            } else {
                Button("Copy notice for chat") { model.meetings.copyConsentNotice() }
                    .buttonStyle(PrimaryButtonStyle())
                Button("I said it") {
                    if let noteId { model.meetings.recordConsent(noteId: noteId, method: .saidAloud) }
                }
                .buttonStyle(SecondaryButtonStyle())
                .help(MeetingConsent.spokenLine)
            }
        }
    }
}
