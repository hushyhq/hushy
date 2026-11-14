import Foundation

/// What a spoken correction in the draft permits in a model answer, and what it never does.
///
/// A correction takes something back, so under one the answer may leave out a number, a name or a negation the
/// speaker retracted. It may not hold one the speaker did not say. `CriticalTokenGuard` used to skip its
/// number, name and negation checks whenever the draft held a correction cue, so a person who corrected
/// themselves anywhere in a stretch let the model put any number there ("the twentieth no wait the twenty
/// seventh" came back as "the seventh"). Under a cue this holds the answer to the draft instead:
/// - every number in the answer is a number the draft says, compared by value (`SpokenNumberRuns`), so "27th",
///   "twenty seventh" and "27" agree, "4,200" is "forty two hundred", and "forty forty four" is not "forty two"
///   with "forty four";
/// - every capitalised word in the answer, a name at the start of a sentence included, is a word the draft has;
/// - the answer has no more negation than the draft, unless a limit the speaker stated stands behind it
///   (`NegationPolarity`: "too busy" for "I don't have the bandwidth").
/// The reasons are the ones the checks without a cue give, so a span the bound objects to is put back alone
/// (`SpanRepair`) exactly like any other changed number, name or negation.
enum CorrectionBound {
    /// `knownNames` are the person's Dictionary terms and installed apps, which an answer may write for a word that
    /// sounds like one (`KnownProductNames`). With `readsSpokenValues` a number the plain reading cannot find in the draft
    /// is looked for again the way people say numbers (`SpokenValueReading`); the whole-transcript check uses it.
    static func violation(
        answer: String, draft: String, spellingWords: Set<String> = [], knownNames: [String] = [], readsSpokenValues: Bool = false
    ) -> String? {
        if NegationPolarity.addsNegation(answer: answer, draft: draft) { return "added negation" }
        if unsaidNumber(answer: answer, draft: draft), !(readsSpokenValues && saysEveryNumberAsSaid(answer: answer, draft: draft)) {
            return "changed digits"
        }
        if !unsaidNames(answer: answer, draft: draft, spellingWords: spellingWords, knownNames: knownNames).isEmpty {
            return "changed name"
        }
        return nil
    }

    // MARK: Numbers

    private static func unsaidNumber(answer: String, draft: String) -> Bool {
        !SpokenNumberRuns(withoutListMarkers(answer, draft: draft)).isSaid(by: SpokenNumberRuns(draft))
    }

    /// The answer's numbers read the way people say them (`SpokenValueReading`); a list's "1." and "2." are layout.
    private static func saysEveryNumberAsSaid(answer: String, draft: String) -> Bool {
        [answer, SpokenListCounters.withoutMarkers(answer)].contains { answer in
            let reading = SpokenValueReading(answer: answer, draft: draft)
            return reading.asideIsSaid && !unsaidNumber(answer: reading.answer, draft: reading.draft)
        }
    }

    /// A list the model lays out numbers its items 1, 2, 3; those numerals are layout, not numbers the speaker said.
    /// Only a marker that is the next number in order counts as one.
    private static func withoutListMarkers(_ answer: String, draft: String) -> String {
        guard EvalMetrics.listItemCount(answer) > EvalMetrics.listItemCount(draft) else { return answer }
        var next = 1
        return answer.components(separatedBy: "\n").map { line in
            guard let match = Regex.firstMatch(line, "^\\s*(\\d+)[.)]\\s+"), let number = match.string(at: 1, in: line),
                  Int(number) == next else { return line }
            next += 1
            return Regex.replace(line, "^\\s*\\d+[.)]\\s+", with: "")
        }.joined(separator: "\n")
    }

    // MARK: Names

    /// A capitalised word in the answer with no source in the draft. Cleanup has always been free to write what was
    /// said in another form, so these are sources: a sound-alike repair of a spoken span in place (`SpokenNameRepair`:
    /// "get hub" -> "GitHub", "Wensday" -> "Wednesday"); the same word in another case or without diacritics; adjacent
    /// spoken words written as one product or acronym, which has a capital inside it ("type script" -> "TypeScript",
    /// spoken letters "g p t" -> "GPT", never "mary ann" -> "Maryann"); a spoken word, other than ordinary glue, that
    /// the answer word starts with and extends by at most six letters ("tues" -> "Tuesday", "postgres" ->
    /// "PostgreSQL"), where the spoken word has four letters or more, or three and the answer word is a weekday or a
    /// month ("wed" -> "Wednesday"); a spelled-out number. A word that starts a sentence is capitalised whatever it
    /// is, so there ordinary glue (`TokenLexicon.functionWords`) is a source too; so is an ordinary English word there
    /// ("However", "Among"), which no one reads as a name. Written shorter, as the same words are: a title or "OK"
    /// (`abbreviations`), a unit (`unitAbbreviations`), and the initials of words spoken one after the other ("CAGR" for
    /// "compound annual growth rate", `initialism`). And a known product or app name standing where a spoken word that
    /// sounds like it stood ("figment" -> "Figma", `KnownProductNames`).
    /// The capitalised words of `answer` that have no source in `draft` (see `unsaidName`), in order.
    static func unsaidNames(answer: String, draft: String, spellingWords: Set<String> = [], knownNames: [String] = []) -> [String] {
        let spoken = OutputGuard.words(draft).map(folded)
        // Letters said glued to a number are said too: "TRY95" holds "try", "64gb" "gb", "11am" "am", so "TRY-95",
        // "64 GB" and "11 AM" write what was said (default-parity, 2026-11-11).
        let said = Set(spoken).union(spoken.flatMap(lettersBesideDigits))
        return capitalizedWords(in: answer).filter { word in
            let parts = nameParts(word.text).map(folded)
            if parts.isEmpty || parts.allSatisfy(SpokenNumberRuns.isNumberWord) { return false }
            if parts.allSatisfy({ said.contains($0) || expandsASaidWord($0, said) }) { return false }
            if hasInnerCapital(word.text), joinsSpokenWords(parts.joined(), spoken) { return false }
            if isAbbreviation(parts.joined(), said: said) || isInitialism(word.text, spoken: spoken) { return false }
            if word.startsSentence, parts.count == 1, isOrdinaryWord(parts[0]), !followsTitle(word.text, in: answer) { return false }
            if SpokenNameRepair.repairs(word.text, name: folded(parts.joined()), answer: answer, draft: draft) { return false }
            if parts.count == 1, spellingWords.contains(nameParts(word.text)[0].lowercased()),
               SpokenNameRepair.repairsFromBlock(word.text, name: parts[0], answer: answer, draft: draft) { return false }
            if parts.count == 1, KnownProductNames.repairs(word.text, answer: answer, draft: draft, knownNames: knownNames,
                                                            isOrdinaryWord: isOrdinaryWord) { return false }
            return !(word.startsSentence && parts.allSatisfy(TokenLexicon.functionWords.contains))
        }.map(\.text)
    }

    /// The runs of letters in a spoken word that also holds digits ("try95" -> ["try"], "v2beta" -> ["v", "beta"]); none
    /// for a word without digits, so an ordinary word is never cut up.
    static func lettersBesideDigits(_ word: String) -> [String] {
        guard word.contains(where: \.isNumber), word.contains(where: \.isLetter) else { return [] }
        return word.split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    /// Titles and "OK", each with the words that say them.
    private static let abbreviations: [String: Set<String>] = [
        "mr": ["mister"], "mrs": ["missus", "missis", "misses"], "ms": ["miss", "mizz"], "dr": ["doctor"], "prof": ["professor"],
        "ok": ["okay"],
    ]

    /// Units and rates, each with the words that say them ("gig" for a gigabyte, as people do).
    private static let unitAbbreviations: [String: Set<String>] = [
        "kb": ["kilobyte", "kilobytes", "kay"], "mb": ["megabyte", "megabytes", "meg", "megs"],
        "gb": ["gigabyte", "gigabytes", "gig", "gigs"], "tb": ["terabyte", "terabytes", "terra"],
        "kbps": ["kilobits"], "mbps": ["megabits"], "gbps": ["gigabits"],
        "mw": ["megawatt", "megawatts"], "gw": ["gigawatt", "gigawatts"], "kw": ["kilowatt", "kilowatts"],
        "mwh": ["megawatt"], "gwh": ["gigawatt"], "kwh": ["kilowatt"],
    ]

    /// A word the system dictionary lists in lower case and not also as a proper noun: "however" and "among", not "Maya",
    /// "Mark" or "Will", which are names as well.
    private static func isOrdinaryWord(_ word: String) -> Bool {
        BoostGuard.systemWords.contains(word) && !properNouns.contains(word)
    }

    /// The dictionary's capitalised entries, lowercased (empty if the list is not there).
    private static let properNouns: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(text.split(whereSeparator: \.isNewline).filter { $0.first?.isUppercase == true }.map { $0.lowercased() })
    }()

    /// "Mr. Smith": the full stop of a title does not open a sentence, so the word after it is a name, whatever else it is.
    private static func followsTitle(_ word: String, in answer: String) -> Bool {
        answer.range(of: "\\b(?:Mr|Mrs|Ms|Dr|Prof|St|Jr|Sr|Sir|Lady|Lord)\\.\\s+\(NSRegularExpression.escapedPattern(for: word))\\b",
                     options: .regularExpression) != nil
    }

    private static func isAbbreviation(_ name: String, said: Set<String>) -> Bool {
        let spoken = abbreviations[name].map { $0.union([name]) } ?? unitAbbreviations[name]
        return spoken.map { !$0.isDisjoint(with: said) } ?? false
    }

    private static let initialismGlue: Set<String> = ["and", "of", "on", "the", "for", "to", "per", "over", "a"]

    /// True when `name` is all capitals (or capitals and "&") and its letters are the first letters of two to six words
    /// spoken one after the other, leaving out "and", "of" and the like: "CAGR", "M&A", "TV" for the letters said apart. A
    /// plural "s" after the capitals is allowed ("PRs").
    private static func isInitialism(_ name: String, spoken: [String]) -> Bool {
        let core = name.count > 2 && name.hasSuffix("s") ? String(name.dropLast()) : name
        let letters = core.filter(\.isLetter)
        guard letters.count >= 2, letters.count <= 6, core.allSatisfy({ $0 == "&" || $0.isLetter && $0.isUppercase }) else { return false }
        let target = letters.lowercased()
        return spoken.indices.contains { start in
            var initials = ""
            for word in spoken[start...].prefix(12) {
                guard let first = word.first else { continue }
                if initials.isEmpty, initialismGlue.contains(word) { return false }
                if initialismGlue.contains(word) { continue }
                initials.append(first)
                if initials == target { return true }
                if initials.count >= target.count { return false }
            }
            return false
        }
    }

    private static func folded(_ word: String) -> String {
        word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    /// True when two or more adjacent spoken words, written one after the other, are `name`.
    private static func joinsSpokenWords(_ name: String, _ spoken: [String]) -> Bool {
        spoken.indices.contains { start in
            var joined = ""
            for (count, word) in spoken[start...].enumerated() {
                joined += word
                if joined.count > name.count { return false }
                if joined == name { return count >= 1 }
            }
            return false
        }
    }

    private static let contractionEndings = ["n't", "'re", "'ve", "'ll", "'d", "'m"]

    private static func expandsASaidWord(_ part: String, _ said: Set<String>) -> Bool {
        said.contains { spoken in
            guard part.hasPrefix(spoken), part.count - spoken.count <= 6, !TokenLexicon.functionWords.contains(spoken) else { return false }
            return spoken.count >= 4 || spoken.count == 3 && calendarNames.contains(part)
        }
    }

    /// "TypeScript", "GPT", "iPhone": a capital after the first letter marks a product or an acronym.
    private static func hasInnerCapital(_ name: String) -> Bool {
        name.dropFirst().contains(where: \.isUppercase)
    }

    static let calendarNames: Set<String> = Set(
        ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"] + InverseTextNormalizer.months.map { $0.lowercased() }
    )

    private static func capitalizedWords(in text: String) -> [(text: String, startsSentence: Bool)] {
        text.components(separatedBy: .newlines).flatMap(Sentences.split).flatMap { sentence in
            let raws = sentence.split(whereSeparator: \.isWhitespace)
            return raws.enumerated().compactMap { index, raw -> (text: String, startsSentence: Bool)? in
                let token = raw.trimmingCharacters(in: .punctuationCharacters)
                guard let first = token.first, first.isUppercase, token != "I" else { return nil }
                // "I'm", "Don't" are not names; a possessive ("Meera's") and "O'Brien" are.
                let plain = token.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
                if Self.contractionEndings.contains(where: plain.hasSuffix) { return nil }
                // A word after a colon starts the clause it opens ("Wednesday: It is the offsite").
                return (token, index == 0 || raws[index - 1].hasSuffix(":"))
            }
        }
    }

    /// The words of a name without a possessive ending: "Meera's" is "meera", "Anne-Marie" is "anne" and "marie".
    private static func nameParts(_ token: String) -> [String] {
        let bare = token.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "'s", with: "")
        return OutputGuard.words(bare).filter { !$0.contains(where: \.isNumber) }
    }
}
