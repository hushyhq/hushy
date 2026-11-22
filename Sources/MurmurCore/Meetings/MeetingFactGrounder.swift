import Foundation

/// Ties each extracted record to the words it came from, the app side of `eval_ami_extract.grounded()`
/// (meetings schema freeze section 5, rule 4). Pure: no model, no store.
///
/// - **Quote.** Must be copied from one line of the chunk (exactly, else ignoring case and spacing). That sets the
///   evidence turn, the UTF-16 span inside it, and the playback span from the turn's word times. No quote found:
///   the fact is stored `unsupported` and never shown.
/// - **Owner** (actions only). A speaker label of the meeting ("You", "Speaker 2", a name the person gave a speaker)
///   is kept with that speaker's id. A person named in the evidence turn or the two turns before it (someone given
///   the task in the turns) is kept by name. Anything else is the extractor's claim only (`ownerClaim`); the shown
///   owner stays empty: blank beats wrong.
/// - **Statement.** A decision or action must share words with what was said around its quote: at least
///   `minimumStatementSupport` of its content words occur in the quote's line or the `statementRadius` lines either
///   side. A record whose quote is about something else ("I give it a four now." for a price) keeps its quote but is
///   stored `unsupported` and never shown.
/// - **Repeats.** A shown fact whose kind and words repeat an earlier one (chunk overlap, a model that loops) is
///   dropped.
/// - **Due.** The due words must occur in the chunk, or the due is dropped.
public enum MeetingFactGrounder {
    /// A speaker as the prompt names them, with the stored speaker when there is one.
    public struct Speaker: Sendable, Equatable {
        public var label: String
        public var speakerId: Int64?
        public init(label: String, speakerId: Int64?) {
            self.label = label
            self.speakerId = speakerId
        }
    }

    public static let maxQuoteScalars = 2_000

    /// Facts for one chunk's records, in the chunk's order. `extractor` is stored on each.
    public static func facts(
        _ records: [MeetingExtractAnswer.Record], chunk: [MeetingExtractPrompt.Line], speakers: [Speaker],
        noteId: Int64, extractor: String
    ) -> [MeetingFact] {
        let chunkText = chunk.map(\.text).joined(separator: "\n").lowercased()
        return records.compactMap { record in
            guard let kind = kind(record.kind) else { return nil }
            let text = clipped(record.text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !text.isEmpty else { return nil }
            let quote = record.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            var fact = MeetingFact(
                noteId: noteId, kind: kind, ordinal: 0, text: text, grounding: .unsupported, origin: .model, extractor: extractor)
            fact.quote = quote.isEmpty ? nil : clipped(quote)
            let evidence = quote.isEmpty ? nil : locate(quote, in: chunk)
            if let evidence, kind == .openQuestion || kind == .change
                || statementSupport(text, line: evidence.line, in: chunk) >= minimumStatementSupport {
                fact.grounding = .verified
                fact.evidenceTurnId = evidence.turn.id
                fact.evidenceStart = evidence.start
                fact.evidenceEnd = evidence.end
                (fact.t0, fact.t1) = span(evidence)
                fact.quote = evidence.quote
            }
            if kind == .action, let owner = present(record.owner) {
                fact.ownerClaim = owner
                if let grounded = groundedOwner(owner, speakers: speakers, evidence: evidence, chunk: chunk) {
                    fact.ownerText = grounded.text
                    fact.ownerSpeakerId = grounded.speakerId
                }
            }
            if let due = present(record.due), chunkText.contains(due.lowercased()) { fact.due = due }
            return fact
        }
    }

    /// Orders facts from several chunks in transcript order (by playback start, unsupported ones after their chunk's
    /// neighbours), drops a repeat of a quote already kept (chunk overlap, a record said twice), and numbers them.
    public static func ordered(_ facts: [MeetingFact]) -> [MeetingFact] {
        var seen = Set<String>()
        var kept: [MeetingFact] = []
        for fact in facts {
            if let quote = fact.quote, fact.grounding == .verified {
                let quoted = seen.insert("\(fact.kind.rawValue)|quote|\(normalized(quote))").inserted
                let worded = seen.insert("\(fact.kind.rawValue)|text|\(normalized(fact.text))").inserted
                guard quoted, worded else { continue }
            }
            kept.append(fact)
        }
        let indexed = kept.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { a, b in
            switch (a.1.t0, b.1.t0) {
            case let (x?, y?) where x != y: return x < y
            default: return a.0 < b.0
            }
        }
        return sorted.enumerated().map { ordinal, pair in
            var fact = pair.1
            fact.ordinal = ordinal
            return fact
        }
    }

    // MARK: - Quote

    struct Evidence {
        let line: Int
        let turn: NoteTurn
        let start: Int
        let end: Int
        let quote: String
    }

    /// The quote's place in the chunk: the line holding it, then the turn of that line where it starts.
    static func locate(_ quote: String, in chunk: [MeetingExtractPrompt.Line]) -> Evidence? {
        for (index, line) in chunk.enumerated() {
            guard let range = find(quote, in: line.text) else { continue }
            let start = line.text.utf16.distance(from: line.text.utf16.startIndex, to: range.lowerBound)
            let length = line.text[range].utf16.count
            guard let part = line.parts.last(where: { $0.offset <= start }) else { continue }
            let turnLength = (part.turn.text.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).length
            let local = start - part.offset
            let end = min(turnLength, local + length)
            guard local >= 0, end > local else { continue }
            return Evidence(line: index, turn: part.turn, start: local, end: end, quote: String(line.text[range]))
        }
        return nil
    }

    /// Exact first; then ignoring case and runs of spaces, as a model copying a quote can change only those.
    static func find(_ quote: String, in text: String) -> Range<String.Index>? {
        if let exact = text.range(of: quote) { return exact }
        let pattern = quote.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "\\s+")
        guard !pattern.isEmpty else { return nil }
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive])
    }

    /// Playback span of the quote: the turn's recognised words under it, by word position (the shown text is the
    /// cleaned words, so the n-th shown word is about the n-th recognised one); the whole turn without word times.
    static func span(_ evidence: Evidence) -> (Double?, Double?) {
        let words = (evidence.turn.words ?? []).filter { $0.flags & NoteTurn.Word.echo == 0 }
        let text = evidence.turn.text.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        guard !words.isEmpty, text.length > 0 else { return (evidence.turn.t0, evidence.turn.t1) }
        func count(_ part: String) -> Int { part.split(whereSeparator: \.isWhitespace).count }
        let before = count(text.substring(to: min(evidence.start, text.length)))
        let inside = count(text.substring(with: NSRange(location: evidence.start, length: max(0, min(evidence.end, text.length) - evidence.start))))
        let shown = count(text as String)
        let scale = Double(words.count) / Double(max(shown, 1))
        let first = min(words.count - 1, Int((Double(before) * scale).rounded(.down)))
        let last = min(words.count - 1, max(first, Int((Double(before + max(inside, 1)) * scale).rounded(.up)) - 1))
        return (words[first].start, words[last].end)
    }

    // MARK: - Statement

    static let minimumStatementSupport = 0.15
    static let statementRadius = 2

    /// The share of `text`'s content words (stemmed, filler left out) found in chunk line `line` and its
    /// `statementRadius` neighbours; 1 when `text` has none.
    static func statementSupport(_ text: String, line: Int, in chunk: [MeetingExtractPrompt.Line]) -> Double {
        let claimed = Set(statementWords(text).filter(isContent).map(stem))
        guard !claimed.isEmpty else { return 1 }
        let window = chunk[max(0, line - statementRadius)...min(chunk.count - 1, line + statementRadius)]
        let said = Set(window.flatMap { statementWords($0.text) }.map(stem))
        return Double(claimed.intersection(said).count) / Double(claimed.count)
    }

    /// `words` as said: an acronym spelled letter by letter ("L_C_D_", "T_V_s", as a transcript can write it) is one
    /// word ("lcd", "tvs"), and a number in digits is its words ("12.50" is "twelve fifty"), the public scorer's
    /// reading (`score_public.tokens`).
    static func statementWords(_ text: String) -> [String] {
        let joined = text.replacing(/\b(?:[A-Za-z]_){2,}/) { $0.output.filter(\.isLetter) }
        let spoken = joined.replacing(/\d+(?:,\d{3})*/) { match in
            Int(match.output.filter { $0 != "," }).map { " \(said($0)) " } ?? String(match.output)
        }
        return words(spoken)
    }

    /// 0 to 999 in words ("one hundred twenty five"); a larger number stays in digits.
    static func said(_ number: Int) -> String {
        guard number < 1000 else { return String(number) }
        let (hundreds, rest) = number.quotientAndRemainder(dividingBy: 100)
        var spoken = hundreds > 0 ? [units[hundreds], "hundred"] : []
        if rest > 0 || spoken.isEmpty {
            spoken += rest < 20 ? [units[rest]] : [tens[rest / 10]] + (rest % 10 > 0 ? [units[rest % 10]] : [])
        }
        return spoken.joined(separator: " ")
    }

    private static let units = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen",
        "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
    ]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    static func isContent(_ word: String) -> Bool {
        word.count > 1 && !word.allSatisfy(\.isNumber) && !statementStopWords.contains(word)
    }

    /// The public scorer's suffix stripping (`score_public.stem`), so "decided" and "decide" meet.
    static func stem(_ word: String) -> String {
        for suffix in ["ing", "ed", "es", "s", "ly"] where word.hasSuffix(suffix) && word.count - suffix.count >= 4 {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    private static let statementStopWords: Set<String> = Set("""
        a an the and or but of to in on at for with by from as is are was were be been being it its this that these those \
        there their they them we our us you your i me my he she his her him not no do does did done will would shall should \
        can could may might must have has had also so such than then very just about into over up out off more most some any \
        each all both other only own same too which who whom what when where why how decided decide decision agreed agree \
        going go get got make made use used need needs one
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    // MARK: - Owner

    struct GroundedOwner: Equatable {
        let text: String
        let speakerId: Int64?
    }

    static func groundedOwner(
        _ owner: String, speakers: [Speaker], evidence: Evidence?, chunk: [MeetingExtractPrompt.Line]
    ) -> GroundedOwner? {
        let key = owner.lowercased()
        if let speaker = speakers.first(where: { $0.label.lowercased() == key }) {
            return GroundedOwner(text: speaker.label, speakerId: speaker.speakerId)
        }
        // Named in the turns where the task was given: the evidence line and the two before it.
        guard let evidence, isPersonName(owner) else { return nil }
        guard let index = chunk.firstIndex(where: { $0.parts.contains { $0.turn.ordinal == evidence.turn.ordinal } })
        else { return nil }
        let nearby = chunk[max(0, index - 2)...index].map(\.text).joined(separator: " ")
        let nameWords = words(owner)
        let said = Set(words(nearby))
        guard !nameWords.isEmpty, nameWords.allSatisfy(said.contains) else { return nil }
        return GroundedOwner(text: owner, speakerId: nil)
    }

    /// One or two capitalised words ("Priya", "Ben Ortiz"), not a role or a group.
    static func isPersonName(_ text: String) -> Bool {
        let parts = text.split(separator: " ")
        guard (1...3).contains(parts.count) else { return false }
        guard parts.allSatisfy({ $0.first?.isUppercase == true && $0.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" } }) else { return false }
        return !groupWords.contains(text.lowercased())
    }

    private static let groupWords: Set<String> = [
        "team", "the team", "everyone", "all", "group", "we", "us", "they", "someone", "somebody", "nobody", "unassigned",
    ]

    // MARK: - Helpers

    static func kind(_ raw: String) -> MeetingFact.Kind? {
        switch raw {
        case "decision": .decision
        case "action": .action
        case "open_question", "openQuestion": .openQuestion
        case "change": .change
        default: nil
        }
    }

    static func present(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              !["null", "none", "n/a", "unassigned", "tbd"].contains(trimmed.lowercased()) else { return nil }
        return trimmed
    }

    static func clipped(_ text: String) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: text.unicodeScalars.prefix(maxQuoteScalars))
        return String(view)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    static func normalized(_ text: String) -> String { words(text).joined(separator: " ") }
}
