import Testing
@testable import MurmurCore

@Suite("A spoken app name is a match, a short list to choose from, or nothing close")
struct AppNameMatcherResolutionTests {
    private let installed: [AppNameMatcher.Candidate] = [
        .init(name: "Google Chrome"), .init(name: "Claude Code URL Handler"),
        .init(name: "Claude"), .init(name: "ChatGPT"),
        .init(name: "Antigravity IDE"), .init(name: "Visual Studio Code"),
        .init(name: "Figma"), .init(name: "Slack"), .init(name: "Notion"),
    ]

    @Test("whatever `best` is sure about stays a confident match, unchanged",
          arguments: ["Chrome", "cloud", "chat gbt", "anti gravity", "Visual Studio Code", "figam", "slack", "Notion"])
    func confidentIsBest(spoken: String) throws {
        let expected = try #require(AppNameMatcher.best(spoken: spoken, among: installed))
        #expect(AppNameMatcher.resolve(spoken: spoken, among: installed) == .confident(expected))
    }

    @Test("two letters off a short name is close, not sure: it is offered, nothing opens")
    func closeButNotSure() {
        // "flask" is two edits from "Slack"; `best` allows one on a five-letter name.
        #expect(AppNameMatcher.best(spoken: "flask", among: installed) == nil)
        #expect(AppNameMatcher.resolve(spoken: "flask", among: installed) == .suggestions([.init(name: "Slack")]))
    }

    @Test("a short word that starts an app's name is offered that app")
    func shortPrefix() {
        let apps: [AppNameMatcher.Candidate] = [.init(name: "Wendy"), .init(name: "Notion"), .init(name: "Slack")]
        #expect(AppNameMatcher.best(spoken: "wen", among: apps) == nil)
        guard case .suggestions(let list) = AppNameMatcher.resolve(spoken: "wen", among: apps) else {
            Issue.record("expected suggestions")
            return
        }
        #expect(list.first?.name == "Wendy")
    }

    @Test("never more than three, best first; ties go to the shorter name, then A to Z")
    func atMostThree() {
        let apps = ["Plank", "Slack", "Blast", "Clasp", "Black"].map { AppNameMatcher.Candidate(name: $0) }
        #expect(AppNameMatcher.best(spoken: "flask", among: apps) == nil)
        let result = AppNameMatcher.resolve(spoken: "flask", among: apps)
        #expect(result == .suggestions([.init(name: "Black"), .init(name: "Blast"), .init(name: "Clasp")]))
        #expect(AppNameMatcher.maxSuggestions == 3)
    }

    @Test("a closer spelling is listed before a looser one")
    func closerFirst() {
        let apps: [AppNameMatcher.Candidate] = [.init(name: "Slack"), .init(name: "Flush"), .init(name: "Notion")]
        guard case .suggestions(let list) = AppNameMatcher.resolve(spoken: "flask", among: apps) else {
            Issue.record("expected suggestions")
            return
        }
        // Flush has all but one of "flask"'s consonants; Slack is two edits off; Notion is nowhere near.
        #expect(list.map(\.name) == ["Flush", "Slack"])
    }

    @Test("nothing resembling the words is nothing close")
    func nothingClose() {
        #expect(AppNameMatcher.resolve(spoken: "xylophone", among: installed) == .nothingClose)
        #expect(AppNameMatcher.resolve(spoken: "", among: installed) == .nothingClose)
        #expect(AppNameMatcher.resolve(spoken: "  ", among: installed) == .nothingClose)
        #expect(AppNameMatcher.resolve(spoken: "q", among: installed) == .nothingClose)
        #expect(AppNameMatcher.resolve(spoken: "slack", among: []) == .nothingClose)
    }

    @Test("a helper is never offered in place of the app")
    func helpersNeverOffered() {
        let helpers: [AppNameMatcher.Candidate] = [.init(name: "Claude Code URL Handler"), .init(name: "Slack Helper")]
        #expect(AppNameMatcher.resolve(spoken: "claude", among: helpers) == .nothingClose)
        guard case .suggestions(let list) = AppNameMatcher.resolve(spoken: "flask", among: installed + helpers) else {
            Issue.record("expected suggestions")
            return
        }
        #expect(!list.contains { $0.name.contains("Helper") || $0.name.contains("Handler") })
    }

    @Test("the same app listed twice is offered once")
    func noDuplicates() {
        let apps: [AppNameMatcher.Candidate] = [.init(name: "Slack"), .init(name: "Slack", bundleID: "com.tinyspeck.slackmacgap")]
        guard case .suggestions(let list) = AppNameMatcher.resolve(spoken: "flask", among: apps) else {
            Issue.record("expected suggestions")
            return
        }
        #expect(list.count == 1)
    }

    @Test("the thresholds are named and sensible")
    func thresholds() {
        #expect(AppNameMatcher.suggestionFloor > 0 && AppNameMatcher.suggestionFloor < 1)
        #expect(AppNameMatcher.minimumLettersToSuggest >= 2)
    }
}
