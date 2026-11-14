import FluidAudio
import Foundation
import MurmurCore

/// NOTSOFAR-1 eval meetings (Microsoft, CC BY 4.0, `huggingface.co/datasets/microsoft/NOTSOFAR`),
/// single-channel far-field track: real office meetings of 3 to 7 people around a table, recorded
/// by one commercial device. This is the "in person, in a group" case Granola users complain about.
///
/// Reference turns come from the official `gt_transcription.json` word timings (each word is
/// `[text, start, end]`), merged per speaker when the gap between words is under
/// `wordMergeGapSeconds`. Utterances without word timings fall back to the utterance bounds.
enum NotsofarDownloader {
    private static let base =
        "https://huggingface.co/datasets/microsoft/NOTSOFAR/resolve/main/benchmark-datasets/eval_set/240825.1_eval_full_with_GT/MTG"

    /// Every eighth meeting of the 129 in `240825.1_eval_full_with_GT`, sorted by id, each on its
    /// first single-channel device by name (`sc_meetup_0` for all of them). Fixed so a rerun reads
    /// the same audio. NVIDIA trained Nemotron 3 on the NOTSOFAR train and dev sets, not this one.
    static let meetings: [(id: String, device: String)] = [
        "MTG_32000", "MTG_32020", "MTG_32029", "MTG_32048", "MTG_32060", "MTG_32068", "MTG_32080",
        "MTG_32089", "MTG_32101", "MTG_32109", "MTG_32183", "MTG_32250", "MTG_32261", "MTG_32313",
        "MTG_32322", "MTG_32336", "MTG_32346",
    ].map { ($0, "sc_meetup_0") }

    static let wordMergeGapSeconds = 0.5

    struct Utterance: Decodable {
        let speaker_id: String
        let start_time: Double
        let end_time: Double
        let word_timing: [[WordField]]?
    }

    enum WordField: Decodable {
        case text(String)
        case time(Double)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) { self = .time(value) } else {
                self = .text(try container.decode(String.self))
            }
        }

        var seconds: Double? { if case .time(let value) = self { value } else { nil } }
    }

    static func load(id: String, device: String, root: URL) async throws -> BakeoffFile {
        let folder = root.appendingPathComponent("notsofar-eval-sc/\(id)", isDirectory: true)
        let wav = folder.appendingPathComponent("\(device).ch0.wav")
        let gt = folder.appendingPathComponent("gt_transcription.json")
        try await BakeoffDownload.ensure(URL(string: "\(base)/\(id)/gt_transcription.json")!, at: gt)
        try await BakeoffDownload.ensure(URL(string: "\(base)/\(id)/\(device)/ch0.wav")!, at: wav)
        let utterances = try JSONDecoder().decode([Utterance].self, from: Data(contentsOf: gt))
        return BakeoffFile(id: id, audio: try AudioConverter().resampleAudioFile(wav), reference: referenceTurns(utterances))
    }

    static func referenceTurns(_ utterances: [Utterance]) -> [DERSegment] {
        var words: [String: [(start: Double, end: Double)]] = [:]
        for utterance in utterances {
            let timed = (utterance.word_timing ?? []).compactMap { fields -> (Double, Double)? in
                guard fields.count >= 3, let start = fields[1].seconds, let end = fields[2].seconds, end > start else { return nil }
                return (start, end)
            }
            let spans = timed.isEmpty ? [(utterance.start_time, utterance.end_time)] : timed
            words[utterance.speaker_id, default: []].append(contentsOf: spans)
        }
        return words.flatMap { speaker, spans in
            mergeSpans(spans, gap: wordMergeGapSeconds).map { DERSegment(speaker: speaker, start: $0.start, end: $0.end) }
        }.sorted { $0.start < $1.start }
    }

    private static func mergeSpans(_ spans: [(start: Double, end: Double)], gap: Double) -> [(start: Double, end: Double)] {
        var merged: [(start: Double, end: Double)] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, span.start - last.end < gap {
                merged[merged.count - 1].end = max(last.end, span.end)
            } else {
                merged.append(span)
            }
        }
        return merged
    }
}
