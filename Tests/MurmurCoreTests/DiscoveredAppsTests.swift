import Foundation
import Synchronization
import Testing

@testable import MurmurCore

/// A pretend Mac: the apps installed on it and what each declares. Never the real machine.
private struct FakeMac: InstalledApps {
    let apps: [InstalledAppInfo]
    func isInstalled(_ bundleID: String) -> Bool { apps.contains { $0.bundleID == bundleID } }
    func displayName(_ bundleID: String) -> String? { apps.first { $0.bundleID == bundleID }?.name }
    func discoveredApps() -> [InstalledAppInfo] { apps }

    static func app(_ id: String, _ name: String, _ category: String? = nil) -> InstalledAppInfo {
        InstalledAppInfo(bundleID: id, name: name, declaredCategory: category.map { "public.app-category.\($0)" })
    }
}

/// Waits on a semaphore from a test body (the call itself is not marked async-unavailable inside a plain function).
private func block(_ semaphore: DispatchSemaphore) { semaphore.wait() }

private final class Counter: Sendable {
    let value = Mutex(0)
}

private final class Flag: Sendable {
    let value = Mutex(true)
}

private func group(_ kind: ToneKind, in groups: [ToneKindGroup]) -> ToneKindGroup? { groups.first { $0.kind == kind } }

@Suite("Apps found on this Mac are placed in a kind without an update")
struct DiscoveredAppsTests {
    private let mail = FakeMac.app("com.apple.mail", "Mail")
    private let notes = FakeMac.app("com.apple.Notes", "Notes", "productivity")

    // MARK: A sparse Mac and a crowded one

    @Test("a Mac with only Mail and Notes shows Email and Everything else, and nothing is invented")
    func sparse() {
        let mac = FakeMac(apps: [mail, notes])
        let onboarding = ToneKinds.groups(settings: .standard, installed: mac, includeEmpty: false)
        #expect(onboarding.map(\.kind) == [.email, .everythingElse])
        #expect(onboarding.flatMap(\.apps).map(\.name) == ["Mail", "Notes"])
        // Settings keeps the four kinds with a tone of their own; AI tools and code editors need an app.
        let settings = ToneKinds.groups(settings: .standard, installed: mac, includeEmpty: true)
        #expect(settings.map(\.kind) == [.workMessages, .email, .personalMessages, .everythingElse])
        #expect(group(.workMessages, in: settings)?.isEmpty == true && group(.personalMessages, in: settings)?.isEmpty == true)
    }

    @Test("a crowded Mac: unknown apps are placed only by a clear declaration; the rest are not guessed")
    func crowded() {
        let mac = FakeMac(apps: [
            mail, notes, FakeMac.app("com.tinyspeck.slackmacgap", "Slack", "business"),
            FakeMac.app("us.zoom.xos", "zoom.us", "business"),
            FakeMac.app("com.example.chatty", "Chatty", "social-networking"),
            FakeMac.app("com.example.jotter", "Jotter", "productivity"),
            FakeMac.app("com.example.ledger", "Ledger", "finance"),
            FakeMac.app("com.example.crm", "Pipeline", "business"),
            FakeMac.app("com.example.nocat", "No Category Tool"),
            FakeMac.app("com.example.postman", "Postman", "developer-tools"),
            FakeMac.app("com.example.game", "Some Game", "games"),
            FakeMac.app("com.google.Chrome", "Google Chrome", "productivity"),
            FakeMac.app("app.hushy.Hushy", "Hushy", "productivity"),
        ])
        let groups = ToneKinds.groups(settings: .standard, installed: mac, includeEmpty: false)
        let names = { (kind: ToneKind) -> [String] in group(kind, in: groups)?.apps.map(\.name) ?? [] }
        #expect(names(.workMessages) == ["Slack", "Zoom"])
        #expect(names(.personalMessages) == ["Chatty"])
        #expect(names(.everythingElse) == ["Notes", "Jotter", "Postman"])
        // Never offered: business, finance and games apps the table does not know, an app with no category,
        // a browser, and Hushy itself.
        let all = groups.flatMap(\.apps).map(\.name)
        for hidden in ["Ledger", "Pipeline", "No Category Tool", "Some Game", "Google Chrome", "Hushy"] { #expect(!all.contains(hidden), "\(hidden)") }
    }

    @Test("an app that cannot be placed shows under Everything else once the person used it or added it")
    func unplacedWhenUsedOrAdded() {
        let mac = FakeMac(apps: [mail, FakeMac.app("com.example.ledger", "Ledger", "finance"), FakeMac.app("com.example.crm", "Pipeline", "business")])
        #expect(group(.everythingElse, in: ToneKinds.groups(settings: .standard, installed: mac, includeEmpty: false)) == nil)
        let used = ToneKinds.groups(settings: .standard, installed: mac, usage: ["com.example.ledger": 120], includeEmpty: false)
        #expect(group(.everythingElse, in: used)?.apps.map(\.name) == ["Ledger"])
        let added = ToneKinds.groups(
            settings: ToneSettings.standard.settingApp(.tone(.casual), bundleIDs: ["com.example.crm"]), installed: mac, includeEmpty: false)
        #expect(group(.everythingElse, in: added)?.apps.map(\.name) == ["Pipeline"])
        #expect(group(.everythingElse, in: added)?.apps.first?.selected == .tone(.casual))
    }

    // MARK: Code tools found on the Mac never get a tone

    @Test("a terminal the table does not know is code when its name and its category agree: no menu, no tone")
    func unknownTerminal() {
        let apps = [
            FakeMac.app("com.example.zephyr", "Zephyr Terminal", "developer-tools"),
            FakeMac.app("com.example.shellpal", "Shell Pal"),
            FakeMac.app("com.example.ssh.connector", "Connector", "utilities"),
            FakeMac.app("com.example.MacVim2", "MacVim 2", "developer-tools"),
            FakeMac.app("com.google.android.studio.fake", "Android Studio Preview", "developer-tools"),
            FakeMac.app("org.rstudio.RStudio", "RStudio", "developer-tools"),
            FakeMac.app("com.example.blankterm", "Blankterm"),
        ]
        let stored = ToneSettings.standard.settingApp(.tone(.casual), bundleIDs: ["com.example.zephyr"])
        let groups = ToneKinds.groups(settings: stored, installed: FakeMac(apps: apps), includeEmpty: false)
        let code = group(.code, in: groups)
        #expect(code?.apps.map(\.name) == ["Android Studio Preview", "Blankterm", "Connector", "MacVim 2", "RStudio", "Shell Pal", "Zephyr Terminal"])
        #expect(code?.apps.allSatisfy { !$0.usesTone && $0.options.isEmpty && $0.selected == .useDefault } == true)
        #expect(group(.everythingElse, in: groups) == nil)
    }

    @Test("a name alone does not switch a prose app off: the declared category has to agree")
    func nameNeedsAgreement() {
        func kind(_ name: String, _ id: String, _ category: String?) -> ToneKind? {
            DeclaredAppCategory.kind(for: FakeMac.app(id, name, category))
        }
        // Prose and social apps with a code-sounding word keep their cleanup and tone.
        #expect(kind("Notes for Vim users", "com.example.vimnotes", "productivity") == .everythingElse)
        #expect(kind("Terminal Notes", "com.example.tnotes", "productivity") == .everythingElse)
        #expect(kind("Shell Chat", "com.example.shellchat", "social-networking") == .personalMessages)
        // Weak words need a known tool name and a declared developer tool.
        #expect(kind("Studio Display", "com.example.studiodisplay", "developer-tools") == .everythingElse)
        #expect(kind("Studio Display", "com.example.studiodisplay", nil) == nil)
        #expect(kind("IDEAS", "com.example.ideas", "developer-tools") == .everythingElse)
        #expect(kind("IDEAS", "com.example.ideas", "productivity") == .everythingElse)
        #expect(kind("Podcast Studio", "com.example.podcast", "productivity") == .everythingElse)
        // Real tools stay code.
        #expect(kind("Android Studio", "com.example.as", "developer-tools") == .code)
        #expect(kind("RStudio", "com.example.rs", "developer-tools") == .code)
        #expect(kind("Visual Studio", "com.example.vs", "developer-tools") == .code)
        #expect(kind("Xcode Beta", "com.example.xb", "developer-tools") == .code)
        #expect(kind("Arduino IDE", "cc.arduino", "developer-tools") == .code)
        // "term" alone is not a terminal; a name that ends in it (iTerm, xterm, WezTerm) is.
        #expect(kind("Long Term Planner", "com.example.longtermplanner", "utilities") == nil)
        #expect(kind("Long Term Planner", "com.example.longtermplanner", nil) == nil)
        #expect(kind("Term Sheet", "com.example.termsheet", "utilities") == nil)
        #expect(kind("Midterm Study", "com.example.midterm", nil) == nil)
        #expect(kind("iTerm", "com.example.iterm", nil) == .code)
        #expect(kind("xterm", "org.example.xterm", "utilities") == .code)
        #expect(kind("WezTerm", "com.example.wezterm", "developer-tools") == .code)
        #expect(kind("Blaze", "com.example.iterm2", nil) == .code)
        #expect(kind("Blaze Terminal", "com.example.blaze", nil) == .code)
        #expect(kind("Blaze Terminal", "com.example.blaze", "utilities") == .code)
        #expect(kind("Blaze Terminal", "com.example.blaze", "developer-tools") == .code)
    }

    @Test("when it is unclear that a developer tool is a code tool, it is Everything else")
    func unsureDeveloperTool() {
        let mac = FakeMac(apps: [FakeMac.app("com.example.postman", "Postman", "developer-tools"),
                                 FakeMac.app("com.example.docker", "Docker Desktop", "developer-tools"),
                                 FakeMac.app("com.example.display", "Studio Display", "developer-tools")])
        let groups = ToneKinds.groups(settings: .standard, installed: mac, includeEmpty: false)
        #expect(groups.map(\.kind) == [.everythingElse])
    }

    // MARK: Order

    @Test("apps the person dictates into most come first; a new install has a fixed order")
    func ordering() {
        let mac = FakeMac(apps: [
            FakeMac.app("com.tinyspeck.slackmacgap", "Slack"), FakeMac.app("com.microsoft.teams2", "Microsoft Teams"),
            FakeMac.app("us.zoom.xos", "zoom.us"), FakeMac.app("com.example.zeta", "Zeta", "social-networking"),
            FakeMac.app("com.example.alpha", "Alpha", "social-networking"),
        ])
        // New install: the table's order (Slack, Teams, Zoom), then the rest by name.
        let fresh = ToneKinds.groups(settings: .standard, installed: mac, includeEmpty: false)
        #expect(group(.workMessages, in: fresh)?.apps.map(\.name) == ["Slack", "Microsoft Teams", "Zoom"])
        #expect(group(.personalMessages, in: fresh)?.apps.map(\.name) == ["Alpha", "Zeta"])
        // After use: most words first, wherever the app comes from.
        let used = ToneKinds.groups(
            settings: .standard, installed: mac,
            usage: ["us.zoom.xos": 900, "com.microsoft.teams2": 300, "com.example.zeta": 50], includeEmpty: false)
        #expect(group(.workMessages, in: used)?.apps.map(\.name) == ["Zoom", "Microsoft Teams", "Slack"])
        #expect(group(.personalMessages, in: used)?.apps.map(\.name) == ["Zeta", "Alpha"])
    }

    // MARK: Install and uninstall between two reads

    @Test("a new app appears and an uninstalled one disappears; its saved tone comes back with it")
    func installAndUninstall() {
        let chatty = FakeMac.app("com.example.chatty", "Chatty", "social-networking")
        let writer = FakeMac.app("com.example.writer", "Writer", "productivity")
        let saved = ToneSettings.standard.settingApp(.tone(.professional), bundleIDs: ["com.example.writer"])
        let before = ToneKinds.groups(settings: saved, installed: FakeMac(apps: [mail, writer]), includeEmpty: false)
        #expect(group(.everythingElse, in: before)?.apps.map(\.name) == ["Writer"])
        #expect(group(.personalMessages, in: before) == nil)

        let after = ToneKinds.groups(settings: saved, installed: FakeMac(apps: [mail, chatty]), includeEmpty: false)
        #expect(group(.personalMessages, in: after)?.apps.map(\.name) == ["Chatty"])
        #expect(group(.everythingElse, in: after) == nil)   // uninstalled: gone from the list
        #expect(saved.appTone(for: "com.example.writer") == .professional)   // but the saved tone is kept

        let back = ToneKinds.groups(settings: saved, installed: FakeMac(apps: [mail, writer]), includeEmpty: false)
        #expect(group(.everythingElse, in: back)?.apps.first?.selected == .tone(.professional))
    }

    // MARK: What each declared category maps to

    @Test("the declared-category mapping is exactly the documented one")
    func mapping() {
        let expected: [(String, ToneKind?)] = [
            ("social-networking", .personalMessages), ("productivity", .everythingElse), ("developer-tools", .everythingElse),
            ("utilities", nil),
            ("business", nil), ("finance", nil), ("games", nil), ("graphics-design", nil), ("music", nil),
            ("video", nil), ("photography", nil), ("education", nil), ("news", nil), ("entertainment", nil), ("lifestyle", nil),
            ("medical", nil), ("reference", nil), ("books", nil), ("travel", nil), ("weather", nil), ("sports", nil),
        ]
        for (category, kind) in expected {
            #expect(DeclaredAppCategory.kind(for: FakeMac.app("com.example.app", "Some App", category)) == kind, "\(category)")
        }
        #expect(DeclaredAppCategory.kind(for: FakeMac.app("com.example.app", "Some App")) == nil)
    }
}

@Suite("The classifier follows what was found on this Mac", .serialized)
struct DiscoveredAppKindsTests {
    @Test("a terminal and a social app that the table does not know are classified once found; nothing else changes")
    func registry() {
        DiscoveredAppKinds.reset()
        defer { DiscoveredAppKinds.reset() }
        #expect(AppCategory.classify(bundleID: "com.example.zephyr") == .other)
        DiscoveredAppKinds.replace(with: [
            FakeMac.app("com.example.zephyr", "Zephyr Terminal", "developer-tools"),
            FakeMac.app("com.example.chatty", "Chatty", "social-networking"),
            FakeMac.app("com.example.jotter", "Jotter", "productivity"),
            FakeMac.app("com.example.vimnotes", "Notes for Vim users", "productivity"),
            FakeMac.app("com.google.Chrome", "Chrome", "developer-tools"),
        ])
        #expect(AppCategory.classify(bundleID: "com.example.zephyr") == .code)
        #expect(AppCategory.classify(bundleID: "com.example.Chatty") == .personalMessages)
        #expect(AppCategory.classify(bundleID: "com.example.jotter") == .other)
        #expect(AppCategory.classify(bundleID: "com.example.vimnotes") == .other)
        // A browser is never code, and an app the table knows keeps the table's answer.
        #expect(AppCategory.classify(bundleID: "com.google.Chrome") == .other)
        #expect(AppCategory.classify(bundleID: "com.apple.mail") == .email)
        // A dictation into the dynamically found terminal gets no tone, like any known terminal.
        let stored = ToneSettings.standard.settingApp(.tone(.casual), bundleIDs: ["com.example.zephyr"])
        let plan = stored.plan(for: AppCategory.classify(bundleID: "com.example.zephyr"), bundleID: "com.example.zephyr")
        #expect(plan.tone == nil && plan.level == .polished)
        DiscoveredAppKinds.reset()
        #expect(AppCategory.classify(bundleID: "com.example.zephyr") == .other)
    }

    @Test("an app that has just started running is added without a new look")
    func addOne() {
        DiscoveredAppKinds.reset()
        defer { DiscoveredAppKinds.reset() }
        DiscoveredAppKinds.add(FakeMac.app("com.example.blazeterm", "Blazeterm", nil))
        #expect(AppCategory.classify(bundleID: "com.example.blazeterm") == .code)
    }

    @Test("until the read of a just-started app ends, the classifier gives it no tone; a failed read clears that")
    func pendingIsSafe() {
        DiscoveredAppKinds.reset()
        defer { DiscoveredAppKinds.reset() }
        DiscoveredAppKinds.markPending(bundleID: "com.example.NewThing")
        #expect(AppCategory.classify(bundleID: "com.example.newthing") == .code)
        let plan = ToneSettings.standard.plan(for: AppCategory.classify(bundleID: "com.example.newthing"), bundleID: "com.example.newthing")
        #expect(plan.tone == nil)
        DiscoveredAppKinds.finishPending(bundleID: "com.example.NewThing")
        #expect(AppCategory.classify(bundleID: "com.example.newthing") == .other)
        // An app the table or the last look has already decided is not made pending.
        DiscoveredAppKinds.replace(with: [FakeMac.app("com.example.jotter", "Jotter", "productivity")])
        DiscoveredAppKinds.markPending(bundleID: "com.example.jotter")
        #expect(AppCategory.classify(bundleID: "com.example.jotter") == .other)
        DiscoveredAppKinds.markPending(bundleID: "com.apple.mail")
        #expect(AppCategory.classify(bundleID: "com.apple.mail") == .email)
    }
}

/// The same serialized suite as above: both touch the one in-memory registry the classifier reads.
extension DiscoveredAppKindsTests {
    @Test("a code editor that launches during a look is still code after the look is published")
    func launchDuringLook() async {
        DiscoveredAppKinds.reset()
        defer { DiscoveredAppKinds.reset() }
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let editor = FakeMac.app("com.example.outsidefolders", "Outside Editor Shell", "developer-tools")
        let catalog = InstalledAppCatalog(
            scan: {
                started.signal()
                release.wait()
                // The look read the folders before the editor existed: it does not list it.
                return [FakeMac.app("com.example.chatty", "Chatty", "social-networking")]
            },
            read: { _ in editor })
        let look = Task { await catalog.refresh() }
        block(started)
        // The editor starts while the look is still running; its read finishes.
        await catalog.noteLaunched(bundleID: editor.bundleID, at: URL(fileURLWithPath: "/tmp/x.app")).value
        #expect(AppCategory.classify(bundleID: "com.example.outsidefolders") == .code)
        release.signal()
        _ = await look.value
        #expect(AppCategory.classify(bundleID: "com.example.outsidefolders") == .code)
        #expect(AppCategory.classify(bundleID: "com.example.chatty") == .personalMessages)
        #expect(Set(catalog.snapshot().map(\.bundleID)) == ["com.example.chatty", "com.example.outsidefolders"])
        // A later look that lists it too does not duplicate it.
        #expect(catalog.snapshot().count == 2)
    }

    @Test("the read of a launched app does not run on the caller: the classifier answers no tone while it is pending")
    func pendingWhileReading() async {
        DiscoveredAppKinds.reset()
        defer { DiscoveredAppKinds.reset() }
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let catalog = InstalledAppCatalog(
            scan: { [] },
            read: { _ in
                started.signal()
                release.wait()
                return FakeMac.app("com.example.writerapp", "Writer App", "productivity")
            })
        let task = catalog.noteLaunched(bundleID: "com.example.writerapp", at: URL(fileURLWithPath: "/tmp/w.app"))
        block(started)
        // The caller came back at once; the read is still running. A dictation now gets no tone.
        #expect(AppCategory.classify(bundleID: "com.example.writerapp") == .code)
        release.signal()
        await task.value
        #expect(AppCategory.classify(bundleID: "com.example.writerapp") == .other)
    }

    @Test("two launches of one unknown app: the first read failing does not clear the pending answer of the second")
    func twoPendingReads() async {
        DiscoveredAppKinds.reset()
        defer { DiscoveredAppKinds.reset() }
        let calls = Counter()
        let firstStarted = DispatchSemaphore(value: 0), firstRelease = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0), secondRelease = DispatchSemaphore(value: 0)
        let catalog = InstalledAppCatalog(scan: { [] }, read: { _ in
            let call = calls.value.withLock { $0 += 1; return $0 }
            if call == 1 {
                firstStarted.signal(); firstRelease.wait()
                return nil   // the first read fails
            }
            secondStarted.signal(); secondRelease.wait()
            return FakeMac.app("com.example.twice", "Twice", "developer-tools")
        })
        let url = URL(fileURLWithPath: "/tmp/twice.app")
        let first = catalog.noteLaunched(bundleID: "com.example.twice", at: url)
        block(firstStarted)
        let second = catalog.noteLaunched(bundleID: "com.example.twice", at: url)
        block(secondStarted)
        // The first read now fails while the second is still running.
        firstRelease.signal()
        await first.value
        #expect(AppCategory.classify(bundleID: "com.example.twice") == .code)
        // The second returns: a developer tool whose name says nothing is an ordinary app.
        secondRelease.signal()
        await second.value
        #expect(AppCategory.classify(bundleID: "com.example.twice") == .other)
    }

    @Test("when the last of two reads fails too, the app is ordinary again")
    func lastReadFails() async {
        DiscoveredAppKinds.reset()
        defer { DiscoveredAppKinds.reset() }
        let catalog = InstalledAppCatalog(scan: { [] }, read: { _ in nil })
        let url = URL(fileURLWithPath: "/tmp/gone.app")
        DiscoveredAppKinds.markPending(bundleID: "com.example.gone")
        let task = catalog.noteLaunched(bundleID: "com.example.gone", at: url)
        await task.value
        #expect(AppCategory.classify(bundleID: "com.example.gone") == .code)   // one read still counted
        DiscoveredAppKinds.finishPending(bundleID: "com.example.gone")
        #expect(AppCategory.classify(bundleID: "com.example.gone") == .other)
    }

    @Test("an app launched from outside the scanned folders and later deleted is dropped by the next look")
    func prunesDeletedLaunchedApps() async {
        DiscoveredAppKinds.reset()
        defer { DiscoveredAppKinds.reset() }
        let present = Flag()
        let editor = FakeMac.app("com.example.dmgterminal", "DMG Terminal", "developer-tools")
        let catalog = InstalledAppCatalog(scan: { [] }, read: { _ in editor }, exists: { _ in present.value.withLock { $0 } })
        let start = Date()
        _ = await catalog.refresh(now: { start })
        await catalog.noteLaunched(bundleID: editor.bundleID, at: URL(fileURLWithPath: "/Volumes/Disk/DMG Terminal.app")).value
        #expect(AppCategory.classify(bundleID: "com.example.dmgterminal") == .code)
        #expect(catalog.snapshot().map(\.bundleID) == ["com.example.dmgterminal"])
        // Still there at the next look: kept.
        _ = await catalog.refresh(now: { start.addingTimeInterval(61) })
        #expect(AppCategory.classify(bundleID: "com.example.dmgterminal") == .code)
        // Deleted, and the look after that drops it. Its saved tone is in the setting, not here.
        present.value.withLock { $0 = false }
        _ = await catalog.refresh(now: { start.addingTimeInterval(130) })
        #expect(AppCategory.classify(bundleID: "com.example.dmgterminal") == .other)
        #expect(catalog.snapshot().isEmpty)
    }

    @Test("a read that finds nothing leaves an ordinary app, not a stuck one")
    func failedRead() async {
        DiscoveredAppKinds.reset()
        defer { DiscoveredAppKinds.reset() }
        let catalog = InstalledAppCatalog(scan: { [] }, read: { _ in nil })
        await catalog.noteLaunched(bundleID: "com.example.nothing", at: URL(fileURLWithPath: "/tmp/n.app")).value
        #expect(AppCategory.classify(bundleID: "com.example.nothing") == .other)
    }

    @Test("a look is not repeated within a minute")
    func lookThrottle() async {
        let counter = Counter()
        let catalog = InstalledAppCatalog(scan: { counter.value.withLock { $0 += 1 }; return [] })
        let start = Date()
        _ = await catalog.refresh(now: { start })
        _ = await catalog.refresh(now: { start.addingTimeInterval(30) })
        #expect(counter.value.withLock { $0 } == 1)
        _ = await catalog.refresh(now: { start.addingTimeInterval(61) })
        #expect(counter.value.withLock { $0 } == 2)
        DiscoveredAppKinds.reset()
    }
}

@Suite("Reading the installed apps' own Info.plist files")
struct InstalledAppScannerTests {
    private func makeApp(_ name: String, in folder: URL, plist: [String: Any]) throws {
        let contents = folder.appendingPathComponent("\(name).app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    @Test("reads the name, identifier and declared category; skips background-only apps; finds one folder level down")
    func scan() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let utilities = root.appendingPathComponent("Utilities")
        try FileManager.default.createDirectory(at: utilities, withIntermediateDirectories: true)
        try makeApp("Chatty", in: root, plist: [
            "CFBundleIdentifier": "com.example.chatty", "CFBundleName": "Chatty",
            "LSApplicationCategoryType": "public.app-category.social-networking"])
        try makeApp("Helper", in: root, plist: ["CFBundleIdentifier": "com.example.helper", "LSBackgroundOnly": true])
        try makeApp("NoName", in: utilities, plist: ["CFBundleIdentifier": "com.example.noname"])
        try makeApp("Broken", in: root, plist: ["CFBundleName": "Broken"])
        try makeApp("Twin", in: utilities, plist: ["CFBundleIdentifier": "com.example.chatty", "CFBundleName": "Twin"])

        let apps = InstalledAppScanner.scan(roots: [root, root.appendingPathComponent("missing")])
        #expect(apps.map(\.bundleID).sorted() == ["com.example.chatty", "com.example.noname"])
        let chatty = try #require(apps.first { $0.bundleID == "com.example.chatty" })
        #expect(chatty.name == "Chatty" && chatty.declaredCategory == "public.app-category.social-networking")
        #expect(apps.first { $0.bundleID == "com.example.noname" }?.name == "NoName")
    }

    @Test("a plist larger than the cap is not read, and the entries and sub-folders opened are bounded")
    func caps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeApp("Small", in: root, plist: ["CFBundleIdentifier": "com.example.small"])
        try makeApp("Huge", in: root, plist: [
            "CFBundleIdentifier": "com.example.huge", "Padding": String(repeating: "x", count: InstalledAppScanner.maxPlistBytes + 10)])
        #expect(InstalledAppScanner.scan(roots: [root]).map(\.bundleID) == ["com.example.small"])

        let crowded = root.appendingPathComponent("crowded")
        try FileManager.default.createDirectory(at: crowded, withIntermediateDirectories: true)
        for index in 0..<10 { try makeApp("App\(index)", in: crowded, plist: ["CFBundleIdentifier": "com.example.app\(index)"]) }
        #expect(InstalledAppScanner.scan(roots: [crowded], maxEntries: 4).count == 4)
        #expect(InstalledAppScanner.scan(roots: [crowded]).count == 10)

        let outer = root.appendingPathComponent("outer")
        for index in 0..<5 {
            let folder = outer.appendingPathComponent("Folder\(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try makeApp("Inner", in: folder, plist: ["CFBundleIdentifier": "com.example.inner\(index)"])
        }
        #expect(InstalledAppScanner.scan(roots: [outer], maxFolders: 2).count == 2)
        #expect(InstalledAppScanner.maxPlistBytes == 524_288 && InstalledAppScanner.maxEntriesPerFolder == 2_000
            && InstalledAppScanner.maxSubfolders == 40)
    }
}

@Suite("Meeting apps are work")
struct MeetingAppsAreWorkTests {
    @Test("Zoom and Webex apps classify as Work messages, ahead of the email needle in Webex's identifier")
    func apps() {
        for id in ["us.zoom.xos", "Cisco-Systems.Spark", "com.webex.meetingmanager", "com.cisco.webexmeetingsapp"] {
            #expect(AppCategory.classify(bundleID: id) == .workMessages, "\(id)")
            #expect(ToneKind.kind(forBundleID: id) == .workMessages, "\(id)")
        }
        #expect(AppCategory.classify(bundleID: "com.readdle.SparkDesktop") == .email)
    }

    @Test("a call in a tab is Work messages: the real tab titles of a Meet call, a Zoom web client call and a Webex call")
    func callTabs() {
        for title in ["Meet - abc-defg-hij - Google Chrome", "Meet – abc-defg-hij", "Meet - abc-defg-hij - Mozilla Firefox",
                      "Google Meet - Google Chrome", "Meet",
                      "Zoom Meeting - Google Chrome", "Zoom Workplace", "Launch Meeting - Zoom - Google Chrome",
                      "Join Meeting - Zoom",
                      "Webex - Google Chrome", "Webex Meetings", "Cisco Webex Meetings - Safari"] {
            #expect(AppCategory.classify(bundleID: "com.google.Chrome", windowTitle: title) == .workMessages, "\(title)")
        }
    }

    @Test("a document, note or page about a meeting is not a call: documents win, and anything unclear is Everything else")
    func notCalls() {
        let documents = ["Google Meet notes - Google Docs", "Zoom Meeting agenda - Notion", "Webex rollout plan - Confluence"]
        for title in documents {
            #expect(AppCategory.classify(bundleID: "com.google.Chrome", windowTitle: title + " - Google Chrome") == .documents, "\(title)")
        }
        let others = ["Zoom Meeting camera review - Example.com", "Meet - project notes - Google Chrome",
                      "Team meet - agenda - Google Chrome", "How to meet people - Google Chrome", "Zoom lens review - Google Chrome",
                      "Meet the team - Example Co", "Webex pricing - Cisco", "Meet - Weekly sync notes"]
        for title in others {
            #expect(AppCategory.classify(bundleID: "com.google.Chrome", windowTitle: title) == .other, "\(title)")
        }
        // A Gmail tab still wins over the word "meet" in a subject line.
        #expect(AppCategory.classify(bundleID: "com.google.Chrome", windowTitle: "Meet tomorrow? - you@gmail.com - Gmail") == .email)
    }
}
