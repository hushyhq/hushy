import Foundation

/// What kind of file a request names. A hard filter on the Spotlight content-type tree.
public enum FileKind: String, Sendable, CaseIterable, Codable {
    case pdf, document, presentation, spreadsheet, image, folder, any

    /// Spotlight content types (`kMDItemContentTypeTree`) that count as this kind; empty for `any`.
    /// One list for the Spotlight predicate and for filtering a fake index in tests.
    public var contentTypes: [String] {
        switch self {
        case .pdf: ["com.adobe.pdf"]
        case .document:
            ["com.adobe.pdf", "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc",
             "com.apple.iwork.pages.sffpages", "com.apple.iwork.pages.pages", "public.rtf", "com.apple.rtfd", "public.plain-text",
             "org.oasis-open.opendocument.text"]
        case .presentation:
            ["org.openxmlformats.presentationml.presentation", "com.microsoft.powerpoint.ppt",
             "com.apple.iwork.keynote.sffkey", "com.apple.iwork.keynote.key", "org.oasis-open.opendocument.presentation"]
        case .spreadsheet:
            ["org.openxmlformats.spreadsheetml.sheet", "com.microsoft.excel.xls", "com.apple.iwork.numbers.sffnumbers", "com.apple.iwork.numbers.numbers",
             "public.comma-separated-values-text", "org.oasis-open.opendocument.spreadsheet"]
        case .image: ["public.image"]
        case .folder: ["public.folder"]
        case .any: []
        }
    }

    /// The kinds a Spotlight content-type tree belongs to (a candidate may be several: a PDF is
    /// both `pdf` and `document`).
    public static func kinds(forContentTypeTree tree: [String]) -> Set<FileKind> {
        let set = Set(tree)
        return Set(FileKind.allCases.filter { kind in kind != .any && kind.contentTypes.contains { set.contains($0) } })
    }
}

/// A time hint, resolved against "now" only when ranking. "Recent" is the one relative hint; a
/// month alone means the latest such month.
public enum FileTimeHint: Sendable, Equatable {
    case recent
    case month(Int)
    case year(Int)
    case monthOfYear(month: Int, year: Int)
}

/// A folder the request names. Never a path: the app maps each case to a known folder.
public enum FileLocation: String, Sendable, CaseIterable, Codable {
    case desktop, documents, downloads

    public var folderName: String { rawValue.capitalized }
}

/// What to do with the file once found. "Fetch" is reveal; only the word "open" opens.
public enum FileAction: String, Sendable, Codable {
    case reveal, open
}

/// The one typed query a file request becomes: name terms, a kind, a time hint, a location hint.
/// Nothing else, and never a path or a command: the model (or the rules) fill these fields and
/// code does the rest. Built only through `init?`, which refuses anything that isn't a plain word.
public struct FileQuery: Sendable, Equatable {
    public static let maxTerms = 6
    public static let maxTermLength = 32

    public let terms: [String]
    public let kind: FileKind
    public let time: FileTimeHint?
    public let location: FileLocation?

    /// nil when there is nothing to search for (no terms and no other hint), a term is not a
    /// plain word, or there are more than `maxTerms`. Terms are lowercased and de-duplicated.
    public init?(terms: [String], kind: FileKind = .any, time: FileTimeHint? = nil, location: FileLocation? = nil) {
        var clean: [String] = []
        for raw in terms {
            guard let word = Self.cleanTerm(raw) else { return nil }
            if !clean.contains(word) { clean.append(word) }
        }
        guard clean.count <= Self.maxTerms else { return nil }
        guard !clean.isEmpty || kind != .any || time != nil || location != nil else { return nil }
        if case .month(let month) = time, !(1...12).contains(month) { return nil }
        if case .monthOfYear(let month, _) = time, !(1...12).contains(month) { return nil }
        self.terms = clean
        self.kind = kind
        self.time = time
        self.location = location
    }

    /// A plain word: letters and digits (hyphen and apostrophe inside), 1 to `maxTermLength`
    /// characters. Anything with a slash, dot, tilde, space, quote or control character is not.
    static func cleanTerm(_ raw: String) -> String? {
        let word = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !word.isEmpty, word.count <= maxTermLength else { return nil }
        let allowed = word.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "'" }
        guard allowed, word.first?.isLetter == true || word.first?.isNumber == true else { return nil }
        return word
    }

    /// Strips a model's or a caller's free text down to plain words; for tolerant inputs only.
    public static func sanitizedTerms(_ raw: [String]) -> [String] {
        var out: [String] = []
        for item in raw {
            for piece in item.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-") }) {
                if let word = cleanTerm(String(piece)), !out.contains(word) { out.append(word) }
            }
        }
        return out
    }
}

/// A query and what to do with the winner.
public struct FileRequest: Sendable, Equatable {
    public let query: FileQuery
    public let action: FileAction

    public init(query: FileQuery, action: FileAction = .reveal) {
        self.query = query
        self.action = action
    }
}
