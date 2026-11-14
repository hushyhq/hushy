import Foundation
import Testing

@testable import MurmurCore

/// The word-level register change only (`rewriteWords`), then the full tone path (`apply`).
@Suite("Tone register")
struct ToneRegisterTests {
    private func casual(_ text: String) -> String { ToneRegister.rewriteWords(.casual, in: text) }
    private func professional(_ text: String) -> String { ToneRegister.rewriteWords(.professional, in: text) }

    // MARK: Refined

    @Test("Refined never changes a word")
    func refinedChangesNothing() {
        for text in Self.corpus {
            #expect(ToneRegister.rewriteWords(.refined, in: text) == text)
            let output = ToneRegister.apply(.refined, to: text, in: .workMessages)
            #expect(ToneRegister.introducedWords(from: text, to: output).isEmpty, "\(text) -> \(output)")
            #expect(ToneRegister.introducedWords(from: output, to: text).isEmpty, "\(text) -> \(output)")
        }
    }

    // MARK: Casual: pronoun + auxiliary

    @Test("Casual contracts a pronoun with am, are, is and will")
    func casualPronounAuxiliary() {
        #expect(casual("I am ready to go") == "I'm ready to go")
        #expect(casual("we are late") == "we're late")
        #expect(casual("you are right") == "you're right")
        #expect(casual("They are here") == "They're here")
        #expect(casual("it is fine") == "it's fine")
        #expect(casual("that is why we left") == "that's why we left")
        #expect(casual("I will send it") == "I'll send it")
        #expect(casual("she is here and he will call") == "she's here and he'll call")
        #expect(casual("We are late") == "We're late")
        #expect(casual("It is fine") == "It's fine")
    }

    @Test("Casual contracts the pronoun when the auxiliary is followed by not")
    func casualPronounBeNot() {
        #expect(casual("it is not ready") == "it's not ready")
        #expect(casual("I am not sure") == "I'm not sure")
        #expect(casual("we are not done") == "we're not done")
    }

    @Test("Casual contracts an auxiliary with not, whatever the subject")
    func casualAuxiliaryNot() {
        #expect(casual("do not touch it") == "don't touch it")
        #expect(casual("Do not touch it") == "Don't touch it")
        #expect(casual("the cache does not refresh") == "the cache doesn't refresh")
        #expect(casual("we did not ship") == "we didn't ship")
        #expect(casual("I cannot go") == "I can't go")
        #expect(casual("the deploy will not finish") == "the deploy won't finish")
        #expect(casual("I will not go") == "I won't go")
        #expect(casual("the build is not green") == "the build isn't green")
        #expect(casual("the tests are not stable") == "the tests aren't stable")
    }

    @Test("Casual never contracts a noun with is, and leaves I have alone")
    func casualLeavesAlone() {
        #expect(casual("the worker is late") == "the worker is late")
        #expect(casual("the worker is on v2.7 and the retry count is six") == "the worker is on v2.7 and the retry count is six")
        #expect(casual("I have finished the draft") == "I have finished the draft")
        #expect(casual("I would go") == "I would go")
        #expect(casual("I'd go") == "I'd go")
        #expect(casual("we can not go") == "we can not go")
    }

    @Test("Casual does not contract at the end of a clause")
    func casualClauseEnd() {
        #expect(casual("Yes I am.") == "Yes I am.")
        #expect(casual("yes it is") == "yes it is")
        #expect(casual("I am, however, ready") == "I am, however, ready")
        #expect(casual("I am\nready") == "I am\nready")
        #expect(casual("that is what it is") == "that's what it is")
        #expect(casual("Do you know what it is?") == "Do you know what it is?")
        #expect(casual("I know where it is now") == "I know where it is now")
        #expect(casual("better than I am today") == "better than I am today")
    }

    @Test("Casual does not contract before not only")
    func casualNotOnly() {
        #expect(casual("the answer is not only fast") == "the answer is not only fast")
    }

    @Test("Casual keeps spoken reductions as spoken")
    func casualKeepsReductions() {
        #expect(casual("I am gonna wanna go") == "I'm gonna wanna go")
        #expect(casual("lemme know, I gotta go, kinda tired") == "lemme know, I gotta go, kinda tired")
    }

    @Test("Casual only touches exact lowercase or capitalised words")
    func casualCaseGuards() {
        #expect(casual("WE ARE LATE") == "WE ARE LATE")
        #expect(casual("i am ready") == "I'm ready")
        #expect(casual("It Is fine") == "It Is fine")
    }

    @Test("Casual follows the apostrophe the text already uses")
    func casualApostrophe() {
        #expect(casual("Alex\u{2019}s team: we are done") == "Alex\u{2019}s team: we\u{2019}re done")
        #expect(casual("Alex's team: we are done") == "Alex's team: we're done")
    }

    // MARK: Professional: reductions

    @Test("Professional expands gonna after a form of be, optionally followed by not")
    func professionalGonna() {
        #expect(professional("I am gonna leave the flag on") == "I am going to leave the flag on")
        #expect(professional("I'm gonna leave") == "I am going to leave")
        #expect(professional("it's gonna rain") == "it's going to rain")
        #expect(professional("we're not gonna ship") == "we are not going to ship")
        #expect(professional("they were gonna call") == "they were going to call")
        #expect(professional("it isn't gonna work") == "it is not going to work")
        #expect(professional("the team's gonna ship") == "the team's going to ship")
        #expect(professional("it has been gonna happen") == "it has been going to happen")
    }

    @Test("Professional leaves gonna alone when be does not precede it")
    func professionalGonnaUnchanged() {
        #expect(professional("gonna leave now") == "gonna leave now")
        #expect(professional("Gonna leave now") == "Gonna leave now")
        #expect(professional("I gonna leave") == "I gonna leave")
        #expect(professional("are you gonna come") == "are you gonna come")
        #expect(professional("GONNA leave") == "GONNA leave")
    }

    @Test("Professional expands wanna after I, we, you, they, do-support, or at the start of a clause")
    func professionalWanna() {
        #expect(professional("I wanna keep it paused") == "I want to keep it paused")
        #expect(professional("do you wanna go") == "do you want to go")
        #expect(professional("I don't wanna go") == "I do not want to go")
        #expect(professional("I really wanna go") == "I really want to go")
        #expect(professional("Wanna grab lunch") == "Want to grab lunch")
        #expect(professional("hey, wanna grab lunch") == "hey, want to grab lunch")
    }

    @Test("Professional leaves wanna alone after he, she, it, before a determiner, or at the end")
    func professionalWannaUnchanged() {
        #expect(professional("he wanna go") == "he wanna go")
        #expect(professional("she wanna go") == "she wanna go")
        #expect(professional("it wanna fail") == "it wanna fail")
        #expect(professional("I wanna a coffee") == "I wanna a coffee")
        #expect(professional("I wanna an apple") == "I wanna an apple")
        #expect(professional("I wanna the red one") == "I wanna the red one")
        #expect(professional("I wanna.") == "I wanna.")
        #expect(professional("the team wanna go") == "the team wanna go")
    }

    @Test("Professional expands kinda, lemme and gimme")
    func professionalOtherReductions() {
        #expect(professional("I am kinda worried") == "I am kind of worried")
        #expect(professional("Kinda late") == "Kind of late")
        #expect(professional("lemme know") == "let me know")
        #expect(professional("Lemme know") == "Let me know")
        #expect(professional("gimme a minute") == "give me a minute")
        #expect(professional("Gimme a minute") == "Give me a minute")
    }

    @Test("Professional expands gotta after have, has, 've and 's, or after a subject that takes have")
    func professionalGotta() {
        #expect(professional("I've gotta finish the notes") == "I have got to finish the notes")
        #expect(professional("I have gotta finish the notes") == "I have got to finish the notes")
        #expect(professional("he has gotta go") == "he has got to go")
        #expect(professional("he's gotta go") == "he's got to go")
        #expect(professional("I gotta finish the notes") == "I have got to finish the notes")
        #expect(professional("and you gotta see it") == "and you have got to see it")
        #expect(professional("so we gotta go") == "so we have got to go")
    }

    @Test("Professional leaves gotta alone when the grammar is unclear")
    func professionalGottaUnchanged() {
        #expect(professional("he gotta go") == "he gotta go")
        #expect(professional("do you gotta go") == "do you gotta go")
        #expect(professional("gotta go") == "gotta go")
        #expect(professional("the team gotta go") == "the team gotta go")
    }

    @Test("wanna and gotta are expanded only when the next word is read as a verb")
    func reductionsNeedAVerbReading() {
        // Verb readings expand.
        #expect(professional("I wanna go home") == "I want to go home")
        #expect(professional("I wanna eat lunch tomorrow") == "I want to eat lunch tomorrow")
        #expect(professional("I gotta pick up my sister") == "I have got to pick up my sister")
        #expect(professional("and you gotta see it") == "and you have got to see it")
        #expect(professional("I wanna really go") == "I want to really go")
        // A noun may mean "want a" or "got a": left as spoken.
        #expect(professional("I wanna coffee") == "I wanna coffee")
        #expect(professional("I gotta car") == "I gotta car")
        #expect(professional("I gotta dog and a cat") == "I gotta dog and a cat")
        #expect(professional("I wanna new phone") == "I wanna new phone")
        // An adjective, a number and the end of the text are no verb reading either.
        #expect(professional("I wanna Italian food") == "I wanna Italian food")
        #expect(professional("I gotta two") == "I gotta two")
        #expect(professional("I wanna") == "I wanna")
    }

    @Test("a capitalised reduction inside a sentence is left as a possible name; a sentence-initial one expands")
    func capitalisedReductionsAreNames() {
        #expect(professional("Open Kinda Studio") == "Open Kinda Studio")
        #expect(professional("Launch Gimme Wallet") == "Launch Gimme Wallet")
        #expect(professional("Ask Lemme Know about it") == "Ask Lemme Know about it")
        #expect(professional("Call me. Kinda tired") == "Call me. Kind of tired")
        #expect(professional("Done!\nGimme a minute") == "Done!\nGive me a minute")
        #expect(professional("Kinda late") == "Kind of late")
        // A lowercase one in the same place still expands.
        #expect(professional("Open kinda studio") == "Open kind of studio")
    }

    @Test("curly quoted spans are kept exactly, double and single, in both tones")
    func curlyQuotesAreProtected() {
        let double = "Say \u{201C}I'm gonna leave\u{201D} verbatim and I'm gonna go"
        #expect(professional(double) == "Say \u{201C}I'm gonna leave\u{201D} verbatim and I am going to go")
        let single = "Say \u{2018}I'm gonna leave\u{2019} verbatim and I'm gonna go"
        #expect(professional(single) == "Say \u{2018}I'm gonna leave\u{2019} verbatim and I am going to go")
        let casualText = "Say \u{201C}we do not need it\u{201D} verbatim and we do not need it"
        #expect(casual(casualText) == "Say \u{201C}we do not need it\u{201D} verbatim and we don't need it")
        let casualSingle = "He said \u{2018}we do not need it\u{2019} and we do not need it"
        // The text already uses curly apostrophes, so the contraction does too.
        #expect(casual(casualSingle) == "He said \u{2018}we do not need it\u{2019} and we don\u{2019}t need it")
        // An apostrophe is not a quote mark, and an unclosed mark protects nothing.
        #expect(professional("I\u{2019}m gonna go and don\u{2019}t stop") == "I am going to go and do not stop")
        // An unclosed quote cannot be told from one that closes later, so everything after it is kept.
        #expect(professional("Say \u{201C}I'm gonna go") == "Say \u{201C}I'm gonna go")
        // Straight quotes still work as before.
        #expect(professional("Say \"I'm gonna leave\" verbatim") == "Say \"I'm gonna leave\" verbatim")
        // Through the whole tone path, not only the word rewrite.
        let whole = ToneRegister.apply(.professional, to: double, in: .other)
        #expect(whole.contains("\u{201C}I'm gonna leave\u{201D}") && whole.contains("I am going to go"))
    }

    @Test("when a mark may or may not close a quotation, more is protected, never less")
    func quotePairingProtectsMore() {
        let say = { (inner: String) in "Say \(inner) exactly" }
        // A possessive inside a single-quoted span does not close it: the last plausible closing mark does.
        #expect(professional(say("\u{2018}the students\u{2019} notes are gonna change\u{2019}"))
            == say("\u{2018}the students\u{2019} notes are gonna change\u{2019}"))
        // Nested single and double quotes of the same style.
        #expect(professional(say("\u{2018}outer \u{2018}inner\u{2019} I'm gonna go\u{2019}"))
            == say("\u{2018}outer \u{2018}inner\u{2019} I'm gonna go\u{2019}"))
        #expect(professional(say("\u{201C}outer \u{201C}inner\u{201D} I'm gonna go\u{201D}"))
            == say("\u{201C}outer \u{201C}inner\u{201D} I'm gonna go\u{201D}"))
        #expect(professional("Say \u{201C}a \u{201C}b\u{201D} c\u{201D} and I'm gonna go")
            == "Say \u{201C}a \u{201C}b\u{201D} c\u{201D} and I am going to go")
        // A straight quote nested in a curly one.
        #expect(professional(say("\u{201C}he said \"I'm gonna go\" and left\u{201D}"))
            == say("\u{201C}he said \"I'm gonna go\" and left\u{201D}"))
        // A curly opener with a straight closer, and the other way round, are a pair.
        #expect(professional(say("\u{201C}I'm gonna leave\"")) == say("\u{201C}I'm gonna leave\""))
        #expect(professional(say("\"I'm gonna leave\u{201D}")) == say("\"I'm gonna leave\u{201D}"))
        #expect(professional(say("\u{2018}I'm gonna leave'")) == say("\u{2018}I'm gonna leave'"))
        #expect(professional(say("'I'm gonna leave\u{2019}")) == say("'I'm gonna leave\u{2019}"))
        // Several quotations on one line: the span runs to the last plausible closing mark.
        #expect(professional("He said \u{2018}no\u{2019} and then \u{2018}I'm gonna go\u{2019} so")
            == "He said \u{2018}no\u{2019} and then \u{2018}I'm gonna go\u{2019} so")
    }

    @Test("an apostrophe is not a quote mark: contractions, 90s and rock 'n' roll are still ordinary text")
    func apostrophesAreNotQuotes() {
        #expect(professional("I'm gonna play rock \u{2019}n\u{2019} roll in the \u{2019}90s")
            == "I am going to play rock \u{2019}n\u{2019} roll in the \u{2019}90s")
        #expect(professional("I\u{2019}m gonna play it, we don\u{2019}t mind") == "I am going to play it, we do not mind")
        #expect(professional("I'm gonna play rock 'n' roll") == "I am going to play rock 'n' roll")
        #expect(professional("I'm gonna buy a 5\" screen and I'm gonna go") == "I am going to buy a 5\" screen and I am going to go")
        #expect(professional("I'm gonna go \u{2018}now") == "I am going to go \u{2018}now")
        #expect(ToneQuoteMasking.quotedSpans(in: "the ’90s, rock ’n’ roll and don’t").isEmpty)
        #expect(ToneQuoteMasking.quotedSpans(in: "Say “a ‘b’ c” and ‘d’ end") == ["“a ‘b’ c”", "‘d’"])
    }

    @Test("a plain apostrophe never starts a quotation, and a curly left quote always does")
    func openers() {
        // Decades and elisions are apostrophes: the rest of the dictation is still rewritten.
        #expect(professional("The '90s were fun and we're gonna leave") == "The '90s were fun and we are going to leave")
        #expect(professional("'cause we're gonna leave") == "'cause we are going to leave")
        #expect(professional("Wait 'til we're gonna go, 'em and 'twas") == "Wait 'til we are going to go, 'em and 'twas")
        #expect(professional("the dogs' bowls are empty and we're gonna leave") == "the dogs' bowls are empty and we are going to leave")
        #expect(professional("rock 'n' roll is gonna win") == "rock 'n' roll is going to win")
        #expect(ToneQuoteMasking.quotedSpans(in: "The '90s, 'cause, 'til, 'em, 'twas and rock 'n' roll").isEmpty)
        // A real single-quoted word after a straight mark is still a quotation.
        #expect(professional("He said 'we're gonna leave' today and we're gonna go")
            == "He said 'we're gonna leave' today and we are going to go")
        // A curly left quote opens a span even right after a letter, and the words inside stay as spoken.
        let glued = "Say\u{2018}I'm gonna leave\nnow\u{2019} verbatim."
        #expect(ToneQuoteMasking.quotedSpans(in: glued) == ["\u{2018}I'm gonna leave\nnow\u{2019}"])
        #expect(professional(glued) == glued)
        for tone in DictationTone.allCases {
            for context in StyleContext.allCases {
                #expect(ToneRegister.apply(tone, to: glued, in: context).contains("\u{2018}I'm gonna leave\nnow\u{2019}"), "\(tone) \(context)")
            }
        }
    }

    @Test("a quotation is kept through the layout step too: no sentence capitalised inside it, in any tone")
    func layoutKeepsQuotations() {
        let pairs = [("\u{201C}", "\u{201D}"), ("\"", "\""), ("\u{2018}", "\u{2019}")]
        for (open, close) in pairs {
            let quote = "\(open)we do not need it\nand we do not need it\(close)"
            for tone in DictationTone.allCases {
                for context in StyleContext.allCases {
                    let output = ToneRegister.apply(tone, to: "Say \(quote)", in: context)
                    #expect(output.contains(quote), "\(tone) \(context) \(open): \(output)")
                    #expect(!output.contains("\nAnd"), "\(tone) \(context) \(open): \(output)")
                }
            }
        }
        // A single-quoted quotation that runs over a line break is kept byte for byte, in every tone.
        let across = "Say \u{2018}I'm gonna leave\nnow\u{2019} verbatim."
        for tone in DictationTone.allCases {
            for context in StyleContext.allCases {
                #expect(ToneRegister.apply(tone, to: across, in: context).contains("\u{2018}I'm gonna leave\nnow\u{2019}"), "\(tone) \(context)")
            }
        }
        #expect(professional(across) == across)
        #expect(ToneQuoteMasking.quotedSpans(in: across) == ["\u{2018}I'm gonna leave\nnow\u{2019}"])
        // An opener with no closer anywhere: pairing is uncertain, so it is protected to the end, never changed.
        #expect(professional("We're gonna say \u{2018}I'm gonna leave\nand we're gonna go")
            == "We are going to say \u{2018}I'm gonna leave\nand we're gonna go")
        #expect(professional("We're gonna say 'I'm gonna leave and we're gonna go")
            == "We are going to say 'I'm gonna leave and we're gonna go")
        // Inside one line, a single-quoted span is kept too.
        let single = "Say \u{2018}we do not need it and we do not need it\u{2019} and we do not need it"
        #expect(ToneRegister.apply(.casual, to: single, in: .other).contains("\u{2018}we do not need it and we do not need it\u{2019}"))
        // The guard on the whole pass: a quotation that is not whole in the output is not accepted.
        #expect(ToneRegister.preservesQuotedSpans(input: "Say \u{201C}a b\u{201D}", output: "Say \u{201C}a b\u{201D}."))
        #expect(!ToneRegister.preservesQuotedSpans(input: "Say \u{201C}a b\u{201D}", output: "Say \u{201C}A b\u{201D}."))
        #expect(!ToneRegister.preservesQuotedSpans(input: "Say \"a b\" ok", output: "Say a b ok"))
        #expect(ToneRegister.preservesQuotedSpans(input: "no quotes here", output: "No quotes here."))
    }

    @Test("the tagger is created once per dictation, and only when wanna or gotta needs it")
    func taggerOncePerDictation() {
        let text = "I wanna go and I gotta run, we gotta see it, I wanna eat"
        let (_, chunks) = ToneText.chunks(of: text)
        let reading = ToneVerbReading(chunks)
        #expect(reading.passes == 0)
        let words = chunks.indices.filter { chunks[$0].isWord }
        for index in words + words { _ = reading.isVerb(at: index) }
        #expect(reading.passes == 1)
    }

    @Test("short forms with no clause after them stay as spoken, whatever the tagger would say about the verb")
    func shortFormsStay() {
        #expect(professional("I've gotta finish") == "I have gotta finish")
        #expect(professional("I have gotta finish") == "I have gotta finish")
        #expect(professional("I wanna quickly go") == "I wanna quickly go")
    }

    // MARK: Professional: contractions

    @Test("Professional expands unambiguous pronoun contractions")
    func professionalPronounContractions() {
        #expect(professional("I'm ready") == "I am ready")
        #expect(professional("we're late") == "we are late")
        #expect(professional("You're right") == "You are right")
        #expect(professional("they're here") == "they are here")
        #expect(professional("I'll send it") == "I will send it")
        #expect(professional("we'll see") == "we will see")
        #expect(professional("We're late") == "We are late")
        #expect(professional("I\u{2019}m ready") == "I am ready")
    }

    @Test("Professional expands negative contractions")
    func professionalNegatives() {
        #expect(professional("I don't know") == "I do not know")
        #expect(professional("it doesn't matter") == "it does not matter")
        #expect(professional("we didn't ship") == "we did not ship")
        #expect(professional("I can't go") == "I cannot go")
        #expect(professional("it won't work") == "it will not work")
        #expect(professional("it isn't ready") == "it is not ready")
        #expect(professional("they aren't ready") == "they are not ready")
        #expect(professional("Don't touch it") == "Do not touch it")
        #expect(professional("Don't forget the milk") == "Do not forget the milk")
    }

    @Test("Professional leaves ambiguous and neutral forms as spoken")
    func professionalLeavesAlone() {
        for text in ["it's fine", "that's why", "let's go", "I'd go", "he's here",
                     "there's a gap", "she's gone", "they'd agree", "who's there"] {
            #expect(professional(text) == text)
        }
    }

    @Test("Professional expands every unambiguous negative, not only the first seven")
    func professionalMoreNegatives() {
        #expect(professional("it wasn't ready") == "it was not ready")
        #expect(professional("they weren't told") == "they were not told")
        #expect(professional("I wouldn't go") == "I would not go")
        #expect(professional("we couldn't find it") == "we could not find it")
        #expect(professional("you shouldn't wait") == "you should not wait")
        #expect(professional("she hasn't replied") == "she has not replied")
        #expect(professional("we haven't shipped") == "we have not shipped")
        #expect(professional("it hadn't started") == "it had not started")
        #expect(professional("The build wasn't green, but we shipped.") == "The build was not green, but we shipped.")
    }

    @Test("Professional expands have and it will after a pronoun")
    func professionalHaveAndItWill() {
        #expect(professional("I've seen it") == "I have seen it")
        #expect(professional("we've shipped") == "we have shipped")
        #expect(professional("you've got mail") == "you have got mail")
        #expect(professional("they've left") == "they have left")
        #expect(professional("it'll work") == "it will work")
        #expect(professional("We've shipped") == "We have shipped")
    }

    @Test("Professional leaves the new negatives alone where they are inverted or a question")
    func professionalNewNegativesInversions() {
        #expect(professional("Wasn't it ready?") == "Wasn't it ready?")
        #expect(professional("Wouldn't that be nice") == "Wouldn't that be nice")
        #expect(professional("why wouldn't we ship") == "why wouldn't we ship")
        #expect(professional("you hadn't, had you?") == "you hadn't, had you?")
        #expect(professional("it wasn't, was it?") == "it wasn't, was it?")
    }

    @Test("Professional leaves inverted questions and tags alone")
    func professionalInversions() {
        #expect(professional("Isn't it ready?") == "Isn't it ready?")
        #expect(professional("why don't we ship") == "why don't we ship")
        #expect(professional("Don't you think so") == "Don't you think so")
        #expect(professional("you did it, didn't you?") == "you did it, didn't you?")
        #expect(professional("Can't wait") == "Can't wait")
        #expect(professional("how can't it") == "how can't it")
    }

    // MARK: All tones

    @Test("literals are never touched")
    func literalsProtected() {
        #expect(casual("`I am` is a string") == "`I am` is a string")
        #expect(casual("Say \"we are\" to them") == "Say \"we are\" to them")
        #expect(casual("see https://example.com/it_is/we-are and we are done") == "see https://example.com/it_is/we-are and we're done")
        #expect(casual("I_am is fine") == "I_am is fine")
        #expect(casual("run `git push` we are done") == "run `git push` we're done")
        #expect(professional("`we're gonna` stays") == "`we're gonna` stays")
        #expect(professional("run \"I'm gonna\" now") == "run \"I'm gonna\" now")
        #expect(professional("open /usr/local/gonna.txt and lemme know") == "open /usr/local/gonna.txt and let me know")
        #expect(professional("set don't_stop to 1") == "set don't_stop to 1")
    }

    @Test("empty and whitespace-only text come back untouched")
    func emptyInput() {
        for tone in DictationTone.allCases {
            #expect(ToneRegister.apply(tone, to: "", in: .other) == "")
            #expect(ToneRegister.apply(tone, to: "  ", in: .other) == "  ")
        }
    }

    @Test("applying a tone twice equals applying it once")
    func idempotent() {
        for tone in DictationTone.allCases {
            for text in Self.corpus {
                for context in StyleContext.allCases {
                    let once = ToneRegister.apply(tone, to: text, in: context)
                    let twice = ToneRegister.apply(tone, to: once, in: context)
                    #expect(once == twice, "\(tone.rawValue)/\(context.rawValue): \(text) -> \(once) -> \(twice)")
                }
                let words = ToneRegister.rewriteWords(tone, in: text)
                #expect(ToneRegister.rewriteWords(tone, in: words) == words, "\(tone.rawValue): \(text)")
            }
        }
    }

    @Test("Casual and Professional only introduce words from their closed sets")
    func introducedWordsAreClosed() {
        for tone in [DictationTone.casual, .professional] {
            let allowed = ToneRegister.closedIntroductions(for: tone)
            #expect(!allowed.isEmpty)
            for text in Self.corpus {
                for context in StyleContext.allCases {
                    let output = ToneRegister.apply(tone, to: text, in: context)
                    let introduced = Set(ToneRegister.introducedWords(from: text, to: output).keys)
                    #expect(introduced.isSubset(of: allowed), "\(tone.rawValue): \(text) -> \(output): \(introduced.subtracting(allowed))")
                }
            }
        }
        #expect(ToneRegister.closedIntroductions(for: .refined).isEmpty)
    }

    @Test("Professional and Casual do change a typical corpus, so the property test is not vacuous")
    func corporaExercised() {
        let casualChanged = Self.corpus.filter { casual($0) != $0 }.count
        let professionalChanged = Self.corpus.filter { professional($0) != $0 }.count
        #expect(casualChanged >= 6)
        #expect(professionalChanged >= 10)
    }

    // MARK: introducedWords

    @Test("introducedWords reports the multiset of normalised words only in the output")
    func introducedWords() {
        let introduced = ToneRegister.introducedWords(from: "I am gonna go", to: "I'm going to go.")
        #expect(introduced == ["i'm": 1, "going": 1, "to": 1])
        #expect(ToneRegister.introducedWords(from: "the the cat", to: "The cat").isEmpty)
        #expect(ToneRegister.introducedWords(from: "go", to: "go go") == ["go": 1])
        #expect(ToneRegister.introducedWords(from: "it\u{2019}s", to: "It's").isEmpty)
    }

    // MARK: Full tone path

    @Test("the full path changes the words, then lays the text out")
    func fullPath() {
        let input = "I am gonna leave the flag on until Friday."
        #expect(ToneRegister.apply(.refined, to: input, in: .workMessages) == "I am gonna leave the flag on until Friday.")
        #expect(ToneRegister.apply(.casual, to: input, in: .workMessages) == "I'm gonna leave the flag on until Friday")
        #expect(ToneRegister.apply(.professional, to: input, in: .workMessages) == "I am going to leave the flag on until Friday.")
    }

    @Test("Professional email keeps the greeting layout")
    func emailLayout() {
        let output = ToneRegister.apply(
            .professional, to: "Hi Mateo, we're gonna hold the shipment until inspection is complete.", in: .email)
        #expect(output == "Hi Mateo,\n\nWe are going to hold the shipment until inspection is complete.")
    }

    @Test("a backtick literal survives every tone")
    func literalSurvives() {
        let input = "Run `we are gonna` now and we are done"
        for tone in DictationTone.allCases {
            let output = ToneRegister.apply(tone, to: input, in: .workMessages)
            #expect(output.contains("`we are gonna`"), "\(tone.rawValue): \(output)")
        }
    }

    // MARK: Corpus

    static let corpus: [String] = [
        "I am gonna leave the flag on until Friday.",
        "i am gonna leave the feature flag on until friday",
        "We are not gonna ship until QA signs off.",
        "I wanna keep the release paused until Nerys signs off.",
        "I am kinda worried about the memory spike at p95.",
        "Hi Eulalia, I gotta finish the audit notes by Tuesday. Thanks",
        "Hello Basim, the patch is in build 418 and the checksum matches. Regards, Basim",
        "We can send the sample on June sixth. Thank you",
        "Hey Soraya, lemme know when you get home.",
        "Uh I am gonna bring the blue umbrella.",
        "The sensor is kinda noisy after midnight.",
        "I am available for a call on Thursday.",
        "It is not ready and they are not happy.",
        "That is what it is. Yes I am.",
        "I do not think it does not matter, and we did not ship it.",
        "I cannot reproduce it and the deploy will not finish.",
        "I'm sure we're late, you're right, they're here and I'll send it.",
        "We don't know, it doesn't matter, we didn't ship, I can't go and it won't work.",
        "It isn't ready and they aren't happy.",
        "It's fine, that's why, let's go, I'd go, we've shipped, I've seen it.",
        "Isn't it ready? Why don't we ship? Don't you think so? Don't forget the milk.",
        "He wanna go and she wanna stay, but I wanna a coffee.",
        "He gotta go. Do you gotta go? Gotta go.",
        "He's gotta go and he has gotta stay, and you gotta see it.",
        "Gimme a minute, lemme check, then I am gonna call.",
        "Gonna leave now. Are you gonna come? Wanna grab lunch?",
        "The worker is on v2.7 and the retry count is six.",
        "Run `we are gonna` now and we are done.",
        "See https://example.com/it_is/we-are and we are done.",
        "Send it to me at three no four after the demo.",
        "Idea: keep the paper receipts for three months.",
        "- we are gonna ship\n- I will not go",
        "I will send it, she is here, he will call and it will not fail.",
        "WE ARE LATE and i am ready.",
    ]
}
