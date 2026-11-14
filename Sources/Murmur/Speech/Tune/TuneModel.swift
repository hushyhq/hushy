import AppKit
import FluidAudio
import Foundation
import MurmurCore
import Observation
import os

/// Drives "Tune Hushy to your voice": up to 5 user terms, 4 short read-aloud sentences plus a
/// 2 s silent room-tone capture, then an auto-tune sweep across {model v2, ultra} x {boosting
/// on, off} scored against the known sentences. Recording goes through the exact production
/// `AudioCapture` (voice processing off, per .claude/DECISIONS.md), matching `VoiceLabModel`.
///
/// The sweep uses its own private `SpeechEngine` instances rather than the app's shared one —
/// the shared engine holds exactly one loaded model at a time (see `SpeechEngine.prepare`), and
/// swapping it mid-sweep would leave the wrong model loaded for live dictation afterward.
@MainActor
@Observable
final class TuneModel {
    enum Phase: Equatable {
        case namingTerms
        case recording
        case roomTone
        case scoring
        case result
        case failed(String)
    }

    private(set) var phase: Phase = .namingTerms
    private(set) var sentences: [TuneSentence] = []
    private(set) var currentIndex = 0
    private(set) var isRecording = false
    private(set) var level: Float = 0
    private(set) var pendingTake: PendingTake?
    private(set) var scoringProgress: (done: Int, total: Int) = (0, 4)
    private(set) var winningCandidate: TuneCandidate?
    private(set) var sentenceScores: [TuneSentenceScore] = []
    private(set) var mishearings: [TuneMishearing] = []
    private(set) var calibration: VoiceCalibration?
    private(set) var addedDictionaryTerms: Set<String> = []
    /// Voice-signature enrollment state (Pro feature), driven by the result step's
    /// `VoiceEnrollmentCard`. Nil `enrollmentError` + `!isEnrolling` + no `enrolledVoice` means
    /// "not yet attempted" — the card always starts by asking for consent
    /// (`VoiceEnrollmentConsent`), never enrolling silently just because Tune finished.
    private(set) var isEnrolling = false
    private(set) var enrolledVoice: Voice?
    private(set) var enrollmentError: String?

    /// Up to 5 names/terms the user typed, prefilled from the existing Dictionary by the view.
    var terms: [String] = ["", "", "", "", ""]

    @ObservationIgnored private let audio = AudioCapture()
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let store: Store
    @ObservationIgnored private let voiceSignatureStore: VoiceSignatureStore
    @ObservationIgnored private let diarizer = SpeakerDiarizer()
    @ObservationIgnored private let log = Logger(subsystem: "app.hushy", category: "tune")
    @ObservationIgnored private var takes: [TuneSentence.Kind: [Float]] = [:]
    @ObservationIgnored private var roomTone: [Float] = []
    @ObservationIgnored private(set) var sessionDirectory: URL

    struct PendingTake {
        let samples: [Float]
        let peak: Float
        let rms: Float
    }

    var currentSentence: TuneSentence? {
        sentences.indices.contains(currentIndex) ? sentences[currentIndex] : nil
    }

    var progressText: String { "\(min(currentIndex + 1, sentences.count))/\(sentences.count)" }

    init(settings: AppSettings, store: Store, voiceSignatureStore: VoiceSignatureStore) {
        self.settings = settings
        self.store = store
        self.voiceSignatureStore = voiceSignatureStore
        sessionDirectory = VoiceLabStorage.root.deletingLastPathComponent()
            .appendingPathComponent("tune-\(Self.dateStamp())", isDirectory: true)
    }

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }

    // MARK: Step 1 — terms

    func startRecording() {
        sentences = TuneSentenceBuilder.build(terms: terms)
        currentIndex = 0
        phase = .recording
        beginCapture()
    }

    // MARK: Step 2 — 4 sentences

    private func beginCapture() {
        pendingTake = nil
        level = 0
        MicrophoneSelector.shared.prepare(audio, picked: settings.inputDeviceName)
        // Voice processing off for every take: see .claude/DECISIONS.md — the production
        // default, and the setting these scores must reflect.
        audio.voiceProcessing = false
        do {
            try audio.start { [weak self] rms in
                Task { @MainActor in self?.level = rms }
            }
            isRecording = true
        } catch {
            log.error("Tune capture failed to start: \(error.localizedDescription)")
            phase = .failed("Couldn't start the microphone.")
        }
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            beginCapture()
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        let samples = audio.stop()
        guard !samples.isEmpty else { return }
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        let rms = StreamingResampler.rms(samples)
        pendingTake = PendingTake(samples: samples, peak: peak, rms: rms)
    }

    func keepPendingTake() {
        guard let pending = pendingTake, let sentence = currentSentence else { return }
        takes[sentence.id] = pending.samples
        pendingTake = nil
        advanceSentence()
    }

    func discardPendingTake() {
        pendingTake = nil
    }

    private func advanceSentence() {
        guard currentIndex + 1 < sentences.count else {
            phase = .roomTone
            return
        }
        currentIndex += 1
        beginCapture()
    }

    // MARK: Step 3 — room tone

    /// Captures 2 s of silence for the noise floor, then runs the sweep.
    func captureRoomTone() {
        do {
            try audio.start { [weak self] rms in
                Task { @MainActor in self?.level = rms }
            }
            isRecording = true
        } catch {
            phase = .failed("Couldn't start the microphone.")
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                self.roomTone = self.audio.stop()
                self.isRecording = false
            }
            await self.runSweep()
        }
    }

    // MARK: Step 4 — auto-tune sweep

    private func runSweep() async {
        phase = .scoring
        scoringProgress = (0, TuneCandidate.sweepOrder.count)
        var results: [TuneCandidateResult] = []
        for (index, candidate) in TuneCandidate.sweepOrder.enumerated() {
            do {
                let transcripts = try await transcribeAll(with: candidate)
                results.append(TuneCandidateResult(candidate: candidate, transcripts: transcripts))
            } catch {
                log.error("Tune sweep candidate \(candidate.model.rawValue, privacy: .public) failed: \(error.localizedDescription)")
            }
            scoringProgress = (index + 1, TuneCandidate.sweepOrder.count)
        }

        guard let best = TuneScorer.pickBest(results, sentences: sentences) else {
            phase = .failed("Couldn't score any configuration — try again.")
            return
        }
        winningCandidate = best.candidate
        sentenceScores = best.scores

        if let bestTranscripts = results.first(where: { $0.candidate == best.candidate })?.transcripts {
            mishearings = sentences.flatMap { sentence -> [TuneMishearing] in
                guard let heard = bestTranscripts[sentence.id] else { return [] }
                return TuneScorer.mishearings(expected: sentence.expected, heard: heard)
            }
        }

        calibration = VoiceCalibration.from(
            roomTone: roomTone,
            speechTakes: sentences.filter { !$0.isWhisper }.compactMap { takes[$0.id] },
            whisperTake: sentences.first { $0.isWhisper }.flatMap { takes[$0.id] } ?? [])
        settings.voiceCalibration = calibration

        saveSession()
        phase = .result
    }

    /// Transcribes every take through a candidate config, using a private `SpeechEngine`
    /// instance per model version (loaded once per version regardless of boosting on/off, since
    /// the model itself doesn't change — only whether a vocabulary is passed).
    private func transcribeAll(with candidate: TuneCandidate) async throws -> [TuneSentence.Kind: String] {
        let engine = try await engine(for: candidate.model)
        let vocabulary = candidate.boosting
            ? VocabularyContext(terms: terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.map { VocabularyTerm(text: $0) })
            : VocabularyContext.empty
        var transcripts: [TuneSentence.Kind: String] = [:]
        for sentence in sentences {
            guard let samples = takes[sentence.id] else { continue }
            let normalized = LoudnessNormalizer.normalize(samples)
            transcripts[sentence.id] = try await engine.transcribe(normalized, vocabulary: vocabulary)
        }
        return transcripts
    }

    @ObservationIgnored private var enginesByVersion: [TuneCandidate.Model: SpeechEngine] = [:]

    private func engine(for model: TuneCandidate.Model) async throws -> SpeechEngine {
        if let existing = enginesByVersion[model] { return existing }
        let version: AsrModelVersion = model == .v2 ? .v2 : .ultra
        let engine = SpeechEngine(status: SpeechModelStatus())
        try await engine.prepare(version: version)
        enginesByVersion[model] = engine
        return engine
    }

    // MARK: Persistence — Voice Lab-compatible sidecars

    /// Saves the 4 takes + sidecars under `tune-<date>/` in the same format Voice Lab uses, so
    /// `murmur-eval voicelab --dir` can score this session later.
    private func saveSession() {
        for sentence in sentences {
            guard let samples = takes[sentence.id] else { continue }
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
            let rms = StreamingResampler.rms(samples)
            let take = VoiceLabTake(
                promptID: sentence.id.rawValue, category: "tune", style: sentence.isWhisper ? .whisper : .normal,
                timestamp: Date(), deviceName: settings.inputDeviceName ?? "System default",
                voiceProcessingEnabled: false, osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                capturePeak: peak, captureRMS: rms, durationSeconds: Double(samples.count) / AudioCapture.sampleRate)
            let base = sessionDirectory.appendingPathComponent(sentence.id.rawValue)
            do {
                try WAVWriter.write(samples, to: base.appendingPathExtension("wav"))
                try VoiceLabStorage.write(take, to: base.appendingPathExtension("json"))
            } catch {
                log.error("Tune session save failed for \(sentence.id.rawValue, privacy: .public): \(error.localizedDescription)")
            }
        }
    }

    // MARK: Mishearing chips

    func addToDictionary(_ mishearing: TuneMishearing) {
        let capitalized = mishearing.expectedWord.prefix(1).uppercased() + mishearing.expectedWord.dropFirst()
        _ = try? store.save(DictionaryEntry(term: capitalized, soundsLike: [mishearing.heardWord]))
        addedDictionaryTerms.insert(mishearing.id)
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(sessionDirectory)
    }

    var whisperTakeSentence: TuneSentence? { sentences.first { $0.isWhisper } }

    // MARK: Voice signature enrollment (Pro)

    /// Enrolls (or re-enrolls, replacing any existing "You" voice) the user's own voice signature
    /// from this session's Tune takes, per this task's requirement: "the user's own signature is
    /// enrolled from the Tune recordings, with consent text." The caller (`VoiceEnrollmentCard`)
    /// is responsible for showing `VoiceEnrollmentConsent` and only calling this after the user
    /// agrees — this method itself does not gate on consent, since consent is a UI-level decision
    /// this model has no way to verify was actually shown.
    func enrollYouVoice() {
        guard !isEnrolling else { return }
        isEnrolling = true
        enrollmentError = nil
        let rawTakes = Array(takes.values)
        let extractor = diarizer
        let signatureStore = voiceSignatureStore
        let db = store
        Task {
            do {
                let embedding = try await VoiceEnrollment.enroll(takes: rawTakes) { samples in
                    try await extractor.extractEmbedding(samples: samples)
                }
                let encrypted = try signatureStore.encrypt(embedding)
                let voice = Voice(name: "You", isYou: true, encryptedEmbedding: encrypted, sampleCount: rawTakes.count)
                let saved = try db.saveVoice(voice)
                await MainActor.run {
                    self.enrolledVoice = saved
                    self.isEnrolling = false
                }
            } catch {
                await MainActor.run {
                    self.enrollmentError = error.localizedDescription
                    self.isEnrolling = false
                }
                self.log.error("voice enrollment failed: \(error.localizedDescription)")
            }
        }
    }
}

extension TuneModel {
    /// Snapshot-only: puts the model on its result step with canned transcripts, so the result
    /// layout can be captured without a microphone, an engine or any file written. Scores and
    /// mishearings come from the same scorer a real run uses.
    func pinResultForSnapshot(transcripts: [TuneSentence.Kind: String], calibration: VoiceCalibration?) {
        let candidate = TuneCandidate.sweepOrder[0]
        sentences = TuneSentenceBuilder.build(terms: terms)
        let result = TuneCandidateResult(candidate: candidate, transcripts: transcripts)
        guard let best = TuneScorer.pickBest([result], sentences: sentences) else { return }
        winningCandidate = best.candidate
        sentenceScores = best.scores
        mishearings = sentences.flatMap { sentence -> [TuneMishearing] in
            guard let heard = transcripts[sentence.id] else { return [] }
            return TuneScorer.mishearings(expected: sentence.expected, heard: heard)
        }
        self.calibration = calibration
        phase = .result
    }
}
