import Foundation

/// Decides whether an "English only" transcript from the multilingual model (Parakeet Ultra,
/// the v3 family) has drifted into another language and must be re-transcribed with the
/// English-only model (Parakeet v2). Pure decision logic — the re-transcription itself lives in
/// `SpeechEngine` (app) and `Engine` (murmur-eval), which both consult this.
///
/// Why this exists: Ultra's language identification occasionally locks onto the wrong language
/// for a whole utterance — or for its opening sentences — on marginal audio (the whisper-into-
/// Polish incident in .claude/DECISIONS.md, 2026-09-25; the founder's 2026-09-28 note whose
/// first ten seconds came out as Spanish-looking words before the text turned English). v2 has
/// no language-ID step and cannot drift that way, so it is the safe fallback; but it is 2.5–2.9
/// WER points worse on spontaneous speech (docs/research/accent-robustness.md), so it should
/// only run when drift is actually suspected.
///
/// Checks, cheapest first:
/// 1. **Script.** Any letter outside the Latin script (Cyrillic, Greek — both are Ultra output
///    languages) is drift, whatever the length. English never contains them.
/// 2. **Language ID, whole text and per sentence** (the same `NLLanguageRecognizer` path
///    `LanguageMatchGuard` uses for the cleanup model): a confident non-English dominant language
///    for the whole transcript, *or for any single sentence of more than three words*, is drift.
///    The per-sentence pass is what catches partial drift: a transcript that opens with a Spanish
///    sentence and ends in English scores as confident English overall (0.81 for the founder's
///    note, 0.58 Spanish for its first sentence alone) and used to slip through. A confident
///    English result for the whole text and every classifiable sentence is accepted.
/// 3. **Short-input word list.** Language ID is unreliable below a handful of words, so a 1–3
///    word transcript (or a longer one the recognizer can't classify) is checked against the
///    system English word list instead: if more words are unknown to English than known, it is
///    treated as drift. Digits are neutral; letters with diacritics ("dziękuję", "señor") count
///    as unknown even when the base word would pass. Unknown *English* words (a name, jargon)
///    do get sent to v2 by this rule — that is the intended trade: v2 is only slightly worse on
///    English, while a missed drift pastes another language into the user's document.
public enum AsrDriftGuard {
    public enum Reason: String, Sendable, Equatable {
        case nonLatinScript
        case nonEnglishLanguage
        case unrecognizedShortWords
    }

    public enum Decision: Sendable, Equatable {
        case accept
        case fallback(Reason)

        public var needsFallback: Bool {
            if case .fallback = self { return true }
            return false
        }
    }

    /// At or below this many words, language ID is skipped in favour of the word-list rule.
    public static let shortInputWordLimit = 3

    /// Spoken-English tokens missing from the system dictionary's base-form list.
    static let spokenEnglishSupplement: Set<String> = [
        "okay", "gonna", "wanna", "gotta", "kinda", "sorta", "yeah", "yup", "nah", "uh", "um",
        "hmm", "mm", "i'm", "i've", "i'll", "i'd", "you're", "we're", "they're", "it's", "that's",
        "what's", "let's", "there's", "here's", "who's", "he's", "she's", "isn't", "aren't",
        "wasn't", "weren't", "don't", "doesn't", "didn't", "can't", "won't", "wouldn't",
        "shouldn't", "couldn't", "haven't", "hasn't", "hadn't", "ain't",
    ]

    /// Classifies `text`. `englishWords` nil (the default) asks the shipped word-frequency table (`WordFrequency`: a word
    /// is English from `knownThreshold` up); tests inject a small list so they never depend on the table's contents.
    public static func decision(for text: String, englishWords: Set<String>? = nil) -> Decision {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .accept }

        if containsNonLatinLetter(trimmed) { return .fallback(.nonLatinScript) }

        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count > shortInputWordLimit, let detected = LanguageDetector.detect(trimmed) {
            guard detected.isEnglish else { return .fallback(.nonEnglishLanguage) }
            // A transcript whose first sentences drifted and whose rest is English scores as
            // English overall; each sentence long enough to classify is checked on its own.
            for sentence in sentences(of: trimmed) {
                let sentenceWords = sentence.split(whereSeparator: \.isWhitespace)
                guard sentenceWords.count > shortInputWordLimit else { continue }
                if let detected = LanguageDetector.detect(sentence), !detected.isEnglish {
                    return .fallback(.nonEnglishLanguage)
                }
            }
            return .accept
        }
        // 1–3 words, or longer text the recognizer could not classify: word-list majority rule.
        return looksEnglish(words, englishWords: englishWords) ? .accept : .fallback(.unrecognizedShortWords)
    }

    /// Keep the primary result if the second recognizer introduces a repeated lexical piece.
    /// A second ASR pass over the same audio cannot justify new repetitions on its own.
    /// A spoken address ("sample.com") still goes to v2 as an unknown word, on purpose: measured
    /// on 160 synthetic clips, v2 often separates a verb the primary glued onto the address, and
    /// its only harm there was repeating the ending over a noisy tail, which this check refuses.
    public static func acceptsFallback(primary: String, fallback: String) -> Bool {
        let candidate = lexicalPieces(fallback)
        guard !candidate.isEmpty else { return false }
        let original = lexicalPieces(primary)
        let originalCounts = Dictionary(original.map { ($0, 1) }, uniquingKeysWith: +)
        let candidateCounts = Dictionary(candidate.map { ($0, 1) }, uniquingKeysWith: +)
        return !candidateCounts.contains { piece, count in
            piece.count > 1 && count > 1 && count > originalCounts[piece, default: 0]
        }
    }

    private static func lexicalPieces(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Splits on sentence-final punctuation and line breaks, keeping non-empty pieces. Parakeet
    /// emits punctuation, so a drifted opening ("Chala y punto cara na varita.") and the English
    /// that follows land in different pieces.
    static func sentences(of text: String) -> [String] {
        text.split(whereSeparator: { ".!?\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Letters outside the Latin blocks (Basic Latin through Latin Extended-B / IPA, plus Latin
    /// Extended Additional) — Cyrillic, Greek, CJK, Arabic… — checked with `isAlphabetic` so
    /// punctuation, symbols and emoji never trip the check.
    static func containsNonLatinLetter(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            guard scalar.properties.isAlphabetic else { return false }
            let value = scalar.value
            let isLatin = value <= 0x02AF || (0x1E00...0x1EFF).contains(value)
            return !isLatin
        }
    }

    /// True unless strictly more words are unknown to English than known. Words made only of
    /// digits/punctuation are ignored. An empty word list (dictionary unavailable) accepts
    /// anything ASCII, so the guard degrades to the script check rather than sending every
    /// short dictation to v2.
    static func looksEnglish(_ words: [String], englishWords: Set<String>?) -> Bool {
        var known = 0
        var unknown = 0
        for word in words {
            let key = BoostGuard.key(word)
            guard key.contains(where: \.isLetter) else { continue }
            let hasDiacritic = key.unicodeScalars.contains { $0.value > 0x7F }
            if hasDiacritic {
                unknown += 1
            } else if englishWords?.isEmpty == true || isEnglishWord(key, in: englishWords) {
                known += 1
            } else {
                unknown += 1
            }
        }
        return unknown <= known
    }

    static func isEnglishWord(_ key: String, in englishWords: Set<String>?) -> Bool {
        func known(_ word: String) -> Bool {
            englishWords.map { BoostGuard.isEnglishWord(word, in: $0) } ?? WordFrequency.shared.isKnown(word)
        }
        if spokenEnglishSupplement.contains(key) { return true }
        if known(key) { return true }
        // "don't"/"isn't" style contractions not in the supplement: strip and retry the stem.
        if key.hasSuffix("n't") { return known(String(key.dropLast(3))) }
        if let apostrophe = key.firstIndex(of: "'") { return known(String(key[..<apostrophe])) }
        return false
    }
}
