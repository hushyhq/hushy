import Foundation
import MurmurCore

/// A line-by-line Swift port of OpenAI Whisper's `EnglishTextNormalizer`
/// (`whisper/normalizers/english.py` + `basic.py`, MIT License, Copyright (c) 2022 OpenAI) — the
/// normaliser behind Whisper's published WERs and, with later additions, the Hugging Face Open ASR
/// Leaderboard. Used so Hushy's public-benchmark WERs are computed the way everyone else's are.
///
/// Verified against the Python reference on every reference/hypothesis string of the
/// US-English benchmark run (see `docs/product/US-ENGLISH-ACCURACY.md`, "Normalisation") and pinned
/// by `WhisperEnglishNormalizerTests`, whose expected outputs were produced by the Python code.
///
/// Differences from the Python original are limited to inputs where Python would crash (a failed
/// `assert` inside the number normaliser) or integers beyond 64 bits, which keep their digits as
/// text instead of doing arithmetic.
///
/// The Open ASR Leaderboard has since extended this normaliser (more filler spellings, a name and
/// acronym map, compound words, bare "3:00" times); `version` says which one produced a number.
enum WhisperEnglishNormalizer {
    static let version = "whisper-en"

    /// The normalised string (single spaces; may carry a leading/trailing space like the original).
    static func normalize(_ input: String) -> String {
        var s = input.lowercased()
        s = Pattern.brackets.replace(s, with: "")
        s = Pattern.parentheses.replace(s, with: "")
        s = Pattern.fillers.replace(s, with: "")
        s = Pattern.spaceBeforeApostrophe.replace(s, with: "'")
        for (pattern, replacement) in Pattern.replacers {
            s = pattern.replace(s, with: replacement)
        }
        s = Pattern.digitComma.replace(s, with: "$1$2")
        s = Pattern.periodNotBeforeDigit.replace(s, with: " $1")
        s = removeSymbolsAndDiacritics(s, keep: ".%$¢€£")
        s = WhisperNumberNormalizer.normalize(s)
        s = s.split(whereSeparator: \.isWhitespace).map { BritishAmericanSpellings.map[String($0)] ?? String($0) }
            .joined(separator: " ")
        s = Pattern.strayCurrencyOrPeriod.replace(s, with: " $1")
        s = Pattern.strayPercent.replace(s, with: "$1 ")
        s = Pattern.whitespace.replace(s, with: " ")
        return s
    }

    /// Normalised tokens, the unit WER is computed over.
    static func words(_ text: String) -> [String] {
        normalize(text).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Corpus WER (total edits / total reference words) after Whisper normalisation. Pairs whose
    /// reference normalises to nothing are skipped, as the Open ASR Leaderboard's
    /// `is_target_text_in_range` filter does.
    static func corpusWER(_ pairs: [(reference: String, hypothesis: String)]) -> Double {
        let totals = editTotals(pairs)
        return totals.words == 0 ? 0 : Double(totals.edits) / Double(totals.words)
    }

    static func editTotals(_ pairs: [(reference: String, hypothesis: String)]) -> (edits: Int, words: Int) {
        var edits = 0
        var words = 0
        for pair in pairs {
            let reference = self.words(pair.reference)
            guard !reference.isEmpty else { continue }
            edits += EvalMetrics.editDistance(reference, self.words(pair.hypothesis))
            words += reference.count
        }
        return (edits, words)
    }

    // MARK: basic.py

    /// Non-ASCII letters NFKD does not split into base + mark.
    static let additionalDiacritics: [Unicode.Scalar: String] = [
        "œ": "oe", "Œ": "OE", "ø": "o", "Ø": "O", "æ": "ae", "Æ": "AE", "ß": "ss", "ẞ": "SS",
        "đ": "d", "Đ": "D", "ð": "d", "Ð": "D", "þ": "th", "Þ": "th", "ł": "l", "Ł": "L",
    ]

    /// Replaces marks, symbols and punctuation with a space and drops combining diacritics (category
    /// Mn), keeping the characters in `keep` — Python's `remove_symbols_and_diacritics`.
    static func removeSymbolsAndDiacritics(_ s: String, keep: String) -> String {
        let kept = Set(keep.unicodeScalars)
        var out = String.UnicodeScalarView()
        for scalar in s.decomposedStringWithCompatibilityMapping.unicodeScalars {
            if kept.contains(scalar) {
                out.append(scalar)
            } else if let replacement = additionalDiacritics[scalar] {
                out.append(contentsOf: replacement.unicodeScalars)
            } else {
                switch scalar.properties.generalCategory {
                case .nonspacingMark:
                    continue
                case .spacingMark, .enclosingMark,
                     .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol,
                     .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                     .initialPunctuation, .finalPunctuation, .otherPunctuation:
                    out.append(" ")
                default:
                    out.append(scalar)
                }
            }
        }
        return String(out)
    }

    // MARK: Patterns (english.py `EnglishTextNormalizer.__init__` / `__call__`)

    enum Pattern {
        static let brackets = PyRegex(#"[<\[][^>\]]*[>\]]"#)
        static let parentheses = PyRegex(#"\(([^)]+?)\)"#)
        static let fillers = PyRegex(#"\b(hmm|mm|mhm|mmm|uh|um)\b"#)
        static let spaceBeforeApostrophe = PyRegex(#"\s+'"#)
        static let digitComma = PyRegex(#"(\d),(\d)"#)
        static let periodNotBeforeDigit = PyRegex(#"\.([^0-9]|$)"#)
        static let strayCurrencyOrPeriod = PyRegex(#"[.$¢€£]([^0-9])"#)
        static let strayPercent = PyRegex(#"([^0-9])%"#)
        static let whitespace = PyRegex(#"\s+"#)

        /// In the original's (insertion) order; each runs over the whole string in turn.
        static let replacers: [(PyRegex, String)] = [
            // common contractions
            (#"\bwon't\b"#, "will not"), (#"\bcan't\b"#, "can not"), (#"\blet's\b"#, "let us"),
            (#"\bain't\b"#, "aint"), (#"\by'all\b"#, "you all"), (#"\bwanna\b"#, "want to"),
            (#"\bgotta\b"#, "got to"), (#"\bgonna\b"#, "going to"), (#"\bi'ma\b"#, "i am going to"),
            (#"\bimma\b"#, "i am going to"), (#"\bwoulda\b"#, "would have"), (#"\bcoulda\b"#, "could have"),
            (#"\bshoulda\b"#, "should have"), (#"\bma'am\b"#, "madam"),
            // contractions in titles/prefixes
            (#"\bmr\b"#, "mister "), (#"\bmrs\b"#, "missus "), (#"\bst\b"#, "saint "), (#"\bdr\b"#, "doctor "),
            (#"\bprof\b"#, "professor "), (#"\bcapt\b"#, "captain "), (#"\bgov\b"#, "governor "),
            (#"\bald\b"#, "alderman "), (#"\bgen\b"#, "general "), (#"\bsen\b"#, "senator "),
            (#"\brep\b"#, "representative "), (#"\bpres\b"#, "president "), (#"\brev\b"#, "reverend "),
            (#"\bhon\b"#, "honorable "), (#"\basst\b"#, "assistant "), (#"\bassoc\b"#, "associate "),
            (#"\blt\b"#, "lieutenant "), (#"\bcol\b"#, "colonel "), (#"\bjr\b"#, "junior "),
            (#"\bsr\b"#, "senior "), (#"\besq\b"#, "esquire "),
            // perfect tenses
            (#"'d been\b"#, " had been"), (#"'s been\b"#, " has been"), (#"'d gone\b"#, " had gone"),
            (#"'s gone\b"#, " has gone"), (#"'d done\b"#, " had done"), (#"'s got\b"#, " has got"),
            // general contractions
            (#"n't\b"#, " not"), (#"'re\b"#, " are"), (#"'s\b"#, " is"), (#"'d\b"#, " would"),
            (#"'ll\b"#, " will"), (#"'t\b"#, " not"), (#"'ve\b"#, " have"), (#"'m\b"#, " am"),
        ].map { (PyRegex($0.0), $0.1) }
    }
}

/// A precompiled `NSRegularExpression` with Python-`re.sub`-style replacement. Templates use `$1`
/// for groups (NSRegularExpression syntax); literal replacements must not contain `$` or `\`.
struct PyRegex: @unchecked Sendable {
    let expression: NSRegularExpression

    init(_ pattern: String) {
        // The patterns are compile-time constants; a failure here is a programming error.
        // swiftlint:disable:next force_try
        expression = try! NSRegularExpression(pattern: pattern)
    }

    func replace(_ s: String, with template: String) -> String {
        expression.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// Replaces each match with `transform(groups)`, where `groups[0]` is the whole match and a
    /// group that did not participate is "".
    func replace(_ s: String, transform: ([String]) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var cursor = 0
        for match in expression.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            out += transform(groups)
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    func split(_ s: String) -> [String] {
        let ns = s as NSString
        var parts: [String] = []
        var cursor = 0
        for match in expression.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            parts.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            cursor = match.range.location + match.range.length
        }
        parts.append(ns.substring(from: cursor))
        return parts
    }

    func matches(_ s: String) -> Bool {
        expression.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
