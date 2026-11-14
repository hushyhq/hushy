import Foundation

/// Finds where a pasted dictation sits inside a (possibly very long) field, without aligning the
/// dictation against the whole field.
///
/// Algorithm (seed, chain, then align; the same shape as read mappers use on genomes):
/// 1. Index the dictation's k-grams (k = 3 from 8 words, else 2) in a dictionary from the packed
///    ids to their positions. Tokens are interned to small integers first, so a k-gram is one
///    `UInt64`, not a string.
/// 2. Scan the field once. Every k-gram that also occurs in the dictation is an anchor hit
///    `(field position j, dictation position p)`. A hit lies on diagonal `d = j - p`; the true
///    placement has most of its hits on nearly one diagonal (edits shift it by a few tokens).
/// 3. Count hits per diagonal band (width `bandWidth`, on two grids offset by half a band so no
///    cluster is split by a boundary). The few best bands are scored by the longest chain of hits
///    that rises in both j and p (longest increasing subsequence, patience sorting). The best chain
///    wins; a tie goes to the later position (the latest paste is the likeliest one).
/// 4. The chain gives the window: its first hit's diagonal to its last hit's end, plus a margin.
///    The caller runs the exact LCS only inside that window, preferring matches near the chain's
///    diagonal when several alignments are equally long.
///
/// Time O(n + m + H log H + w^2) for a field of n tokens, a dictation of m, H anchor hits (at most
/// `maxPositionsPerGram` per field position) and a window of w = O(m) tokens; memory O(m + H + w^2).
/// A whole-field LCS is O(n x m) time and memory.
enum FieldAnchorLocator {
    /// Most dictation positions kept per k-gram, so a repeated phrase cannot flood the hits.
    static let maxPositionsPerGram = 4
    /// Bands examined with the longest-chain score, best vote count first.
    static let candidateBands = 3
    /// Interned ids must fit 21 bits to pack three into a `UInt64`.
    static let idLimit = 1 << 21

    /// The k-gram length for a dictation of `words` tokens; nil when it is too short to anchor.
    static func gramLength(words: Int) -> Int? {
        if words >= 8 { return 3 }
        if words >= 4 { return 2 }
        return nil
    }

    /// Where to align: the field tokens `range`, and the diagonal (`field position - dictation
    /// position`, in field coordinates) that the anchor chain lies on. Among equally long alignments
    /// the LCS prefers matches near that diagonal, so a common word elsewhere cannot stand in for
    /// the dictation's own word.
    struct Window: Equatable {
        let range: Range<Int>
        let diagonal: Int
    }

    /// The window worth aligning the dictation against, or nil when no anchor was found. `inserted`
    /// and `field` are interned token ids; -1 never matches.
    static func window(inserted: [Int32], field: [Int32]) -> Window? {
        let m = inserted.count, n = field.count
        guard let k = gramLength(words: m), n >= k else { return nil }

        var grams: [UInt64: [Int32]] = [:]
        for p in 0...(m - k) {
            guard let key = pack(inserted, at: p, length: k) else { continue }
            if (grams[key]?.count ?? 0) < maxPositionsPerGram { grams[key, default: []].append(Int32(p)) }
        }
        guard !grams.isEmpty else { return nil }

        // Anchor hits, in field order; positions of one gram stay ascending.
        var hitField: [Int32] = [], hitInserted: [Int32] = []
        for j in 0...(n - k) where field[j] >= 0 {
            guard let key = pack(field, at: j, length: k), let positions = grams[key] else { continue }
            for p in positions { hitField.append(Int32(j)); hitInserted.append(p) }
        }
        guard !hitField.isEmpty else { return nil }

        let width = bandWidth(words: m)
        let candidates = bestBands(hitField: hitField, hitInserted: hitInserted, width: width)
        var best: (length: Int, lower: Int, chain: [Int])?
        for band in candidates {
            let members = (0..<hitField.count).filter { band.contains(Int(hitField[$0]) - Int(hitInserted[$0])) }
            let chain = longestChain(members, hitField: hitField, hitInserted: hitInserted)
            if best == nil || chain.count > best!.length || (chain.count == best!.length && band.lower > best!.lower) {
                best = (chain.count, band.lower, chain)
            }
        }
        guard let chain = best?.chain, let first = chain.first, let last = chain.last else { return nil }
        let margin = windowMargin(words: m)
        let start = Int(hitField[first]) - Int(hitInserted[first])
        let end = Int(hitField[last]) + (m - Int(hitInserted[last]))   // exclusive end of the dictation's expected span
        let lower = max(0, start - margin), upper = min(n, end + margin)
        guard lower < upper else { return nil }
        let diagonals = chain.map { Int(hitField[$0]) - Int(hitInserted[$0]) }
        return Window(range: lower..<upper, diagonal: (diagonals.min()! + diagonals.max()!) / 2)
    }

    static func bandWidth(words: Int) -> Int { max(16, words / 2) }
    static func windowMargin(words: Int) -> Int { max(8, words / 4) }

    private struct Band {
        let lower: Int   // first diagonal in the band
        let width: Int
        func contains(_ diagonal: Int) -> Bool { diagonal >= lower && diagonal < lower + width }
    }

    /// The most voted bands over two half-offset grids; ties go to the higher (later) diagonal.
    private static func bestBands(hitField: [Int32], hitInserted: [Int32], width: Int) -> [Band] {
        let half = width / 2
        var votes: [Int: Int] = [:]   // key: grid * 2^40 + bin index (offset to stay positive)
        let bias = 1 << 30
        for index in 0..<hitField.count {
            let diagonal = Int(hitField[index]) - Int(hitInserted[index])
            for grid in 0..<2 {
                let bin = floorDiv(diagonal + grid * half, width)
                votes[grid << 40 | (bin + bias), default: 0] += 1
            }
        }
        let bands = votes.map { entry -> (votes: Int, band: Band) in
            let grid = entry.key >> 40, bin = (entry.key & ((1 << 40) - 1)) - bias
            return (entry.value, Band(lower: bin * width - grid * half, width: width))
        }
        return bands
            .sorted { $0.votes != $1.votes ? $0.votes > $1.votes : $0.band.lower > $1.band.lower }
            .prefix(candidateBands).map(\.band)
    }

    /// Indices (into the hit arrays) of the longest chain rising in both field and dictation
    /// position. `members` are in field order; hits at one field position are taken by descending
    /// dictation position so a position cannot appear twice in a chain.
    private static func longestChain(_ members: [Int], hitField: [Int32], hitInserted: [Int32]) -> [Int] {
        let ordered = members.sorted {
            hitField[$0] != hitField[$1] ? hitField[$0] < hitField[$1] : hitInserted[$0] > hitInserted[$1]
        }
        var tails: [Int] = []   // tails[len-1] = index of the smallest-p hit ending a chain of that length
        var previous = [Int](repeating: -1, count: ordered.count)
        for (slot, hit) in ordered.enumerated() {
            let p = hitInserted[hit]
            var low = 0, high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if hitInserted[ordered[tails[mid]]] < p { low = mid + 1 } else { high = mid }
            }
            previous[slot] = low > 0 ? tails[low - 1] : -1
            if low == tails.count { tails.append(slot) } else { tails[low] = slot }
        }
        var chain: [Int] = []
        var slot = tails.last ?? -1
        while slot >= 0 { chain.append(ordered[slot]); slot = previous[slot] }
        return Array(chain.reversed())
    }

    /// `length` ids from `ids[at...]` packed into one `UInt64`; nil if any is -1 (never matches).
    private static func pack(_ ids: [Int32], at: Int, length: Int) -> UInt64? {
        var key: UInt64 = 0
        for offset in 0..<length {
            let id = ids[at + offset]
            if id < 0 { return nil }
            key = key << 21 | UInt64(id)
        }
        return key
    }

    private static func floorDiv(_ a: Int, _ b: Int) -> Int {
        a >= 0 ? a / b : -((-a + b - 1) / b)
    }
}
