import Foundation

/// What the person is told once an update has been downloaded in the background, and where its
/// release notes come from. Pure values, so the words and the notes handling are testable
/// without Sparkle or a window.
struct UpdateReadyPrompt: Equatable {
    let notes: UpdateReleaseNotes
}

/// The notes behind "What's new": the text embedded in the appcast item when there is some,
/// otherwise the page it links to, otherwise nothing (and no link is shown).
enum UpdateReleaseNotes: Equatable {
    case none
    case text(String)
    case link(URL)

    /// `description` and `format` are the appcast item's embedded notes ("html", "plain-text",
    /// "markdown"; a missing format means HTML, as in Sparkle). HTML is reduced to readable lines.
    static func make(description: String?, format: String?, link: URL?) -> UpdateReleaseNotes {
        if let raw = description?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let isHTML = (format ?? "html").lowercased() == "html"
            let text = isHTML ? readableText(fromHTML: raw) : raw
            if !text.isEmpty { return .text(text) }
        }
        return link.flatMap(trustedNotesURL).map(UpdateReleaseNotes.link) ?? .none
    }

    /// The only notes page Hushy will open: https, on tryhushy.com or one of its subdomains
    /// (updates.tryhushy.com today). The URL comes from the appcast, so nothing else is trusted.
    static func trustedNotesURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(),
              host == "tryhushy.com" || host.hasSuffix(".tryhushy.com")
        else { return nil }
        return url
    }

    /// Notes as light Markdown (or plain text), keeping line breaks and turning "- " into bullets.
    /// Never clickable: notes are information, so every link attribute is removed and a Markdown
    /// link shows as its plain text.
    static func attributed(_ notes: String) -> AttributedString {
        let bulleted = notes.replacingOccurrences(of: "(?m)^\\s*[-*] ", with: "• ", options: .regularExpression)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var text = (try? AttributedString(markdown: bulleted, options: options)) ?? AttributedString(bulleted)
        for run in text.runs where run.link != nil {
            text[run.range].link = nil
        }
        return text
    }

    static func readableText(fromHTML html: String) -> String {
        var text = html
        let rules: [(String, String)] = [
            ("(?i)<br\\s*/?>|</p>|</li>|</h[1-6]>|</div>", "\n"),
            ("(?i)<li[^>]*>", "• "),
            ("<[^>]+>", ""),
        ]
        for (pattern, replacement) in rules {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        let entities = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&amp;": "&"]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.reduce(into: [String]()) { kept, line in
            if line.isEmpty, kept.last?.isEmpty ?? true { return }
            kept.append(line)
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Every sentence the update flow shows.
enum UpdateCopy {
    static let relaunchNow = "Relaunch now"
    static let later = "Later"
    static let whatsNew = "What's new"
    static let hideWhatsNew = "Hide"
    static let switchTitle = "Install updates automatically"
    static let switchDetail = "Hushy downloads new versions in the background and asks you once to relaunch."
    static let readyDetail = "It's downloaded and ready. Relaunch to start using it, or it installs when you quit Hushy."

    /// No version: the marketing version stays the same across releases, and people are not shown build numbers.
    static let readyTitle = "A new version of Hushy is ready"

    /// The line under "Updates" in Settings → About.
    static func statusText(installsAutomatically: Bool, checksAutomatically: Bool = true) -> String {
        if !checksAutomatically { return "Checks only when you ask." }
        return installsAutomatically
            ? "New versions download in the background. You choose when to relaunch."
            : "Checks for updates automatically and asks before installing."
    }
}
