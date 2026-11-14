import Foundation

/// English text normalization for ASR corpus WER, in the style of Whisper's `EnglishTextNormalizer`
/// and the ESB (End-to-end Speech Benchmark) normalizer: designed to strip scoring artefacts that
/// are not genuine recognition errors (number format, contractions, spelling variants, hyphenation,
/// filler words) so WER reflects what the model actually got wrong, applied identically to every
/// engine so no engine is favored by normalization choices.
///
/// Versioned explicitly (`version`) because normalization changes are not comparable to older
/// results computed with a different normalizer; `Evals/results.md` labels which version produced
/// each number.
public enum EvalTextNormalizer {
    /// Bump this whenever the normalization rules change; recorded next to every corpus WER.
    public static let version = "esb-v1"

    /// Normalizes text into a flat list of comparison tokens: lowercased, contractions expanded,
    /// multi-word and single-word number words converted to digits, US/UK spelling folded to one
    /// form, hyphenated compounds split, symbols (%, $, &, #) spelled out, standalone fillers
    /// ("uh", "um", "erm", "mm") dropped, and punctuation/whitespace collapsed.
    public static func normalizedWords(_ text: String) -> [String] {
        var t = text.lowercased()
        t = t.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
        t = expandContractions(t)
        t = spellOutSymbols(t)
        t = splitHyphenatedCompounds(t)
        var words = tokenize(t)
        words = words.map { ukToUS[$0] ?? $0 }
        words = collapseNumberWords(words)
        words = words.compactMap { fillers.contains($0) ? nil : $0 }
        return words.filter { !$0.isEmpty }
    }

    /// Word-level Levenshtein distance, reused from `EvalMetrics` (same algorithm, different token stream).
    public static func editDistance(_ reference: [String], _ hypothesis: [String]) -> Int {
        EvalMetrics.editDistance(reference, hypothesis)
    }

    public static func wer(reference: String, hypothesis: String) -> Double {
        let ref = normalizedWords(reference)
        guard !ref.isEmpty else { return normalizedWords(hypothesis).isEmpty ? 0 : 1 }
        return Double(editDistance(ref, normalizedWords(hypothesis))) / Double(ref.count)
    }

    public static func corpusWER(_ pairs: [(reference: String, hypothesis: String)]) -> Double {
        var edits = 0
        var words = 0
        for pair in pairs {
            let ref = normalizedWords(pair.reference)
            edits += editDistance(ref, normalizedWords(pair.hypothesis))
            words += ref.count
        }
        return words == 0 ? 0 : Double(edits) / Double(words)
    }

    // MARK: Tokenization

    private static func tokenize(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    // MARK: Contractions (expand so "it's" == "it is", "don't" == "do not", …)

    /// Irregular contractions that don't follow the generic suffix rule below (the stem changes,
    /// not just the ending): "won't" -> "will not", not "won" + " not".
    private static let irregularContractions: [String: String] = [
        "won't": "will not", "can't": "cannot", "shan't": "shall not", "ain't": "is not",
        "let's": "let us", "y'all": "you all",
        "it's": "it is", "that's": "that is", "there's": "there is", "here's": "here is",
        "what's": "what is", "who's": "who is", "he's": "he is", "she's": "she is",
        "how's": "how is", "where's": "where is", "when's": "when is", "why's": "why is",
    ]

    /// Generic possessive/verb-suffix contractions: strip the suffix from the stem and append the
    /// expansion as a separate word ("don't" -> "do" + " not", "we're" -> "we" + " are").
    private static let suffixExpansions: [(suffix: String, expansion: String)] = [
        ("n't", " not"), ("'re", " are"), ("'ve", " have"), ("'ll", " will"),
        ("'d", " would"), ("'m", " am"), ("'s", " is"),
    ]

    private static func expandContractions(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        for word in words {
            let stripped = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
            if let irregular = irregularContractions[stripped] {
                out.append(irregular)
                continue
            }
            var handled = false
            for (suffix, expansion) in suffixExpansions where stripped.hasSuffix(suffix) && stripped.count > suffix.count {
                out.append(String(stripped.dropLast(suffix.count)) + expansion)
                handled = true
                break
            }
            if !handled { out.append(word) }
        }
        return out.joined(separator: " ")
    }

    // MARK: Symbols

    private static func spellOutSymbols(_ text: String) -> String {
        var result = text
        // Currency: "$5" is spoken "five dollars" (amount first, unit after), so move the
        // symbol's word after the digits it prefixes rather than replacing it in place.
        result = result.replacingOccurrences(
            of: "\\$\\s*([0-9][0-9.,]*)", with: "$1 dollars", options: .regularExpression)
        result = result.replacingOccurrences(of: "%", with: " percent ")
        result = result.replacingOccurrences(of: "&", with: " and ")
        result = result.replacingOccurrences(of: "$", with: " dollars ")
        result = result.replacingOccurrences(of: "#", with: " number ")
        result = result.replacingOccurrences(of: "@", with: " at ")
        result = result.replacingOccurrences(of: "+", with: " plus ")
        return result
    }

    // MARK: Hyphenation / compounds ("check-in" == "check in", "e-mail" == "email")

    private static func splitHyphenatedCompounds(_ text: String) -> String {
        text.replacingOccurrences(of: "-", with: " ")
    }

    // MARK: US/UK spelling (fold to US spelling, the more common ASR training convention)

    private static let ukToUS: [String: String] = [
        "colour": "color", "colours": "colors", "favour": "favor", "favours": "favors",
        "favourite": "favorite", "favourites": "favorites", "honour": "honor", "honours": "honors",
        "labour": "labor", "labours": "labors", "neighbour": "neighbor", "neighbours": "neighbors",
        "behaviour": "behavior", "behaviours": "behaviors", "centre": "center", "centres": "centers",
        "theatre": "theater", "theatres": "theaters", "metre": "meter", "metres": "meters",
        "litre": "liter", "litres": "liters", "fibre": "fiber", "fibres": "fibers",
        "organise": "organize", "organised": "organized", "organising": "organizing",
        "organisation": "organization", "organisations": "organizations",
        "realise": "realize", "realised": "realized", "realising": "realizing",
        "recognise": "recognize", "recognised": "recognized", "recognising": "recognizing",
        "apologise": "apologize", "apologised": "apologized", "apologising": "apologizing",
        "analyse": "analyze", "analysed": "analyzed", "analysing": "analyzing",
        "travelling": "traveling", "travelled": "traveled", "traveller": "traveler",
        "cancelled": "canceled", "cancelling": "canceling", "cancellation": "cancelation",
        "modelling": "modeling", "modelled": "modeled", "counselling": "counseling",
        "defence": "defense", "offence": "offense", "licence": "license", "practise": "practice",
        "grey": "gray", "programme": "program", "programmes": "programs",
        "catalogue": "catalog", "catalogues": "catalogs", "dialogue": "dialog", "dialogues": "dialogs",
        "cheque": "check", "cheques": "checks", "tyre": "tire", "tyres": "tires",
        "aluminium": "aluminum", "mould": "mold", "moulds": "molds", "jewellery": "jewelry",
        "ageing": "aging", "enrol": "enroll", "enrolment": "enrollment", "fulfil": "fulfill",
        "fulfilment": "fulfillment", "skilful": "skillful", "wilful": "willful",
        "utilise": "utilize", "utilised": "utilized", "utilising": "utilizing",
        "specialise": "specialize", "specialised": "specialized", "specialising": "specializing",
        "mum": "mom", "mummy": "mommy",
    ]

    // MARK: Fillers (drop when standalone; symmetric across reference and hypothesis)

    private static let fillers: Set<String> = ["uh", "um", "erm", "uhh", "umm", "mm", "hmm", "mhm", "huh"]

    // MARK: Numbers: single- and multi-word number phrases -> digits ("twenty three" -> "23")

    private static let unitsMap: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tensMap: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
        "eighty": 80, "ninety": 90,
    ]
    private static let scaleMap: [String: Int] = [
        "hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000,
    ]
    private static let ordinalMap: [String: String] = [
        "first": "1st", "second": "2nd", "third": "3rd", "fourth": "4th", "fifth": "5th",
        "sixth": "6th", "seventh": "7th", "eighth": "8th", "ninth": "9th", "tenth": "10th",
        "eleventh": "11th", "twelfth": "12th", "twentieth": "20th", "thirtieth": "30th",
    ]

    /// Scans left to right, greedily grouping runs of number words ("twenty three thousand five
    /// hundred") into a single numeric token, matching how Whisper's normalizer and most WER
    /// tooling treat spelled-out numbers as equivalent to digits regardless of grouping.
    static func collapseNumberWords(_ words: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            if word == "okay" || word == "o" && index + 1 < words.count && words[index + 1] == "k" {
                result.append("ok")
                index += word == "okay" ? 1 : 2
                continue
            }
            if let ordinal = ordinalMap[word] {
                result.append(ordinal)
                index += 1
                continue
            }
            if unitsMap[word] != nil || tensMap[word] != nil || word == "and" && isMidNumber(words, index) {
                if let (value, consumed) = parseNumberPhrase(words, from: index) {
                    result.append(String(value))
                    index += consumed
                    continue
                }
            }
            result.append(numberWordFallback[word] ?? word)
            index += 1
        }
        return result
    }

    /// "and" only counts as part of a number phrase ("one hundred and five") when flanked by
    /// number words on both sides, so ordinary "and" is untouched.
    private static func isMidNumber(_ words: [String], _ index: Int) -> Bool {
        guard index > 0, index + 1 < words.count else { return false }
        let before = words[index - 1]
        let after = words[index + 1]
        let beforeIsNumber = unitsMap[before] != nil || tensMap[before] != nil || scaleMap[before] != nil
        let afterIsNumber = unitsMap[after] != nil || tensMap[after] != nil
        return beforeIsNumber && afterIsNumber
    }

    /// Parses the longest number phrase starting at `from`, returning its value and how many
    /// tokens it consumed, or nil if `from` isn't the start of a number phrase.
    private static func parseNumberPhrase(_ words: [String], from start: Int) -> (value: Int, consumed: Int)? {
        var index = start
        var total = 0
        var current = 0
        var consumed = 0
        var sawAny = false
        while index < words.count {
            let word = words[index]
            if let unit = unitsMap[word] {
                current += unit
                sawAny = true
            } else if let tens = tensMap[word] {
                current += tens
                sawAny = true
            } else if let scale = scaleMap[word] {
                if scale == 100 {
                    current = max(current, 1) * scale
                } else {
                    total += max(current, 1) * scale
                    current = 0
                }
                sawAny = true
            } else if word == "and", isMidNumber(words, index) {
                // Skip the linking "and"; it does not change the running value.
            } else {
                break
            }
            index += 1
            consumed = index - start
        }
        guard sawAny else { return nil }
        return (total + current, consumed)
    }

    private static let numberWordFallback: [String: String] = [
        "okay": "ok", "o.k": "ok",
    ]
}
