import Foundation
import os

/// Dictionary replacement with the same results as the one-regex-per-variant loop (`Personalizer.applyDictionarySequential`),
/// found in one pass over the text.
///
/// **What the old loop means.** Entries in order; within an entry, the heard phrases and the term longest first; each phrase
/// is a case-insensitive whole-word search over the text *as the earlier phrases left it*. Call each phrase a rule. Rule `r`
/// finds its matches left to right without overlap, drops the ones the keep-as-heard set blocks, widens each to the stretch
/// that already reads as the term (`TermSpan.reading`), skips one that overlaps a widened match of the same rule or already
/// equals the term, and writes the term over the rest. An earlier rule's output is what a later rule searches, so the result
/// is order-dependent.
///
/// **What this does.** One Aho–Corasick scan (`PhraseAutomaton`) finds every occurrence of every rule in the input, O(n + z)
/// however large the Dictionary is. Then:
/// 1. *Batch.* When the occurrences cannot interact, every rule is evaluated on the input text and all edits are written at
///    once. They cannot interact when no occurrence's context (its two neighbour characters and the letters
///    `TermSpan.reading` looks at) touches another rule's edit, and rescanning the output finds no later rule that matches
///    around an inserted term, except the term matching itself (a rule whose phrase is the term it just wrote is a no-op by
///    definition: the text already equals the term). Only plain ASCII input takes this path.
/// 2. *Rescan.* Otherwise rules are applied in order exactly like the old loop, rescanning only after a rule changed the text,
///    and skipping rules with no occurrence (a rule with no match changes nothing). Cost O(n) per rule that edits.
/// 3. *Reference.* Text or phrases holding scalars whose case-insensitive matching is not one-to-one (ß, İ, ligatures)
///    return nil, and the caller runs the regular-expression loop.
struct DictionaryMatcher: Sendable {
    enum Path: Equatable, Sendable { case empty, batch, rescan }

    struct Applied: Sendable, Equatable {
        let text: String
        let fixes: Int
        let path: Path
    }

    private struct Rule: Sendable {
        let term: String
        let termScalars: Int
        let termLetters: Int
        let leadingCount: Int
        let trailingCount: Int
        /// The term's lower-case letters and digits when the term is plain ASCII (else nil).
        let asciiLetters: String?
    }

    private let rules: [Rule]
    private let automaton: PhraseAutomaton
    private let isSupported: Bool

    /// Nodes of work above which the batch check gives up and the rescan path decides (candidates times edits).
    private static let batchPairLimit = 250_000

    init(entries: [DictionaryEntry]) {
        var rules: [Rule] = []
        var patterns: [[UInt32]] = []
        var supported = true
        for entry in entries where !entry.term.isEmpty {
            // Longest variants first so "cooper netties" wins over "cooper".
            let variants = (entry.soundsLike + [entry.term]).filter { !$0.isEmpty }.sorted { $0.count > $1.count }
            let letters = entry.term.filter { $0.isLetter || $0.isNumber }.count
            let rule = Rule(
                term: entry.term, termScalars: entry.term.unicodeScalars.count, termLetters: letters,
                leadingCount: entry.term.prefix { !($0.isLetter || $0.isNumber) }.count,
                trailingCount: entry.term.reversed().prefix { !($0.isLetter || $0.isNumber) }.count,
                asciiLetters: entry.term.allSatisfy(\.isASCII) ? String(entry.term.lowercased().filter { $0.isLetter || $0.isNumber }) : nil)
            for variant in variants {
                let symbols = variant.unicodeScalars.compactMap(PhraseFolding.symbol)
                if symbols.count != variant.unicodeScalars.count { supported = false }
                rules.append(rule)
                patterns.append(symbols)
            }
        }
        self.rules = rules
        self.isSupported = supported
        self.automaton = supported ? PhraseAutomaton(patterns: patterns) : PhraseAutomaton(patterns: [])
    }

    var ruleCount: Int { rules.count }

    /// The replaced text, or nil when the regular-expression loop must decide.
    func apply(_ text: String, keep: KeepHeardSet) -> Applied? {
        guard isSupported else { return nil }
        if rules.isEmpty { return Applied(text: text, fixes: 0, path: .empty) }
        guard let scan = TextScan(text, automaton: automaton) else { return nil }
        if scan.occurrences.isEmpty { return Applied(text: text, fixes: 0, path: .batch) }
        if scan.isASCII, let batch = applyBatch(scan, keep: keep) { return batch }
        return applyRescanning(scan, keep: keep)
    }

    // MARK: Rescan: the old loop, run only for rules that occur

    private func applyRescanning(_ first: TextScan, keep: KeepHeardSet) -> Applied? {
        var scan = first
        var fixes = 0
        var floor = 0
        while let group = scan.firstGroup(atOrAfter: floor) {
            floor = group.rule + 1
            let edits = candidates(group, in: scan, keep: keep).compactMap(\.span)
            guard !edits.isEmpty else { continue }
            fixes += edits.count
            var out = scan.text
            for span in edits.sorted(by: { $0.lowerBound > $1.lowerBound }) { out.replaceSubrange(span, with: rules[group.rule].term) }
            guard let next = TextScan(out, automaton: automaton) else { return nil }
            scan = next
        }
        return Applied(text: scan.text, fixes: fixes, path: .rescan)
    }

    // MARK: Batch: every rule on the input, all edits at once

    private struct Candidate {
        let rule: Int
        let heard: Range<Int>
        let span: Range<String.Index>?
    }

    private func applyBatch(_ scan: TextScan, keep: KeepHeardSet) -> Applied? {
        let all = scan.groups.flatMap { candidates($0, in: scan, keep: keep) }
        let edits = all.filter { $0.span != nil }
        if edits.isEmpty { return Applied(text: scan.text, fixes: 0, path: .batch) }
        guard all.count * edits.count <= Self.batchPairLimit else { return nil }
        let ranges = edits.map { (rule: $0.rule, range: scan.scalarRange($0.span!)) }
        for candidate in all {
            let zone = zone(of: candidate, in: scan)
            if ranges.contains(where: { $0.rule != candidate.rule && $0.range.overlaps(zone) }) { return nil }
        }
        let placed = ranges.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var out = ""
        var cursor = scan.text.startIndex
        var shift = 0
        var regions: [(rule: Int, range: Range<Int>)] = []
        for edit in edits.sorted(by: { $0.span!.lowerBound < $1.span!.lowerBound }) {
            out += scan.text[cursor..<edit.span!.lowerBound]
            out += rules[edit.rule].term
            cursor = edit.span!.upperBound
        }
        out += scan.text[cursor...]
        for edit in placed {
            let size = rules[edit.rule].termScalars
            regions.append((edit.rule, (edit.range.lowerBound + shift)..<(edit.range.lowerBound + shift + size)))
            shift += size - edit.range.count
        }
        guard let output = TextScan(out, automaton: automaton), insertionsAreInert(output, regions: regions) else { return nil }
        return Applied(text: out, fixes: edits.count, path: .batch)
    }

    /// True when no rule that comes after an inserting rule matches around the inserted term, other than a rule whose
    /// phrase is that very term: an occurrence the old loop would have found and left alone.
    private func insertionsAreInert(_ output: TextScan, regions: [(rule: Int, range: Range<Int>)]) -> Bool {
        for occurrence in output.occurrences {
            let reach = (Int(occurrence.start) - 1)..<(Int(occurrence.end) + 1)
            let touching = regions.filter { $0.rule < Int(occurrence.rule) && $0.range.overlaps(reach) }
            if touching.isEmpty { continue }
            guard touching.count == 1, let region = touching.first,
                  region.range == Int(occurrence.start)..<Int(occurrence.end),
                  rules[region.rule].term == rules[Int(occurrence.rule)].term else { return false }
        }
        return true
    }

    /// Every character the evaluation of this occurrence read: its neighbours, the stretch it is replaced over, and the
    /// letters and punctuation `TermSpan.reading` compares. That function looks beyond the heard phrase only for the letters
    /// the term has and the phrase lacks, and only when the phrase is shorter than the term.
    private func zone(of candidate: Candidate, in scan: TextScan) -> Range<Int> {
        let rule = rules[candidate.rule]
        let span = candidate.span.map(scan.scalarRange) ?? candidate.heard
        var low = min(candidate.heard.lowerBound, span.lowerBound)
        var high = max(candidate.heard.upperBound, span.upperBound)
        let heardLetters = candidate.heard.reduce(0) { $0 + (scan.isASCIIAlphanumeric($1) ? 1 : 0) }
        guard heardLetters > 0, heardLetters <= rule.termLetters else { return (low - 1)..<(high + 1) }
        let reach = rule.termLetters - heardLetters
        var seen = 0
        var position = candidate.heard.lowerBound
        while position > 0, seen < reach {
            position -= 1
            if scan.isASCIIAlphanumeric(position) { seen += 1 }
        }
        low = min(low, position - rule.leadingCount)
        seen = 0
        position = candidate.heard.upperBound
        while position < scan.scalars.count, seen < reach {
            if scan.isASCIIAlphanumeric(position) { seen += 1 }
            position += 1
        }
        high = max(high, position + rule.trailingCount)
        return (low - 1)..<(high + 1)
    }

    // MARK: One rule on one text, as the old loop did

    /// `TermSpan.reading`, skipping the work when it cannot find anything: it only reads a term's letters around a heard phrase
    /// whose own letters are a run inside the term's letters, so a phrase that is not one gets nil without a look at the text.
    private func reading(_ rule: Rule, around heard: Range<String.Index>, _ scalars: Range<Int>, in scan: TextScan) -> Range<String.Index>? {
        if scan.isASCII, let letters = rule.asciiLetters {
            let own = scan.lowercasedLetters(scalars)
            guard !own.isEmpty, own.count <= letters.count, letters.contains(own) else { return nil }
        }
        return TermSpan.reading(term: rule.term, around: heard, in: scan.text)
    }

    private func candidates(_ group: TextScan.Group, in scan: TextScan, keep: KeepHeardSet) -> [Candidate] {
        let rule = rules[group.rule]
        let writtenKey = keep.isEmpty ? "" : VocabularySwap.key(rule.term)
        var spans: [Range<String.Index>] = []
        var found: [Candidate] = []
        var consumedTo = 0
        for occurrence in scan.occurrences[group.range] {
            let (start, end) = (Int(occurrence.start), Int(occurrence.end))
            // A regular expression continues after the end of its last match.
            if start < consumedTo { continue }
            consumedTo = end
            let heard = scan.indices[start]..<scan.indices[end]
            if !keep.isEmpty, keep.blocks(heardKey: VocabularySwap.key(String(scan.text[heard])), writtenKey: writtenKey) {
                found.append(Candidate(rule: group.rule, heard: start..<end, span: nil))
                continue
            }
            // A heard phrase inside text that already reads as the term (the term contains the phrase, as in
            // "jimmylord" -> "jimmylord.com") is replaced together with the rest of that reading, so a replacement
            // applied to its own output changes nothing.
            let span = reading(rule, around: heard, start..<end, in: scan) ?? heard
            if !spans.contains(where: { $0.overlaps(span) }), scan.text[span] != rule.term {
                spans.append(span)
                found.append(Candidate(rule: group.rule, heard: start..<end, span: span))
            } else {
                found.append(Candidate(rule: group.rule, heard: start..<end, span: nil))
            }
        }
        return found
    }
}

/// The input text as scalars, with every occurrence of every rule's phrase that stands as a whole word.
private struct TextScan {
    struct Occurrence { let rule: Int32; let start: Int32; let end: Int32 }
    struct Group { let rule: Int; let range: Range<Int> }

    let text: String
    let scalars: [Unicode.Scalar]
    let indices: [String.Index]
    let isASCII: Bool
    let occurrences: [Occurrence]

    /// Nil when the text holds a scalar the automaton cannot fold (the caller then uses the regular expressions).
    init?(_ text: String, automaton: PhraseAutomaton) {
        var scalars: [Unicode.Scalar] = []
        var indices: [String.Index] = []
        var symbols: [UInt32] = []
        var isASCII = true
        let view = text.unicodeScalars
        var index = view.startIndex
        while index < view.endIndex {
            let scalar = view[index]
            guard let symbol = PhraseFolding.symbol(scalar) else { return nil }
            if scalar.value >= 128 { isASCII = false }
            scalars.append(scalar)
            indices.append(index)
            symbols.append(symbol)
            index = view.index(after: index)
        }
        indices.append(view.endIndex)
        var found: [Occurrence] = []
        automaton.scan(symbols) { pattern, end in
            let start = end - Int(automaton.patternLengths[pattern])
            guard start == 0 || !PhraseFolding.isWord(scalars[start - 1]),
                  end == scalars.count || !PhraseFolding.isWord(scalars[end]) else { return }
            found.append(Occurrence(rule: Int32(pattern), start: Int32(start), end: Int32(end)))
        }
        found.sort { ($0.rule, $0.start) < ($1.rule, $1.start) }
        (self.text, self.scalars, self.indices, self.isASCII, self.occurrences) = (text, scalars, indices, isASCII, found)
    }

    var groups: [Group] {
        var result: [Group] = []
        var first = 0
        while first < occurrences.count {
            var last = first
            while last < occurrences.count, occurrences[last].rule == occurrences[first].rule { last += 1 }
            result.append(Group(rule: Int(occurrences[first].rule), range: first..<last))
            first = last
        }
        return result
    }

    func firstGroup(atOrAfter floor: Int) -> Group? {
        guard let first = occurrences.firstIndex(where: { Int($0.rule) >= floor }) else { return nil }
        let rule = occurrences[first].rule
        var last = first
        while last < occurrences.count, occurrences[last].rule == rule { last += 1 }
        return Group(rule: Int(rule), range: first..<last)
    }

    func scalarRange(_ range: Range<String.Index>) -> Range<Int> {
        offset(of: range.lowerBound)..<offset(of: range.upperBound)
    }

    /// The ASCII letters and digits of a range, lower-cased (the comparison key `TermSpan` uses, for ASCII text).
    func lowercasedLetters(_ range: Range<Int>) -> String {
        var letters = String.UnicodeScalarView()
        for position in range where isASCIIAlphanumeric(position) {
            let value = scalars[position].value
            letters.append(Unicode.Scalar(value >= 65 && value <= 90 ? value + 32 : value)!)
        }
        return String(letters)
    }

    func isASCIIAlphanumeric(_ position: Int) -> Bool {
        let value = scalars[position].value
        return (value >= 48 && value <= 57) || (value >= 65 && value <= 90) || (value >= 97 && value <= 122)
    }

    /// Position of a string index in the scalar array (binary search; the indices are sorted).
    private func offset(of index: String.Index) -> Int {
        var low = 0, high = indices.count - 1
        while low < high {
            let middle = (low + high) / 2
            if indices[middle] < index { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

/// The matcher for each app scope of one `Personalizer`, built the first time it is needed and kept until the Dictionary
/// changes (a changed Dictionary is a new `Personalizer`, so a new box).
final class DictionaryMatcherCache: Sendable {
    private let matchers = OSAllocatedUnfairLock<[String?: DictionaryMatcher]>(initialState: [:])

    func matcher(for app: String?, build: () -> DictionaryMatcher) -> DictionaryMatcher {
        if let hit = matchers.withLock({ $0[app] }) { return hit }
        let built = build()
        matchers.withLock { $0[app] = built }
        return built
    }
}
