import Foundation

/// A website people write in, which the tone page can place on a tone like an app (TRY-93). A browser tab can be
/// anything, so the browser itself takes no tone; a site the person placed does (`ToneSettings.siteChoices`).
public struct KnownWebsite: Identifiable, Equatable, Sendable {
    /// What is stored for it ("google-docs"). Never a URL; a key has no dot, so it cannot be taken for a host.
    public let key: String
    public let name: String
    /// The hosts it is served from. A subdomain of one is the same site ("acme.notion.site").
    public let hosts: [String]
    /// How its tab title ends, lowercased, once the browser's own suffix is removed (" - google docs"), or the whole
    /// title. Anchored at the end, so a page that only mentions the site (a search, a help article) is not it.
    let titleEndings: [String]
    let wholeTitles: [String]
    /// How dictation there is classified when the person placed nothing: it gives the site's lane, as a native app's
    /// kind does (Gmail is Email, so Professional; ChatGPT is an AI app, so Prompt).
    public let category: AppCategory

    public var id: String { key }
}

public enum KnownWebsites {
    /// Popular writing sites, in the order the tone page offers them. Titles marked "assumed" were not checked in a
    /// browser; the host is always read when the title says nothing.
    public static let all: [KnownWebsite] = [
        // "<document> - Google Docs" (checked: the shape `AppCategory.webApps` already relies on).
        .init(key: "google-docs", name: "Google Docs", hosts: ["docs.google.com"],
              titleEndings: [" - google docs"], wholeTitles: [], category: .documents),
        // "Inbox (3) - <address> - Gmail".
        .init(key: "gmail", name: "Gmail", hosts: ["mail.google.com"],
              titleEndings: [" - gmail"], wholeTitles: ["gmail"], category: .email),
        // A Notion tab is titled with the page alone, so only its address names it.
        .init(key: "notion", name: "Notion web", hosts: ["notion.so", "notion.site", "notion.com"],
              titleEndings: [], wholeTitles: [], category: .documents),
        // "Mail - <name> - Outlook" (assumed).
        .init(key: "outlook", name: "Outlook web",
              hosts: ["outlook.office.com", "outlook.office365.com", "outlook.live.com", "outlook.cloud.microsoft"],
              titleEndings: [" - outlook"], wholeTitles: [], category: .email),
        // "<channel> - <workspace> - Slack" (assumed).
        .init(key: "slack", name: "Slack web", hosts: ["app.slack.com"],
              titleEndings: [" - slack"], wholeTitles: [], category: .workMessages),
        // "ChatGPT" on a new chat; a conversation is titled with its own name, so the address is read then.
        .init(key: "chatgpt", name: "ChatGPT web", hosts: ["chatgpt.com", "chat.openai.com"],
              titleEndings: [" - chatgpt"], wholeTitles: ["chatgpt"], category: .aiPrompts),
        // "<conversation> - Claude" (assumed).
        .init(key: "claude", name: "Claude.ai", hosts: ["claude.ai"],
              titleEndings: [" - claude"], wholeTitles: ["claude"], category: .aiPrompts),
    ]

    public static func site(key: String) -> KnownWebsite? { all.first { $0.key == key } }

    /// The known site a browser window title names, if any. The browser's own suffix (" - Google Chrome") is removed
    /// first (`WebCodeEditor.pageTitle`).
    public static func site(forTitle windowTitle: String?) -> KnownWebsite? {
        guard let windowTitle else { return nil }
        let title = WebCodeEditor.pageTitle(from: windowTitle).trimmingCharacters(in: .whitespaces).lowercased()
        guard !title.isEmpty else { return nil }
        return all.first { site in
            site.wholeTitles.contains(title) || site.titleEndings.contains { title.hasSuffix($0) && title.count > $0.count }
        }
    }

    /// The known site a host belongs to: the host itself or a subdomain of it.
    public static func site(forHost host: String) -> KnownWebsite? {
        all.first { $0.hosts.contains { WebsiteAddress.host(host, isWithin: $0) } }
    }
}

/// Turning an address into what is kept: only the host, and only for a site the person placed.
public enum WebsiteAddress {
    /// The host of an address a person typed or a browser reported, lowercased, without "www." or a port. `nil` for
    /// anything that is not a web address with a dotted host (a file, a mail link, "localhost").
    public static func host(of address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              // "mailto:a@b.com" given a scheme would read as a user and a password at b.com.
              components.user == nil, components.password == nil,
              var host = components.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let allowed = CharacterSet.lowercaseLetters.union(.decimalDigits).union(CharacterSet(charactersIn: ".-"))
        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."),
              host.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return host
    }

    /// What is stored for an address: the known site's key when it is one, else its host.
    public static func key(from address: String) -> String? {
        guard let host = host(of: address) else { return nil }
        return KnownWebsites.site(forHost: host)?.key ?? host
    }

    /// True for `host` itself and any of its subdomains: "eng.wiki.acme.io" is within "wiki.acme.io".
    static func host(_ candidate: String, isWithin host: String) -> Bool {
        candidate == host || candidate.hasSuffix("." + host)
    }

    /// The name a stored key is shown with: the known site's name, or the host the person typed.
    public static func name(forKey key: String) -> String { KnownWebsites.site(key: key)?.name ?? key }
}

/// Which placed site a browser tab is, from what key-down can read. Built only when at least one site has a choice
/// of its own (`ToneSettings.siteMatcher`), so a person who placed none pays nothing.
public struct WebsiteMatcher: Equatable, Sendable {
    public enum TitleMatch: Equatable, Sendable {
        /// The title names a placed site.
        case placed(String)
        /// The title names a known site that has no choice: nothing applies, and no address needs reading.
        case notPlaced
        /// The title names no known site: only the address can say.
        case unknown
    }

    /// Site keys with a choice: known keys and hosts the person typed.
    public let placed: Set<String>

    public init?(placed: some Sequence<String>) {
        let keys = Set(placed)
        guard !keys.isEmpty else { return nil }
        self.placed = keys
    }

    public func match(title: String?) -> TitleMatch {
        guard let site = KnownWebsites.site(forTitle: title) else { return .unknown }
        return placed.contains(site.key) ? .placed(site.key) : .notPlaced
    }

    /// The placed site a page's host belongs to, if any.
    public func match(host: String) -> String? {
        if let known = KnownWebsites.site(forHost: host) { return placed.contains(known.key) ? known.key : nil }
        // The most specific host the person typed wins ("eng.acme.io" over "acme.io").
        return placed.filter { $0.contains(".") && WebsiteAddress.host(host, isWithin: $0) }.max { $0.count < $1.count }
    }

    /// What a log line may say about a site: a known site's key, or "custom" for a host the person typed.
    public static func logKey(_ key: String?) -> String {
        guard let key else { return "-" }
        return KnownWebsites.site(key: key) == nil ? "custom" : key
    }
}
