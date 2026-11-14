import Foundation

/// A bundled list of names for one field (NBA players, drug names, developer tools), used as recogniser vocabulary
/// for the people whose screen and history show they talk about that field (`PackActivation`).
///
/// Packs come from public, licensed sources only, and each one says which (`licence`, `sourceURL`, `sourceNote`).
/// The JSON files in `Lexicon/Packs/` are the record; `DomainPackData.swift` embeds them in the binary
/// (`scripts/lexicon/embed_packs.py`), so nothing is read from disk or fetched at run time.
public struct DomainPack: Codable, Sendable, Equatable, Identifiable {
    public struct Term: Codable, Sendable, Equatable {
        public var surface: String
        /// Other spellings of the same name ("Luka Doncic"), never nicknames.
        public var aliases: [String]
        public var kind: PersonalTerm.Kind
    }

    public var id: String
    public var version: String
    public var title: String
    /// SPDX identifier ("CC0-1.0").
    public var licence: String
    public var sourceURL: String
    public var sourceNote: String
    /// Most written-about first: the order the boost list takes pack terms in when the person's own evidence ties.
    public var terms: [Term]

    /// A pack whose source and licence are chosen but whose terms are not built yet.
    public var isStub: Bool { terms.isEmpty }
}

public enum DomainPackCatalog {
    /// Every bundled pack, stubs included. Decoded once.
    public static let all: [DomainPack] = DomainPackData.sources.compactMap { source in
        try? JSONDecoder().decode(DomainPack.self, from: Data(source.utf8))
    }

    /// Packs with terms.
    public static var usable: [DomainPack] { all.filter { !$0.isStub } }

    public static func pack(id: String) -> DomainPack? { all.first { $0.id == id } }
}
