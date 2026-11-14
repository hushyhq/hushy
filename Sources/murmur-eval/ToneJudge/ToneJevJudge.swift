import Foundation
import MurmurCore

/// Asks Jev the tone-v1 questions. Answers are cached on disk under `.build/judge-cache/jev-tone/`,
/// keyed by model + rubric version + the full request, exactly like `JevJudge`, so a rerun is free
/// and a rubric edit invalidates the cache by itself. The API key only ever reaches
/// `TypeSafeClient.ask`'s Authorization header.
struct ToneJevJudge: Sendable {
    let apiKey: String
    var cacheDirectory: URL? = JudgeCache.defaultDirectory.appendingPathComponent("jev-tone", isDirectory: true)
    var budget: CallBudget?

    func read(spoken: String, output: String) async throws -> ToneRead {
        let response = try await cachedAsk(
            state: ToneJevRubric.readState(spoken: spoken, output: output), questions: ToneJevRubric.readQuestions)
        return try ToneRead.decode(response)
    }

    func fit(tone: DictationTone, spoken: String, output: String) async throws -> ToneFit {
        let response = try await cachedAsk(
            state: ToneJevRubric.fitState(tone: tone, spoken: spoken, output: output), questions: ToneJevRubric.fitQuestions)
        return try ToneFit.decode(response)
    }

    private func cachedAsk(
        state: TypeSafeClient.AnyJSON, questions: [String: TypeSafeClient.Question]
    ) async throws -> TypeSafeClient.Response {
        let key = ToneJevRubric.cacheKey(state: state, questions: questions)
        if let cached = load(key) { return cached }
        if let budget, !(await budget.take()) { throw CallBudget.Exhausted(name: budget.name) }
        let response = try await TypeSafeClient.ask(state: state, questions: questions, apiKey: apiKey, model: ToneJevRubric.model)
        store(response, key: key)
        return response
    }

    private func load(_ key: String) -> TypeSafeClient.Response? {
        guard let url = cacheDirectory?.appendingPathComponent("\(key).json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TypeSafeClient.Response.self, from: data)
    }

    private func store(_ response: TypeSafeClient.Response, key: String) {
        guard let directory = cacheDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(response) {
            try? data.write(to: directory.appendingPathComponent("\(key).json"), options: .atomic)
        }
    }
}
