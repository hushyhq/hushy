import Foundation

/// Learning from a correction to a dictation of one or two words.
///
/// A short dictation cannot be found in a field by fuzzy matching: one misspelled name has no
/// surviving words to anchor on. So it is located exactly, using reads the app already takes
/// of the same field (the `LearningReadSchedule` reads, nothing new): an earlier read (the
/// anchor) that holds the dictation exactly once splits the field into the text before it and
/// the text after it. A later read counts only if that text is untouched and the dictation's
/// slot holds the same number of words. A recorded swap revert may change that count.
///
/// What is accepted is narrow: exactly one word replaced by one word, which the classifier calls
/// an ASR term correction (term-like, not an ordinary-word swap, no digits, sounds or spells like
/// what was heard), seen on at least `minStableReads` reads. The ordinary two-observation rule
/// before a learned term is used is untouched: no one-letter shortcut is granted.
public enum ShortDictationCapture {
    /// Dictations of up to this many words take this path; longer ones use `CorrectionCapture.derive`.
    public static let maxWords = 2
    /// Reads that must show the same fix, so a word caught half-typed is not learned.
    public static let minStableReads = 2

    public static func qualifies(_ inserted: String) -> Bool {
        (1...maxWords).contains(CorrectionAlignment.tokens(inserted).count)
    }

    private struct Read {
        let tokens: [String]
        let elapsed: TimeInterval
    }

    private struct Fix {
        let readIndex: Int
        let event: CorrectionEvent
        var signature: String { event.before.lowercased() + "\u{0}" + event.after.lowercased() }
    }

    public static func derive(
        inserted: String, raw: String, snapshots: [FieldSnapshot], context: LearningContext,
        dictationID: Int64, now: Date = Date(), evidence: TermEvidence = .none, swaps: [VocabularySwap] = [],
        isCommonWord: (String) -> Bool = LearningLexicon.isCommonWord
    ) -> CorrectionCapture? {
        explain(inserted: inserted, raw: raw, snapshots: snapshots, context: context, dictationID: dictationID,
                now: now, evidence: evidence, swaps: swaps, isCommonWord: isCommonWord).capture
    }

    /// `derive`, with the reason when there is nothing to learn (for the `learning` log line).
    public static func explain(
        inserted: String, raw: String, snapshots: [FieldSnapshot], context: LearningContext,
        dictationID: Int64, now: Date = Date(), evidence: TermEvidence = .none, swaps: [VocabularySwap] = [],
        isCommonWord: (String) -> Bool = LearningLexicon.isCommonWord
    ) -> CorrectionDerivation {
        let words = CorrectionAlignment.tokens(inserted)
        guard qualifies(inserted) else { return .dropped(.shortNoFix(words: words.count)) }
        let reads = snapshots.compactMap { snapshot -> Read? in
            guard let value = snapshot.value else { return nil }
            let tokens = CorrectionAlignment.tokens(value)
            return tokens.count <= CorrectionAlignment.maxFieldTokens ? Read(tokens: tokens, elapsed: snapshot.elapsed) : nil
        }
        var fixes: [Fix] = []
        var reverted: [(Int, Revert)] = []
        // Set while every look so far was refused by the gate.
        var refusal: LearningRefusal?
        for (index, read) in reads.enumerated() {
            var atRead = context
            atRead.elapsed = read.elapsed
            let refused = LearningGate.refusal(atRead)
            refusal = index == 0 || refusal != nil ? refused : nil
            if refused == nil,
               let anchor = reads[..<index].last(where: { occurrences(of: words, in: $0.tokens).count == 1 }),
               let start = occurrences(of: words, in: anchor.tokens).first {
                let anchorEnd = start + words.count
                let suffix = Array(anchor.tokens[anchorEnd...])
                let end = read.tokens.count - suffix.count
                // Only the anchored dictation slot may change length; its surroundings stay exact.
                if end > start, end <= read.tokens.count,
                   read.tokens.starts(with: anchor.tokens[..<start]),
                   Array(read.tokens[end...]) == suffix {
                    let alignment = CorrectionAlignment.align(inserted: words, edited: Array(read.tokens[start..<end]))
                    if let revert = RevertDetector.split(alignment, swaps: swaps).reverts.first {
                        reverted.append((index, revert))
                    }
                }
            }
            guard refused == nil,
                  let anchor = reads[..<index].last(where: { occurrences(of: words, in: $0.tokens).count == 1 }),
                  let event = correction(words, anchor: anchor.tokens, read: read.tokens, raw: raw, evidence: evidence, swaps: swaps, isCommonWord: isCommonWord)
            else { continue }
            fixes.append(Fix(readIndex: index, event: event))
        }
        if let newest = reverted.last,
           reverted.filter({ $0.1 == newest.1 }).count >= minStableReads,
           !reads[(newest.0 + 1)...].contains(where: { !occurrences(of: words, in: $0.tokens).isEmpty }) {
            return .capture(CorrectionCapture(dictationID: dictationID, appBundleID: context.appBundleID,
                                              capturedAt: now, events: [], reverts: [newest.1]))
        }
        guard let newest = fixes.last else {
            guard let last = reads.last else { return .dropped(.unreadable) }
            if let refusal { return .dropped(.refused(refusal)) }
            let isStillThere = !occurrences(of: words, in: last.tokens).isEmpty
            return .dropped(isStillThere ? .unchanged : .shortNoFix(words: words.count))
        }
        guard fixes.filter({ $0.signature == newest.signature }).count >= minStableReads,
              !reads[(newest.readIndex + 1)...].contains(where: { !occurrences(of: words, in: $0.tokens).isEmpty })
        else { return .dropped(.shortNotSettled(words: words.count)) }
        return .capture(CorrectionCapture(dictationID: dictationID, appBundleID: context.appBundleID, capturedAt: now,
                                          events: [newest.event], supportedKeys: evidence.supports(newest.event.after) ? [newest.event.after.lowercased()] : []))
    }

    /// The one accepted shape: the field is the anchor with the dictation's words replaced by the
    /// same number of words, exactly one of which differs, and the classifier calls that an ASR term.
    private static func correction(
        _ words: [String], anchor: [String], read: [String], raw: String, evidence: TermEvidence, swaps: [VocabularySwap], isCommonWord: (String) -> Bool
    ) -> CorrectionEvent? {
        guard read.count == anchor.count, let start = occurrences(of: words, in: anchor).first else { return nil }
        let end = start + words.count
        let before = Array(anchor[..<start]), after = Array(anchor[end...])
        guard Array(read[..<start]) == before, Array(read[end...]) == after else { return nil }
        let alignment = CorrectionAlignment.align(inserted: words, edited: Array(read[start..<end]))
        guard RevertDetector.split(alignment, swaps: swaps).reverts.isEmpty else { return nil }
        guard alignment.surfaceChanges.isEmpty, alignment.edits.count == 1,
              alignment.edits[0].before.count == 1, alignment.edits[0].after.count == 1,
              let event = CorrectionClassifier.classify(alignment, raw: raw, evidence: evidence, isCommonWord: isCommonWord).first,
              event.kind == .asrTerm
        else { return nil }
        let heard = CorrectionAlignment.key(alignment.edits[0].before[0])
        let fixed = CorrectionAlignment.key(alignment.edits[0].after[0])
        let elsewhere = Set((before + after).map(CorrectionAlignment.key))
        guard !heard.isEmpty, !fixed.isEmpty, heard != fixed,
              !heard.hasPrefix(fixed), !fixed.hasPrefix(heard),
              !elsewhere.contains(heard), !elsewhere.contains(fixed)
        else { return nil }
        return event
    }

    /// Start indices where `words` occurs exactly (same surface) as a contiguous run.
    private static func occurrences(of words: [String], in tokens: [String]) -> [Int] {
        guard !words.isEmpty, words.count <= tokens.count else { return [] }
        return (0...(tokens.count - words.count)).filter { Array(tokens[$0..<($0 + words.count)]) == words }
    }
}
