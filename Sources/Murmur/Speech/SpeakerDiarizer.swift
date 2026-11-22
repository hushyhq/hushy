import CryptoKit
import FluidAudio
import Foundation
import MurmurCore
import os

/// Runs post-hoc speaker diarization over a finished note's audio and persists the result, per
/// docs/research/speaker-labeling.md §2.1: one pass over the *whole* note's audio in time order (not per-chunk),
/// streamed window by window (`StreamedDiarization`) so neither the hour of samples nor its features are held at
/// once, and paused between windows while a dictation is in progress. The engine is `SpeakerDiarizerConstants.engine` (Nemotron 3, measured in
/// docs/research/diarizer-bakeoff-2026-11-06.md); FluidAudio's legacy `DiarizerManager` is the
/// fallback and still provides the voice embeddings saved voices are compared in.
///
/// This type owns nothing that must survive across notes except the lazily-loaded CoreML models
/// (mirroring `SpeechEngine`'s own lazy model load): the first call downloads/loads FluidAudio's
/// segmentation + embedding models if they aren't cached yet, then reuses them for every
/// subsequent note. A `DiarizerManager` instance is not `Sendable`-safe to share mutable state
/// across concurrent notes, so this actor serializes diarization runs one at a time — acceptable
/// since it's a background, best-effort pass and Hushy only records one note at a time anyway.
actor SpeakerDiarizer {
    enum DiarizerError: LocalizedError {
        case noAudio
        case modelsNotCached
        case modelsBackingOff
        var errorDescription: String? {
            switch self {
            case .noAudio: "No audio chunks were found for this note."
            case .modelsNotCached: "The speaker models are not on this Mac yet."
            case .modelsBackingOff: "The speaker models did not download a short while ago; not trying again yet."
            }
        }
    }

    private var manager: DiarizerManager?
    private var nemotron: LoadedNemotron?
    private var nemotronLoad = ModelLoadBackoff()
    private var legacyLoad = ModelLoadBackoff()
    private let downloadLegacyModels: @Sendable () async throws -> DiarizerModels
    private let now: @Sendable () -> Date
    private let log = Logger(subsystem: "app.hushy", category: "diarization")

    init(
        downloadLegacyModels: @escaping @Sendable () async throws -> DiarizerModels = { try await DiarizerModels.downloadIfNeeded() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.downloadLegacyModels = downloadLegacyModels
        self.now = now
    }

    /// Builds a finished note's turns (`TurnAssembler`) from both streams' words and saves them, with
    /// the speakers and their segments, in one transaction (`Store.replaceAssembly`). Returns whether
    /// turns were saved.
    ///
    /// - Two-channel: the mic side is the owner; only the call side is diarized. When that fails
    ///   or speaker labels are off, the call side is one "Speaker 1", so the note still has both sides.
    /// - Mic-only: the room is diarized; when that fails nothing is saved and the capture turns stay.
    ///
    /// Never throws and never fails the note: every error is logged.
    @discardableResult
    func assembleAndSave(
        note: Note, micWords: [MurmurCore.WordTiming], systemWords: [MurmurCore.WordTiming], isTwoChannel: Bool,
        ownerName: String?, diarize shouldDiarize: Bool, clean: @Sendable (String) -> String, store: Store,
        audio: SideAudio, yield: @escaping @Sendable () async -> Void = {}, voiceSignatureStore: VoiceSignatureStore? = nil
    ) async -> Bool {
        guard let id = note.id, !micWords.isEmpty || !systemWords.isEmpty else { return false }
        let start = Date()
        var diarized: DiarizedAudio?
        // One side on the note clock (`CaptureSegmentAudio.windows`), so diarized times match word times.
        let side: CaptureStream = isTwoChannel ? .system : .mic
        if shouldDiarize {
            do {
                let words = isTwoChannel ? systemWords : micWords
                if !words.isEmpty, audio.hasAudio(side) {
                    diarized = try await diarize(audio, side: side, noteId: id, yield: yield)
                }
            } catch {
                log.error("diarization for note \(id) failed, keeping the turns by side: \(error.localizedDescription)")
            }
        }
        guard isTwoChannel || diarized != nil else { return false }
        await yield()
        let assembly = TurnAssembler.assemble(
            mic: micWords, system: systemWords, isTwoChannel: isTwoChannel,
            micTurns: isTwoChannel ? [] : diarized?.turns ?? [], systemTurns: isTwoChannel ? diarized?.turns ?? [] : [],
            ownerName: ownerName, clean: clean)
        do {
            guard try store.replaceAssembly(noteId: id, assembly: assembly) else { return false }
        } catch {
            log.error("saving turns for note \(id) failed, keeping the capture turns: \(error.localizedDescription)")
            return false
        }
        log.notice("""
            assembled note \(id): \(assembly.turns.count) turn(s), \(assembly.speakers.count) speaker(s), \
            \(assembly.wordCount) words, diarized \(diarized != nil) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s
            """)
        if !isTwoChannel, let diarized, let voiceSignatureStore, Entitlements.has(.voiceSignatures),
           let speakers = try? store.noteSpeakers(noteId: id) {
            await yield()
            await suggestVoiceMatches(
                noteId: id, insertedSpeakers: speakers, labels: assembly.speakers.map(\.diarizerLabel), diarized: diarized,
                range: { try audio.range(side, $0, $1) }, store: store, voiceSignatureStore: voiceSignatureStore)
        }
        return true
    }

    /// Matches each newly-inserted speaker's averaged embedding against the saved voice library
    /// and records an unconfirmed suggestion for any match at or above
    /// `VoiceMatcher.defaultThreshold` — never links `voiceId` directly (see `Store
    /// .suggestSpeakerVoice`'s doc comment). Pro-gated by the caller (`Entitlements
    /// .has(.voiceSignatures)`), and a pure best-effort step: any failure here is logged and never
    /// affects the note or the segments already saved above.
    private func suggestVoiceMatches(
        noteId: Int64, insertedSpeakers: [NoteSpeaker], labels: [String], diarized: DiarizedAudio,
        range: (Double, Double) throws -> [Float], store: Store, voiceSignatureStore: VoiceSignatureStore
    ) async {
        do {
            let voices = try store.voices()
            guard !voices.isEmpty else { return }
            let decodedVoices: [(id: Int64, name: String, embedding: [Float])] = try voices.compactMap { voice in
                guard let id = voice.id else { return nil }
                let embedding = try voiceSignatureStore.decrypt(voice.encryptedEmbedding)
                return (id, voice.name, embedding)
            }

            let averaged = try await speakerEmbeddings(diarized, range: range)
            // `insertedSpeakers[i]` is "Speaker i+1", built from `labels[i]` in `diarizeAndSave`.
            for (speaker, label) in zip(insertedSpeakers, labels) {
                guard let speakerId = speaker.id, speaker.voiceId == nil, let embedding = averaged[label] else { continue }
                guard let match = VoiceMatcher.bestMatch(for: embedding, among: decodedVoices) else { continue }
                try store.suggestSpeakerVoice(id: speakerId, voiceId: match.id, similarity: Double(match.similarity))
                log.notice("note \(noteId) speaker \(speakerId) suggested match: voice \(match.id) (similarity \(String(format: "%.2f", match.similarity)))")
            }
        } catch {
            log.error("voice matching for note \(noteId) failed, segments remain usable: \(error.localizedDescription)")
        }
    }

    /// Extracts a single 256-d L2-normalized speaker embedding from `samples` (16 kHz mono),
    /// loading the diarizer's models on first use exactly like `diarizeAndSave`. Used by
    /// `VoiceEnrollment` (via `TuneModel`) to turn a clean Tune take into an embedding — the same
    /// FluidAudio embedding space diarization itself clusters into, so a saved voice's signature
    /// is directly comparable to a diarized speaker's averaged embedding
    /// (`DiarizedSpeakerEmbeddings.averageEmbeddings`).
    func extractEmbedding(samples: [Float]) async throws -> [Float] {
        let manager = try await loadedManager()
        return try manager.extractSpeakerEmbedding(from: samples)
    }

    /// `extractEmbedding` for the "remember this voice" action, which must never trigger a model
    /// download: throws `modelsNotCached` unless the models are already loaded or on disk (they are
    /// for any note that has speakers, because diarizing it put them there).
    func extractEmbeddingFromCachedModels(samples: [Float]) async throws -> [Float] {
        if manager == nil, !Self.modelsAreCached { throw DiarizerError.modelsNotCached }
        return try await extractEmbedding(samples: samples)
    }

    private static var modelsAreCached: Bool {
        let folder = DiarizerModels.defaultModelsDirectory()
        return DiarizerModels.requiredModelNames.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    /// Loads (downloading on first use) FluidAudio's diarizer models, reusing them for every
    /// subsequent call. `DiarizerManager` is a non-`Sendable` class, so it cannot be handed back
    /// through a `Task<DiarizerManager, Error>.value` (that would require crossing an isolation
    /// boundary with a non-Sendable value); instead this method is itself `async` and does the
    /// download/initialize inline, relying on this type being an actor for serialization — two
    /// overlapping calls simply run this method's `await` points one after another rather than
    /// as a true single in-flight task, which is an acceptable simplification since Hushy only
    /// ever finalizes one note's diarization at a time in practice (notes record sequentially).
    private func loadedManager() async throws -> DiarizerManager {
        if let manager { return manager }
        let models = try await downloadLegacyModels()
        let manager = DiarizerManager(config: SpeakerDiarizerConstants.diarizerConfig)
        manager.initialize(models: models)
        self.manager = manager
        legacyLoad.succeeded()
        return manager
    }

    /// `loadedManager` for a finished meeting. While a failed load is backing off (`ModelLoadBackoff`) it throws at
    /// once, so an offline Mac does not try the download again for every meeting. Tune's own enrollment still tries.
    private func meetingManager() async throws -> DiarizerManager {
        if let manager { return manager }
        guard legacyLoad.mayTry(at: now()) else { throw DiarizerError.modelsBackingOff }
        do {
            return try await loadedManager()
        } catch {
            legacyLoad.failed(at: now())
            log.error("the legacy diarizer did not load (\(error.localizedDescription)); meetings try again after \(self.legacyLoad.retryAt?.formatted() ?? "-", privacy: .public)")
            throw error
        }
    }

    /// Finds who spoke when on one side with `SpeakerDiarizerConstants.engine`, window by window and yielding to any
    /// dictation between windows; falls back to the legacy diarizer (which needs the whole side at once) when the
    /// chosen engine fails or finds no one speaking.
    private func diarize(_ audio: SideAudio, side: CaptureStream, noteId: Int64, yield: @escaping @Sendable () async -> Void) async throws -> DiarizedAudio {
        var nemotronTurns: [DiarizationTurn]?
        if SpeakerDiarizerConstants.engine == .nemotron3 {
            // The legacy models stay on disk for "remember this voice" and give the voice embeddings.
            _ = try await meetingManager()
            nemotronTurns = await self.nemotronTurns(audio.windows(side), noteId: noteId, yield: yield)
        }
        if let turns = Self.usable(nemotronTurns, noteId: noteId) { return DiarizedAudio(turns: turns, perTurnEmbeddings: nil) }
        await yield()
        return try await legacyDiarize(try audio.whole(side))
    }

    /// Nemotron's turns when it found at least one; nil sends the note to the legacy diarizer. An
    /// empty answer is not trusted: a recorded note with no speaker at all is far likelier a miss.
    static func usable(_ turns: [DiarizationTurn]?, noteId: Int64) -> [DiarizationTurn]? {
        guard let turns else { return nil }
        guard !turns.isEmpty else {
            Logger(subsystem: "app.hushy", category: "diarization")
                .notice("Nemotron 3 found no speaker turns in note \(noteId); using the legacy diarizer")
            return nil
        }
        return turns
    }

    /// nil when Nemotron could not load or run. One session per note over the shared models, so a second note that
    /// starts while this one waits for a dictation cannot touch its speaker state.
    private func nemotronTurns(
        _ windows: AsyncThrowingStream<[Float], any Error>, noteId: Int64, yield: @escaping @Sendable () async -> Void
    ) async -> [DiarizationTurn]? {
        guard let models = await loadedNemotronModels() else { return nil }
        let config = SpeakerDiarizerConstants.nemotronConfig
        let session = NemotronStreamingSession(diarizer: Nemotron3Diarizer(config: config, models: models))
        do {
            let result = try await StreamedDiarization.run(windows, session: session, yield: yield)
            let segments = Nemotron3Diarizer.segments(
                probabilities: result.probabilities, frameCount: result.frames, numSpeakers: config.numSpeakers,
                threshold: SpeakerDiarizerConstants.nemotronSpeechThreshold)
            log.notice("Nemotron 3 streamed note \(noteId): \(result.windows) window(s), \(result.frames) frame(s)")
            return segments.map { DiarizationTurn(speakerLabel: "S\($0.speakerIndex + 1)", start: Double($0.startSeconds), end: Double($0.endSeconds)) }
        } catch {
            log.error("Nemotron 3 diarization for note \(noteId) failed, using the legacy diarizer: \(error.localizedDescription)")
            return nil
        }
    }

    private func legacyDiarize(_ samples: [Float]) async throws -> DiarizedAudio {
        let segments = try await meetingManager()
            .performCompleteDiarization(samples, sampleRate: Int(SpeakerDiarizerConstants.sampleRate)).segments
        let embeddings = segments.map {
            LabeledEmbedding(
                speakerLabel: $0.speakerId, embedding: $0.embedding,
                durationSeconds: Double($0.endTimeSeconds - $0.startTimeSeconds))
        }
        return DiarizedAudio(turns: segments.map(Self.turn), perTurnEmbeddings: embeddings)
    }

    private static func turn(_ segment: TimedSpeakerSegment) -> DiarizationTurn {
        DiarizationTurn(speakerLabel: segment.speakerId, start: Double(segment.startTimeSeconds), end: Double(segment.endTimeSeconds))
    }

    /// One embedding per speaker label in the legacy WeSpeaker space saved voices are stored in.
    /// The legacy diarizer gives one per turn; for another engine each speaker's clean turns are
    /// picked the way "remember this voice" picks them, read from disk range by range (`range`, seconds on the note
    /// clock), and embedded with the legacy model.
    private func speakerEmbeddings(_ diarized: DiarizedAudio, range: (Double, Double) throws -> [Float]) async throws -> [String: [Float]] {
        if let perTurn = diarized.perTurnEmbeddings { return DiarizedSpeakerEmbeddings.averageEmbeddings(by: perTurn) }
        let manager = try await meetingManager()
        var labeled: [LabeledEmbedding] = []
        for label in orderedDistinctLabels(diarized.turns.map(\.speakerLabel)) {
            let own = diarized.turns.filter { $0.speakerLabel == label }.map { SpeechRange(start: $0.start, end: $0.end) }
            let others = diarized.turns.filter { $0.speakerLabel != label }.map { SpeechRange(start: $0.start, end: $0.end) }
            guard case .ready(let ranges, _) = SpeakerVoiceSampling.select(own: own, others: others) else { continue }
            for speech in ranges {
                let samples = try range(speech.start, speech.end)
                guard !samples.isEmpty else { continue }
                let embedding = try manager.extractSpeakerEmbedding(from: samples)
                labeled.append(LabeledEmbedding(speakerLabel: label, embedding: embedding, durationSeconds: speech.duration))
            }
        }
        return DiarizedSpeakerEmbeddings.averageEmbeddings(by: labeled)
    }

    /// Loads (downloading the 190 MB preset on first use) Nemotron 3's models, reused for every later note.
    /// nil while a failed load is backing off (`ModelLoadBackoff`), so an offline Mac does not try
    /// the download again for every note.
    private func loadedNemotronModels() async -> Nemotron3Models? {
        if let nemotron { return nemotron.models }
        guard nemotronLoad.mayTry(at: now()) else { return nil }
        do {
            let loaded = try await Self.loadNemotron(SpeakerDiarizerConstants.nemotronConfig)
            nemotron = loaded
            nemotronLoad.succeeded()
            return loaded.models
        } catch {
            nemotronLoad.failed(at: now())
            log.error("Nemotron 3 did not load (\(error.localizedDescription)); the legacy diarizer runs until \(self.nemotronLoad.retryAt?.formatted() ?? "-", privacy: .public)")
            return nil
        }
    }

    /// Loads off the actor and hands the models over in a box: FluidAudio's types are not
    /// `Sendable`, and after this the actor is the only one that touches them.
    private static func loadNemotron(_ config: Nemotron3Config) async throws -> LoadedNemotron {
        LoadedNemotron(models: try await Nemotron3Models.loadFromHuggingFace(config: config))
    }

    private final class LoadedNemotron: @unchecked Sendable {
        let models: Nemotron3Models
        init(models: Nemotron3Models) { self.models = models }
    }

    /// Finds every `chunk-NNNN<suffix>.wav`(`.enc`) file under `audioPath`, in chunk order.
    /// `suffix` is `""` for the mic stream or `"-system"` for the system-audio stream — passing
    /// the wrong one is how the two streams stay from ever being cross-contaminated when both
    /// exist side by side in the same note folder.
    static func chunkFileURLs(audioPath: String, suffix: String) throws -> [URL] {
        let folder = URL(fileURLWithPath: audioPath, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }
        let expectedSuffix = suffix + ".wav"
        return files
            .filter { url in
                let ext = url.pathExtension.lowercased()
                let base = ext == "enc" ? url.deletingPathExtension() : url
                guard base.pathExtension.lowercased() == "wav" else { return false }
                let name = base.lastPathComponent.lowercased()
                // The mic stream's "chunk-0004.wav" must not pick up the call side's "chunk-0004-system.wav".
                return name.hasSuffix(expectedSuffix) && name.hasPrefix("chunk-")
                    && (!suffix.isEmpty || !name.hasSuffix("-system.wav"))
            }
            .map { $0.pathExtension.lowercased() == "enc" ? $0.deletingPathExtension() : $0 }
            .reduce(into: [URL]()) { result, url in if !result.contains(url) { result.append(url) } }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Distinct labels in first-appearance order, so "Speaker 1" is whichever cluster spoke
    /// first in the note (a more useful default than an arbitrary/alphabetical assignment).
    private func orderedDistinctLabels(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for label in labels where !seen.contains(label) {
            seen.insert(label)
            ordered.append(label)
        }
        return ordered
    }
}

/// When to try a model load again after one failed (an offline first download): not for every note.
/// The wait triples from ten minutes up to six hours; a load that works clears it.
struct ModelLoadBackoff: Equatable {
    static let firstWait: TimeInterval = 10 * 60
    static let longestWait: TimeInterval = 6 * 3600

    private(set) var failures = 0
    private(set) var retryAt: Date?

    func mayTry(at now: Date) -> Bool { retryAt.map { now >= $0 } ?? true }

    mutating func failed(at now: Date) {
        failures += 1
        let wait = min(Self.firstWait * pow(3, Double(failures - 1)), Self.longestWait)
        retryAt = now.addingTimeInterval(wait)
    }

    mutating func succeeded() {
        failures = 0
        retryAt = nil
    }
}

/// A note's speaker turns. `perTurnEmbeddings` is the legacy diarizer's own per-turn voice
/// embeddings; `nil` when another engine found the turns and none come for free.
struct DiarizedAudio {
    let turns: [DiarizationTurn]
    let perTurnEmbeddings: [LabeledEmbedding]?
}

/// The pipeline that finds who spoke when in a note.
enum MeetingDiarizationEngine {
    /// FluidAudio `DiarizerManager`: pyannote-3 segmentation, WeSpeaker, online clustering.
    case legacy
    /// NVIDIA Nemotron 3 Diarization through FluidAudio's `Nemotron3Diarizer`: an end-to-end
    /// model with a speaker cache, at most 8 speakers, on the Neural Engine.
    case nemotron3
}

enum SpeakerDiarizerConstants {
    static let sampleRate: Double = 16_000

    /// Measured on AMI single distant mic (16 test meetings), NOTSOFAR-1 eval and VoxConverse test:
    /// `docs/research/diarizer-bakeoff-2026-11-06.md`. `.legacy` stays the fallback.
    static let engine: MeetingDiarizationEngine = .nemotron3

    /// 10.24 s of audio per call on the Neural Engine. As accurate as the GPU-only `offline` preset
    /// in the bakeoff, and it leaves the GPU to the summary model that runs right after.
    static let nemotronConfig = Nemotron3Config.fast128

    /// A frame belongs to a speaker above this probability. FluidAudio's default is 0.5; 0.3 marked
    /// more quiet far-field speech on the AMI dev meetings (DER 21.1% to 20.0%) with no added confusion.
    static let nemotronSpeechThreshold: Float = 0.3

    /// Tuned clustering config, per `Evals/results.md`'s 2026-09-26 diarization tuning entry:
    /// searched on half of AMI (`dev.mini`) and half of VoxConverse's fixed dev subset, reported
    /// on the other, held-out half of each. `clusteringThreshold 0.65` (down from FluidAudio's
    /// default 0.7) and `minSpeechDuration 0.5s` (down from the default 1.0s) reduced AMI SDM
    /// (far-field) held-out DER from 40.7% to 28.2% and VoxConverse held-out DER from 19.3% to
    /// 12.9% — a real improvement on both datasets, not a trade-off between them.
    /// `minSilenceGap`/`numClusters` are left at FluidAudio's defaults (0.5s / auto): the same
    /// tuning pass found no measurable effect from `minSilenceGap` on this offline pipeline.
    static var diarizerConfig: DiarizerConfig {
        var config = DiarizerConfig.default
        config.clusteringThreshold = DiarizerTuning.clusteringThreshold
        config.minSpeechDuration = DiarizerTuning.minSpeechDuration
        return config
    }
}
