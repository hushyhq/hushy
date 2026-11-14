import Foundation

/// One name or term in the person's vocabulary, with where Hushy met it and how much it has been used.
/// Built in memory from what Hushy already stores (`PersonalLexicon.build`); nothing here is a new table.
///
/// `uses` is a decayed count: it halves every `PersonalLexicon.halfLife` (30 days) after `lastSeen`, so a name
/// the person stopped using slides down the ranking and out of the capped boost list. It is never deleted for
/// that: the term stays visible and comes back as soon as it is used again. Confirmations (the person taught
/// the spelling) do not fade; a rejection (they undid it, forgot it, kept what was heard) blocks the term.
public struct PersonalTerm: Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case person, org, product, identifier, term
    }

    public enum Source: Hashable, Sendable {
        case screen, history, edit, contact, calendar
        case pack(String)

        /// The spelling came from text a person typed or a curated list, not from Hushy's own recogniser.
        var isSpellingAuthority: Bool {
            if case .history = self { return false }
            return true
        }

        var isPack: Bool {
            if case .pack = self { return true }
            return false
        }
    }

    public var surface: String
    public var spokenForms: [String]
    public var kind: Kind
    public var sources: Set<Source>
    /// Decayed count as of `lastSeen`.
    public var uses: Double
    public var confirmations: Int
    public var rejections: Int
    public var firstSeen: Date
    public var lastSeen: Date
    /// Position in its pack's ranking (0 = most written about); nil for a term no pack holds.
    public var packRank: Int?

    public init(
        surface: String, spokenForms: [String] = [], kind: Kind, sources: Set<Source>, uses: Double = 0,
        confirmations: Int = 0, rejections: Int = 0, firstSeen: Date, lastSeen: Date, packRank: Int? = nil
    ) {
        self.surface = surface
        self.spokenForms = spokenForms
        self.kind = kind
        self.sources = sources
        self.uses = uses
        self.confirmations = confirmations
        self.rejections = rejections
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.packRank = packRank
    }

    public var key: String { Self.key(surface) }

    /// The person undid, forgot or kept-as-heard this term: it is never boosted, from any source.
    public var isBlocked: Bool { rejections > 0 }

    /// Uses as they stand at `now`.
    public func decayedUses(at now: Date) -> Double {
        uses * EvidenceMath.weight(afterSeconds: now.timeIntervalSince(lastSeen), halfLife: PersonalLexicon.halfLife)
    }

    /// decayed(uses) + w·confirmations − w·rejections. Blocked terms score −∞.
    public func score(at now: Date) -> Double {
        guard !isBlocked else { return -.infinity }
        return decayedUses(at: now) + PersonalLexicon.confirmationWeight * Double(confirmations)
    }

    /// Folds one more sighting into the decayed count.
    mutating func use(at date: Date, weight: Double = 1) {
        if date >= lastSeen {
            uses = decayedUses(at: date) + weight
            lastSeen = date
        } else {
            uses += weight * EvidenceMath.weight(afterSeconds: lastSeen.timeIntervalSince(date), halfLife: PersonalLexicon.halfLife)
        }
        firstSeen = min(firstSeen, date)
    }

    mutating func merge(_ other: PersonalTerm) {
        // A spelling a person typed or a list gives wins over one Hushy's recogniser wrote.
        if !hasAuthoritativeSpelling, other.hasAuthoritativeSpelling { surface = other.surface }
        if other.lastSeen > lastSeen {
            uses = decayedUses(at: other.lastSeen) + other.uses
            lastSeen = other.lastSeen
        } else {
            uses += other.decayedUses(at: lastSeen)
        }
        firstSeen = min(firstSeen, other.firstSeen)
        sources.formUnion(other.sources)
        confirmations += other.confirmations
        rejections += other.rejections
        packRank = [packRank, other.packRank].compactMap { $0 }.min()
        for form in other.spokenForms where !spokenForms.contains(form) { spokenForms.append(form) }
        if kind == .term { kind = other.kind }
    }

    /// The surface came from a person's typing or a curated list, not only from Hushy's own output.
    public var hasAuthoritativeSpelling: Bool { sources.contains(where: \.isSpellingAuthority) }

    public static func key(_ surface: String) -> String {
        surface.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
