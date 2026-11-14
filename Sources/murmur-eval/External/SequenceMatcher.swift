import Foundation

/// A port of Python's `difflib.SequenceMatcher` (Ratcliff/Obershelp "Gestalt pattern matching")
/// with `isjunk=None, autojunk=False` — the configuration DRES's scorer uses
/// (`utils_evaluate.build_alignment_df`). Only `matchingBlocks` and `opcodes` are ported; both
/// follow CPython's `Lib/difflib.py` step by step (including its tie-breaking: the earliest,
/// longest block wins), so an alignment here is the alignment the paper's Python produced.
///
/// With no junk and no auto-junk, CPython's junk-extension loops in `find_longest_match` can
/// never fire, so they are omitted.
struct SequenceMatcher {
    struct Block: Equatable {
        let a: Int
        let b: Int
        let size: Int
    }

    enum Tag: String {
        case equal, delete, insert, replace
    }

    struct Opcode: Equatable {
        let tag: Tag
        let i1: Int, i2: Int, j1: Int, j2: Int
    }

    let a: [String]
    let b: [String]
    /// b's elements → the ascending indices where they occur (CPython's `b2j`).
    private let b2j: [String: [Int]]

    init(_ a: [String], _ b: [String]) {
        self.a = a
        self.b = b
        var b2j: [String: [Int]] = [:]
        for (index, element) in b.enumerated() { b2j[element, default: []].append(index) }
        self.b2j = b2j
    }

    /// Longest matching block in a[alo..<ahi] and b[blo..<bhi]; among equal lengths, the one that
    /// starts earliest in `a`, then earliest in `b` (CPython's `k > bestsize` scan order).
    func findLongestMatch(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> Block {
        var besti = alo, bestj = blo, bestsize = 0
        var j2len: [Int: Int] = [:]
        for i in alo..<max(alo, ahi) {
            var newj2len: [Int: Int] = [:]
            for j in b2j[a[i]] ?? [] {
                if j < blo { continue }
                if j >= bhi { break }
                let k = (j2len[j - 1] ?? 0) + 1
                newj2len[j] = k
                if k > bestsize {
                    besti = i - k + 1
                    bestj = j - k + 1
                    bestsize = k
                }
            }
            j2len = newj2len
        }
        return Block(a: besti, b: bestj, size: bestsize)
    }

    /// CPython's `get_matching_blocks`: recursive longest matches, sorted, adjacent blocks
    /// collapsed, terminated by the `(len(a), len(b), 0)` sentinel.
    var matchingBlocks: [Block] {
        var queue = [(0, a.count, 0, b.count)]
        var blocks: [Block] = []
        while let (alo, ahi, blo, bhi) = queue.popLast() {
            let match = findLongestMatch(alo, ahi, blo, bhi)
            guard match.size > 0 else { continue }
            blocks.append(match)
            if alo < match.a && blo < match.b { queue.append((alo, match.a, blo, match.b)) }
            if match.a + match.size < ahi && match.b + match.size < bhi {
                queue.append((match.a + match.size, ahi, match.b + match.size, bhi))
            }
        }
        blocks.sort { ($0.a, $0.b, $0.size) < ($1.a, $1.b, $1.size) }
        var collapsed: [Block] = []
        var i1 = 0, j1 = 0, k1 = 0
        for block in blocks {
            if i1 + k1 == block.a && j1 + k1 == block.b {
                k1 += block.size
            } else {
                if k1 > 0 { collapsed.append(Block(a: i1, b: j1, size: k1)) }
                (i1, j1, k1) = (block.a, block.b, block.size)
            }
        }
        if k1 > 0 { collapsed.append(Block(a: i1, b: j1, size: k1)) }
        collapsed.append(Block(a: a.count, b: b.count, size: 0))
        return collapsed
    }

    /// CPython's `get_opcodes`.
    var opcodes: [Opcode] {
        var i = 0, j = 0
        var answer: [Opcode] = []
        for block in matchingBlocks {
            let tag: Tag? =
                if i < block.a && j < block.b { .replace }
                else if i < block.a { .delete }
                else if j < block.b { .insert }
                else { nil }
            if let tag { answer.append(Opcode(tag: tag, i1: i, i2: block.a, j1: j, j2: block.b)) }
            i = block.a + block.size
            j = block.b + block.size
            if block.size > 0 { answer.append(Opcode(tag: .equal, i1: block.a, i2: i, j1: block.b, j2: j)) }
        }
        return answer
    }
}
