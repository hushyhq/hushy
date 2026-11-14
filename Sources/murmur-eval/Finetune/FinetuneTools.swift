import CryptoKit
import Foundation
import HushyModelsMLX
import MurmurCore

/// The Swift half of the voice-actions (tools-v1) fine-tune data (`scripts/finetune/tools`,
/// `docs/product/FINETUNE.md` "Voice actions data v1"). Python writes candidate rows; these
/// subcommands decide, with the shipping code, whether each label is one the runtime accepts, and
/// render the exact prompt and answer bytes the MLX runtime uses:
///
///   finetune tools-prompt [--grammar tool-first]
///       JSON: prompt version, catalogue version, grammar mode, system text and its SHA-256
///   finetune tools-check --in cand.jsonl --out checked.jsonl [--grammar tool-first]
///       rows {id, utterance, context{now,timeZone,locale,frontmostApp}, call{tool,args}} →
///       + answer (the envelope bytes), rejection (null when every check passes)
///   finetune tools-export --in rows.jsonl --out-dir dir [--grammar tool-first]
///       rows that passed (+ split) → train.jsonl / valid.jsonl chat rows + export.json
///
/// Checks, in order: the case context parses; the call is schema-valid (`ToolCall
/// .validationIssues`); the deterministic pre-model screen (`ActionSafetyScreen
/// .unsupportedRequest`) agrees with the label; `VoiceToolGuard.review` leaves the call unchanged
/// (Shortcuts library = the labelled name + the eval's unrelated five); no positive call carries
/// what `SensitiveContentScreen` flags; every copied value is a verbatim span of the utterance;
/// every date phrase resolves with `DateAnchor` and every timer length with the eval's
/// `SpokenDuration`; the envelope renders in the grammar's key order, the compiled XGrammar
/// grammar accepts it, and `ToolCall(envelopeJSON:)` reads back the same call.
enum FinetuneTools {
    static let defaultGrammar = "tool-first"

    static func run(_ command: String, _ args: Arguments) throws {
        let grammar = args.string("grammar") ?? defaultGrammar
        guard ToolEnvelopeAnswer.trainableModes.contains(grammar) else {
            throw EvalError.missing("finetune \(command): --grammar must be one of \(ToolEnvelopeAnswer.trainableModes)")
        }
        switch command {
        case "tools-prompt": try printPrompt(grammar: grammar)
        case "tools-check": try check(args, grammar: grammar)
        case "tools-export": try export(args, grammar: grammar)
        default: throw EvalError.missing("usage: murmur-eval finetune tools-prompt|tools-check|tools-export")
        }
    }

    static var systemText: String {
        MLXLanguageModel.systemText(instructions: VoiceToolCatalog.instructions, schema: VoiceToolCatalog.envelopeSchema)
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func promptInfo(grammar: String) -> [String: Any] {
        [
            "promptVersion": VoiceToolCatalog.promptVersion, "catalog": VoiceToolCatalog.version, "grammar": grammar,
            "system": systemText, "systemSHA256": sha256(systemText),
            "userTemplate": VoiceToolCatalog.userPrompt(contextLine: "<contextLine>", utterance: "<utterance>"),
        ]
    }

    private static func printPrompt(grammar: String) throws {
        let data = try JSONSerialization.data(withJSONObject: promptInfo(grammar: grammar), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
    }

    // MARK: - check

    private static func check(_ args: Arguments, grammar: String) throws {
        let rows = try FinetuneJSONL.read(try FinetuneRunner.required(args, "in"))
        let scalars = Set(rows.flatMap { row in (FinetuneJSONL.string(row, "utterance") ?? "").unicodeScalars.filter { !$0.isASCII } })
        let checker = try ToolEnvelopeChecker(mode: grammar, extraScalars: scalars)
        var reasons: [String: Int] = [:]
        let checked = rows.map { row -> FinetuneJSONL.Row in
            var out = row
            switch verdict(row, grammar: grammar, checker: checker) {
            case .success(let answer):
                out["answer"] = answer
                out["rejection"] = NSNull()
                reasons["accepted", default: 0] += 1
            case .failure(let rejection):
                out["answer"] = NSNull()
                out["rejection"] = rejection.text
                reasons[rejection.text.components(separatedBy: ":").first ?? rejection.text, default: 0] += 1
            }
            return out
        }
        try FinetuneJSONL.write(checked, to: try FinetuneRunner.required(args, "out"))
        print("finetune tools-check (\(grammar)): \(checked.count) rows, \(reasons["accepted"] ?? 0) accepted")
        for (reason, count) in reasons.sorted(by: { $0.value > $1.value }) where reason != "accepted" {
            print("  rejected \(count): \(reason)")
        }
    }

    struct Rejection: Error {
        let text: String
        init(_ text: String) { self.text = text }
    }

    static func verdict(_ row: FinetuneJSONL.Row, grammar: String, checker: ToolEnvelopeChecker) -> Result<String, Rejection> {
        guard let utterance = FinetuneJSONL.string(row, "utterance"), !utterance.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .failure(Rejection("input: missing utterance"))
        }
        guard let context = decode(ToolEvalCase.Context.self, row["context"]), let now = context.nowDate, let zone = context.zone,
              ToolEvalCase.Context.locales.contains(context.locale)
        else { return .failure(Rejection("input: bad context")) }
        guard let call = decode(ToolCall.self, row["call"]) else { return .failure(Rejection("input: bad call")) }
        if let issue = call.validationIssues().first { return .failure(Rejection("schema: \(issue)")) }
        if ActionSafetyScreen.unsupportedRequest(in: utterance) != nil, call.noActionReason != .unsupported {
            return .failure(Rejection("prescreen: the runtime refuses this utterance as unsupported before the model"))
        }
        let names = call.tool == "run_shortcut" ? [call.arguments["name"].flatMap(stringValue) ?? ""] : []
        let reviewed = VoiceToolGuard.review(call, utterance: utterance, installedShortcuts: names + EvalShortcutLibrary.unrelated)
        if reviewed != call { return .failure(Rejection("guard: VoiceToolGuard turns it into \(reviewed.tool) \(reviewed.noActionReason?.rawValue ?? "")")) }
        if !call.isNoAction, SensitiveContentScreen.finding(in: utterance) != nil {
            return .failure(Rejection("sensitive: a positive call on text SensitiveContentScreen flags"))
        }
        let dates = DateContext(now: now, timeZone: zone, locale: Locale(identifier: context.locale))
        if let problem = argumentProblem(call, utterance: utterance, dates: dates) { return .failure(Rejection(problem)) }
        guard let answer = ToolEnvelopeAnswer.render(call, mode: grammar) else { return .failure(Rejection("render: value the envelope can't hold")) }
        guard checker.accepts(answer) else { return .failure(Rejection("grammar: the \(grammar) grammar rejects the answer")) }
        guard ToolCall(envelopeJSON: answer) == call else { return .failure(Rejection("roundtrip: ToolCall(envelopeJSON:) reads a different call")) }
        return .success(answer)
    }

    /// Grounding, dates and durations: nil when every argument is fine. Grounding is by word:
    /// every word of a copied value must be a word of the utterance, because a self-correction
    /// ("at 3 no 4 pm" → "at 4 pm", "call the dentist no the vet" → "call the vet") makes the
    /// right value a non-contiguous copy. What it forbids is an invented word.
    static func argumentProblem(_ call: ToolCall, utterance: String, dates: DateContext) -> String? {
        guard let spec = VoiceToolCatalog.tool(named: call.tool) else { return "schema: unknown tool" }
        let spoken = Set(EvalText.normalize(utterance).split(separator: " ").map(String.init))
        for (key, value) in call.arguments.sorted(by: { $0.key < $1.key }) {
            guard let kind = spec.parameter(named: key)?.kind else { continue }
            let texts: [String]
            switch (kind, value) {
            case (.enumeration, _), (.durationMinutes, _): continue
            case (_, .string(let text)): texts = [text]
            case (_, .strings(let items)): texts = items
            case (.duration, .integer): continue
            default: return "schema: \(key) has the wrong shape"
            }
            for text in texts {
                let words = EvalText.normalize(text).split(separator: " ").map(String.init)
                if words.isEmpty || !words.allSatisfy(spoken.contains) { return "ungrounded: \(key) has a word the utterance doesn't" }
            }
            if kind == .dateTime, let phrase = texts.first, DateAnchor.firstDate(in: phrase, context: dates) == nil {
                return "date: DateAnchor can't resolve the when phrase"
            }
            if kind == .duration, SpokenDuration.seconds(value) == nil {
                return "duration: SpokenDuration can't read the timer length"
            }
        }
        return nil
    }

    static func stringValue(_ value: ToolArgumentValue) -> String? {
        if case .string(let text) = value { return text }
        return nil
    }

    static func decode<T: Decodable>(_ type: T.Type, _ object: Any?) -> T? {
        guard let object, JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: - export

    private static func export(_ args: Arguments, grammar: String) throws {
        let rows = try FinetuneJSONL.read(try FinetuneRunner.required(args, "in"))
        let outDir = try FinetuneRunner.required(args, "out-dir")
        _ = try FinetunePathGuard.checked(outDir)
        let system = systemText
        var splits: [String: [FinetuneJSONL.Row]] = ["train": [], "valid": []]
        var skipped = 0
        for row in rows {
            guard let utterance = FinetuneJSONL.string(row, "utterance"),
                  let context = decode(ToolEvalCase.Context.self, row["context"]), let now = context.nowDate, let zone = context.zone,
                  let call = decode(ToolCall.self, row["call"]), let answer = ToolEnvelopeAnswer.render(call, mode: grammar),
                  answer == FinetuneJSONL.string(row, "answer")
            else {
                skipped += 1
                continue
            }
            let line = VoiceToolCatalog.contextLine(now: now, timeZone: zone, locale: context.locale, frontmostApp: context.frontmostApp)
            let split = row["split"] as? String == "valid" ? "valid" : "train"
            splits[split, default: []].append([
                "id": row["id"] as? String ?? "",
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": VoiceToolCatalog.userPrompt(contextLine: line, utterance: utterance)],
                    ["role": "assistant", "content": answer],
                ],
            ])
        }
        guard skipped == 0 else { throw EvalError.missing("finetune tools-export: \(skipped) rows lack a checked answer for --grammar \(grammar); run tools-check first") }
        var files: [String: [String: Any]] = [:]
        for (split, examples) in splits {
            let path = outDir + "/\(split).jsonl"
            try FinetuneJSONL.write(examples, to: path)
            files[split] = ["rows": examples.count, "sha256": try fileSHA256(path)]
        }
        var summary = promptInfo(grammar: grammar)
        summary["files"] = files
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: try FinetunePathGuard.checked(outDir + "/export.json"))
        print("finetune tools-export (\(grammar), \(VoiceToolCatalog.promptVersion)): train \(splits["train"]?.count ?? 0), valid \(splits["valid"]?.count ?? 0) → \(outDir)")
    }

    static func fileSHA256(_ path: String) throws -> String {
        let data = try Data(contentsOf: try FinetunePathGuard.checked(path))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
