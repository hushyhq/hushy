import Foundation
import Testing

@testable import MurmurCore

private struct NoApps: InstalledApps {
    func isInstalled(_ bundleID: String) -> Bool { false }
    func displayName(_ bundleID: String) -> String? { nil }
}

/// TRY-93 follow-up: a website (Google Docs, Gmail, Notion…) can be placed on any tone, As spoken included, as a chip
/// of its own. The browser still takes no tone; the page does. Only a site key or the host the person typed is kept.
@Suite("Websites on the tone page")
struct WebsiteToneTests {
    private static let chrome = "com.google.Chrome"

    private func board(_ settings: ToneSettings, prompt: Bool = true) -> ToneBoard {
        ToneBoard.make(settings: settings, installed: NoApps(), promptAvailable: prompt)
    }

    // MARK: Recognising the site

    @Test("a known site is named by the end of its tab title, never by a mention", arguments: [
        ("Q3 plan - Google Docs", "google-docs"),
        ("Q3 plan - Google Docs - Google Chrome", "google-docs"),
        ("Inbox (3) - someone@example.com - Gmail", "gmail"),
        ("Mail - Dana Smith - Outlook", "outlook"),
        ("general (Channel) - Acme - Slack", "slack"),
        ("ChatGPT", "chatgpt"),
        ("Trip plan - Claude", "claude"),
    ])
    func titles(title: String, key: String) {
        #expect(KnownWebsites.site(forTitle: title)?.key == key)
    }

    @Test("a page that only mentions a site is not that site", arguments: [
        "claude - Google Search", "How to use Google Docs offline", "gmail login help - YouTube", "", "Notion",
    ])
    func mentions(title: String) {
        #expect(KnownWebsites.site(forTitle: title) == nil)
    }

    @Test("hosts match the site and its subdomains, never a look-alike")
    func hosts() {
        #expect(KnownWebsites.site(forHost: "docs.google.com")?.key == "google-docs")
        #expect(KnownWebsites.site(forHost: "www.notion.so")?.key == "notion")
        #expect(KnownWebsites.site(forHost: "acme.notion.site")?.key == "notion")
        #expect(KnownWebsites.site(forHost: "mail.google.com")?.key == "gmail")
        #expect(KnownWebsites.site(forHost: "chat.openai.com")?.key == "chatgpt")
        #expect(KnownWebsites.site(forHost: "docs.google.com.example.net") == nil)
        #expect(KnownWebsites.site(forHost: "notdocs.google.com") == nil)
        #expect(KnownWebsites.site(forHost: "google.com") == nil)
    }

    @Test("an address the person types becomes a site key: a known site's key, else the bare host")
    func typedAddresses() {
        #expect(WebsiteAddress.key(from: "https://docs.google.com/document/d/abc/edit") == "google-docs")
        #expect(WebsiteAddress.key(from: "https://www.Example.com/path?x=1") == "example.com")
        #expect(WebsiteAddress.key(from: "example.com:8080") == "example.com")
        #expect(WebsiteAddress.key(from: "  wiki.acme.io  ") == "wiki.acme.io")
        for bad in ["", "localhost", "not a site", "file:///Users/x/notes.txt", "mailto:a@b.com", "http://"] {
            #expect(WebsiteAddress.key(from: bad) == nil, "\(bad)")
        }
        #expect(WebsiteAddress.host(of: "https://www.notion.so/page") == "notion.so")
    }

    @Test("with nothing placed there is no matcher, so key-down reads no address")
    func noPlacementsNoRead() {
        #expect(ToneSettings.standard.siteMatcher == nil)
        #expect(ToneSettings.standard.addingSite("gmail").siteMatcher == nil)
        #expect(ToneSettings.standard.settingSite(.asSpoken, key: "gmail").siteMatcher != nil)
    }

    @Test("the title decides when it names a known site; only an unnamed tab needs the address")
    func matcher() throws {
        let settings = ToneSettings.standard
            .settingSite(.asSpoken, key: "google-docs").settingSite(.tone(.casual), key: "wiki.acme.io")
        let matcher = try #require(settings.siteMatcher)
        #expect(matcher.match(title: "Plan - Google Docs") == .placed("google-docs"))
        #expect(matcher.match(title: "Inbox - Gmail") == .notPlaced)
        #expect(matcher.match(title: "Team wiki") == .unknown)
        #expect(matcher.match(title: nil) == .unknown)
        #expect(matcher.match(host: "docs.google.com") == "google-docs")
        #expect(matcher.match(host: "mail.google.com") == nil)
        #expect(matcher.match(host: "eng.wiki.acme.io") == "wiki.acme.io")
        #expect(matcher.match(host: "acme.io") == nil)
        #expect(WebsiteMatcher.logKey("google-docs") == "google-docs" && WebsiteMatcher.logKey("wiki.acme.io") == "custom")
    }

    @Test("resolving a site from a title and host is cheap enough for key-down")
    func resolutionCost() throws {
        let settings = ToneSettings.standard
            .settingSite(.asSpoken, key: "google-docs").settingSite(.tone(.casual), key: "wiki.acme.io")
        let matcher = try #require(settings.siteMatcher)
        let rounds = 20_000
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for index in 0..<rounds {
                _ = matcher.match(title: index.isMultiple(of: 2) ? "Plan - Google Docs - Google Chrome" : "Team wiki")
                _ = matcher.match(host: "eng.wiki.acme.io")
            }
        }
        let microseconds = Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6
        print("website match: \(String(format: "%.2f", microseconds / Double(rounds))) µs per title + host")
        #expect(microseconds / Double(rounds) < 200)
    }

    // MARK: What a placed site does to the dictation

    @Test("a site on As spoken is word for word in any browser; the same page unplaced keeps its tone")
    func siteIsVerbatim() {
        let settings = ToneSettings.standard.settingSite(.asSpoken, key: "google-docs")
        let plan = settings.plan(for: .documents, bundleID: Self.chrome, site: "google-docs")
        #expect(plan.level == .verbatim && plan.tone == nil && plan.style == nil)
        #expect(settings.register(for: .documents, bundleID: Self.chrome, site: "google-docs") == nil)
        #expect(settings.dictationLevel(for: "com.apple.Safari", site: "google-docs") == .verbatim)
        #expect(settings.dictationLevel(for: Self.chrome, site: nil) == .polished)
        #expect(settings.dictationLevel(for: Self.chrome, site: "gmail") == .polished)
        // A site key only means something in a browser.
        #expect(settings.dictationLevel(for: "com.apple.Notes", site: "google-docs") == .polished)
        let run = PipelineSettings.forDictation(
            cleanup: CleanupOptions(level: .verbatim), tone: settings,
            mode: Mode.builtIns(userName: "")[0].resolvingAppCleanupLevel(.verbatim), category: .documents,
            bundleID: Self.chrome, windowTitle: "Plan - Google Docs", site: "google-docs")
        #expect(run.cleanupOptions.level == .verbatim && run.tone == nil && run.style == nil)
    }

    @Test("a site on a tone gets that tone and its register, like an app's own choice")
    func siteTone() {
        let settings = ToneSettings.standard.settingSite(.tone(.professional), key: "notion")
            .settingSite(.prompt, key: "google-docs")
        #expect(settings.plan(for: .other, bundleID: Self.chrome, site: "notion").tone == .professional)
        #expect(settings.register(for: .other, bundleID: Self.chrome, site: "notion") == .professional)
        #expect(settings.register(for: .documents, bundleID: Self.chrome, site: "google-docs") == .prompt)
        // The tab still follows its kind with no site placed.
        #expect(settings.plan(for: .email, bundleID: Self.chrome).tone == .professional)
        #expect(settings.register(for: .other, bundleID: Self.chrome) == nil)
    }

    // MARK: The board

    @Test("each known site sits in the lane its kind gives, as a native app does")
    func naturalLanes() {
        let expected: [String: ToneLane] = [
            "google-docs": .refined, "gmail": .professional, "notion": .refined, "outlook": .professional,
            "slack": .refined, "chatgpt": .prompt, "claude": .prompt,
        ]
        #expect(Set(KnownWebsites.all.map(\.key)) == Set(expected.keys))
        var settings = ToneSettings.standard
        for site in KnownWebsites.all { settings = settings.addingSite(site.key) }
        let board = board(settings)
        for site in KnownWebsites.all {
            let chip = board.app(id: ToneBoard.siteChipID(site.key))
            #expect(chip?.lane == expected[site.key] && chip?.isSite == true && chip?.isPlaced == false, "\(site.key)")
        }
        // Without register lines the AI sites sit in the tone they really get.
        #expect(self.board(settings, prompt: false).app(id: ToneBoard.siteChipID("claude"))?.lane == .refined)
    }

    @Test("adding a site to a lane places it there; adding it to its own lane only lists it")
    func addingSites() throws {
        let docs = ToneBoard.addingSite("google-docs", to: .asSpoken, in: .standard, promptAvailable: true)
        #expect(docs.siteChoices == ["google-docs": .asSpoken] && docs.addedSites == ["google-docs"])
        let chip = try #require(board(docs).app(id: ToneBoard.siteChipID("google-docs")))
        #expect(chip.lane == .asSpoken && chip.isPlaced && chip.name == "Google Docs")
        #expect(board(docs).lane(.asSpoken)?.apps.map(\.name) == ["Google Docs"])
        let gmail = ToneBoard.addingSite("gmail", to: .professional, in: .standard, promptAvailable: true)
        #expect(gmail.siteChoices.isEmpty && gmail.addedSites == ["gmail"])
        // A chip moved back to where its kind puts it stays on the page, with no choice of its own.
        let back = ToneBoard.moving(chip, to: .refined, in: docs, promptAvailable: true)
        #expect(back.siteChoices.isEmpty && board(back).app(id: ToneBoard.siteChipID("google-docs"))?.lane == .refined)
        // Removed, nothing of it is left.
        #expect(ToneBoard.removingSite(chip, from: docs) == .standard)
    }

    @Test("a typed address is added as its own chip; one that is not a website is refused")
    func addingByAddress() throws {
        let added = try #require(ToneBoard.addingSite(address: "https://wiki.acme.io/home", to: .asSpoken, in: .standard, promptAvailable: true))
        #expect(added.siteChoices == ["wiki.acme.io": .asSpoken])
        #expect(board(added).app(id: ToneBoard.siteChipID("wiki.acme.io"))?.name == "wiki.acme.io")
        let known = try #require(ToneBoard.addingSite(address: "docs.google.com", to: .casual, in: .standard, promptAvailable: true))
        #expect(known.siteChoices == ["google-docs": .tone(.casual)])
        #expect(ToneBoard.addingSite(address: "not a site", to: .casual, in: .standard, promptAvailable: true) == nil)
    }

    @Test("sites are stored by key only and survive a relaunch")
    func storage() throws {
        let settings = ToneBoard.addingSite("google-docs", to: .asSpoken, in: .standard, promptAvailable: true)
            .addingSite("wiki.acme.io")
        let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        #expect(json.contains("\"sites\"") && json.contains("google-docs") && !json.contains("http"))
        #expect(try JSONDecoder().decode(ToneSettings.self, from: Data(json.utf8)) == settings)
    }
}
