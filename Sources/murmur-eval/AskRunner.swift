import Foundation
import MurmurCore

/// The ask-actions evals (dev only; there is no sealed set yet):
///
///   murmur-eval ask routing   [--dataset Evals/ask-routing-dev.json] [--report path.json] [--show N]
///   murmur-eval ask grounding [--dataset Evals/ask-grounding-dev.json] [--backend apple|none] [--report path.json] [--show N]
///
/// `routing` runs `AskRouter` (deterministic, no model) over utterances labelled ask_ai /
/// ask_own / summarize / none, and reports per-route accuracy plus the negatives that must stay
/// plain dictation. `grounding` runs `OwnStuffAnswerer` over fixture sources and checks that
/// the answer cites the expected source, lists every `mustList` item, lists nothing from
/// `mustNotList`, and mentions every `mustMention` string; a `null` cite expects a not-found.
/// Both write `{"cases": [{"id", "passed"}]}` reports for `scripts/finetune/compare_runs.py`.
enum AskRunner {
    static func run(_ args: Arguments) async throws {
        switch args.positional.first {
        case "routing": try await routing(args)
        case "grounding": try await grounding(args)
        case "files": try await files(args)
        default: throw EvalError.missing("usage: murmur-eval ask routing|grounding|files [--dataset …] [--report …]")
        }
    }

    // MARK: Routing

    struct RoutingSet: Decodable {
        struct Case: Decodable {
            struct Expect: Decodable {
                var route: String
                var service: String?
                var question: String?
                var focus: String?
            }
            var id: String
            var utterance: String
            var category: String
            var expect: Expect
        }
        var format: String
        var name: String
        var cases: [Case]
    }

    static func routing(_ args: Arguments) async throws {
        let path = args.string("dataset") ?? "Evals/ask-routing-dev.json"
        let url = URL(fileURLWithPath: path)
        try SealedEvalGuard.assertTuningSafe(url, purpose: "ask routing eval")
        let set = try JSONDecoder().decode(RoutingSet.self, from: Data(contentsOf: url))
        guard set.format == "hushy.ask-routing/v1" else { throw EvalError.missing("\(path): unexpected format \(set.format)") }
        var rows: [(id: String, category: String, passed: Bool, got: String, want: String, utterance: String)] = []
        for item in set.cases {
            let got = AskRouter.route(item.utterance)
            let want = item.expect
            let passed: Bool
            switch got {
            case .askAI(let service, let question):
                passed = want.route == "ask_ai" && (want.service == nil || want.service == service.rawValue)
                    && (want.question == nil || want.question == question)
            case .askOwn: passed = want.route == "ask_own"
            case .summarizeScreen(let focus): passed = want.route == "summarize" && (want.focus == focus || want.focus == nil && focus == nil)
            case .none: passed = want.route == "none"
            case .findFile: passed = want.route == "find_file"
            case .maybeFile: passed = want.route == "maybe_file"
            }
            rows.append((item.id, item.category, passed, describe(got), want.route + (want.service.map { "/\($0)" } ?? ""), item.utterance))
        }
        let byCategory = Dictionary(grouping: rows, by: \.category).sorted { $0.key < $1.key }
        var lines = ["### Ask routing · \(set.name) · \(rows.count) cases", "", "| category | pass | n |", "|---|---|---|"]
        for (category, group) in byCategory {
            let passed = group.filter(\.passed).count
            lines.append("| \(category) | \(percent(passed, group.count)) | \(passed)/\(group.count) |")
        }
        let total = rows.filter(\.passed).count
        lines.append("| **all** | **\(percent(total, rows.count))** | \(total)/\(rows.count) |")
        let show = args.int("show") ?? 20
        let failures = rows.filter { !$0.passed }
        if !failures.isEmpty {
            lines.append("")
            lines.append("Misses (\(failures.count)):")
            for row in failures.prefix(show) { lines.append("- \(row.id) `\(row.utterance)` → \(row.got), wanted \(row.want)") }
        }
        print(lines.joined(separator: "\n"))
        try writeReport(args, name: set.name, rows: rows.map { ($0.id, $0.passed) })
    }

    static func describe(_ intent: AskIntent) -> String {
        switch intent {
        case .askAI(let service, let question): "ask_ai/\(service.rawValue) \"\(question)\""
        case .askOwn: "ask_own"
        case .summarizeScreen(let focus): "summarize" + (focus.map { " (\($0))" } ?? "")
        case .none: "none"
        case .findFile: "find_file"
        case .maybeFile: "maybe_file"
        }
    }

    // MARK: Grounding

    struct GroundingSet: Decodable {
        struct Source: Decodable {
            var id: String
            var kind: String
            var title: String
            var body: String
            var date: String?
        }
        struct Case: Decodable {
            struct Context: Decodable {
                var now: String
                var timeZone: String
                var locale: String
            }
            struct Expect: Decodable {
                var cite: String?
                var mustList: [String]
                var mustNotList: [String]
                var mustMention: [String]
            }
            var id: String
            var question: String
            var context: Context
            var expect: Expect
        }
        var format: String
        var name: String
        var sources: [Source]
        var cases: [Case]
    }

    struct FixtureSource: OwnStuffSource {
        let name = "fixture"
        let items: [OwnStuffItem]
        func search(_ query: OwnStuffQuery) async -> [OwnStuffItem] { items }
    }

    static func grounding(_ args: Arguments) async throws {
        let path = args.string("dataset") ?? "Evals/ask-grounding-dev.json"
        let url = URL(fileURLWithPath: path)
        try SealedEvalGuard.assertTuningSafe(url, purpose: "ask grounding eval")
        let set = try JSONDecoder().decode(GroundingSet.self, from: Data(contentsOf: url))
        guard set.format == "hushy.ask-grounding/v1" else { throw EvalError.missing("\(path): unexpected format \(set.format)") }
        let model = try args.languageModel()
        let items = set.sources.compactMap { source -> OwnStuffItem? in
            guard let kind = OwnStuffItem.Kind(rawValue: source.kind) else { return nil }
            return OwnStuffItem(id: source.id, kind: kind, title: source.title, body: source.body,
                                date: source.date.flatMap(ProposalFields.parseISO8601))
        }
        let answerer = OwnStuffAnswerer(sources: [FixtureSource(items: items)], model: model)
        var rows: [(id: String, passed: Bool, cited: Bool, invented: Int, missed: Int, note: String)] = []
        var latencies: [Double] = []
        for item in set.cases {
            let context = DateContext(
                now: ProposalFields.parseISO8601(item.context.now) ?? Date(),
                timeZone: TimeZone(identifier: item.context.timeZone) ?? .current, locale: Locale(identifier: item.context.locale))
            let start = Date()
            let result = await answerer.answer(item.question, context: context)
            latencies.append(Date().timeIntervalSince(start))
            rows.append(score(item, result))
        }
        let cited = rows.filter(\.cited).count
        let invented = rows.reduce(0) { $0 + $1.invented }
        let missed = rows.reduce(0) { $0 + $1.missed }
        let passed = rows.filter(\.passed).count
        let sorted = latencies.sorted()
        let p50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        var lines = [
            "### Ask grounding · \(set.name) · \(model.identifier) · \(rows.count) cases", "",
            "| pass | right source | invented items | missed items | p50 |", "|---|---|---|---|---|",
            "| \(percent(passed, rows.count)) | \(percent(cited, rows.count)) | \(invented) | \(missed) | \(String(format: "%.1f s", p50)) |",
        ]
        let failures = rows.filter { !$0.passed }
        if !failures.isEmpty {
            lines.append("")
            lines.append("Misses (\(failures.count)):")
            for row in failures.prefix(args.int("show") ?? 20) { lines.append("- \(row.id): \(row.note)") }
        }
        print(lines.joined(separator: "\n"))
        try writeReport(args, name: set.name, rows: rows.map { ($0.id, $0.passed) })
    }

    static func score(_ item: GroundingSet.Case, _ result: Result<AskAnswer, AskFailure>) -> (id: String, passed: Bool, cited: Bool, invented: Int, missed: Int, note: String) {
        let want = item.expect
        switch result {
        case .failure(let failure):
            let passed = want.cite == nil
            return (item.id, passed, passed, 0, 0, passed ? "not found, as expected" : "no answer (\(failure)), wanted \(want.cite ?? "-")")
        case .success(let answer):
            // `cite` and `mustMention` entries may list alternatives with "|" ("3|three").
            let cited = (want.cite ?? "").split(separator: "|").map(String.init).contains(answer.source.id)
            let text = AskRouter.normalize(answer.text + " " + answer.items.joined(separator: " "))
            let invented = want.mustNotList.filter { text.contains(AskRouter.normalize($0)) }
            // A listed item may carry its owner ("Ada to fix the pill hover bug") and still count.
            let missedItems = want.mustList.filter { item in !answer.items.contains { AskRouter.normalize($0).contains(AskRouter.normalize(item)) } }
            let missedMentions = want.mustMention.filter { mention in
                !mention.split(separator: "|").contains { text.contains(AskRouter.normalize(String($0))) }
            }
            let passed = cited && invented.isEmpty && missedItems.isEmpty && missedMentions.isEmpty
            var notes: [String] = []
            if !cited { notes.append("cited \(answer.source.id), wanted \(want.cite ?? "-")") }
            if !invented.isEmpty { notes.append("invented \(invented)") }
            if !missedItems.isEmpty { notes.append("missed items \(missedItems)") }
            if !missedMentions.isEmpty { notes.append("didn't mention \(missedMentions)") }
            if answer.isExtractive { notes.append("(extractive fallback)") }
            return (item.id, passed, cited, invented.count, missedItems.count + missedMentions.count, notes.joined(separator: "; "))
        }
    }

    // MARK: Shared

    static func percent(_ part: Int, _ whole: Int) -> String {
        whole == 0 ? "–" : String(format: "%.0f%%", Double(part) / Double(whole) * 100)
    }

    /// `{"name", "cases": [{"id", "passed"}]}` — the shape `compare_runs.py` reads.
    static func writeReport(_ args: Arguments, name: String, rows: [(String, Bool)]) throws {
        guard let path = args.string("report") else { return }
        let report: [String: Any] = ["name": name, "cases": rows.map { ["id": $0.0, "passed": $0.1] }]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
    }
}
