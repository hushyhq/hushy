import AppKit
import Foundation
import MurmurCore

/// "Find and fetch my resume": a typed query, a search of this Mac's Spotlight index, and an
/// honest answer on the pill: one file (shown in Finder), a short list to pick from, or plainly
/// nothing. Show in Finder and Open are the only effects. Nothing found is logged beyond a
/// payload-free outcome code (`FileFindOutcomeCode`); file contents are never read.
extension VoiceActionsController {
    // MARK: Routing entry points

    /// The rules decided: search for the typed query. One attempt: it reports one usage event (a
    /// category, never a name, path or word) unless it was cancelled (esc reports that, once, in
    /// `cancelProcessing`) or a newer utterance owns the pill, which then drops this answer.
    func findFile(_ request: FileRequest, utterance: String) async {
        let epoch = utteranceEpoch
        var card = AnswerCardState(question: utterance, phase: .thinking)
        card.thinkingLabel = FileCardText.searching
        pill.state = .answer(card)
        let outcome = await FileServices.engine.find(request)
        log.info("\(outcome.code.logLine, privacy: .public)")
        guard !Task.isCancelled, outcome.code != .cancelled, epoch == utteranceEpoch else { return }
        // The person may have closed the card or moved on while the search ran.
        guard case .answer(let showing) = pill.state, showing.question == utterance, showing.isThinking else { return }
        onMetric?(Self.metric(for: outcome))
        card.phase = present(outcome, request: request)
        pill.state = .answer(card)
    }

    /// The rules didn't decide ("where is my passport"): one model call fills the query; if it
    /// isn't a file request (or no model answers), it is an ordinary question about their stuff.
    func maybeFindFile(question: String, utterance: String, followUp: AnswerCardState?) async {
        let epoch = utteranceEpoch
        let request = await FileServices.extractor.extract(utterance)
        guard !Task.isCancelled, epoch == utteranceEpoch else { return }
        if let request {
            await findFile(request, utterance: utterance)
        } else {
            await askOwn(question, thread: Self.thread(after: followUp))
        }
    }

    /// The usage event for a finished search, in the existing categories: an answer is a success;
    /// nothing found is "not found"; the rest map by why the search could not run.
    static func metric(for outcome: FileFindOutcome) -> VoiceActionMetricEvent {
        switch outcome {
        case .foundOne, .foundSeveral: VoiceActionMetricEvent(outcome: .succeeded, failure: nil)
        case .none: VoiceActionMetricEvent(outcome: .failed, failure: .notFound)
        case .cancelled: VoiceActionMetricEvent(outcome: .cancelled, failure: nil)
        case .unavailable(let reason):
            switch reason {
            case .slow: VoiceActionMetricEvent(outcome: .failed, failure: .timedOut)
            case .folderNotReadable: VoiceActionMetricEvent(outcome: .failed, failure: .permissionDenied)
            case .indexOff, .failed: VoiceActionMetricEvent(outcome: .failed, failure: .backendFailed)
            }
        }
    }

    // MARK: Showing the outcome

    /// The card phase for an outcome; reveals or opens the one clear winner as a side effect.
    private func present(_ outcome: FileFindOutcome, request: FileRequest) -> AnswerCardState.Phase {
        switch outcome {
        case .foundOne(let file, let matchedBy):
            let row = fileRow(0, file)
            countUse(.ask)
            if matchedBy == .content {
                return .files(.init(text: FileCardText.mentionsOne, rows: [row]))
            }
            let effect = FileEffect.forOutcome(outcome, action: request.action)
            return .files(.init(text: perform(effect, path: row.path), rows: [row]))
        case .foundSeveral(let files, let matchedBy):
            countUse(.ask)
            let rows = files.enumerated().map { fileRow($0.offset, $0.element) }
            let text = matchedBy == .content
                ? (rows.count == 1 ? FileCardText.mentionsOne : FileCardText.mentionsSeveral)
                : FileCardText.severalMatches
            return .files(.init(text: text, rows: rows))
        case .none:
            return .failure(.init(message: FileCardText.nothing(in: request.query.location), suggestion: nil))
        case .unavailable(let reason):
            return .failure(.init(message: FileCardText.unavailable(reason), suggestion: nil))
        case .cancelled:
            return .failure(.init(message: FileCardText.nothing(in: nil), suggestion: nil))
        }
    }

    private func fileRow(_ id: Int, _ file: FileCandidate) -> FileRow {
        FileRow(id: id, candidate: file, home: FileServices.home.path)
    }

    // MARK: Show in Finder and Open

    /// A row's name click on the card (or the voice pick): show it in Finder.
    func revealFile(rowID: Int) { choose(rowID, open: false) }

    /// A row's Open button.
    func openFile(rowID: Int) { choose(rowID, open: true) }

    /// Acts on one row of the card and collapses the card to that file.
    private func choose(_ rowID: Int, open: Bool) {
        guard case .answer(var card) = pill.state, case .files(let content) = card.phase,
              let row = content.rows.first(where: { $0.id == rowID }) else { return }
        let text = perform(FileEffect.forChoice(path: row.path, open: open), path: row.path)
        card.phase = .files(.init(text: text, rows: [FileRow.single(row)]))
        pill.state = .answer(card)
    }

    /// Does the effect and returns what the card says about it. The file must still be there
    /// (the index can be behind). What to do is `FileEffect`'s decision, not this method's.
    private func perform(_ effect: FileEffect, path: String) -> String {
        let launcher = FileServices.launcher
        guard launcher.exists(path) else { return FileCardText.gone }
        switch effect {
        case .none:
            return ""
        case .open(let path):
            if launcher.open(path) {
                recordFileEffect(opened: true)
                return FileCardText.opening
            }
            launcher.reveal(path)
            recordFileEffect(opened: false)
            return FileCardText.showing
        case .reveal(let path, let instead):
            launcher.reveal(path)
            recordFileEffect(opened: false)
            return instead ? FileCardText.showingInsteadOfOpening : FileCardText.showing
        }
    }

    /// The History row for a file effect: what happened, with no name, path or words.
    private func recordFileEffect(opened: Bool) {
        let record = ActionRecord(
            kind: .openLink, title: opened ? "Opened a file" : "Showed a file in Finder", detail: "On this Mac",
            sourceText: "", status: .completed)
        do {
            _ = try store.save(record)
        } catch {
            log.error("history write failed: a file action record")
        }
    }

    // MARK: Picking by voice

    /// A spoken follow-up on the file list ("the first one", "the PDF", "the one from March",
    /// "open the second"). True when it was a pick (settled or said back), false when it should go
    /// on as an ordinary follow-up.
    func pickFile(_ transcript: String, after card: AnswerCardState) -> Bool {
        guard case .files(let content) = card.phase else { return false }
        let result = FilePick.resolve(transcript, rows: content.pickRows)
        var restored = card
        switch result {
        case .notAPick:
            return false
        case .picked(let index, let open):
            pill.state = .answer(restored)
            choose(content.rows[index].id, open: open)
        case .several:
            restored.phase = .files(.init(text: FileCardText.stillSeveral, rows: content.rows))
            pill.state = .answer(restored)
        case .noMatch:
            restored.phase = .files(.init(text: FileCardText.noneOfThese, rows: content.rows))
            pill.state = .answer(restored)
        }
        return true
    }
}

extension FileRow {
    /// This row alone, as the card's single result.
    static func single(_ row: FileRow) -> FileRow {
        FileRow(id: 0, path: row.path, name: row.name, folderPath: row.folderPath, shortFolder: row.shortFolder,
                dateLabel: row.dateLabel, kinds: row.kinds, modified: row.modified)
    }
}

/// The words on the card for a file request. Plain and short; no claim of accuracy.
enum FileCardText {
    static let searching = "Looking for your file…"
    static let showing = "Showing it in Finder."
    static let opening = "Opening it."
    static let showingInsteadOfOpening = "I don't open programs or scripts. Showing it in Finder."
    static let severalMatches = "I found a few. Which one?"
    static let mentionsOne = "No file has that name. This one mentions it."
    static let mentionsSeveral = "No file has that name. These mention it."
    static let gone = "That file isn't there anymore."
    static let stillSeveral = "More than one fits. Click the one you want."
    static let noneOfThese = "None of these fits. Click the one you want."

    static func nothing(in location: FileLocation?) -> String {
        guard let location else { return "I couldn't find a file like that." }
        return "I couldn't find a file like that in \(location.folderName)."
    }

    static func unavailable(_ reason: FileSearchUnavailable) -> String {
        switch reason {
        case .indexOff: "Spotlight isn't searching this Mac right now, so I can't look for files. You can turn it on in System Settings."
        case .folderNotReadable: "Hushy can't read that folder. You can allow it in System Settings, under Privacy & Security."
        case .slow: "The search took too long. Try again in a moment."
        case .failed: "I couldn't search for files just now."
        }
    }
}
