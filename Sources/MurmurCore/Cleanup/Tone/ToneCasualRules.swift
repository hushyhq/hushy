import Foundation

/// Casual register: contract a pronoun with its auxiliary, and an auxiliary with "not".
/// Nothing else. Noun + "is" is never contracted, and nothing is contracted at the end of a clause.
enum ToneCasualRules {
    /// Pronoun -> auxiliary -> contraction suffix (the apostrophe is written as `'`).
    static let pronounAuxiliary: [String: [String: String]] = [
        "i": ["am": "'m", "will": "'ll"],
        "we": ["are": "'re", "will": "'ll"],
        "you": ["are": "'re", "will": "'ll"],
        "they": ["are": "'re", "will": "'ll"],
        "he": ["is": "'s", "will": "'ll"],
        "she": ["is": "'s", "will": "'ll"],
        "it": ["is": "'s"],
        "that": ["is": "'s"],
    ]

    /// Auxiliary + "not" -> contraction.
    static let auxiliaryNot: [String: String] = [
        "do": "don't", "does": "doesn't", "did": "didn't", "is": "isn't", "are": "aren't", "will": "won't",
    ]

    static let cannot = ("cannot", "can't")

    /// A pronoun after one of these is often at the end of its clause ("what it is"), where the
    /// contracted form is wrong. The brief rule: when in doubt, leave it.
    private static let elisionHazard: Set<String> = [
        "what", "where", "who", "why", "how", "which", "than", "as", "whether",
    ]

    static var introducedForms: Set<String> {
        var forms = Set<String>()
        for (pronoun, auxiliaries) in pronounAuxiliary {
            for suffix in auxiliaries.values { forms.insert(pronoun + suffix) }
        }
        forms.formUnion(auxiliaryNot.values)
        forms.insert(cannot.1)
        return forms
    }

    static func rewrite(_ chunks: [ToneChunk], apostrophe: String) -> [ToneChunk] {
        var output: [ToneChunk] = []
        var index = 0
        while index < chunks.count {
            if let merged = pronounContraction(chunks, at: index, apostrophe: apostrophe) {
                output.append(merged)
                index += 2
            } else if let merged = negativeContraction(chunks, at: index, apostrophe: apostrophe) {
                output.append(merged)
                index += 2
            } else if let single = cannotContraction(chunks[index], apostrophe: apostrophe) {
                output.append(single)
                index += 1
            } else {
                output.append(chunks[index])
                index += 1
            }
        }
        return output
    }

    private static func join(_ first: ToneChunk, _ second: ToneChunk, core: String) -> ToneChunk {
        ToneChunk(lead: first.lead, core: core, trail: second.trail, gap: second.gap, isWord: true)
    }

    private static func isPronoun(_ chunk: ToneChunk, _ key: String) -> Bool {
        guard chunk.isWord else { return false }
        // A lowercase "i" is the same word; the contraction is written with a capital I.
        if key == "i" { return chunk.core == "I" || chunk.core == "i" }
        return chunk.core == key || chunk.core == ToneText.capitalisingFirst(key)
    }

    /// A word follows in the same clause (or a digit), so the contraction does not end a clause.
    private static func clauseContinues(_ chunks: [ToneChunk], after index: Int) -> Bool {
        guard index + 1 < chunks.count, chunks[index].trail.isEmpty, !chunks[index].gapHasNewline else { return false }
        let next = chunks[index + 1]
        return next.isWord || next.core.first?.isNumber == true
    }

    private static func pronounContraction(_ chunks: [ToneChunk], at index: Int, apostrophe: String) -> ToneChunk? {
        guard index + 1 < chunks.count else { return nil }
        let first = chunks[index]
        let second = chunks[index + 1]
        guard first.joinsNext, second.isWord else { return nil }
        for (pronoun, auxiliaries) in pronounAuxiliary where isPronoun(first, pronoun) {
            guard let suffix = auxiliaries[second.core] else { return nil }
            guard clauseContinues(chunks, after: index + 1) else { return nil }
            // "I will not" is handled as "will not" -> "won't".
            if second.core == "will", index + 2 < chunks.count, chunks[index + 2].core == "not" { return nil }
            if index > 0, chunks[index - 1].isWord, chunks[index - 1].trail.isEmpty,
               elisionHazard.contains(chunks[index - 1].lowered) { return nil }
            let spoken = pronoun == "i" ? "I" : first.core
            return join(first, second, core: spoken + suffix.replacingOccurrences(of: "'", with: apostrophe))
        }
        return nil
    }

    private static func negativeContraction(_ chunks: [ToneChunk], at index: Int, apostrophe: String) -> ToneChunk? {
        guard index + 1 < chunks.count else { return nil }
        let first = chunks[index]
        let second = chunks[index + 1]
        guard first.joinsNext, first.isWord, second.isWord, second.core == "not" else { return nil }
        let key = ToneText.normalised(first.core).lowercased()
        guard let contraction = auxiliaryNot[key], ToneText.hasPlainCase(first.core) else { return nil }
        // Capitalised "Is not" / "Are not" is usually an inverted question.
        if first.core.first?.isUppercase == true, key == "is" || key == "are" || key == "will" { return nil }
        if index + 2 < chunks.count, chunks[index + 2].core == "only" { return nil }
        let core = ToneText.matchCase(contraction, like: first.core).replacingOccurrences(of: "'", with: apostrophe)
        return join(first, second, core: core)
    }

    private static func cannotContraction(_ chunk: ToneChunk, apostrophe: String) -> ToneChunk? {
        guard chunk.isWord, chunk.core == cannot.0 || chunk.core == ToneText.capitalisingFirst(cannot.0) else { return nil }
        return chunk.replacingCore(ToneText.matchCase(cannot.1, like: chunk.core).replacingOccurrences(of: "'", with: apostrophe))
    }
}
