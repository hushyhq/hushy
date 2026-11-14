import Foundation

/// Summarizes a note transcript — a voice note or an hour-long meeting — into a title, key
/// points, decisions and action items, on whatever `LanguageModel` is current.
///
/// Two strategies (see `.claude/DECISIONS.md`, "Meeting digests"):
/// - **Single pass** — the whole transcript in one call. `.auto` uses it only for a transcript
///   that fits one piece: measured on long meetings, one call over the whole transcript misses
///   late items even when the window is large (Qwen3.5-4B: 62% vs 79% last-quartile recall).
/// - **Map-reduce** — pieces sized to the window (`pieceWords(contextTokens:)`: 1,500 words for
///   Apple FM's 4,096 tokens, 3,000 for a long-context model): *map* each overlapping piece (`TranscriptChunker`) to its decisions, action
///   items (owner, task, due), changes to earlier items, and key points; *reduce* all pieces'
///   notes in meeting order into the final digest, applying later changes ("instead", "scratch
///   that") to earlier items. The merge keeps every numbered action item unless it drops one with
///   evidence. A failed call is retried once with sampling; a piece that still fails is
///   summarized extractively; a merge that still fails falls back to `NoteDigestMerge.merge`.
///   Notes too long for one merge call are merged in halves first.
///
/// If a single-pass call fails under `.auto`, it runs map-reduce.
public enum NoteSummarizer {
    public enum Strategy: String, Sendable, CaseIterable {
        case auto
        case mapReduce = "map-reduce"
        case singlePass = "single-pass"
    }

    public struct Configuration: Sendable {
        public var strategy: Strategy = .auto
        /// Transcript words per map call; nil = `pieceWords(contextTokens:)` for the model.
        public var chunkWords: Int?
        public var overlapWords = 100
        /// Words of piece notes one merge call takes before merging in halves.
        public var mergeWords = 1_300
        /// Per call; a call that runs out is treated like any other failed call. Normal calls take
        /// 5–30 s; Apple FM occasionally loops until its context is full (measured: ~180 s on one
        /// meeting piece), and this caps that.
        public var callBudget: Duration = .seconds(60)
        /// For the whole summary, the most time it gives way to dictations on the shared 4B (`MeetingLanguageModel`):
        /// waiting for a quiet spell, and attempts a dictation cut short. When it runs out the run stops calling the 4B
        /// and the summary runs again on Apple FM, so a person who never pauses gets one at most this much later, plus
        /// Apple FM's own time. It never cuts a call no dictation interrupted: that call has `callBudget`, whatever is
        /// left of this.
        public var dictationYieldLimit: Duration = .seconds(60)
        /// Eval-only inspection hook: receives the merge input (piece notes). Nil in the app;
        /// transcript-derived text is never logged.
        public var trace: (@Sendable (String) -> Void)?

        public init() {}
    }

    /// What happened, for eval reports and logs (never text).
    public struct Report: Sendable, Equatable {
        public var strategy: Strategy = .auto
        public var calls = 0
        public var pieces = 0
        public var retries = 0
        /// Pieces summarized extractively after two failed calls.
        public var extractivePieces = 0
        /// The merge fell back to `NoteDigestMerge.merge` (deterministic).
        public var deterministicMerge = false
        public var singlePassFellBack = false
        /// The model produced nothing usable; the note got the extractive summary.
        public var extractiveOnly = false
        /// The meeting model (local 4B) left the digest degraded, so the whole summary ran again on Apple FM.
        public var reranOnApple = false
        /// A call gave way to dictations for `dictationYieldLimit`; the rest of the run made no model calls.
        public var gaveWayToDictation = false
        /// A model call was made and part of the digest still came from the extractive or deterministic path.
        var isDegraded: Bool { calls > 0 && (extractivePieces > 0 || deterministicMerge || extractiveOnly) }
        /// Why each failed call failed, in order.
        public var failures: [ModelCallFailure] = []
    }

    struct SummaryCallTimeout: Error {}

    /// Words of transcript per map call for a model's window. 1,500 words ≈ 2,100 tokens leaves
    /// Apple's 4,096-token window room for the instructions, schema and answer. A larger window
    /// gets 3,000-word pieces — not more: on Qwen3.5-4B, 3,000-word pieces had the best
    /// precision/recall/latency balance and bigger ones (single pass) lost late items.
    public static func pieceWords(contextTokens: Int) -> Int {
        contextTokens >= 8_192 ? 3_000 : 1_500
    }

    public static func summarize(
        _ transcript: String, fallbackTitle: String, model: any LanguageModel = LanguageModels.meeting,
        configuration: Configuration = Configuration()
    ) async -> (output: ExtractiveSummarizer.Output, report: Report) {
        let first = await summarizeOnce(transcript, fallbackTitle: fallbackTitle, model: model, configuration: configuration)
        // The 4B left something extractive: summarise again on Apple FM, which chunks to its own window.
        guard first.report.isDegraded, let apple = (model as? MeetingLanguageModel)?.appleFallback, apple.isAvailable,
              !Task.isCancelled else { return first }
        var second = await summarizeOnce(transcript, fallbackTitle: fallbackTitle, model: apple, configuration: configuration)
        // Keep the first digest when Apple FM did no better; either way say that a second run happened.
        guard !second.report.extractiveOnly || first.report.extractiveOnly else { return first }
        second.report.reranOnApple = true
        second.report.calls += first.report.calls
        return second
    }

    private static func summarizeOnce(
        _ transcript: String, fallbackTitle: String, model: any LanguageModel, configuration: Configuration
    ) async -> (output: ExtractiveSummarizer.Output, report: Report) {
        let fallback = ExtractiveSummarizer.summarize(transcript, fallbackTitle: fallbackTitle)
        let words = TextStats.wordCount(transcript)
        var run = Run(model: model, configuration: configuration)
        guard model.isAvailable, words >= ExtractiveSummarizer.minimumWordsToSummarize else {
            run.report.extractiveOnly = true
            return (fallback, run.report)
        }
        run.names = SpeakerNameInference.names(in: transcript)
        let digest = await run.digest(transcript, words: words)
        guard var digest else {
            run.report.extractiveOnly = true
            return (fallback, run.report)
        }
        let source = DigestGrounding.Source(transcript)
        digest.actionItems = NoteDigestMerge.naming(digest.actionItems, run.names).map { DigestGrounding.grounded($0, in: source) }
        return (NoteDigestMerge.output(digest, fallbackTitle: fallback.title), run.report)
    }

    /// One summarization: the model, its settings, and the running report.
    struct Run {
        let model: any LanguageModel
        let configuration: Configuration
        var report = Report()
        /// "Speaker 2" → "Ben" where the transcript makes it clear (`SpeakerNameInference`).
        var names: [String: String] = [:]
        /// What is left of `dictationYieldLimit` for this run.
        var yieldLeft: Duration

        init(model: any LanguageModel, configuration: Configuration) {
            self.model = model
            self.configuration = configuration
            self.yieldLeft = configuration.dictationYieldLimit
        }

        /// Whether calls give way to dictations: the shared 4B. Apple FM's do not, and the yield limit never cuts them.
        private var yields: Bool { (model as? MeetingLanguageModel)?.route == .sharedLocal }

        var pieceWords: Int {
            configuration.chunkWords ?? NoteSummarizer.pieceWords(contextTokens: model.contextTokens)
        }

        mutating func digest(_ transcript: String, words: Int) async -> MeetingDigest? {
            // A transcript that fits one piece is one call whatever the strategy.
            let single = configuration.strategy == .singlePass || words <= pieceWords
            if single {
                report.strategy = .singlePass
                if let digest = await callWithRetry(NoteDigestPrompts.whole, prompt: "Transcript:\n\n\(transcript)", MeetingDigest.self) {
                    return digest
                }
                guard configuration.strategy == .auto else { return nil }
                report.singlePassFellBack = true
            }
            report.strategy = .mapReduce
            return await mapReduce(transcript)
        }

        mutating func mapReduce(_ transcript: String) async -> MeetingDigest? {
            let pieces = TranscriptChunker.chunks(
                transcript, maxWords: pieceWords, overlapWords: configuration.overlapWords)
            report.pieces = pieces.count
            var notes: [MeetingPartNotes] = []
            for (index, piece) in pieces.enumerated() {
                notes.append(await notesForPiece(piece, index: index, of: pieces.count))
            }
            if report.extractivePieces == pieces.count { return nil }
            let parts = NoteDigestMerge.dedupedAcrossOverlap(NoteDigestMerge.namingOwners(notes, known: names))
            configuration.trace?(NoteDigestMerge.render(parts))
            return await merge(parts)
        }

        /// The map call for one piece: once, again, then the extractive notes for that piece.
        mutating func notesForPiece(_ piece: String, index: Int, of count: Int) async -> MeetingPartNotes {
            let prompt = "Part \(index + 1) of \(count) of the meeting transcript"
                + (index > 0 ? " (its first lines repeat the end of the previous part)" : "") + ":\n\n\(piece)"
            if let notes = await callWithRetry(NoteDigestPrompts.part, prompt: prompt, MeetingPartNotes.self) { return notes }
            report.extractivePieces += 1
            return NoteDigestMerge.extractiveNotes(piece)
        }

        /// Merges piece notes in meeting order; halves first when they are too long for one call.
        mutating func merge(_ parts: [MeetingPartNotes]) async -> MeetingDigest {
            let rendered = NoteDigestMerge.render(parts)
            if parts.count > 2, TextStats.wordCount(rendered) > configuration.mergeWords {
                let middle = parts.count / 2
                let first = await merge(Array(parts[..<middle]))
                let second = await merge(Array(parts[middle...]))
                // Each half keeps its parts' changes, so a change in the second half still reaches
                // an item from the first.
                return await merge([
                    NoteDigestMerge.partNotes(from: first, changes: parts[..<middle].flatMap(\.changes)),
                    NoteDigestMerge.partNotes(from: second, changes: parts[middle...].flatMap(\.changes)),
                ])
            }
            if let answer = await callWithRetry(NoteDigestPrompts.merge, prompt: rendered, MeetingMerge.self) {
                return NoteDigestMerge.apply(answer, to: parts)
            }
            report.deterministicMerge = true
            return NoteDigestMerge.merge(parts)
        }

        /// Greedy first; a failed call is retried once with the backend's default sampling, since
        /// greedy decoding repeats the same failure (a small model looping inside a string).
        mutating func callWithRetry<Output: StructuredOutput>(
            _ instructions: String, prompt: String, _ type: Output.Type
        ) async -> Output? {
            if let output = await call(instructions, prompt: prompt, Output.self, options: .greedy) { return output }
            guard !report.gaveWayToDictation else { return nil }
            report.retries += 1
            return await call(instructions, prompt: prompt, Output.self, options: .systemDefault)
        }

        private static func isPreempted<Output>(_ result: Result<Output, any Error>) -> Bool {
            if case .failure(let error) = result, error is ForegroundPreempted { return true }
            return false
        }

        /// A wait shorter than this returned at once (no dictation was in progress) and uses up none of the yield limit,
        /// so a run without dictations keeps the full call budget for every attempt.
        static let immediateWait = Duration.milliseconds(1)

        /// Whether `model` gave way to dictations within `limit`; false when the limit ran out first.
        private static func yield(_ model: any LanguageModel, within limit: Duration) async -> Bool {
            guard limit > .zero else { return false }
            return await withTaskGroup(of: Bool.self) { group in
                group.addTask { await model.yieldToForeground(); return !Task.isCancelled }
                group.addTask { try? await Task.sleep(for: limit); return false }
                defer { group.cancelAll() }
                return await group.next() ?? false
            }
        }

        mutating func call<Output: StructuredOutput>(
            _ instructions: String, prompt: String, _ type: Output.Type, options: LanguageModelOptions
        ) async -> Output? {
            guard !report.gaveWayToDictation else { return nil }
            report.calls += 1
            let model = self.model, budget = configuration.callBudget, yields = self.yields
            var result: Result<Output, any Error>
            repeat {
                // A dictation in progress goes first; the wait is not part of the call's budget. A call a dictation
                // cut short (`ForegroundPreempted`) is asked again once it is over, and is not a failure. Waiting and
                // cut-short attempts use up `yieldLeft`; when it runs out the run stops here and `summarize` reruns it
                // on Apple FM. An attempt no dictation interrupts has the call budget, not what is left of `yieldLeft`.
                if yields {
                    let waitBegan = ContinuousClock.now
                    let gaveWay = await Self.yield(model, within: yieldLeft)
                    let waited = ContinuousClock.now - waitBegan
                    if waited >= Self.immediateWait { yieldLeft -= waited }
                    guard gaveWay || Task.isCancelled else {
                        report.gaveWayToDictation = true
                        return nil
                    }
                }
                let began = ContinuousClock.now
                result = await withTaskGroup(of: Result<Output, any Error>?.self) { group in
                    group.addTask {
                        do {
                            return .success(try await model.respond(
                                instructions: instructions, prompt: prompt, generating: Output.self, options: options))
                        } catch { return .failure(error) }
                    }
                    group.addTask {
                        try? await Task.sleep(for: budget)
                        guard !Task.isCancelled else { return nil }
                        return .failure(SummaryCallTimeout())
                    }
                    let first = await group.next() ?? nil
                    group.cancelAll()
                    return first ?? .failure(CancellationError())
                }
                if Self.isPreempted(result) { yieldLeft -= ContinuousClock.now - began }
            } while Self.isPreempted(result) && !Task.isCancelled
            switch result {
            case .success(let output):
                return output
            case .failure(let error):
                let failure: ModelCallFailure = error is SummaryCallTimeout ? .timeout : ModelCallFailure(error)
                report.failures.append(failure)
                // Error descriptions carry no transcript text (schema names, token counts).
                configuration.trace?("\(Output.generationSchema.name) call failed: \(error)")
                return nil
            }
        }
    }
}
