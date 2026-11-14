import Foundation
import Testing
@testable import MurmurCore

/// A stand-in for the diarizer's audio-to-embedding step: returns canned vectors and records what it
/// was asked for, so these tests never touch audio or a model.
final class FakeVoiceEmbedder: SpeakerVoiceEmbedder, @unchecked Sendable {
    var stream: SpeakerAudioStream? = .mic
    var vector: [Float] = [1, 0, 0, 0]
    var failure: Error?
    private(set) var requests: [[SpeechRange]] = []

    func audioStream(for note: Note) -> SpeakerAudioStream? { stream }

    func embeddings(note: Note, stream: SpeakerAudioStream, ranges: [SpeechRange]) async throws -> [[Float]] {
        requests.append(ranges)
        if let failure { throw failure }
        return ranges.map { _ in vector }
    }
}

@Suite("Remembering and reinforcing a speaker's voice")
struct SpeakerVoiceMemoryTests {
    struct Fixture {
        let store: Store
        let signatures: VoiceSignatureStore
        let embedder: FakeVoiceEmbedder
        let memory: SpeakerVoiceMemory
        let noteId: Int64
        let danaId: Int64
        let otherId: Int64
    }

    /// A note where Speaker 1 talks for `danaSeconds` then Speaker 2 for 20 s; Speaker 1 is named "Dana".
    private func makeFixture(danaSeconds: Double = 30, danaName: String? = "Dana") throws -> Fixture {
        let store = try Store()
        let note = try store.save(Note(title: "T", transcript: "t", summary: "- Speaker 1 owns QA", status: .ready, audioPath: "/tmp/none"))
        let noteId = try #require(note.id)
        let speakers = try store.replaceSpeakerSegments(
            noteId: noteId,
            speakers: [NoteSpeaker(noteId: noteId, label: "Speaker 1"), NoteSpeaker(noteId: noteId, label: "Speaker 2")],
            segments: [
                (0, AlignedSegment(speakerLabel: "S1", start: 0, end: danaSeconds, text: "a")),
                (1, AlignedSegment(speakerLabel: "S2", start: danaSeconds, end: danaSeconds + 20, text: "b")),
            ])
        let danaId = try #require(speakers[0].id)
        if let danaName { try store.renameSpeaker(id: danaId, to: danaName) }
        let signatures = VoiceSignatureStore(keyManager: EncryptionKeyManager(keyStore: InMemoryKeyStore()))
        let embedder = FakeVoiceEmbedder()
        let memory = SpeakerVoiceMemory(store: store, signatures: signatures, embedder: embedder)
        return Fixture(
            store: store, signatures: signatures, embedder: embedder, memory: memory, noteId: noteId,
            danaId: danaId, otherId: try #require(speakers[1].id))
    }

    private func linkedVoiceId(_ f: Fixture) throws -> Int64? {
        try f.store.noteSegments(noteId: f.noteId).first { $0.speaker?.id == f.danaId }?.speaker?.voiceId
    }

    // MARK: remember

    @Test("remembering stores one encrypted voice, links the speaker, and keeps the name")
    func remembersAndLinks() async throws {
        let f = try makeFixture()
        let outcome = await f.memory.remember(speakerId: f.danaId)

        guard case .remembered(let voiceId, let updatedExisting) = outcome else {
            Issue.record("expected remembered, got \(outcome)")
            return
        }
        #expect(!updatedExisting)
        let voice = try #require(try f.store.voice(id: voiceId))
        #expect(voice.name == "Dana")
        #expect(!voice.isYou)
        #expect(voice.sampleCount == 1)
        #expect(try f.signatures.decrypt(voice.encryptedEmbedding) == [1, 0, 0, 0])
        #expect(voice.encryptedEmbedding != VoiceEmbeddingCodec.encode([1, 0, 0, 0]))  // stored encrypted, not as plain floats
        #expect(try linkedVoiceId(f) == voiceId)
        let speaker = try #require(try f.store.noteSegments(noteId: f.noteId).first?.speaker)
        #expect(speaker.displayName == "Dana")
    }

    @Test("only the chosen speaker's clean speech is sent to the embedder")
    func usesOnlyThatSpeakersSpeech() async throws {
        let f = try makeFixture()
        _ = await f.memory.remember(speakerId: f.danaId)

        let requested = try #require(f.embedder.requests.first)
        #expect(!requested.isEmpty)
        for range in requested { #expect(range.end <= 30) }  // Speaker 2 starts at 30 s
    }

    @Test("too little speech declines in one line and stores nothing")
    func declinesShortSpeech() async throws {
        let f = try makeFixture(danaSeconds: 5)
        let outcome = await f.memory.remember(speakerId: f.danaId)

        guard case .declined(let message) = outcome else {
            Issue.record("expected declined, got \(outcome)")
            return
        }
        #expect(!message.isEmpty && !message.contains("\n"))
        #expect(!message.contains("Dana"))
        #expect(try f.store.voices().isEmpty)
        #expect(try linkedVoiceId(f) == nil)
        #expect(f.embedder.requests.isEmpty)
    }

    @Test("gone audio declines and stores nothing")
    func declinesWithoutAudio() async throws {
        let f = try makeFixture()
        f.embedder.stream = nil
        guard case .declined = await f.memory.remember(speakerId: f.danaId) else {
            Issue.record("expected declined")
            return
        }
        #expect(try f.store.voices().isEmpty)
    }

    @Test("an embedder failure declines without surfacing the error text or storing anything")
    func declinesOnFailure() async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "secret-detail-from-model" } }
        let f = try makeFixture()
        f.embedder.failure = Boom()
        guard case .declined(let message) = await f.memory.remember(speakerId: f.danaId) else {
            Issue.record("expected declined")
            return
        }
        #expect(!message.contains("secret-detail"))
        #expect(try f.store.voices().isEmpty)
    }

    @Test("a speaker with no real name is never remembered")
    func refusesAnUnnamedSpeaker() async throws {
        let f = try makeFixture(danaName: nil)
        guard case .declined = await f.memory.remember(speakerId: f.danaId) else {
            Issue.record("expected declined")
            return
        }
        #expect(try f.store.voices().isEmpty)
        #expect(f.embedder.requests.isEmpty)
    }

    @Test("a speaker already linked is not remembered a second time")
    func refusesALinkedSpeaker() async throws {
        let f = try makeFixture()
        _ = await f.memory.remember(speakerId: f.danaId)
        guard case .declined = await f.memory.remember(speakerId: f.danaId) else {
            Issue.record("expected declined")
            return
        }
        #expect(try f.store.voices().count == 1)
    }

    @Test("the same name remembered from another note strengthens the existing voice instead of duplicating it")
    func foldsIntoSameNameVoice() async throws {
        let f = try makeFixture()
        let existing = try f.store.saveVoice(Voice(
            name: "dana ", encryptedEmbedding: try f.signatures.encrypt([1, 0, 0, 0]), sampleCount: 2))
        f.embedder.vector = [0.8, 0.6, 0, 0]

        let outcome = await f.memory.remember(speakerId: f.danaId)

        guard case .remembered(let voiceId, let updatedExisting) = outcome else {
            Issue.record("expected remembered")
            return
        }
        #expect(updatedExisting && voiceId == existing.id)
        let voices = try f.store.voices()
        #expect(voices.count == 1)
        #expect(voices[0].sampleCount == 3)
        #expect(try linkedVoiceId(f) == voiceId)
    }

    @Test("a same-named 'You' voice is never merged into")
    func neverFoldsIntoYou() async throws {
        let f = try makeFixture()
        _ = try f.store.saveVoice(Voice(
            name: "Dana", isYou: true, encryptedEmbedding: try f.signatures.encrypt([1, 0, 0, 0])))
        _ = await f.memory.remember(speakerId: f.danaId)
        #expect(try f.store.voices().count == 2)
        #expect(try f.store.youVoice()?.sampleCount == 1)
    }

    // MARK: reinforce

    private func savedVoice(_ f: Fixture, embedding: [Float], count: Int) throws -> Voice {
        try f.store.saveVoice(Voice(
            name: "Dana", encryptedEmbedding: try f.signatures.encrypt(embedding), sampleCount: count))
    }

    @Test("a confirmed match is folded into the saved voice and counted")
    func reinforceFolds() async throws {
        let f = try makeFixture()
        let voice = try savedVoice(f, embedding: [1, 0, 0, 0], count: 3)
        f.embedder.vector = [0.8, 0.6, 0, 0]

        let outcome = await f.memory.reinforce(speakerId: f.danaId, voiceId: try #require(voice.id))

        #expect(outcome == .folded(sampleCount: 4))
        let voiceId = try #require(voice.id)
        let stored = try #require(try f.store.voice(id: voiceId))
        #expect(stored.sampleCount == 4)
        let embedding = try f.signatures.decrypt(stored.encryptedEmbedding)
        let expected = VoiceSimilarity.weightedAverage(existing: [1, 0, 0, 0], existingCount: 3, new: [0.8, 0.6, 0, 0])
        #expect(embedding == expected)
    }

    @Test("a very well-established voice still moves: the existing weight is capped")
    func reinforceCapsExistingWeight() async throws {
        let f = try makeFixture()
        let voice = try savedVoice(f, embedding: [1, 0, 0, 0], count: 500)
        f.embedder.vector = [0.8, 0.6, 0, 0]

        _ = await f.memory.reinforce(speakerId: f.danaId, voiceId: try #require(voice.id))

        let voiceId = try #require(voice.id)
        let stored = try #require(try f.store.voice(id: voiceId))
        let embedding = try f.signatures.decrypt(stored.encryptedEmbedding)
        let expected = VoiceSimilarity.weightedAverage(
            existing: [1, 0, 0, 0], existingCount: SpeakerVoiceMemory.maximumExistingWeight, new: [0.8, 0.6, 0, 0])
        #expect(embedding == expected)
        #expect(stored.sampleCount == 501)
    }

    @Test("a sample that does not sound like the saved voice is not folded in")
    func reinforceSkipsDissimilar() async throws {
        let f = try makeFixture()
        let voice = try savedVoice(f, embedding: [1, 0, 0, 0], count: 3)
        f.embedder.vector = [0, 1, 0, 0]

        let outcome = await f.memory.reinforce(speakerId: f.danaId, voiceId: try #require(voice.id))

        #expect(outcome == .skipped)
        let voiceId = try #require(voice.id)
        let stored = try #require(try f.store.voice(id: voiceId))
        #expect(stored.sampleCount == 3)
        #expect(try f.signatures.decrypt(stored.encryptedEmbedding) == [1, 0, 0, 0])
    }

    @Test("reinforcing is skipped quietly when the audio is gone or the speech is too short")
    func reinforceSkipsWithoutMaterial() async throws {
        let gone = try makeFixture()
        let voiceA = try savedVoice(gone, embedding: [1, 0, 0, 0], count: 1)
        gone.embedder.stream = nil
        #expect(await gone.memory.reinforce(speakerId: gone.danaId, voiceId: try #require(voiceA.id)) == .skipped)

        let short = try makeFixture(danaSeconds: 4)
        let voiceB = try savedVoice(short, embedding: [1, 0, 0, 0], count: 1)
        #expect(await short.memory.reinforce(speakerId: short.danaId, voiceId: try #require(voiceB.id)) == .skipped)
        #expect(short.embedder.requests.isEmpty)
        #expect(try short.store.voice(id: try #require(voiceB.id))?.sampleCount == 1)
    }

    @Test("reinforcing a voice that was forgotten meanwhile does nothing")
    func reinforceMissingVoice() async throws {
        let f = try makeFixture()
        #expect(await f.memory.reinforce(speakerId: f.danaId, voiceId: 999) == .skipped)
        #expect(try f.store.voices().isEmpty)
    }
}
