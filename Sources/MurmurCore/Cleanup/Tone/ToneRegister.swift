import Foundation
import Synchronization

/// The word-level register change for a `DictationTone`, followed by the existing layout style.
///
/// It only ever swaps a word for a word from a small closed set (contractions for Casual, spelled-out
/// forms for Professional), keeps the first-letter case of what was spoken, and never touches backtick
/// literals, quoted spans (curly or straight, kept masked through the layout step too), URLs, paths or
/// identifiers. When a rule is in doubt the word is left as spoken.
///
/// For the same input on the same macOS version the result is the same, but it is not independent of the
/// system: expanding "wanna" and "gotta" asks Apple's on-device language tagger whether the next word is a
/// verb (`ToneVerbReading`), and that answer can differ between macOS versions. The fallback is always
/// "leave as spoken".
public enum ToneRegister {
    public static func apply(_ tone: DictationTone, to text: String, in context: StyleContext) -> String {
        apply(tone, layout: tone.formattingStyle, to: text, in: context)
    }

    /// The register change for `tone`, laid out with `layout` instead of the tone's own style.
    /// Only a layout someone chose earlier and still keeps (see `ToneSettings.keptLayouts`) differs.
    public static func apply(_ tone: DictationTone, layout: WritingStyle, to text: String, in context: StyleContext) -> String {
        // Quoted spans stay masked through the word rules and the layout step, and are restored last.
        let quotes = ToneQuoteMasking(text)
        let rewritten = rewriteWords(tone, in: quotes.masked, apostropheFrom: text)
        let styled = StyleFormatter.apply(layout, to: rewritten, in: context)
        guard LiteralSyntaxProtection.violation(candidate: styled, draft: quotes.masked) == nil,
              let restored = quotes.restore(styled), preservesQuotedSpans(input: text, output: restored)
        else {
            if !ToneQuoteMasking.quotedSpans(in: text).isEmpty { quoteRefusals.withLock { $0 += 1 } }
            return text
        }
        return restored
    }

    /// How many times the tone pass gave the text back unchanged because a quoted span would not have
    /// survived it byte for byte. A count only; no text is kept.
    static var quoteGuardRefusals: Int { quoteRefusals.withLock { $0 } }
    private static let quoteRefusals = Mutex(0)

    /// Every quoted span of the input is still in the output, whole.
    static func preservesQuotedSpans(input: String, output: String) -> Bool {
        ToneQuoteMasking.quotedSpans(in: input).allSatisfy { output.contains($0) }
    }

    /// The register change alone, without layout. Returns the input when nothing applies or when
    /// the result would alter a literal.
    static func rewriteWords(_ tone: DictationTone, in text: String, apostropheFrom source: String? = nil) -> String {
        guard tone != .refined else { return text }
        let quotes = ToneQuoteMasking(text)
        let protected = LiteralSyntaxProtection(quotes.masked, codeContext: true)
        let (prefix, chunks) = ToneText.chunks(of: protected.masked)
        let rewritten: [ToneChunk]
        switch tone {
        case .refined: return text
        case .casual: rewritten = ToneCasualRules.rewrite(chunks, apostrophe: ToneText.apostrophe(for: source ?? text))
        case .professional: rewritten = ToneProfessionalRules.rewrite(chunks)
        }
        let masked = ToneText.render(prefix: prefix, chunks: rewritten)
        guard let literalsBack = protected.restore(masked), let restored = quotes.restore(literalsBack),
              LiteralSyntaxProtection.violation(candidate: restored, draft: text) == nil else { return text }
        return restored
    }

    /// Normalised words (lowercase, straight apostrophes, punctuation stripped) that appear in
    /// `output` more often than in `input`, with how many extra times.
    public static func introducedWords(from input: String, to output: String) -> [String: Int] {
        var remaining = wordCounts(input)
        var introduced: [String: Int] = [:]
        for word in normalisedWords(output) {
            if let count = remaining[word], count > 0 {
                remaining[word] = count - 1
            } else {
                introduced[word, default: 0] += 1
            }
        }
        return introduced
    }

    /// The only words a tone may introduce. Empty for Refined.
    public static func closedIntroductions(for tone: DictationTone) -> Set<String> {
        switch tone {
        case .refined: []
        case .casual: ToneCasualRules.introducedForms
        case .professional: ToneProfessionalRules.introducedWords
        }
    }

    private static func wordCounts(_ text: String) -> [String: Int] {
        normalisedWords(text).reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    private static func normalisedWords(_ text: String) -> [String] {
        let normalised = ToneText.normalised(text).lowercased()
        return normalised
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }
}
