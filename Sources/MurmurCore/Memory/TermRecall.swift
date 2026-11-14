import Foundation

public enum TermRecall {
    /// Exact hearing, exact spelling, phonetic near match, then the learner's sound matcher.
    public static func recall(_ transcript: String, from index: MemoryIndex, limit: Int = 11,
                              isCommonWord: (String) -> Bool = LearningLexicon.isCommonWord) -> [MemoryEntry] {
        let ranks = ranks(transcript, from: index, isCommonWord: isCommonWord)
        return index.terms.compactMap { entry in ranks[entry.id].map { (entry: entry, rank: $0) } }
            .sorted { a, b in
                if a.rank != b.rank { return a.rank < b.rank }
                return a.entry.createdAt > b.entry.createdAt
            }
            .prefix(max(0, min(limit, 11))).map(\.entry)
    }

    /// The best tier each recalled term reached, by entry id: 0 heard-as, 1 spelling, 2 near
    /// sound, 3 loose sound.
    static func ranks(_ transcript: String, from index: MemoryIndex, isCommonWord: (String) -> Bool) -> [UUID: Int] {
        let tokens = CorrectionAlignment.tokens(transcript).map(CorrectionAlignment.key).filter { !$0.isEmpty }
        guard !tokens.isEmpty, !index.terms.isEmpty else { return [:] }
        var best: [UUID: Int] = [:]
        // Terms the sound pass has already matched; a later run cannot improve on that there.
        var heard = [Bool](repeating: false, count: index.terms.count)
        for run in runs(of: tokens, isCommonWord: isCommonWord) {
            note(index.termsByHearing[run.text], rank: 0, in: &best)
            note(index.termsByKey[run.text], rank: 1, in: &best)
            // A run of ordinary words recalls a term only exactly: as it was heard or as it is
            // spelled. Whether the word was meant is the model's call, not a rule's.
            if run.isCommon { continue }
            matchBySound(RecallKeys(key: run.text), in: index, heard: &heard, best: &best)
        }
        return best
    }

    /// Every distinct 1 to 3-word run, each with whether all of its words are ordinary ones.
    private static func runs(of tokens: [String], isCommonWord: (String) -> Bool) -> [(text: String, isCommon: Bool)] {
        var known: [String: Bool] = [:]
        let common = tokens.map { token -> Bool in
            if let cached = known[token] { return cached }
            let value = isCommonWord(token)
            known[token] = value
            return value
        }
        var seen = Set<String>()
        var runs: [(text: String, isCommon: Bool)] = []
        for start in tokens.indices {
            for end in start..<min(start + 3, tokens.count) {
                let text = tokens[start...end].joined(separator: " ")
                guard seen.insert(text).inserted else { continue }
                runs.append((text, common[start...end].allSatisfy { $0 }))
            }
        }
        return runs
    }

    private static func note(_ entries: [MemoryEntry]?, rank: Int, in best: inout [UUID: Int]) {
        for entry in entries ?? [] { best[entry.id] = min(best[entry.id] ?? rank, rank) }
    }

    private static func matchBySound(_ run: RecallKeys, in index: MemoryIndex, heard: inout [Bool],
                                     best: inout [UUID: Int]) {
        for position in index.termPositionsByPhoneticKey[run.phonetic] ?? [] {
            let term = index.recallKeys[position].joined
            guard ContextSpellingFixer.levenshtein(run.joined, term)
                    <= ContextSpellingFixer.maxEditDistance(for: term.count) else { continue }
            heard[position] = true
            note([index.terms[position]], rank: 2, in: &best)
        }
        for (position, term) in index.recallKeys.enumerated() where !heard[position] && run.soundsLike(term) {
            heard[position] = true
            note([index.terms[position]], rank: 3, in: &best)
        }
    }
}
