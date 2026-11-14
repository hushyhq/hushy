import Foundation

/// One in-memory vocabulary replacement. Never stores the surrounding dictation.
public struct VocabularySwap: Sendable, Equatable, Hashable {
    public enum Source: String, Sendable { case boost, screenSpelling, dictionaryName, installedName, productName, dictionaryAlias }
    public let heard: String
    public let written: String
    public let source: Source
    public var heardKey: String { Self.key(heard) }
    public var writtenKey: String { Self.key(written) }

    public init(heard: String, written: String, source: Source) {
        self.heard = heard
        self.written = written
        self.source = source
    }

    public static func key(_ text: String) -> String {
        CorrectionAlignment.tokens(text).map(CorrectionAlignment.key).joined(separator: " ")
    }
}

public enum VocabularySwaps {
    public static func diff(from before: String, to after: String, source: VocabularySwap.Source) -> [VocabularySwap] {
        restore(from: before, to: after, source: source, keeping: .empty).swaps
    }

    /// Restores only explicitly blocked replacements, preserving the new text's whitespace elsewhere.
    public static func restore(from before: String, to after: String, source: VocabularySwap.Source,
                               keeping keep: KeepHeardSet) -> (text: String, swaps: [VocabularySwap]) {
        guard before != after else { return (after, []) }
        let old = CorrectionAlignment.tokens(before).map(wordSurface)
        let new = CorrectionAlignment.tokens(after).map(wordSurface)
        let ranges = tokenRanges(after).map { wordRange(in: after, token: $0) }
        var swaps: [VocabularySwap] = []
        var replacements: [(Range<String.Index>, String)] = []
        var insertedIndex = 0
        for region in BoostGuard.align(old.map(CorrectionAlignment.key), new.map(CorrectionAlignment.key)) {
            if case .same(let range) = region {
                // Letter casing is a vocabulary change too (notion → Notion). Punctuation alone is not.
                for (offset, index) in range.enumerated() {
                    let heard = old[insertedIndex + offset], written = new[index]
                    guard heard != written, heard.lowercased() == written.lowercased() else { continue }
                    let swap = VocabularySwap(heard: heard, written: written, source: source)
                    if keep.blocks(heardKey: swap.heardKey, writtenKey: swap.writtenKey) {
                        replacements.append((ranges[index], heard))
                    } else { swaps.append(swap) }
                }
                insertedIndex += range.count
                continue
            }
            guard case .changed(let a, let b) = region else { continue }
            insertedIndex = a.upperBound
            let blocked = blockedReplacements(old: old, new: new, before: a, after: b, keep: keep)
            if !blocked.isEmpty {
                for (tokens, heard) in blocked {
                    replacements.append((ranges[tokens.lowerBound].lowerBound..<ranges[tokens.upperBound - 1].upperBound, heard))
                }
                // A partially rewritten run is not evidence for any new replacement.
                continue
            }
            guard (1...3).contains(a.count), (1...3).contains(b.count) else { continue }
            let swap = VocabularySwap(heard: old[a].joined(separator: " "), written: new[b].joined(separator: " "), source: source)
            if keep.blocks(heardKey: swap.heardKey, writtenKey: swap.writtenKey) {
                replacements.append((ranges[b.lowerBound].lowerBound..<ranges[b.upperBound - 1].upperBound, swap.heard))
            } else { swaps.append(swap) }
        }
        var text = after
        for (range, heard) in replacements.reversed() { text.replaceSubrange(range, with: heard) }
        return (text, swaps)
    }

    private static func blockedReplacements(old: [String], new: [String], before: Range<Int>, after: Range<Int>,
                                            keep: KeepHeardSet) -> [(Range<Int>, String)] {
        guard !keep.isEmpty, !before.isEmpty, !after.isEmpty else { return [] }
        let oldKeys = old.map(CorrectionAlignment.key), newKeys = new.map(CorrectionAlignment.key)
        var usedOld = Set<Int>(), usedNew = Set<Int>()
        var result: [(Range<Int>, String)] = []
        for pair in keep.blockedPairs {
            let heard = occurrences(pair.heard, in: oldKeys, within: before)
            let written = occurrences(pair.written, in: newKeys, within: after)
            var remainingHeard = heard.filter { usedOld.isDisjoint(with: $0) }
            for target in written where usedNew.isDisjoint(with: target) {
                guard let source = remainingHeard.first else { break }
                remainingHeard.removeFirst()
                usedOld.formUnion(source)
                remainingHeard.removeAll { !usedOld.isDisjoint(with: $0) }
                usedNew.formUnion(target)
                result.append((target, old[source].joined(separator: " ")))
            }
        }
        return result.sorted { $0.0.lowerBound < $1.0.lowerBound }
    }

    private static func occurrences(_ phrase: [String], in keys: [String], within range: Range<Int>) -> [Range<Int>] {
        guard !phrase.isEmpty, phrase.count <= range.count else { return [] }
        return (range.lowerBound...(range.upperBound - phrase.count)).compactMap { start in
            let span = start..<(start + phrase.count)
            return Array(keys[span]) == phrase ? span : nil
        }
    }

    /// Replace the lexical core only: cleanup owns quotes, punctuation and possessive suffixes.
    private static func wordSurface(_ token: String) -> String {
        String(token[wordRange(in: token, token: token.startIndex..<token.endIndex)])
    }

    private static func wordRange(in text: String, token: Range<String.Index>) -> Range<String.Index> {
        let slice = text[token]
        guard let first = slice.firstIndex(where: { $0.isLetter || $0.isNumber }),
              let last = slice.lastIndex(where: { $0.isLetter || $0.isNumber }) else { return token }
        var end = text.index(after: last)
        let core = text[first..<end]
        if core.lowercased().hasSuffix("'s") || core.lowercased().hasSuffix("’s") {
            end = text.index(end, offsetBy: -2)
        }
        return first..<end
    }

    private static func tokenRanges(_ text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        for index in text.indices {
            if text[index].isWhitespace {
                if let lower = start { ranges.append(lower..<index); start = nil }
            } else if start == nil { start = index }
        }
        if let start { ranges.append(start..<text.endIndex) }
        return ranges
    }
}
