import Foundation
import os

/// Anything that turns 16 kHz mono samples into text: the production ASR engine in the app,
/// a FluidAudio-backed engine in the eval harness, or a fake in tests. Kept in MurmurCore
/// (which does not depend on FluidAudio) so the pipeline can be built and tested without it.
public protocol Transcriber: Sendable {
    func transcribe(_ samples: [Float]) async throws -> String

    /// Transcribes with a vocabulary to bias recognition towards (names, jargon, acronyms from
    /// the user's Dictionary). Conformers that support boosting (see `SpeechEngine`) apply it;
    /// others fall back to the plain `transcribe(_:)` and ignore `vocabulary` — the default
    /// implementation below does exactly that, so existing conformers and test fakes need no
    /// changes to keep building.
    func transcribe(_ samples: [Float], vocabulary: VocabularyContext) async throws -> String

    /// Transcribes and, when the engine can provide it, returns per-word ASR confidence
    /// alongside the text. This is the confidence-aware entry point `DictationPipeline` uses;
    /// conformers that have no confidence signal (test fakes, engines built before this was
    /// added) inherit the default below, which wraps `transcribe(_:vocabulary:)` with
    /// `confidences: nil` — so nothing changes for them and the hybrid cleanup strategy behaves
    /// exactly as it did before confidences existed.
    func transcribeWithConfidence(_ samples: [Float], vocabulary: VocabularyContext) async throws -> TranscriptionResult
}

extension Transcriber {
    public func transcribe(_ samples: [Float], vocabulary: VocabularyContext) async throws -> String {
        try await transcribe(samples)
    }

    public func transcribeWithConfidence(
        _ samples: [Float], vocabulary: VocabularyContext
    ) async throws -> TranscriptionResult {
        TranscriptionResult(text: try await transcribe(samples, vocabulary: vocabulary), confidences: nil)
    }
}

/// Immutable settings for one pipeline run: which cleanup rules to apply, the user's
/// dictionary/snippets, and the writing style for the target context (if any). Capturing
/// these once per session — rather than reading live settings mid-pipeline — matches how
/// `DictationController` snapshots settings at key-down.
public struct PipelineSettings: Sendable {
    public var cleanupOptions: CleanupOptions
    public var personalizer: Personalizer
    /// The style to apply after cleanup, and the context it belongs to. `nil` means the
    /// target never gets styled (e.g. a code editor) or styling is not wanted (notes).
    public var style: (context: StyleContext, style: WritingStyle)?
    /// The tone to apply with `style`'s layout, for English or unknown-language text. `nil` keeps
    /// the plain layout-only styling (non-English text, and callers that have no tone). A tone is
    /// also what asks for the grammar-and-flow cleanup; see `resolvedForLanguage`.
    public var tone: DictationTone?
    /// The active custom mode, if any (see `Mode`). `cleanupOptions.level` should already
    /// reflect `mode.cleanupLevel` when a mode is active — callers set both from the same
    /// resolved mode (see `ModeResolver`) — this field only carries the mode's `prompt` forward
    /// to `ModeExecutor`, which runs after styling. `nil` (no mode, or the Default mode with no
    /// prompt) skips the transform step entirely: nothing changes for a dictation with no mode
    /// selected, matching pre-modes behavior exactly.
    public var mode: Mode?
    /// Candidate names/terms pulled from the surrounding editor text by `ContextExtractor`, for
    /// "Context awareness" (Settings → Privacy & data, off by default). Empty unless the feature
    /// is on and produced candidates for this one dictation; never persisted by the caller (see
    /// `.claude/DECISIONS.md`) — this struct just carries them through one pipeline run.
    public var contextTerms: [String]
    /// Snapshot of installed app display names for this dictation. The app owns the cached scan and hands it over
    /// most relevant first (`RankedInstalledApps`); the cap `maxInstalledNameTerms` then cuts from the end, after the
    /// ordinary-word filter, so the apps a person never uses are the ones that drop.
    public var installedApps: [InstalledAppInfo]
    public var frontmostBundleID: String?
    /// The focus is a prompt box of a coding agent (a terminal or editor chat). Detection cannot say which agent it is,
    /// so `AIProductCloudCues` treats it as an Anthropic place the way it treats the Claude desktop app.
    public var focusedAgentSession: Bool
    /// The focused app is one where people dictate prompts for an AI (`AppCategory.aiPrompts`: Claude, ChatGPT, Codex, an
    /// agent prompt box). The recogniser is then also boosted towards the AI model names (`VocabularyContext.aiModelTerms`).
    public var aiPromptApp: Bool
    public var keepHeard: KeepHeardSet {
        didSet { personalizer.keep = keepHeard }
    }
    /// Names from the personal lexicon (`LexiconSnapshot.boostTerms`): what the person uses, and the active domain packs.
    /// Boosted after the Dictionary and screen terms, before installed app names; also protected from cleanup rewrites.
    /// Empty when there is no evidence, and then the vocabulary is exactly what it was before the lexicon existed.
    public var lexiconTerms: [VocabularyTerm] = []
    public static let maxInstalledNameTerms = 150

    public init(
        cleanupOptions: CleanupOptions = CleanupOptions(),
        personalizer: Personalizer = Personalizer(),
        style: (context: StyleContext, style: WritingStyle)? = nil,
        tone: DictationTone? = nil,
        mode: Mode? = nil,
        contextTerms: [String] = [], installedApps: [InstalledAppInfo] = [],
        frontmostBundleID: String? = nil, focusedAgentSession: Bool = false, aiPromptApp: Bool = false,
        keepHeard: KeepHeardSet = .empty
    ) {
        self.cleanupOptions = cleanupOptions
        self.personalizer = personalizer.scoped(to: frontmostBundleID)
        self.style = style
        self.tone = tone
        self.mode = mode
        self.contextTerms = contextTerms
        self.installedApps = installedApps
        self.frontmostBundleID = frontmostBundleID
        self.focusedAgentSession = focusedAgentSession
        self.aiPromptApp = aiPromptApp
        self.keepHeard = keepHeard
        self.personalizer.keep = keepHeard
    }

    /// Dictionary entries, context terms, installed app display names, and built-in terms.
    /// Dictionary entries win duplicate spellings because they can carry spoken aliases.
    /// Ordinary-word app names are excluded; every remaining term still passes `BoostGuard`.
    func installedNameTerms(excluding excluded: Set<String> = []) -> [VocabularyTerm] {
        guard FeatureFlags.installedNames else { return [] }
        var seen = Set<String>()
        var names: [VocabularyTerm] = []
        for app in installedApps {
            let name = app.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !excluded.contains(name.lowercased()),
                  !InstalledNamePolicy.isOrdinary(name),
                  seen.insert(name.lowercased()).inserted else { continue }
            names.append(VocabularyTerm(text: name, source: .installedApp))
            if names.count == Self.maxInstalledNameTerms { break }
        }
        return names
    }

    /// The vocabulary to build the recogniser's boosting session for while the person speaks: this dictation's own,
    /// and only when the screen gave it terms. Without them the vocabulary is the one that is kept warm already, so
    /// there is nothing to start.
    public var contextWarmVocabulary: VocabularyContext? {
        contextTerms.isEmpty && !aiPromptApp && lexiconTerms.isEmpty ? nil : vocabulary
    }

    public var vocabulary: VocabularyContext {
        let dictionaryContext = VocabularyContext.from(dictionary: personalizer.dictionary)
        let existingKeys = Set(dictionaryContext.terms.map { $0.text.lowercased() })
        // A screen term the personal lexicon also learned stays the person's own term (`VocabularyTerm.Source`).
        let learnedKeys = Set(lexiconTerms.filter { $0.source == .personal }.map { $0.text.lowercased() })
        let extra = contextTerms.filter { !existingKeys.contains($0.lowercased()) }.map {
            VocabularyTerm(text: $0, source: learnedKeys.contains($0.lowercased()) ? .personal : .context)
        }
        let screenAndDictionary = dictionaryContext.terms + extra
        let screenKeys = Set(screenAndDictionary.map { $0.text.lowercased() })
        let lexicon = lexiconTerms.filter { !screenKeys.contains($0.text.lowercased()) }
        let userTerms = screenAndDictionary + lexicon
        let userKeys = Set(userTerms.map { $0.text.lowercased() })
        let appTerms = installedNameTerms(excluding: userKeys)
        var seen = userKeys
        var distinctApps: [VocabularyTerm] = []
        for app in appTerms {
            guard distinctApps.count < Self.maxInstalledNameTerms else { break }
            if seen.insert(app.text.lowercased()).inserted { distinctApps.append(app) }
        }
        let builtIns = VocabularyContext.builtInTerms.filter { !seen.contains($0.text.lowercased()) }
        seen.formUnion(builtIns.map { $0.text.lowercased() })
        let aiModels = aiPromptApp ? VocabularyContext.aiModelTerms.filter { !seen.contains($0.text.lowercased()) } : []
        return VocabularyContext(terms: userTerms + distinctApps + builtIns + aiModels)
    }
}

/// The result of running the production pipeline once.
public struct PipelineResult: Sendable {
    /// The raw ASR transcript, before any cleanup.
    public let raw: String
    /// Text after cleanup, personalization and (if configured) styling.
    public let text: String
    /// True when the utterance ended in a spoken "press enter"/"hit return".
    public let pressEnter: Bool
    /// Which cleanup strategy actually ran (rules only, or rules + model).
    public let usedModel: Bool
    /// Why a model rewrite was rejected, if one was attempted and rejected.
    public let rejection: String?
    /// True when the active mode's transform (see `Mode`, `ModeExecutor`) ran the on-device
    /// model and its answer was accepted. False for a non-transform mode (or no mode), and
    /// false when the transform fell back to rules/unchanged text.
    public let usedMode: Bool
    /// Why the mode transform was rejected or skipped, if any was attempted.
    public let modeRejection: String?
    /// Per-stage timing, matching the app's `LatencyBreakdown` stages.
    public let timings: PipelineTimings
    /// True when "Context awareness" (see `PipelineSettings.contextTerms`) actually changed this
    /// dictation's output — either the spelling-fix pass rewrote a word, or at least one context
    /// term survived `BoostGuard` into the boosted transcript. Drives the small indicator in the
    /// pill (`DictationController`/`PillState`); false whenever the feature is off or made no
    /// difference, so the indicator only ever appears when it did something real.
    public let usedContext: Bool
    /// The model was wanted but no answer came in time (see `SmartCleaner.Output.speedFallback`):
    /// the rules text was pasted, and the pill says so.
    public let speedFallback: Bool
    /// What the model did for each group of the dictation (one for a short dictation). `usedModel`
    /// and `rejection` above describe only the last group; this keeps every group's outcome.
    public let groups: [GroupTrace]
    /// A long dictation: how each group was served, in order (`SmartCleaner.GroupSource`).
    public var groupSources: [SmartCleaner.GroupSource] = []
    /// Groups cleaned before the key release and how many of them the final transcript used; nil with no early cleaning.
    public var early: EarlyCleanupTally?
    public var cleanupStages = ""
    public var vocabularySwaps: [VocabularySwap] = []

    public init(
        raw: String, text: String, pressEnter: Bool, usedModel: Bool, rejection: String?,
        timings: PipelineTimings, usedMode: Bool = false, modeRejection: String? = nil,
        usedContext: Bool = false, speedFallback: Bool = false, groups: [GroupTrace] = []
    ) {
        self.groups = groups
        self.raw = raw
        self.text = text
        self.pressEnter = pressEnter
        self.usedModel = usedModel
        self.rejection = rejection
        self.timings = timings
        self.usedMode = usedMode
        self.modeRejection = modeRejection
        self.usedContext = usedContext
        self.speedFallback = speedFallback
    }
}

/// Elapsed milliseconds for each pipeline stage, so callers (app latency logging, eval
/// reports) can break down where time went without re-timing themselves.
public struct PipelineTimings: Sendable {
    public var normalizeMs: Double = 0
    public var speechMs: Double = 0
    public var cleanupMs: Double = 0

    public var totalMs: Double { normalizeMs + speechMs + cleanupMs }

    public init(normalizeMs: Double = 0, speechMs: Double = 0, cleanupMs: Double = 0) {
        self.normalizeMs = normalizeMs
        self.speechMs = speechMs
        self.cleanupMs = cleanupMs
    }
}

/// The single production processing path shared by the app (dictation hot path, History
/// retry) and the eval harness: loudness normalization → ASR → `SmartCleaner` (rules, then
/// the on-device model when warranted) → `Personalizer` → `StyleFormatter`.
///
/// Kept deliberately small and allocation-light: the app's hot path calls `run(samples:...)`
/// on every key release, so this type does no more work than the steps it documents, and it
/// does not retain any per-call state between invocations. ASR is injected via `Transcriber`
/// so the app can pass its FluidAudio-backed `SpeechEngine`, `murmur-eval` can pass its own
/// engine wrapper, and tests can pass a deterministic fake — all three exercise the exact same
/// normalization/cleanup/personalization/style steps.
public struct DictationPipeline: Sendable {
    private let transcriber: any Transcriber
    private let cleaner: SmartCleaner
    private let warmScheduler: KeyDownWarmScheduler?
    private static let log = Logger(subsystem: "app.hushy", category: "pipeline")

    public init(transcriber: any Transcriber, cleaner: SmartCleaner = SmartCleaner(),
                warmScheduler: KeyDownWarmScheduler? = nil) {
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.warmScheduler = warmScheduler
    }

    /// Runs the full dictation path on raw samples: normalize → transcribe → clean →
    /// personalize → style. This is what `DictationController.process` and the eval `e2e`/
    /// `cleanup` commands should call so both exercise identical production behavior.
    public func run(
        samples: [Float], settings: PipelineSettings, strategy: SmartCleaner.Strategy? = nil
    ) async throws -> PipelineResult {
        var timings = PipelineTimings()
        let start = Date()
        // The model's deadline counts from here, so a slow transcription uses up its share.
        let started = ContinuousClock.now
        let normalized = LoudnessNormalizer.normalize(samples)
        timings.normalizeMs = Date().timeIntervalSince(start) * 1000

        let speechStart = Date()
        let transcribed = try await transcriber.transcribeWithConfidence(normalized, vocabulary: settings.vocabulary)
        let release = ReleaseSwaps.apply(transcribed, keep: settings.keepHeard)
        let fixed = vocabularyFixes(release.text, settings: settings)
        let raw = fixed.text
        let usedContext = fixed.usedContext
        timings.speechMs = Date().timeIntervalSince(speechStart) * 1000

        guard !raw.isEmpty else {
            return PipelineResult(
                raw: raw, text: "", pressEnter: false, usedModel: false, rejection: nil, timings: timings)
        }

        let (result, cleanupMs) = await time {
            await self.processTranscript(
                raw, confidences: transcribed.confidences, settings: settings, strategy: strategy, released: started)
        }
        timings.cleanupMs = cleanupMs
        var output = PipelineResult(
            raw: raw, text: Self.screenSpelling(keepAcceptedVocabulary(result.text, heard: release.text, settings: settings), settings: settings), pressEnter: result.pressEnter, usedModel: result.usedModel,
            rejection: result.rejection, timings: timings, usedMode: result.usedMode,
            modeRejection: result.modeRejection, usedContext: usedContext, speedFallback: result.speedFallback,
            groups: result.groups)
        output.vocabularySwaps = release.swaps + fixed.swaps + settings.personalizer.aliasSwaps(in: raw)
        return output
    }

    /// Normalizes and transcribes only, with no cleanup/personalization/style — what the notes
    /// pipeline uses for each 30 s chunk (voice commands and styling do not apply to a recorded
    /// conversation the way they do to a dictated instruction). `vocabulary` still applies: note
    /// chunks benefit from the same name/jargon boosting as dictation.
    public func transcribeRaw(_ samples: [Float], vocabulary: VocabularyContext = .empty) async throws -> String {
        try await transcriber.transcribe(LoudnessNormalizer.normalize(samples), vocabulary: vocabulary)
    }

    /// Same as `transcribeRaw`, but also returns per-word timing when the transcriber can
    /// provide it (see `TranscriptionResult.timings`). Added for `NoteRecorder` (Phase 0 of
    /// docs/research/speaker-labeling.md) so note chunks can carry word timing forward for a
    /// later diarization pass, without changing `transcribeRaw`'s existing callers/behavior.
    /// File import (`FileTranscriber`) also uses this — it needs the same per-word timing to
    /// export subtitles/timestamped text, and diarization's own alignment code
    /// (`SpeakerAlignment`) is reused there too (see `NoteTranscriptExporter`/`FileTranscriber`).
    public func transcribeRawWithTimings(
        _ samples: [Float], vocabulary: VocabularyContext = .empty
    ) async throws -> TranscriptionResult {
        try await transcriber.transcribeWithConfidence(LoudnessNormalizer.normalize(samples), vocabulary: vocabulary)
    }

    /// Runs cleanup/personalization/style on an already-transcribed string, for callers that
    /// have their own ASR step (the eval `cleanup` command scores text-only golden cases) or
    /// need to re-clean a raw transcript (History retry). `confidences` lets a caller that ran
    /// ASR itself (e.g. `DictationController`, which calls `SpeechEngine` directly on its hot
    /// path rather than through `run(samples:...)`) still pass along word confidence; omitting
    /// it (the default) matches pre-confidence behavior exactly.
    public func clean(
        _ raw: String, confidences: [WordConfidence]? = nil, settings: PipelineSettings,
        strategy: SmartCleaner.Strategy? = nil, incremental: Bool = true, released: ContinuousClock.Instant? = nil,
        onProgress: CleanupProgressObserver? = nil
    ) async -> PipelineResult {
        await warmScheduler?.beforeRealCall()
        var timings = PipelineTimings()
        let fixes = vocabularyFixes(raw, settings: settings)
        let fixed = fixes.text
        let usedContext = fixes.usedContext
        guard !fixed.isEmpty else {
            return PipelineResult(raw: fixed, text: "", pressEnter: false, usedModel: false, rejection: nil, timings: timings)
        }
        let (result, cleanupMs) = await time {
            await self.processTranscript(
                fixed, confidences: confidences, settings: settings, strategy: strategy, incremental: incremental,
                released: released, onProgress: onProgress)
        }
        timings.cleanupMs = cleanupMs
        var output = PipelineResult(
            raw: fixed,
            text: Self.writtenForms(Self.screenSpelling(keepAcceptedVocabulary(result.text, heard: raw, settings: settings),
                                                        settings: settings), settings: settings),
            pressEnter: result.pressEnter, usedModel: result.usedModel,
            rejection: result.rejection, timings: timings, usedMode: result.usedMode,
            modeRejection: result.modeRejection, usedContext: usedContext, speedFallback: result.speedFallback,
            groups: result.groups)
        output.vocabularySwaps = fixes.swaps + settings.personalizer.aliasSwaps(in: fixed)
        output.groupSources = result.groupSources
        output.early = result.early
        output.cleanupStages = Self.cleanupStageLine(groups: result.groups, cleanupMs: cleanupMs,
            smartMs: result.smartMs, styleMs: result.styleMs, modeMs: result.modeMs)
        Self.log.notice("\(output.cleanupStages, privacy: .public)")
        return output
    }

    /// One transcript through cleanup, styling, and (the modes extension point) a mode
    /// transform, in that fixed order. This is the single place `ModeExecutor` is called from —
    /// every other pipeline stage (`SmartCleaner`, `StyleFormatter`) is unaware modes exist.
    private struct TranscriptResult {
        let text: String
        let pressEnter: Bool
        let usedModel: Bool
        let rejection: String?
        let usedMode: Bool
        let modeRejection: String?
        let speedFallback: Bool
        let groups: [GroupTrace]
        var groupSources: [SmartCleaner.GroupSource] = []
        var early: EarlyCleanupTally?
        var smartMs = 0
        var styleMs = 0
        var modeMs = 0
    }

    /// Runs the "Context awareness" spelling-fix pass (`ContextSpellingFixer`) on the raw ASR
    /// transcript using `settings.contextTerms`, and reports whether it changed anything —
    /// either by rewriting a near-miss word, or because a context term already survived into
    /// `raw` via vocabulary boosting (i.e. present verbatim where it wasn't before boosting could
    /// be checked at this layer; conservatively, presence is treated as "context contributed").
    /// A no-op (empty `contextTerms`, or the fixer made no change) returns `raw` unchanged and
    /// `usedContext: false`, so the feature being off costs nothing and changes no behavior.
    private func applyContextSpellingFix(_ raw: String, settings: PipelineSettings) -> (text: String, usedContext: Bool, swaps: [VocabularySwap]) {
        guard !settings.contextTerms.isEmpty, !raw.isEmpty else { return (raw, false, []) }
        let joined = ScreenIdentifierJoiner.join(raw, terms: settings.contextTerms)
        let fixed = VocabularySwaps.restore(from: raw, to: ContextSpellingFixer.fix(joined, terms: settings.contextTerms),
                                            source: .screenSpelling, keeping: settings.keepHeard)
        if fixed.text != raw { return (fixed.text, true, fixed.swaps) }
        let rawKey = raw.lowercased()
        let termAppears = settings.contextTerms.contains { rawKey.contains($0.lowercased()) }
        return (fixed.text, termAppears, fixed.swaps)
    }

    /// An on-screen identifier the delivered text holds with the same letters and digits is written as the screen spells
    /// it: cleanup rules or the model can drop its punctuation ("GPT-4o" pasted as "GPT4o"), which the protected-term guard
    /// does not see because it compares letters and digits only.
    static func screenSpelling(_ text: String, settings: PipelineSettings) -> String {
        settings.contextTerms.isEmpty ? text : ScreenIdentifierJoiner.join(text, terms: settings.contextTerms)
    }

    /// An explicit rejected pair also wins when a model or mode proposes that same replacement.
    private func keepAcceptedVocabulary(_ text: String, heard: String, settings: PipelineSettings) -> String {
        guard !settings.keepHeard.isEmpty else { return text }
        return VocabularySwaps.restore(from: heard, to: text, source: .dictionaryAlias, keeping: settings.keepHeard).text
    }

    private func vocabularyFixes(_ raw: String, settings: PipelineSettings) -> (text: String, usedContext: Bool, swaps: [VocabularySwap]) {
        let context = applyContextSpellingFix(raw, settings: settings)
        let dictionary = VocabularySwaps.restore(from: context.text,
            to: DictionaryTermFixer.fix(context.text, personalizer: settings.personalizer),
            source: .dictionaryName, keeping: settings.keepHeard)
        let installed = VocabularySwaps.restore(from: dictionary.text,
            to: InstalledNameFixer.fix(dictionary.text, settings: settings),
            source: .installedName, keeping: settings.keepHeard)
        let product = VocabularySwaps.restore(from: installed.text,
            to: AIProductNameFixer.fix(installed.text, settings: settings),
            source: .productName, keeping: settings.keepHeard)
        let joined = Self.writtenForms(product.text, settings: settings)
        return (joined, context.usedContext, context.swaps + dictionary.swaps + installed.swaps + product.swaps)
    }

    /// Spoken addresses and code-like names in their written form: "john at gmail dot com" as john@gmail.com, and
    /// "TRY95" or "try ninety five" as the TRY-95 the screen or the Dictionary has. Before the model, so it is given the
    /// written form and its guards hold it there, and again on its answer, which can drop the join ("John at @gmail.com").
    static func writtenForms(_ text: String, settings: PipelineSettings) -> String {
        let options = settings.cleanupOptions
        guard options.level != .verbatim, options.isEnglishOrUnknown, !text.isEmpty else { return text }
        let terms = settings.contextTerms + settings.personalizer.dictionary.map(\.term)
        let keep = settings.keepHeard
        let named = KnownIdentifierForms.apply(text, terms: terms) { heard, written in
            keep.blocks(heardKey: VocabularySwap.key(heard), writtenKey: VocabularySwap.key(written))
        }
        return SpokenEmails.apply(named)
    }

    private func processTranscript(
        _ raw: String, confidences: [WordConfidence]?, settings requested: PipelineSettings, strategy: SmartCleaner.Strategy?,
        incremental: Bool = true, released: ContinuousClock.Instant? = nil, onProgress: CleanupProgressObserver? = nil
    ) async -> TranscriptResult {
        let (settings, options) = Self.cleanerInputs(requested)
        let rawTrace = RepeatTrace(raw)
        if rawTrace.isLoopedRecogniserText {
            Self.log.notice("\(RepeatTrace.looped(stage: "recogniser", rawTrace), privacy: .public)")
        }
        let smartStarted = ContinuousClock.now
        let cleaned = await cleaner.clean(
            raw, confidences: confidences, options: options, personalizer: settings.personalizer,
            strategy: strategy, incremental: incremental, released: released, onProgress: onProgress)
        let smartMs = Int(ModelPace.ms(ContinuousClock.now - smartStarted))
        var text = cleaned.text
        let styleStarted = ContinuousClock.now
        if let (context, style) = settings.style, settings.cleanupOptions.level != .verbatim,
           !settings.cleanupOptions.isCodeContext {
            let styled: String
            // A model that was sent the register line has already written the register, so the word swaps are left out
            // (the layout still applies). If it gave no answer there is nothing it wrote, and the swaps do the tone.
            // A group whose register answer was refused and was asked again without the line was written plainly.
            let modelWroteRegister = cleaned.usedModel && cleaned.sentRegisterLines
                && !cleaned.groups.contains(where: \.registerDropped)
            if let tone = settings.tone, settings.cleanupOptions.isEnglishOrUnknown {
                styled = ToneRegister.apply(modelWroteRegister ? .refined : tone, layout: style, to: text, in: context)
            } else {
                styled = StyleFormatter.apply(style, to: text, in: context)
            }
            text = styled
            SmartCleaner.noteAddedRepeats(stage: "style", from: cleaned.text, to: text)
            // The tone and layout step treats a lone address as a sentence; it ends as the address is written.
            text = SmartCleaner.settleLoneAddress(text, options: settings.cleanupOptions, personalizer: settings.personalizer)
        }
        let styleMs = Int(ModelPace.ms(ContinuousClock.now - styleStarted))
        // Modes extension point: only reached when a transform mode is active and cleanup
        // actually produced text (a command-only "press enter" utterance has nothing to
        // transform). Verbatim mode still allows a mode transform to run — unlike styling, a
        // mode's formatting instruction is an explicit user choice for this dictation, not a
        // per-app default that should defer to "as spoken".
        guard let mode = settings.mode, mode.isTransform, !text.isEmpty else {
            Self.noteDistance(RewriteDistance(raw: raw, text: text, groups: cleaned.groups, asHeard: cleaned.deliveredAsHeard))
            return TranscriptResult(
                text: text, pressEnter: cleaned.pressEnter, usedModel: cleaned.usedModel,
                rejection: cleaned.rejection, usedMode: false, modeRejection: nil, speedFallback: cleaned.speedFallback,
                groups: cleaned.groups, groupSources: cleaned.groupSources, early: cleaned.early,
                smartMs: smartMs, styleMs: styleMs)
        }
        let modeStarted = ContinuousClock.now
        let transformed = await ModeExecutor.apply(mode, to: text)
        let modeMs = Int(ModelPace.ms(ContinuousClock.now - modeStarted))
        SmartCleaner.noteAddedRepeats(stage: "mode", from: text, to: transformed.text)
        Self.noteDistance(RewriteDistance(
            raw: raw, text: transformed.text, groups: cleaned.groups, asHeard: cleaned.deliveredAsHeard, usedMode: transformed.usedModel))
        return TranscriptResult(
            text: transformed.text, pressEnter: cleaned.pressEnter, usedModel: cleaned.usedModel,
            rejection: cleaned.rejection, usedMode: transformed.usedModel, modeRejection: transformed.rejection,
            speedFallback: cleaned.speedFallback, groups: cleaned.groups, groupSources: cleaned.groupSources, early: cleaned.early,
            smartMs: smartMs, styleMs: styleMs, modeMs: modeMs)
    }

    static func cleanupStageLine(groups: [GroupTrace], cleanupMs: Double, smartMs: Int, styleMs: Int, modeMs: Int) -> String {
        let recovery = groups.reduce(0) { $0 + $1.measured.failureRetryMs }
        let first = groups.reduce(0) { $0 + ($1.measured.callMs ?? 0) } - recovery
        let again = groups.reduce(0) { $0 + ($1.retryMs ?? 0) }
        let opinion = groups.reduce(0) { $0 + ($1.secondPassMs ?? 0) }
        let opinionCalls = groups.filter { $0.secondPass != .none }.count
        let opinionModel = groups.reduce(0) { $0 + ($1.measured.secondPassCallMs ?? 0) }
        let model = groups.reduce(0) { $0 + ($1.modelMs ?? 0) }
        let span = groups.reduce(0) { $0 + $1.measured.spanRepairMs }
        let rerank = groups.reduce(0) { $0 + $1.measured.rerankMs }
        let verify = groups.reduce(0) { $0 + $1.measured.grammarVerifyMs }
        let guards = max(0, model - first - recovery - again - opinion - span - rerank - verify)
        let rules = max(0, smartMs - model)
        let other = max(0, Int(cleanupMs) - smartMs - styleMs - modeMs)
        return "cleanup stages groups=\(groups.count) firstMs=\(first) recoveryMs=\(recovery) guidedMs=\(again) "
            + "opinionCalls=\(opinionCalls) opinionMs=\(opinion) opinionModelMs=\(opinionModel) "
            + "rerankMs=\(rerank) verifyMs=\(verify) spanMs=\(span) guardsMs=\(guards) "
            + "rulesMs=\(rules) styleMs=\(styleMs) modeMs=\(modeMs) "
            + "otherMs=\(other) totalMs=\(Int(cleanupMs))"
    }

    /// One line per dictation: how far the delivered text is from the recogniser's, in counts (see `RewriteDistance`).
    static func noteDistance(_ distance: RewriteDistance) {
        log.notice("\(distance.line, privacy: .public)")
    }

    /// The settings and cleanup options one transcript is cleaned under. One place, so a group cleaned before the key
    /// release (`cleanEarly`) is cleaned under exactly what `clean` will use after it.
    static func cleanerInputs(_ requested: PipelineSettings) -> (settings: PipelineSettings, options: CleanupOptions) {
        var settings = requested.resolvedForLanguage()
        settings.personalizer.keep = settings.keepHeard
        var options = settings.cleanupOptions
        options.protectedTerms += settings.installedNameTerms().map(\.text)
        options.protectedTerms += settings.lexiconTerms.map(\.text)
        return (settings, options)
    }

    // MARK: Cleaning while the person is still speaking

    /// A dictation has started: sentence groups may be cleaned ahead until its `clean`. The token it returns is for
    /// `endEarlyCleaning`, which drops what was cleaned for this dictation once it is over.
    @discardableResult
    public func openEarlyCleaning() async -> Int {
        await cleaner.openEarlyCleaning()
    }

    public func endEarlyCleaning(_ token: Int) async {
        await cleaner.endEarlyCleaning(token)
    }

    /// The transcript heard so far, with the fixes `clean` applies to a transcript before it is cleaned, so its
    /// sentence groups are spelled the way the final transcript's will be.
    public func earlyTranscript(_ raw: String, settings: PipelineSettings) -> String {
        vocabularyFixes(raw, settings: settings).text
    }

    /// Cleans one closed sentence group of `earlyTranscript` ahead of the key release, under the options `clean` will
    /// use. Returns whether a model call was started. It only saves time: `clean` still cleans the final transcript in
    /// its own groups and uses this result only for a group with exactly this text (`SmartCleaner.cleanEarly`).
    @discardableResult
    public func cleanEarly(group: String, settings requested: PipelineSettings) async -> Bool {
        await warmScheduler?.beforeRealCall()
        let (settings, options) = Self.cleanerInputs(requested)
        return await cleaner.cleanEarly(group, options: options, personalizer: settings.personalizer)
    }

    private func time<T>(_ work: () async -> T) async -> (T, Double) {
        let start = Date()
        let value = await work()
        return (value, Date().timeIntervalSince(start) * 1000)
    }
}
