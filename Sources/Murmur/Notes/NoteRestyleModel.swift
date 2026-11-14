import Foundation
import MurmurCore
import Observation
import os

/// The note page's restyle (`NoteRestyle`): which style each open note is shown in, the rewrite in progress, and Undo.
/// The rewrite runs on the cleanup model at utility priority, only while nothing is being dictated or recorded, and
/// stops between pieces the moment that changes. A note's text is never logged; the log line carries counts.
@MainActor
@Observable
final class NoteRestyleModel {
    enum Phase: Equatable {
        case idle
        /// The text is covered while this style is written.
        case rewriting(RestyleStyle)
        /// The last request kept the text as it was; the line says why.
        case notice(String)
    }

    struct Page: Equatable {
        var state: NoteStyleState
        var phase: Phase
    }

    private(set) var pages: [Int64: Page] = [:]
    @ObservationIgnored private let model: any LanguageModel
    @ObservationIgnored private let isCapturing: @MainActor () -> Bool
    @ObservationIgnored private let notesDirectory: URL
    @ObservationIgnored private var runs: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "app.hushy", category: "note-restyle")

    /// - Parameter isCapturing: true while a dictation or a recording is under way; a rewrite neither starts nor
    ///   continues then.
    init(model: any LanguageModel, isCapturing: @escaping @MainActor () -> Bool,
         notesDirectory: URL = AppPaths.notesAudioDirectory) {
        self.model = model
        self.isCapturing = isCapturing
        self.notesDirectory = notesDirectory
    }

    /// The page for `note`, as last loaded; a note never loaded reads as written.
    func page(for note: Note) -> Page {
        guard let id = note.id, let page = pages[id], page.state.fits(note.transcript) else {
            return Page(state: NoteStyleState(body: note.transcript), phase: .idle)
        }
        return page
    }

    /// The text the page shows for `note`.
    func text(for note: Note) -> String { page(for: note).state.text(body: note.transcript) }

    /// Reads the note's saved style from its folder (once per note and text).
    func load(_ note: Note) {
        guard let id = note.id, pages[id]?.state.fits(note.transcript) != true else { return }
        let state = file(for: note)?.read(body: note.transcript) ?? NoteStyleState(body: note.transcript)
        pages[id] = Page(state: state, phase: .idle)
    }

    /// Shows `note` in `style`: at once when that version exists (Refined always does), else after the model writes
    /// it. Anything the guard refuses keeps the text as it was and says why.
    func pick(_ style: RestyleStyle, for note: Note) {
        guard let id = note.id else { return }
        load(note)
        guard var page = pages[id], page.phase != .rewriting(style) else { return }
        if page.state.hasVersion(style) {
            runs[id]?.cancel()
            page.state = page.state.showing(style)
            page.phase = .idle
            commit(page, for: note)
            return
        }
        guard !isCapturing() else {
            pages[id]?.phase = .notice(NoteRestyleCopy.paused)
            return
        }
        runs[id]?.cancel()
        pages[id]?.phase = .rewriting(style)
        let body = note.transcript
        let model = model
        let started = ContinuousClock.now
        runs[id] = Task(priority: .utility) { [weak self] in
            let outcome = await NoteRestyle.restyle(body, as: style, model: model, shouldContinue: { [weak self] in
                guard !Task.isCancelled else { return false }
                return await MainActor.run { !(self?.isCapturing() ?? true) }
            })
            guard !Task.isCancelled else { return }
            self?.finish(outcome, style: style, note: note, started: started)
        }
    }

    /// Esc or Stop: the rewrite ends and the text stays as it is.
    func stop(_ note: Note) {
        guard let id = note.id, case .rewriting = pages[id]?.phase else { return }
        runs[id]?.cancel()
        runs[id] = nil
        pages[id]?.phase = .idle
    }

    func undo(_ note: Note) {
        guard let id = note.id else { return }
        load(note)
        guard var page = pages[id], page.state.canUndo else { return }
        runs[id]?.cancel()
        page.state = page.state.undone()
        page.phase = .idle
        commit(page, for: note)
    }

    /// The note was deleted: its rewrite stops and its page is dropped (the file went with the note's folder).
    func forget(noteId: Int64) {
        runs[noteId]?.cancel()
        runs[noteId] = nil
        pages[noteId] = nil
    }

    /// Snapshots show a page in a fixed state; nothing is read or written.
    func pinForSnapshot(_ page: Page, noteId: Int64) {
        pages[noteId] = page
    }

    private func finish(_ outcome: NoteRestyle.Outcome, style: RestyleStyle, note: Note, started: ContinuousClock.Instant) {
        guard let id = note.id, var page = pages[id], page.phase == .rewriting(style) else { return }
        runs[id] = nil
        log.notice("note restyle: style=\(style.rawValue, privacy: .public) outcome=\(Self.code(outcome), privacy: .public) chars=\(note.transcript.count) ms=\(Int(ModelPace.ms(ContinuousClock.now - started)))")
        switch outcome {
        case .rewritten(let text):
            page.state = page.state.showing(style, text: text)
            page.phase = .idle
            commit(page, for: note)
        case .kept(let why):
            pages[id]?.phase = .notice(NoteRestyleCopy.kept(why))
        case .paused:
            pages[id]?.phase = .notice(NoteRestyleCopy.paused)
        case .tooLong:
            pages[id]?.phase = .notice(NoteRestyleCopy.tooLong)
        }
    }

    /// Shows `page` and saves it beside the note. A failed save keeps it for this session and logs the failure.
    private func commit(_ page: Page, for note: Note) {
        guard let id = note.id else { return }
        pages[id] = page
        do {
            try file(for: note)?.write(page.state)
        } catch {
            log.error("note restyle: saving the style failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func file(for note: Note) -> NoteStyleFile? {
        NoteStyleFile(note: note, notesDirectory: notesDirectory)
    }

    private static func code(_ outcome: NoteRestyle.Outcome) -> String {
        switch outcome {
        case .rewritten: "rewritten"
        case .kept(let why): "kept-\(why.rawValue)"
        case .paused: "paused"
        case .tooLong: "too-long"
        }
    }
}
