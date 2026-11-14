import Foundation

/// One paragraph dictated into both Hushy and a competitor (gate 12, `docs/product/DIRECTION.md`
/// §2). The competitor side is produced **manually by the founder** — there is no automation of
/// Wispr Flow or any other product, on purpose (privacy; see the product-lead decisions log).
///
/// `audioPath` is optional and only ever a path the founder passed in explicitly; the harness
/// never opens the app's database or `~/Library/Application Support/Hushy`.
struct HeadToHeadPair: Codable, Equatable, Sendable {
    let id: String
    let audioPath: String?
    let hushyOutput: String
    let otherOutput: String
    let otherName: String

    init(id: String, audioPath: String? = nil, hushyOutput: String, otherOutput: String, otherName: String) {
        self.id = id
        self.audioPath = audioPath
        self.hushyOutput = hushyOutput
        self.otherOutput = otherOutput
        self.otherName = otherName
    }
}

enum HeadToHeadPairs {
    enum LoadError: LocalizedError, Equatable {
        case empty
        case duplicateIDs([String])
        case blankOutput(String)

        var errorDescription: String? {
            switch self {
            case .empty: "Pairs file has no records"
            case .duplicateIDs(let ids): "Pairs file has duplicate ids: \(ids.joined(separator: ", "))"
            case .blankOutput(let id): "Pair \(id) has an empty Hushy or competitor output"
            }
        }
    }

    /// Decodes and validates a pairs file: nonempty, unique ids, no blank sides. Blank sides
    /// are rejected rather than scored as a total loss because the most likely cause is a slot
    /// the founder forgot to fill in the template, not a product failure.
    static func load(from url: URL) throws -> [HeadToHeadPair] {
        let data = try Data(contentsOf: url)
        return try validate(JSONDecoder().decode([HeadToHeadPair].self, from: data))
    }

    static func validate(_ pairs: [HeadToHeadPair]) throws -> [HeadToHeadPair] {
        guard !pairs.isEmpty else { throw LoadError.empty }
        var seen = Set<String>()
        var duplicates: [String] = []
        for pair in pairs where !seen.insert(pair.id).inserted {
            duplicates.append(pair.id)
        }
        guard duplicates.isEmpty else { throw LoadError.duplicateIDs(duplicates) }
        for pair in pairs {
            let blank = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if blank(pair.hushyOutput) || blank(pair.otherOutput) { throw LoadError.blankOutput(pair.id) }
        }
        return pairs
    }

    static func write(_ pairs: [HeadToHeadPair], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(pairs).write(to: url, options: .atomic)
    }
}
