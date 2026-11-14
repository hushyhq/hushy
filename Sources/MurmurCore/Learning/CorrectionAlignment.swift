import Foundation

/// One changed run between the text Hushy inserted and what the user left in the field:
/// `before` are the inserted tokens that were replaced/removed, `after` the user's tokens
/// (surface forms, punctuation attached, as they appeared).
public struct WordEdit: Sendable, Equatable {
    public let before: [String]
    public let after: [String]

    public init(before: [String], after: [String]) {
        self.before = before
        self.after = after
    }
}

/// A same-word pair whose surface differs (casing, attached punctuation).
public struct SurfaceChange: Sendable, Equatable {
    public let before: String
    public let after: String
    /// The pair is the dictation's last word (where a dropped terminal period is meaningful).
    public let isFinal: Bool

    public init(before: String, after: String, isFinal: Bool = false) {
        self.before = before
        self.after = after
        self.isFinal = isFinal
    }
}

/// The inserted dictation lined up against the user's edited version of it, word by word.
public struct CorrectionAlignment: Sendable, Equatable {
    /// Inserted tokens, in order.
    public let inserted: [String]
    /// The user's tokens covering the same stretch of the field.
    public let edited: [String]
    /// Runs whose normalized words differ.
    public let edits: [WordEdit]
    /// Pairs whose normalized words match but whose surface form differs.
    public let surfaceChanges: [SurfaceChange]
    /// The field continues on the same line after the located dictation (the user kept
    /// typing), so a missing final period is a continuation, not a style choice.
    public var continuesAfter = false

    /// Number of inserted tokens that were replaced or removed.
    public var changedInsertedWords: Int { edits.reduce(0) { $0 + $1.before.count } }
    /// Number of tokens the user typed that weren't in the inserted text.
    public var addedWords: Int { edits.reduce(0) { $0 + $1.after.count } }
}

extension CorrectionAlignment {
    /// Fields with more tokens than this are not searched at all: a time bound for a runaway field
    /// (a pasted book), not a size rule. A 20,000-token field is located in a few milliseconds.
    public static let maxFieldTokens = 200_000
    /// The same bound in bytes, checked before the field is scanned.
    static let maxFieldBytes = 4_000_000
    /// Most cells (dictation tokens x field tokens) the whole-field alignment may fill. It runs only
    /// when no anchor window is found or confirmed (very short dictations, heavily rewritten text),
    /// and bounds the old O(n x m) behaviour so it can never stall a paste.
    static let maxFallbackCells = 2_000_000
    /// At least this share of the inserted words must still be present, in order, inside the
    /// located span. Below it the user rewrote the text (or sent it and typed something new).
    public static let minSurvivingShare = 0.6

    /// Finds the stretch of `fieldValue` that corresponds to `inserted` and aligns the two.
    ///
    /// The field may hold other text around the dictation ("Hi team, <dictation> Thanks"). The
    /// span runs from the first to the last inserted word that survived, widened by as many
    /// unmatched field tokens as there were unmatched inserted tokens at either edge (so a
    /// corrected first or last word is still captured). Returns nil when the dictation can't
    /// be located confidently.
    ///
    /// Long fields are searched with k-gram anchors (`FieldAnchorLocator`): the dictation's k-grams
    /// are found in one pass over the field, the best chain of hits names a window of about the
    /// dictation's own length, and the exact LCS runs only inside it. A dictation too short to anchor
    /// (three words or fewer), or a window that fails the survival tests, falls back to the LCS over
    /// the whole field while that costs at most `maxFallbackCells`.
    public static func locate(inserted: String, in fieldValue: String) -> CorrectionAlignment? {
        let insertedTokens = tokens(inserted)
        guard !insertedTokens.isEmpty, fieldValue.utf8.count <= maxFieldBytes else { return nil }
        let (insertedIDs, vocabulary) = intern(insertedTokens.map(key))
        let field = FieldTokenScan(fieldValue, vocabulary: vocabulary)
        guard field.count > 0, field.count <= maxFieldTokens else { return nil }

        if let window = FieldAnchorLocator.window(inserted: insertedIDs, field: field.ids),
           let alignment = locate(insertedTokens, insertedIDs, field, in: window.range, diagonal: window.diagonal) {
            return alignment
        }
        guard insertedIDs.count * field.count <= maxFallbackCells else { return nil }
        return locate(insertedTokens, insertedIDs, field, in: 0..<field.count)
    }

    /// The survival tests and the alignment, with the LCS restricted to `window` of the field.
    private static func locate(
        _ insertedTokens: [String], _ insertedIDs: [Int32], _ field: FieldTokenScan,
        in window: Range<Int>, diagonal: Int? = nil
    ) -> CorrectionAlignment? {
        let pairs = matchedPairs(insertedIDs, Array(field.ids[window]), preferredDiagonal: diagonal.map { $0 - window.lowerBound })
            .map { (inserted: $0.inserted, field: $0.field + window.lowerBound) }
        guard let first = pairs.first, let last = pairs.last else { return nil }
        // A token with no letter or digit in it (a list dash, "—", "•", "&") has an empty key and can never match, so it
        // is not a word that failed to survive: an editor that turns "- item" into a bullet point must not make the
        // dictation look rewritten.
        let keyedWords = insertedIDs.filter { $0 >= 0 }.count
        guard Double(pairs.count) / Double(max(keyedWords, 1)) >= minSurvivingShare else { return nil }

        let leadingMissing = first.inserted
        let trailingMissing = insertedTokens.count - 1 - last.inserted
        let (firstField, lastField) = tightEdges(pairs, insertedIDs, field.ids)
        let start = max(0, firstField - leadingMissing)
        let end = min(field.count - 1, lastField + trailingMissing)
        // Scattered matches (common words picked up across a long field) mean we didn't find
        // the dictation, just words that happen to recur.
        let span = field.tokens(start...end)
        let spanWords = span.filter { !key($0).isEmpty }.count
        guard Double(pairs.count) / Double(max(spanWords, 1)) >= minSurvivingShare else { return nil }
        var alignment = align(inserted: insertedTokens, edited: span)
        alignment.continuesAfter = end < field.count - 1 && !field.continuesOnNewLine(afterToken: end)
        return alignment
    }

    /// The field positions of the first and last matched pair, moved inward as far as equal words
    /// allow. An LCS has many equally long alignments; when a word next to the dictation repeats
    /// the dictation's first or last word ("ba | ba laso ..."), the match may land on the outside
    /// copy, which would add a phantom edit. The tightest alignment has the fewest edits.
    static func tightEdges(_ pairs: [(inserted: Int, field: Int)], _ inserted: [Int32], _ field: [Int32]) -> (first: Int, last: Int) {
        guard pairs.count > 1 else { return (pairs[0].field, pairs[0].field) }
        var limit = pairs[pairs.count - 1].field   // pairs after this one sit at or beyond `limit`
        var firstField = limit
        for index in stride(from: pairs.count - 2, through: 0, by: -1) {
            var position = pairs[index].field
            var probe = position + 1
            while probe < limit {
                if field[probe] == inserted[pairs[index].inserted] { position = probe }
                probe += 1
            }
            limit = position
            firstField = position
        }
        limit = pairs[0].field
        var lastField = limit
        for index in 1..<pairs.count {
            var position = pairs[index].field
            var probe = position - 1
            while probe > limit {
                if field[probe] == inserted[pairs[index].inserted] { position = probe }
                probe -= 1
            }
            limit = position
            lastField = position
        }
        return (firstField, lastField)
    }

    /// Interns the dictation's comparison keys: distinct non-empty keys get ids 0..., an empty key is
    /// -1 and never matches. Also returns the key to id table the field scan looks tokens up in.
    static func intern(_ insertedKeys: [String]) -> (ids: [Int32], vocabulary: [String: Int32]) {
        var vocabulary: [String: Int32] = [:]
        let ids = insertedKeys.map { key -> Int32 in
            guard !key.isEmpty else { return -1 }
            if let id = vocabulary[key] { return id }
            let id = Int32(vocabulary.count)
            vocabulary[key] = id
            return id
        }
        return (ids, vocabulary)
    }

    /// Aligns two token lists (already located) into changed runs and surface-only changes.
    public static func align(inserted: [String], edited: [String]) -> CorrectionAlignment {
        var edits: [WordEdit] = []
        var surface: [SurfaceChange] = []
        var insertedIndex = 0
        for region in BoostGuard.align(inserted.map(key), edited.map(key)) {
            switch region {
            case .same(let range):
                // `range` indexes `edited`; the matching inserted run starts at `insertedIndex`.
                for (offset, editedIndex) in range.enumerated() {
                    let before = inserted[insertedIndex + offset]
                    let after = edited[editedIndex]
                    let isFinal = insertedIndex + offset == inserted.count - 1
                    if before != after, !key(before).isEmpty { surface.append(SurfaceChange(before: before, after: after, isFinal: isFinal)) }
                }
                insertedIndex += range.count
            case .changed(let old, let new):
                let before = Array(inserted[old]), after = Array(edited[new])
                // Only punctuation marks came or went ("- item" shown as a bullet), or the field drew two lines as one
                // ("plan.\nCan" read back as "plan.Can"): not an edit of the person's words.
                if !(before + after).allSatisfy({ key($0).isEmpty }), !isLineJoin(before, after) {
                    edits.append(WordEdit(before: before, after: after))
                }
                insertedIndex = old.upperBound
            }
        }
        return CorrectionAlignment(inserted: inserted, edited: edited, edits: edits, surfaceChanges: surface)
    }

    /// The same characters with a break lost after a punctuation mark: some fields read paragraphs back with nothing
    /// between them. A split term the person joined ("Terra form" → "Terraform") has no mark at the seam.
    static func isLineJoin(_ before: [String], _ after: [String]) -> Bool {
        before.count > after.count && before.joined() == after.joined()
            && before.dropLast().contains { $0.last.map { $0.isPunctuation } ?? false }
    }

    /// True when the text after token `index` starts on a new line ("…ready.\nThanks").
    static func continuesOnNewLine(_ text: String, afterToken index: Int) -> Bool {
        var seen = -1
        var inToken = false
        for character in text {
            if character.isWhitespace {
                if inToken { inToken = false }
                if seen == index, character.isNewline { return true }
            } else {
                if !inToken { inToken = true; seen += 1 }
                if seen > index { return false }
            }
        }
        return false
    }

    /// Whitespace-separated surface tokens.
    public static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Comparison key: lowercased letters, digits and apostrophes (same as `BoostGuard`).
    public static func key(_ token: String) -> String {
        BoostGuard.key(token.replacingOccurrences(of: "\u{2019}", with: "'"))
    }

    /// Largest diagonal distance that still costs more (further matches all cost the same).
    private static let diagonalCostCap = 64

    /// LCS matched index pairs, in order (ids below 0 never match).
    ///
    /// With no `preferredDiagonal` this is the plain LCS with the original tie-breaking. With one
    /// (field index minus inserted index, in `b`'s coordinates) the table holds `matches x weight -
    /// total distance of the matches from that diagonal`, with a weight above any possible total
    /// distance: the number of matches is still maximal, and among alignments with the same number
    /// it picks the one nearest the diagonal. One flat table, not an array of arrays.
    static func matchedPairs(_ a: [Int32], _ b: [Int32], preferredDiagonal: Int? = nil) -> [(inserted: Int, field: Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        let columns = b.count + 1
        let maxPairs = min(a.count, b.count)
        var weight: Int32 = 1
        var center: Int?
        if let preferredDiagonal, maxPairs * maxPairs * (diagonalCostCap + 1) < Int(Int32.max) {
            weight = Int32(maxPairs * diagonalCostCap + 1)
            center = preferredDiagonal
        }
        @inline(__always) func gain(_ i: Int, _ j: Int) -> Int32 {
            guard let center else { return 1 }
            return weight - Int32(min(abs(j - i - center), diagonalCostCap))
        }
        var lcs = [Int32](repeating: 0, count: (a.count + 1) * columns)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                let skip = max(lcs[(i + 1) * columns + j], lcs[i * columns + j + 1])
                lcs[i * columns + j] = a[i] == b[j] && a[i] >= 0 ? max(skip, lcs[(i + 1) * columns + j + 1] + gain(i, j)) : skip
            }
        }
        var pairs: [(inserted: Int, field: Int)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j], a[i] >= 0, lcs[i * columns + j] == lcs[(i + 1) * columns + j + 1] + gain(i, j) {
                pairs.append((i, j)); i += 1; j += 1
            } else if lcs[(i + 1) * columns + j] >= lcs[i * columns + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }
}
