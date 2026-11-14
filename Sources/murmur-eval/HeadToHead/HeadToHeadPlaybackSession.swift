import Foundation

/// The pure, hardware-free state machine behind `murmur-eval head-to-head play`: given an
/// ordered list of cases (slot id -> WAV path) and a stream of capture events (paste received,
/// hotkey pressed, silence timeout fired), decides when to advance, what to persist, and what
/// the finished output looks like. Kept separate from `HeadToHeadPlaybackRunner.swift` (which
/// does the actual audio playback and HTTP serving) so the sequencing logic — the part most
/// likely to have an off-by-one — is unit testable without a real capture window or WAV files.
struct HeadToHeadPlaybackSession: Sendable {
    /// One clip to play, keyed the same way as `HeadToHeadTemplate.Slot.id` so the recorded
    /// output round-trips through `head-to-head build` unchanged.
    struct Case: Equatable, Sendable {
        let id: String
        let audioPath: String
    }

    /// Founder-driven signals the capture window (or a test) can send.
    enum Event: Equatable, Sendable {
        /// The capture page received a paste and the text stabilised (no further input for
        /// `pasteSettleDelay`) — the normal "app finished pasting" signal.
        case textCaptured(String)
        /// The founder pressed the advance hotkey, e.g. because the app never pasted anything
        /// for this slot and they want to move on (recorded as empty and flagged).
        case skip
        /// No text arrived within `silenceTimeout` of the clip finishing playback.
        case silenceTimeout
    }

    /// What the runner should do after processing an event.
    enum Action: Equatable, Sendable {
        /// Save this text for the current case, then play the next clip (or finish).
        case saveAndAdvance(caseID: String, text: String)
        /// Nothing arrived in time; record an empty slot (so `build` reports it as missing
        /// rather than silently dropping it) and move on.
        case advanceEmpty(caseID: String)
        case finished
    }

    /// One case's outcome, in case order, for writing the `filled.md` output.
    struct Result: Equatable, Sendable {
        let caseID: String
        let text: String
    }

    private let cases: [Case]
    private(set) var results: [Result] = []
    private var index = 0

    init(cases: [Case]) {
        self.cases = cases
    }

    var isFinished: Bool { index >= cases.count }
    var currentCase: Case? { isFinished ? nil : cases[index] }
    var remaining: Int { max(0, cases.count - index) }

    /// Advances the state machine by one event for the current case. Calling this after
    /// `isFinished` is a programmer error (asserts in debug, no-ops in release) since the
    /// runner should stop pulling clips once `currentCase` is nil.
    mutating func handle(_ event: Event) -> Action {
        guard let current = currentCase else {
            assertionFailure("handle(_:) called after the session finished")
            return .finished
        }
        let text: String
        switch event {
        case .textCaptured(let captured):
            text = captured.trimmingCharacters(in: .whitespacesAndNewlines)
        case .skip, .silenceTimeout:
            text = ""
        }
        results.append(Result(caseID: current.id, text: text))
        index += 1
        if text.isEmpty { return .advanceEmpty(caseID: current.id) }
        return .saveAndAdvance(caseID: current.id, text: text)
    }

    /// Renders results as a `filled.md` document — the same `## <id>` heading format
    /// `HeadToHeadTemplate.parse` reads, so `murmur-eval head-to-head build` consumes this file
    /// unchanged, whichever product's capture window produced it.
    func renderFilledMarkdown(product: String) -> String {
        var lines = ["# Head-to-head dictation — \(product) (captured via virtual mic)", ""]
        for result in results {
            lines.append("## \(result.caseID)")
            lines.append("")
            lines.append(result.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func renderFilledMarkdown(_ results: [Result], product: String) -> String {
        var session = HeadToHeadPlaybackSession(cases: [])
        session.results = results
        return session.renderFilledMarkdown(product: product)
    }
}
