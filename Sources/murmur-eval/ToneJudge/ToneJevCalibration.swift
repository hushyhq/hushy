import Foundation
import MurmurCore

/// The calibration set for the tone rubric, built from the expected outputs in `Evals/tones-dev.json`
/// (the only tone set with exact expected strings), and the tables that score Jev against it.
/// Pure: no network, so it is unit-tested. Only invented dev-set text goes in.
enum ToneJevCalibration {
    typealias Case = ToneEvalChecks.Case

    /// One spoken input with the text each tone is expected to produce for it.
    struct Sample: Equatable {
        enum Source: String { case expected, ruleMade }
        let id: String
        let spoken: String
        let texts: [DictationTone: String]
        let source: Source
    }

    /// One output to ask `tone_read` about.
    struct ReadItem: Equatable {
        /// `distinct`: another tone's text has different words. `shared`: every known text has the
        /// same words (only layout, such as the closing period, may differ), so a read cannot be
        /// told apart from the others and is not an error either way. `single`: one text known.
        enum Kind: String { case distinct, shared, single }
        let caseID: String
        let source: Sample.Source
        /// The tone this text is the expected output for.
        let intended: DictationTone
        let spoken: String
        let text: String
        /// Reads that are not wrong for this text: every tone whose text has the same words, plus
        /// "unclear" when more than one does. This is how "fits more than one tone" is handled
        /// without counting it as an error.
        let acceptable: Set<String>
        let kind: Kind
    }

    /// One (requested tone, output) pair to ask the fault questions about.
    struct FitItem: Equatable {
        /// `words`: the text has different words from what the requested tone expects (a register
        /// mismatch). `layout`: same words, different layout only (informational).
        enum Difference: String { case none, words, layout }
        let caseID: String
        let source: Sample.Source
        let requested: DictationTone
        /// The tone the text is the expected output for. Equal to `requested` for an own-tone item.
        let from: DictationTone
        let spoken: String
        let text: String
        let difference: Difference
        var expectedBroken: Bool { difference == .words }
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }).map(String.init)
    }

    // MARK: Samples

    /// The author's expected strings in the case file (only the short set has them).
    static func expectedSamples(_ cases: [Case]) -> [Sample] {
        cases.compactMap { item in
            let texts = Dictionary(uniqueKeysWithValues: DictationTone.allCases.compactMap { tone in
                item.toneExpectations[tone.rawValue]?.exact.map { (tone, $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            })
            return texts.isEmpty ? nil : Sample(id: item.id, spoken: item.raw, texts: texts, source: .expected)
        }
    }

    /// Known-answer samples made by the real tone rules from each case's cleaned `ideal` text. Kept only
    /// where the tones differ in words, because the case file's expectations differ mostly in the
    /// closing period. `limit` keeps the number of calls modest.
    static func ruleMadeSamples(_ cases: [Case], limit: Int) -> [Sample] {
        var samples: [Sample] = []
        for item in cases {
            let category = AppCategory.classify(bundleID: item.target.bundleID, windowTitle: item.target.windowTitle)
            let context = StyleContext.from(category) ?? .other
            let texts = Dictionary(uniqueKeysWithValues: DictationTone.allCases.map {
                ($0, ToneRegister.apply($0, to: item.ideal, in: context).trimmingCharacters(in: .whitespacesAndNewlines))
            })
            guard Set(texts.values.map(words)).count > 1 else { continue }
            samples.append(Sample(id: "rule:" + item.id, spoken: item.raw, texts: texts, source: .ruleMade))
            if samples.count == limit { break }
        }
        return samples
    }

    static func readItems(_ samples: [Sample]) -> [ReadItem] {
        samples.flatMap { sample in
            DictationTone.allCases.compactMap { tone -> ReadItem? in
                guard let text = sample.texts[tone] else { return nil }
                let mine = words(text)
                let same = DictationTone.allCases.filter { sample.texts[$0].map(words) == mine }
                var acceptable = Set(same.map(\.rawValue))
                if same.count > 1 { acceptable.insert("unclear") }
                let known = sample.texts.count
                let kind: ReadItem.Kind = known < 2 ? .single : (same.count == known ? .shared : .distinct)
                return ReadItem(caseID: sample.id, source: sample.source, intended: tone, spoken: sample.spoken, text: text,
                                acceptable: acceptable, kind: kind)
            }
        }
    }

    static func fitItems(_ samples: [Sample]) -> [FitItem] {
        samples.flatMap { sample in
            DictationTone.allCases.flatMap { requested -> [FitItem] in
                guard let own = sample.texts[requested] else { return [] }
                var items = [FitItem(caseID: sample.id, source: sample.source, requested: requested, from: requested,
                                     spoken: sample.spoken, text: own, difference: .none)]
                for other in DictationTone.allCases where other != requested {
                    guard let text = sample.texts[other], text != own else { continue }
                    let difference: FitItem.Difference = words(text) == words(own) ? .layout : .words
                    items.append(FitItem(caseID: sample.id, source: sample.source, requested: requested, from: other,
                                         spoken: sample.spoken, text: text, difference: difference))
                }
                return items
            }
        }
    }

    // MARK: Tables

    struct ReadTable: Equatable {
        /// intended -> read option -> count.
        var counts: [DictationTone: [String: Int]] = [:]
        var strictCorrect = 0
        var lenientCorrect = 0
        var total = 0

        mutating func add(_ item: ReadItem, read: String) {
            counts[item.intended, default: [:]][read, default: 0] += 1
            total += 1
            if read == item.intended.rawValue { strictCorrect += 1 }
            if item.acceptable.contains(read) { lenientCorrect += 1 }
        }
    }

    static func readTable(_ results: [(item: ReadItem, read: ToneRead)], kind: ReadItem.Kind) -> ReadTable {
        var table = ReadTable()
        for (item, read) in results where item.kind == kind { table.add(item, read: read.choice) }
        return table
    }

    struct FitSummary: Equatable {
        var ownTotal = 0
        var ownFlagged = 0
        var ownRuleBroken = 0
        var ownOverreach = 0
        /// Pairs whose words differ from what the requested tone expects.
        var wordsTotal = 0
        var wordsFlagged = 0
        /// Pairs that differ only in layout (informational).
        var layoutTotal = 0
        var layoutFlagged = 0
        /// "from->requested" -> [flagged, total], words-different pairs only.
        var pairs: [String: [Int]] = [:]
        var ownMeanPBad = 0.0
        var wordsMeanPBad = 0.0
    }

    static func fitSummary(_ results: [(item: FitItem, fit: ToneFit)]) -> FitSummary {
        var summary = FitSummary()
        var ownSum = 0.0
        var wordsSum = 0.0
        for (item, fit) in results {
            switch item.difference {
            case .none:
                summary.ownTotal += 1
                ownSum += fit.pBad
                if fit.flagged { summary.ownFlagged += 1 }
                if fit.ruleBroken >= ToneFit.flagAt { summary.ownRuleBroken += 1 }
                if fit.overreach >= ToneFit.flagAt { summary.ownOverreach += 1 }
            case .words:
                summary.wordsTotal += 1
                wordsSum += fit.pBad
                if fit.flagged { summary.wordsFlagged += 1 }
                let key = "\(item.from.rawValue)->\(item.requested.rawValue)"
                var pair = summary.pairs[key] ?? [0, 0]
                pair[1] += 1
                if fit.flagged { pair[0] += 1 }
                summary.pairs[key] = pair
            case .layout:
                summary.layoutTotal += 1
                if fit.flagged { summary.layoutFlagged += 1 }
            }
        }
        summary.ownMeanPBad = summary.ownTotal == 0 ? 0 : ownSum / Double(summary.ownTotal)
        summary.wordsMeanPBad = summary.wordsTotal == 0 ? 0 : wordsSum / Double(summary.wordsTotal)
        return summary
    }

    // MARK: Text

    static func formatReadTable(_ table: ReadTable, title: String) -> String {
        let columns = ToneJevRubric.readOptions
        var lines = ["#### \(title) (n \(table.total))", "| intended \\ read | " + columns.joined(separator: " | ") + " |",
                     "|---|" + columns.map { _ in "---:|" }.joined()]
        for tone in DictationTone.allCases {
            let row = table.counts[tone] ?? [:]
            lines.append("| \(tone.rawValue) | " + columns.map { String(row[$0] ?? 0) }.joined(separator: " | ") + " |")
        }
        if table.total > 0 {
            lines.append("Read equals intended: \(table.strictCorrect)/\(table.total); read is an acceptable one: \(table.lenientCorrect)/\(table.total).")
        }
        return lines.joined(separator: "\n")
    }

    static func formatFitSummary(_ summary: FitSummary) -> String {
        var lines = [
            "- Expected outputs flagged as a fault, own tone (false alarms): \(summary.ownFlagged)/\(summary.ownTotal)"
                + " (rule broken \(summary.ownRuleBroken), overreach \(summary.ownOverreach); mean pBad \(String(format: "%.2f", summary.ownMeanPBad)))",
            "- Pairs whose words differ from the requested tone's expectation, flagged (caught): \(summary.wordsFlagged)/\(summary.wordsTotal)"
                + " (mean pBad \(String(format: "%.2f", summary.wordsMeanPBad)))",
        ]
        for key in summary.pairs.keys.sorted() {
            let pair = summary.pairs[key] ?? [0, 0]
            lines.append("  - text for \(key.replacingOccurrences(of: "->", with: ", judged as ")): \(pair[0])/\(pair[1]) flagged")
        }
        lines.append("- Pairs that differ only in layout (such as the closing period), flagged (informational, not an error): \(summary.layoutFlagged)/\(summary.layoutTotal)")
        return lines.joined(separator: "\n")
    }
}
