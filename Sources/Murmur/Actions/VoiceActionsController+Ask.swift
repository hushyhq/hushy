import AppKit
import Foundation
import MurmurCore

/// The ask flows: an AI hand-off, an answer from your own stuff, a screen summary, and the
/// answer card's controls (Copy, Save as note, Open source, Open in Assistant, the failure
/// card's offer, Close) plus the voice follow-up thread.
extension VoiceActionsController {
    // MARK: Ask an AI

    /// "Ask Claude …": a Tier-1 hand-off. The link is built from a fixed template and act first
    /// unless "Ask before doing" says otherwise. The done chip stays honest until that service's
    /// `linkSubmitsAutomatically` flag is verified by hand.
    func handOff(service: AIHandoffLink.Service, question: String, utterance: String) async {
        guard let link = AIHandoffLink.build(service: service, question: question) else {
            pill.state = .error("Nothing to ask \(service.displayName)")
            return
        }
        let action = ProposedAction(kind: .openLink, title: link.summary, url: link.url.absoluteString, sourceText: utterance)
        await dispatch([action], utterance: utterance)
    }

    // MARK: Ask about your own stuff

    func askOwn(_ question: String, thread: [AskTurn]) async {
        let epoch = utteranceEpoch
        var card = AnswerCardState(question: question, phase: .thinking, thread: thread)
        pill.state = .answer(card)
        let sources = answerer.sources + (searchesAppleNotes() ? [optionalSource].compactMap { $0 } : [])
        let answerer = sources.count == self.answerer.sources.count ? self.answerer : OwnStuffAnswerer(sources: sources)
        let result = await answerer.answer(question, thread: thread, context: .current())
        // The user may have closed the card or moved on while the model worked.
        guard !Task.isCancelled, epoch == utteranceEpoch,
              case .answer(let showing) = pill.state, showing.question == question, showing.isThinking else { return }
        switch result {
        case .success(let answer):
            card.phase = .answer(Self.content(for: answer))
            countUse(.ask)
        case .failure(.notFound(let message, let suggestion)):
            card.phase = .failure(.init(message: message, suggestion: searchesAppleNotes() ? nil : suggestion))
        case .failure(.sourcesDontSay(let message)):
            card.phase = .failure(.init(message: message, suggestion: nil))
        }
        pill.state = .answer(card)
    }

    static func content(for answer: AskAnswer) -> AnswerCardState.AnswerContent {
        let source = answer.source
        var label = "From \(source.sourceLabel())"
        if let date = source.dateLabel() { label += " · \(date)" }
        let link: AnswerCardState.AnswerContent.SourceLink? = source.openURL.map { url in
            if url.scheme == "hushy", url.host == "note", let id = Int64(url.lastPathComponent) { return .note(id: id) }
            return .url(url)
        }
        return .init(text: answer.text, items: answer.items, sourceLabel: label, sourceLink: link)
    }

    /// The thread the next turn continues: the card's earlier turns plus its current answer.
    static func thread(after card: AnswerCardState?) -> [AskTurn] {
        guard let card else { return [] }
        var thread = card.thread
        if let answer = card.answer {
            let text = ([answer.text] + answer.items).filter { !$0.isEmpty }.joined(separator: "; ")
            thread.append(AskTurn(question: card.question, answer: text))
        }
        return thread
    }

    /// A follow-up the question rules did not take: "add coffee" after a grocery answer is a Do in
    /// the thread's context (the cited list names the reminders list). The model decides whether
    /// it is a Do; when it is not, the thread continues as a question (`extractAndDispatchInThread`).
    /// No rule here decides it is a question.
    func followUpDo(_ transcript: String, after card: AnswerCardState) async {
        if pickFile(transcript, after: card) { return }
        if let request = Self.recognisedOpen(transcript) {
            await dispatch(Self.openAction(request, utterance: transcript), utterance: transcript)
        } else {
            await extractAndDispatchInThread(transcript, listHint: Self.listName(cited: card), card: card)
        }
    }

    private func extractAndDispatchInThread(_ transcript: String, listHint: String?, card: AnswerCardState) async {
        var restored = card
        restored.phase = card.answer.map { .answer($0) } ?? .thinking
        // Keep the card while the extractor thinks; if it turns out not to be a command, the
        // thread continues as a question instead of pasting anything.
        let epoch = utteranceEpoch
        let output = await runExtraction(transcript)
        // Cancelled (esc) or replaced by a newer utterance while the extractor thought: nothing
        // is dispatched and the pill is left alone, as on the ordinary path.
        guard !Task.isCancelled, epoch == utteranceEpoch else { return }
        switch output.result {
        case .actions(var actions):
            if let listHint {
                for index in actions.indices where actions[index].kind == .createReminder && actions[index].listName == nil {
                    actions[index].listName = listHint
                }
            }
            await dispatch(actions, utterance: transcript)
        case .refused(let refusal):
            pill.state = .error(refusal.message)
        case .notAnAction, .rejected, .modelUnavailable:
            await askOwn(transcript, thread: Self.thread(after: restored))
        }
    }

    /// The Reminders list (or note) the card's answer came from, for "add coffee".
    static func listName(cited card: AnswerCardState) -> String? {
        guard let answer = card.answer, !answer.isScreenSummary else { return nil }
        let label = answer.sourceLabel
        guard let range = label.range(of: "Reminders list '") ?? label.range(of: "note '") else { return nil }
        let rest = label[range.upperBound...]
        guard let close = rest.firstIndex(of: "'") else { return nil }
        return String(rest[..<close])
    }

    // MARK: Summarize this

    func summarizeScreen(focus: String?, utterance: String) async {
        let epoch = utteranceEpoch
        var card = AnswerCardState(question: utterance, phase: .thinking)
        pill.state = .answer(card)
        guard let window = ScreenTextReader.frontWindowText() else {
            card.phase = .failure(.init(
                message: "I couldn't read this window. Hushy needs Accessibility access, and some apps don't share their text.",
                suggestion: nil))
            pill.state = .answer(card)
            return
        }
        // Untrusted text: it goes to the summarizer only, never to the action extractor.
        let result = await summarizer.summarize(window.text, focus: focus)
        guard !Task.isCancelled, epoch == utteranceEpoch,
              case .answer(let showing) = pill.state, showing.isThinking else { return }
        switch result {
        case .success(let summary):
            let title = window.title.isEmpty ? window.appName : "\(window.appName) · \(window.title)"
            card.phase = .answer(.init(
                text: summary.gist, items: summary.points,
                sourceLabel: "\(title) (\(summary.wordCount.formatted()) words)", sourceLink: nil, isScreenSummary: true))
            countUse(.summary)
        case .failure(.nothingToRead), .failure(.tooShort):
            card.phase = .failure(.init(message: "There isn't enough text in this window to summarize.", suggestion: nil))
        case .failure(.modelUnavailable):
            card.phase = .failure(.init(message: "Summaries need Apple Intelligence or Hushy's local model.", suggestion: nil))
        case .failure(.modelFailed):
            card.phase = .failure(.init(message: "The model didn't answer in time. Try again?", suggestion: nil))
        }
        pill.state = .answer(card)
    }

    // MARK: The card's controls

    /// Copy: "Copied", then the card collapses back to the pill.
    func copyAnswer() {
        guard case .answer(var card) = pill.state, card.answer != nil else { return }
        TextInserter.copy(card.copyText)
        card.copied = true
        pill.state = .answer(card)
    }

    func saveAnswerAsNote() {
        guard case .answer(let card) = pill.state, let answer = card.answer else { return }
        let note = Note(
            title: card.question.prefix(1).uppercased() + card.question.dropFirst(),
            transcript: card.copyText, summary: answer.text, actionItems: answer.items, status: .ready)
        do {
            _ = try store.save(note)
            pill.state = .actionDone(DoneChipState(title: "Saved as note", detail: note.title, kind: .openLink))
        } catch {
            log.error("saving the answer as a note failed: \(error.localizedDescription)")
            pill.state = .error("Couldn't save the note")
        }
    }

    func openAnswerSource() {
        guard case .answer(let card) = pill.state, let link = card.answer?.sourceLink else { return }
        switch link {
        case .note(let id): onOpenNote?(id)
        case .url(let url): NSWorkspace.shared.open(url)
        }
        pill.state = .idle
    }

    /// The thread as text, for the Assistant's draft: the user reads it and sends it themselves.
    func openAnswerInAssistant() {
        guard case .answer(let card) = pill.state else { return }
        var lines = card.thread.flatMap { ["Q: \($0.question)", "A: \($0.answer)"] }
        lines.append("Q: \(card.question)")
        if card.answer != nil { lines.append("A: \(card.copyText)") }
        onOpenInAssistant?(lines.joined(separator: "\n"))
        pill.state = .idle
    }

    /// The failure card's offer ("Search Apple Notes?"): turns Apple Notes on, then asks again. If
    /// access is refused the card stays and says why, in `AppleNotesAccessNotice`'s words.
    func takeAnswerSuggestion() {
        guard case .answer(let card) = pill.state else { return }
        if case .failure(let failure) = card.phase, failure.retriesAction {
            retryAction(card.question)
            return
        }
        let result = enableAppleNotes()
        guard result.isGranted else {
            pill.state = .answer(card.refusedNotesAccess(result))
            return
        }
        Task { await askOwn(card.question, thread: card.thread) }
    }

    func closeAnswer() {
        guard case .answer = pill.state else { return }
        pill.state = .idle
    }

    /// The footer's follow-up control: the same as holding the chord.
    func followUpFromButton() {
        guard case .answer = pill.state else { return }
        toggleFromButton()
    }
}
