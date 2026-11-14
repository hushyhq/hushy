import Foundation
import MurmurCore
import os

private let lateLandingLog = Logger(subsystem: "app.hushy", category: "dictation")

/// What a finished dictation is handed to, and what is done to the clipboard when the second look finds the
/// paste missing. Live, the app's paster and the system clipboard; a test replaces both, so no test pastes into
/// an app or writes the real clipboard.
struct DictationDelivery {
    var deliver: @MainActor (_ text: String, _ target: FocusTarget, _ pressReturn: Bool) async -> TextInserter.Delivered
    var clipboard: LateLandingClipboard

    static let live = DictationDelivery(
        deliver: { await TextInserter.deliver($0, to: $1, pressReturn: $2) }, clipboard: .live)
}

struct LateLandingClipboard {
    /// False once something other than Hushy's paster has written the clipboard since the paste.
    var isUntouched: @MainActor () -> Bool
    var copy: @MainActor (String) -> Void

    static let live = LateLandingClipboard(
        isUntouched: { TextInserter.shared.isAsLastWritten }, copy: { TextInserter.shared.copyForManualPaste($0) })
}

extension DictationController {
    /// Starts the second look in the background and keeps it, so the next dictation can end it
    /// (`cancelLateLanding`). A look still running when another is handed over is ended first.
    func startLateLanding(_ look: @escaping @MainActor () async -> LateLanding, text: String, savedID: Int64?) {
        lateLandingTask?.cancel()
        lateLandingTask = Task { await self.settleLateLanding(look, text: text, savedID: savedID) }
    }

    /// A new dictation starts: a look still polling another app's field has nothing left to say that is worth
    /// its reads. It ends as unreadable, which changes nothing.
    func cancelLateLanding() {
        lateLandingTask?.cancel()
        lateLandingTask = nil
    }

    /// The second look at a paste into a field Hushy was sure of. The pill has already said Done; this reads the
    /// field again (counts only, never its text) and acts only when it was read, did not change, and no
    /// selection explains that (`LateLanding.notLanded`). Then the words stay recoverable the way an unconfirmed
    /// paste's do: History lists the row as not pasted, and the dictation goes on the clipboard with the same
    /// card the unconfirmed paste opens.
    ///
    /// The clipboard and the card are left alone while another dictation is under way (that one owns them) and
    /// when the person has copied something since the paste (that copy is theirs).
    func settleLateLanding(
        _ look: @MainActor () async -> LateLanding, text: String, savedID: Int64?, clipboard: LateLandingClipboard? = nil
    ) async {
        let clipboard = clipboard ?? delivery.clipboard
        guard await look() == .notLanded, !Task.isCancelled else { return }
        let keepsClipboard = isBusy || !clipboard.isUntouched()
        lateLandingLog.notice("late landing=not-landed delivery=pasted clipboard=\(keepsClipboard ? "unchanged" : "copied", privacy: .public)")
        if let savedID {
            do {
                try store.markUnlandedPaste(id: savedID)
                onSaved?()
            } catch {
                lateLandingLog.error("could not mark an unlanded paste: \(error.localizedDescription)")
            }
        }
        guard !keepsClipboard else { return }
        clipboard.copy(text)
        pill.present(.noField(.copiedAutomaticallyUnconfirmed), text: text)
    }
}
