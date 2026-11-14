import Foundation
import MurmurCore

/// Where a boosted term came from. The app merges these into one `VocabularyContext`; the eval keeps the
/// label so a harmful swap can be traced back to the source that put the term there.
enum VocabSource: String, Codable, Sendable, CaseIterable {
    case dictionary
    case screen
    case installedApp = "installed app"
    case builtIn = "built-in"
    /// The AI model names an AI-prompt app adds (`VocabularyContext.aiModelTerms`).
    case aiModel = "ai model"
}

/// One realistic, invented vocabulary: installed app names, a screen, and a Dictionary. Rows pick a profile
/// (a subset of the sources) so a bad swap can be isolated to one source.
struct VocabFixture: Decodable, Sendable {
    struct DictionaryItem: Decodable, Sendable {
        let term: String
        let soundsLike: [String]
    }
    struct Screen: Decodable, Sendable { let context: String }

    let installedApps: [String]
    let screen: Screen
    let dictionary: [DictionaryItem]
    let profiles: [String: [String]]

    static func load(_ path: String) throws -> VocabFixture {
        try JSONDecoder().decode(VocabFixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
}

/// A vocabulary exactly as `PipelineSettings.vocabulary` assembles it for the fixture, plus the source of each term.
struct SourcedVocabulary: Sendable {
    let context: VocabularyContext
    /// Lowercased term text -> source.
    let sources: [String: VocabSource]
    /// Lowercased alias -> its term's source.
    let aliasSources: [String: VocabSource]

    func source(ofTerm text: String) -> VocabSource? { sources[text.lowercased()] }
}

extension VocabFixture {
    /// Builds the vocabulary for a profile through the app's own assembly (`PipelineSettings.vocabulary`): the
    /// Dictionary, the screen terms the widened extractor takes, the installed names (cap, ordinary-word
    /// filter and de-duplication included) and the built-in terms.
    /// `aiPromptApp` builds it as the app does for an AI-prompt app (`PipelineSettings.aiPromptApp`).
    func vocabulary(profile: String, aiPromptApp: Bool = false) throws -> SourcedVocabulary {
        guard let included = profiles[profile] else {
            throw EvalError.missing("vocab-real-boost: the fixture has no profile \"\(profile)\"")
        }
        let entries = included.contains("dictionary")
            ? dictionary.map { DictionaryEntry(term: $0.term, soundsLike: $0.soundsLike) } : []
        let contextTerms = included.contains("screen") ? ContextTermTrace.extractedTerms(from: screen.context) : []
        let apps = included.contains("apps")
            ? installedApps.map { InstalledAppInfo(bundleID: "eval.fixture." + Self.slug($0), name: $0) } : []
        let settings = PipelineSettings(
            personalizer: Personalizer(dictionary: entries), contextTerms: contextTerms, installedApps: apps,
            aiPromptApp: aiPromptApp)
        let context = settings.vocabulary

        let dictionaryKeys = Set(entries.map { $0.term.lowercased() })
        let builtInKeys = Set(VocabularyContext.builtInTerms.map { $0.text.lowercased() })
        let aiModelKeys = Set(VocabularyContext.aiModelTerms.map { $0.text.lowercased() })
        var sources: [String: VocabSource] = [:]
        var aliasSources: [String: VocabSource] = [:]
        for term in context.terms {
            let key = term.text.lowercased()
            let source: VocabSource = term.installedApp ? .installedApp
                : dictionaryKeys.contains(key) ? .dictionary
                : builtInKeys.contains(key) ? .builtIn
                : aiPromptApp && aiModelKeys.contains(key) ? .aiModel : .screen
            sources[key] = source
            for alias in term.aliases { aliasSources[alias.lowercased()] = source }
        }
        return SourcedVocabulary(context: context, sources: sources, aliasSources: aliasSources)
    }

    private static func slug(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

struct HarmRow: Decodable, Sendable {
    let id: String
    let vocab: String
    let text: String
}

struct WinRow: Decodable, Sendable {
    let id: String
    let vocab: String
    let text: String
    let expect: [String]
}

enum VocabRowFiles {
    static func load<Row: Decodable>(_ path: String, as type: Row.Type = Row.self) throws -> [Row] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return try text.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
    }
}
