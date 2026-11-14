import Foundation

public enum ReleaseSwaps {
    public static func apply(_ result: TranscriptionResult, keep: KeepHeardSet = .empty) -> (text: String, swaps: [VocabularySwap]) {
        guard let unboosted = result.unboosted else { return (result.text, []) }
        return VocabularySwaps.restore(from: unboosted, to: result.text, source: .boost, keeping: keep)
    }
}
