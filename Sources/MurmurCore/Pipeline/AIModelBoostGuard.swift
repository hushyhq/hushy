import Foundation

/// Keeps the AI-model boost to sentences that are about AI. In an AI-prompt app the recogniser is boosted towards the
/// model and product names (`VocabularyContext.aiModelTerms`) with no other evidence that one was said, and the CTC pass
/// then trades a person's name it heard for one of them: "Anthony Edwards" became "Anthropic Edwards", "Cade Cunningham"
/// "Codex Cunningham", and "Claude Sonnet 4.5" "Claude Code 4.5" (accuracy eval, Claude app, 2026-11-11). `BoostGuard`
/// keeps only ordinary English words, and a given name is not one.
///
/// So, after `BoostGuard`, a changed region that brings in a word of a built-in AI-model term goes back to what was heard
/// unless all three hold, the same kind of evidence the screen and the lexicon need before they boost a term:
/// - its sentence says it is about AI work: a word of `cues` outside the region;
/// - none of the heard words is itself an AI model or product name: a name heard is not traded for another;
/// - the heard words are not part of a person's full name: a capitalised word right beside them that the region did not
///   change ("Anthony" before "Edwards").
/// A term the person has in their Dictionary, on screen or in the lexicon is not a built-in one and is not judged here.
/// Cost: one alignment of the two transcripts, only when the vocabulary holds built-in AI terms and the boost changed text.
public enum AIModelBoostGuard {
    /// Words that put a sentence about AI work: the work itself and the names of the models and products.
    static let cues: Set<String> = Set([
        "prompt", "prompts", "model", "models", "llm", "llms", "ai", "agent", "agents", "subagent", "subagents", "api",
        "apis", "token", "tokens", "mcp", "chatbot", "assistant", "openai", "copilot",
    ]).union(nameWords)

    /// The words of the AI model and product names the app knows: every one-word name ("Sonnet", "Codex"), and the words
    /// of a longer name that are not ordinary English ("Claude" of "Claude Code", not "code").
    static let nameWords: Set<String> = {
        let names = VocabularyContext.aiModelTerms.map(\.text) + AIProductNameFixer.productNames + ["Anthropic", "OpenAI"]
        return Set(names.flatMap { name -> [String] in
            let words = name.split(whereSeparator: \.isWhitespace).map { BoostGuard.key(String($0)) }
            return words.count == 1 ? words : words.filter { !WordFrequency.shared.isOrdinary($0) }
        })
    }()

    /// `boosted` with each unsupported region that brought in a word of `aiTerms` put back to `original`'s words.
    public static func keepSupported(original: String, boosted: String, aiTerms: [String]) -> String {
        guard original != boosted, !aiTerms.isEmpty else { return boosted }
        let aiKeys = Set(aiTerms.flatMap { $0.split(whereSeparator: \.isWhitespace).map { BoostGuard.key(String($0)) } })
        let before = original.split(whereSeparator: \.isWhitespace).map(String.init)
        let after = boosted.split(whereSeparator: \.isWhitespace).map(String.init)
        let sentence = sentenceIndex(before)
        var output: [String] = []
        for region in BoostGuard.align(before.map(BoostGuard.key), after.map(BoostGuard.key)) {
            switch region {
            case .same(let range):
                output += after[range]
            case .changed(let old, let new):
                let bringsInName = after[new].contains { aiKeys.contains(BoostGuard.key($0)) }
                if bringsInName, !supported(old, in: before, sentence: sentence) { output += before[old] } else { output += after[new] }
            }
        }
        return output.joined(separator: " ")
    }

    private static func supported(_ old: Range<Int>, in heard: [String], sentence: [Int]) -> Bool {
        guard !old.isEmpty else { return hasCue(around: old, in: heard, sentence: sentence) }
        if heard[old].contains(where: { nameWords.contains(BoostGuard.key($0)) }) { return false }
        if partOfFullName(old, in: heard, sentence: sentence) { return false }
        return hasCue(around: old, in: heard, sentence: sentence)
    }

    private static func hasCue(around old: Range<Int>, in heard: [String], sentence: [Int]) -> Bool {
        let here: Int? = old.isEmpty ? (sentence[safe: old.lowerBound] ?? sentence.last) : sentence[old.lowerBound]
        return heard.indices.contains { index in
            !old.contains(index) && sentence[index] == here && cues.contains(BoostGuard.key(heard[index]))
        }
    }

    /// A capitalised heard word right before or after the region, in the same sentence and not a sentence opener, that is
    /// not an AI name: the region is a given name or a surname of someone's full name.
    private static func partOfFullName(_ old: Range<Int>, in heard: [String], sentence: [Int]) -> Bool {
        guard heard[old].allSatisfy({ $0.first?.isUppercase == true }) else { return false }
        func isName(_ index: Int) -> Bool {
            guard heard.indices.contains(index), sentence[index] == sentence[old.lowerBound],
                  let first = heard[index].first, first.isUppercase else { return false }
            let key = BoostGuard.key(heard[index])
            return !key.isEmpty && !nameWords.contains(key) && !WordFrequency.shared.isOrdinary(key)
        }
        return isName(old.lowerBound - 1) || isName(old.upperBound)
    }

    /// The sentence each heard word stands in, counted from 0; a word ending in `.`, `!` or `?` closes its sentence.
    private static func sentenceIndex(_ words: [String]) -> [Int] {
        var index = 0
        return words.map { word in
            defer { if let last = word.last, ".!?".contains(last) { index += 1 } }
            return index
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
