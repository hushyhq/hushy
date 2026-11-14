#if DEBUG
import Foundation

/// A stretch of one speaker's speech as the note stored it (seconds from the start of the capture).
struct MockMicNoteSegment: Equatable {
    let speaker: String
    let start: Double
    let end: Double
}

/// Which reference speaker a speaker found in a note is, by how much their speech overlaps each
/// reference turn once the capture offset is allowed for.
enum MockMicAssignment {
    struct Match: Equatable {
        let reference: String
        let overlapSeconds: Double
    }

    /// Less overlap than this is noise, not a match.
    static let minimumOverlap = 1.0

    /// `offset` is how long after the start of the clip the capture began (note time = clip time + offset).
    static func map(segments: [MockMicNoteSegment], turns: [MockMicManifest.Turn], offset: Double) -> [String: Match] {
        var overlaps: [String: [String: Double]] = [:]
        for segment in segments {
            for turn in turns {
                let shared = min(segment.end, turn.end + offset) - max(segment.start, turn.start + offset)
                if shared > 0 { overlaps[segment.speaker, default: [:]][turn.speaker, default: 0] += shared }
            }
        }
        var result: [String: Match] = [:]
        for (speaker, byReference) in overlaps {
            guard let best = byReference.max(by: { $0.value < $1.value }), best.value >= minimumOverlap else { continue }
            result[speaker] = Match(reference: best.key, overlapSeconds: best.value)
        }
        return result
    }

    /// Speakers with at least `minimumSeconds` of speech in total.
    static func distinctSpeakers(_ segments: [MockMicNoteSegment], minimumSeconds: Double) -> Int {
        var totals: [String: Double] = [:]
        for segment in segments { totals[segment.speaker, default: 0] += max(segment.end - segment.start, 0) }
        return totals.values.filter { $0 >= minimumSeconds }.count
    }
}

/// What a later meeting showed for the remembered voice and for everyone else.
struct MockMicVoiceObservation: Equatable {
    var rememberedSuggestedName: String?
    var rememberedIsNamed: Bool
    var rememberedSimilarity: Double?
    /// Across every other speaker in the meeting: any suggestion, any automatic name, the highest similarity.
    var otherSuggestedName: String?
    var otherIsNamed: Bool
    var otherSimilarity: Double?
}

enum MockMicVoiceChecks {
    static func laterMeeting(_ observation: MockMicVoiceObservation, invented: String, expectsRemembered: Bool) -> [MockMicCheck] {
        var checks: [MockMicCheck] = []
        if expectsRemembered {
            checks.append(check("remembered voice is suggested by name",
                                observation.rememberedSuggestedName == invented,
                                value: describe(observation.rememberedSuggestedName, observation.rememberedSimilarity)))
            checks.append(check("remembered voice is not named automatically", !observation.rememberedIsNamed,
                                value: "named=\(observation.rememberedIsNamed)"))
        }
        checks.append(check(expectsRemembered ? "new voice has no suggestion" : "no speaker has a suggestion",
                            observation.otherSuggestedName == nil,
                            value: describe(observation.otherSuggestedName, observation.otherSimilarity)))
        checks.append(check("no other speaker is named automatically", !observation.otherIsNamed,
                            value: "named=\(observation.otherIsNamed)"))
        return checks
    }

    private static func check(_ name: String, _ passed: Bool, value: String) -> MockMicCheck {
        MockMicCheck(name: name, passed: passed, enforced: true, value: value, threshold: nil)
    }

    private static func describe(_ name: String?, _ similarity: Double?) -> String {
        let score = similarity.map { String(format: "%.3f", $0) } ?? "n/a"
        return "suggestion=\(name == nil ? "none" : "yes"), similarity=\(score)"
    }
}
#endif
