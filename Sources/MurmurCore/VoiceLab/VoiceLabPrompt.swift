import Foundation

/// One held-out Voice Lab prompt: what the user is asked to read aloud, and the expected
/// cleaned-up output for scoring. Reuses the golden-set scoring conventions (layout matches,
/// `alternatives`, `exactText`, `expectedPressEnter`) so the existing `EvalMetrics` scorer
/// applies without a second scoring implementation.
public struct VoiceLabPrompt: Codable, Sendable, Equatable {
    public enum Style: String, Codable, Sendable, CaseIterable {
        /// Spoken at a normal conversational volume.
        case normal
        /// Spoken in a whisper.
        case whisper
        /// Spoken with a video, TV show, or music playing in the background.
        case noisy
    }

    public let id: String
    /// Free-form grouping label (e.g. "plain", "numbers", "correction"), independent of
    /// `style`, for breaking down results by content type as well as recording condition.
    public let category: String
    public let style: Style
    /// Instructions plus the text the user reads aloud.
    public let prompt: String
    /// Expected cleaned-up text.
    public let expected: String
    /// Other outputs a reasonable person would also accept.
    public let alternatives: [String]?
    public let expectedPressEnter: Bool?
    public let exactText: Bool?

    public init(
        id: String, category: String, style: Style, prompt: String, expected: String,
        alternatives: [String]? = nil, expectedPressEnter: Bool? = nil, exactText: Bool? = nil
    ) {
        self.id = id
        self.category = category
        self.style = style
        self.prompt = prompt
        self.expected = expected
        self.alternatives = alternatives
        self.expectedPressEnter = expectedPressEnter
        self.exactText = exactText
    }

    public var accepted: [String] { [expected] + (alternatives ?? []) }

    /// Short instruction shown above the record button, distinct from the literal prompt text.
    public var instruction: String {
        switch style {
        case .normal: "Say it naturally:"
        case .whisper: "Whisper this:"
        case .noisy: "Turn on background noise (video, TV, or music), then say:"
        }
    }
}

/// Loads and validates the Voice Lab prompt set.
public enum VoiceLabPrompts {
    public enum LoadError: LocalizedError {
        case duplicateIDs([String])
        case unsafeIDs([String])
        case empty

        public var errorDescription: String? {
            switch self {
            case .duplicateIDs(let ids): "Duplicate prompt ids: \(ids.joined(separator: ", "))"
            case .unsafeIDs(let ids): "Prompt ids must be letters, digits, - or _: \(ids.joined(separator: ", "))"
            case .empty: "Prompt set is empty"
            }
        }
    }

    public static func load(from url: URL) throws -> [VoiceLabPrompt] {
        let prompts = try JSONDecoder().decode([VoiceLabPrompt].self, from: Data(contentsOf: url))
        try validate(prompts)
        return prompts
    }

    /// Validates uniqueness of ids and non-empty required fields. Used by both the loader and
    /// tests so prompt-file regressions are caught the same way in both places.
    public static func validate(_ prompts: [VoiceLabPrompt]) throws {
        guard !prompts.isEmpty else { throw LoadError.empty }
        var seen = Set<String>()
        var duplicates: [String] = []
        for prompt in prompts {
            if !seen.insert(prompt.id).inserted { duplicates.append(prompt.id) }
        }
        guard duplicates.isEmpty else { throw LoadError.duplicateIDs(duplicates) }
        // Ids become file names; anything else could write outside the session folder.
        let unsafe = prompts.map(\.id).filter { !isSafeID($0) }
        guard unsafe.isEmpty else { throw LoadError.unsafeIDs(unsafe) }
    }

    public static func isSafeID(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil
    }
}
