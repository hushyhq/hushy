import Foundation
import Testing
@testable import MurmurCore

/// A full stop that closes an abbreviation is not a sentence end: the word after "p.m." or "e.g." is not capitalized
/// as the start of a new sentence. All sentences here are invented.
@Suite("Capital letters after abbreviations")
struct SentenceAbbreviationTests {
    private func cleaned(_ spoken: String) -> String {
        TextCleaner(options: CleanupOptions(level: .clean)).clean(spoken).text
    }

    @Test("a written time with p.m. does not start a sentence at the next word",
          arguments: [
              ("the call is at 2:45 p.m. on thursday so please be ready", "The call is at 2:45 p.m. on Thursday so please be ready."),
              ("we open at 9 a.m. and close at 5 p.m. on friday", "We open at 9 a.m. and close at 5 p.m. on Friday."),
              ("the call is at 6 p.m. on thursday", "The call is at 6 p.m. on Thursday."),
              ("the call is at 6 pm. on thursday", "The call is at 6 pm. on Thursday."),
              ("the call is at 6 P.M. on thursday", "The call is at 6 P.M. on Thursday."),
              ("the call is at 6 p. m. on thursday", "The call is at 6 p. m. on Thursday."),
          ])
    func meridiem(spoken: String, expected: String) {
        #expect(cleaned(spoken) == expected)
    }

    @Test("an On a model wrote after p.m. goes back to lower case, with or without the dots")
    func modelCapital() {
        #expect(Punctuation.tidy("The call is at 6 p.m. On Thursday.") == "The call is at 6 p.m. on Thursday.")
        #expect(Punctuation.tidy("The call is at 6:00pm. On Thursday.") == "The call is at 6:00pm. on Thursday.")
        #expect(Punctuation.tidy("The call is at 6 pm On Thursday.") == "The call is at 6 pm on Thursday.")
        #expect(Punctuation.tidy("The call is at 6:30 PM at the office.") == "The call is at 6:30 PM at the office.")
        // A conjunction a model wrote after a full stop may be its own sentence break.
        #expect(Punctuation.tidy("The call is at 6 p.m. But we left.") == "The call is at 6 p.m. But we left.")
    }

    @Test("the weekday after a time keeps its capital, and a sentence on a plain number is left alone")
    func weekdayAndNumbers() {
        #expect(Punctuation.tidy("the call is at 6 p.m. thursday works") == "The call is at 6 p.m. Thursday works")
        #expect(Punctuation.tidy("we need 6. on thursday we start") == "We need 6. On thursday we start")
    }

    @Test("e.g., i.e., vs. and cf. never end a sentence")
    func latinAbbreviations() {
        #expect(Punctuation.tidy("bring a tool, e.g. a screwdriver, and a light") == "Bring a tool, e.g. a screwdriver, and a light")
        #expect(Punctuation.tidy("the lead, i.e. the new hire, will join") == "The lead, i.e. the new hire, will join")
        #expect(Punctuation.tidy("cats vs. dogs is an old debate") == "Cats vs. dogs is an old debate")
        #expect(Punctuation.tidy("it is on page two, cf. the appendix") == "It is on page two, cf. the appendix")
    }

    @Test("etc. before a conjunction continues, and otherwise a sentence can start after it")
    func etcetera() {
        #expect(Punctuation.tidy("we need pens, paper, etc. and a stapler") == "We need pens, paper, etc. and a stapler")
        #expect(Punctuation.tidy("we need pens, paper, etc. then we leave") == "We need pens, paper, etc. Then we leave")
    }

    @Test("a sentence that really ends on a time still starts the next one with a capital")
    func realSentenceEnd() {
        #expect(Punctuation.tidy("the call is at 6 p.m. we will start on time") == "The call is at 6 p.m. We will start on time")
        #expect(Punctuation.tidy("I am. then we go") == "I am. Then we go")
        #expect(Punctuation.tidy("it was 10 a.m. the team arrived") == "It was 10 a.m. The team arrived")
    }

    @Test("a title is followed by a name, which keeps its capital")
    func titles() {
        #expect(Punctuation.tidy("ask dr. okafor and mr. bell") == "Ask dr. Okafor and mr. Bell")
    }
}

@Suite("Capital letters after a time in a model's answer")
struct ModelAnswerTimeCapitalTests {
    private struct FixedAnswerModel: LanguageModel {
        let answer: String
        var identifier: String { "fixed-answer" }
        var availability: LanguageModelAvailability { .available }
        func supportsLanguage(_ languageCode: String) -> Bool { true }
        func prewarm(instructions: String) {}
        func prefixCache(instructions: String) async {}
        func respond(
            instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
        ) async throws -> String {
            let data = try JSONEncoder().encode(["text": answer])
            return String(decoding: data, as: UTF8.self)
        }
    }

    @Test("a model that starts a sentence after the time does not leave an On behind", arguments: [
        "The meeting is at 6 p.m. On Thursday.", "The meeting is at 6. On Thursday.",
    ])
    func noCapitalOn(answer: String) async {
        let cleaner = SmartCleaner(model: FixedAnswerModel(answer: answer), health: ModelHealth())
        let output = await cleaner.clean("the meeting is at six pm on thursday", options: CleanupOptions(level: .clean))
        #expect(!output.text.contains(" On "), "\(output.text)")
    }
}
