import Foundation
import MurmurCore

/// `murmur-eval ask files [--dataset Evals/ask-files-dev.json] [--report path.json] [--show N]`
///
/// The "find my file" voice route, deterministic and model-free, on invented requests over an
/// invented file tree held in memory (`InMemoryFileFinder`): it never reads a real folder. Each
/// case is scored on three things that must all hold: the route (`AskRouter`), the typed query
/// the rules built (name terms, kind, time, location, action), and the outcome class the engine
/// reached on the fake tree (found_one / found_several / none, and which file for found_one).
/// "maybe_file" cases are the ones the rules leave to the model; the model call is not scored here.
extension AskRunner {
    struct FilesSet: Decodable {
        struct TreeFile: Decodable {
            var path: String
            var modified: String
            var kinds: [String]
            var text: String?
            var folder: Bool?
        }
        struct Case: Decodable {
            struct Expect: Decodable {
                var route: String
                var terms: [String]?
                var kind: String?
                var time: String?
                var location: String?
                var action: String?
                var outcome: String?
                var file: String?
            }
            var id: String
            var utterance: String
            var category: String
            var expect: Expect
        }
        var format: String
        var name: String
        var now: String
        var timeZone: String
        var home: String
        var tree: [TreeFile]
        var cases: [Case]
    }

    static func files(_ args: Arguments) async throws {
        let path = args.string("dataset") ?? "Evals/ask-files-dev.json"
        let url = URL(fileURLWithPath: path)
        try SealedEvalGuard.assertTuningSafe(url, purpose: "ask files eval")
        let set = try JSONDecoder().decode(FilesSet.self, from: Data(contentsOf: url))
        guard set.format == "hushy.ask-files/v1" else { throw EvalError.missing("\(path): unexpected format \(set.format)") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: set.timeZone) ?? .gmt
        let now = ProposalFields.parseISO8601(set.now) ?? Date()
        let home = URL(fileURLWithPath: set.home, isDirectory: true)
        var candidates: [FileCandidate] = []
        var contents: [String: String] = [:]
        for file in set.tree {
            let full = home.path + "/" + file.path
            let day = ProposalFields.parseISO8601(file.modified + "T12:00:00Z")
            candidates.append(FileCandidate(
                path: full, modified: day, kinds: Set(file.kinds.compactMap(FileKind.init(rawValue:))), isFolder: file.folder ?? false))
            if let text = file.text { contents[full] = text }
        }
        let engine = FileFindEngine(
            finder: InMemoryFileFinder(files: candidates, contents: contents), home: home, now: { now }, calendar: calendar)

        var rows: [(id: String, category: String, route: Bool, query: Bool?, outcome: Bool?, note: String, utterance: String)] = []
        for item in set.cases {
            let want = item.expect
            let routed = AskRouter.route(item.utterance, now: now)
            var routeOK = false
            var queryOK: Bool?
            var outcomeOK: Bool?
            var notes: [String] = []
            switch routed {
            case .findFile(let request):
                routeOK = want.route == "find_file"
                if routeOK {
                    let mismatch = queryMismatches(request, want)
                    queryOK = mismatch.isEmpty
                    notes += mismatch
                    let outcome = await engine.find(request)
                    let check = outcomeCheck(outcome, want, home: home.path)
                    outcomeOK = check.ok
                    if !check.ok { notes.append(check.note) }
                }
            case .maybeFile: routeOK = want.route == "maybe_file"
            case .askOwn: routeOK = want.route == "ask_own"
            case .askAI: routeOK = want.route == "ask_ai"
            case .summarizeScreen: routeOK = want.route == "summarize"
            case .none: routeOK = want.route == "none"
            }
            if !routeOK { notes.append("routed \(describe(routed)), wanted \(want.route)") }
            rows.append((item.id, item.category, routeOK, queryOK, outcomeOK, notes.joined(separator: "; "), item.utterance))
        }
        report(set: set, rows: rows, args: args)
        try writeReport(args, name: set.name, rows: rows.map { ($0.id, $0.route && $0.query != false && $0.outcome != false) })
    }

    private static func queryMismatches(_ request: FileRequest, _ want: FilesSet.Case.Expect) -> [String] {
        var out: [String] = []
        if Set(request.query.terms) != Set(want.terms ?? []) { out.append("terms \(request.query.terms)") }
        if request.query.kind.rawValue != (want.kind ?? "any") { out.append("kind \(request.query.kind.rawValue)") }
        if timeName(request.query.time) != want.time { out.append("time \(timeName(request.query.time) ?? "nil")") }
        if request.query.location?.rawValue != want.location { out.append("location \(request.query.location?.rawValue ?? "nil")") }
        if request.action.rawValue != (want.action ?? "reveal") { out.append("action \(request.action.rawValue)") }
        return out
    }

    private static func timeName(_ hint: FileTimeHint?) -> String? {
        switch hint {
        case nil: nil
        case .recent: "recent"
        case .month(let month): "month:\(month)"
        case .year(let year): "year:\(year)"
        case .monthOfYear(let month, let year): "monthyear:\(month):\(year)"
        }
    }

    private static func outcomeCheck(_ outcome: FileFindOutcome, _ want: FilesSet.Case.Expect, home: String) -> (ok: Bool, note: String) {
        let got: String
        var file: String?
        switch outcome {
        case .foundOne(let candidate, _):
            got = "found_one"
            file = String(candidate.path.dropFirst(home.count + 1))
        case .foundSeveral: got = "found_several"
        case .none: got = "none"
        case .unavailable: got = "unavailable"
        case .cancelled: got = "cancelled"
        }
        guard got == want.outcome else { return (false, "outcome \(got)\(file.map { " (\($0))" } ?? ""), wanted \(want.outcome ?? "-")") }
        if let expected = want.file, file != expected { return (false, "picked \(file ?? "-"), wanted \(expected)") }
        return (true, "")
    }

    private static func report(
        set: FilesSet,
        rows: [(id: String, category: String, route: Bool, query: Bool?, outcome: Bool?, note: String, utterance: String)],
        args: Arguments
    ) {
        func passed(_ row: (id: String, category: String, route: Bool, query: Bool?, outcome: Bool?, note: String, utterance: String)) -> Bool {
            row.route && row.query != false && row.outcome != false
        }
        let routeOK = rows.filter(\.route).count
        let queried = rows.filter { $0.query != nil }
        let queryOK = queried.filter { $0.query == true }.count
        let outcomes = rows.filter { $0.outcome != nil }
        let outcomeOK = outcomes.filter { $0.outcome == true }.count
        var lines = [
            "### Ask files · \(set.name) · \(rows.count) cases (rules only; the model fallback is not scored)", "",
            "| measure | pass | n |", "|---|---|---|",
            "| route | \(percent(routeOK, rows.count)) | \(routeOK)/\(rows.count) |",
            "| query fields (find_file routes) | \(percent(queryOK, queried.count)) | \(queryOK)/\(queried.count) |",
            "| outcome class (find_file routes) | \(percent(outcomeOK, outcomes.count)) | \(outcomeOK)/\(outcomes.count) |",
            "| **all three** | **\(percent(rows.filter(passed).count, rows.count))** | \(rows.filter(passed).count)/\(rows.count) |",
            "", "| category | pass | n |", "|---|---|---|",
        ]
        for (category, group) in Dictionary(grouping: rows, by: \.category).sorted(by: { $0.key < $1.key }) {
            let ok = group.filter(passed).count
            lines.append("| \(category) | \(percent(ok, group.count)) | \(ok)/\(group.count) |")
        }
        let misses = rows.filter { !passed($0) }
        if !misses.isEmpty {
            lines += ["", "Misses (\(misses.count)):"]
            for row in misses.prefix(args.int("show") ?? 30) { lines.append("- \(row.id) `\(row.utterance)` → \(row.note)") }
        }
        print(lines.joined(separator: "\n"))
    }
}
