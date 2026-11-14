import Foundation
import NaturalLanguage

/// Whether the word after "wanna" or "gotta" is read as a verb, so the expansion ("want to",
/// "have got to") is only made when the verb reading is established. "I wanna coffee" and "I gotta car"
/// can mean "want a" and "got a", so a noun, an adjective or anything the tagger is unsure of leaves
/// the word as spoken. This is the system's on-device lexical-class tagger, with no word list.
///
/// One instance per dictation: the whole text is tagged once, the first time a word is asked about, and a
/// dictation with no "wanna" or "gotta" never creates a tagger. The answer depends on Apple's model, so it
/// can differ between macOS versions; the fallback is always "leave as spoken".
final class ToneVerbReading {
    private let chunks: [ToneChunk]
    /// How many times this dictation has been tagged: 0 until a word is asked about, then always 1.
    private(set) var passes = 0
    private var verbChunks: Set<Int>?

    init(_ chunks: [ToneChunk]) { self.chunks = chunks }

    func isVerb(at target: Int) -> Bool {
        guard chunks.indices.contains(target), chunks[target].isWord else { return false }
        if verbChunks == nil { verbChunks = tagVerbs() }
        return verbChunks?.contains(target) == true
    }

    private func tagVerbs() -> Set<Int> {
        let text = chunks.map(\.rendered).joined()
        guard !text.isEmpty else { return [] }
        var starts: [String.Index: Int] = [:]
        var position = text.startIndex
        for (index, chunk) in chunks.enumerated() {
            starts[text.index(position, offsetBy: chunk.lead.count)] = index
            position = text.index(position, offsetBy: chunk.rendered.count)
        }
        passes += 1
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        tagger.setLanguage(.english, range: text.startIndex..<text.endIndex)
        var verbs: Set<Int> = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            if tag == .verb, let chunk = starts[range.lowerBound] { verbs.insert(chunk) }
            return true
        }
        return verbs
    }
}
