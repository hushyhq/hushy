import Testing
@testable import MurmurCore

/// A browser tab is prose, whatever site it shows (founder, 2026-10-04: "in browser let's treat it
/// as prose"), except a web code editor, which is code (founder, 2026-10-05; see
/// BrowserCodeEditorTests). Editors and terminals stay code. A GitHub or GitLab tab is a work message (a PR
/// description or a review comment), so the spoken technical-token rules run there; Codepen,
/// Replit and any other site are plain prose. Technical tokens already in the text are kept by
/// the token rules, not by the code classification.
@Suite("Browser destinations are prose")
struct BrowserProseTests {
    private static let githubPullRequest = "Refactor user lookup · Pull Request #1203 · acme/api-gateway · GitHub"
    private static let gitlabMergeRequest = "Draft: Add retry to ledger writer (!93) · Merge requests · acme / billing · GitLab"

    /// The cleanup options the app builds for a destination (see `DictationController`).
    private func options(bundleID: String, windowTitle: String? = nil) -> CleanupOptions {
        let category = AppCategory.classify(bundleID: bundleID, windowTitle: windowTitle)
        var options = CleanupOptions(level: .clean, voiceCommandsEnabled: false)
        options.isCodeContext = category == .code
        options.technicalTokens = TechnicalTokenContext.make(category: category, bundleID: bundleID, windowTitle: windowTitle)
        return options
    }

    private func clean(_ raw: String, bundleID: String, windowTitle: String? = nil) -> String {
        TextCleaner(options: options(bundleID: bundleID, windowTitle: windowTitle)).clean(raw).text
    }

    @Test("a browser on a GitHub pull request or GitLab merge request is a work message",
          arguments: [githubPullRequest, gitlabMergeRequest])
    func pullRequestPagesAreWorkMessages(title: String) {
        for bundleID in ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "org.mozilla.firefox"] {
            let category = AppCategory.classify(bundleID: bundleID, windowTitle: title)
            #expect(category == .workMessages, "\(bundleID) on \(title)")
            #expect(StyleContext.from(category) == .workMessages, "\(bundleID): styled as a work message")
        }
    }

    @Test("Codepen, Replit and an arbitrary site are plain prose", arguments: [
        "Pen - CodePen", "Replit - main.py", "Hacker News", "Stack Overflow - Where developers learn",
    ])
    func otherSitesAreOther(title: String) {
        #expect(AppCategory.classify(bundleID: "com.google.Chrome", windowTitle: title) == .other)
    }

    @Test("an ordinary page in a browser is never code, with or without a window title", arguments: AppCategory.browsers)
    func browsersAreNeverCode(bundleID: String) {
        for title in [nil, "", "GitHub", "Codepen", "Replit - main.py", "Pull Request #1 · GitHub", "Merge requests · GitLab"] {
            #expect(AppCategory.classify(bundleID: bundleID, windowTitle: title) != .code, "\(bundleID) / \(title ?? "nil")")
        }
    }

    @Test("a sentence dictated into a GitHub or GitLab tab gets capital and full stop",
          arguments: [githubPullRequest, gitlabMergeRequest])
    func sentencesGetProseTreatment(title: String) {
        let out = clean("we should add a test for the expired token case", bundleID: "com.apple.Safari", windowTitle: title)
        #expect(out == "We should add a test for the expired token case.")
    }

    @Test("editors and terminals keep code treatment with the same text", arguments: [
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode", "dev.zed.Zed",
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.jetbrains.intellij",
    ])
    func codeAppsStayCode(bundleID: String) {
        #expect(AppCategory.classify(bundleID: bundleID, windowTitle: Self.githubPullRequest) == .code)
        #expect(AppCategory.classify(bundleID: bundleID) == .code)
        let out = clean("we should add a test for the expired token case", bundleID: bundleID, windowTitle: Self.githubPullRequest)
        #expect(out == "we should add a test for the expired token case")
    }

    @Test("a path, a flag and backticked code survive in a browser sentence", arguments: [githubPullRequest, gitlabMergeRequest])
    func technicalTokensSurvive(title: String) {
        let raw = "please don't pass --no-verify when you touch src/api/handlers/user.ts and keep `getUserById` as is"
        let out = clean(raw, bundleID: "com.google.Chrome", windowTitle: title)
        #expect(out.hasPrefix("Please don't pass"))
        for token in ["--no-verify", "src/api/handlers/user.ts", "`getUserById`"] {
            #expect(out.contains(token), "\(token) lost: \(out)")
        }
        #expect(out.hasSuffix("."))
    }

    @Test("spoken paths and flags are converted in a GitHub or GitLab tab", arguments: [githubPullRequest, gitlabMergeRequest])
    func spokenTokensConvert(title: String) {
        let path = clean("lgtm just one thing in src slash api slash handlers slash user dot ts the error leaks the query",
                         bundleID: "com.apple.Safari", windowTitle: title)
        #expect(path.contains("src/api/handlers/user.ts"), "\(path)")
        #expect(!path.contains("slash"), "\(path)")
        let flag = clean("please don't pass dash dash no verify here because the hook catches the lint errors",
                         bundleID: "com.apple.Safari", windowTitle: title)
        #expect(flag.contains("--no-verify"), "\(flag)")
        #expect(!flag.contains("dash dash"), "\(flag)")
    }

    @Test("a GitHub tab gets exactly what Slack gets for spoken member access (no rule for it yet)")
    func spokenDotNameMatchesSlack() {
        let raw = "this will crash when profile dot name is nil so please guard it"
        let github = clean(raw, bundleID: "com.apple.Safari", windowTitle: Self.githubPullRequest)
        let slack = clean(raw, bundleID: "com.apple.Safari", windowTitle: "general | Acme Slack")
        #expect(github == slack, "\(github) vs \(slack)")
    }

    @Test("an ordinary sentence with no technical evidence is unchanged by the token rules", arguments: [githubPullRequest, gitlabMergeRequest])
    func plainSentenceUnchanged(title: String) {
        let raw = "i went for a walk by the river and ate a slash of lemon with dash of salt"
        let out = clean(raw, bundleID: "com.apple.Safari", windowTitle: title)
        #expect(out == "I went for a walk by the river and ate a slash of lemon with dash of salt.")
    }

    @Test("a flag at the start of a browser sentence keeps its exact form")
    func flagAtSentenceStart() {
        let out = clean("--force is risky here", bundleID: "com.google.Chrome", windowTitle: Self.githubPullRequest)
        #expect(out.hasPrefix("--force is risky"))
    }

    @Test("web apps recognised by title are unchanged by the browser rule")
    func otherWebAppsUnchanged() {
        #expect(AppCategory.classify(bundleID: "com.google.Chrome", windowTitle: "Inbox - Gmail") == .email)
        #expect(AppCategory.classify(bundleID: "com.google.Chrome", windowTitle: "general - Slack") == .workMessages)
        #expect(AppCategory.classify(bundleID: "com.google.Chrome", windowTitle: "Q4 plan - Google Docs") == .documents)
        #expect(AppCategory.classify(bundleID: "com.google.Chrome", windowTitle: "Some page") == .other)
    }
}
