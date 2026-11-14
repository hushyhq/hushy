import Foundation

/// Keeps capitalized names recognized in the rules draft present in a model rewrite.
/// Sentence-initial capitalization is ignored in the draft because it is ambiguous, while
/// sentence-initial words in the answer count as evidence that a draft name survived a split.
enum CapitalizedNameGuard {
    static func changedNames(answer: String, draft: String) -> Bool {
        let draftNames = capitalizedNames(in: draft, includingSentenceInitial: false)
        let answerNames = capitalizedNames(in: answer, includingSentenceInitial: true)
        return !draftNames.isEmpty && !draftNames.isSubset(of: answerNames)
    }

    static func capitalizedNames(in text: String, includingSentenceInitial: Bool) -> Set<String> {
        let sentences = Sentences.split(text)
        var names: Set<String> = []
        for sentence in sentences {
            let tokens = sentence.split(whereSeparator: \.isWhitespace).map(String.init)
            for (index, rawToken) in tokens.enumerated() {
                let token = rawToken.trimmingCharacters(in: .punctuationCharacters)
                guard let first = token.first, first.isUppercase, token != "I" else { continue }
                // "I'm", "I'll", "I've", "I'd" are pronouns rather than names.
                if token.hasPrefix("I'") || token.hasPrefix("I\u{2019}") { continue }
                if index == 0, !includingSentenceInitial { continue }
                names.insert(token.lowercased())
            }
        }
        return names
    }
}
