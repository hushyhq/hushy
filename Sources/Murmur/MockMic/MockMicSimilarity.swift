#if DEBUG
import Foundation
import MurmurCore

/// The harness's own measurement of how much a speaker in a note sounds like the saved voice, made the
/// way `SpeakerVoiceMemory` makes the voice (same sampling, same embedder, duration-weighted average),
/// so a score below the product's 0.75 suggestion gate is still visible in the report.
struct MockMicSimilarity {
    let embedder: DiarizerVoiceEmbedder
    let signatures: VoiceSignatureStore

    func embedding(of speaker: NoteSpeaker, in recorded: MockMicRecorded) async -> [Float]? {
        guard let speakerId = speaker.id, let stream = embedder.audioStream(for: recorded.note) else { return nil }
        func range(_ row: NoteSegmentWithSpeaker) -> SpeechRange {
            SpeechRange(start: row.segment.startTime, end: row.segment.endTime)
        }
        let own = recorded.rows.filter { $0.segment.speakerId == speakerId }.map(range)
        let others = recorded.rows.filter { $0.segment.speakerId != nil && $0.segment.speakerId != speakerId }.map(range)
        guard case .ready(let ranges, _) = SpeakerVoiceSampling.select(own: own, others: others),
              let vectors = try? await embedder.embeddings(note: recorded.note, stream: stream, ranges: ranges)
        else { return nil }
        let labelled = zip(ranges, vectors).map {
            LabeledEmbedding(speakerLabel: "speaker", embedding: $1, durationSeconds: $0.duration)
        }
        return DiarizedSpeakerEmbeddings.averageEmbeddings(by: labelled)["speaker"]
    }

    func similarity(of speaker: NoteSpeaker, in recorded: MockMicRecorded, to voice: Voice) async -> Double? {
        guard let saved = try? signatures.decrypt(voice.encryptedEmbedding),
              let vector = await embedding(of: speaker, in: recorded) else { return nil }
        return Double(VoiceSimilarity.cosine(saved, vector))
    }
}
#endif
