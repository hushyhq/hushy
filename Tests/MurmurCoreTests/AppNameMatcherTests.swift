import Testing
@testable import MurmurCore

@Suite("Spoken app names resolve to installed apps, never helpers")
struct AppNameMatcherTests {
    private let installed: [AppNameMatcher.Candidate] = [
        .init(name: "Google Chrome"), .init(name: "Claude Code URL Handler"),
        .init(name: "Claude"), .init(name: "ChatGPT"),
        .init(name: "Antigravity IDE"), .init(name: "Visual Studio Code"),
        .init(name: "Figma"),
    ]

    @Test("common spoken aliases, punctuation and ASR spellings")
    func aliases() {
        for (spoken, expected) in [
            ("Chrome", "Google Chrome"), ("cloud", "Claude"),
            ("chat gbt", "ChatGPT"), ("anti gravity", "Antigravity IDE"),
            ("Visual Studio Code", "Visual Studio Code"), ("figam", "Figma"),
        ] {
            #expect(AppNameMatcher.best(spoken: spoken, among: installed)?.name == expected)
        }
    }

    @Test("an app nobody listed is still found from what speech makes of its name",
          arguments: ["Ghostty", "Ghost", "Ghosty", "Ghost T", "Ghost Tea", "Ghostie"])
    func unlistedApp(spoken: String) {
        let apps = installed + [.init(name: "Ghostty"), .init(name: "Terminal")]
        #expect(AppNameMatcher.best(spoken: spoken, among: apps)?.name == "Ghostty")
    }

    @Test("a service helper is not a substitute for the actual app")
    func excludesHelpers() {
        #expect(AppNameMatcher.best(spoken: "Claude", among: [.init(name: "Claude Code URL Handler")]) == nil)
        #expect(AppNameMatcher.best(spoken: "nonsense", among: installed) == nil)
    }

    @Test("edit distance stays independent across calls")
    func independentDistance() {
        #expect(AppNameMatcher.editDistance("figam", "figma") == 1)
        #expect(AppNameMatcher.editDistance("chrome", "figma") > 1)
        #expect(AppNameMatcher.editDistance("figam", "figma") == 1)
    }
}
