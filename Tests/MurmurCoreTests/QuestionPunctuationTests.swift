import Testing
@testable import MurmurCore

@Suite("QuestionPunctuation")
struct QuestionPunctuationTests {
    @Test("detects direct questions", arguments: [
        "is the beta build signed",
        "Should we remember the position per tab",
        "can you send me the link",
        "Do you think we should show the word count",
        "could it be a toggle in settings",
        "so how long does the model take to load",
        "What do you think",
        "What time does the meeting start",
        "Which one is better",
        "how about Tuesday",
        "what if we cached it",
        "Is it ready yet",
        "Don't you think it's too long",
        "Have you seen the new build",
        "Why not ship it today",
        "Does the app crash on launch",
    ])
    func detectsQuestions(sentence: String) {
        #expect(QuestionPunctuation.opensQuestion(sentence))
    }

    @Test("statements are not questions", arguments: [
        "What I mean is that the sidebar should remember its width",
        "what i'm trying to say is the reminders should show up",
        "When you have twenty projects it becomes a wall of text",
        "How we do it matters",
        "What we decided was fine",
        "I wonder if we can make the shortcut configurable",
        "Do the dishes before dinner",
        "Have a good weekend",
        "Should you need anything, call me",
        "Had we known, we would have waited",
        "Should be fine",
        "Will do",
        "Did it",
        "What is clear is that we need logs",
        "Can't wait to see it",
        "So far the test suite takes 4 minutes",
        "What didn't go well, the estimate for the migration task was way off",
        "Hey are you free for lunch tomorrow",
        "Is",
        "",
    ])
    func statementsAreNotQuestions(sentence: String) {
        #expect(!QuestionPunctuation.opensQuestion(sentence))
    }

    @Test("marks question sentences and splits tag and run-together questions", arguments: [
        ("Is it ready yet.", "Is it ready yet?"),
        ("I wonder if we can make the shortcut configurable what do you think.",
         "I wonder if we can make the shortcut configurable. What do you think?"),
        ("So how long does the model take to load on an M1, is it more than two seconds?",
         "So how long does the model take to load on an M1? Is it more than two seconds?"),
        ("It is just bad. What do you think we can do about that should we remember it per tab or is that overkill.",
         "It is just bad. What do you think we can do about that? Should we remember it per tab or is that overkill?"),
        ("Maybe check the doc. Can you remind me what we decided.", "Maybe check the doc. Can you remind me what we decided?"),
        ("The plan works, does that make sense.", "The plan works. Does that make sense?"),
        ("I don't know what do you think about it.", "I don't know. What do you think about it?"),
        ("The new invoice layout looks a bit too how would I say it.", "The new invoice layout looks a bit too... How would I say it?"),
        ("The new onboarding feels like a what's the word.", "The new onboarding feels like a... What's the word?"),
        ("The dashboard needs a more what do you call it.", "The dashboard needs a more... What do you call it?"),
        ("We could call the release something like a how do I put it.", "We could call the release something like a... How do I put it?"),
        ("Ines wants the design to feel a bit more, how should I put it.", "Ines wants the design to feel a bit more... How should I put it?"),
    ])
    func appliesFixes(input: String, expected: String) {
        #expect(QuestionPunctuation.apply(input) == expected)
    }

    @Test("leaves statements, exclamations, lists and existing punctuation alone", arguments: [
        "What I mean is that the sidebar should remember its width.",
        "Wait for the upload to finish, then click Export.",
        "Should you need anything, call me.",
        "Is it ready yet?",
        "Do it now!",
        "Topics for the sync:\n- Can we ship\n- Roadmap",
        "Sounds good, see you tomorrow.",
        "Should we ship it now or is it too early?",
        "Can we ship it, if it is ready?",
        "We could call the release something like. A how do I put it.",
        "I don't know how would I say it.",
        "Ask them how do I put it.",
        "How would I say it?",
    ])
    func negatives(text: String) {
        #expect(QuestionPunctuation.apply(text) == text)
    }

    @Test("an unterminated question is left for the terminal-punctuation pass")
    func unterminatedLeftAlone() {
        #expect(QuestionPunctuation.apply("is it ready") == "is it ready")
    }
}
