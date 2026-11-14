import Foundation
import Testing
@testable import MurmurCore

/// One bad span in the whole-transcript model's answer used to cost the whole answer (TRY-87): a protected term the
/// model respelled, or "two B" written "2B", and the person got the rules draft with its fillers. Only the span goes back.
@Suite("Whole-transcript span repair", .timeLimit(.minutes(1)))
struct IntentSpanRepairTests {
    private struct Scripted: LanguageModel {
        let answer: String
        var identifier: String { "scripted-intent" }
        var availability: LanguageModelAvailability { .available }
        func supportsLanguage(_ languageCode: String) -> Bool { true }
        func prewarm(instructions: String) {}
        func prefixCache(instructions: String) async {}
        func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
            let data = try JSONSerialization.data(withJSONObject: ["text": answer])
            return String(decoding: data, as: UTF8.self)
        }
    }

    private func clean(_ raw: String, answer: String, terms: [String] = [], wholeTranscript: Bool = true) async -> SmartCleaner.Output {
        var options = CleanupOptions(level: .clean)
        options.protectedTerms = terms
        return await SmartCleaner(model: Scripted(answer: answer), health: ModelHealth(), wholeTranscript: { wholeTranscript })
            .clean(raw, options: options, strategy: .model)
    }

    private let termRaw = "so i think uh wispr flow you know is a really good tool for writing long emails every day"
    private let termAnswer = "I think Whisper Flow is a really good tool for writing long emails every day."

    @Test("a respelled protected term goes back and the filler removal around it stays")
    func protectedTermWholeTranscript() async {
        let output = await clean(termRaw, answer: termAnswer, terms: ["Wispr Flow"])
        let text = output.text.lowercased()
        #expect(text.contains("wispr flow"), "\(output.text)")
        #expect(!text.contains("whisper"))
        #expect(!text.contains(" uh ") && !text.contains("you know"), "\(output.text)")
        #expect(output.groups.first?.outcome == .used, "\(String(describing: output.groups.first?.guardCode))")
    }

    @Test("a respelled protected term goes back in the older per-group path too")
    func protectedTermGroupPath() async {
        let output = await clean(termRaw, answer: termAnswer, terms: ["Wispr Flow"], wholeTranscript: false)
        let text = output.text.lowercased()
        #expect(text.contains("wispr flow"), "\(output.text)")
        #expect(!text.contains("whisper"))
        #expect(!text.contains(" uh ") && !text.contains("you know"), "\(output.text)")
        #expect(output.groups.first?.outcome == .used, "\(String(describing: output.groups.first?.guardCode))")
    }

    @Test("a term the person keeps is never rewritten: with nothing else to keep the draft stands")
    func protectedTermWithNothingElseToKeep() async {
        let output = await clean("we should try wispr flow today", answer: "We should try Whisper Flow today.", terms: ["Wispr Flow"])
        #expect(!output.text.lowercased().contains("whisper"), "\(output.text)")
    }

    private let digitsRaw = "so the new model is um two B parameters and it runs you know really fast on my laptop"
    private let digitsAnswer = "The new model is 2B parameters and it runs really fast on my laptop."

    @Test("two B written 2B is the same value and the cleanup is kept")
    func sameValueDifferentSpelling() async {
        let output = await clean(digitsRaw, answer: digitsAnswer)
        #expect(output.text.contains("2B"), "\(output.text)")
        #expect(!output.text.lowercased().contains("you know") && !output.text.contains(" um "), "\(output.text)")
        #expect(output.groups.first?.outcome == .used, "\(String(describing: output.groups.first?.guardCode))")
    }

    @Test("two B written 2B is the same value in the older per-group path too")
    func sameValueGroupPath() async {
        let output = await clean(digitsRaw, answer: digitsAnswer, wholeTranscript: false)
        #expect(output.text.contains("2B") || output.text.lowercased().contains("two b"), "\(output.text)")
        #expect(!output.text.lowercased().contains("you know") && !output.text.contains(" um "), "\(output.text)")
        #expect(output.groups.first?.outcome == .used, "\(String(describing: output.groups.first?.guardCode))")
    }

    @Test("a changed value goes back to what was said in the older path, with the rest kept")
    func changedValueIsRepaired() async {
        let raw = "so the meeting will take 5 minutes and um we start at noon you know on the dot"
        let answer = "The meeting will take 6 minutes and we start at noon on the dot."
        let output = await clean(raw, answer: answer, wholeTranscript: false)
        #expect(output.text.contains("5 minutes"), "\(output.text)")
        #expect(!output.text.contains("6"), "\(output.text)")
        #expect(!output.text.lowercased().contains("you know"), "\(output.text)")
    }

    @Test("a changed value in the whole-transcript path is never kept: it goes back as the rules draft writes it")
    func changedValueWholeTranscript() async {
        let raw = "so the meeting will take 5 minutes and um we start at noon you know on the dot"
        let answer = "The meeting will take 6 minutes and we start at noon on the dot."
        let output = await clean(raw, answer: answer)
        #expect(!output.text.contains("6"), "\(output.text)")
        #expect(output.text.contains("5 minutes"), "\(output.text)")
        #expect(!output.text.lowercased().contains("you know"), "\(output.text)")
    }

    @Test("two values merged in a long answer: only that span goes back, the paragraphs and punctuation stay")
    func mergedValueInLongAnswer() async {
        let raw = "so um the plan for tomorrow is simple we meet the client at the office and walk them through the new dashboard "
            + "and the pricing page then lunch is at eight or maybe eight thirty at the place on main street and after that we fly home"
        let answer = "The plan for tomorrow is simple. We meet the client at the office and walk them through the new dashboard "
            + "and the pricing page.\n\nThen lunch is at 8:30 at the place on Main Street, and after that we fly home."
        let output = await clean(raw, answer: answer)
        #expect(output.text.contains("\n\n"), "\(output.text)")
        // Both values, as the rules draft writes them.
        #expect(Regex.firstMatch(output.text, "(?:eight|8) or maybe (?:eight thirty|8:30)") != nil, "\(output.text)")
        #expect(output.text.contains("The plan for tomorrow is simple. We meet"), "\(output.text)")
        #expect(!output.text.lowercased().contains(" um "), "\(output.text)")
        #expect(output.groups.first?.outcome == .used, "\(String(describing: output.groups.first?.guardCode))")
    }

    @Test("an added negation in a long answer: only that span goes back, the rest of the answer stays")
    func addedNegationInLongAnswer() async {
        let raw = "nothing should stay in review for more than two days and sofia wants like a clear owner for every ticket "
            + "so the backlog keeps growing every sprint and i will take a pass at sorting it this week"
        let answer = "Nothing should stay in review for more than two days. Sofia wants a clear owner for every ticket so the "
            + "backlog doesn't keep growing every sprint.\n\nI'll take a pass at sorting it this week."
        let output = await clean(raw, answer: answer)
        #expect(output.text.contains("keeps growing"), "\(output.text)")
        #expect(!output.text.contains("doesn't"), "\(output.text)")
        #expect(output.text.contains("\n\n") && output.text.contains("two days. Sofia"), "\(output.text)")
        #expect(output.groups.first?.outcome == .used, "\(String(describing: output.groups.first?.guardCode))")
    }

    @Test("with a retraction in the dictation, a value the answer got wrong never stays: it goes back to the draft or the draft stands")
    func retractionValueIsNeverKept() async {
        let raw = "the total is ten no wait twelve euros and we pay on friday"
        let answer = "The total is \u{20AC}10, and we pay on Friday."
        let output = await clean(raw, answer: answer)
        #expect(!output.text.contains("\u{20AC}10"), "\(output.text)")
        #expect(output.text.contains("12"), "\(output.text)")
    }

    @Test("a value span goes back whole, with its unit, never cut to the bare number")
    func valueSpanKeepsItsUnit() async {
        let raw = "so quick note the total hmm is ten so yeah thousand make that sixty euros in the meantime"
        let output = await clean(raw, answer: "Quick note: the total is \u{20AC}600 in the meantime.")
        #expect(!output.text.contains("600"), "\(output.text)")
        #expect(output.text.contains("euros"), "\(output.text)")
    }

    @Test("a long list with a self-correction and one wrong value: that value goes back, the list stays")
    func wrongValueInLongList() async {
        let raw = "okay so for the launch post 1 write a short intro that says we shipped today two list the three biggest changes "
            + "3 let's use the quill icon no wait 3 let's use the feather icon for the header four change the button to say try it free "
            + "number five keep the price at nine dollars a month after the trial and sixth mention that it works on every mac from 2020 on"
        let answer = "For the launch post:\n\n1. Write a short intro that says we shipped today.\n2. List the three biggest changes.\n"
            + "3. Use the feather icon for the header.\n4. Change the button to say \"Try it free\".\n"
            + "5. Keep the price at $19 a month after the trial.\n6. Mention that it works on every Mac from 2020 on."
        let output = await clean(raw, answer: answer)
        #expect(!output.text.contains("$19"), "\(output.text)")
        #expect(output.text.contains("\n2. List the three biggest changes."), "\(output.text)")
        #expect(output.text.contains("Use the feather icon"), "\(output.text)")
        #expect(output.groups.first?.outcome == .used, "\(String(describing: output.groups.first?.guardCode))")
    }

    @Test("number ranges keep their written numbers: a value check's refusal is not repaired to spoken words")
    func numberRangesStayWritten() async {
        let ranges: [(raw: String, answer: String, written: [String])] = [
            ("we expect a hundred or a hundred and twenty guests at the dinner on Friday",
             "We expect 100 or 120 guests at the dinner on Friday.", ["100", "120"]),
            ("three or four hundred dollars", "$300 or $400.", ["$300", "$400"]),
            ("two to three hundred dollars", "$200 to $300.", ["$200", "$300"]),
            ("five to ten thousand dollars", "$5,000 to $10,000.", ["$5,000", "$10,000"]),
        ]
        for range in ranges {
            let output = await clean(range.raw, answer: range.answer)
            for written in range.written {
                #expect(output.text.contains(written), "\(range.raw) -> \(output.text)")
            }
            #expect(!output.text.lowercased().contains("hundred") && !output.text.lowercased().contains("thousand"),
                    "\(range.raw) -> \(output.text)")
        }
    }

    @Test("a changed value is never kept when it is the only change")
    func changedValueAlone() async {
        let output = await clean("the meeting will take 5 minutes", answer: "The meeting will take 6 minutes.")
        #expect(!output.text.contains("6"), "\(output.text)")
    }
}
