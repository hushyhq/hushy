import Foundation

/// Calls Jev with rubric v2 (`JevRubric`), caching every answer on disk under
/// `.build/judge-cache/jev/` keyed by the full request (model id + rubric version + state +
/// questions), so reruns cost nothing and a rubric edit invalidates the cache by itself.
/// `useCache: false` bypasses the cache; determinism probes use `repeatTag` instead. The API key is passed in by the caller and
/// only ever reaches `TypeSafeClient.ask`'s Authorization header.
struct JevJudge: Sendable {
    let apiKey: String
    var cacheDirectory: URL? = JevJudge.defaultCacheDirectory
    /// Caps real (uncached) API calls; nil = unlimited.
    var budget: CallBudget?

    static var defaultCacheDirectory: URL {
        JudgeCache.defaultDirectory.appendingPathComponent("jev", isDirectory: true)
    }

    struct Timed<Value: Sendable>: Sendable {
        let value: Value
        /// Wall time of the network call; nil when served from cache.
        let seconds: Double?
    }

    func judge(
        level: String, spoken: String, output: String, reference: String?, useCache: Bool = true,
        repeatTag: String? = nil
    ) async throws -> Timed<JevJudgment> {
        let state = JevRubric.state(level: level, spoken: spoken, output: output, reference: reference)
        let questions = JevRubric.questions(hasReference: reference != nil)
        let timed = try await cachedAsk(state: state, questions: questions, useCache: useCache, repeatTag: repeatTag)
        return Timed(value: try JevJudgment.decode(timed.value), seconds: timed.seconds)
    }

    /// Blind pairwise preference for A/B experiments (e.g. model-first vs heuristic, MLX vs Apple
    /// FM). Callers should ask both orders and treat an order flip as "same"; see `JevPairwise`.
    func prefer(
        level: String, spoken: String, reference: String?, first: String, second: String, useCache: Bool = true
    ) async throws -> Timed<JevPairwise> {
        var fields: [String: TypeSafeClient.AnyJSON] = [
            "level": .string(JevRubric.displayLevel(level)), "level_rules": .string(JevRubric.promise(for: level)),
            "spoken": .string(spoken), "output_a": .string(first), "output_b": .string(second),
        ]
        if let reference { fields["reference"] = .string(reference) }
        let timed = try await cachedAsk(state: .object(fields), questions: JevPairwise.questions, useCache: useCache)
        return Timed(value: try JevPairwise.decode(timed.value), seconds: timed.seconds)
    }

    // MARK: Cache + transport

    func cachedAsk(
        state: TypeSafeClient.AnyJSON, questions: [String: TypeSafeClient.Question], useCache: Bool,
        repeatTag: String? = nil
    ) async throws -> Timed<TypeSafeClient.Response> {
        // `repeatTag` stores a deliberate second answer to the same request under its own key,
        // so determinism probes are reproducible from cache too.
        let key = JevRubric.cacheKey(state: state, questions: questions) + (repeatTag.map { "__\($0)" } ?? "")
        if useCache, let cached = load(key) { return Timed(value: cached, seconds: nil) }
        if let budget, !(await budget.take()) { throw CallBudget.Exhausted(name: budget.name) }
        let started = Date()
        let response = try await TypeSafeClient.ask(
            state: state, questions: questions, apiKey: apiKey, model: JevRubric.model)
        let seconds = Date().timeIntervalSince(started)
        if useCache { store(response, key: key) }
        return Timed(value: response, seconds: seconds)
    }

    private func fileURL(_ key: String) -> URL? {
        cacheDirectory?.appendingPathComponent("\(key).json", isDirectory: false)
    }

    private func load(_ key: String) -> TypeSafeClient.Response? {
        guard let url = fileURL(key), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TypeSafeClient.Response.self, from: data)
    }

    private func store(_ response: TypeSafeClient.Response, key: String) {
        guard let url = fileURL(key), let directory = cacheDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(response) { try? data.write(to: url, options: .atomic) }
    }
}

/// Jev's pairwise answer: a Choice over which output is the better cleanup at the level, plus
/// one meaning-safety Noul per side so a "better reading" output that broke meaning is visible.
struct JevPairwise: Codable, Equatable, Sendable {
    /// "a", "b" or "same".
    let choice: String
    let probabilities: [String: Double]
    let aBreaksMeaning: Double
    let bBreaksMeaning: Double

    static let questions: [String: TypeSafeClient.Question] = [
        "better": .init(
            type: .choice,
            instructions: .string(
                "Which is the better cleanup of `spoken` at `level` (see `level_rules`)? Faithfulness comes first: "
                    + "an output that drops or changes something the speaker meant is worse than one that keeps a "
                    + "filler. Then prefer the output that reads cleaner while staying within `level_rules`."),
            criteria: .strings([
                "a": "`output_a` is the better cleanup.",
                "b": "`output_b` is the better cleanup.",
                "same": "Both are equally good, or they differ only in ways that do not matter to a reader.",
            ])),
        "a_breaks_meaning": .init(
            type: .noul,
            instructions: .string(
                "Does `output_a` drop, change or contradict a fact, name, number, negation or request the speaker "
                    + "still meant in `spoken`?")),
        "b_breaks_meaning": .init(
            type: .noul,
            instructions: .string(
                "Does `output_b` drop, change or contradict a fact, name, number, negation or request the speaker "
                    + "still meant in `spoken`?")),
    ]

    static func decode(_ response: TypeSafeClient.Response) throws -> JevPairwise {
        guard let better = response.answers["better"], let choice = better.choice,
              let a = response.answers["a_breaks_meaning"]?.noul, let b = response.answers["b_breaks_meaning"]?.noul
        else { throw TypeSafeClient.ClientError.decoding("Jev pairwise response is missing answers") }
        return JevPairwise(choice: choice, probabilities: better.probabilities ?? [:], aBreaksMeaning: a, bBreaksMeaning: b)
    }
}

/// A hard cap on real (uncached) judge calls, shared across concurrent tasks.
actor CallBudget {
    struct Exhausted: LocalizedError {
        let name: String
        var errorDescription: String? { "\(name) call budget exhausted" }
    }

    let name: String
    private(set) var remaining: Int
    private(set) var used = 0

    init(name: String, limit: Int) {
        self.name = name
        remaining = max(0, limit)
    }

    func take() -> Bool {
        guard remaining > 0 else { return false }
        remaining -= 1
        used += 1
        return true
    }
}
