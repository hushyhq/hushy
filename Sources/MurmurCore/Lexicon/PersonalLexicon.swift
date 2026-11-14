import Foundation

/// The personal lexicon: one view over every place Hushy already learns names from, built in memory, ranked, and
/// handed to the recogniser boost and the cleanup's protected terms. No new table: the sources are History (kept
/// dictations), learned items (edits), kept-as-heard reverts, meeting attendees (calendar, already permitted), the
/// pack state file (screen sightings of pack names), and the bundled domain packs. See
/// `docs/engineering/personal-lexicon.md`.
///
/// `build` is pure and runs off the hot path (when History or learning changes); a dictation only reads the
/// finished `LexiconSnapshot`.
public enum PersonalLexicon {
    /// A use counts half after 30 days.
    public static let halfLife: TimeInterval = 30 * 24 * 3600
    public static let confirmationWeight = 3.0
    /// A name only Hushy's own output has shown (no typing, no list) needs this many recent uses: 1.5 means two
    /// dictations within about a month. A misheard spelling seen once is never boosted.
    public static let historyOnlyMinUses = 1.5
    /// Personal terms in the boost list. With the screen's 40 and a typical Dictionary this keeps the recogniser's
    /// vocabulary near FluidAudio's 100-term size step (`ContextBiasingConstants.rescorerConfig(forVocabSize:)`).
    public static let maxPersonalBoostTerms = 40
    /// Pack terms in the boost list, across every active pack: the person's own sightings first, then the pack's
    /// most written-about names. Each boost term costs about 0.7 ms of recogniser time (`murmur-eval lexicon-pack
    /// --latency-only`, 2026-11-07: 42 terms +7 ms, 82 +37 ms, 152 +97 ms, 302 +220 ms p50 over 2 terms), so 80.
    public static let maxPackBoostTerms = 80
    /// Kept dictations read for the lexicon, newest first.
    public static let maxHistoryRows = 2_000

    public struct HistoryText: Sendable, Equatable {
        public let text: String
        public let date: Date
        public init(text: String, date: Date) { self.text = text; self.date = date }
    }

    public struct DatedName: Sendable, Equatable {
        public let name: String
        public let date: Date
        public init(name: String, date: Date) { self.name = name; self.date = date }
    }

    public struct Inputs: Sendable {
        public var learned: [LearnedItem] = []
        public var keepHeard: [KeepHeardEntry] = []
        public var history: [HistoryText] = []
        public var attendees: [DatedName] = []
        public var packState = PackState()
        public var packs: [DomainPack] = DomainPackCatalog.usable
        public init() {}
    }

    public static func build(_ inputs: Inputs, now: Date = Date(), calendar: Calendar = .current) -> LexiconSnapshot {
        var terms: [String: PersonalTerm] = [:]
        var blocked = Set<String>()
        func add(_ term: PersonalTerm) {
            if term.isBlocked { blocked.insert(term.key) }
            if var existing = terms[term.key] {
                existing.merge(term)
                terms[term.key] = existing
            } else {
                terms[term.key] = term
            }
        }
        for term in learnedTerms(inputs.learned) { add(term) }
        for entry in inputs.keepHeard where entry.status == .active {
            add(PersonalTerm(surface: entry.written, kind: .term, sources: [.edit], rejections: 1,
                             firstSeen: entry.createdAt, lastSeen: entry.lastSeenAt))
        }
        for name in inputs.attendees where LexiconTermShape.isBoostable(name.name) {
            add(PersonalTerm(surface: name.name, kind: .person, sources: [.calendar], uses: 1,
                             firstSeen: name.date, lastSeen: name.date))
        }
        for row in inputs.history {
            for surface in historyCandidates(row.text) {
                add(PersonalTerm(surface: surface, kind: LexiconTermShape.kind(of: surface), sources: [.history], uses: 1,
                                 firstSeen: row.date, lastSeen: row.date))
            }
        }
        let activations = inputs.packs.map { pack in
            activation(for: pack, inputs: inputs, now: now, calendar: calendar)
        }
        let ranked = terms.values.filter { !$0.isBlocked }.sorted { rank($0, $1, now: now) }
        return LexiconSnapshot(terms: ranked, blocked: blocked, activations: activations, packs: inputs.packs, now: now)
    }

    /// Screen evidence from the state file plus History evidence read again now.
    static func activation(for pack: DomainPack, inputs: Inputs, now: Date, calendar: Calendar) -> PackActivation {
        let choice = inputs.packState.choice(for: pack.id)
        var evidence = inputs.packState.screenEvidence(for: pack)
        if choice != .off {
            let matcher = PackMatcher(pack: pack)
            for row in inputs.history {
                evidence.record(matcher.hits(in: row.text), on: PackEvidence.dayKey(row.date, calendar: calendar))
            }
        }
        return PackActivation.evaluate(packID: pack.id, evidence: evidence, choice: choice, now: now, calendar: calendar)
    }

    /// Global learned terms: in use = confirmed, still being judged = used, forgotten = blocked.
    static func learnedTerms(_ items: [LearnedItem]) -> [PersonalTerm] {
        items.filter { $0.kind == .term && $0.appBundleID == nil }.map { item in
            let heard = LearnedPersonalization.heardAliases(item.heardAs, term: item.value)
            switch item.status {
            case .active:
                return PersonalTerm(surface: item.value, spokenForms: heard, kind: LexiconTermShape.kind(of: item.value),
                                    sources: [.edit], confirmations: 1, firstSeen: item.createdAt, lastSeen: item.lastSeenAt)
            case .candidate:
                return PersonalTerm(surface: item.value, spokenForms: heard, kind: LexiconTermShape.kind(of: item.value),
                                    sources: [.edit], uses: Double(max(1, item.observations)),
                                    firstSeen: item.createdAt, lastSeen: item.lastSeenAt)
            case .forgotten:
                return PersonalTerm(surface: item.value, kind: .term, sources: [.edit], rejections: 1,
                                    firstSeen: item.createdAt, lastSeen: item.lastSeenAt)
            }
        }
    }

    /// Names and identifiers in one kept dictation, each once, through the lexicon's shape filter: runs of capitalized
    /// words ("Anouk Vermeulen"; a common word that only starts the sentence is dropped, so "Ping Anouk" gives
    /// "Anouk"), and single code-like or unknown tokens ("rl-v9", "kubectl").
    static func historyCandidates(_ text: String) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        func offer(_ term: String) {
            if LexiconTermShape.isBoostable(term), seen.insert(PersonalTerm.key(term)).inserted { found.append(term) }
        }
        var run: [String] = []
        var runStartsSentence = false
        func flush() {
            var words = run
            if runStartsSentence, let first = words.first, LearningLexicon.isCommonWord(first.lowercased()) { words.removeFirst() }
            if !words.isEmpty, words.count <= maxNameWords { offer(words.joined(separator: " ")) }
            run = []
        }
        var sentenceStart = true
        for raw in text.split(whereSeparator: \.isWhitespace) {
            let word = String(raw).trimmingCharacters(in: leadingPunctuation).trimmingCharacters(in: trailingPunctuation)
            let endsClause = word.count < raw.count && raw.last.map { ",;:.!?)\"”".contains($0) } == true
            if let first = word.first, first.isUppercase, word.allSatisfy({ $0.isLetter || "'’-".contains($0) }) {
                if run.isEmpty { runStartsSentence = sentenceStart }
                run.append(word)
                if endsClause { flush() }
            } else {
                flush()
                if !word.isEmpty, LexiconTermShape.isCodeLike(word) || LexiconTermShape.isUnknownWord(word) { offer(word) }
            }
            sentenceStart = raw.last.map { ".!?".contains($0) } ?? false
        }
        flush()
        return found
    }

    static let maxNameWords = 4
    private static let leadingPunctuation = CharacterSet(charactersIn: "(\"'“‘[")
    private static let trailingPunctuation = CharacterSet(charactersIn: ",;:.!?)\"'”’]")

    /// Highest score first; then the newest; then the spelling, so the order never depends on dictionary order.
    static func rank(_ a: PersonalTerm, _ b: PersonalTerm, now: Date) -> Bool {
        let scoreA = a.score(at: now), scoreB = b.score(at: now)
        if scoreA != scoreB { return scoreA > scoreB }
        if a.lastSeen != b.lastSeen { return a.lastSeen > b.lastSeen }
        return a.surface < b.surface
    }

    /// A pack name boosts only when its last word is not ordinary English. "Kevin Love" turned "I love the heat" into
    /// "Kevin Love the heat", and "Miami Heat", "Jalen Green" or "Stephen Curry" are names the recogniser already writes
    /// from ordinary words; the names worth boosting are the ones it cannot spell ("Wembanyama", "Gilgeous-Alexander").
    public static func isBoostablePackName(_ surface: String) -> Bool {
        guard LexiconTermShape.isBoostable(surface) else { return false }
        let words = surface.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
            .filter { !LexiconTermShape.nameSuffixes.contains($0) }
        guard let last = words.last else { return false }
        let parts = last.split(whereSeparator: { "-'’".contains($0) }).map(String.init)
        return parts.contains { !WordFrequency.shared.isOrdinary($0) && !LearningLexicon.isCommonWord($0) }
    }

    /// Whether a term has earned a place in the boost list.
    static func qualifies(_ term: PersonalTerm, now: Date) -> Bool {
        guard !term.isBlocked, LexiconTermShape.isBoostable(term.surface) else { return false }
        if term.confirmations > 0 { return true }
        if !term.hasAuthoritativeSpelling { return term.decayedUses(at: now) >= historyOnlyMinUses }
        return term.decayedUses(at: now) > 0.05
    }
}

/// What one dictation reads: the ranked personal terms and the pack activations, frozen when they were built.
public struct LexiconSnapshot: Sendable, Equatable {
    public let terms: [PersonalTerm]
    public let blocked: Set<String>
    public let activations: [PackActivation]
    let packs: [DomainPack]
    public let builtAt: Date

    init(terms: [PersonalTerm], blocked: Set<String>, activations: [PackActivation], packs: [DomainPack], now: Date) {
        self.terms = terms
        self.blocked = blocked
        self.activations = activations
        self.packs = packs
        builtAt = now
    }

    /// No evidence of anything: the boost list is empty and every dictation runs exactly as before.
    public static let empty = LexiconSnapshot(terms: [], blocked: [], activations: [], packs: [], now: .distantPast)

    public var activePacks: [DomainPack] {
        let on = Set(activations.filter(\.active).map(\.packID))
        return packs.filter { on.contains($0.id) }
    }

    /// The recogniser vocabulary this lexicon adds, best first: personal terms, then active pack terms. Terms whose
    /// lowercased spelling is in `excluding` (the Dictionary, screen terms, built-ins) are left to their own path.
    public func boostTerms(excluding: Set<String> = [], now: Date? = nil) -> [VocabularyTerm] {
        let now = now ?? builtAt
        var taken = Set(excluding.map(PersonalTerm.key))
        var result: [VocabularyTerm] = []
        for term in terms where result.count < PersonalLexicon.maxPersonalBoostTerms {
            guard PersonalLexicon.qualifies(term, now: now), taken.insert(term.key).inserted else { continue }
            result.append(VocabularyTerm(
                text: term.surface, aliases: term.spokenForms.filter { PersonalTerm.key($0) != term.key }, source: .personal))
        }
        var packCount = 0
        for pack in activePacks {
            let hits = activations.first { $0.packID == pack.id }?.hitTerms ?? []
            let order = pack.terms.indices.filter { hits.contains($0) } + pack.terms.indices.filter { !hits.contains($0) }
            for index in order where packCount < PersonalLexicon.maxPackBoostTerms {
                let term = pack.terms[index]
                let key = PersonalTerm.key(term.surface)
                guard !blocked.contains(key), PersonalLexicon.isBoostablePackName(term.surface), taken.insert(key).inserted else { continue }
                result.append(VocabularyTerm(text: term.surface, aliases: term.aliases, source: .pack))
                packCount += 1
                // No separate surname term: measured on `murmur-eval lexicon-pack` (2026-11-07) it fixed the surname and
                // left the first name misheard ("Lowry Markkanen"), fan condition 84% -> 73%, and did not fix
                // surname-only sentences either.
            }
        }
        return result
    }
}
