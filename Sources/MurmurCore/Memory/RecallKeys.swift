import Foundation

/// What term recall compares for one term or one transcript run. `MemoryIndex` computes it once
/// per term and `TermRecall` once per run, so no key is rebuilt inside the term × run loop.
struct RecallKeys: Sendable, Equatable {
    /// The comparison key with its spaces removed ("terra form" and "terraform" are one word here).
    let joined: String
    let phonetic: String
    private let letters: [Character]
    private let skeleton: [Character]
    private let letterTally: LetterTally
    private let skeletonTally: LetterTally

    init(key: String) {
        joined = key.replacingOccurrences(of: " ", with: "")
        phonetic = ContextSpellingFixer.phoneticKey(joined)
        letters = Array(joined)
        skeleton = Array(CorrectionClassifier.skeleton(joined))
        letterTally = LetterTally(letters)
        skeletonTally = LetterTally(skeleton)
    }

    /// The same answer as `CorrectionClassifier.soundsAlike(joined, term.joined)`, from the stored
    /// keys. An edit distance is worked out only when its floor leaves a match possible, which
    /// rules out most pairs with a few integer operations.
    func soundsLike(_ term: RecallKeys) -> Bool {
        guard !letters.isEmpty, !term.letters.isEmpty else { return false }
        if Self.isWithin(CorrectionClassifier.alikeWordRatio, letters, letterTally, term.letters, term.letterTally) { return true }
        guard skeleton.count >= 2, letters.first == term.letters.first || skeleton.first == term.skeleton.first
        else { return false }
        return Self.isWithin(CorrectionClassifier.alikeSkeletonRatio, skeleton, skeletonTally, term.skeleton, term.skeletonTally)
    }

    /// Whether the edit distance is at most `ratio` of the longer side.
    private static func isWithin(_ ratio: Double, _ a: [Character], _ aTally: LetterTally,
                                 _ b: [Character], _ bTally: LetterTally) -> Bool {
        let longer = Double(max(a.count, b.count))
        guard Double(aTally.floor(to: bTally)) / longer <= ratio else { return false }
        return Double(CorrectionClassifier.levenshtein(a, b)) / longer <= ratio
    }
}

/// How long a string is and how many of each letter it holds: enough for a floor on the edit
/// distance to another string without comparing the two letter by letter.
private struct LetterTally: Sendable, Equatable {
    private let length: Int
    /// A four-bit count per letter group, sixteen groups to a word. A count stops at 7, which
    /// leaves the top bit of each field free for the subtraction in `excess`.
    private let low: UInt64
    private let high: UInt64

    init(_ characters: [Character]) {
        var words: [UInt64] = [0, 0]
        for character in characters {
            let group = Self.group(character)
            let shift = UInt64(group % 16) * 4
            if (words[group / 16] >> shift) & 0xF < 7 { words[group / 16] += 1 << shift }
        }
        length = characters.count
        low = words[0]
        high = words[1]
    }

    /// An edit distance is never below the difference in length, nor below the number of letters
    /// one side holds that the other has no match for. Stopping a count at 7, or putting several
    /// letters in one group, can only hide a difference, so this stays a floor.
    func floor(to other: LetterTally) -> Int {
        max(abs(length - other.length),
            Self.excess(low, over: other.low) + Self.excess(high, over: other.high),
            Self.excess(other.low, over: low) + Self.excess(other.high, over: high))
    }

    /// The sum over the sixteen fields of how far a's count is above b's.
    private static func excess(_ a: UInt64, over b: UInt64) -> Int {
        let top: UInt64 = 0x8888_8888_8888_8888
        // Each field becomes 8 + a − b: the top bit survives only where a is not below b.
        let difference = (a | top) &- b
        let positive = difference & (((difference & top) >> 3) &* 7)
        let pairs = (positive & 0x0F0F_0F0F_0F0F_0F0F) &+ ((positive >> 4) & 0x0F0F_0F0F_0F0F_0F0F)
        return Int((pairs &* 0x0101_0101_0101_0101) >> 56)
    }

    /// a–z each alone, then one group for digits, one for the apostrophe, one for anything else.
    private static func group(_ character: Character) -> Int {
        guard let ascii = character.asciiValue else { return 28 }
        switch ascii {
        case 97...122: return Int(ascii) - 97
        case 48...57: return 26
        case 39: return 27
        default: return 28
        }
    }
}
