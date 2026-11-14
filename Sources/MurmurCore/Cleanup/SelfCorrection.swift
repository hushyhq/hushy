import Foundation

/// Resolves spoken self-corrections such as "let's meet at 10, no, 9" -> "let's meet at 9".
///
/// Strategy: find a correction cue set off by commas, then decide which trailing span of the
/// text before the cue is replaced by the head of the text after it. The span is chosen by
/// matching the replacement's kind (number, weekday, month, name) or an anchor word it
/// repeats ("to the park, no, to the beach"). When no rule is confident, the text is left
/// untouched and the cue is reported as unresolved, so we never guess destructively.
enum SelfCorrection {
    struct Outcome {
        let text: String
        let unresolvedCues: Int
    }

    /// Cues that almost always signal a correction when set off by commas.
    /// Longest alternatives first: with "no" first, "…, no wait, the 19th" matched the cue "no"
    /// and left "wait, the 19th" as the replacement, so the swap never resolved.
    private static let strongCue = "(?:sorry,?\\s+I mean[t]?|no,?\\s+I mean[t]?|no wait|no no|nope|no|wait,? no|sorry|oops|I meant|I mean|correction|make that|rather)"
    /// "actually" is often used literally, so it only applies when kinds match.
    private static let weakCue = "(?:actually|wait)"
    private static let openingRequestVerbs: Set<String> = [
        "ask", "tell", "send", "notify", "email", "invite", "contact", "remind", "thank",
    ]

    static func apply(_ text: String) -> Outcome {
        var current = text
        var unresolved = 0
        // Resolve repeatedly: one utterance can contain several corrections.
        for _ in 0..<8 {
            guard let step = resolveFirst(current) else { break }
            switch step {
            case .resolved(let next): current = next
            case .unresolved(let next):
                unresolved += 1
                current = next
            }
        }
        return Outcome(text: current.replacingOccurrences(of: protectedMarker, with: ""), unresolvedCues: unresolved)
    }

    private enum Step {
        case resolved(String)
        /// Cue found but not confidently resolvable; returns text with the cue protected from reprocessing.
        case unresolved(String)
    }

    private static let protectedMarker = "\u{2060}"

    private static func resolveFirst(_ text: String) -> Step? {
        for (cue, isStrong) in [(strongCue, true), (weakCue, false)] {
            let pattern = "^(.+?)(?:,|[—–])\\s*\(cue)[,.]?\\s+(?!\(protectedMarker))(.+)$"
            guard let match = Regex.firstMatch(text, pattern),
                  let before = match.string(at: 1, in: text),
                  let after = match.string(at: 2, in: text)
            else { continue }

            if let replaced = replace(before: before, after: after, requireKindMatch: !isStrong) {
                return .resolved(replaced)
            }
            if isStrong {
                // Leave the words alone but mark this cue so we do not loop on it.
                let cueRange = match.range(at: 2)
                if let range = Range(cueRange, in: text) {
                    var marked = text
                    marked.insert(contentsOf: protectedMarker, at: range.lowerBound)
                    return .unresolved(marked)
                }
            }
        }
        return nil
    }

    /// "the offline ones", "the new one": the replacement stands for a noun the swapped span
    /// holds. `FrameCorrection.headNoun` restores it when it can; when it declined, swapping
    /// from the anchor would drop the noun ("the online maps, no, the offline ones" → "the
    /// offline ones"), so the cue is left for the model instead.
    ///
    /// Likewise a replacement that opens a new clause ("…, sorry, the report was late", "…, no,
    /// the price doesn't matter") is not a swap for the anchored words: swapping gave "I sent
    /// the report was late".
    private static func refersBack(_ afterTokens: [Token]) -> Bool {
        let head = afterTokens.prefix(5).dropFirst()
        return head.contains { ["one", "ones"].contains($0.normalized) }
            || afterTokens.prefix(4).dropFirst().contains { FrameCorrection.clauseVerbs.contains($0.normalized) }
    }

    /// True when an anchored swap would replace one slot, not a clause: the words it drops hold
    /// no finite verb ("The team meeting is at 9 AM, I mean the standup starts then" clarifies a
    /// complete clause; swapping from "the" deleted it), and every time, date, number or name
    /// they hold has a counterpart of the same kind early in the replacement ("I sent it to
    /// Priya, I mean the whole team has it" would lose "Priya"). `span` is indexed from the
    /// sentence start (index 0 = its first word). Otherwise the cue is left for the model.
    private static func isSameSlot(_ span: ArraySlice<Token>, replacedBy afterTokens: [Token]) -> Bool {
        guard !span.contains(where: { FrameCorrection.clauseVerbs.contains($0.normalized) }) else { return false }
        let replacementKinds = afterTokens.prefix(6).compactMap(\.kind)
        return span.indices.allSatisfy { index in
            let token = span[index]
            guard let kind = token.kind, kind != .word else { return true }
            // The sentence's first word is capitalised by casing, not because it is a name.
            if kind == .name, index == 0 { return true }
            return replacementKinds.contains { $0.isCompatible(with: kind) }
        }
    }

    private static func replace(before: String, after: String, requireKindMatch: Bool) -> String? {
        let beforeTokens = Token.split(before)
        let afterTokens = Token.split(after)
        guard let head = afterTokens.first, !beforeTokens.isEmpty else { return nil }

        // Correction must stay within the current sentence of `before`.
        let sentenceStart = (beforeTokens.lastIndex { $0.endsSentence } ?? -1) + 1
        let candidates = Array(beforeTokens[sentenceStart...])
        guard !candidates.isEmpty else { return nil }

        let spanStart: Int?
        if let kind = head.kind, kind != .word {
            // Walk back from the last matching-kind token to the start of its contiguous run,
            // so a multi-word number ("twenty five") is replaced as a whole rather than just
            // its last word ("five") — "twenty five, no, fifteen" should drop all of "twenty
            // five", not leave "twenty" behind from a stale earlier word.
            //
            // An opening capital is sentence casing unless the clause is the name itself
            // ("Sarah, sorry, John", "Sarah Connor, sorry, John Smith"). Matching it inside a
            // longer clause deleted the clause ("Ship the patch tonight, sorry, Finance…").
            let openingIsOnlyCasing = kind == .name && (
                !candidates.allSatisfy { $0.kind == .name }
                    || openingRequestVerbs.contains(candidates[0].normalized))
            if let lastMatch = candidates.indices.last(where: { index in
                guard candidates[index].kind?.isCompatible(with: kind) == true else { return false }
                if openingIsOnlyCasing, index == 0 { return false }
                return true
            }) {
                // A name run is only as long as the name that replaces it: "Ask Maria, sorry, Mark"
                // swaps one word (the sentence's capital "Ask" is casing, not a name), "Sarah
                // Connor, sorry, John Smith" swaps two.
                let maxRun = kind == .name ? max(1, afterTokens.prefix { $0.kind == .name }.count) : Int.max
                var runStart = lastMatch
                while runStart > 0, !(openingIsOnlyCasing && runStart == 1), lastMatch - runStart + 1 < maxRun,
                      candidates[runStart - 1].kind?.isCompatible(with: kind) == true {
                    runStart -= 1
                }
                // The month matches in "March is the launch window, sorry, June is only the
                // rehearsal", but the span holds a finite verb, so the cue is a new clause.
                spanStart = isSameSlot(candidates[runStart...], replacedBy: afterTokens)
                    && preservesSlotTail(candidates[runStart...], replacedBy: afterTokens)
                    ? runStart + sentenceStart : nil
            } else {
                spanStart = nil
            }
        } else if !requireKindMatch, !refersBack(afterTokens),
                  let anchor = candidates.lastIndex(where: { $0.normalized == head.normalized && head.isFunctionWord }),
                  isSameSlot(candidates[anchor...], replacedBy: afterTokens) {
            // "go to the park, no, to the beach": the repeated word marks where the swap starts.
            spanStart = anchor + sentenceStart
        } else {
            // Anything else ("tomato, no, forget the tomato") needs understanding, not rules:
            // leave it for the language-model pass rather than guess destructively.
            spanStart = nil
        }

        guard let start = spanStart else { return nil }
        let kept = beforeTokens[..<start].map(\.text).joined(separator: " ")
        let joined = kept.isEmpty ? after : kept + " " + after
        return joined.replacingOccurrences(of: protectedMarker, with: "")
    }

    /// Kind matching alone cannot license deleting ordinary words after the value or name.
    /// A shared tail ("four people, no, six people") survives; an unlisted verb in a clause
    /// ("March slipped badly, sorry, June is…") cannot disappear just because it is not in
    /// `clauseVerbs`.
    private static func preservesSlotTail(_ span: ArraySlice<Token>, replacedBy after: [Token]) -> Bool {
        let ordinary = span.filter { $0.kind == .word || $0.kind == nil }.map(\.normalized)
        let replacementTail = after.drop(while: { $0.kind != .word && $0.kind != nil })
        return ordinary == replacementTail.prefix(ordinary.count).map(\.normalized)
    }
}

/// A whitespace-delimited word plus a little classification.
struct Token {
    enum Kind: Equatable {
        case number, weekday, month, time, name, word

        func isCompatible(with other: Kind) -> Bool {
            let temporal: Set<Kind> = [.number, .time]
            return self == other || (temporal.contains(self) && temporal.contains(other))
        }
    }

    let text: String

    var normalized: String {
        text.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    var endsSentence: Bool { text.last.map { ".!?".contains($0) } ?? false }
    var endsClause: Bool { text.last.map { ",;:.!?".contains($0) } ?? false }

    var isFunctionWord: Bool {
        ["to", "at", "on", "in", "for", "with", "the", "a", "an", "from", "by", "into", "of"].contains(normalized)
    }

    var kind: Kind? {
        let word = normalized
        guard !word.isEmpty else { return nil }
        if Token.weekdays.contains(word) { return .weekday }
        if Token.months.contains(word) { return .month }
        if word.range(of: "^\\d{1,2}(:\\d{2})?(am|pm)?$", options: .regularExpression) != nil,
           word.contains(":") || word.hasSuffix("am") || word.hasSuffix("pm") {
            return .time
        }
        if word.range(of: "^[$€£]?\\d[\\d,.]*[%kmb]?$", options: .regularExpression) != nil { return .number }
        if Token.numberWords.contains(word) { return .number }
        // "I", "I'm", "I've"…: a capital that is the pronoun, not a name — "Elena, sorry I'm late"
        // read "I'm" as a name correcting "Elena" and dropped both the name and the apology.
        // A capitalised function word ("The", "To") is sentence casing, never a name.
        if let first = text.first, first.isUppercase, !Token.firstPersonSingular.contains(word), !isFunctionWord {
            return .name
        }
        return .word
    }

    static func split(_ text: String) -> [Token] {
        text.split(whereSeparator: { $0 == " " }).map { Token(text: String($0)) }
    }

    private static let firstPersonSingular: Set<String> = [
        "i", "i'm", "i've", "i'll", "i'd", "i\u{2019}m", "i\u{2019}ve", "i\u{2019}ll", "i\u{2019}d",
    ]
    private static let weekdays: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "today", "tomorrow", "tonight", "yesterday",
    ]
    private static let months: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
    ]
    private static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "fifteen", "twenty", "thirty", "forty", "fifty", "hundred",
    ]
}

/// A one-word self-repair spoken without a pause the ASR could punctuate — "Indian English with
/// Ameri sorry Indian accent", "on the Tues- no Wednesday call", "send it to Mar I mean Maria".
/// `SelfCorrection` only resolves a cue after a comma, so these reached the model, which
/// sometimes *completed the abandoned fragment* ("…with American accent") instead of keeping
/// the word after the cue. The replacement is always the word after the cue.
///
/// Only strong repair cues ("sorry", "I mean", "I meant", "oops", "no wait"), plus a bare "no"
/// when the abandoned word is visibly cut off (ends in "-"). Never across a sentence break after
/// the cue, and never "I mean," with a comma (a discourse marker, not a repair). Conservative
/// about the apology "sorry": the word before the cue must not be a pronoun, auxiliary or degree
/// word ("I'm sorry", "is sorry", "really sorry"), and the word after it must be a content word,
/// not a function word ("sorry about", "sorry for", "sorry to", "sorry you").
enum FragmentRepair {
    private static let notRepairable: Set<String> = [
        "i", "i'm", "im", "we", "we're", "you", "you're", "they", "they're", "he", "she", "it",
        "is", "am", "are", "was", "were", "be", "been", "feel", "feels", "felt", "so", "very",
        "really", "truly", "deeply", "terribly", "awfully", "too", "not", "say", "said", "just",
        "and", "but", "or", "the", "a", "an", "to", "of",
        // "What I mean is…", "That I mean…": a wh-word or demonstrative before "I mean" opens a
        // clarification, not a repair.
        "what", "that", "which", "who", "how", "why", "where", "when", "this", "all", "if",
    ]
    private static let functionWords: Set<String> = [
        "about", "for", "to", "you", "i", "we", "that", "if", "but", "and", "it", "this", "the",
        "a", "an", "guys", "everyone", "all", "again", "though", "man", "dude", "folks", "no",
        "is", "was", "are", "were", "it's", "that's", "it", "in", "on", "at", "of", "with", "so",
        // "could you notify chen no wait just remind him": the repair is a new clause, not a
        // word replacing "chen" (that gave "Could you notify just remind him").
        "just", "him", "her", "them", "me", "us", "actually", "instead",
        // A determiner or possessive after the cue opens a new noun phrase ("the deploy is slow I
        // mean my team owns it"), so it is no one-word replacement for the word before the cue.
        "my", "our", "your", "their", "his", "its", "these", "those", "some", "any", "every", "each", "another",
    ]

    /// A word after the replacement that starts a predicate, so the replacement is the subject of a
    /// new clause: auxiliaries and irregular past forms, plus the regular "-ed" / "-s" shapes.
    private static let clauseVerbs: Set<String> = [
        "is", "are", "was", "were", "has", "have", "had", "will", "would", "can", "could", "should", "must",
        "may", "might", "does", "did", "went", "ran", "made", "took", "got", "sent", "built", "left", "found",
        "came", "said", "saw", "knew", "wrote", "gave", "told", "kept", "held", "met", "paid", "won", "lost",
    ]
    /// Words that end like a verb but are adverbs or time words.
    private static let notVerbLike: Set<String> = [
        "always", "sometimes", "perhaps", "besides", "towards", "afterwards", "otherwise", "whereas", "thanks",
        "yesterday", "today", "tomorrow", "tonight", "status", "access", "process", "business", "news", "series",
    ]
    private static let calendarWords: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february",
        "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
    ]

    static func apply(_ text: String) -> String {
        var out = text
        // A cue followed by "." ends a sentence ("…last forever I mean. Oh, yeah…"), and "I mean,"
        // is a discourse marker before a new clause ("…nice I mean, honestly…"): neither is a
        // repair, and both dropped the word before the cue.
        let apology = "(?:(?:sorry|oops),?|i mean|i meant)"
        let wait = "(?:no wait|wait no),?"
        // A cue can follow another cue ("arjun no sorry miyeon", "ravi actually no wait sunil"): the
        // abandoned word is the one before the whole cue run, never the "no" or "actually" itself.
        // No comma inside the run: "went well, sorry Dana" is a new clause, not a repair.
        // "oh", "well" and "actually" directly before an apology ("shipped oh sorry dana needs it") are an
        // aside, not a retraction, so they may lead only "no wait" / "wait no" or a "no" / "nope" that
        // itself leads the apology; otherwise they are the abandoned word, as before.
        let lead = "(?:no|nope|actually|oh|well)"
        // "oh sorry" and "actually sorry" are one aside-led cue: the word before them is what the
        // speaker abandoned, never the aside itself ("ping dana oh sorry dina" -> "ping dina").
        let cue = "(?:(?:\(lead)\\s+){0,2}\(wait)|(?:\(lead)\\s+)?(?:no|nope)\\s+\(apology)|(?:oh|actually)\\s+\(apology)|\(apology))"
        // Up to two words before the abandoned word are captured (and written back) to tell a
        // sentence from a bare phrase; the word after the replacement is read in a lookahead.
        let word = "(?:[A-Za-z][A-Za-z'\u{2019}]*|[0-9]+)"
        let pattern = "\\b((?:\(word)\\s+){0,2}?)(\(word)-?)\\s+(\(cue))\\s+(\(word))\\b(?=(?:\\s+(\(word)))?)"
        out = Regex.replace(out, pattern) { whole, groups in
            guard groups.count > 5 else { return whole }
            let found = Found(before: groups[1], abandoned: groups[2], cue: groups[3].lowercased(),
                              replacement: groups[4], next: groups.count > 5 ? groups[5] : "")
            return found.before + resolve(whole.dropFirst(found.before.count).description, found)
        }
        // "Tues- no Wednesday": a bare "no" only after a visibly cut-off word.
        out = Regex.replace(out, "\\b([A-Za-z]+-)\\s+no[,.]?\\s+(\(word))\\b") { whole, groups in
            guard groups.count > 2 else { return whole }
            return resolve(whole, Found(before: "", abandoned: groups[1], cue: "no", replacement: groups[2], next: ""))
        }
        return out
    }

    private struct Found {
        let before: String
        let abandoned: String
        let cue: String
        let replacement: String
        let next: String
    }

    /// The text for one match, without the words captured before it.
    private static func resolve(_ whole: String, _ found: Found) -> String {
        let abandoned = found.abandoned.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let replacementKey = found.replacement.lowercased()
        guard !notRepairable.contains(abandoned), !functionWords.contains(replacementKey) else { return whole }
        guard abandoned != replacementKey else { return whole }
        // A number is several words, so one word cannot be swapped for another (see `FragmentRepairNumbers`).
        guard !FragmentRepairNumbers.cutsANumber(abandoned: found.abandoned, replacement: found.replacement,
                                                 before: found.before, next: found.next) else { return whole }
        let nextKey = found.next.lowercased()
        let isAside = found.cue.hasPrefix("oh ") || found.cue.hasPrefix("actually ")
        // "oh sorry priya for the delay" apologizes to priya: no repair at all.
        if isAside, nextKey == "for" { return whole }
        let isSentence = found.before.split(whereSeparator: \.isWhitespace).count >= 2
        if isSentence, !found.abandoned.hasSuffix("-"), startsClause(replacementKey, next: nextKey) {
            // "the update shipped oh sorry dana needs the link": the word after the cue starts a new
            // clause, so nothing is being replaced. "no wait", "sorry" and "oops" end the sentence
            // there and only the cue goes; "i mean" is a discourse marker and stays, with every
            // content word, for the model and its guards.
            if found.cue.contains("mean") { return whole }
            return found.abandoned + ". " + found.replacement
        }
        // A hyphenated cut-off ("Tues-") always swaps; an unhyphenated prefix or another
        // like-for-like replacement is checked by FragmentRepairKinds.
        guard found.abandoned.hasSuffix("-")
                || FragmentRepairKinds.areAlike(abandoned: found.abandoned, replacement: found.replacement,
                                                before: found.before, cue: found.cue)
        else { return whole }
        return found.replacement
    }

    /// The replacement is a subject: a word that is no date or number, followed by a verb.
    private static func startsClause(_ replacement: String, next: String) -> Bool {
        guard !next.isEmpty, !calendarWords.contains(replacement), !calendarWords.contains(next),
              !NumberPhrase.isNumberWord(replacement) else { return false }
        if clauseVerbs.contains(next) || next.hasSuffix("n't") { return true }
        guard next.count > 3, !functionWords.contains(next), !notVerbLike.contains(next) else { return false }
        if next.hasSuffix("ed") { return true }
        return next.hasSuffix("s") && !["ss", "us", "is"].contains(where: next.hasSuffix)
    }
}

/// "…, sorry, not X, I mean Y …": the speaker retracts X and names Y in one breath. The whole
/// "sorry, not X, I mean" is correction scaffolding — Y replaces X, and the "not" goes with the
/// retracted X, not with Y. Before this, `SelfCorrection` swapped only the item and kept the
/// "not" ("Sorry, not Tuesday, I mean Wednesday works for me" -> "Sorry, not Wednesday works for
/// me"), inverting the meaning.
///
/// - X also said earlier in the sentence ("send the file to Maria, sorry, not Maria, I mean
///   Mark"): that earlier X becomes Y -> "send the file to Mark".
/// - Nothing but a cue before it ("Sorry, not Tuesday, I mean Wednesday works"): the text after
///   the cue stands -> "Wednesday works".
/// - Otherwise the shape is ambiguous and is left alone (the model, and its guards, decide).
enum NotXIMeanY {
    static func apply(_ text: String) -> String {
        let pattern = "^(.*?)[,;]?\\s*(?:\\b(?:sorry|no|oops|wait)[,.]?\\s+)?\\bnot\\s+((?:[A-Za-z0-9'\u{2019}]+\\s+){0,2}[A-Za-z0-9'\u{2019}]+)[,.]?\\s+i\\s+mean[t]?[,.]?\\s+(.+)$"
        guard let match = Regex.firstMatch(text, pattern),
              let before = match.string(at: 1, in: text),
              let retracted = match.string(at: 2, in: text),
              let after = match.string(at: 3, in: text)
        else { return text }
        let head = before.trimmingCharacters(in: CharacterSet(charactersIn: " ,;"))
        let onlyCue = head.isEmpty || head.range(of: "^(?:sorry|no|oops|wait|okay|so)$", options: [.regularExpression, .caseInsensitive]) != nil
        if onlyCue { return after }
        guard let range = head.range(of: "\\b\(NSRegularExpression.escapedPattern(for: retracted))\\b",
                                     options: [.regularExpression, .caseInsensitive, .backwards])
        else { return text }
        let retractedCount = retracted.split(separator: " ").count
        let afterWords = after.split(separator: " ").map(String.init)
        let replacement = afterWords.prefix(retractedCount).joined(separator: " ")
        let rest = afterWords.dropFirst(retractedCount).joined(separator: " ")
        let tail = String(head[range.upperBound...])
        var result = String(head[..<range.lowerBound]) + replacement + tail
        if !rest.isEmpty { result += " " + rest }
        return result
    }
}
