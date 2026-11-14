import Foundation
import MurmurCore

/// `murmur-eval analyze --dataset <name> --engines v2,apple [--limit N] [--reuse <run.json>]`
///
/// Error-analysis for ASR: aligns each engine's hypothesis against the reference word-by-word
/// (Levenshtein alignment, not just distance) and classifies every substitution/insertion/deletion
/// into one of six buckets so a raw WER number can be broken into "is this actually a scoring
/// artefact, a name we mangled, a disfluency, or a genuine mishearing." Reuses cached hypotheses
/// from a prior `asr --report` JSON if `--reuse` points at one; otherwise runs the engines itself.
enum Analyze {
    struct CaseHypothesis: Codable {
        let id: String
        let reference: String
        let hypothesis: String
    }

    /// One classified error, covering a contiguous run of aligned ops (so "twenty three" -> "23"
    /// scores as one normalization error, not two substitutions).
    struct ClassifiedError {
        let category: ErrorCategory
        let id: String
        let reference: String
        let hypothesis: String
        let refSpan: String
        let hypSpan: String
    }

    enum ErrorCategory: String, CaseIterable {
        case normalization = "scoring/normalization artefact"
        case properNoun = "proper noun / name"
        case disfluency = "disfluency / repetition"
        case mishearing = "genuine mishearing"
        case deletion = "deletion / hallucinated segment"
        case referenceError = "reference error / wrong language"

        var shortName: String { rawValue }
    }

    static func run(_ args: Arguments) async throws {
        guard let datasetName = args.string("dataset") else {
            throw EvalError.missing("usage: murmur-eval analyze --dataset <name> --engines v2,apple [--limit N] [--reuse-v2 path.json] [--reuse-apple path.json]")
        }
        let engineNames = (args.string("engines") ?? "v2,apple").split(separator: ",").map(String.init)
        let limit = args.int("limit") ?? .max

        let clips = try loadClips(datasetName, limit: limit)
        print("### Error analysis · \(datasetName) · \(clips.count) clips · engines: \(engineNames.joined(separator: ", "))\n")

        for engineName in engineNames {
            let pairs = try await hypotheses(for: engineName, dataset: datasetName, clips: clips, args: args)
            let errors = classify(pairs)
            report(engineName: engineName, dataset: datasetName, pairs: pairs, errors: errors)
        }
    }

    // MARK: Hypothesis sourcing (reuse cached JSON, or run the engine)

    private static func loadClips(_ name: String, limit: Int) throws -> [EvalClip] {
        if let dataset = Dataset(rawValue: name) {
            return try Array(dataset.load(root: Paths.data)
                .filter { !$0.reference.trimmingCharacters(in: .whitespaces).isEmpty }
                .prefix(limit))
        }
        let manifestURL = Paths.data.appendingPathComponent(name, isDirectory: true).appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw EvalError.missing("Unknown dataset '\(name)' (no catalogue entry or local manifest.json)")
        }
        return try Array(JSONDecoder().decode([EvalClip].self, from: Data(contentsOf: manifestURL))
            .filter { !$0.reference.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(limit))
    }

    /// `--reuse-<engine> path.json` points at a `Evals/runs/.../analyze-cache-<engine>.json`
    /// (an array of `CaseHypothesis`) saved by a previous `analyze` run, so re-running the
    /// classifier (e.g. after a heuristic change) doesn't re-transcribe every clip.
    private static func hypotheses(
        for engineName: String, dataset: String, clips: [EvalClip], args: Arguments
    ) async throws -> [CaseHypothesis] {
        if let reusePath = args.string("reuse-\(engineName)") {
            let cached = try JSONDecoder().decode([CaseHypothesis].self, from: Data(contentsOf: URL(fileURLWithPath: reusePath)))
            let byID = Dictionary(uniqueKeysWithValues: cached.map { ($0.id, $0) })
            let matched = clips.compactMap { byID[$0.id] }
            guard matched.count == clips.count else {
                throw EvalError.missing("--reuse-\(engineName) is missing \(clips.count - matched.count) of \(clips.count) requested clips")
            }
            return matched
        }
        let recognizer: any Recognizer = switch engineName {
        case "v2": try await Engine.load(.v2)
        case "ultra": try await Engine.load(.ultra)
        // Matches Recognizers.make's naming exactly: "apple" is the transcriber preset (what
        // Evals/results.md's "apple-transcriber" rows and the README's "Apple" numbers use),
        // "apple-dictation" is the short-dictation preset. Kept consistent so --engines apple
        // reuses/compares against the same numbers as `asr --engine apple`.
        case "apple": try await AppleRecognizer.make(.transcriber)
        case "apple-dictation": try await AppleRecognizer.make(.dictation)
        default: throw EvalError.missing("Unknown engine '\(engineName)' (use v2, ultra, apple, apple-dictation)")
        }
        var results: [CaseHypothesis] = []
        results.reserveCapacity(clips.count)
        for clip in clips {
            let url = URL(fileURLWithPath: clip.audioPath)
            let (text, _) = try await recognizer.transcribe(file: url)
            results.append(CaseHypothesis(id: clip.id, reference: clip.reference, hypothesis: text))
        }
        // Cache hypotheses next to the run's other evidence so a later classifier-only re-run
        // (e.g. after tuning a heuristic) doesn't need to re-transcribe.
        if let cacheDir = args.string("cache-dir") {
            let url = URL(fileURLWithPath: cacheDir).appendingPathComponent("analyze-cache-\(engineName)-\(dataset).json")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(results).write(to: url, options: .atomic)
        }
        return results
    }

    // MARK: Alignment + classification

    /// Levenshtein alignment producing a sequence of ops, then groups adjacent non-`.match` ops
    /// into spans (so a multi-word substitution classifies as one error, not N).
    enum AlignOp {
        case match(String)
        case substitute(ref: String, hyp: String)
        case insert(String)
        case delete(String)
    }

    static func align(_ reference: [String], _ hypothesis: [String]) -> [AlignOp] {
        let n = reference.count, m = hypothesis.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { dp[i][0] = i }
        for j in 0...m { dp[0][j] = j }
        for i in 1...max(n, 1) where n > 0 {
            for j in 1...max(m, 1) where m > 0 {
                let cost = reference[i - 1] == hypothesis[j - 1] ? 0 : 1
                dp[i][j] = min(dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost)
            }
        }
        var ops: [AlignOp] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, reference[i - 1] == hypothesis[j - 1] {
                ops.append(.match(reference[i - 1])); i -= 1; j -= 1
            } else if i > 0, j > 0, dp[i][j] == dp[i - 1][j - 1] + 1 {
                ops.append(.substitute(ref: reference[i - 1], hyp: hypothesis[j - 1])); i -= 1; j -= 1
            } else if i > 0, dp[i][j] == dp[i - 1][j] + 1 {
                ops.append(.delete(reference[i - 1])); i -= 1
            } else {
                ops.append(.insert(hypothesis[j - 1])); j -= 1
            }
        }
        return ops.reversed()
    }

    /// Groups consecutive non-match ops into spans and classifies each span using heuristics,
    /// with priority: reference errors > normalization artefacts > proper nouns > disfluency >
    /// large deletions > genuine mishearing (the catch-all).
    static func classify(_ pairs: [CaseHypothesis]) -> [ClassifiedError] {
        var errors: [ClassifiedError] = []
        for pair in pairs {
            let ref = EvalMetrics.normalizedWords(pair.reference)
            let hyp = EvalMetrics.normalizedWords(pair.hypothesis)
            if looksNonEnglishOrCorrupt(pair.reference) {
                errors.append(ClassifiedError(
                    category: .referenceError, id: pair.id, reference: pair.reference, hypothesis: pair.hypothesis,
                    refSpan: pair.reference, hypSpan: pair.hypothesis))
                continue
            }
            let ops = align(ref, hyp)
            var index = 0
            while index < ops.count {
                guard !isMatch(ops[index]) else { index += 1; continue }
                var span = [ops[index]]
                var next = index + 1
                while next < ops.count, !isMatch(ops[next]) { span.append(ops[next]); next += 1 }
                let refSpan = span.compactMap(refWord).joined(separator: " ")
                let hypSpan = span.compactMap(hypWord).joined(separator: " ")
                let category = classifySpan(refSpan: refSpan, hypSpan: hypSpan, span: span)
                errors.append(ClassifiedError(
                    category: category, id: pair.id, reference: pair.reference, hypothesis: pair.hypothesis,
                    refSpan: refSpan, hypSpan: hypSpan))
                index = next
            }
        }
        return errors
    }

    private static func isMatch(_ op: AlignOp) -> Bool { if case .match = op { return true }; return false }
    private static func refWord(_ op: AlignOp) -> String? {
        switch op {
        case .match(let w): w
        case .substitute(let r, _): r
        case .delete(let w): w
        case .insert: nil
        }
    }
    private static func hypWord(_ op: AlignOp) -> String? {
        switch op {
        case .match(let w): w
        case .substitute(_, let h): h
        case .delete: nil
        case .insert(let w): w
        }
    }

    /// A reference transcript that is mostly non-Latin script, or empty after stripping bracketed
    /// annotations, indicates a mislabeled/wrong-language clip rather than a recognition error.
    private static func looksNonEnglishOrCorrupt(_ reference: String) -> Bool {
        let letters = reference.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        let nonLatin = letters.filter { $0.value > 0x02FF }.count
        return Double(nonLatin) / Double(letters.count) > 0.3
    }

    private static let fillerWords: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "ah", "hmm", "mm", "like", "okay", "ok"]
    private static let ukUSPairs: Set<String> = [
        "colour-color", "favourite-favorite", "theatre-theater", "centre-center", "organised-organized",
        "realised-realized", "recognised-recognized", "grey-gray", "programme-program", "travelling-traveling",
        "cancelled-canceled", "labour-labor", "honour-honor", "neighbour-neighbor",
    ]
    private static let symbolLiterals: Set<String> = ["%", "$", "&", "#", "@", "+"]

    private static func classifySpan(refSpan: String, hypSpan: String, span: [AlignOp]) -> ErrorCategory {
        let refWords = refSpan.split(separator: " ").map(String.init)
        let hypWords = hypSpan.split(separator: " ").map(String.init)

        // (a) Scoring/normalization artefacts: digits vs number words, contractions, hyphens,
        // UK/US spelling, "okay/ok", filler-only spans, or spans that normalize equal under the
        // ESB-style normalizer (meaning this "error" disappears once normalized).
        func debugLog(_ message: String) {
            if ProcessInfo.processInfo.environment["ANALYZE_DEBUG"] != nil {
                FileHandle.standardError.write(Data("  \(refSpan)/\(hypSpan): \(message)\n".utf8))
            }
        }
        if EvalTextNormalizer.normalizedWords(refSpan) == EvalTextNormalizer.normalizedWords(hypSpan), !refSpan.isEmpty {
            debugLog("check1 (normalizer equal)"); return .normalization
        }
        // Filler-only spans are a normalization artefact only on the *deletion/insertion* side
        // of a span that is itself short (≤2 words either side) — e.g. ref "uh" -> hyp "" or
        // ref "" -> hyp "um". A short filler standing in for a long deleted/misheard span (e.g.
        // 8 reference words replaced by a single "uh") is a genuine mishearing/deletion, not a
        // scoring artefact, so this must not fire when the *other* side carries real content.
        if !refWords.isEmpty, refWords.allSatisfy({ fillerWords.contains($0) }), hypWords.count <= 2 {
            debugLog("check2 (ref all filler)"); return .normalization
        }
        if !hypWords.isEmpty, hypWords.allSatisfy({ fillerWords.contains($0) }), refWords.count <= 2 {
            debugLog("check3 (hyp all filler)"); return .normalization
        }
        if refWords.count == 1, hypWords.count == 1,
           ukUSPairs.contains("\(refWords[0])-\(hypWords[0])") || ukUSPairs.contains("\(hypWords[0])-\(refWords[0])") {
            debugLog("check4 (uk/us)"); return .normalization
        }
        if isNumericPhrase(refSpan) || isNumericPhrase(hypSpan) {
            debugLog("check5 (numeric ref=\(isNumericPhrase(refSpan)) hyp=\(isNumericPhrase(hypSpan)))"); return .normalization
        }
        // Only a normalization artefact when the *reference* actually contains the symbol this
        // word spells out (e.g. ref "&" vs hyp "and") — otherwise a genuinely misheard "and"
        // (which happens to be a word on the symbol-expansion list) would be misclassified.
        if !refSpan.isEmpty, symbolLiterals.contains(where: { refSpan.contains($0) }) {
            debugLog("check6 (symbol literal)"); return .normalization
        }

        // (b) Proper nouns/names: reference word starts with a capital letter mid-sentence, or is
        // a short unusual token the hypothesis clearly mangled phonetically.
        if looksLikeName(refSpan) {
            return .properNoun
        }

        // (c) Disfluency/repetition: hypothesis repeats a word/phrase the reference has once, or
        // vice versa (stutter the ASR did or didn't catch).
        if isRepetition(refWords: refWords, hypWords: hypWords) {
            return .disfluency
        }

        // (e) Deletions of whole segments/hallucinations: a long deleted or inserted run (more
        // than 4 words with no matching side) rather than a word-level substitution.
        if hypWords.isEmpty, refWords.count > 4 {
            return .deletion
        }
        if refWords.isEmpty, hypWords.count > 4 {
            return .deletion
        }

        // (d) Everything else is a genuine mishearing: the model heard different words.
        return .mishearing
    }

    /// True when every word in the span is part of a number phrase. "and" alone is a linking
    /// word inside phrases like "one hundred and five", never numeric by itself, so it only
    /// counts when at least one other word in the span is a genuine number word/digit.
    private static func isNumericPhrase(_ text: String) -> Bool {
        let words = text.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return false }
        let numberWords: Set<String> = [
            "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
            "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
            "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
            "hundred", "thousand", "million", "billion",
        ]
        func isNumeric(_ word: String) -> Bool {
            numberWords.contains(word) || word.allSatisfy(\.isNumber) || (word.dropLast(2).allSatisfy(\.isNumber) && word.count > 2)
        }
        guard words.contains(where: isNumeric) else { return false }
        return words.allSatisfy { isNumeric($0) || $0 == "and" }
    }

    /// Capitalized in the original (pre-normalization) reference text and not sentence-initial —
    /// a cheap but effective proper-noun signal without a gazetteer.
    private static func looksLikeName(_ normalizedSpan: String) -> Bool {
        // normalizedSpan is already lowercased by EvalMetrics.normalizedWords upstream of this
        // call, so instead check length/shape heuristics: short, non-dictionary-looking tokens
        // that are common failure points for names (e.g. "kwame", "nguyen").
        let words = normalizedSpan.split(separator: " ").map(String.init)
        guard words.count <= 2, let word = words.first, word.count >= 3 else { return false }
        let commonWords: Set<String> = [
            "the", "a", "an", "and", "or", "but", "so", "to", "of", "in", "on", "at", "is", "was",
            "are", "were", "it", "that", "this", "he", "she", "they", "we", "you", "i", "not", "no",
        ]
        guard !commonWords.contains(word) else { return false }
        // Heuristic: consonant clusters or letter patterns uncommon in everyday English words
        // often indicate a name ASR mangled (e.g. "nguyen" -> "when", "kwame" -> "kwomi").
        let uncommonPatterns = ["ngu", "kw", "zh", "xi", "vy", "ky", "dh", "th'"]
        return uncommonPatterns.contains { word.contains($0) }
    }

    private static func isRepetition(refWords: [String], hypWords: [String]) -> Bool {
        guard !refWords.isEmpty || !hypWords.isEmpty else { return false }
        if hypWords.count >= 2, Set(hypWords).count == 1 { return true }
        if refWords.count >= 2, Set(refWords).count == 1 { return true }
        // "the the" -> "the": hypothesis or reference has an immediate word-repeat.
        if let first = hypWords.first, hypWords.count == 2, hypWords[1] == first { return true }
        if let first = refWords.first, refWords.count == 2, refWords[1] == first { return true }
        return false
    }

    // MARK: Reporting

    private static func report(engineName: String, dataset: String, pairs: [CaseHypothesis], errors: [ClassifiedError]) {
        let refWordCounts = pairs.reduce(0) { $0 + EvalMetrics.normalizedWords($1.reference).count }
        let totalWER = EvalMetrics.corpusWER(pairs.map { ($0.reference, $0.hypothesis) })
        print("## Engine: \(engineName)")
        print("- Overall WER (product normalizer): \(pct(totalWER))")
        print("- Reference words: \(refWordCounts), classified error spans: \(errors.count)\n")

        let byCategory = Dictionary(grouping: errors, by: \.category)
        print("| Category | Count | Share of errors |")
        print("|---|---:|---:|")
        for category in ErrorCategory.allCases {
            let count = byCategory[category]?.count ?? 0
            let share = errors.isEmpty ? 0 : Double(count) / Double(errors.count)
            print("| \(category.rawValue) | \(count) | \(pct(share)) |")
        }
        print("")

        for category in ErrorCategory.allCases {
            guard let items = byCategory[category], !items.isEmpty else { continue }
            print("### \(engineName) · \(category.rawValue) — \(items.count) example(s), showing up to 15\n")
            for item in items.prefix(15) {
                print("- [\(item.id)] ref: \"\(item.refSpan)\" -> hyp: \"\(item.hypSpan)\"")
            }
            print("")
        }
    }

    private static func pct(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
}

