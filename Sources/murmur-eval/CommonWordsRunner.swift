import Foundation
import MurmurCore

/// `murmur-eval common-words [--cases Evals/screen-common-words.jsonl] [--text] [--report path]`
///
/// Traces ordinary-word loss through release/boost replay, draft reconciliation, fixers and rules cleanup.
/// Optional protectionCandidate replays a proposed correction through ProtectedTermGuard; it is not model inference.
enum CommonWordsRunner {
    struct Case: Decodable {
        let id: String
        let context: String
        let draft: String
        let base: String
        let boosted: String?
        let expected: String
        let installedApps: [String]?
        let frontmostApp: String?
        /// Replay of a proposed cleanup correction, not a model inference.
        let protectionCandidate: String?
        enum CodingKeys: String, CodingKey {
            case id, context, draft, base, boosted, expected, installedApps, frontmostApp, protectionCandidate
        }
    }

    enum Stage: String, Sendable {
        case boost = "boost"
        case draftGuard = "draft_guard"
        case fixer = "fixer"
        case cleanup = "cleanup"
        case protection = "protected_terms"
    }

    static func run(_ args: Arguments) async throws {
        let path = args.string("cases") ?? "Evals/screen-common-words.jsonl"
        let file = path.hasPrefix("/") ? path : Paths.root.appendingPathComponent(path).path
        let cases = try load(file)
        guard !cases.isEmpty else { throw EvalError.missing("common-words needs cases") }
        let level = CleanupLevel(rawValue: args.string("level") ?? "polished") ?? .polished
        let pipeline = DictationPipeline(transcriber: NullTranscriber())

        var stageFailures: [Stage: Int] = [:]
        var exact = 0
        var installedTerms = Set<String>()
        print("### Common words · \(cases.count) cases · level \(level.rawValue)")

        for item in cases {
            let extracted = ContextTermTrace.extractedTerms(from: item.context)
            let settings = PipelineSettings(
                cleanupOptions: CleanupOptions(level: level),
                contextTerms: extracted,
                installedApps: (item.installedApps ?? []).map { InstalledAppInfo(bundleID: "test.\($0)", name: $0) },
                frontmostBundleID: item.frontmostApp.map { "test.\($0)" })
            let vocabulary = settings.vocabulary
            installedTerms.formUnion(vocabulary.terms.filter(\.installedApp).map(\.text))
            // The recorded boosted reading happens only when a term it introduces is still in this dictation's vocabulary.
            let boosted = boostApplies(base: item.base, boosted: item.boosted, vocabulary: vocabulary) ? item.boosted! : item.base
            let afterBoost = vocabulary.guarded(original: item.base, boosted: boosted)
            let guarded = DraftCommonWordGuard.reconcile(draft: item.draft, release: afterBoost, vocabulary: vocabulary, installedApps: settings.installedApps)
            let afterFix = DictionaryTermFixer.fixNames(
                ContextSpellingFixer.fix(ScreenIdentifierJoiner.join(guarded.text, terms: extracted), terms: extracted), settings: settings)
            var cleanupInput = afterFix
            if let candidate = item.protectionCandidate {
                // Same installed terms cleanerInputs supplies; exercise the guard separately from model quality.
                let terms = vocabulary.terms.filter(\.installedApp).map(\.text)
                if ProtectedTermGuard.violation(answer: candidate, draft: afterFix, terms: terms) == nil {
                    cleanupInput = candidate
                } else {
                    stageFailures[.protection, default: 0] += 1
                }
            }
            let finalText = (await pipeline.clean(cleanupInput, settings: settings, strategy: .rules)).text

            let stages = failingStages(
                item: item, afterBoost: afterBoost, guarded: guarded.text, afterFix: afterFix, final: finalText)
            for stage in stages { stageFailures[stage, default: 0] += 1 }
            if normalized(finalText) == normalized(item.expected) { exact += 1 }
            if !stages.isEmpty { print("- \(item.id) loss: \(stages.map { $0.rawValue }.joined(separator: ","))") }
        }

        print("\n| stage | failures |")
        print("|---|---|")
        for stage in [Stage.boost, .draftGuard, .fixer, .protection, .cleanup] {
            print("| \(stage.rawValue) | \(stageFailures[stage, default: 0]) |")
        }
        print("| installed terms admitted | \(installedTerms.count) |")
        print("| exact | \(exact)/\(cases.count) |")
        if let report = args.string("report") {
            let payload: [String: Any] = [
                "exact": exact, "cases": cases.count, "installedTermsAdmitted": installedTerms.count,
                "stages": Dictionary(uniqueKeysWithValues: [Stage.boost, .draftGuard, .fixer, .protection, .cleanup]
                    .map { ($0.rawValue, stageFailures[$0, default: 0]) }),
            ]
            let url = URL(fileURLWithPath: report)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                .write(to: url, options: .atomic)
        }
    }

    private static func failingStages(
        item: Case, afterBoost: String, guarded: String, afterFix: String, final: String
    ) -> [Stage] {
        var stages: [Stage] = []
        let expect = normalized(item.expected)
        if normalized(afterBoost) != expect, commonWordLost(item.draft, in: afterBoost) { stages.append(.boost) }
        if normalized(guarded) != expect, guarded != afterBoost, commonWordLost(item.draft, in: guarded) {
            stages.append(.draftGuard)
        }
        if normalized(afterFix) != expect, commonWordLost(item.draft, in: afterFix) { stages.append(.fixer) }
        if normalized(final) != expect { stages.append(.cleanup) }
        return stages
    }

    private static func commonWordLost(_ reference: String, in output: String) -> Bool {
        let ref = reference.split(whereSeparator: \.isWhitespace).map(String.init)
        let out = output.split(whereSeparator: \.isWhitespace).map(String.init)
        guard ref.count == out.count else { return true }
        return zip(ref, out).contains { heard, delivered in
            heard != delivered && LearningLexicon.isCommonWord(heard.lowercased())
        }
    }

    private static func boostApplies(base: String, boosted: String?, vocabulary: VocabularyContext) -> Bool {
        guard let boosted else { return false }
        let baseWords = Set(normalized(base).split(separator: " ").map(String.init))
        let introduced = normalized(boosted).split(separator: " ").map(String.init).filter { !baseWords.contains($0) }
        let terms = Set(vocabulary.terms.flatMap { [$0.text] + $0.aliases }.map { normalized($0) })
        return introduced.contains { word in terms.contains { $0 == word || $0.hasPrefix(word) || word.hasPrefix($0) } }
    }

    /// Case, spacing and edge punctuation do not count; cleanup adds a capital and a full stop.
    private static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func load(_ path: String) throws -> [Case] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return try text.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try JSONDecoder().decode(Case.self, from: Data($0.utf8)) }
    }
}
