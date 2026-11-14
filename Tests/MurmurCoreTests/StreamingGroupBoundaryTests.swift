import Testing
@testable import MurmurCore

/// Covers the group-boundary stability `StreamingDictationSession.prewarmClosedGroups` depends
/// on (task: "no dropped or duplicated words at chunk boundaries"): as FluidAudio confirms more
/// of the transcript and `manager.confirmedTranscript` grows, re-splitting it with
/// `TextSegmentation.groups` must keep producing the *same* text for every earlier (already
/// prewarmed) group — never reshuffling words across a group boundary as more text arrives,
/// which would otherwise mean a later `groups()` call silently drops or duplicates words versus
/// what was already cleaned and cached for that group index.
///
/// This models the real incremental sequence: `prewarmClosedGroups` is called after every
/// FluidAudio transcription update, each time re-splitting whatever has been confirmed so far —
/// never with a stable, complete text up front the way `SmartCleanerSegmentationTests`/
/// `TextSegmentationTests` already exercise.
@Suite("Streaming group-boundary stability as confirmed text grows")
struct StreamingGroupBoundaryTests {
    /// Ten identical filler-laden sentences, each with a distinct trailing word so a dropped or
    /// duplicated word is easy to detect by counting occurrences.
    private func sentences(_ count: Int) -> [String] {
        (0..<count).map { "This is an ordinary filler sentence number \($0)." }
    }

    @Test("every earlier group's text is unchanged as more sentences are confirmed and appended")
    func earlierGroupsStableAsTextGrows() {
        let allSentences = sentences(12)
        var confirmedSoFar = ""
        var lastNonTailGroupTexts: [String] = []

        for sentence in allSentences {
            confirmedSoFar = confirmedSoFar.isEmpty ? sentence : confirmedSoFar + " " + sentence
            let groups = TextSegmentation.groups(confirmedSoFar)
            let nonTail = groups.filter { !$0.isTail }.map(\.text)

            // Every group that was already closed on the previous iteration must still be
            // present, verbatim, in this iteration's non-tail groups — this is exactly the
            // invariant `prewarmClosedGroups`'s `prewarmedGroupTexts` de-dup set relies on to
            // avoid re-cleaning (or, worse, silently losing) a group's text.
            for previous in lastNonTailGroupTexts {
                #expect(
                    nonTail.contains(previous),
                    "group '\(previous.prefix(40))…' disappeared or changed after more text was confirmed"
                )
            }
            lastNonTailGroupTexts = nonTail
        }
    }

    @Test("no word is dropped or duplicated across the full incremental sequence, once finished")
    func noDroppedOrDuplicatedWordsAcrossIncrementalGrouping() {
        let allSentences = sentences(12)
        let fullText = allSentences.joined(separator: " ")
        var confirmedSoFar = ""
        for sentence in allSentences {
            confirmedSoFar = confirmedSoFar.isEmpty ? sentence : confirmedSoFar + " " + sentence
        }
        #expect(confirmedSoFar == fullText)

        // The final incremental split, re-joined, must exactly equal the final whole text —
        // i.e. after all sentences have arrived, splitting into groups and joining them back
        // loses nothing and adds nothing, matching `TextSegmentationTests.groupsRoundTrip`'s
        // guarantee but specifically for text that was built up incrementally (sentence by
        // sentence, as `prewarmClosedGroups` sees it) rather than handed over all at once.
        let finalGroups = TextSegmentation.groups(confirmedSoFar)
        let rejoined = TextSegmentation.join(finalGroups.map(\.text))
        #expect(rejoined == fullText)

        // Every distinct sentence number appears exactly once in the rejoined text.
        for index in 0..<allSentences.count {
            let marker = "number \(index)."
            let occurrences = rejoined.components(separatedBy: marker).count - 1
            #expect(occurrences == 1, "sentence \(index) appeared \(occurrences) times, expected exactly 1")
        }
    }

    @Test("a group only ever closes once its sentence boundary is confirmed — no partial-sentence group")
    func groupsNeverSplitMidSentence() {
        var confirmedSoFar = "This sentence is still being spoken and has not ended yet"
        var groups = TextSegmentation.groups(confirmedSoFar)
        // With no terminal punctuation, `Sentences.split` treats this as one (still-open)
        // sentence — a single group, correctly still the tail, never prewarmed.
        #expect(groups.count == 1)
        #expect(groups[0].isTail)

        confirmedSoFar += "."
        groups = TextSegmentation.groups(confirmedSoFar)
        #expect(groups.count == 1)
        #expect(groups[0].text.hasSuffix("."))
    }
}
