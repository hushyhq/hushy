import MurmurCore

/// The way to one dictation in History from outside it. The pill's password-field row never
/// shows its words, so its History button is the one place they can be read.
///
/// The pill has the text, not the row's id (the row is saved off the hot path, after the pill is
/// showing). The newest dictation with text is that row for as long as the pill row is up, so the
/// id is taken from it, and only when its text is the same.
enum HistoryRoute {
    /// The id of `last` when it is the dictation with this text, else nil (History then opens
    /// without a selection, rather than on the wrong item).
    static func itemID(matching text: String, last: Dictation?) -> Int64? {
        guard let last, last.text == text else { return nil }
        return last.id
    }
}

extension AppModel {
    /// The pill's route into the app's windows: one dictation in History.
    func installPillRoutes() {
        pill.onOpenInHistory = { [weak self] text in
            guard let self else { return }
            self.openHistory(selecting: HistoryRoute.itemID(matching: text, last: try? self.store.lastDictation()))
        }
    }

    /// Opens History on one dictation (`openHistoryItem(_:)` in `HistoryOpenRequest.swift`), or
    /// on nothing selected when the row could not be identified.
    func openHistory(selecting id: Int64?) {
        if let id {
            openHistoryItem(id)
        } else {
            section = .history
            openMainWindow()
        }
    }
}
