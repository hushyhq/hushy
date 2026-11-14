import Foundation
import MurmurCore

/// The writing and exporting steps: one summary over the assembled turns, then the exports, each only while the note
/// is still stored (an Erase confirmed meanwhile wins).
extension FinalizeRunner {
    /// Writing, exporting and the end status in one call, for a note whose turns are in: ready when it has turns or
    /// audio, failed when it has neither. Nil when the note was deleted or erased meanwhile.
    func summarizeAndFinalize(_ note: Note) async -> Note? {
        guard var written = await write(note), let id = written.id else { return nil }
        let journal = try? store.captureJournal(noteId: id)
        let hasTurns = !(written.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        written.status = hasTurns || (journal?.hasAudioFrames ?? false) ? .ready : .failed
        do {
            guard try store.setNoteStatus(id: id, written.status) else { return nil }
        } catch {
            log.error("saving note status failed: \(error.localizedDescription)")
        }
        if written.status == .ready { export(written) }
        return written
    }

    /// The summary, title, action items and language, written in one update. Nil when the note is gone.
    func write(_ note: Note) async -> Note? {
        var note = (note.id.flatMap { try? store.note(id: $0) }) ?? note
        let turns = note.id.flatMap { try? store.transcript(noteId: $0) } ?? NoteTranscript(turns: [])
        note = note.caching(turns)
        if settings.speechLanguageMode == .automatic {
            note.language = LanguageDetector.detect(turns.plainText)?.code
        }
        await foreground?.waitUntilIdle(pollInterval: .milliseconds(50))
        let digest = await summarize(turns.rendered, note.title)
        note.title = titleAfterSummary(for: note, digestTitle: digest.title)
        note.summary = digest.summary
        note.setActionItems(from: digest)
        do {
            guard let saved = try store.update(note) else {
                log.notice("note was deleted before its summary was saved; nothing written")
                return nil
            }
            return saved.caching(turns)
        } catch {
            log.error("saving the summary failed: \(error.localizedDescription)")
            return note
        }
    }

    /// Markdown and Apple Notes, each when it is on and the note is still stored.
    func export(_ note: Note) {
        guard let id = note.id else { return }
        let turns = (try? store.transcript(noteId: id)) ?? NoteTranscript(turns: [])
        let done = (try? store.doneActionItemIndexes(noteId: id)) ?? []
        if settings.exportNotesToMarkdown, isStillStored(note, before: "Markdown") {
            do { try MarkdownExporter.export(note, transcript: turns, to: settings.exportDirectory, done: done) }
            catch { log.error("exporting note failed: \(error.localizedDescription)") }
        }
        if settings.saveNotesToAppleNotes, isStillStored(note, before: "Apple Notes") {
            do { try AppleNotesExporter.export(note, transcript: turns, done: done, using: appleNotesScripter) }
            catch { log.error("saving note to Apple Notes failed: \(error.localizedDescription)") }
        }
    }

    /// Whether the note is still in the store, asked right before an export. A store that cannot be read counts as
    /// stored, so a read error never costs a person their export.
    private func isStillStored(_ note: Note, before export: String) -> Bool {
        beforeExport?(export)
        guard let id = note.id else { return true }
        do {
            guard try store.note(id: id) != nil else {
                log.notice("note was erased before its \(export, privacy: .public) export; nothing exported")
                return false
            }
            return true
        } catch {
            log.error("could not check the note before its \(export, privacy: .public) export: \(error.localizedDescription)")
            return true
        }
    }

    /// A note named from its calendar meeting keeps the title the store holds; every other note takes the summary's.
    private func titleAfterSummary(for note: Note, digestTitle: String) -> String {
        guard let id = note.id, (try? store.calendarLink(forNote: id)) != nil else { return digestTitle }
        return (try? store.note(id: id))?.title ?? note.title
    }
}
