import Foundation

/// Keeps the cleanup model from changing words the speaker said. The model may remove fillers,
/// resolve a self-correction, punctuate, capitalise, format numbers, contract and fix a
/// misspelling. It may not replace a word with a different one: "priyanka" must not become
/// "Priya", "postgres" must not become "PostgreSQL". When it does, the speaker's word goes back
/// in place of the model's, and the rest of the answer is kept.
///
/// Draft and answer are aligned word by word (longest common subsequence on lower-cased words).
/// Between two matching words sits a region; where draft and answer each have the same number of
/// content words there, the words are paired in order and each pair is judged by
/// `WordRelation.isDifferent`. Function words, fillers, numbers and contractions are not content
/// words here. Spelled-out number values are checked separately within each aligned region;
/// a number the draft holds as digits is left to `FactPreservationGuard`.
/// A region that cannot be paired is left to the other guards.
///
/// A token the technical-token rules converted ("p99", "us-east-1", "--dry-run", "package.json")
/// also keeps its exact case when the model only changed its capitals.
enum SpokenWordFidelity {
    struct Result: Equatable {
        var text: String
        var wordRepairs = 0
        var caseRestores = 0
        var fired: Bool { wordRepairs + caseRestores > 0 }
    }

    struct Token {
        let text: String
        let range: Range<String.Index>
        let key: String
    }

    private struct Edit {
        let range: Range<String.Index>
        let replacement: String
    }

    private struct NumberEntry {
        let range: Range<String.Index>
        let value: Int
        let writtenAsDigits: Bool
    }

    private static let maxAlignmentCells = 4_000_000
    private static let tokenPattern = #"(?:(?<![\p{L}\p{N}])--(?=\p{L}))?[\p{L}\p{N}]+(?:['’_/.\-][\p{L}\p{N}]+)*"#
    private static let numberFormatting: Set<String> = [
        "percent", "dollars", "dollar", "cents", "cent", "point", "am", "pm", "hundred", "thousand", "million",
        "billion", "k", "x",
    ]

    /// The answer with replaced words put back and converted tokens' case restored.
    /// `lowConfidenceWords` (the ASR's doubtful words, lower-cased) stay open to correction.
    static func enforce(
        answer: String, draft: String, lowConfidenceWords: Set<String>?,
        knownWords: Set<String> = BoostGuard.systemWords
    ) -> Result {
        guard answer != draft else { return Result(text: answer) }
        let spoken = tokens(draft), written = tokens(answer)
        guard !spoken.isEmpty, !written.isEmpty, spoken.count * written.count <= maxAlignmentCells else {
            return Result(text: answer)
        }
        var result = Result(text: answer)
        var edits: [Edit] = []
        var unmatchedSpoken: [(token: Token, region: Int)] = []
        var unmatchedWritten: [(token: Token, region: Int)] = []
        var previousSpoken = 0, previousWritten = 0
        let anchors = align(spoken.map(\.key), written.map(\.key)) + [(spoken.count, written.count)]
        for (region, anchor) in anchors.enumerated() {
            let (spokenIndex, writtenIndex) = anchor
            let spokenRegion = Array(spoken[previousSpoken..<spokenIndex])
            let writtenRegion = Array(written[previousWritten..<writtenIndex])
            let repairs = wordRepairs(
                spoken: spokenRegion, written: writtenRegion,
                lowConfidenceWords: lowConfidenceWords, knownWords: knownWords)
            result.wordRepairs += repairs.count
            edits += repairs
            let saidNumbers = numbers(in: spokenRegion)
            let wroteNumbers = numbers(in: writtenRegion)
            if saidNumbers.count == wroteNumbers.count {
                // A number the draft already holds as digits stays with `FactPreservationGuard`, which
                // rejects the whole answer; only a number still spelled out is put back here.
                for (said, wrote) in zip(saidNumbers, wroteNumbers)
                where said.value != wrote.value && !said.writtenAsDigits {
                    if spokenRegion.contains(where: {
                        $0.range.lowerBound >= said.range.lowerBound && $0.range.upperBound <= said.range.upperBound &&
                        lowConfidenceWords?.contains(BoostGuard.key($0.text)) == true
                    }) { continue }
                    let replacement = wrote.writtenAsDigits ? String(said.value) : String(draft[said.range])
                    edits.append(Edit(range: wrote.range, replacement: replacement))
                    result.wordRepairs += 1
                }
            }
            let saidContent = spokenRegion.filter { !isFreeInDraft($0.key) }
            let wroteContent = writtenRegion.filter { !isFreeInDraft($0.key) }
            if saidContent.count != wroteContent.count {
                unmatchedSpoken += saidContent.map { (token: $0, region: region) }
                unmatchedWritten += wroteContent.map { (token: $0, region: region) }
            }
            if spokenIndex < spoken.count, ConvertedTokenShape.isCaseSensitive(spoken[spokenIndex].text),
               spoken[spokenIndex].text != written[writtenIndex].text {
                edits.append(Edit(range: written[writtenIndex].range, replacement: spoken[spokenIndex].text))
                result.caseRestores += 1
            }
            previousSpoken = spokenIndex + 1
            previousWritten = writtenIndex + 1
        }
        for said in unmatchedSpoken {
            guard lowConfidenceWords?.contains(BoostGuard.key(said.token.text)) != true else { continue }
            let candidates = unmatchedWritten.filter {
                $0.region != said.region && WordRelation.isStrongRelation(draft: said.token.key, answer: $0.token.key)
            }
            guard candidates.count == 1 else { continue }
            let wrote = candidates[0].token
            let rivals = unmatchedSpoken.filter {
                $0.region != candidates[0].region && WordRelation.isStrongRelation(draft: $0.token.key, answer: wrote.key)
            }
            guard rivals.count == 1 else { continue }
            edits.append(Edit(range: wrote.range, replacement: restoredSpelling(said.token.text, likeAnswer: wrote.text)))
            result.wordRepairs += 1
        }
        result.text = apply(edits, to: answer)
        return result
    }

    /// `enforce` for the live path: the repaired answer, with a stderr trace when
    /// `HUSHY_FIDELITY_TRACE` is set so evals can count how often the guard fired.
    static func enforcing(_ answer: String, draft: String, lowConfidenceWords: Set<String>?) -> String {
        let result = enforce(answer: answer, draft: draft, lowConfidenceWords: lowConfidenceWords)
        if result.fired, ProcessInfo.processInfo.environment["HUSHY_FIDELITY_TRACE"] != nil {
            let line = "[fidelity] words=\(result.wordRepairs) case=\(result.caseRestores) | \(answer) -> \(result.text)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        return result.text
    }

    // MARK: Words

    static func tokens(_ text: String) -> [Token] {
        Regex.matches(text, tokenPattern).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let word = String(text[range])
            let key = word.lowercased().replacingOccurrences(of: "’", with: "'")
            return Token(text: word, range: range, key: key == "okay" ? "ok" : key)
        }
    }

    private static func wordRepairs(
        spoken: [Token], written: [Token], lowConfidenceWords: Set<String>?, knownWords: Set<String>
    ) -> [Edit] {
        guard !spoken.isEmpty, !written.isEmpty else { return [] }
        if spoken.count == 1, written.count == 1,
           spoken[0].key.contains("-") != written[0].key.contains("-"),
           WordRelation.collapsed(spoken[0].key) == WordRelation.collapsed(written[0].key),
           lowConfidenceWords?.contains(BoostGuard.key(spoken[0].text)) != true,
           (spoken[0].key.contains("-") || (written[0].key.split(separator: "-").first?.count ?? 0) >= 2) {
            return [Edit(range: written[0].range,
                         replacement: restoredSpelling(spoken[0].text, likeAnswer: written[0].text))]
        }
        // Joined or split compounds, hyphens and apostrophes: the same letters, the same word.
        guard WordRelation.collapsed(spoken.map(\.key).joined()) != WordRelation.collapsed(written.map(\.key).joined()) else {
            return []
        }
        let spokenWords = spoken.filter { !isFreeInDraft($0.key) }
        let writtenWords = written.filter { !isNumberOrContraction($0.key) }
        guard !spokenWords.isEmpty, spokenWords.count == writtenWords.count else { return [] }
        return zip(spokenWords, writtenWords).compactMap { said, wrote in
            if lowConfidenceWords?.contains(BoostGuard.key(said.text)) == true { return nil }
            guard WordRelation.isDifferent(draft: said.key, answer: wrote.key, knownWords: knownWords) else { return nil }
            return Edit(range: wrote.range, replacement: restoredSpelling(said.text, likeAnswer: wrote.text))
        }
    }

    /// Number spans are paired in order within an alignment region. The existing fact check
    /// recognises digit tokens; the cleanup cardinal parser supplies spoken values.
    private static func numbers(in tokens: [Token]) -> [NumberEntry] {
        var entries: [NumberEntry] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if FactPreservationGuard.extractFacts(token.text).numbers.contains(token.text),
               let value = Int(token.text) {
                entries.append(NumberEntry(range: token.range, value: value, writtenAsDigits: true))
                index += 1
                continue
            }
            guard InverseTextNormalizer.parseCardinal(token.key) != nil else {
                index += 1
                continue
            }
            var best: (end: Int, value: Int)?
            var end = index + 1
            while end <= tokens.count {
                if tokens[end - 1].key == "and" { end += 1; continue }
                let phrase = tokens[index..<end].map(\.key).joined(separator: " ")
                guard let value = InverseTextNormalizer.parseCardinal(phrase) else { break }
                best = (end, value)
                end += 1
            }
            if let best {
                entries.append(NumberEntry(range: token.range.lowerBound..<tokens[best.end - 1].range.upperBound,
                                           value: best.value, writtenAsDigits: false))
                index = best.end
            } else {
                index += 1
            }
        }
        return entries
    }

    private static func isNumberOrContraction(_ key: String) -> Bool {
        key.contains("'") || key.contains { $0.isNumber } || TokenLexicon.numberWords.contains(key) || numberFormatting.contains(key)
    }

    private static func isFreeInDraft(_ key: String) -> Bool {
        isNumberOrContraction(key) || TokenLexicon.functionWords.contains(key) || DisfluencyOnlyGuard.droppable.contains(key)
    }

    /// The speaker's word, capitalised when the model's word was.
    private static func restoredSpelling(_ said: String, likeAnswer wrote: String) -> String {
        guard wrote.first?.isUppercase == true, said.first?.isLowercase == true else { return said }
        return said.prefix(1).uppercased() + said.dropFirst()
    }

    // MARK: Alignment

    /// Index pairs (draft, answer) of the longest common subsequence of equal keys.
    private static func align(_ spoken: [String], _ written: [String]) -> [(Int, Int)] {
        let columns = written.count + 1
        var lengths = [Int](repeating: 0, count: (spoken.count + 1) * columns)
        for i in stride(from: spoken.count - 1, through: 0, by: -1) {
            for j in stride(from: written.count - 1, through: 0, by: -1) {
                lengths[i * columns + j] = spoken[i] == written[j]
                    ? lengths[(i + 1) * columns + j + 1] + 1
                    : max(lengths[(i + 1) * columns + j], lengths[i * columns + j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < spoken.count, j < written.count {
            if spoken[i] == written[j] {
                pairs.append((i, j)); i += 1; j += 1
            } else if lengths[(i + 1) * columns + j] >= lengths[i * columns + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    private static func apply(_ edits: [Edit], to text: String) -> String {
        var out = ""
        var cursor = text.startIndex
        for edit in edits.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            out += text[cursor..<edit.range.lowerBound] + edit.replacement
            cursor = edit.range.upperBound
        }
        return out + text[cursor...]
    }
}
