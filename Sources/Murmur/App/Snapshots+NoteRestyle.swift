import MurmurCore
import SwiftUI

/// Restyle a note after the fact (`nr-*`, light and dark): an invented memo's page as written, while Professional is
/// written (the text blurred under its label), and after, shown as Professional with Undo and Back to Refined.
/// `HUSHY_SNAPSHOT_ONLY=nr-` renders just these. The Professional text is written here by hand for the still; it is not
/// a model's output.
extension Snapshots {
    private static let memoBody = """
        Okay so quick note for the team offsite. We will not book the boat this year, it was too expensive last time. \
        Marta is sorting out the bus and she said we need 14 seats, so can everyone confirm by Thursday. Also lunch \
        is at the farm place again, the one near the lake, and I'll send the address later.
        """

    private static let memoProfessional = """
        A quick note on the team offsite. We will not book the boat this year, as it was too expensive last time. \
        Marta is arranging the bus and needs 14 seats, so please confirm your place by Thursday. Lunch will again be \
        at the farm restaurant near the lake; I will send the address later.
        """

    static func renderNoteRestyle(model: AppModel, size: CGSize, directory: URL) async {
        guard FeatureFlags.meetings, wantsAny(prefix: "nr-"), let note = seedMemo(into: model.store, now: model.dayClock.now),
              let id = note.id else { return }
        try? await Task.sleep(for: .seconds(1))
        model.section = .notes
        model.selectedNoteID = id
        model.settings.assistantCollapsed = true
        let written = NoteStyleState(body: note.transcript)
        let professional = written.showing(.professional, text: memoProfessional)
        let states: [(String, NoteRestyleModel.Page)] = [
            ("nr-before", .init(state: written, phase: .idle)),
            ("nr-during", .init(state: written, phase: .rewriting(.professional))),
            ("nr-after", .init(state: professional, phase: .idle)),
            ("nr-kept", .init(state: written, phase: .notice(NoteRestyleCopy.kept(.wouldChangeMeaning)))),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (name, page) in states {
                model.noteStyles.pinForSnapshot(page, noteId: id)
                await capture(MainView().environment(model), name: name, scheme: scheme, size: size, directory: directory)
            }
        }
        model.noteStyles.forget(noteId: id)
        model.selectedNoteID = nil
        model.settings.assistantCollapsed = false
    }

    /// One memo as the recorder leaves it: started by hand, one voice, ready, an hour old (so no stage track).
    private static func seedMemo(into store: Store, now: Date) -> Note? {
        let started = now.addingTimeInterval(-3_600)
        var note = Note(title: "Offsite plan", createdAt: started, updatedAt: started.addingTimeInterval(70),
                        durationSeconds: 64, status: .ready)
        guard let saved = try? store.save(note), let id = saved.id else { return nil }
        note = saved
        note.audioPath = AppPaths.notesAudioDirectory.appendingPathComponent("\(id)", isDirectory: true).path
        note.summary = "- No boat this year\n- Marta needs 14 seats for the bus, confirm by Thursday"
        note = (try? store.save(note)) ?? note
        try? store.replaceTurns(noteId: id, turns: [
            NoteTurn(noteId: id, ordinal: 0, stream: .mic, t0: 0, t1: 64, text: memoBody, origin: .capture),
        ])
        return (try? store.note(id: id)) ?? note
    }
}
