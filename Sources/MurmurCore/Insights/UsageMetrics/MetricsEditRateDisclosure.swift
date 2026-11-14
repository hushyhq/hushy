import Foundation

/// The words "See what's sent" uses for the edit rate, with an example line. One place, so the sheet and a
/// test agree, and the example is made by the real encoder so it cannot drift from what is sent.
public enum EditRateDisclosure {
    public static let title = "How often you edit what Hushy writes"
    public static var summary: String {
        "About \(Int(LearningReadSchedule.verdictOffset)) seconds after Hushy pastes a dictation, it looks once at the field to see whether "
            + "you changed the text. The words are read on this Mac and dropped. If you share usage numbers, only a count is kept: "
            + "kept as typed, edited (and whether you changed 1 to 2 words, 3 to 10 or more), field cleared, or not checked. "
            + "Counts are grouped by tone and by kind of app, such as Email or Code."
    }

    public static let exampleIntro = "One line of a day's batch looks like this:"

    /// A real row, encoded the way a batch encodes it.
    public static var exampleRow: String {
        var table = MetricsEditRateTable()
        if let key = try? MetricsEditRateKey(tone: .professional, appKind: .email, verdict: .edited, size: .words1to2) {
            for _ in 0..<4 { table.increment(key) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(table), let text = String(data: data, encoding: .utf8),
              text.hasPrefix("["), text.hasSuffix("]") else {
            return #"{"appKind":"email","count":4,"size":"words1to2","tone":"professional","verdict":"edited"}"#
        }
        return String(text.dropFirst().dropLast())
    }

    public static let exampleMeaning =
        "That says: 4 dictations in the Professional tone, pasted into an email app, were edited afterwards by 1 to 2 words. "
        + "It never says which app, who it was for, or what was changed."
}
