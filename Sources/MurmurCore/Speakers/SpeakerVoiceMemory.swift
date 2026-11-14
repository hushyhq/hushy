import Foundation

/// Which retained recording track holds a speaker's voice.
public enum SpeakerAudioStream: Sendable, Equatable {
    /// The single mixed track of a one-stream note.
    case mic
    /// The system-audio track of a two-channel note, where everyone but the note owner is heard.
    case system
}

/// The audio-to-embedding step, kept behind a protocol so nothing here needs a model or a file: the
/// app implements it with the diarizer, tests with canned vectors.
public protocol SpeakerVoiceEmbedder: Sendable {
    /// The track other people's voices are on, or `nil` when the note's audio is gone.
    func audioStream(for note: Note) -> SpeakerAudioStream?
    /// One embedding per range, in order (an empty array for a range that could not be read).
    func embeddings(note: Note, stream: SpeakerAudioStream, ranges: [SpeechRange]) async throws -> [[Float]]
}

public enum RememberVoiceOutcome: Equatable, Sendable {
    /// Saved (or folded into the same-named voice already saved) and linked to the speaker.
    case remembered(voiceId: Int64, updatedExisting: Bool)
    /// Nothing was stored; the message is the one line to show.
    case declined(String)
}

public enum ReinforceOutcome: Equatable, Sendable {
    case folded(sampleCount: Int)
    /// Not folded in (no audio, too little speech, or the sample did not sound like the saved voice). Never an error.
    case skipped
}

/// Learns a named speaker's voice from a note's retained audio, with the user's explicit say-so, and
/// keeps a remembered voice up to date when the user confirms a later match. Embeddings are encrypted
/// before they reach the store and are never logged or put into messages.
public struct SpeakerVoiceMemory: Sendable {
    /// A confirmed sample is folded in only when it sounds at least this much like the saved voice;
    /// a lower score means the confirm was a mistake or the clip is poor, and either would smear the voice.
    public static let minimumFoldSimilarity: Float = 0.6
    /// The saved voice counts as at most this many samples when averaging, so a long-established
    /// voice still follows how the person sounds now.
    public static let maximumExistingWeight = 10

    static let audioGoneMessage = RememberVoiceAvailability.audioGoneMessage
    static let failedMessage = "Couldn't read this speaker's audio. Nothing was saved."
    static let notNamedMessage = "Give this speaker a name first. Nothing was saved."

    private let store: Store
    private let signatures: VoiceSignatureStore
    private let embedder: any SpeakerVoiceEmbedder

    public init(store: Store, signatures: VoiceSignatureStore, embedder: some SpeakerVoiceEmbedder) {
        self.store = store
        self.signatures = signatures
        self.embedder = embedder
    }

    /// The track to use for `speaker` in `note`, or `nil` when it cannot be used.
    public func availability(of speaker: NoteSpeaker, in speakers: [NoteSpeaker], note: Note, entitled: Bool)
        -> RememberVoiceAvailability {
        RememberVoiceAvailability.evaluate(
            speaker: speaker, in: speakers, audioStream: embedder.audioStream(for: note), entitled: entitled)
    }

    // MARK: Remember

    /// The user chose "Remember <name>'s voice". Computes the speaker's embedding from this note's audio,
    /// encrypts it, saves it as a voice (or folds it into the same-named one) and links the speaker.
    public func remember(speakerId: Int64) async -> RememberVoiceOutcome {
        guard let context = loadContext(speakerId: speakerId) else { return .declined(Self.failedMessage) }
        guard context.speaker.hasRealName, context.speaker.voiceId == nil, context.speaker.hasGenericLabel else {
            return .declined(Self.notNamedMessage)
        }
        switch await averagedEmbedding(context) {
        case .failure(let message): return .declined(message)
        case .success(let embedding): return save(embedding, for: context.speaker)
        }
    }

    private func save(_ embedding: [Float], for speaker: NoteSpeaker) -> RememberVoiceOutcome {
        guard let speakerId = speaker.id, let name = speaker.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return .declined(Self.failedMessage) }
        do {
            if let existing = try sameNamedVoice(name), let existingId = existing.id,
               let folded = try folded(embedding, into: existing) {
                try store.updateVoiceEmbedding(
                    id: existingId, encryptedEmbedding: folded.data, sampleCount: existing.sampleCount + 1)
                try store.setSpeakerVoice(id: speakerId, voiceId: existingId)
                return .remembered(voiceId: existingId, updatedExisting: true)
            }
            let voice = try store.saveVoice(Voice(name: name, encryptedEmbedding: try signatures.encrypt(embedding)))
            guard let voiceId = voice.id else { return .declined(Self.failedMessage) }
            try store.setSpeakerVoice(id: speakerId, voiceId: voiceId)
            return .remembered(voiceId: voiceId, updatedExisting: false)
        } catch {
            return .declined(Self.failedMessage)
        }
    }

    /// A saved voice (never the reserved "You" one) already carrying this name, ignoring case and spacing.
    private func sameNamedVoice(_ name: String) throws -> Voice? {
        let wanted = name.lowercased()
        return try store.voices().first {
            !$0.isYou && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted
        }
    }

    // MARK: Reinforce

    /// A suggestion was confirmed: recompute this speaker's embedding from the note's audio and fold it
    /// into the saved voice. The name is already applied, so every failure here is a quiet `.skipped`.
    public func reinforce(speakerId: Int64, voiceId: Int64) async -> ReinforceOutcome {
        guard let voice = try? store.voice(id: voiceId), let context = loadContext(speakerId: speakerId),
              case .success(let embedding) = await averagedEmbedding(context) else { return .skipped }
        do {
            guard let folded = try folded(embedding, into: voice) else { return .skipped }
            let sampleCount = voice.sampleCount + 1
            try store.updateVoiceEmbedding(id: voiceId, encryptedEmbedding: folded.data, sampleCount: sampleCount)
            return .folded(sampleCount: sampleCount)
        } catch {
            return .skipped
        }
    }

    /// `embedding` averaged into `voice`'s saved signature, or `nil` when it does not sound like it.
    private func folded(_ embedding: [Float], into voice: Voice) throws -> (data: Data, vector: [Float])? {
        let saved = try signatures.decrypt(voice.encryptedEmbedding)
        guard VoiceSimilarity.cosine(saved, embedding) >= Self.minimumFoldSimilarity else { return nil }
        let vector = VoiceSimilarity.weightedAverage(
            existing: saved, existingCount: min(voice.sampleCount, Self.maximumExistingWeight), new: embedding)
        return (try signatures.encrypt(vector), vector)
    }

    // MARK: Audio

    private struct Context {
        let speaker: NoteSpeaker
        let note: Note
        let own: [SpeechRange]
        let others: [SpeechRange]
        let stream: SpeakerAudioStream?
    }

    private enum Averaged {
        case success([Float])
        case failure(String)
    }

    private func loadContext(speakerId: Int64) -> Context? {
        guard let speaker = try? store.noteSpeaker(id: speakerId),
              let note = try? store.note(id: speaker.noteId),
              let rows = try? store.noteSegments(noteId: speaker.noteId) else { return nil }
        let ownerTrack = Set(rows.compactMap(\.speaker).filter { !$0.hasGenericLabel }.compactMap(\.id))
        // A two-channel note (it has an owner track) holds everyone else on the system stream only;
        // the mic track would be the owner's voice, never to be learned under someone else's name.
        let found = embedder.audioStream(for: note)
        let stream = (!ownerTrack.isEmpty && found != .system) ? nil : found
        func range(_ row: NoteSegmentWithSpeaker) -> SpeechRange {
            SpeechRange(start: row.segment.startTime, end: row.segment.endTime)
        }
        let own = rows.filter { $0.segment.speakerId == speakerId }.map(range)
        // On the system stream the owner's mic speech is on another track, so it cannot contaminate.
        let others = rows.filter { row in
            guard let other = row.segment.speakerId, other != speakerId else { return false }
            return !(stream == .system && ownerTrack.contains(other))
        }.map(range)
        return Context(speaker: speaker, note: note, own: own, others: others, stream: stream)
    }

    private func averagedEmbedding(_ context: Context) async -> Averaged {
        guard let stream = context.stream else { return .failure(Self.audioGoneMessage) }
        guard case .ready(let ranges, _) = SpeakerVoiceSampling.select(own: context.own, others: context.others) else {
            return .failure(SpeakerVoiceSampling.tooLittleMessage)
        }
        guard let vectors = try? await embedder.embeddings(note: context.note, stream: stream, ranges: ranges) else {
            return .failure(Self.failedMessage)
        }
        let labelled = zip(ranges, vectors).map {
            LabeledEmbedding(speakerLabel: "speaker", embedding: $1, durationSeconds: $0.duration)
        }
        guard let average = DiarizedSpeakerEmbeddings.averageEmbeddings(by: labelled)["speaker"] else {
            return .failure(Self.failedMessage)
        }
        return .success(average)
    }
}
