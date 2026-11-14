import Foundation

public struct Revert: Sendable, Equatable {
    public let swap: VocabularySwap
    public let typed: String
    public init(swap: VocabularySwap, typed: String) { self.swap = swap; self.typed = typed }
}

public enum RevertDetector {
    public static func split(_ alignment: CorrectionAlignment, swaps: [VocabularySwap]) -> (reverts: [Revert], rest: CorrectionAlignment) {
        var reverts: [Revert] = []
        let edits = alignment.edits.filter { edit in
            guard let swap = swaps.first(where: {
                $0.writtenKey == VocabularySwap.key(edit.before.joined(separator: " ")) &&
                $0.heardKey == VocabularySwap.key(edit.after.joined(separator: " "))
            }) else { return true }
            reverts.append(Revert(swap: swap, typed: edit.after.joined(separator: " ")))
            return false
        }
        let surface = alignment.surfaceChanges.filter { change in
            guard let swap = swaps.first(where: {
                $0.heardKey == $0.writtenKey
                    && change.before.trimmingCharacters(in: .punctuationCharacters) == $0.written.trimmingCharacters(in: .punctuationCharacters)
                    && change.after.trimmingCharacters(in: .punctuationCharacters) == $0.heard.trimmingCharacters(in: .punctuationCharacters)
            }) else { return true }
            reverts.append(Revert(swap: swap, typed: change.after))
            return false
        }
        var rest = CorrectionAlignment(inserted: alignment.inserted, edited: alignment.edited, edits: edits, surfaceChanges: surface)
        rest.continuesAfter = alignment.continuesAfter
        return (reverts, rest)
    }
}
