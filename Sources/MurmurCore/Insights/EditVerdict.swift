import Foundation

/// Decides whether pasted text survived untouched, from the field's contents a little later.
///
/// Only the verdict is kept; the field contents are read on-device and discarded.
public enum EditVerdict {
    /// - Returns: `.kept` if the text is still there verbatim, `.edited` if most of its words are
    ///   still there but it changed, or nil when we can't tell (e.g. a chat message was sent and
    ///   the box emptied, or the field isn't readable).
    public static func judge(inserted: String, fieldValue: String?) -> Dictation.EditState? {
        guard let fieldValue, !inserted.isEmpty else { return nil }
        if fieldValue.contains(inserted) { return .kept }
        let insertedWords = EvalMetrics.normalizedWords(inserted)
        guard insertedWords.count >= 3 else { return nil }
        let fieldWords = Set(EvalMetrics.normalizedWords(fieldValue))
        let surviving = insertedWords.filter { fieldWords.contains($0) }.count
        let share = Double(surviving) / Double(insertedWords.count)
        // Mostly still there but not verbatim: the user fixed something. Mostly gone: unknown.
        return share >= 0.5 ? .edited : nil
    }

    /// Share of judged dictations the user didn't have to touch.
    public static func editFreeRate(_ dictations: [Dictation]) -> Double? {
        let judged = dictations.compactMap(\.editState)
        guard !judged.isEmpty else { return nil }
        return Double(judged.filter { $0 == .kept }.count) / Double(judged.count)
    }
}
