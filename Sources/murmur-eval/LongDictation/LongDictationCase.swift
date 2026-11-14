import Foundation

/// One invented, rambling dictation of 100 to 140 words with the answer key the whole-dictation scorer needs
/// (`Evals/long-dictation-dev.jsonl`, provenance in `Evals/long-dictation-dev.provenance.md`). Task 142.
///
/// - `spoken`: raw recogniser output (little or no punctuation, lowercase mostly).
/// - `reference`: what the speaker would have typed. A blank line separates paragraphs.
/// - `mustKeep`: names, numbers, dates, negated statements and each distinct item. `a|b` accepts either spelling.
/// - `fillers`: for each hedge or filler phrase, how many times `spoken` uses it as a hedge (`hedge`) and as
///   a real word (`legit`, such as "I would like that"). Output beyond `legit` is leftover.
/// - `repairs`: words the speaker abandoned (`restart`, `false_start`, `correction`). Any of the `a|b` phrases still
///   in the output is one unrepaired fault.
/// - `breaks`: `[end of one phrase, start of the next]` where the reference has a sentence end and `spoken` runs on.
struct LongDictationCase: Decodable, Sendable, Equatable {
    struct Filler: Decodable, Sendable, Equatable {
        let p: String
        let hedge: Int
        let legit: Int
    }

    struct Repair: Decodable, Sendable, Equatable {
        let kind: String
        let abandoned: String
    }

    let id: String
    let domain: String
    let spoken: String
    let reference: String
    let mustKeep: [String]
    let fillers: [Filler]
    let repairs: [Repair]
    let breaks: [[String]]

    enum CodingKeys: String, CodingKey {
        case id, domain, spoken, reference, fillers, repairs, breaks
        case mustKeep = "must_keep"
    }

    var spokenWordCount: Int { spoken.split(whereSeparator: \.isWhitespace).count }

    static func load(_ path: String) throws -> [LongDictationCase] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let decoder = JSONDecoder()
        return try text.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try decoder.decode(LongDictationCase.self, from: Data($0.utf8)) }
    }

    /// Two dictations as one, for probing how a longer text behaves (`--double`): the spoken texts run on, the
    /// references are separate paragraphs, and the answer keys add up (a filler phrase used in both is summed).
    func followed(by other: LongDictationCase) -> LongDictationCase {
        var merged: [Filler] = []
        for filler in fillers + other.fillers {
            if let index = merged.firstIndex(where: { $0.p == filler.p }) {
                merged[index] = Filler(p: filler.p, hedge: merged[index].hedge + filler.hedge, legit: merged[index].legit + filler.legit)
            } else {
                merged.append(filler)
            }
        }
        return LongDictationCase(
            id: "\(id)+\(other.id)", domain: domain, spoken: spoken + " " + other.spoken,
            reference: reference + "\n\n" + other.reference, mustKeep: mustKeep + other.mustKeep, fillers: merged,
            repairs: repairs + other.repairs, breaks: breaks + other.breaks)
    }

    init(id: String, domain: String, spoken: String, reference: String, mustKeep: [String], fillers: [Filler],
         repairs: [Repair], breaks: [[String]]) {
        self.id = id
        self.domain = domain
        self.spoken = spoken
        self.reference = reference
        self.mustKeep = mustKeep
        self.fillers = fillers
        self.repairs = repairs
        self.breaks = breaks
    }

    /// What is wrong with the answer key itself (empty when it is sound): the checks that keep the scorer honest.
    func problems(wordRange: ClosedRange<Int> = 100...140) -> [String] {
        var found: [String] = []
        if !wordRange.contains(spokenWordCount) { found.append("\(id): spoken has \(spokenWordCount) words") }
        let spokenTokens = LongDictationScorer.tokens(spoken)
        let referenceTokens = LongDictationScorer.tokens(reference)
        for filler in fillers {
            let phrase = LongDictationScorer.tokens(filler.p)
            let inSpoken = LongDictationScorer.occurrences(of: phrase, in: spokenTokens)
            let inReference = LongDictationScorer.occurrences(of: phrase, in: referenceTokens)
            if inSpoken != filler.hedge + filler.legit { found.append("\(id): filler '\(filler.p)' is in spoken \(inSpoken) times, key says \(filler.hedge + filler.legit)") }
            if inReference != filler.legit { found.append("\(id): filler '\(filler.p)' is in the reference \(inReference) times, key says \(filler.legit)") }
        }
        for repair in repairs {
            if !["restart", "false_start", "correction"].contains(repair.kind) { found.append("\(id): unknown repair kind \(repair.kind)") }
            for phrase in repair.abandoned.split(separator: "|").map(String.init) {
                let tokens = LongDictationScorer.tokens(phrase)
                if LongDictationScorer.occurrences(of: tokens, in: spokenTokens) == 0 { found.append("\(id): abandoned '\(phrase)' is not in spoken") }
                if LongDictationScorer.occurrences(of: tokens, in: referenceTokens) > 0 { found.append("\(id): abandoned '\(phrase)' is in the reference") }
            }
        }
        for item in mustKeep where !LongDictationScorer.contains(item, in: referenceTokens) {
            found.append("\(id): must_keep '\(item)' is not in the reference")
        }
        for pair in breaks {
            guard pair.count == 2 else { found.append("\(id): a break needs two phrases"); continue }
            let sample = LongDictationScorer.score(
                LongDictationCase(id: id, domain: domain, spoken: spoken, reference: reference, mustKeep: [], fillers: [], repairs: [],
                                  breaks: [pair]),
                output: reference, groupTexts: [])
            if sample.faults.breaksUnlocated > 0 || sample.faults.breaksMissing > 0 {
                found.append("\(id): break '\(pair[0])' | '\(pair[1])' is not a sentence end in the reference")
            }
        }
        return found
    }
}
