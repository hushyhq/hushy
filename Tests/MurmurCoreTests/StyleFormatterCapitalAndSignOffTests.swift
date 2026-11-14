import Testing
@testable import MurmurCore

/// Polished work messages arrive with the casing preserved (the cleaner keeps a casual target's
/// casing), so the style layer is what makes formal, casual and excited text start with capitals.
@Suite("Style formatter capitals")
struct StyleFormatterCapitalTests {
    private static let capitalising: [WritingStyle] = [.formal, .casual, .excited]

    @Test("formal, casual and excited capitalise the start of every sentence")
    func sentenceStartsAreCapitalised() {
        let input = "reproduced this on staging. the token refresh fails when the clock skew is large"
        for context in StyleContext.allCases {
            for style in Self.capitalising {
                let output = StyleFormatter.apply(style, to: input, in: context)
                #expect(output.hasPrefix("Reproduced this on staging"), "\(context.rawValue)/\(style.rawValue): \(output)")
                #expect(output.contains(". The token refresh"), "\(context.rawValue)/\(style.rawValue): \(output)")
            }
        }
    }

    @Test("a lowercase work message gets its capital")
    func workMessageStartsWithCapital() {
        let output = StyleFormatter.apply(.formal, to: "thanks for the quick turnaround I'll update the ticket", in: .workMessages)
        #expect(output == "Thanks for the quick turnaround I'll update the ticket.")
    }

    @Test("very casual keeps lowercasing sentence starts")
    func veryCasualStaysLowercase() {
        let output = StyleFormatter.apply(.veryCasual, to: "Reproduced this on staging. The token fails", in: .personalMessages)
        #expect(output == "reproduced this on staging. the token fails")
    }

    @Test("a sentence starting with a plain word gets a capital, hyphenated names included")
    func plainWordStartsAreCapitalised() {
        let output = StyleFormatter.apply(.formal, to: "auth-service is down again", in: .workMessages)
        #expect(output == "Auth-service is down again.")
    }

    @Test("a mixed-case word at the start of a sentence keeps its own casing")
    func mixedCaseWordsKeepTheirCasing() {
        let cases: [(String, String)] = [
            ("iPhone builds are slower", "iPhone builds are slower."),
            ("macOS 26 is out. eBay was down", "macOS 26 is out. eBay was down."),
            ("gRPC calls time out. iOS is fine", "gRPC calls time out. iOS is fine."),
        ]
        for (input, expected) in cases {
            for context in [StyleContext.workMessages, .personalMessages, .email, .other] {
                let output = StyleFormatter.apply(.formal, to: input, in: context)
                #expect(output == expected, "\(context.rawValue): \(input) -> \(output)")
            }
        }
    }

    @Test("backtick literals are never recased while the sentences around them are")
    func backtickLiteralsSurvive() {
        let output = StyleFormatter.apply(.formal, to: "run `npm ci` first. then try `myVar` again", in: .workMessages)
        #expect(output == "Run `npm ci` first. Then try `myVar` again.")
    }

    @Test("a literal that opens the text keeps its casing")
    func leadingBacktickLiteralKeepsCasing() {
        let output = StyleFormatter.apply(.casual, to: "`myVar` is unset. check it", in: .workMessages)
        #expect(output == "`myVar` is unset. Check it")
    }
}

@Suite("Style formatter email sign-off")
struct StyleFormatterSignOffTests {
    @Test("the body ends with a full stop and the sign-off word and name are capitalised")
    func commaBeforeSignOffBecomesFullStop() {
        let input = "Hi Dev, I looked into the leak. I'll send a fix tomorrow, thanks, lena"
        for style in [WritingStyle.formal, .excited] {
            let output = StyleFormatter.apply(style, to: input, in: .email)
            #expect(output.hasSuffix("tomorrow.\n\nThanks,\nLena"), "\(style.rawValue): \(output)")
        }
        let casual = StyleFormatter.apply(.casual, to: input, in: .email)
        #expect(casual.hasSuffix("tomorrow.\n\nThanks,\nLena"), "casual: \(casual)")
    }

    @Test("a lowercase closing with no comma is laid out the same way")
    func lowercaseClosingIsCapitalised() {
        let output = StyleFormatter.apply(.formal, to: "Sorry for the late notice. thanks sam", in: .email)
        #expect(output == "Sorry for the late notice.\n\nThanks,\nSam")
    }

    @Test("two-word closings stay together on the closing line")
    func multiWordClosingsStayTogether() {
        let kind = StyleFormatter.apply(.formal, to: "Could you help? kind regards jonas", in: .email)
        #expect(kind == "Could you help?\n\nKind regards,\nJonas")
        let thanks = StyleFormatter.apply(.formal, to: "We are affected. thank you elena", in: .email)
        #expect(thanks == "We are affected.\n\nThank you,\nElena")
        let best = StyleFormatter.apply(.formal, to: "Let me know if that works. best regards anita", in: .email)
        #expect(best == "Let me know if that works.\n\nBest regards,\nAnita")
    }

    @Test("a body that already ends in a question mark keeps it")
    func questionMarkSurvives() {
        let output = StyleFormatter.apply(.formal, to: "Can you take a look? cheers, jo", in: .email)
        #expect(output == "Can you take a look?\n\nCheers,\nJo")
    }

    @Test("a correct sign-off is left alone")
    func correctSignOffUnchanged() {
        let input = "Looks good.\n\nThanks,\nMark"
        #expect(StyleFormatter.apply(.formal, to: input, in: .email) == input)
    }

    @Test("a multi-word addressee stays whole on the greeting line")
    func multiWordAddresseeStaysWhole() {
        let team = StyleFormatter.apply(
            .formal, to: "Dear customer success team, we upgraded last week. Could you help? kind regards jonas", in: .email)
        #expect(team == "Dear customer success team,\n\nWe upgraded last week. Could you help?\n\nKind regards,\nJonas")
        let group = StyleFormatter.apply(.excited, to: "Hello everyone on staff, the build is green.", in: .email)
        #expect(group.hasPrefix("Hello everyone on staff,\n\nThe build is green"), Comment(rawValue: group))
        let single = StyleFormatter.apply(.formal, to: "Hi Dev, the leak is fixed.", in: .email)
        #expect(single == "Hi Dev,\n\nThe leak is fixed.")
    }

    @Test("a greeting with no comma still splits after one word")
    func greetingWithoutCommaKeepsOneWordName() {
        let output = StyleFormatter.apply(.formal, to: "Hi Dev the leak is fixed.", in: .email)
        #expect(output == "Hi Dev,\n\nThe leak is fixed.")
    }

    @Test("with no comma, dear is not split because its addressee can be any length")
    func dearWithoutCommaIsNotSplit() {
        let output = StyleFormatter.apply(
            .formal, to: "Dear customer success team we upgraded last week. Could you help?", in: .email)
        #expect(output == "Dear customer success team we upgraded last week. Could you help?")
    }

    @Test("a closing word in the middle of a clause is body text, not a sign-off")
    func midClauseClosingsAreLeftAlone() {
        let sentences = [
            "I think this works best today",
            "that would be best thanks everyone",
            "the team sends warm regards tomorrow",
            "we should cheers up quickly",
            "this is our best idea",
        ]
        for sentence in sentences {
            let output = StyleFormatter.apply(.formal, to: sentence, in: .email)
            #expect(output == sentence.prefix(1).uppercased() + sentence.dropFirst() + ".", "\(sentence) -> \(output)")
        }
    }

    @Test("a closing right after a comma, full stop or question mark still counts")
    func clauseStartClosingsCount() {
        let comma = StyleFormatter.apply(.formal, to: "Great work, thanks mark", in: .email)
        #expect(comma == "Great work.\n\nThanks,\nMark")
        let question = StyleFormatter.apply(.formal, to: "Can you check? cheers jo", in: .email)
        #expect(question == "Can you check?\n\nCheers,\nJo")
        let bang = StyleFormatter.apply(.formal, to: "That worked! thanks sam", in: .email)
        #expect(bang == "That worked!\n\nThanks,\nSam")
    }

    @Test("a colon or semicolon in the body is never stripped")
    func bodyPunctuationSurvives() {
        let colon = StyleFormatter.apply(.formal, to: "Use the subject: best practices", in: .email)
        #expect(colon == "Use the subject: best practices.")
        let semicolon = StyleFormatter.apply(.formal, to: "It failed; thanks. best regards anita", in: .email)
        #expect(semicolon == "It failed; thanks.\n\nBest regards,\nAnita")
    }

    @Test("a sentence that starts with hi, hey or hello is not a greeting unless a name follows")
    func greetingWordWithoutNameIsNotSplit() {
        for input in ["Hi can you send this?", "Hey could you look at the build", "hello there is a problem"] {
            let output = StyleFormatter.apply(.formal, to: input, in: .email)
            #expect(!output.contains("\n\n"), "\(input) -> \(output)")
        }
        let named = StyleFormatter.apply(.formal, to: "Hi Dev the leak is fixed.", in: .email)
        #expect(named == "Hi Dev,\n\nThe leak is fixed.")
    }

    @Test("a title abbreviation keeps its full stop inside the greeting")
    func titleGreeting() {
        let ms = StyleFormatter.apply(.formal, to: "Dear Ms. Patel, we are really sorry about the delay.", in: .email)
        #expect(ms == "Dear Ms. Patel,\n\nWe are really sorry about the delay.")
        let dr = StyleFormatter.apply(.excited, to: "Hello Dr. Chen, thank you for the update.", in: .email)
        #expect(dr.hasPrefix("Hello Dr. Chen,\n\nThank you for the update"), Comment(rawValue: dr))
        let other = StyleFormatter.apply(.formal, to: "Hi Sam. we are sorry, it was late.", in: .email)
        #expect(!other.hasPrefix("Hi Sam. we are sorry,\n\n"), Comment(rawValue: other))
    }

    @Test("a group word after hi, hey or hello is a greeting even when it arrives lowercase")
    func groupAddresseeGreetings() {
        let salutations = ["hi", "hey", "hello"]
        let groups = ["all", "everyone", "everybody", "team", "folks"]
        for salutation in salutations {
            for group in groups {
                let input = "\(salutation) \(group) quick reminder that the freeze starts on the fifteenth"
                let output = StyleFormatter.apply(.formal, to: input, in: .email)
                let expected = "\(salutation.capitalized) \(group),\n\nQuick reminder that the freeze starts on the fifteenth."
                #expect(output == expected, Comment(rawValue: "\(input) -> \(output)"))
            }
        }
        let upper = StyleFormatter.apply(.formal, to: "HI ALL quick reminder about the freeze", in: .email)
        #expect(upper.contains(",\n\n"), Comment(rawValue: upper))
    }

    @Test("a group word that is part of a longer phrase, or any other word, is not a greeting")
    func nonGreetingsStayWhole() {
        for input in ["hi there is a problem with the build", "hi all of you need to rebase", "Hi can you send this?", "hello teammates are on leave"] {
            let output = StyleFormatter.apply(.formal, to: input, in: .email)
            #expect(!output.contains("\n\n"), Comment(rawValue: "\(input) -> \(output)"))
        }
    }

    @Test("casual style does no greeting layout for a group greeting")
    func casualKeepsGroupGreetingInline() {
        let output = StyleFormatter.apply(.casual, to: "hi all quick reminder about the freeze", in: .email)
        #expect(!output.contains("\n\n"), Comment(rawValue: output))
    }
}
