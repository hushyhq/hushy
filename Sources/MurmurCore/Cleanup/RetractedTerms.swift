import Foundation

/// Which protected terms the speaker took back, so that dropping them is the right answer and not "a changed term".
///
/// "Send the invoice to Sarah no wait to Priya by Friday": the model writes "Send the invoice to Priya by Friday." and
/// `ProtectedTermGuard` counts the missing "Sarah" as a respelled term, so the person got the raw text. A term the speaker
/// retracted is not one the answer owes them.
///
/// A term counts as retracted only when all of this holds, so a term the speaker kept is never let go:
/// - it sits right before a takeback cue ("no wait", "scratch that", "I mean", "actually", ...), at most two words away;
/// - the cue is followed by what replaces it; and
/// - the answer puts that replacement where the term stood: the word before the term (if any) is followed by the first
///   word of the replacement ("to" then "Priya"), or the replacement opens the answer when the term opened the speech.
///   "I like Sarah, actually she is great" fails this ("like she" is not in the answer), so Sarah stays protected.
enum RetractedTerms {
    private static let cues: [[String]] = [
        ["no", "wait"], ["scratch", "that"], ["strike", "that"], ["hold", "on"], ["i", "mean"], ["i", "meant"],
        ["make", "that"], ["change", "that"], ["not", "that"], ["never", "mind"], ["nevermind"], ["my", "mistake"],
        ["my", "bad"], ["actually"], ["sorry"], ["wait"], ["oops"], ["correction"], ["no"], ["nope"], ["rather"], ["instead"],
    ].sorted { $0.count > $1.count }
    private static let maximumGap = 2

    /// The terms (and heard variants of aliases) among `candidates` that the speaker retracted in `raw` and whose
    /// replacement stands in the answer's text.
    static func retracted(_ candidates: [String], raw: String, answer: String) -> Set<String> {
        let spoken = words(raw), written = words(answer)
        guard !spoken.isEmpty, !written.isEmpty else { return [] }
        var found: Set<String> = []
        for candidate in candidates {
            let key = words(candidate)
            if !key.isEmpty, isRetracted(key, in: spoken, answer: written) { found.insert(candidate) }
        }
        return found
    }

    private static func isRetracted(_ term: [String], in spoken: [String], answer: [String]) -> Bool {
        guard spoken.count > term.count else { return false }
        for start in 0...(spoken.count - term.count) where Array(spoken[start..<(start + term.count)]) == term {
            let end = start + term.count
            for gap in 0...maximumGap {
                let cueStart = end + gap
                guard let cue = cues.first(where: { matches($0, in: spoken, at: cueStart) }) else { continue }
                if replaced(term: start, cueEnd: cueStart + cue.count, in: spoken, answer: answer) { return true }
            }
        }
        return false
    }

    private static func replaced(term start: Int, cueEnd: Int, in spoken: [String], answer: [String]) -> Bool {
        var next = cueEnd
        // "no wait, I mean ..." stacks cues.
        while let more = cues.first(where: { matches($0, in: spoken, at: next) }) { next += more.count }
        guard next < spoken.count else { return false }
        let before: String? = start > 0 ? spoken[start - 1] : nil
        var first = spoken[next]
        // "to Sarah no wait to Priya": the speaker repeats the word in front of the slot.
        if first == before, next + 1 < spoken.count { first = spoken[next + 1] }
        guard let before else { return answer.first == first }
        return zip(answer, answer.dropFirst()).contains { $0 == before && $1 == first }
    }

    private static func matches(_ cue: [String], in spoken: [String], at index: Int) -> Bool {
        index + cue.count <= spoken.count && Array(spoken[index..<(index + cue.count)]) == cue
    }

    private static func words(_ text: String) -> [String] {
        CorrectionAlignment.tokens(text).map(CorrectionAlignment.key).filter { !$0.isEmpty }
    }
}
