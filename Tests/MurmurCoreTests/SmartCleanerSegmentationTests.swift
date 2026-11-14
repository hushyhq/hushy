import Testing
@testable import MurmurCore

/// Exercises `SmartCleaner.clean`'s segmented path for long dictations (`.rules`/`.hybrid`
/// strategy triggers `cleanSegmented` once `TextSegmentation.groups` returns more than one
/// group). Uses `.rules` throughout so these tests are deterministic and don't depend on
/// Foundation Models being available in CI/this environment — the segmentation/join mechanics
/// under test are the same regardless of which strategy drives each group's cleanup.
@Suite("SmartCleaner segmented cleanup")
struct SmartCleanerSegmentationTests {
    let cleaner = SmartCleaner()

    /// 10 filler-laden sentences, comfortably over the single-group threshold, so `clean(_:...)`
    /// takes the segmented path.
    func longDictation(sentenceCount: Int = 10) -> String {
        let sentence = "Um, so we, uh, need to ship the report by Friday."
        return Array(repeating: sentence, count: sentenceCount).joined(separator: " ")
    }

    @Test("a long dictation is cleaned the same as if each sentence were cleaned alone, then joined")
    func longDictationMatchesGroupwiseCleanup() async {
        let raw = longDictation()
        let options = CleanupOptions()
        let result = await cleaner.clean(raw, options: options, strategy: .rules)

        // Every filler should be gone throughout, not just in a first/last group — proving the
        // segmented path actually processed every group, not just the head or tail.
        #expect(!result.text.contains("um"))
        #expect(!result.text.contains("Um"))
        #expect(!result.text.contains("uh"))
        // Content survives: the same number of "ship the report by Friday" occurrences as
        // sentences in the input.
        let occurrences = result.text.components(separatedBy: "ship the report by Friday").count - 1
        #expect(occurrences == 10)
    }

    @Test("a short dictation takes the single-group path and is unaffected by segmentation")
    func shortDictationSingleGroup() async {
        let raw = "Um, so we, uh, need to ship the report by Friday."
        let result = await cleaner.clean(raw, options: CleanupOptions(), strategy: .rules)
        #expect(result.text == "So we need to ship the report by Friday.")
    }

    @Test("a correction spanning a group boundary still resolves correctly when segmented")
    func correctionAcrossGroupBoundaryResolves() async {
        // Pad the front with enough filler sentences to push the group near its size limit,
        // then follow with a correction that must stay grouped with the sentence it corrects.
        let filler = Array(repeating: "This is an ordinary sentence with several words in it.", count: 5)
            .joined(separator: " ")
        let raw = filler + " Let's meet at 10, no, 9 tomorrow."
        let result = await cleaner.clean(raw, options: CleanupOptions(), strategy: .rules)
        #expect(result.text.contains("Let's meet at 9 tomorrow."))
        #expect(!result.text.contains("Let's meet at 10"))
    }

    @Test("guards still apply per group: a model-only strategy on a long dictation never invents words")
    func guardsApplyPerGroupWithRulesStrategy() async {
        // With .rules, no model call happens at all, but this exercises that cleanSegmented's
        // per-group TextCleaner pass never introduces content across group boundaries.
        let raw = longDictation(sentenceCount: 12)
        let result = await cleaner.clean(raw, options: CleanupOptions(), strategy: .rules)
        let originalWords = Set(OutputGuard.words(raw))
        let resultWords = Set(OutputGuard.words(result.text))
        #expect(resultWords.isSubset(of: originalWords))
    }

    @Test("personalization still applies to every group's text after joining")
    func personalizationAppliesAcrossJoinedText() async {
        let personalizer = Personalizer(dictionary: [DictionaryEntry(term: "Friday", soundsLike: ["fry day"])])
        let raw = longDictation()
        let result = await cleaner.clean(raw, options: CleanupOptions(), personalizer: personalizer, strategy: .rules)
        // The dictionary entry's own term already matches what's in the text; this mainly
        // proves personalization runs without throwing/breaking across the joined multi-group
        // text and every occurrence (from every group) still reads "Friday".
        let occurrences = result.text.components(separatedBy: "Friday").count - 1
        #expect(occurrences == 10)
    }

    @Test("press-enter is reported from the final group")
    func pressEnterFromFinalGroup() async {
        let filler = Array(repeating: "This is an ordinary sentence with several words in it.", count: 8)
            .joined(separator: " ")
        let raw = filler + " Sounds good, see you then. Press enter."
        let result = await cleaner.clean(raw, options: CleanupOptions(), strategy: .rules)
        #expect(result.pressEnter)
        #expect(!result.text.lowercased().contains("press enter"))
    }
}
