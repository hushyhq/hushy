import Foundation
import MurmurCore

/// `murmur-eval rewrite-check --cases <file.jsonl> --out <file.jsonl> [--tone refined] [--bundle <id>] [--no-rewrite-check]`
/// `murmur-eval rewrite-check --pairs <file>[,<file>…] --out <file.jsonl>`
///
/// Is what the cleanup delivers a rewrite of what was said, or something else (a reply, a sentence of the model's own)?
///
/// `--cases`: each line is a JSON object with at least `id` and `spoken` (invented text only; other fields pass through).
/// Every case goes through `DictationPipeline.clean` under the settings the app builds for a dictation
/// (`LiveShapeRunner.settings`), once with the model and once rules only. The output file has, per case, the delivered
/// text, the rules text, whether the model's text was used and why not, the model's answer when a check refused it, and
/// the `RewriteAccount` of the model's answer against its input. `--no-rewrite-check` runs the cleaner as it was before
/// the last check existed, so one run shows what was delivered then and what the check would have refused.
///
/// `--pairs`: the files are dev sets that hold an input beside the text a person would want (`spoken`/`raw`/`input` and
/// `expected`/`ideal`/`reference`). No model runs. Each pair's wanted text is measured against its input, so the share of
/// wanted rewrites the check would refuse is known before it ships. Ids and counts only on the terminal.
enum RewriteCheckRunner {
    static func run(_ args: Arguments) async throws {
        guard let out = args.string("out") else { throw failure("rewrite-check needs --out <file.jsonl>") }
        if let pairs = args.string("pairs") {
            try measurePairs(pairs.split(separator: ",").map(String.init), out: out)
        } else if let cases = args.string("cases") {
            try await runCases(cases, out: out, args: args)
        } else {
            throw failure("rewrite-check needs --cases <file.jsonl> or --pairs <file>[,<file>…]")
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "murmur-eval", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func numbers(_ account: RewriteAccount) -> [String: Any] {
        [
            "words": account.words, "letters": account.letters, "in_order": account.inOrder,
            "in_order_letters": account.inOrderLetters, "elsewhere": account.elsewhere,
            "elsewhere_letters": account.elsewhereLetters, "added": account.added, "added_letters": account.addedLetters,
            "share": account.share, "is_rewrite": account.isRewrite,
            "new_words": account.newWords, "dropped_words": account.droppedWords, "repeated_words": account.repeatedWords,
            "invents_speaker": account.inventsSpeaker, "wording": account.rewordsFaithfully,
            "register_ok": account.isRewrite(under: .professional),
        ]
    }

    private static func write(_ rows: [[String: Any]], to path: String) throws {
        let lines = try rows.map { row in
            String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: Cases through the app's cleanup path

    private static func runCases(_ path: String, out: String, args: Arguments) async throws {
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isNewline)
        let tone = DictationTone(rawValue: args.string("tone") ?? "refined") ?? .refined
        let bundle = args.string("bundle") ?? "com.apple.TextEdit"
        let (settings, category) = LiveShapeRunner.settings(tone: tone, bundleID: bundle)
        let checks = !args.flag("no-rewrite-check")
        print("### Rewrite check · \(lines.count) cases · tone \(tone.rawValue) · \(bundle) → \(category.rawValue) · level \(settings.cleanupOptions.level.rawValue) · last check \(checks ? "on" : "off")")
        var rows: [[String: Any]] = []
        var used = 0, refused = 0, wouldRefuse = 0, otherGuard = 0, noAnswer = 0
        for line in lines {
            guard var row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let spoken = row["spoken"] as? String else { throw failure("a case needs id and spoken") }
            let cleaner = SmartCleaner(retainsRejectedCandidates: true, requiresRewrite: checks)
            let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: cleaner)
            let started = ContinuousClock.now
            let result = await pipeline.clean(spoken, settings: settings, released: started)
            let rules = await DictationPipeline(transcriber: NullTranscriber(), cleaner: SmartCleaner(model: NullLanguageModel()))
                .clean(spoken, settings: settings, strategy: .rules, released: ContinuousClock.now)
            row["output"] = result.text
            row["rules"] = rules.text
            row["used_model"] = result.usedModel
            row["why"] = result.groups.map(\.label)
            row["wait_ms"] = Int(ModelPace.ms(ContinuousClock.now - started))
            row["candidates"] = result.groups.compactMap(\.rejectedCandidate)
            row["accounts"] = result.groups.compactMap { $0.account.map(numbers) }
            row["delivered_account"] = numbers(RewriteAccount.measure(result.text, against: spoken))
            rows.append(row)
            for group in result.groups {
                if group.outcome == .used { used += 1 }
                if group.guardCode == .notARewrite { refused += 1 } else if group.outcome == .rejectedByGuard { otherGuard += 1 }
                if group.outcome != .used, group.outcome != .rejectedByGuard { noAnswer += 1 }
                if let account = group.account, !account.isRewrite { wouldRefuse += 1 }
            }
        }
        try write(rows, to: out)
        print("- groups: model text used \(used), refused as not a rewrite \(refused), refused by another check \(otherGuard), no answer \(noAnswer)")
        print("- answers the last check refuses or would refuse: \(wouldRefuse)")
        print("- rows written to \(out)")
    }

    // MARK: Wanted rewrites in the dev sets

    private static let inputKeys = ["spoken", "raw", "input"]
    private static let wantedKeys = ["expected", "ideal", "reference"]

    private static func cases(in path: String) throws -> [[String: Any]] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if path.hasSuffix(".jsonl") {
            return try String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
                .compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        let object = try JSONSerialization.jsonObject(with: data)
        if let list = object as? [[String: Any]] { return list }
        return ((object as? [String: Any])?["cases"] as? [[String: Any]]) ?? []
    }

    private static func measurePairs(_ paths: [String], out: String) throws {
        var rows: [[String: Any]] = []
        print("| set | pairs | wanted text refused | ids |")
        print("|---|---|---|---|")
        for path in paths {
            let name = URL(fileURLWithPath: path).lastPathComponent
            var pairs = 0
            var refused: [String] = []
            for item in try cases(in: path) {
                guard let input = inputKeys.lazy.compactMap({ item[$0] as? String }).first,
                      let wanted = wantedKeys.lazy.compactMap({ item[$0] as? String }).first, !wanted.isEmpty else { continue }
                let id = (item["id"] as? String) ?? "\(pairs)"
                let account = RewriteAccount.measure(wanted, against: input)
                pairs += 1
                if !account.isRewrite { refused.append(id) }
                var row = numbers(account)
                row["set"] = name
                row["id"] = id
                row["input_words"] = RewriteAccount.measure(input, against: input).words
                rows.append(row)
            }
            print("| \(name) | \(pairs) | \(refused.count) | \(refused.prefix(12).joined(separator: " ")) |")
        }
        try write(rows, to: out)
        print("rows written to \(out)")
    }
}
