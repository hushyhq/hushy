import Foundation

/// What a register answer (Professional, Casual, Prompt) brings besides what was said, told apart into wording and
/// content. A rewrite in a register changes how a thing is said: "look at" becomes "review", "when you get a sec" becomes
/// "when you get a chance", "can you" becomes "would you please". A reply, or a model's invention for a dictation that lost
/// its start, adds something that was not said: a thing done, a thing promised, an answer.
///
/// Letters alone cannot tell the two apart for a short message (`RewriteAccount.isRewrite(under:)` needs 60 kept letters
/// before it loosens), so this looks at the words:
/// - **Glue and politeness weigh little.** Words that carry no content ("would", "could", "please", "since", "it is") and a
///   few that only soften or apologise ("appreciate", "regarding", "unfortunately") may be added at a small price.
/// - **A content word has to replace a word that was said.** Each content word the answer brings that was not said has to
///   stand in for a word that was said and is gone ("review" for "look", "unable" for "can't", "at the moment" for "right
///   now"). A filler, pronoun, preposition or conjunction that is gone makes room for nothing: a fragment that lost its verb
///   keeps those ("boxes for me", "new office when you have a minute"), and a model that writes the verb for it rewrites them
///   ("send boxes to me", "a minute to discuss the new office"). A word added with only those gone is something new ("send",
///   "opening", "contract").
/// - **No new speaker.** A first-person clause the dictation does not have is the model talking as the speaker: a promise
///   ("I will…", "I can…") when nothing like it was said, or "I am…", "I have…" when the speaker never spoke of themselves.
/// - **Nothing said twice that was said once.** An answer that repeats a content word more often than it was said is
///   filling space.
///
/// There is no list of phrases and no list of replies. The only lists are words that carry no content (glue, politeness,
/// fillers) and irregular verb forms; the rest is counted.
enum RegisterWording {
    /// Words that hold a sentence together or say who or when without saying what, plus the polite openers and closers of a
    /// message. Spelled as `WordRelation.collapsed` spells them (no apostrophes: "won't" is "wont").
    static let glue: Set<String> = [
        "a", "an", "the", "and", "or", "but", "nor", "so", "if", "as", "than", "that", "this", "these", "those",
        "it", "its", "i", "im", "ill", "id", "ive", "me", "my", "mine", "myself", "we", "were", "us", "our", "ours", "you", "youre",
        "youll", "youd", "youve", "your", "yours", "he", "hes", "him", "his", "she", "shes", "her", "they", "theyre", "them",
        "their", "to", "of", "in", "on", "at", "by", "for", "with", "from", "into", "onto", "about", "over", "under", "after",
        "before", "during", "until", "while", "since", "because", "though", "although", "when", "where", "which", "who", "whom",
        "whose", "what", "how", "why", "is", "isnt", "am", "are", "arent", "was", "wasnt", "werent", "be", "been", "being", "do",
        "does", "did", "done", "dont", "doesnt", "didnt", "have", "has", "had", "having", "havent", "hasnt", "hadnt", "not", "no",
        "can", "cant", "cannot", "will", "wont", "shall", "may", "might", "must", "should", "shouldnt", "would", "wouldnt",
        "could", "couldnt", "also", "just", "very", "really", "too", "then", "now", "still", "yet", "already", "again", "even",
        "only", "more", "most", "much", "many", "some", "any", "all", "each", "every", "both", "either", "let", "lets", "hi",
        "hello", "hey", "dear", "thanks", "thank", "please", "kindly", "regards", "sincerely", "best",
        // Particles ("follow up", "sent over", "get back"), "whether", and the "o'clock" of "three o'clock".
        "up", "out", "off", "back", "over", "down", "away", "whether", "oclock",
    ]

    /// Words that soften, thank or apologise: wording around a message, not part of what it says.
    static let courtesy: Set<String> = [
        "appreciate", "appreciated", "grateful", "regarding", "concerning", "unfortunately", "apologies", "apologize", "apologise",
        "sorry", "perhaps", "wondering",
    ]

    /// Words a speaker says to fill a sentence. Dropping one is not dropping content.
    static let filler: Set<String> = [
        "um", "uh", "er", "ah", "hmm", "like", "okay", "ok", "so", "well", "actually", "basically", "literally", "honestly",
        "kinda", "sorta", "yeah", "gonna", "wanna", "kind", "sort", "just", "right", "totally",
    ]

    /// Glue words that say who, where, or how two clauses join, not what is said: gone, they make no room for a content word
    /// (`rewordsFaithfully`).
    static let structure: Set<String> = [
        "i", "me", "my", "mine", "myself", "we", "us", "our", "ours", "you", "your", "yours", "he", "him", "his", "she", "her",
        "they", "them", "their", "it", "its", "to", "of", "in", "on", "at", "by", "for", "with", "from", "into", "onto", "about",
        "over", "under", "after", "before", "during", "until", "up", "out", "off", "back", "down", "away", "when", "because", "as",
        "since", "and", "but", "or", "so", "if", "while", "though", "although", "that", "which", "who", "where", "than",
        "whether", "nor",
    ]

    static func isGlue(_ word: String) -> Bool { glue.contains(word) || courtesy.contains(word) }

    // MARK: Speaker

    /// Whether `answer` speaks as the speaker where `source` does not: a first-person promise or ability when the source
    /// has no first-person modal ("I will send it", "I can help"), or any first-person clause but a polite one when the
    /// source has no first person at all ("I am available", "I have a ticket").
    static func inventsSpeaker(answer: String, source: String) -> Bool {
        let said = speakerTokens(source), written = speakerTokens(answer)
        let speaks = said.contains { firstPerson.contains($0) }
        let promised = promises(said)
        for index in written.indices where firstPerson.contains(written[index]) {
            let next = index + 1 < written.count ? written[index + 1] : ""
            let after = index + 2 < written.count ? written[index + 2] : ""
            if commits(next, after) {
                // "I go with that" written "I'll go with that": the speaker said what they do, the answer says it will be done.
                if !promised, !restatesSaid(written, from: index + 1, said: said) { return true }
            } else if !speaks, !courteous(next, after) {
                return true
            }
        }
        return false
    }

    private static let firstPerson: Set<String> = ["i", "we"]
    /// Adverbs that sit between a speaker and the verb without changing it ("I would really appreciate").
    private static let softeners: Set<String> = ["really", "also", "truly", "greatly", "just", "kindly", "still", "only"]

    private static func speakerTokens(_ text: String) -> [String] { tokens(text).filter { !softeners.contains($0) } }
    private static let promising: Set<String> = ["will", "shall", "can", "must", "promise", "promised", "plan", "plans"]
    /// "I would like", "I would love": a polite way to ask, not a promise.
    private static let politeWould: Set<String> = ["like", "love", "appreciate", "prefer", "ask", "request", "welcome", "be"]
    /// What a speaker may start a clause with when the source never spoke of themselves: thanks, regret, a reason to write.
    private static let courteousStarts: Set<String> = ["appreciate", "apologize", "apologise", "regret", "thank", "wanted", "wish"]
    private static let courteousBeing: Set<String> = ["sorry", "grateful", "writing", "following", "reaching", "contacting", "pleased"]

    private static func commits(_ next: String, _ after: String) -> Bool {
        // "I must have missed it": a guess about the past, not a promise.
        if next == "must" && after == "have" { return false }
        // "I can't take it on", "I will not be able to": what the speaker cannot or will not do is a limit, not a promise.
        // A dictation with no first person has none of these either (the check for a speaker with nothing to say), and the
        // added negation is judged by `NegationPolarity`.
        if after == "not" || after == "never" { return false }
        if promising.contains(next) { return true }
        if next == "would" { return !politeWould.contains(after) }
        return (next == "am" || next == "are") && after == "going"
    }

    /// Words that stand between "I" and the verb it governs without being it ("I am going to go", "I will also check",
    /// "I am not going to").
    private static let verbLeads: Set<String> = [
        "am", "are", "was", "were", "will", "shall", "would", "can", "must", "may", "might", "could", "should", "going", "gonna",
        "to", "do", "did", "not", "never", "also", "just", "really", "still", "only", "definitely", "certainly", "gladly",
        "happily", "kindly", "truly", "then", "now", "already", "always",
    ]
    /// Verbs that only carry another verb ("be able to go", "have to go", "need to go").
    private static let carriers: Set<String> = ["have", "has", "had", "need", "needs", "want", "wants", "got", "ready", "be"]

    /// The verb the first-person clause at `start` is about: the first word that is not a modal, an auxiliary, a negation,
    /// an adverb or a carrier ("be able to", "have to").
    private static func clauseVerb(_ tokens: [String], from start: Int) -> String? {
        var index = start
        while index < tokens.count {
            let word = tokens[index]
            if verbLeads.contains(word) { index += 1; continue }
            let next = index + 1 < tokens.count ? tokens[index + 1] : ""
            if word == "be", next == "able" { index += 2; continue }
            if word == "able", next == "to" { index += 2; continue }
            if carriers.contains(word), next == "to" { index += 2; continue }
            return word
        }
        return nil
    }

    /// Whether the answer's first-person clause at `start` does what the speaker said they do: its verb is a verb the
    /// speaker put after "I" or "we" (in another tense or form). "I go with that" said, "I will go with that" written:
    /// a commitment the speaker made themselves, not one the model made for them. A verb the speaker never put after
    /// "I" ("can you review it", "I need you to review it" for "I will review it") is still a new promise.
    private static func restatesSaid(_ written: [String], from start: Int, said: [String]) -> Bool {
        guard let verb = clauseVerb(written, from: start) else { return false }
        return said.indices.contains { index in
            firstPerson.contains(said[index]) && clauseVerb(said, from: index + 1).map { sameVerb($0, verb) || WordRelation.isInflection($0, verb) } == true
        }
    }

    private static func promises(_ said: [String]) -> Bool {
        for index in said.indices where firstPerson.contains(said[index]) {
            let next = index + 1 < said.count ? said[index + 1] : ""
            let after = index + 2 < said.count ? said[index + 2] : ""
            if commits(next, after) { return true }
        }
        return false
    }

    private static func courteous(_ next: String, _ after: String) -> Bool {
        if courteousStarts.contains(next) { return true }
        if next == "would" { return politeWould.contains(after) }
        return next == "am" && courteousBeing.contains(after)
    }

    /// Lower-case words, contractions written out ("won't" as "will not", "I'd" as "I would", "I'm" as "I am"), letters and
    /// digits only.
    static func tokens(_ text: String) -> [String] {
        var spelled = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        for (short, long) in contractions { spelled = spelled.replacingOccurrences(of: short, with: long) }
        spelled = spelled.replacingOccurrences(of: "'s", with: "")
        return spelled.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static let contractions: [(String, String)] = [
        ("won't", "will not"), ("can't", "can not"), ("cannot", "can not"), ("n't", " not"), ("'ll", " will"), ("'d", " would"), ("'m", " am"),
        ("'re", " are"), ("'ve", " have"),
    ]

    // MARK: Tenses

    /// Whether two words are one verb in two forms that `WordRelation` cannot see: an irregular past or participle.
    static func sameVerb(_ a: String, _ b: String) -> Bool {
        a == b || (irregular[a] ?? a) == (irregular[b] ?? b)
    }

    private static let irregular: [String: String] = [
        "got": "get", "gotten": "get", "gets": "get", "getting": "get", "went": "go", "gone": "go", "goes": "go", "going": "go",
        "saw": "see", "seen": "see", "took": "take", "taken": "take", "made": "make", "gave": "give", "given": "give", "sent": "send",
        "told": "tell", "said": "say", "had": "have", "kept": "keep", "knew": "know", "known": "know", "thought": "think",
        "spoke": "speak", "spoken": "speak", "wrote": "write", "written": "write", "came": "come", "left": "leave", "met": "meet",
        "brought": "bring", "bought": "buy", "found": "find", "felt": "feel", "ran": "run", "began": "begin", "begun": "begin",
        "understood": "understand", "paid": "pay", "heard": "hear", "held": "hold", "built": "build", "lost": "lose",
    ]

    // MARK: Echo

    /// Content words `answer` says more often than `source` did (by spelling).
    static func repeated(answer: [String], source: [String]) -> [String] {
        var said: [String: Int] = [:], written: [String: Int] = [:]
        for word in source { said[word, default: 0] += 1 }
        for word in answer where !isGlue(word) && !filler.contains(word) { written[word, default: 0] += 1 }
        return written.filter { word, count in count > 1 && count > (said[word] ?? 0) }.keys.sorted()
    }
}

extension RewriteAccount {
    /// Whether the text is the source reworded: it brings wording, not content (see `RegisterWording`). All of:
    /// - it does not speak as the speaker where the source does not, and repeats nothing the source said once;
    /// - each content word it brings that the source does not have stands in for a word of the source that is gone (not a
    ///   filler, pronoun, preposition or conjunction);
    /// - what it brings is small beside what it keeps in the source's order: content words weigh 6 a letter, except as many
    ///   letters as the source's content words that are gone (a swap), which weigh 2 like glue and politeness words; moved
    ///   words weigh 1; and the sum may reach `registerWordingLooseness` times the kept letters.
    ///
    /// Only meaningful under a register: `isRewrite(under:)` is the one door.
    public var rewordsFaithfully: Bool {
        guard !inventsSpeaker, repeatedWords.isEmpty else { return false }
        // The same verb in another tense ("get" written, "got" said) is neither new nor gone.
        var gone = droppedWords.filter { !RegisterWording.filler.contains($0) && !RegisterWording.structure.contains($0) }
        var content: [String] = []
        for word in newWords where !RegisterWording.isGlue(word) {
            if let same = gone.firstIndex(where: { RegisterWording.sameVerb($0, word) }) { gone.remove(at: same) } else { content.append(word) }
        }
        guard content.count <= gone.count else { return false }
        let contentLetters = content.reduce(0) { $0 + $1.count }
        let goneLetters = gone.filter { !RegisterWording.isGlue($0) }.reduce(0) { $0 + $1.count }
        let glueLetters = max(0, addedLetters - contentLetters)
        // A content word that takes the place of one that is gone costs what glue costs; letters beyond that are new.
        let swapped = min(contentLetters, goneLetters)
        let cost = 6 * (contentLetters - swapped) + Self.glueWeight * (swapped + glueLetters) + elsewhereLetters
        return cost <= Self.registerWordingLooseness * inOrderLetters
    }

    /// What a letter of glue or politeness the text adds weighs, against 6 for a letter of content.
    static let glueWeight = 2
    /// What the weighted sum above may reach, in kept letters (the bound for a long register answer is the same 4).
    static let registerWordingLooseness = 4
}
