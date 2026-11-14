import Foundation

/// When the release pass used vocabulary boosting, common words the live draft had correctly can be
/// swapped for on-screen labels or ambiguous installed names, including two words joined into one.
/// Prefer the draft reading unless explicit app syntax or a personal Dictionary entry supports the name.
/// UI labels are restored only across equal-length aligned spans; installed-name restoration can
/// expand a joined name to preserve every word the recogniser heard.
public enum DraftCommonWordGuard {
    public struct Outcome: Sendable, Equatable {
        public let text: String
        /// One-for-one positions where draft and release transcripts disagreed.
        public let disagreements: Int
        /// Common words restored from the draft after a bad boost.
        public let repairs: Int
    }

    public static func reconcile(
        draft: String?, release: String, vocabulary: VocabularyContext = .empty, installedApps: [InstalledAppInfo] = []
    ) -> Outcome {
        guard let draft, !draft.isEmpty else { return Outcome(text: release, disagreements: 0, repairs: 0) }
        let draftWords = draft.split(whereSeparator: \.isWhitespace).map(String.init)
        let repaired = restoreInstalledNames(draft: draftWords, release: release, vocabulary: vocabulary, apps: installedApps)
        let releaseWords = repaired.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard draftWords != releaseWords else {
            return repaired
        }
        let regions = BoostGuard.align(draftWords.map(tokenKey), releaseWords.map(tokenKey))
        var result = releaseWords
        var disagreements = 0
        var repairs = 0
        for region in regions {
            guard case .changed(let draftRange, let releaseRange) = region,
                  draftRange.count == releaseRange.count, !draftRange.isEmpty else { continue }
            for offset in 0..<draftRange.count {
                let heard = draftWords[draftRange.lowerBound + offset]
                let delivered = releaseWords[releaseRange.lowerBound + offset]
                guard tokenKey(heard) != tokenKey(delivered) else { continue }
                disagreements += 1
                guard restores(heard: heard, delivered: delivered) else { continue }
                result[releaseRange.lowerBound + offset] = restoredWord(heard, over: delivered)
                repairs += 1
            }
        }
        let text = repairs == 0 ? repaired.text : result.joined(separator: " ")
        return Outcome(text: text, disagreements: disagreements + repaired.disagreements, repairs: repairs + repaired.repairs)
    }

    private static func restoreInstalledNames(
        draft: [String], release: String, vocabulary: VocabularyContext, apps: [InstalledAppInfo]
    ) -> Outcome {
        let ambiguous = Set(apps.filter { InstalledNamePolicy.isOrdinary($0.name) }.map { BoostGuard.key($0.name) })
        let userTerms = Set(vocabulary.terms.filter { !$0.installedApp }.map { BoostGuard.key($0.text) })
        guard FeatureFlags.installedNames, !ambiguous.isEmpty else { return Outcome(text: release, disagreements: 0, repairs: 0) }
        let matches = Regex.matchesCaseSensitive(release, "\\S+").compactMap { Range($0.range, in: release) }
        let words = matches.map { String(release[$0]) }
        let draftKeys = draft.map(BoostGuard.key), releaseKeys = words.map(BoostGuard.key)
        guard draftKeys != releaseKeys else { return Outcome(text: release, disagreements: 0, repairs: 0) }
        var replacements: [(Range<String.Index>, String)] = []
        for region in BoostGuard.align(draftKeys, releaseKeys) {
            guard case .changed(let old, let new) = region, !new.isEmpty, (1...4 * new.count).contains(old.count),
                  draft[old].allSatisfy({ LearningLexicon.isCommonWord(BoostGuard.key($0)) }),
                  let first = new.first, let last = new.last,
                  words[new].allSatisfy({ ambiguous.contains(BoostGuard.key($0)) && !userTerms.contains(BoostGuard.key($0)) })
            else { continue }
            let previous = old.lowerBound > 0 ? BoostGuard.key(draft[old.lowerBound - 1]) : nil
            let next = old.upperBound < draft.count ? BoostGuard.key(draft[old.upperBound]) : nil
            guard !InstalledNamePolicy.hasExplicitAppCue(previous: previous, next: next) else { continue }
            let punctuation = String(words[last].reversed().prefix(while: { $0.isPunctuation }).reversed())
            let restored = draft[old].joined(separator: " ")
            let suffix = draft[old].last?.last?.isPunctuation == true ? "" : punctuation
            // One replacement owns the whole aligned span, including adjacent names.
            // Copy every draft word exactly once rather than restoring names over it.
            replacements.append((matches[first].lowerBound..<matches[last].upperBound, restored + suffix))
        }
        var text = release
        for (range, replacement) in replacements.reversed() { text.replaceSubrange(range, with: replacement) }
        return Outcome(text: text, disagreements: replacements.count, repairs: replacements.count)
    }

    /// A name a hint supplied ("clot" → "Claude") is the boost doing its job and stays.
    private static func restores(heard: String, delivered: String) -> Bool {
        let heardKey = heard.lowercased().trimmingCharacters(in: .punctuationCharacters)
        guard WordFrequency.shared.isOrdinary(heardKey) else { return false }
        let deliveredKey = delivered.lowercased().trimmingCharacters(in: .punctuationCharacters)
        return ScreenBoostPolicy.uiLabelDenylist.contains(deliveredKey)
    }

    private static func tokenKey(_ token: String) -> String {
        BoostGuard.key(token)
    }

    /// The live pass often has no period where the release token does. Restoring the word alone
    /// would end the sentence early.
    private static func restoredWord(_ heard: String, over delivered: String) -> String {
        let scalars = Array(delivered.unicodeScalars)
        var end = scalars.count
        while end > 0, CharacterSet.punctuationCharacters.contains(scalars[end - 1]) {
            end -= 1
        }
        guard end < scalars.count else { return heard }
        if let last = heard.unicodeScalars.last, CharacterSet.punctuationCharacters.contains(last) {
            return heard
        }
        return heard + String(String.UnicodeScalarView(scalars[end...]))
    }
}
