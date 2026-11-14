import Foundation

/// Consent text shown before enrolling the user's own voice signature from Tune recordings, per
/// this task's requirement ("enrolled from the Tune recordings, with consent text"). A single,
/// versioned string (not scattered inline copy) so `.claude/DECISIONS.md`'s biometric-consent
/// entry can point at exactly what the user was shown, and so a future copy change is a one-line
/// diff with an obvious audit trail (`consentVersion`).
public enum VoiceEnrollmentConsent {
    /// Bump whenever the consent copy changes materially (not for typo fixes) — see
    /// `.claude/DECISIONS.md`. Nothing currently gates on this value; it exists so a future
    /// re-consent requirement has a version to compare against.
    public static let consentVersion = 1

    public static let title = "Recognize your voice across notes"

    public static let body = """
        Hushy can remember what your voice sounds like — a small numeric signature computed \
        from the recordings you just made in Tune — so future meeting notes can automatically \
        suggest "You" instead of "Speaker 1."

        This signature is biometric data. It:
        • Stays on this Mac. It is never uploaded, and Hushy has no server to send it to.
        • Is encrypted at rest with the same key Hushy already uses to protect your recordings.
        • Is never applied silently — a match only ever appears as a suggestion you confirm.
        • Can be deleted at any time from Settings → Voices, instantly and permanently.

        You can also enroll voices for other people later, from a note's transcript, once you've \
        confirmed who they are — Hushy will never guess a name for someone it hasn't been told \
        about.
        """

    public static let declineNotice = "You can enroll your voice later from Settings → Voices."
}

/// Turns a set of Tune recordings (raw 16 kHz mono samples, one per sentence) into a single
/// averaged speaker embedding, ready for `VoiceSignatureStore.encrypt` and `Store.saveVoice`.
/// Pure orchestration over an injected embedding function so this type has no FluidAudio/CoreML
/// dependency and is unit-testable with a fake extractor.
public enum VoiceEnrollment {
    public enum EnrollmentError: Error, LocalizedError, Equatable {
        case noSamples
        case extractionFailed

        public var errorDescription: String? {
            switch self {
            case .noSamples: "No voice recordings were available to enroll."
            case .extractionFailed: "Couldn't compute a voice signature from these recordings."
            }
        }
    }

    /// Extracts one embedding per non-empty take in `takes` via `extractEmbedding`, then averages
    /// them into a single unit-normalized vector (a plain mean-then-renormalize, since every take
    /// is an equally-trusted sample of the same person's voice — no take is weighted differently
    /// just because it came from a whispered sentence, matching Tune's existing "voice processing
    /// off for every take" even-handed treatment of all takes).
    ///
    /// - Parameter minimumTakes: the fewest usable takes to accept an enrollment (default 1 —
    ///   Tune's 4 sentences are all short, but even one clean take is a usable, if lower-quality,
    ///   signature; a caller wanting a stricter bar can raise this).
    public static func enroll(
        takes: [[Float]], minimumTakes: Int = 1, extractEmbedding: ([Float]) throws -> [Float]
    ) throws -> [Float] {
        let usable = try usableTakes(takes, minimumTakes: minimumTakes)
        var embeddings: [[Float]] = []
        for take in usable {
            guard let embedding = try? extractEmbedding(take), !embedding.isEmpty else { continue }
            embeddings.append(embedding)
        }
        return try averaged(embeddings)
    }

    /// Async-extractor counterpart of `enroll(takes:minimumTakes:extractEmbedding:)`, for callers
    /// whose embedding extraction is itself `async` (e.g. `SpeakerDiarizer`, an actor) — avoids
    /// bridging an async call into a synchronous closure with a blocking semaphore.
    public static func enroll(
        takes: [[Float]], minimumTakes: Int = 1, extractEmbedding: @Sendable ([Float]) async throws -> [Float]
    ) async throws -> [Float] {
        let usable = try usableTakes(takes, minimumTakes: minimumTakes)
        var embeddings: [[Float]] = []
        for take in usable {
            guard let embedding = try? await extractEmbedding(take), !embedding.isEmpty else { continue }
            embeddings.append(embedding)
        }
        return try averaged(embeddings)
    }

    private static func usableTakes(_ takes: [[Float]], minimumTakes: Int) throws -> [[Float]] {
        let usable = takes.filter { !$0.isEmpty }
        guard usable.count >= minimumTakes, !usable.isEmpty else { throw EnrollmentError.noSamples }
        return usable
    }

    private static func averaged(_ embeddings: [[Float]]) throws -> [Float] {
        guard !embeddings.isEmpty else { throw EnrollmentError.extractionFailed }
        let dimension = embeddings[0].count
        guard embeddings.allSatisfy({ $0.count == dimension }) else { throw EnrollmentError.extractionFailed }

        var mean = [Float](repeating: 0, count: dimension)
        for embedding in embeddings {
            for i in 0..<dimension { mean[i] += embedding[i] }
        }
        let count = Float(embeddings.count)
        for i in 0..<dimension { mean[i] /= count }

        let norm = mean.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { throw EnrollmentError.extractionFailed }
        return mean.map { $0 / norm }
    }
}

/// Result of matching one note's diarized speakers against the saved voice library, per
/// docs/research/speaker-labeling.md §2.6 and this task's "suggest, never auto-name" contract.
public struct VoiceMatchSuggestion: Sendable, Equatable {
    public let speakerId: Int64
    public let voiceId: Int64
    public let voiceName: String
    public let similarity: Float

    public init(speakerId: Int64, voiceId: Int64, voiceName: String, similarity: Float) {
        self.speakerId = speakerId
        self.voiceId = voiceId
        self.voiceName = voiceName
        self.similarity = similarity
    }
}

/// Matches a diarized speaker's embedding against a library of known voices by cosine similarity,
/// per this task's instruction: "match speakers to known voices by cosine similarity with a
/// conservative threshold, and suggest 'Is this Dana?' (never auto-name without a confirmed
/// match)." Pure function — no I/O, no FluidAudio dependency, testable with synthetic vectors.
public enum VoiceMatcher {
    /// Conservative default threshold. FluidAudio/WeSpeaker-style 256-d embeddings for the same
    /// speaker typically score well above 0.8 cosine similarity on clean single-speaker audio;
    /// different speakers usually score below 0.6. 0.75 is deliberately closer to the
    /// same-speaker end of that range: a missed match (no suggestion) costs the user one extra
    /// tap to rename manually, but a *wrong* match (suggesting the wrong person's name) actively
    /// misleads a summary/action-item attribution, which is the worse failure mode per the
    /// research doc's "never auto-name without a confirmed match" instruction.
    public static let defaultThreshold: Float = 0.75

    /// Finds the best-matching known voice for `embedding`, if any known voice scores at or above
    /// `threshold`. Never returns a match below the threshold, and never guesses among several
    /// close candidates — it always returns the single highest-scoring voice that clears the bar,
    /// which is what the caller then presents as one "Is this Dana?" suggestion.
    public static func bestMatch(
        for embedding: [Float], among voices: [(id: Int64, name: String, embedding: [Float])],
        threshold: Float = defaultThreshold
    ) -> (id: Int64, name: String, similarity: Float)? {
        voices
            .map { (id: $0.id, name: $0.name, similarity: VoiceSimilarity.cosine(embedding, $0.embedding)) }
            .filter { $0.similarity >= threshold }
            .max { $0.similarity < $1.similarity }
    }
}
