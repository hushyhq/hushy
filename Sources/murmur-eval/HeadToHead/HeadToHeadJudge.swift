import CryptoKit
import Foundation

/// Blind preference judge for gate 12: the existing Codex CLI judge (`CodexCLIJudge`, default
/// `gpt-6-luna` at low effort) is asked which of two anonymised outputs reads better as typed
/// text, **two pairs per call**, under a hard budget of `maxCalls` calls (60 by default, per the
/// product-lead decision to stretch the Codex cap). Report-only: any failure — not logged in,
/// timeout, unparseable answer — leaves the affected pairs unjudged and never throws out of
/// `judge(_:)`, so a quota outage cannot fail a run.
///
/// The judge sees only `BlindedPair.a`/`.b` and a neutral pair number, never a product name and
/// never `hushyIsA`; unblinding happens in the runner after the verdicts come back.
struct HeadToHeadJudge {
    static let defaultMaxCalls = 60
    static let pairsPerCall = 2

    struct Verdict: Equatable, Sendable {
        let id: String
        let choice: BlindChoice
        let reasoning: String
    }

    struct Outcome: Equatable, Sendable {
        var verdicts: [Verdict] = []
        var callsMade = 0
        var callsFailed = 0
        /// Pairs left unjudged because the call budget ran out (not because a call failed).
        var unjudgedForBudget: [String] = []
        var skippedReason: String?
    }

    let backend: CodexCLIJudge
    let maxCalls: Int
    let cacheDirectory: URL?

    init(backend: CodexCLIJudge, maxCalls: Int = HeadToHeadJudge.defaultMaxCalls, cacheDirectory: URL? = HeadToHeadJudge.defaultCacheDirectory) {
        self.backend = backend
        self.maxCalls = min(max(maxCalls, 0), HeadToHeadJudge.defaultMaxCalls)
        self.cacheDirectory = cacheDirectory
    }

    static var defaultCacheDirectory: URL {
        JudgeCache.defaultDirectory.appendingPathComponent("head-to-head", isDirectory: true)
    }

    /// How many pairs fit in the budget: `maxCalls * pairsPerCall`.
    var pairBudget: Int { maxCalls * Self.pairsPerCall }

    func judge(_ pairs: [BlindedPair]) async -> Outcome {
        var outcome = Outcome()
        let judged = Array(pairs.prefix(pairBudget))
        outcome.unjudgedForBudget = pairs.dropFirst(pairBudget).map(\.id)
        let batches = stride(from: 0, to: judged.count, by: Self.pairsPerCall).map { Array(judged[$0..<min($0 + Self.pairsPerCall, judged.count)]) }

        let results: [(Int, Result<[Verdict], Error>)]
        do {
            results = try await JudgeClient.mapConcurrently(Array(batches.enumerated())) { item in
                let (index, batch) = item
                do {
                    return (index, .success(try await judgeBatch(batch)))
                } catch {
                    return (index, .failure(error))
                }
            }
        } catch {
            outcome.skippedReason = error.localizedDescription
            return outcome
        }

        for (_, result) in results.sorted(by: { $0.0 < $1.0 }) {
            outcome.callsMade += 1
            switch result {
            case .success(let verdicts): outcome.verdicts.append(contentsOf: verdicts)
            case .failure(let error):
                outcome.callsFailed += 1
                if case CLIJudgeError.cliNotLoggedIn = error, outcome.skippedReason == nil {
                    outcome.skippedReason = error.localizedDescription
                }
            }
        }
        return outcome
    }

    private func judgeBatch(_ batch: [BlindedPair]) async throws -> [Verdict] {
        let prompt = Self.prompt(for: batch)
        if let cached = loadCached(prompt: prompt), let verdicts = try? Self.parse(cached, batch: batch) {
            return verdicts
        }
        let text = try await backend.completeText(prompt: prompt)
        if let verdicts = try? Self.parse(text, batch: batch) {
            storeCached(text, prompt: prompt)
            return verdicts
        }
        let retry = prompt + "\n\nYour previous response was not valid JSON. Respond again with ONLY the JSON object, no other text."
        let secondText = try await backend.completeText(prompt: retry)
        let verdicts = try Self.parse(secondText, batch: batch)
        storeCached(secondText, prompt: prompt)
        return verdicts
    }

    // MARK: Prompt and parsing

    static func prompt(for batch: [BlindedPair]) -> String {
        let rendered = batch.enumerated().map { index, pair in
            """
            Pair \(index + 1)
            Output A:
            \(pair.a)

            Output B:
            \(pair.b)
            """
        }.joined(separator: "\n\n")
        return """
            You are comparing two dictation products. For each pair below, the same spoken \
            paragraph was dictated into two products; you see only their final text output, \
            labelled A and B in random order. Decide which output a careful writer would rather \
            paste as-is: faithful to what was evidently said (no dropped or invented facts, \
            names, numbers or negations), correctly cleaned of speech disfluencies, and \
            punctuated like typed text. Prefer "tie" when both are equally usable or differ only \
            in trivial punctuation or casing.

            Respond with ONLY a single JSON object and nothing else — no prose, no markdown code \
            fences. The object must have exactly this shape, one entry per pair, in order:
            {"verdicts": [{"pair": 1, "winner": "A" | "B" | "tie", "reasoning": "<one sentence>"}, …]}

            \(rendered)

            Respond with only the JSON object described above.
            """
    }

    enum ParseError: LocalizedError, Equatable {
        case noJSON
        case malformed(String)
        case wrongCount(expected: Int, got: Int)

        var errorDescription: String? {
            switch self {
            case .noJSON: "Head-to-head judge returned no JSON object"
            case .malformed(let detail): "Head-to-head judge JSON was not a verdict list: \(detail)"
            case .wrongCount(let expected, let got): "Head-to-head judge returned \(got) verdicts for \(expected) pairs"
            }
        }
    }

    private struct Response: Decodable {
        struct Entry: Decodable {
            let pair: Int
            let winner: String
            let reasoning: String?
        }
        let verdicts: [Entry]
    }

    /// Maps the judge's position-numbered verdicts back onto `batch` by pair number. Throws on
    /// a count mismatch or an unknown winner label, which triggers the one allowed retry.
    static func parse(_ text: String, batch: [BlindedPair]) throws -> [Verdict] {
        guard let json = extractJSONObject(from: text) else { throw ParseError.noJSON }
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: Data(json.utf8))
        } catch {
            throw ParseError.malformed(String(describing: error))
        }
        guard response.verdicts.count == batch.count else {
            throw ParseError.wrongCount(expected: batch.count, got: response.verdicts.count)
        }
        return try response.verdicts.map { entry in
            guard batch.indices.contains(entry.pair - 1) else {
                throw ParseError.malformed("pair number \(entry.pair) out of range")
            }
            let label = entry.winner.trimmingCharacters(in: .whitespaces).lowercased()
            let choice: BlindChoice
            switch label {
            case "a": choice = .a
            case "b": choice = .b
            case "tie", "equal", "neither": choice = .tie
            default: throw ParseError.malformed("unknown winner \(entry.winner)")
            }
            return Verdict(id: batch[entry.pair - 1].id, choice: choice, reasoning: entry.reasoning ?? "")
        }
    }

    private static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        var index = start
        while index < text.endIndex {
            let char = text[index]
            if inString {
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == "\"" { inString = false }
            } else {
                switch char {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return String(text[start...index]) }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    // MARK: Cache (raw response text keyed by backend, model and prompt hash)

    private func cacheURL(prompt: String) -> URL? {
        guard let cacheDirectory else { return nil }
        let hex = SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("\(backend.name)__\(backend.model)__\(hex).txt")
    }

    private func loadCached(prompt: String) -> String? {
        guard let url = cacheURL(prompt: prompt) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func storeCached(_ text: String, prompt: String) {
        guard let url = cacheURL(prompt: prompt) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
