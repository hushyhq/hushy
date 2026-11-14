import Foundation
import MurmurCore

/// One diarizer cluster in one excerpt, with the two embeddings the app can compare: the duration-weighted
/// mean of the diarizer's per-turn embeddings (what a later note is matched with today) and the "remember"
/// embedding built from the cluster's longest clean turns (what a saved voice is made of).
struct ClusterRecord: Codable {
    let label: String
    let seconds: Double
    let trueSpeaker: String?
    let purity: Double
    let avgTurn: [Float]
    let remember: [Float]?
    /// The cluster's turns as [start, end] seconds within the excerpt (times only; used to study fragment folding).
    var turns: [[Double]]? = nil
}

struct ExcerptRecord: Codable {
    let recording: String
    let set: String
    let half: VoiceMatchHalf
    let index: Int
    let startSeconds: Double
    /// Seconds of real speech per true speaker in this excerpt.
    let trueSeconds: [String: Double]
    let clusters: [ClusterRecord]
    /// For a true speaker split over several clusters: the merged embeddings of those clusters.
    let mergedAvgTurn: [String: [Float]]
    let mergedRemember: [String: [Float]]
    let analysisSeconds: Double
    /// Frame-wise DER pieces for the excerpt as diarized: missed, false alarm, confusion, reference speech (seconds).
    var derSeconds: [Double]? = nil

    var id: String { "\(recording)#\(index)" }
}

enum VoiceMatchRules {
    /// A true speaker with less speech than this in an excerpt is not counted as present.
    static let truthMinSeconds = 5.0
    /// A cluster needs this much speech to count as a voice in a similarity pair.
    static let clusterMinSeconds = 5.0
    /// A cluster this big, mostly one true speaker, counts as a piece of that speaker's split voice.
    static let splitMinSeconds = 3.0
    static let minimumPurity = 0.5
}
