import Foundation

/// Recognises a browser tab that is a web code editor from its window title alone (founder,
/// 2026-10-05: "Anywhere code editors when cursor is placed in should be code"). No URL, no
/// Accessibility read: the title is all `AppCategory.classify` receives.
///
/// A closed table of title shapes, each anchored at the end of the title (after the browser's
/// own " - Google Chrome" style suffix is removed), so a page that merely mentions a product
/// (a search, a video, a blog post, a docs page) is not matched. Marketing and dashboard pages
/// that share a product's suffix are excluded by `nonProjectNames`.
enum WebCodeEditor {
    /// The browser's own suffix on the window title (Safari and Arc add none). Chrome may add a
    /// profile name after it ("… - Google Chrome - Ada"); Edge may add "and N more pages".
    private static let browserSuffix = try! NSRegularExpression(
        pattern: #"\s[-–—]\s(?:Google Chrome|Brave|Microsoft\W*Edge|Mozilla Firefox|Firefox|Vivaldi|Opera|Zen Browser|Safari)(?:\s[-–—]\s.*)?$"#,
        options: [.caseInsensitive])
    private static let titleSeparator = try! NSRegularExpression(pattern: #" [-–—] "#)
    private static let remoteLabel = try! NSRegularExpression(pattern: #"\[([^\[\]]+)\]$"#)
    private static let schemePayload = try! NSRegularExpression(pattern: #"^[a-z][a-z0-9-]*\+\S+$"#)
    private static let playgroundEnding = try! NSRegularExpression(
        pattern: #"\bplayground$"#, options: [.caseInsensitive])

    /// "<name> - <product>": the editor titles the tab "<project or file> - <product>". A bare
    /// product name, or one of `nonProjectNames` in front of it, is a site page, not an editor.
    private static let namedProducts = [
        "replit",  // assumed, not checked (needs an account)
        "stackblitz",  // verified 2026-10-05: "<project> - StackBlitz"
        "codesandbox",  // assumed, not checked (needs an account)
        "jupyterlab",  // assumed, not checked; JupyterLite shows only "JupyterLite"
        "jupyter notebook",  // assumed, not checked; Notebook 7 in JupyterLite shows only the bare notebook name, so this may never match
        "colab",  // verified 2026-10-05: "<notebook> - Colab"
        "colaboratory",  // assumed, not checked; older Colab suffix
    ]

    /// GitHub's in-page file editor: "Editing <path> at <branch> · <owner>/<repo>", optionally
    /// followed by " · GitHub". The branch part holds no "·", so a pull request or issue whose own
    /// title starts with "Editing …" ("Editing x at night · Pull Request #12 · o/r") is not matched.
    /// Assumed, not checked (needs an account).
    private static let githubFileEditor = try! NSRegularExpression(
        pattern: #"^Editing\s.+\sat\s[^·]+\s·\s[\w.-]+/[\w.-]+(?:\s·\s(?:GitHub))?$"#,
        options: [.caseInsensitive])

    /// Names a product site uses for its own pages, never for a project.
    private static let nonProjectNames: Set<String> = [
        "home", "login", "log in", "sign in", "sign up", "signup", "pricing", "docs", "documentation",
        "blog", "templates", "explore", "dashboard", "about", "careers", "status", "support", "help",
        "download", "downloads", "learn", "community", "enterprise", "teams", "education",
    ]

    /// The title with the browser's own suffix removed.
    static func pageTitle(from windowTitle: String) -> String {
        let range = NSRange(windowTitle.startIndex..., in: windowTitle)
        guard let match = browserSuffix.firstMatch(in: windowTitle, range: range),
              let cut = Range(match.range, in: windowTitle)
        else { return windowTitle }
        return String(windowTitle[..<cut.lowerBound])
    }

    static func matches(windowTitle: String) -> Bool {
        let title = pageTitle(from: windowTitle).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return false }
        if githubFileEditor.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil {
            return true
        }
        let parts = titleParts(title)
        return matchesVSCode(parts) || matchesJSFiddle(parts)
            || hasProjectPrefix(title.lowercased(), before: namedProducts)
    }

    private static func titleParts(_ title: String) -> [String] {
        let matches = titleSeparator.matches(in: title, range: NSRange(title.startIndex..., in: title))
        var parts: [String] = []
        var start = title.startIndex
        for match in matches {
            guard let range = Range(match.range, in: title) else { continue }
            parts.append(String(title[start..<range.lowerBound]))
            start = range.upperBound
        }
        parts.append(String(title[start...]))
        return parts
    }

    /// Verified 2026-10-05 for vscode.dev and github.dev; Codespaces is assumed, not checked
    /// (needs an account). VS Code may add a matching remote label or a scheme+payload part.
    private static func matchesVSCode(_ parts: [String]) -> Bool {
        guard let app = parts.firstIndex(where: { $0.lowercased() == "visual studio code" }),
              app > 0, !parts[app - 1].isEmpty else { return false }
        if app == 1 && nonProjectNames.contains(parts[0].lowercased()) { return false }
        let isInsiders = parts.indices.contains(app + 1) && parts[app + 1].lowercased() == "insiders"
        let remoteStart = app + (isInsiders ? 2 : 1)
        if remoteStart == parts.count { return true }
        guard remoteStart + 1 == parts.count else { return false }
        let remote = parts[remoteStart]
        let preceding = parts[app - 1]
        if let match = remoteLabel.firstMatch(in: preceding, range: NSRange(preceding.startIndex..., in: preceding)),
           let contentRange = Range(match.range(at: 1), in: preceding) {
            let content = String(preceding[contentRange])
            let label = content.split(separator: ":", maxSplits: 1).first.map(String.init) ?? content
            if remote.caseInsensitiveCompare(content) == .orderedSame ||
                remote.caseInsensitiveCompare(label) == .orderedSame { return true }
        }
        return schemePayload.firstMatch(in: remote, range: NSRange(remote.startIndex..., in: remote)) != nil
    }

    /// Verified 2026-10-05: a new fiddle has no name; a saved fiddle adds one before JSFiddle.
    private static func matchesJSFiddle(_ parts: [String]) -> Bool {
        guard parts.count == 2 || parts.count == 3 else { return false }
        let product = parts.count - 2
        guard parts[product].lowercased() == "jsfiddle" else { return false }
        if product == 1 && (parts[0].isEmpty || nonProjectNames.contains(parts[0].lowercased())) { return false }
        let tagline = parts[parts.count - 1]
        return playgroundEnding.firstMatch(in: tagline, range: NSRange(tagline.startIndex..., in: tagline)) != nil
    }

    /// True when `title` is "<something> <dash> <suffix>" for one of `suffixes` and the
    /// something is not a product-site page name.
    private static func hasProjectPrefix(_ title: String, before suffixes: [String]) -> Bool {
        for suffix in suffixes {
            for dash in ["-", "–", "—"] {
                let tail = " \(dash) \(suffix)"
                guard title.hasSuffix(tail) else { continue }
                let name = title.dropLast(tail.count).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty && !nonProjectNames.contains(name) { return true }
            }
        }
        return false
    }
}
