import Foundation

/// One word the pill may offer to add to the person's words after a dictation.
public struct NameCandidate: Sendable, Equatable {
    /// The word as it was pasted, without the punctuation around it or a possessive ending.
    public let word: String
    /// The recogniser's own confidence in it, 0…1.
    public let confidence: Float

    public init(word: String, confidence: Float) {
        self.word = word
        self.confidence = confidence
    }
}

/// Chooses the one word, if any, that a finished dictation offers: a word that looks like a name,
/// that the recogniser was unsure of, and that is new to Hushy. A rule, not a judgement: it never
/// says the word is wrong, only that it is worth asking about.
public enum NameOfferChoice {
    /// The comparison key for a pasted or heard word: `MemoryIndex.key` of the word without its
    /// possessive ending, so "Okonkwo's" and "Okonkwo" are one word.
    public static func key(_ word: String) -> String {
        MemoryIndex.key(bare(word))
    }

    /// - Parameters:
    ///   - pasted: the text that went into the field.
    ///   - confidences: the recogniser's word confidences for this dictation, or nil when it has
    ///     none that line up with the text (vocabulary boosting changed it). Nil offers nothing.
    ///   - index: the person's memory: their words, what each was heard as, and the forgotten ones.
    ///   - knownKeys: keys of words Hushy knows from elsewhere (the Dictionary).
    ///   - offered: keys already offered since the app started; a word is offered once.
    ///   - isDictionaryWord: whether a key is an ordinary dictionary word, in any capitals.
    public static func candidate(
        pasted: String, confidences: [WordConfidence]?, index: MemoryIndex,
        knownKeys: Set<String> = [], skipping offered: Set<String> = [],
        threshold: Float = ConfidenceSpans.Calibration.threshold,
        isDictionaryWord: (String) -> Bool = NameOfferChoice.isDictionaryWord
    ) -> NameCandidate? {
        guard let confidences, !confidences.isEmpty else { return nil }
        // The least sure the recogniser was of each word it wrote.
        var heard: [String: Float] = [:]
        for word in confidences {
            let key = key(word.word)
            guard !key.isEmpty else { continue }
            heard[key] = min(heard[key] ?? word.confidence, word.confidence)
        }
        var best: NameCandidate?
        var startsSentence = true
        for token in CorrectionAlignment.tokens(pasted) {
            defer { startsSentence = token.last.map { ".!?:".contains($0) } ?? false }
            let word = bare(token)
            guard isNameLike(word, startsSentence: startsSentence) else { continue }
            let key = MemoryIndex.key(word)
            // Only a word the recogniser itself wrote, and was unsure of.
            guard let confidence = heard[key], confidence < threshold else { continue }
            guard !offered.contains(key), !knownKeys.contains(key),
                  !isOrdinary(word, isDictionaryWord: isDictionaryWord),
                  !isKnown(word, key: key, in: index) else { continue }
            if confidence < best?.confidence ?? .infinity { best = NameCandidate(word: word, confidence: confidence) }
        }
        return best
    }

    /// An ordinary dictionary word in any capitals ("Friday", "Sarah", "London" count), or a
    /// contraction. With no word list on this Mac every word counts as ordinary, so nothing is
    /// offered: without the list a capital letter alone would decide.
    public static func isDictionaryWord(_ key: String) -> Bool {
        guard !BoostGuard.systemWords.isEmpty else { return true }
        return BoostGuard.isEnglishWord(key, in: BoostGuard.systemWords) || LearningLexicon.shortFunctionWords.contains(key)
    }

    // MARK: Rules

    /// Spoken words that open a sentence with a capital and are in no dictionary.
    static let informalOpeners: Set<String> = [
        "gonna", "wanna", "gotta", "kinda", "sorta", "lemme", "gimme", "dunno", "yeah", "yep", "yup",
        "nope", "nah", "hmm", "uh", "um", "uhh", "umm", "ok", "okay", "hey", "btw", "fyi", "lol",
    ]

    /// The word without the punctuation around it and without a possessive ending.
    static func bare(_ token: String) -> String {
        var word = token.replacingOccurrences(of: "\u{2019}", with: "'")
        word = String(word.drop { !$0.isLetter && !$0.isNumber })
        while let last = word.last, !last.isLetter, !last.isNumber { word.removeLast() }
        if word.lowercased().hasSuffix("'s") { word.removeLast(2) }
        return word
    }

    /// A capital, then letters: three or more, with at most hyphens and apostrophes inside. Not
    /// an acronym (all capitals) and nothing with a digit. The first word of a sentence has its
    /// capital from its place, so there a contraction or a spoken filler is not name-like.
    static func isNameLike(_ word: String, startsSentence: Bool) -> Bool {
        guard let first = word.first, first.isLetter, first.isUppercase else { return false }
        let letters = word.filter(\.isLetter)
        guard letters.count >= 3, word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }) else { return false }
        guard letters.contains(where: \.isLowercase) else { return false }
        if startsSentence, word.contains("'") || informalOpeners.contains(word.lowercased()) { return false }
        return true
    }

    /// Every part of the word (a hyphenated name has several) is a dictionary word.
    private static func isOrdinary(_ word: String, isDictionaryWord: (String) -> Bool) -> Bool {
        word.split(separator: "-").map { MemoryIndex.key(String($0)) }.filter { !$0.isEmpty }.allSatisfy(isDictionaryWord)
    }

    /// Already one of the person's words: as it is spelled, as it was once heard, or close enough
    /// in sound that recall would bring that word up. A forgotten word is never offered.
    private static func isKnown(_ word: String, key: String, in index: MemoryIndex) -> Bool {
        if index.forgottenKeys.contains(key) || index.termsByKey[key] != nil || index.termsByHearing[key] != nil { return true }
        return !TermRecall.recall(word, from: index, limit: 1, isCommonWord: { _ in false }).isEmpty
    }
}

/// How often the pill offers a word. In memory only, so an offer nobody answered leaves no trace
/// once the app quits. One offer, then none for `gap`; the gap doubles each time an offer is
/// ignored or closed and goes back to the base when one is taken.
public struct NameOfferPacing: Sendable, Equatable {
    public static let baseGap: TimeInterval = 10 * 60
    public static let longestGap: TimeInterval = 80 * 60

    public private(set) var lastShownAt: Date?
    /// Offers in a row that were ignored or closed.
    public private(set) var unanswered = 0
    /// Keys offered since the app started: a word is offered once.
    public private(set) var offeredKeys: Set<String> = []

    public init() {}

    public var gap: TimeInterval {
        min(Self.baseGap * pow(2, Double(unanswered)), Self.longestGap)
    }

    public func allows(at now: Date) -> Bool {
        lastShownAt.map { now.timeIntervalSince($0) >= gap } ?? true
    }

    public mutating func shown(_ key: String, at now: Date) {
        lastShownAt = now
        offeredKeys.insert(key)
    }

    public mutating func answered(added: Bool) {
        unanswered = added ? 0 : unanswered + 1
    }
}
