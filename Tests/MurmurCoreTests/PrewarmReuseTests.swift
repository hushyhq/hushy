import Testing
@testable import MurmurCore

/// Release-time reuse of streaming prewarm (2026-09-26): groups prewarm cleaned are found in the
/// final transcript by their words, even when the final whole-utterance pass punctuates
/// differently, and only unseen text is cleaned at release. Plain punctuated sentences with no
/// disfluency keep `.hybrid` from calling the model, so these run deterministically.
@Suite("SmartCleaner prewarm reuse")
struct PrewarmReuseTests {
    let sentences = (0..<9).map { "The report for region number \($0) is ready for review today." }

    @Test("groups prewarmed from the streamed text are hits even when the final text is repunctuated")
    func hitsAcrossPunctuationChanges() async {
        let cleaner = SmartCleaner()
        let options = CleanupOptions(level: .clean)
        let streamed = sentences.joined(separator: " ")
        let groups = TextSegmentation.groups(streamed)
        #expect(groups.count >= 3)
        for group in groups where !group.isTail {
            await cleaner.prewarmGroup(group.text, options: options, strategy: .hybrid)
        }
        // The final pass merged sentences with commas and changed capitalization.
        let final = streamed.replacingOccurrences(of: ". The", with: ", the")
        let output = await cleaner.clean(final, options: options, strategy: .hybrid)
        let hits = output.groupSources.filter { $0 == .prewarmHit }.count
        #expect(hits == groups.count - 1)
        #expect(output.groupSources.last == .fresh)
        for index in 0..<9 { #expect(output.text.contains("region number \(index)")) }
    }

    @Test("a group whose words the final pass changed is cleaned fresh; unchanged later groups still hit")
    func changedWordMisses() async {
        let cleaner = SmartCleaner()
        let options = CleanupOptions(level: .clean)
        let streamed = sentences.joined(separator: " ")
        for group in TextSegmentation.groups(streamed) where !group.isTail {
            await cleaner.prewarmGroup(group.text, options: options, strategy: .hybrid)
        }
        let final = streamed.replacingOccurrences(of: "region number 0", with: "regional number 0")
        let output = await cleaner.clean(final, options: options, strategy: .hybrid)
        #expect(output.groupSources.first == .fresh)
        #expect(output.groupSources.contains(.prewarmHit))
        #expect(output.text.contains("regional number 0"))
        for index in 1..<9 { #expect(output.text.contains("region number \(index)")) }
    }

    @Test("clearing prewarmed groups means the next dictation cleans fresh")
    func clearResets() async {
        let cleaner = SmartCleaner()
        let options = CleanupOptions(level: .clean)
        let streamed = sentences.joined(separator: " ")
        for group in TextSegmentation.groups(streamed) where !group.isTail {
            await cleaner.prewarmGroup(group.text, options: options, strategy: .hybrid)
        }
        await cleaner.clearPrewarmedGroups()
        let output = await cleaner.clean(streamed, options: options, strategy: .hybrid)
        #expect(output.groupSources.allSatisfy { $0 == .fresh })
    }
}

@Suite("FragmentRepair")
struct FragmentRepairTests {
    @Test("keeps the word after the cue, even when the abandoned word was cut off", arguments: [
        ("with Ameri sorry Indian accent", "with Indian accent"),
        ("on the Tues- no Wednesday call", "on the Wednesday call"),
        ("send it to Mar I mean Maria", "send it to Maria"),
        ("the call is on tuesday sorry wednesday", "the call is on wednesday"),
        ("move it to the blue oops green folder", "move it to the green folder"),
    ])
    func repairs(input: String, expected: String) {
        #expect(FragmentRepair.apply(input) == expected)
    }

    @Test("apologies and non-repairs are untouched", arguments: [
        "I'm sorry about the delay",
        "I'm really sorry you had to wait",
        "we are so sorry for the trouble",
        "sorry guys, running late",
        "she felt sorry for him",
        "no problem at all",
        "there is no way that works",
        "I mean it",
        "say sorry to your sister",
        "What I mean is that the sidebar should remember its width.",
        "That I mean is fine",
    ])
    func negatives(text: String) {
        #expect(FragmentRepair.apply(text) == text)
    }
}

@Suite("NotXIMeanY")
struct NotXIMeanYTests {
    @Test("Y replaces X and the not leaves with X", arguments: [
        ("send the file to Maria, sorry, not Maria, I mean Mark", "send the file to Mark"),
        ("Sorry, not Tuesday, I mean Wednesday works for me", "Wednesday works for me"),
        ("book the room for Tuesday, no, not Tuesday, I mean Thursday", "book the room for Thursday"),
    ])
    func resolves(input: String, expected: String) {
        #expect(NotXIMeanY.apply(input) == expected)
    }

    @Test("leaves other uses of not and I mean alone", arguments: [
        "I do not mean that at all",
        "It's not Tuesday, it's Wednesday.",
        "Let's go, not Tuesday, I mean whenever works.",
        "I mean, it's not great.",
        "We did not ship it. I mean we tried.",
    ])
    func negatives(text: String) {
        #expect(NotXIMeanY.apply(text) == text)
    }
}
