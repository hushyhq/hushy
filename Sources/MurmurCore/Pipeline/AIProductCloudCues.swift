import Foundation

/// Finds the word "cloud" that is really "Claude" (or "Cloud Code" that is "Claude Code") because the evidence is
/// strong, beyond `AIProductPairing`'s set-against-another-product case. The recogniser writes "Claude" as "Cloud"
/// all the time and the founder dictates about Claude constantly (TRY-103: "Claude has a feature… by Anthropic" came
/// out "Cloud has a feature… by Anthropic"). The common word stays safe, so a swap needs a cue AND no blocker:
/// 1. the same dictation names an Anthropic or AI product or word (`dictationCues`: Anthropic, Opus, Sonnet, Haiku,
///    Claude, Codex, ChatGPT, Gemini, prompt, model, LLM);
/// 2. the focused app is an Anthropic one (Claude desktop, or an agent prompt box: `PipelineSettings.focusedAgentSession`)
///    and "cloud" stands where a name would: before a verb ("Cloud has", "Cloud said"), after "ask"/"tell", before
///    ", can you", or with a possessive ("Cloud's");
/// 3. "Cloud Code" (any case) is "Claude Code" when cue 1 holds or the focused app is an Anthropic one. Google has a
///    "Cloud Code" extension, so it is never changed alone.
/// A blocker is the word right before "cloud" ("the", "in", "Google", "private", "multi-", another AI product's name),
/// the word right after it ("storage", "provider", "GPUs", "based", "model"), a local or vendor word set against it
/// ("cloud or on-device", "AWS and cloud"), and the user's own Dictionary or rejected swaps (checked by the caller).
enum AIProductCloudCues {
    struct Replacement {
        let range: Range<String.Index>
        let text: String
    }

    private static let dictationCues: Set<String> = [
        "anthropic", "opus", "sonnet", "haiku", "claude", "codex", "chatgpt", "gpt", "gemini", "prompt", "prompts",
        "model", "models", "llm", "llms",
    ]
    private static let blockers = AIProductPairing.blockers.union([
        "for", "via", "at", "over", "across", "within", "onto", "off", "codex", "chatgpt", "gemini", "openai",
        "anthropic", "claude", "cursor", "copilot",
    ])
    /// The word right after "cloud" that makes it the place or a service ("cloud model" is the hosted model).
    private static let followVetoes: Set<String> = [
        "storage", "provider", "providers", "computing", "compute", "infrastructure", "hosting", "hosted", "server",
        "servers", "service", "services", "gpu", "gpus", "instance", "instances", "native", "function", "functions",
        "backup", "backups", "sync", "syncing", "drive", "bill", "bills", "cost", "costs", "spend", "platform",
        "vendor", "vendors", "region", "regions", "deployment", "deployments", "based", "first", "only", "edge",
        "database", "databases", "security", "migration", "bucket", "buckets", "model", "models", "llm", "llms",
        "ai", "api", "apis", "inference", "tier",
    ]
    /// What may follow "Cloud Code" when it is Google's extension.
    private static let codeFollowVetoes: Set<String> = [
        "extension", "extensions", "plugin", "plugins", "ide", "intellij", "vscode", "emulator",
    ]
    private static let codePrefixVetoes: Set<String> = [
        "google", "aws", "amazon", "azure", "microsoft", "ibm", "oracle", "alibaba", "apple", "adobe", "salesforce",
        "cloudflare", "digitalocean",
    ]
    /// A local or vendor word that "cloud" is being set against, with or without a connector between.
    private static let setAgainst: Set<String> = [
        "local", "locally", "on", "device", "offline", "edge", "prem", "premise", "premises", "onprem", "aws",
        "azure", "gcp", "google", "amazon", "microsoft", "ibm", "oracle", "alibaba", "s3", "servers", "server",
        "hosting", "kubernetes", "docker", "vps", "self", "selfhosted", "hosted", "lan", "laptop", "mac",
    ]
    private static let connectorWords: Set<String> = ["and", "or", "vs", "versus"]
    private static let subjectVerbs: Set<String> = [
        "has", "had", "is", "was", "does", "did", "said", "says", "can", "could", "will", "would", "should", "wrote",
        "writes", "thinks", "thought", "knows", "gave", "gives", "makes", "made", "seems", "helps", "helped",
        "suggests", "suggested", "recommends", "replied", "responded", "understands", "handles", "offers",
        "supports", "remembers", "keeps", "doesn't", "didn't", "isn't", "wasn't", "can't", "won't", "hasn't",
    ]
    private static let addresseeVerbs: Set<String> = [
        "ask", "asks", "asked", "asking", "tell", "tells", "told", "telling", "ping", "pinged", "thank", "thanks",
    ]
    private static let callWords: Set<String> = [
        "can", "could", "would", "will", "please", "what", "how", "why", "do", "does", "are", "is", "help",
    ]

    private struct Token {
        let lower: String
        let range: Range<String.Index>
        var isPossessive: Bool { lower.hasSuffix("'s") || lower.hasSuffix("’s") }
        /// The word without a trailing possessive ("google's" -> "google").
        var stem: String { isPossessive ? String(lower.dropLast(2)) : lower }
    }

    /// True when "Cloud Code" at these neighbours is Google's, whatever else is said (the main loop's own cues do
    /// not look at the words around it).
    static func isOrdinaryCloudCode(previous: String?, next: String?) -> Bool {
        if let previous {
            let possessive = previous.hasSuffix("'s") || previous.hasSuffix("’s")
            if codePrefixVetoes.contains(possessive ? String(previous.dropLast(2)) : previous) { return true }
        }
        return next.map(codeFollowVetoes.contains) ?? false
    }

    /// The replacements for `text`. `claimed` holds ranges the caller already changes; they are never returned.
    /// `anthropicPlace` is true when the focused app is an Anthropic one (cue 2 and cue 3).
    static func replacements(in text: String, claimed: [Range<String.Index>], anthropicPlace: Bool) -> [Replacement] {
        let tokens = Regex.matchesCaseSensitive(text, "[A-Za-z][A-Za-z'’]*").compactMap { match -> Token? in
            guard let range = Range(match.range, in: text) else { return nil }
            return Token(lower: text[range].lowercased(), range: range)
        }
        func gap(_ left: Int, _ right: Int) -> Substring { text[tokens[left].range.upperBound..<tokens[right].range.lowerBound] }
        /// Adjacent: only spaces or a hyphen between ("multi-cloud"), no punctuation that ends a phrase.
        func adjacent(_ left: Int, _ right: Int) -> Bool {
            let between = gap(left, right)
            return !between.isEmpty && between.allSatisfy { $0.isWhitespace || $0 == "-" }
        }
        func sentenceBreak(_ left: Int, _ right: Int) -> Bool { gap(left, right).contains { ".!?;\n".contains($0) } }
        var result: [Replacement] = []
        for index in tokens.indices {
            let token = tokens[index]
            guard token.stem == "cloud", !claimed.contains(where: { $0.overlaps(token.range) }) else { continue }
            let previous = index > 0 && adjacent(index - 1, index) ? tokens[index - 1] : nil
            if let previous, blockers.contains(previous.stem) { continue }
            let isCode = !token.isPossessive && index + 1 < tokens.count && adjacent(index, index + 1)
                && tokens[index + 1].lower == "code" && !claimed.contains { $0.overlaps(tokens[index + 1].range) }
            let afterWord = isCode ? index + 2 : index + 1
            let next = afterWord < tokens.count && adjacent(afterWord - 1, afterWord) ? tokens[afterWord] : nil
            if isCode {
                if isOrdinaryCloudCode(previous: previous?.lower, next: next?.lower) { continue }
            } else if let next, followVetoes.contains(next.lower) { continue }
            if isSetAgainst(index, tokens: tokens, sentenceBreak: sentenceBreak) { continue }
            let cue1 = tokens.indices.contains { other in
                other != index && dictationCues.contains(tokens[other].lower)
                    && !claimed.contains { $0.overlaps(tokens[other].range) }
            }
            if isCode {
                guard cue1 || anthropicPlace else { continue }
                result.append(Replacement(range: token.range.lowerBound..<tokens[index + 1].range.upperBound, text: "Claude Code"))
                continue
            }
            let cue2 = anthropicPlace && isNamePosition(index, tokens: tokens, previous: previous,
                                                         gap: gap, adjacent: adjacent, sentenceBreak: sentenceBreak)
            guard cue1 || cue2 else { continue }
            let end = text.index(token.range.lowerBound, offsetBy: 5)
            result.append(Replacement(range: token.range.lowerBound..<end, text: "Claude"))
        }
        return result
    }

    /// "cloud or on-device", "local or cloud", "AWS and cloud": a local or vendor word on the far side of a connector.
    private static func isSetAgainst(_ index: Int, tokens: [Token], sentenceBreak: (Int, Int) -> Bool) -> Bool {
        if index + 2 < tokens.count, connectorWords.contains(tokens[index + 1].lower),
           !sentenceBreak(index, index + 2), setAgainst.contains(tokens[index + 2].stem) {
            return true
        }
        return index >= 2 && connectorWords.contains(tokens[index - 1].lower)
            && !sentenceBreak(index - 2, index) && setAgainst.contains(tokens[index - 2].stem)
    }

    /// Cue 2: "cloud" stands where a name would.
    private static func isNamePosition(_ index: Int, tokens: [Token], previous: Token?, gap: (Int, Int) -> Substring,
                                       adjacent: (Int, Int) -> Bool, sentenceBreak: (Int, Int) -> Bool) -> Bool {
        if tokens[index].isPossessive { return true }
        if let previous, addresseeVerbs.contains(previous.lower) { return true }
        guard index + 1 < tokens.count else { return false }
        let next = tokens[index + 1]
        if adjacent(index, index + 1), subjectVerbs.contains(next.lower) { return true }
        // "Cloud, can you …": a call at the start of a clause.
        let between = gap(index, index + 1)
        return previous == nil && callWords.contains(next.lower)
            && between.contains(",") && between.allSatisfy { $0 == "," || $0.isWhitespace }
    }
}
