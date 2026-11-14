import Foundation

/// Narrow structural edits; deleted content never becomes a writing preference.
public enum StyleEditSignals {
    static let greetingMarker = "<greeting>"

    public static func split(_ alignment: CorrectionAlignment) -> (events: [CorrectionEvent], rest: CorrectionAlignment) {
        var events: [CorrectionEvent] = []
        let edits = alignment.edits.filter { edit in
            guard edit.after.isEmpty, (1...2).contains(edit.before.count),
                  let first = edit.before.first,
                  ["hi", "hey", "hello", "dear"].contains(CorrectionAlignment.key(first)),
                  alignment.inserted.starts(with: edit.before),
                  edit.before.count == 1 || edit.before[1].first?.isUppercase == true
            else { return true }
            events.append(CorrectionEvent(kind: .formatting, before: greetingMarker, after: ""))
            return false
        }
        var rest = CorrectionAlignment(inserted: alignment.inserted, edited: alignment.edited,
                                       edits: edits, surfaceChanges: alignment.surfaceChanges)
        rest.continuesAfter = alignment.continuesAfter
        return (events, rest)
    }
}
