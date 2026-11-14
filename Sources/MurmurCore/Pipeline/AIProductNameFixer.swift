import Foundation
import NaturalLanguage

/// Spelling for the AI products people dictate about, after the recognizer has finished. The recognizer writes "Claude"
/// as "clawed", "claud" or "clod", "Claude Code" as "clawed code", "ChatGPT" as "chat gpt". Those are real words or
/// spellings no Dictionary holds, and `InstalledNameFixer` only knows apps that are installed, so this is the built-in
/// list. A product name is a name, not a rule over ordinary English, so a swap happens only where something says it is
/// the product:
/// - the screen names it (`PipelineSettings.contextTerms`), or the frontmost app is that product;
/// - a word of the same clause points at AI or coding work ("ask clawed to refactor this"); or
/// - the heard words can only be the name (the two words "clawed code", "chat gpt").
/// "the cat clawed the sofa" stays as heard: with no cue there is no swap, and a verb's own grammar (a noun or pronoun
/// before it, an object after it) stops the swap even where a cue is near. "cloud" is never a single-word mishearing,
/// since it is far too common; only the two words "cloud code" are, and only with a cue other than "code", the
/// word "cloud" set directly against another AI product ("Codex or cloud", `AIProductPairing`), and the word "cloud"
/// with strong evidence and no blocker (`AIProductCloudCues`: an AI word in the dictation, or an Anthropic app and a
/// name position). The model names (Sonnet, Opus, Haiku, Codex, Gemini, GPT, Claude Code) are spelled by the same rule in
/// `AIModelNames`: "son at agent" is "Sonnet agent" with an AI cue, "my son at school" stays.
public enum AIProductNameFixer {
    private struct Alias {
        let words: [String]
        /// The heard words can only mean the product, so no cue is needed.
        let standalone: Bool
    }

    private struct Product {
        let name: String
        let aliases: [Alias]
        /// A context term or the frontmost app's name containing one of these means the product is in play.
        let evidenceKeys: [String]
        /// Words of the same clause that make the product likely.
        let cues: Set<String>
        /// Words of the same clause that make the heard word an ordinary one ("codecs" with "video").
        let vetoes: Set<String>
    }

    private static let aiCues: Set<String> = [
        "prompt", "prompts", "prompting", "model", "models", "anthropic", "openai", "cursor", "api", "apis",
        "agent", "agents", "subagent", "subagents", "ask", "asks", "asked", "asking", "chat", "chatgpt", "gpt",
        "llm", "llms", "ai", "codex", "gemini", "copilot", "sonnet", "opus", "haiku", "claude", "chatbot",
        "assistant", "token", "tokens", "mcp", "terminal", "cli", "refactor", "repo", "ide", "skills",
    ]
    private static let codeCues: Set<String> = ["code", "coding"]
    private static let dictationCues: Set<String> = [
        "dictation", "dictate", "dictating", "voice", "speech", "transcription", "transcribe", "transcribed",
        "microphone", "hushy", "wispr", "superwhisper", "macwhisper", "raycast", "competitor", "alternative",
        "app", "tool", "subscription", "pricing", "versus", "vs", "compared",
    ]
    private static let mediaVetoes: Set<String> = [
        "video", "videos", "audio", "h264", "h265", "hevc", "mp3", "mp4", "encode", "encoding", "encoder",
        "decode", "decoding", "decoder", "ffmpeg", "stream", "streaming", "media", "playback", "compression",
    ]

    /// The products this fixer spells, by name (the names check accepts them as known names, `KnownProductNames`).
    static var productNames: [String] { products.map(\.name) }

    private static let products: [Product] = [
        Product(name: "Claude Code",
                aliases: [Alias(words: ["clawed", "code"], standalone: true), Alias(words: ["claud", "code"], standalone: true),
                          Alias(words: ["clod", "code"], standalone: true), Alias(words: ["cloud", "code"], standalone: false)],
                evidenceKeys: ["claude"], cues: aiCues, vetoes: []),
        Product(name: "Claude",
                aliases: [Alias(words: ["clawed"], standalone: false), Alias(words: ["claud"], standalone: false),
                          Alias(words: ["clod"], standalone: false)],
                evidenceKeys: ["claude", "anthropic"], cues: aiCues.union(codeCues), vetoes: []),
        Product(name: "ChatGPT",
                aliases: ["chat gpt", "chat g p t", "chat gbt", "chat gtp", "chatgpt"].map {
                    Alias(words: $0.split(separator: " ").map(String.init), standalone: true)
                },
                evidenceKeys: ["chatgpt"], cues: [], vetoes: []),
        Product(name: "Codex",
                aliases: [Alias(words: ["codecs"], standalone: false), Alias(words: ["kodex"], standalone: false),
                          Alias(words: ["code", "x"], standalone: false)],
                evidenceKeys: ["codex"], cues: aiCues.subtracting(["chat"]), vetoes: mediaVetoes),
        Product(name: "Wispr Flow",
                aliases: [Alias(words: ["whisper", "flow"], standalone: false), Alias(words: ["wisper", "flow"], standalone: false),
                          Alias(words: ["whispr", "flow"], standalone: false), Alias(words: ["wispr", "flow"], standalone: true)],
                evidenceKeys: ["wispr"], cues: aiCues.union(dictationCues), vetoes: []),
        Product(name: "Superwhisper",
                aliases: [Alias(words: ["super", "whisper"], standalone: false), Alias(words: ["super", "wisper"], standalone: false),
                          Alias(words: ["superwhisper"], standalone: true)],
                evidenceKeys: ["superwhisper"], cues: aiCues.union(dictationCues), vetoes: []),
    ]

    /// How far from the heard words a cue may stand, inside the same clause.
    private static let cueDistance = 6
    private static let determiners: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "my", "your", "our", "his", "her", "their", "its",
        "some", "any", "each", "every", "another",
    ]
    private static let subjectPronouns: Set<String> = ["he", "she", "it", "they", "who", "which", "that", "we", "you", "i"]
    /// What follows "clawed" when it is the verb ("clawed the sofa", "clawed at it", "clawed his way out").
    private static let objectWords: Set<String> = [
        "the", "a", "an", "at", "his", "her", "their", "its", "my", "your", "our", "me", "him", "them", "us", "it",
        "back", "through", "up", "out", "away", "into", "over", "off", "down", "open", "free",
    ]

    private struct Token {
        let word: String
        let lower: String
        let range: Range<String.Index>
    }

    public static func fix(_ text: String, settings: PipelineSettings) -> String {
        guard !text.isEmpty else { return text }
        let tokens = Regex.matchesCaseSensitive(text, "[A-Za-z][A-Za-z'’-]*").compactMap { match -> Token? in
            guard let range = Range(match.range, in: text) else { return nil }
            let word = String(text[range])
            return Token(word: word, lower: word.lowercased(), range: range)
        }
        guard !tokens.isEmpty else { return text }
        let screen = settings.contextTerms.map { $0.lowercased() }
        let frontmost = frontmostName(settings)
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var changes: [(Range<String.Index>, String)] = []
        var index = 0
        while index < tokens.count {
            guard let hit = match(at: index, in: tokens, text: text) else { index += 1; continue }
            let (product, alias) = hit
            let end = index + alias.words.count - 1
            let heard = String(text[tokens[index].range.lowerBound..<tokens[end].range.upperBound])
            let advance = end + 1
            defer { index = max(index + 1, advance) }
            guard heard != product.name, !settings.personalizer.protectsHeardWord(heard),
                  !settings.keepHeard.blocks(heardKey: VocabularySwap.key(heard), writtenKey: VocabularySwap.key(product.name))
            else { continue }
            let clause = clauseBounds(around: index, to: end, in: tokens, text: text)
            let nearby = (max(clause.lowerBound, index - cueDistance)...min(clause.upperBound, end + cueDistance))
                .filter { !(index...end).contains($0) }.map { tokens[$0].lower }
            if nearby.contains { product.vetoes.contains($0) } { continue }
            if alias.words == ["cloud", "code"], AIProductCloudCues.isOrdinaryCloudCode(
                previous: index > 0 ? tokens[index - 1].lower : nil,
                next: end + 1 < tokens.count ? tokens[end + 1].lower : nil) { continue }
            if !alias.standalone {
                let evidence = isOnScreen(product, screen) || isFrontmost(product, frontmost, settings)
                    || nearby.contains { product.cues.contains($0) }
                guard evidence else { continue }
            }
            if alias.words.count == 1,
               !isNamePosition(heard: tokens[index].lower, at: index, end: end, clause: clause, in: tokens, tagger: tagger) {
                continue
            }
            changes.append((tokens[index].range.lowerBound..<tokens[end].range.upperBound, product.name))
        }
        for range in AIProductPairing.cloudRanges(in: text, claimed: changes.map(\.0)) {
            let heard = String(text[range])
            guard !settings.personalizer.protectsHeardWord(heard),
                  !settings.keepHeard.blocks(heardKey: VocabularySwap.key(heard), writtenKey: VocabularySwap.key("Claude"))
            else { continue }
            changes.append((range, "Claude"))
        }
        guard let claude = products.first(where: { $0.name == "Claude" }) else { return text }
        let anthropicPlace = settings.focusedAgentSession || isFrontmost(claude, frontmost, settings)
        for found in AIProductCloudCues.replacements(in: text, claimed: changes.map(\.0), anthropicPlace: anthropicPlace) {
            let heard = String(text[found.range])
            guard !settings.personalizer.protectsHeardWord(heard),
                  !settings.keepHeard.blocks(heardKey: VocabularySwap.key(heard), writtenKey: VocabularySwap.key(found.text))
            else { continue }
            changes.append((found.range, found.text))
        }
        for found in AIModelNames.replacements(in: text, claimed: changes.map(\.0), anthropicPlace: anthropicPlace, screen: screen) {
            let heard = String(text[found.range])
            guard !settings.personalizer.protectsHeardWord(heard),
                  !settings.keepHeard.blocks(heardKey: VocabularySwap.key(heard), writtenKey: VocabularySwap.key(found.text))
            else { continue }
            changes.append((found.range, found.text))
        }
        var output = text
        for (range, replacement) in changes.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            output.replaceSubrange(range, with: replacement)
        }
        return output
    }

    /// The product and the heard words that start at `index`, longest first, separated by plain whitespace only.
    private static func match(at index: Int, in tokens: [Token], text: String) -> (Product, Alias)? {
        var best: (Product, Alias)?
        for product in products {
            for alias in product.aliases where index + alias.words.count <= tokens.count {
                let fits = alias.words.indices.allSatisfy { offset in
                    guard tokens[index + offset].lower == alias.words[offset] else { return false }
                    guard offset > 0 else { return true }
                    let gap = text[tokens[index + offset - 1].range.upperBound..<tokens[index + offset].range.lowerBound]
                    return !gap.isEmpty && gap.allSatisfy(\.isWhitespace)
                }
                if fits, alias.words.count > (best?.1.words.count ?? 0) { best = (product, alias) }
            }
        }
        return best
    }

    /// The token range of the clause that holds `start...end`: it stops at sentence marks and commas.
    private static func clauseBounds(around start: Int, to end: Int, in tokens: [Token], text: String) -> ClosedRange<Int> {
        func breaks(_ left: Int, _ right: Int) -> Bool {
            text[tokens[left].range.upperBound..<tokens[right].range.lowerBound].contains { ".!?;,:\n".contains($0) }
        }
        var low = start
        while low > 0, !breaks(low - 1, low) { low -= 1 }
        var high = end
        while high + 1 < tokens.count, !breaks(high, high + 1) { high += 1 }
        return low...high
    }

    /// True when a single heard word is used as a name, not as the English word it spells ("a clod of dirt",
    /// "the cat clawed the sofa", "it clawed at the door").
    private static func isNamePosition(heard: String, at index: Int, end: Int, clause: ClosedRange<Int>,
                                       in tokens: [Token], tagger: NLTagger) -> Bool {
        let previous = index > clause.lowerBound ? tokens[index - 1] : nil
        let next = end < clause.upperBound ? tokens[end + 1] : nil
        if let previous, determiners.contains(previous.lower) || previous.lower.hasSuffix("'s") || previous.lower.hasSuffix("’s") {
            return false
        }
        if heard == "clod", next?.lower == "of" { return false }
        guard heard == "clawed" else { return true }
        if let previous {
            if subjectPronouns.contains(previous.lower) { return false }
            // A word that opens the clause may be an imperative ("use clawed"), which the tagger reads as a noun.
            let opensClause = index - 1 == clause.lowerBound
            let afterDeterminer = !opensClause && determiners.contains(tokens[index - 2].lower)
            let tagged = tagger.tag(at: previous.range.lowerBound, unit: .word, scheme: .lexicalClass).0 == .noun
            if afterDeterminer || (tagged && !opensClause) { return false }
        }
        if let next, objectWords.contains(next.lower) { return false }
        return true
    }

    private static func isOnScreen(_ product: Product, _ screen: [String]) -> Bool {
        screen.contains { term in product.evidenceKeys.contains { term.contains($0) } }
    }

    private static func frontmostName(_ settings: PipelineSettings) -> String? {
        guard let id = settings.frontmostBundleID else { return nil }
        return settings.installedApps.first { $0.bundleID == id }?.name.lowercased()
    }

    private static func isFrontmost(_ product: Product, _ name: String?, _ settings: PipelineSettings) -> Bool {
        if let name, product.evidenceKeys.contains { name.contains($0) } { return true }
        guard let id = settings.frontmostBundleID else { return false }
        return product.evidenceKeys.contains { AppNameMatcher.bundleIDs[$0] == id }
    }
}
