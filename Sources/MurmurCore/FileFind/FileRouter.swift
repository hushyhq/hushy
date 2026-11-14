import Foundation

/// What the file router decided about one utterance.
public enum FileRouting: Sendable, Equatable {
    /// A file request: the typed query, built by rules.
    case file(FileRequest)
    /// The shape of "find my …" with nothing that says "file": the rules don't decide, so the
    /// caller may ask the model once (`FileQueryExtractor`), or treat it as an own-stuff question.
    case undecided
    case no
}

/// Closed grammatical frames, in the order they are read:
///
///     FRAME  := [need-frame | where-frame | VERBS [me]] OBJECT
///     VERBS  := fetch-verb ("and" fetch-verb)*
///     OBJECT := (my | our | the | a | …)? words, with a file word, a kind word or a file noun
///
/// Evidence of a file (a kind word like "pdf" or "slides", the word "file", or a name noun such
/// as "resume" or "invoice") is what makes it a file request. "What is a resume", "how do I
/// write a resume", "find a resume template" and "find my notes about pricing" are not: the
/// frame is wrong, a how-to word is present, or the object is the person's own notes. Judges the
/// frame only, like `AskRouter`; tested in `FileRouterTests`, scored by `murmur-eval files`.
public enum FileRouter {
    public static func decide(_ frame: String, now: Date = Date(), calendar: Calendar = .current) -> FileRouting {
        let tokens = prepared(frame)
        guard let (verbsEnd, action, isVerbFrame) = openingFrame(tokens), verbsEnd < tokens.count else { return .no }
        let object = Array(tokens[verbsEnd...])
        guard let first = object.first, plausibleOpening(first, object: object) else { return .no }
        guard !object.contains(where: FileVocabulary.notAboutFiles.contains) else { return .no }
        let evidence = Evidence(object)
        // "find my X in|on (my) Downloads|Desktop|Documents": a named folder makes it a file request
        // whatever the noun. Needs a possessive and at least one word besides the folder.
        let namesFolder = isVerbFrame && (first == "my" || first == "our") && namesKnownFolder(object)
        // "find my notes about pricing": the person's own stuff, even when it mentions a contract.
        if object.contains(where: FileVocabulary.ownTopics.contains), !evidence.hasKindOrFileWord, !namesFolder { return .no }
        guard evidence.isFile || namesFolder else {
            let possessive = first == "my" || first == "our"
            let hasContent = object.contains { !FileVocabulary.termStopWords.contains($0) && !FileVocabulary.determiners.contains($0) }
            return possessive && isVerbFrame && hasContent && object.count <= 8 ? .undecided : .no
        }
        guard let request = request(from: object, action: action, now: now, calendar: calendar) else { return .no }
        return .file(request)
    }

    /// "my … in|on (my|the) desktop|downloads|documents (folder)" with something left besides it.
    static func namesKnownFolder(_ object: [String]) -> Bool {
        var words = object
        guard takeLocation(&words) != nil else { return false }
        return words.contains { !FileVocabulary.termStopWords.contains($0) && !FileVocabulary.determiners.contains($0) }
    }

    // MARK: - Tokens

    /// Lowercased, accent-folded words with "." and spoken spellings handled ("resume.pdf",
    /// "p d f", "résumé").
    static func prepared(_ frame: String) -> [String] {
        var text = " " + frame.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "/", with: " ") + " "
        for (heard, written) in FileVocabulary.heard {
            let key = heard.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            text = text.replacingOccurrences(of: " \(key) ", with: " \(written) ")
        }
        return text.split(separator: " ").map(String.init)
    }

    /// The index after the opening frame, what it asks (open or reveal), and whether it was a
    /// verb frame ("find my …", as opposed to "i need my …"); nil when no frame opens `tokens`.
    static func openingFrame(_ tokens: [String]) -> (end: Int, action: FileAction, isVerbFrame: Bool)? {
        for phrase in FileVocabulary.whereFrames + FileVocabulary.needFrames {
            let words = phrase.split(separator: " ").map(String.init)
            if tokens.starts(with: words) {
                return (words.count, .reveal, FileVocabulary.whereFrames.contains(phrase))
            }
        }
        var index = 0
        var action = FileAction.reveal
        var sawVerb = false
        while let verb = fetchVerb(at: index, in: tokens) {
            sawVerb = true
            if verb.phrase == "open" { action = .open }
            index += verb.length
            if index < tokens.count, tokens[index] == "me" { index += 1 }
            if index + 1 < tokens.count, tokens[index] == "and", fetchVerb(at: index + 1, in: tokens) != nil {
                index += 1
            } else {
                break
            }
        }
        return sawVerb ? (index, action, true) : nil
    }

    private static func fetchVerb(at index: Int, in tokens: [String]) -> (phrase: String, length: Int)? {
        for phrase in FileVocabulary.fetchVerbs {
            let words = phrase.split(separator: " ").map(String.init)
            if index + words.count <= tokens.count, Array(tokens[index..<index + words.count]) == words {
                return (phrase, words.count)
            }
        }
        return nil
    }

    /// The object may open with a possessive or definite word, or with the file word itself
    /// ("find resume", "open pdf"); "this", "it", "out", "how" and the like are not files.
    private static func plausibleOpening(_ first: String, object: [String]) -> Bool {
        if FileVocabulary.determiners.contains(first) { return true }
        if FileVocabulary.recentWords.contains(first) { return true }
        if kindWord(first) != nil || FileVocabulary.fileWords.contains(first) { return true }
        if FileVocabulary.fileNouns.contains(first) { return true }
        return FileVocabulary.fileNouns.contains(where: { $0.hasPrefix(first + " ") && object.starts(with: $0.split(separator: " ").map(String.init)) })
    }

    static func kindWord(_ token: String) -> FileVocabulary.KindWord? {
        FileVocabulary.kindWords[token] ?? FileVocabulary.kindWords[FileVocabulary.singular(token)]
    }

    // MARK: - Evidence

    struct Evidence {
        var hasKindOrFileWord = false
        var hasNoun = false
        var isFile: Bool { hasKindOrFileWord || hasNoun }

        init(_ object: [String]) {
            for token in object where kindWord(token) != nil || FileVocabulary.fileWords.contains(token) {
                hasKindOrFileWord = true
            }
            let joined = " " + object.map(FileVocabulary.singular).joined(separator: " ") + " "
            let plain = " " + object.joined(separator: " ") + " "
            hasNoun = FileVocabulary.fileNouns.contains { joined.contains(" \($0) ") || plain.contains(" \($0) ") }
        }
    }

    // MARK: - Building the query

    static func request(from object: [String], action: FileAction, now: Date, calendar: Calendar) -> FileRequest? {
        var words = object
        let location = takeLocation(&words)
        let time = takeTime(&words, now: now, calendar: calendar)
        var kind = FileKind.any
        var terms: [String] = []
        for word in words {
            if let entry = kindWord(word), kind == .any {
                kind = entry.kind
                if let name = entry.alsoName { terms.append(name) }
            } else if FileVocabulary.termStopWords.contains(word) || FileVocabulary.determiners.contains(word) {
                continue
            } else if FileVocabulary.fileWords.contains(word) {
                continue
            } else {
                terms.append(word)
            }
        }
        guard let query = FileQuery(terms: Array(terms.prefix(FileQuery.maxTerms)), kind: kind, time: time, location: location)
        else { return nil }
        return FileRequest(query: query, action: action)
    }

    private static let locationPreps: Set<String> = ["on", "in", "from", "inside", "under", "within", "off"]

    /// "on my desktop", "in downloads", "from the documents folder": removes it from `words`.
    static func takeLocation(_ words: inout [String]) -> FileLocation? {
        for (index, word) in words.enumerated() {
            guard let location = FileVocabulary.locations[word] else { continue }
            var start = index
            if start > 0, words[start - 1] == "my" || words[start - 1] == "the" { start -= 1 }
            guard start > 0, locationPreps.contains(words[start - 1]) else { continue }
            var end = index + 1
            if end < words.count, words[end] == "folder" { end += 1 }
            words.removeSubrange((start - 1)..<end)
            return location
        }
        return nil
    }

    private static let monthPreps: Set<String> = ["from", "in", "of", "during", "last", "this", "early", "late"]

    /// "recent", "from march", "in 2024", "march 2024", "last year", "last month": removes it.
    static func takeTime(_ words: inout [String], now: Date, calendar: Calendar) -> FileTimeHint? {
        let year = calendar.component(.year, from: now)
        let month = calendar.component(.month, from: now)
        // Two-word relative spans.
        for index in words.indices.dropLast() where words[index] == "last" || words[index] == "this" {
            let next = words[index + 1]
            let isLast = words[index] == "last"
            switch next {
            case "year":
                words.removeSubrange(index...index + 1)
                return .year(isLast ? year - 1 : year)
            case "month":
                words.removeSubrange(index...index + 1)
                let shifted = isLast ? (month == 1 ? (12, year - 1) : (month - 1, year)) : (month, year)
                return .monthOfYear(month: shifted.0, year: shifted.1)
            case "week":
                words.removeSubrange(index...index + 1)
                return .recent
            default: break
            }
        }
        for (index, word) in words.enumerated() {
            guard let number = FileVocabulary.months[word] else { continue }
            let preceded = index > 0 && monthPreps.contains(words[index - 1])
            let followedByYear = index + 1 < words.count && isYear(words[index + 1])
            guard preceded || followedByYear else { continue }
            var end = index + 1
            var foundYear: Int?
            if followedByYear { foundYear = Int(words[index + 1]); end += 1 }
            let start = preceded ? index - 1 : index
            words.removeSubrange(start..<end)
            if let foundYear { return .monthOfYear(month: number, year: foundYear) }
            return .month(number)
        }
        for (index, word) in words.enumerated() where isYear(word) {
            let preceded = index > 0 && monthPreps.contains(words[index - 1])
            let start = preceded ? index - 1 : index
            let value = Int(word)
            words.removeSubrange(start...index)
            return value.map(FileTimeHint.year)
        }
        if let index = words.firstIndex(where: FileVocabulary.recentWords.contains) {
            words.remove(at: index)
            return .recent
        }
        return nil
    }

    private static func isYear(_ word: String) -> Bool {
        guard word.count == 4, let value = Int(word) else { return false }
        return (1990...2099).contains(value)
    }
}
