import Foundation

/// Case format and deterministic scoring for spoken prompts to coding agents (`murmur-eval agent-prompts`).
enum AgentPromptsChecks {
    struct Case: Decodable, Sendable {
        let id: String
        let app: String
        let bundle: String
        let spoken: String
        let intended: String
        let identifiers: [String]
        let requirements: [String]
        let screenTerms: [String]
        let listItems: Int?
        let responseTraps: [String]?

        enum CodingKeys: String, CodingKey {
            case id, app, bundle, spoken, intended, identifiers, requirements
            case screenTerms = "screen_terms"
            case listItems = "list_items"
            case responseTraps = "response_traps"
        }
    }

    struct Verdict: Equatable, Sendable {
        let id: String
        let identifierExactRate: Double
        let identifiersMissing: [String]
        let requirementsKeptRate: Double
        let requirementsMissing: [String]
        let inventedRequirement: Bool
        let answeredInsteadOfCleaned: Bool
        let listShapeOK: Bool
    }

    static let scorerVersion = 1

    private static let answerPrefixes = [
        "sure,", "sure ", "certainly", "here's", "here is", "i'll ", "i will ", "let me ",
        "i've ", "i have ", "done.", "completed", "i can ", "absolutely",
    ]

    private static let inventedMarkers = [
        "i created", "i added", "i removed", "pull request", "merged", "deployed",
        "i implemented", "i fixed it", "the fix is",
    ]

    static func loadCases(_ path: String) throws -> [Case] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let decoder = JSONDecoder()
        let items = try text.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .compactMap { line -> Case? in
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      obj["_header"] == nil, obj["schema"] == nil else { return nil }
                return try decoder.decode(Case.self, from: Data(line.utf8))
            }
        guard !items.isEmpty, Set(items.map(\.id)).count == items.count else {
            throw EvalError.missing("agent-prompts cases must be nonempty with unique IDs")
        }
        return items
    }

    private static func normalizedPhrase(_ text: String) -> String {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    private static func hasPhrase(_ haystack: String, _ needle: String) -> Bool {
        let key = normalizedPhrase(needle)
        guard !key.isEmpty else { return true }
        return normalizedPhrase(haystack).contains(key)
    }

    private static func listItemCount(_ text: String) -> Int {
        let numbered = text.ranges(of: /(?m)^\s*\d+[\.)]\s+/).count
        let bullets = text.ranges(of: /(?m)^\s*[-*•]\s+/).count
        let lower = text.lowercased()
        let semis = (lower.contains("first,") && lower.contains("second,")) ? text.filter { $0 == ";" }.count + 1 : 0
        return max(numbered, bullets, semis > 1 ? semis : 0)
    }

    private static func answeredInstead(_ text: String) -> Bool {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if answerPrefixes.contains(where: { stripped.hasPrefix($0) }) { return true }
        if stripped.hasPrefix("```"), stripped.prefix(80).contains("fix") { return true }
        return false
    }

    private static func inventedRequirement(output: String, reference: Case) -> Bool {
        let lower = output.lowercased()
        for trap in reference.responseTraps ?? [] where lower.contains(trap.lowercased()) { return true }
        let intended = reference.intended.lowercased()
        for marker in inventedMarkers where lower.contains(marker) && !intended.contains(marker) { return true }
        return false
    }

    static func score(_ reference: Case, output: String) -> Verdict {
        let identifiers = reference.identifiers
        let idHits = identifiers.filter { output.contains($0) }
        let idRate = identifiers.isEmpty ? 1.0 : Double(idHits.count) / Double(identifiers.count)
        let requirements = reference.requirements
        let reqHits = requirements.filter { hasPhrase(output, $0) }
        let reqRate = requirements.isEmpty ? 1.0 : Double(reqHits.count) / Double(requirements.count)
        let expectedItems = reference.listItems ?? 0
        let listOK = expectedItems <= 1 || listItemCount(output) >= expectedItems
        return Verdict(
            id: reference.id,
            identifierExactRate: idRate,
            identifiersMissing: identifiers.filter { !output.contains($0) },
            requirementsKeptRate: reqRate,
            requirementsMissing: requirements.filter { !hasPhrase(output, $0) },
            inventedRequirement: inventedRequirement(output: output, reference: reference),
            answeredInsteadOfCleaned: answeredInstead(output),
            listShapeOK: listOK)
    }
}
