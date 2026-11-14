import Testing
@testable import MurmurCore

/// Founder, 2026-10-05: "Anywhere code editors when cursor is placed in should be code". A tab
/// that is a web code editor (vscode.dev, github.dev, Codespaces, Replit, StackBlitz, CodeSandbox,
/// JSFiddle, JupyterLab, Colab, GitHub's file editor) gets code treatment. The earlier ruling
/// stands for everything else: ordinary tabs, including GitHub and GitLab pull request, issue and
/// review pages, are prose. Only the bundle ID and window title are used, and a title must be
/// shaped like the editor's own (a suffix match, not a mention).
@Suite("Web code editors in a browser are code")
struct BrowserCodeEditorTests {
    /// (product, title) pairs as the editor shows them, before any browser suffix.
    static let editorTitles: [(String, String)] = [
        ("vscode.dev", "parser.ts - hushy - Visual Studio Code"),
        ("vscode.dev welcome", "Get Started - Visual Studio Code"),
        ("github.dev", "parser.ts - hushy [GitHub] - Visual Studio Code"),
        ("Codespaces", "parser.ts - hushy [Codespaces: fuzzy-space-123] - Visual Studio Code"),
        ("Codespaces remote", "parser.ts - hushy [Codespaces: fuzzy-space-123] — Visual Studio Code — Codespaces"),
        ("VS Code Insiders", "parser.ts - hushy — Visual Studio Code — Insiders"),
        ("Replit", "api-gateway - Replit"),
        ("StackBlitz", "react-starter - StackBlitz"),
        ("CodeSandbox", "react-starter - CodeSandbox"),
        ("JSFiddle", "Edit fiddle - JSFiddle - Code Playground"),
        ("JSFiddle new fiddle", "JSFiddle - Code Playground"),
        ("JupyterLab", "analysis.ipynb - JupyterLab"),
        ("Jupyter Notebook", "analysis.ipynb - Jupyter Notebook"),
        ("Colab", "analysis.ipynb - Colab"),
        ("GitHub file editor", "Editing hushy/Sources/Parser.swift at main · example/hushy"),
        ("GitHub file editor with site name", "Editing README.md at feature/x · acme/api-gateway · GitHub"),
    ]

    /// The suffix each browser appends to the page title (Safari and Arc append nothing).
    static let browsers: [(bundleID: String, suffix: String)] = [
        ("com.google.Chrome", " - Google Chrome"),
        ("com.google.Chrome", " - Google Chrome - Ada"),
        ("com.apple.Safari", ""),
        ("company.thebrowser.Browser", ""),
        ("com.brave.Browser", " - Brave"),
        ("com.microsoft.edgemac", " - Microsoft Edge"),
        ("org.mozilla.firefox", " — Mozilla Firefox"),
    ]

    static let editorCases: [String] = editorTitles.map(\.1)

    /// Real signed-out document titles read on macOS, 2026-10-05.
    static let observedTitles = [
        "Workspace — Visual Studio Code",
        "vscode-extension-samples [GitHub] — Visual Studio Code — GitHub",
        "vscode-extension-samples — Visual Studio Code — github+7b2276223a312c22726566223a7b2274797065223a342c226964223a226d61696e227d7d",
        "Vitejs - Vite (forked) - StackBlitz",
        "JSFiddle - React, Tailwind, and code Playground",
        "React - JSFiddle - React, Tailwind, and code Playground",
        "Welcome To Colab - Colab",
    ]

    @Test("observed editor titles are code with and without Chrome's suffix", arguments: observedTitles)
    func observedTitlesAreCode(title: String) {
        #expect(AppCategory.classify(bundleID: "com.apple.Safari", windowTitle: title) == .code, "Safari / \(title)")
        #expect(AppCategory.classify(bundleID: "com.google.Chrome", windowTitle: title + " - Google Chrome") == .code, "Chrome / \(title)")
    }

    @Test("a github.dev title stays code ahead of the GitHub web-app entry")
    func githubDevPrecedesWorkMessages() {
        let title = Self.observedTitles[1] + " - Google Chrome"
        let category = AppCategory.classify(bundleID: "com.google.Chrome", windowTitle: title)
        #expect(category == .code)
        #expect(category != .workMessages)
    }

    @Test("each web code editor is code in Chrome", arguments: editorCases)
    func codeInChrome(title: String) {
        #expect(AppCategory.classify(bundleID: "com.google.Chrome", windowTitle: title + " - Google Chrome") == .code, "\(title)")
    }

    @Test("each web code editor is code in Safari, which adds no suffix", arguments: editorCases)
    func codeInSafari(title: String) {
        #expect(AppCategory.classify(bundleID: "com.apple.Safari", windowTitle: title) == .code, "\(title)")
    }

    @Test("every browser's own title suffix is tolerated")
    func browserSuffixes() {
        for (bundleID, suffix) in Self.browsers {
            for title in Self.editorCases {
                #expect(AppCategory.classify(bundleID: bundleID, windowTitle: title + suffix) == .code, "\(bundleID) / \(title + suffix)")
            }
        }
    }

    @Test("matching is case-insensitive for the product name")
    func caseInsensitive() {
        #expect(AppCategory.classify(bundleID: "com.apple.Safari", windowTitle: "app - REPLIT") == .code)
    }

    @Test("code in a browser gets code treatment and no writing style")
    func codeTreatment() {
        let category = AppCategory.classify(bundleID: "com.google.Chrome", windowTitle: "analysis.ipynb - JupyterLab - Google Chrome")
        #expect(category == .code)
        #expect(StyleContext.from(category) == nil)
        #expect(TechnicalTokenContext.make(category: category, bundleID: "com.google.Chrome", windowTitle: "x") == nil)
    }

    @Test("a web editor title is ignored outside a browser")
    func notInNativeApps() {
        #expect(AppCategory.classify(bundleID: "com.apple.Notes", windowTitle: "analysis.ipynb - JupyterLab") == .documents)
    }

    // MARK: Ordinary tabs stay prose (earlier ruling)

    @Test("pull request, issue, review and merge request pages stay work messages", arguments: [
        "Refactor user lookup · Pull Request #1203 · acme/api-gateway · GitHub",
        "Crash when profile is nil · Issue #88 · acme/api-gateway · GitHub",
        "Files changed · Pull Request #1203 · acme/api-gateway · GitHub",
        "Editing docs at night · Pull Request #12 · acme/api · GitHub",
        "Editing the config at runtime · Issue #5 · acme/api · GitHub",
        "Draft: Add retry to ledger writer (!93) · Merge requests · acme / billing · GitLab",
    ])
    func reviewPagesStayProse(title: String) {
        for bundleID in ["com.google.Chrome", "com.apple.Safari"] {
            let suffix = bundleID == "com.google.Chrome" ? " - Google Chrome" : ""
            #expect(AppCategory.classify(bundleID: bundleID, windowTitle: title + suffix) == .workMessages, "\(bundleID) / \(title)")
        }
    }

    @Test("Gmail, Slack, Google Docs and an unknown page keep their categories")
    func otherWebAppsUnchanged() {
        #expect(AppCategory.classify(bundleID: "com.google.Chrome", windowTitle: "Inbox (3) - you@gmail.com - Gmail - Google Chrome") == .email)
        #expect(AppCategory.classify(bundleID: "com.google.Chrome", windowTitle: "general - Acme - Slack - Google Chrome") == .workMessages)
        #expect(AppCategory.classify(bundleID: "com.apple.Safari", windowTitle: "Q4 plan - Google Docs") == .documents)
        #expect(AppCategory.classify(bundleID: "com.apple.Safari", windowTitle: "Some page") == .other)
    }

    @Test("a page that only mentions a code editor stays out of code", arguments: [
        // search results
        "vscode.dev - Google Search - Google Chrome",
        "github.dev codespaces - Search",
        // video about Jupyter
        "Jupyter Notebook tutorial for beginners - YouTube",
        // blog post about Replit
        "Why we moved our classroom to Replit - Medium",
        "Replit vs StackBlitz: which is better? - The Dev Blog",
        // documentation sites
        "Visual Studio Code - Code Editing. Redefined",
        "Python in Visual Studio Code",
        "Download Visual Studio Code - Mac, Linux, Windows",
        "JupyterLab Documentation — JupyterLab 4.0 documentation",
        "Using Colab with Drive - Google Colab Docs",
        // marketing and home pages
        "Replit – Build apps and sites with AI",
        "Replit",
        "Home - Replit",
        "Pricing - Replit",
        "StackBlitz",
        "Pricing - StackBlitz",
        "Dashboard - CodeSandbox",
        "CodeSandbox: Cloud development platform",
        "Project Jupyter | Home",
        "Google Colab",
        // VS Code mentions and unrelated trailing products
        "Python Tutorial - Visual Studio Code - YouTube",
        "Debugging - Visual Studio Code - Stack Overflow",
        "Crash on open - Visual Studio Code - GitHub",
        "Visual Studio Code - Wikipedia",
        "Pricing - Visual Studio Code",
        "Project - Visual Studio Code - GitHub - Extra",
        "Project [GitHub] - Visual Studio Code - GitLab",
        "Project - Visual Studio Code - github+",
        "Project - Visual Studio Code - github+payload with spaces",
        "Project [:] - Visual Studio Code - GitHub",
        "Project [::] — Visual Studio Code — :",
        // JSFiddle mentions without an editor tagline
        "JSFiddle - Wikipedia",
        "How to use JSFiddle - YouTube",
        "jsfiddle playground alternatives - Google Search",
        "React - JSFiddle - Playground guide",
        "React - JSFiddle - superplayground",
        // GitHub pages that are not the editor
        "GitHub - example/hushy: dictation for Mac",
        "hushy/Sources/Parser.swift at main · example/hushy · GitHub",
        "hushy/README.md at main · example/hushy",
        "Pull requests · example/hushy · GitHub",
        "Visual Studio Code - Releases · microsoft/vscode · GitHub",
        // an email whose subject mentions an editor
        "Setup - Visual Studio Code - you@gmail.com - Gmail",
    ])
    func lookAlikesStayProse(title: String) {
        for bundleID in ["com.google.Chrome", "com.apple.Safari"] {
            let suffix = bundleID == "com.google.Chrome" ? " - Google Chrome" : ""
            #expect(AppCategory.classify(bundleID: bundleID, windowTitle: title + suffix) != .code, "\(bundleID) / \(title)")
        }
    }

    @Test("a plain browser with no title is never code", arguments: AppCategory.browsers)
    func noTitleIsNotCode(bundleID: String) {
        #expect(AppCategory.classify(bundleID: bundleID, windowTitle: nil) != .code)
        #expect(AppCategory.classify(bundleID: bundleID, windowTitle: "") != .code)
    }
}
