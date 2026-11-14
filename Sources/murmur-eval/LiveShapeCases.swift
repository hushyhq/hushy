import Foundation
import HushyModelsApple
import MurmurCore

/// `murmur-eval live-shape --cases <file.jsonl> [--arm single|chain] [--path release|prewarmed|both] [--tone professional]`
///
/// Task 130 phase 1 (measurement only). A cases file has one JSON object per line:
/// `{"id", "spoken", "hedge_like": n, "legit_like": n, "doubled": n, "must_keep": ["names", "numbers", "dates", "negations"]}`.
/// Each case goes through the same settings the app builds (`LiveShapeRunner.settings`), and the output is scored without a
/// model and without reading meaning:
/// - `hedge_left`: "like"s in the output beyond the legitimate ones (`like` count − `legit_like`, never below 0).
/// - `legit_removed`: legitimate "like"s the output has fewer of than it should (`legit_like` − `like` count, never below 0).
///   Both are exact unless one offsets the other in the same text.
/// - `doubled_left`: adjacent repeated words in the output, at most `doubled`.
/// - `missing`: `must_keep` strings that are not in the output (case-insensitive, contractions read as their long form).
/// - `seams`: group seams (a piece of a run-on that was cleaned on its own) where the output has a sentence end right
///   before the first words of that piece.
/// - guard outcome per group, and the wait after release.
/// A per-case line prints ids and numbers only, never text, so a private file can be scored without being shown.
enum LiveShapeCases {
    struct Case: Decodable {
        let id: String
        let spoken: String
        let hedgeLike: Int
        let legitLike: Int
        let doubled: Int
        let mustKeep: [String]
        /// Pairs `[end of one phrase, start of the next]` that were one thought and must not have a sentence end between them.
        let joins: [[String]]
        /// Phrases after which the speaker trailed off and began a new sentence: the output should show an ellipsis there.
        let trails: [String]
        /// Short clauses a rising voice can make a question: a model's "?" after one is kept, not demoted.
        let questions: [String]
        /// Labels (a letter or digit after a noun, "plan b") that must survive as written, counted under the identifier class.
        let identifiers: [String]
        /// Cut-off word starts the speaker really stuttered ("m make"): the phrase should be gone from the output.
        let fragments: [String]
        /// Statement clauses that must not end with a question mark.
        let notQuestions: [String]
        /// The text the speaker meant (a public disfluency set's original). When present the run also reports, over all cases,
        /// how many outputs equal it after lowercasing and stripping punctuation, and the corpus word error rate against it.
        let reference: String?
        enum CodingKeys: String, CodingKey {
            case id, spoken, doubled, joins, trails, questions, identifiers, fragments, reference
            case notQuestions = "not_questions"
            case hedgeLike = "hedge_like", legitLike = "legit_like", mustKeep = "must_keep"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            spoken = try c.decode(String.self, forKey: .spoken)
            hedgeLike = try c.decode(Int.self, forKey: .hedgeLike)
            legitLike = try c.decode(Int.self, forKey: .legitLike)
            doubled = try c.decode(Int.self, forKey: .doubled)
            mustKeep = try c.decode([String].self, forKey: .mustKeep)
            joins = try c.decodeIfPresent([[String]].self, forKey: .joins) ?? []
            trails = try c.decodeIfPresent([String].self, forKey: .trails) ?? []
            questions = try c.decodeIfPresent([String].self, forKey: .questions) ?? []
            identifiers = try c.decodeIfPresent([String].self, forKey: .identifiers) ?? []
            fragments = try c.decodeIfPresent([String].self, forKey: .fragments) ?? []
            notQuestions = try c.decodeIfPresent([String].self, forKey: .notQuestions) ?? []
            reference = try c.decodeIfPresent(String.self, forKey: .reference)
        }
    }

    struct Score {
        var hedgeLeft = 0, legitRemoved = 0, doubledLeft = 0, missing = 0, seams = 0, joinsBroken = 0, joinsIn = 0
        var identifiersIn = 0, identifiersMissing = 0, fragmentsIn = 0, fragmentsLeft = 0
        var triggersOld = 0, triggersNew = 0, groupsOut = 0
        var questionsIn = 0, questionsKept = 0, notQuestionsIn = 0, notQuestionsWrong = 0
        var tripped = 0, fellNothingToKeep = 0, nothingToKeepAny = 0, spanRescued = 0, askRescued = 0, fellBack = 0, askedMs = 0
        var mixedLeft = 0, mixedIn = 0, trailsMissing = 0, trailsIn = 0, contractionsLeft = 0, contractionsIn = 0
        var outcomes: [String: Int] = [:]
        /// What came of asking again, for groups where a check threw the answer away or asking again passed.
        var askCategories: [String: Int] = [:]
        var waitSeconds = 0.0
        var hedgeIn = 0, legitIn = 0, doubledIn = 0, mustIn = 0
    }

    static func load(_ path: String) throws -> [Case] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let decoder = JSONDecoder()
        return try text.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try decoder.decode(Case.self, from: Data($0.utf8)) }
    }

    /// Lowercase, straight apostrophes, contractions as their long form, punctuation as spaces.
    static func normalised(_ text: String) -> String {
        var t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        for (short, long) in [("won't", "will not"), ("can't", "cannot"), ("n't", " not"), ("'ll", " will"), ("'m", " am"), ("'re", " are"), ("'ve", " have")] {
            t = t.replacingOccurrences(of: short, with: long)
        }
        let kept = t.map { $0.isLetter || $0.isNumber ? $0 : " " }
        return " " + kept.split(separator: " ").joined(separator: " ") + " "
    }

    static func score(_ item: Case, output: String, groupTexts: [String], outcomes: [String]) -> Score {
        var s = Score()
        let likes = LiveShapeRunner.likes(output)
        s.hedgeLeft = max(0, likes - item.legitLike)
        s.legitRemoved = max(0, item.legitLike - likes)
        s.doubledLeft = min(item.doubled, LiveShapeRunner.doubled(output))
        let flat = normalised(output)
        s.missing = item.mustKeep.filter { !flat.contains(normalised($0)) }.count
        for group in groupTexts.dropFirst() {
            let first = LiveShapeRunner.words(group).prefix(2).map { NSRegularExpression.escapedPattern(for: $0) }
            guard first.count == 2 else { continue }
            let pattern = "[.?!][\"')\\]]*\\s+" + first.joined(separator: "[^a-zA-Z0-9']+")
            if output.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil { s.seams += 1 }
        }
        for pair in item.joins where pair.count == 2 {
            s.joinsIn += 1
            let tail = LiveShapeRunner.words(pair[0]).suffix(2).map { NSRegularExpression.escapedPattern(for: $0) }
            let head = LiveShapeRunner.words(pair[1]).prefix(2).map { NSRegularExpression.escapedPattern(for: $0) }
            guard !tail.isEmpty, !head.isEmpty else { continue }
            let pattern = tail.joined(separator: "[^a-zA-Z0-9']+") + "[\\s]*[.?!]+[\"')\\]]*\\s+" + head.joined(separator: "[^a-zA-Z0-9']+")
            if output.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil { s.joinsBroken += 1 }
        }
        s.mixedIn = mixedNumeralPhrases(item.spoken)
        s.mixedLeft = mixedNumeralPhrases(output)
        for tail in item.trails {
            s.trailsIn += 1
            let words = LiveShapeRunner.words(tail).suffix(3).map { NSRegularExpression.escapedPattern(for: $0) }
            guard !words.isEmpty else { continue }
            let pattern = words.joined(separator: "[^a-zA-Z0-9']+") + "[\\s,]*(\u{2026}|\\.\\.\\.)"
            if output.range(of: pattern, options: [.regularExpression, .caseInsensitive]) == nil { s.trailsMissing += 1 }
        }
        func followedBy(_ mark: String, _ phrase: String) -> Bool {
            let words = LiveShapeRunner.words(phrase).suffix(3).map { NSRegularExpression.escapedPattern(for: $0) }
            guard !words.isEmpty else { return false }
            let pattern = words.joined(separator: "[^a-zA-Z0-9']+") + "[\\s\"')]*" + NSRegularExpression.escapedPattern(for: mark)
            return output.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        let lowerOutput = output.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        func hasPhrase(_ phrase: String) -> Bool {
            let words = LiveShapeRunner.words(phrase).map { NSRegularExpression.escapedPattern(for: $0) }
            guard !words.isEmpty else { return false }
            let pattern = "(?<![a-z0-9'])" + words.joined(separator: "[^a-z0-9']+") + "(?![a-z0-9'])"
            return lowerOutput.range(of: pattern, options: .regularExpression) != nil
        }
        for phrase in item.identifiers { s.identifiersIn += 1; if !hasPhrase(phrase) { s.identifiersMissing += 1 } }
        for phrase in item.fragments { s.fragmentsIn += 1; if hasPhrase(phrase) { s.fragmentsLeft += 1 } }
        for phrase in item.questions { s.questionsIn += 1; if followedBy("?", phrase) { s.questionsKept += 1 } }
        for phrase in item.notQuestions { s.notQuestionsIn += 1; if followedBy("?", phrase) { s.notQuestionsWrong += 1 } }
        // How many of the groups the first pass left would be sent to the second model, before and after the trigger
        // read the shared marker vocabulary.
        for group in TextSegmentation.groups(output) {
            s.groupsOut += 1
            if SmartCleaner.hasLeftoverFiller(group.text, includingMarkers: false) { s.triggersOld += 1 }
            if SmartCleaner.hasLeftoverFiller(group.text) { s.triggersNew += 1 }
        }
        s.contractionsIn = avoidableContractions(item.spoken)
        s.contractionsLeft = avoidableContractions(output)
        for code in outcomes { s.outcomes[code, default: 0] += 1 }
        s.hedgeIn = item.hedgeLike; s.legitIn = item.legitLike; s.doubledIn = item.doubled; s.mustIn = item.mustKeep.count
        return s
    }

    private static let numberWords: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen",
        "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty",
        "sixty", "seventy", "eighty", "ninety", "hundred", "thousand",
    ]

    /// Phrases where a number word and a digit sit next to each other in one range or quantity: "3 or four weeks",
    /// "five to 10 people", "twenty 5". Counted from the text alone.
    static func mixedNumeralPhrases(_ text: String) -> Int {
        let tokens = LiveShapeRunner.words(text)
        let joiners: Set<String> = ["or", "to", "and", "through", "by"]
        func kind(_ token: String) -> Int { token.allSatisfy(\.isNumber) ? 1 : (numberWords.contains(token) ? 2 : 0) }
        var count = 0
        var index = 0
        while index < tokens.count {
            let first = kind(tokens[index])
            guard first != 0 else { index += 1; continue }
            var next = index + 1
            if next < tokens.count, joiners.contains(tokens[next]) { next += 1 }
            if next < tokens.count, kind(tokens[next]) != 0, kind(tokens[next]) != first { count += 1; index = next + 1 } else { index = next }
        }
        return count
    }

    /// Contractions the Professional register would spell out, left in `text`: every apostrophe form except the
    /// ones kept on purpose (`'s`, `'d`, "let's"), which are ambiguous between two readings.
    static func avoidableContractions(_ text: String) -> Int {
        LiveShapeRunner.words(text.replacingOccurrences(of: "\u{2019}", with: "'")).filter { word in
            guard word.contains("'") else { return false }
            if word.hasSuffix("'s") || word.hasSuffix("'d") || word == "let's" || word.hasSuffix("s'") { return false }
            return word.hasSuffix("n't") || word.hasSuffix("'m") || word.hasSuffix("'re") || word.hasSuffix("'ll") || word.hasSuffix("'ve")
        }.count
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    /// One case through one arm and one path. `chain` is arm C: the first model cleans, and the second model is
    /// asked only about sentences that still hold a "like".
    static func clean(
        _ spoken: String, base: PipelineSettings, tone: DictationTone, prewarm: Bool, primary: SmartCleaner, second: SmartCleaner?,
        strategy: SmartCleaner.Strategy? = nil
    ) async -> (text: String, groups: [GroupTrace], wait: Double) {
        let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: primary)
        var settings = base
        let groups = TextSegmentation.groups(spoken)
        if prewarm, groups.count > 1 {
            for group in groups where !group.isTail {
                await primary.prewarmGroup(group.text, options: settings.cleanupOptions, continuesSentence: group.continuesSentence,
                    previousRaw: group.index > 0 ? groups[group.index - 1].text : nil)
            }
        }
        let started = ContinuousClock.now
        guard let second else {
            let result = await pipeline.clean(spoken, settings: settings, strategy: strategy, released: started)
            return (result.text, result.groups, ModelPace.ms(ContinuousClock.now - started) / 1000)
        }
        // Arm C: the tone and layout come last, after the second model has looked at what still holds a "like".
        let layout = settings.style
        settings.tone = nil
        settings.style = nil
        let first = await pipeline.clean(spoken, settings: settings, released: started)
        let secondPipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: second)
        var pieces: [String] = []
        var traces = first.groups
        for sentence in sentences(first.text) {
            if LiveShapeRunner.likes(sentence) > 0 {
                let again = await secondPipeline.clean(sentence, settings: settings, released: ContinuousClock.now)
                pieces.append(again.text)
                traces += again.groups
            } else {
                pieces.append(sentence)
            }
        }
        var text = pieces.joined(separator: " ")
        if let layout { text = ToneRegister.apply(base.tone ?? tone, layout: layout.style, to: text, in: layout.context) }
        return (text, traces, ModelPace.ms(ContinuousClock.now - started) / 1000)
    }

    /// Sentences of already cleaned text, each keeping its end mark.
    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let chars = Array(text)
        for (index, char) in chars.enumerated() {
            current.append(char)
            let next = index + 1 < chars.count ? chars[index + 1] : " "
            if ".?!".contains(char), next == " " { result.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { result.append(current.trimmingCharacters(in: .whitespaces)) }
        return result
    }

    static func run(_ args: Arguments, casesPath: String) async throws {
        let cases = try load(casesPath)
        let tone = DictationTone(rawValue: args.string("tone") ?? "professional") ?? .professional
        let bundle = args.string("bundle") ?? "com.anthropic.claudefordesktop"
        let (base, _) = LiveShapeRunner.settings(tone: tone, bundleID: bundle)
        let arm = args.string("arm") ?? "single"
        let paths: [String]
        switch args.string("path") ?? "both" {
        case "release": paths = ["release"]
        case "prewarmed": paths = ["prewarmed"]
        case "rules": paths = ["rules"]
        default: paths = ["release", "prewarmed"]
        }
        print("### Live shape cases · \(cases.count) cases · arm \(arm) · tone \(tone.rawValue) · level \(base.cleanupOptions.level.rawValue)")
        print("| id | path | hedge_left/in | legit_removed/in | doubled_left/in | missing/in | seams | joins_broken/in | mixed_left/in | trails_missing/in | contractions_left/in | groups | wait |")
        print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        var perPath: [String: [Score]] = [:]
        var referencePairs: [String: [(reference: String, hypothesis: String, spoken: String)]] = [:]
        for item in cases {
            for path in paths {
                let primary = args.makeCleaner(retainsRejectedCandidates: args.flag("show-rejected"))
                let second: SmartCleaner? = arm == "chain" ? SmartCleaner(model: AppleFoundationModel()) : nil
                let (text, traces, wait) = await clean(
                    item.spoken, base: base, tone: tone, prewarm: path == "prewarmed", primary: primary, second: second,
                    strategy: path == "rules" ? .rules : nil)
                let groupTexts = TextSegmentation.groups(item.spoken).map(\.text)
                let codes = traces.map { "\($0.outcome.rawValue)\($0.guardCode.map { "/\($0.rawValue)" } ?? "")" }
                var s = score(item, output: text, groupTexts: groupTexts, outcomes: codes)
                s.waitSeconds = wait
                for t in traces {
                    s.spanRescued += t.repairedSpans > 0 ? 1 : 0
                    s.fellNothingToKeep += t.outcome == .rejectedByGuard && t.repairHadNothingToKeep ? 1 : 0
                    s.nothingToKeepAny += t.repairHadNothingToKeep ? 1 : 0
                    s.askRescued += t.askedAgain == .passed ? 1 : 0
                    s.fellBack += t.outcome == .rejectedByGuard ? 1 : 0
                    if t.outcome == .rejectedByGuard || t.askedAgain == .passed { s.askCategories[t.askedAgain.rawValue, default: 0] += 1 }
                    s.askedMs += t.retryMs ?? 0
                }
                s.tripped = s.spanRescued + s.askRescued + s.fellBack
                perPath[path, default: []].append(s)
                if let reference = item.reference { referencePairs[path, default: []].append((reference, text, item.spoken)) }
                let outcomeText = s.outcomes.sorted { $0.key < $1.key }.map { "\($0.value)×\($0.key)" }.joined(separator: " ")
                print("| \(item.id) | \(path) | \(s.hedgeLeft)/\(s.hedgeIn) | \(s.legitRemoved)/\(s.legitIn) | \(s.doubledLeft)/\(s.doubledIn) | \(s.missing)/\(s.mustIn) | \(s.seams) | \(s.joinsBroken)/\(s.joinsIn) | \(s.mixedLeft)/\(s.mixedIn) | \(s.trailsMissing)/\(s.trailsIn) | \(s.contractionsLeft)/\(s.contractionsIn) | \(outcomeText) | \(String(format: "%.1f", wait)) s |")
                if args.flag("text") { print("    \(text)") }
                let ranSecond = traces.filter { $0.secondPass != .none }
                if !ranSecond.isEmpty {
                    let used = ranSecond.filter { $0.secondPass == .used }.count
                    let widened = ranSecond.filter(\.secondPassOnlyBecauseWidened).count
                    print("    second pass ran on \(ranSecond.count) group(s): \(used) changed the text, \(ranSecond.count - used) kept the first pass; \(widened) ran only because the trigger was widened")
                }
                if args.flag("show-rejected") {
                    for t in traces { if let candidate = t.rejectedCandidate { print("    rejected(\(t.label), asked again: \(t.askedAgain.rawValue)): \(candidate)") } }
                }
            }
        }
        for path in paths {
            if let pairs = referencePairs[path] {
                func plain(_ text: String) -> String {
                    text.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace }.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                }
                let exact = pairs.filter { plain($0.reference) == plain($0.hypothesis) }.count
                let spokenExact = pairs.filter { plain($0.reference) == plain($0.spoken) }.count
                let wer = EvalMetrics.corpusWER(pairs.map { ($0.reference, $0.hypothesis) })
                let spokenWER = EvalMetrics.corpusWER(pairs.map { ($0.reference, $0.spoken) })
                print("\n**reference check · \(path)** — \(pairs.count) cases; output equals the reference after lowercasing and stripping punctuation: \(exact) (the spoken text itself: \(spokenExact)); corpus word error rate against the reference: \(String(format: "%.4f", wer)) (the spoken text itself: \(String(format: "%.4f", spokenWER)))")
            }
            guard let scores = perPath[path] else { continue }
            func sum(_ key: KeyPath<Score, Int>) -> Int { scores.reduce(0) { $0 + $1[keyPath: key] } }
            let waits = scores.map(\.waitSeconds)
            var outcomes: [String: Int] = [:]
            for s in scores { for (k, v) in s.outcomes { outcomes[k, default: 0] += v } }
            var asked: [String: Int] = [:]
            for s in scores { for (k, v) in s.askCategories { asked[k, default: 0] += v } }
            let askedText = AskedAgain.allCases.map { "\($0.rawValue) \(asked[$0.rawValue, default: 0])" }.joined(separator: ", ")
            print("""

            **\(arm) · \(path)** — hedge likes left \(sum(\.hedgeLeft)) of \(sum(\.hedgeIn)); legit likes removed \(sum(\.legitRemoved)) of \(sum(\.legitIn)); \
            doubled words left \(sum(\.doubledLeft)) of \(sum(\.doubledIn)); must-keep missing \(sum(\.missing)) of \(sum(\.mustIn)); \
            seam breaks \(sum(\.seams)); joins broken \(sum(\.joinsBroken)) of \(sum(\.joinsIn)); mixed numerals left \(sum(\.mixedLeft)) of \(sum(\.mixedIn)); trail-offs without an ellipsis \(sum(\.trailsMissing)) of \(sum(\.trailsIn)); avoidable contractions left \(sum(\.contractionsLeft)) of \(sum(\.contractionsIn)); identifiers lost \(sum(\.identifiersMissing)) of \(sum(\.identifiersIn)); real stutter fragments left \(sum(\.fragmentsLeft)) of \(sum(\.fragmentsIn)); second-pass trigger on \(sum(\.triggersOld)) of \(sum(\.groupsOut)) groups before, \(sum(\.triggersNew)) after; possible questions ending in a question mark \(sum(\.questionsKept)) of \(sum(\.questionsIn)) (only above 0 if the model wrote the mark; the keep rule is pinned by unit tests); statements ending in a question mark \(sum(\.notQuestionsWrong)) of \(sum(\.notQuestionsIn)) (should be 0); wait after release p50 \(String(format: "%.1f", percentile(waits, 0.5))) s, p95 \(String(format: "%.1f", percentile(waits, 0.95))) s; \
            checks tripped on \(sum(\.tripped)) groups: kept the model's text with the span put back \(sum(\.spanRescued)), rescued by asking again \(sum(\.askRescued)), fell back to plain text \(sum(\.fellBack)) (of those, \(sum(\.fellNothingToKeep)) had nothing of the model's to keep: every change it made was the one a check objected to); span repair found nothing of the model's to keep on \(sum(\.nothingToKeepAny)) groups in all, whatever became of them; time of the second ask itself, summed over the groups asked again, \(sum(\.askedMs)) ms
            groups: \(outcomes.sorted { $0.key < $1.key }.map { "\($0.value)×\($0.key)" }.joined(separator: ", "))
            asking again, for groups a check threw away or that asking again saved: \(askedText)
            """)
        }
    }
}
