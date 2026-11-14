import Foundation

/// One file the index returned. The path is the citation: it is what the card shows and what
/// Reveal and Open act on. File contents are never part of it.
public struct FileCandidate: Sendable, Equatable, Hashable {
    public let path: String
    public let displayName: String
    public let modified: Date?
    public let lastUsed: Date?
    public let kinds: Set<FileKind>
    public let isFolder: Bool

    public init(
        path: String, displayName: String? = nil, modified: Date? = nil, lastUsed: Date? = nil,
        kinds: Set<FileKind> = [], isFolder: Bool = false
    ) {
        self.path = path
        self.displayName = displayName ?? (path as NSString).lastPathComponent
        self.modified = modified
        self.lastUsed = lastUsed
        self.kinds = kinds
        self.isFolder = isFolder
    }

    /// The later of modified and last-used.
    public var recency: Date? {
        switch (modified, lastUsed) {
        case (let a?, let b?): max(a, b)
        case (let a?, nil): a
        case (nil, let b?): b
        case (nil, nil): nil
        }
    }

    public var folderPath: String { (path as NSString).deletingLastPathComponent }
}

/// One pass of the search: which words, matched where, within which folders. The finder turns it
/// into a Spotlight query; a fake answers from a list.
public struct FileSearchSpec: Sendable, Equatable {
    public enum Pass: String, Sendable {
        /// Every name term in the file name.
        case nameAll
        /// At least one name term in the file name (only when `nameAll` found nothing).
        case nameAny
        /// Every term in the file's text (only when no name matched at all).
        case content
    }

    public let pass: Pass
    /// One group per term; any spelling in a group counts (`FileVocabulary.variants`).
    public let termGroups: [[String]]
    public let kind: FileKind
    public let roots: [URL]
    /// The most files a finder returns, counted after `FileScope.isExcluded` has cut what is out
    /// of scope: excluded hits never use up the limit.
    public let limit: Int
    public let timeBox: Duration
    /// The home folder the scope is judged against; empty means no scope filtering (predicate tests).
    public let homePath: String

    public init(
        pass: Pass, termGroups: [[String]], kind: FileKind, roots: [URL], limit: Int, timeBox: Duration,
        homePath: String = ""
    ) {
        self.homePath = homePath
        self.pass = pass
        self.termGroups = termGroups
        self.kind = kind
        self.roots = roots
        self.limit = limit
        self.timeBox = timeBox
    }
}

/// Why a search could not run, in code the card turns into words. Carries no text.
public enum FileSearchUnavailable: String, Sendable, Equatable, CaseIterable {
    /// Spotlight is not indexing this Mac (or the index is off for it).
    case indexOff
    /// The named folder can't be read.
    case folderNotReadable
    /// The query did not answer within the time box.
    case slow
    /// The search failed for another reason.
    case failed
}

public enum FileSearchResponse: Sendable, Equatable {
    /// In-scope matches in the index's own order (newest first), possibly cut off at the limit or the time box.
    case results([FileCandidate])
    case unavailable(FileSearchUnavailable)
}

/// The Mac's file index behind a small protocol: `SpotlightFileFinder` (NSMetadataQuery) in the
/// app, a list in tests and in `murmur-eval files`.
public protocol FileFinding: Sendable {
    func search(_ spec: FileSearchSpec) async -> FileSearchResponse
    /// Whether the index answers at all; asked only after every pass came back empty.
    func isIndexAvailable() async -> Bool
}

public extension FileFinding {
    func isIndexAvailable() async -> Bool { true }
}
