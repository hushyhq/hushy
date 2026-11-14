import Foundation

/// What the model returns for "is this a request for one of my files, and which?". Fields are
/// words and enum values only; there is nowhere to put a path or a command.
struct FileQueryModelOutput: StructuredOutput {
    var isFileRequest: Bool
    var nameWords: [String]
    var kind: String
    var time: String
    var location: String

    static let generationSchema = GenerationSchemaSpec(name: "FileQueryModelOutput", json: #"""
        {"additionalProperties":false,"properties":{"isFileRequest":{"description":"True only if the person asks to find, fetch, open or show one of their own files or documents on this Mac. False for notes, reminders, calendar, questions, anything else.","type":"boolean"},"nameWords":{"description":"Words from the request that would be in the file's name, copied as spoken. Empty if none.","items":{"type":"string"},"type":"array"},"kind":{"description":"The kind of file if said, else any","enum":["pdf","document","presentation","spreadsheet","image","folder","any"],"type":"string"},"time":{"description":"A time phrase from the request such as recent, march, 2024, last year; empty if none","type":"string"},"location":{"description":"desktop, documents or downloads if the request names that folder, else none","enum":["desktop","documents","downloads","none"],"type":"string"}},"required":["isFileRequest","nameWords","kind","time","location"],"title":"FileQueryModelOutput","type":"object","x-order":["isFileRequest","nameWords","kind","time","location"]}
        """#)
}

/// The fallback when the rules don't decide ("where is my passport"): one model call fills the
/// typed query, and code checks it. A name word the person did not say is dropped, so the model
/// cannot invent what to search for; no model, a slow model or a doubtful answer is "not a file
/// request" and the utterance goes on as an ordinary question about the person's own stuff.
public struct FileQueryExtractor: Sendable {
    public static let budget: Duration = .seconds(3)

    private let model: any LanguageModel

    public init(model: any LanguageModel = LanguageModels.current) {
        self.model = model
    }

    public func prewarm() {
        if model.isAvailable { model.prewarm(instructions: Self.instructions) }
    }

    public func extract(_ utterance: String, now: Date = Date(), calendar: Calendar = .current) async -> FileRequest? {
        guard model.isAvailable else { return nil }
        let spoken = FileRouter.prepared(AskRouter.frame(utterance))
        guard !spoken.isEmpty else { return nil }
        let output = await model.respond(
            instructions: Self.instructions, prompt: "Request: \(spoken.joined(separator: " "))",
            generating: FileQueryModelOutput.self, options: .greedy, budget: Self.budget)
        guard let output else { return nil }
        return Self.validated(output, spoken: spoken, now: now, calendar: calendar)
    }

    static func validated(_ output: FileQueryModelOutput, spoken: [String], now: Date, calendar: Calendar) -> FileRequest? {
        guard output.isFileRequest else { return nil }
        let heard = Set(spoken.map(FileVocabulary.singular))
        let known = Set(spoken)
        let terms = FileQuery.sanitizedTerms(output.nameWords).filter { term in
            !FileVocabulary.termStopWords.contains(term)
                && (known.contains(term) || heard.contains(FileVocabulary.singular(term)))
        }
        let kind = FileKind(rawValue: output.kind) ?? .any
        let location = FileVocabulary.locations[output.location]
        let time = timeHint(output.time, now: now, calendar: calendar)
        guard let query = FileQuery(terms: Array(terms.prefix(FileQuery.maxTerms)), kind: kind, time: time, location: location),
              !terms.isEmpty || kind != .any
        else { return nil }
        // The request itself was a guess (the rules could not tell), so it never opens: reveal at most.
        return FileRequest(query: query, action: .reveal)
    }

    /// "recent", "last year", or a bare "march" / "2024".
    static func timeHint(_ phrase: String, now: Date, calendar: Calendar) -> FileTimeHint? {
        var words = FileRouter.prepared(phrase)
        if let hint = FileRouter.takeTime(&words, now: now, calendar: calendar) { return hint }
        var framed = FileRouter.prepared("from " + phrase)
        return FileRouter.takeTime(&framed, now: now, calendar: calendar)
    }

    static let instructions = """
        You turn one spoken request into a search for a file on the person's Mac. Decide whether \
        they are asking to find, fetch, open or show one of their own files or documents. Notes, \
        reminders, calendar items, questions, advice and anything else are not file requests. Fill \
        nameWords with words that appear in the request and would appear in the file's name; never \
        invent a word, a name or a path. Fill kind, time and location only if the request says so.
        """
}
