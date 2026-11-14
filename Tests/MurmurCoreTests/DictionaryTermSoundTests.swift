import Testing
@testable import MurmurCore

/// A word in the Dictionary is what the person says. When the recognizer writes a word that sounds like it instead
/// ("codecs" for "Codex"), the Dictionary word replaces it, whether or not the person also filled in "often heard as".
/// All terms and sentences here are invented.
@Suite("Dictionary words that the recognizer writes as a sound-alike", .serialized)
struct DictionaryTermSoundTests {
    private func settings(_ terms: [String], heardAs: [String: [String]] = [:]) -> PipelineSettings {
        PipelineSettings(personalizer: Personalizer(dictionary: terms.map {
            DictionaryEntry(term: $0, soundsLike: heardAs[$0] ?? [])
        }))
    }

    @Test("x sounds like cs: a term ending in x matches the plural-looking word the recognizer wrote")
    func xIsCs() {
        #expect(ContextSpellingFixer.phoneticKey("vellix") == ContextSpellingFixer.phoneticKey("vellics"))
        #expect(ContextSpellingFixer.phoneticKey("codex") == ContextSpellingFixer.phoneticKey("codecs"))
        // Still apart from words that merely look close.
        #expect(ContextSpellingFixer.phoneticKey("vellix") != ContextSpellingFixer.phoneticKey("vellum"))
    }

    @Test("a word the recognizer wrote that is not an English word, and sounds like a Dictionary word, becomes it")
    func unknownSoundAlike() {
        let dictionary = settings(["Vellix"])
        #expect(DictionaryTermFixer.fixNames("please ask vellics to review the draft", settings: dictionary)
                == "please ask Vellix to review the draft")
        #expect(DictionaryTermFixer.fixNames("vellics is faster than the old tool", settings: dictionary)
                == "Vellix is faster than the old tool")
        #expect(DictionaryTermFixer.fixNames("the notes from vellics are in the folder", settings: dictionary)
                == "the notes from Vellix are in the folder")
    }

    @Test("an ordinary English word that sounds like a Dictionary word becomes it where a name belongs")
    func ordinaryWordInANamePosition() {
        let dictionary = settings(["Relix"])
        #expect(DictionaryTermFixer.fixNames("ask relics to open the file", settings: dictionary) == "ask Relix to open the file")
        #expect(DictionaryTermFixer.fixNames("open relics", settings: dictionary) == "open Relix")
    }

    @Test("an ordinary English word in an ordinary sentence is left alone")
    func ordinaryWordElsewhere() {
        let dictionary = settings(["Relix"])
        for text in ["the relics were old", "we found two relics in the cellar", "he sells relics at the market"] {
            #expect(DictionaryTermFixer.fixNames(text, settings: dictionary) == text, "\(text)")
        }
    }

    @Test("a word that sounds different, a short term and a word already spelled right are not touched")
    func noFalseMatches() {
        let dictionary = settings(["Vellix", "Zed"])
        for text in ["the vellum was thin", "vellis is a name", "he said zad", "ask Vellix to review it"] {
            #expect(DictionaryTermFixer.fixNames(text, settings: dictionary) == text, "\(text)")
        }
    }

    @Test("a spoken variant the person listed under another word is not taken for this one")
    func listedVariantStaysWithItsOwnWord() {
        let dictionary = settings(["Vellix", "Vellic"], heardAs: ["Vellic": ["vellics"]])
        #expect(DictionaryTermFixer.fixNames("ask vellics to review", settings: dictionary) == "ask vellics to review")
    }

    @Test("two Dictionary words that fit the same sound leave the word as it was")
    func ambiguousSound() {
        let dictionary = settings(["Vellix", "Velics"])
        #expect(DictionaryTermFixer.fixNames("ask vellics to review", settings: dictionary) == "ask vellics to review")
    }

    @Test("the whole path: a Dictionary word written as a sound-alike is fixed before cleanup and survives it")
    func throughThePipeline() async {
        let dictionary = settings(["Vellix"])
        let pipeline = DictationPipeline(transcriber: FixedTranscriber(text: "so i asked vellics to check the build"))
        let result = await pipeline.clean("so i asked vellics to check the build", settings: dictionary, strategy: .rules)
        #expect(result.text.contains("Vellix"), "\(result.text)")
        #expect(!result.text.lowercased().contains("vellics"))
    }

    private struct FixedTranscriber: Transcriber {
        let text: String
        func transcribe(_ samples: [Float]) async throws -> String { text }
    }
}
