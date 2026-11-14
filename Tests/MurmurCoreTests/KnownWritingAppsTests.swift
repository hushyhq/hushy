import Foundation
import Testing

@testable import MurmurCore

private struct FakeApps: InstalledApps {
    let ids: Set<String>
    func isInstalled(_ bundleID: String) -> Bool { ids.contains(bundleID) }
    func displayName(_ bundleID: String) -> String? { ids.contains(bundleID) ? bundleID : nil }
}

@Suite("Kinds of apps, known apps and the per-app tone list")
struct KnownWritingAppsTests {
    private let everything = FakeApps(ids: Set(KnownWritingApps.all.flatMap(\.bundleIDs)))
    private let mixed = FakeApps(ids: [
        "com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.apple.mail", "com.microsoft.Outlook",
        "net.whatsapp.WhatsApp", "com.apple.MobileSMS", "com.anthropic.claudefordesktop", "notion.id",
        "com.todesktop.230313mzl4w4u92", "com.apple.Terminal",
    ])

    private func group(_ kind: ToneKind, in groups: [ToneKindGroup]) throws -> ToneKindGroup {
        try #require(groups.first { $0.kind == kind })
    }

    // MARK: The table

    @Test("the table has unique identifiers, and every app's kind matches how dictation in it is classified")
    func table() {
        let ids = KnownWritingApps.all.flatMap(\.bundleIDs)
        #expect(Set(ids).count == ids.count)
        for app in KnownWritingApps.all {
            let classified = AppToneRow.row(for: app, in: .standard)
            #expect(ToneKind.kind(forBundleID: app.id) == app.toneKind, "\(app.name)")
            switch app.kind {
            case .writing:
                #expect(app.context != nil, "\(app.name)")
                #expect(AppCategory.classify(bundleID: app.id) != .code, "\(app.name)")
                #expect(classified.usesTone, "\(app.name)")
            case .ai:
                #expect(app.toneKind == .aiTools && AppCategory.classify(bundleID: app.id) == .aiPrompts, "\(app.name)")
            case .aiEditor, .code:
                #expect(app.toneKind == .code && AppCategory.classify(bundleID: app.id) == .code, "\(app.name)")
                #expect(!classified.usesTone, "\(app.name)")
            }
        }
    }

    @Test("only installed apps are found; with nothing installed there are none")
    func detection() {
        #expect(KnownWritingApps.allInstalled(using: FakeApps(ids: [])).isEmpty)
        let some = FakeApps(ids: ["com.tinyspeck.slackmacgap", "com.microsoft.teams", "com.example.unknown"])
        #expect(KnownWritingApps.allInstalled(using: some).map(\.name) == ["Slack", "Microsoft Teams"])
    }

    // MARK: Kinds

    @Test("apps are grouped by kind, in a fixed order, and a kind with nothing installed is left out in onboarding")
    func grouping() throws {
        let groups = ToneKinds.groups(settings: .standard, installed: mixed, includeEmpty: false)
        #expect(groups.map(\.kind) == [.workMessages, .email, .personalMessages, .aiTools, .everythingElse, .code])
        #expect(try group(.workMessages, in: groups).apps.map(\.name) == ["Slack", "Microsoft Teams"])
        #expect(try group(.email, in: groups).apps.map(\.name) == ["Mail", "Outlook"])
        #expect(try group(.personalMessages, in: groups).apps.map(\.name) == ["Messages", "WhatsApp"])
        #expect(try group(.aiTools, in: groups).apps.map(\.name) == ["Claude"])
        #expect(try group(.everythingElse, in: groups).apps.map(\.name) == ["Notion"])
        #expect(try group(.code, in: groups).apps.map(\.name) == ["Cursor", "Terminal"])
        let few = ToneKinds.groups(settings: .standard, installed: FakeApps(ids: ["com.apple.mail"]), includeEmpty: false)
        #expect(few.map(\.kind) == [.email])
        #expect(ToneKinds.groups(settings: .standard, installed: FakeApps(ids: []), includeEmpty: false).isEmpty)
    }

    @Test("Settings keeps the four kinds that have a tone of their own, so a kind with no apps can still be given a tone")
    func emptyKindsInSettings() throws {
        let groups = ToneKinds.groups(settings: .standard, installed: FakeApps(ids: []), includeEmpty: true)
        // AI tools and code editors have no tone to give, so they show only when there is an app in them.
        #expect(groups.map(\.kind) == [.workMessages, .email, .personalMessages, .everythingElse])
        #expect(groups.allSatisfy { $0.isEmpty })
        #expect(try group(.workMessages, in: groups).options.count == 4)
    }

    @Test("a kind with many apps can be capped, and the rest are counted")
    func cap() throws {
        let groups = ToneKinds.groups(settings: .standard, installed: everything, includeEmpty: false, limit: 2)
        let personal = try group(.personalMessages, in: groups)
        #expect(personal.apps.count == 2)
        #expect(personal.hiddenCount == 3)
        #expect(ToneCopy.moreApps(personal.hiddenCount) == "and 3 more")
        #expect(try group(.workMessages, in: ToneKinds.groups(settings: .standard, installed: everything, includeEmpty: false)).hiddenCount == 0)
    }

    @Test("every kind starts on the default; Email starts on Professional and says so")
    func startsOnDefault() throws {
        let groups = ToneKinds.groups(settings: .standard, installed: mixed, includeEmpty: false)
        for kind in [ToneKind.workMessages, .personalMessages, .everythingElse] {
            let item = try group(kind, in: groups)
            #expect(item.selected == .useDefault && item.tone == .refined, "\(kind)")
            #expect(item.options.first?.title == "Default (Refined)", "\(kind)")
        }
        let email = try group(.email, in: groups)
        #expect(email.selected == .useDefault && email.tone == .professional)
        #expect(email.options.first?.title == "Default (Professional)")
        #expect(email.note == "Here, Hushy starts on Professional.")
        // The menu says what a plain kind uses, so there is no line for it; an earlier layout still gets one.
        #expect(try group(.workMessages, in: groups).note == nil)
        let earlier = ToneSettings.migrated(from: .init(cleanupLevel: nil, styles: ["workMessages": "excited"], isExistingInstall: true))
        #expect(try group(.workMessages, in: ToneKinds.groups(settings: earlier, installed: mixed, includeEmpty: false)).note
                == "Still using your earlier “Excited!” layout here. Pick a tone to replace it.")
        // Apps in the kind start on Default and follow the kind.
        #expect(email.apps.allSatisfy { $0.selected == .useDefault && $0.defaultTone == .professional })
    }

    @Test("a tone for a whole kind is the main move: every app in it follows, and Default goes back to where it starts")
    func kindTone() throws {
        var settings = ToneKinds.applying(.tone(.casual), to: .workMessages, in: .standard)
        var groups = ToneKinds.groups(settings: settings, installed: mixed, includeEmpty: false)
        let work = try group(.workMessages, in: groups)
        #expect(work.selected == .tone(.casual) && work.apps.allSatisfy { $0.defaultTone == .casual })
        #expect(settings.plan(for: .workMessages, bundleID: "com.microsoft.teams2").tone == .casual)
        // Email's Default is Professional, not the overall default.
        settings = ToneKinds.applying(.tone(.casual), to: .email, in: settings)
        settings = ToneKinds.applying(.useDefault, to: .email, in: settings)
        #expect(settings.tone(for: .email) == .professional)
        settings = ToneKinds.applying(.useDefault, to: .workMessages, in: settings)
        groups = ToneKinds.groups(settings: settings, installed: mixed, includeEmpty: false)
        #expect(try group(.workMessages, in: groups).selected == .useDefault)
        #expect(settings == .standard)
        // The overall default moves every kind still on Default, and none that was chosen.
        var moved = ToneKinds.applying(.tone(.casual), to: .personalMessages, in: .standard)
        moved.choice = .professional
        #expect(moved.tone(for: .workMessages) == .professional && moved.tone(for: .personalMessages) == .casual)
    }

    @Test("one app inside a kind can differ, and it wins over the kind")
    func appInsideAKind() throws {
        var settings = ToneKinds.applying(.tone(.professional), to: .workMessages, in: .standard)
        let slack = try #require(KnownWritingApps.app(forBundleID: "com.tinyspeck.slackmacgap"))
        settings = AppToneRow.applying(.tone(.casual), to: AppToneRow.row(for: slack, in: settings), in: settings)
        let groups = ToneKinds.groups(settings: settings, installed: mixed, includeEmpty: false)
        let apps = try group(.workMessages, in: groups).apps
        #expect(apps.first { $0.name == "Slack" }?.selected == .tone(.casual))
        #expect(apps.first { $0.name == "Microsoft Teams" }?.selected == .useDefault)
        #expect(settings.plan(for: .workMessages, bundleID: "com.tinyspeck.slackmacgap").tone == .casual)
        #expect(settings.plan(for: .workMessages, bundleID: "com.microsoft.teams2").tone == .professional)
    }

    // MARK: AI tools and code

    @Test("AI tools are their own kind: no tone of their own, Prompt is coming, and the apps still take a tone")
    func aiTools() throws {
        let groups = ToneKinds.groups(settings: .standard, installed: mixed, includeEmpty: false)
        let ai = try group(.aiTools, in: groups)
        #expect(ai.showsPromptComing && ai.options.isEmpty && !ToneKind.aiTools.hasOwnTone)
        #expect(ai.note == "Uses your Everything else tone, Refined, for now.")
        // Nothing can be set for the kind, and no Prompt is selectable.
        #expect(ToneKinds.applying(.tone(.casual), to: .aiTools, in: .standard) == .standard)
        #expect(ToneKinds.applying(.prompt, to: .workMessages, in: .standard) == .standard)
        let claude = try #require(ai.apps.first)
        let prompt = try #require(claude.options.first { $0.value == .prompt })
        #expect(prompt.title == "Prompt" && prompt.badge == "Coming" && !prompt.isSelectable)
        #expect(AppToneRow.applying(.prompt, to: claude, in: .standard) == .standard)
        // The AI apps follow Everything else, so a change there is shown.
        let changed = ToneKinds.applying(.tone(.casual), to: .everythingElse, in: .standard)
        #expect(try group(.aiTools, in: ToneKinds.groups(settings: changed, installed: mixed, includeEmpty: false)).note
                == "Uses your Everything else tone, Casual, for now.")
        #expect(changed.plan(for: AppCategory.classify(bundleID: claude.id), bundleID: claude.id).tone == .casual)
        // An app can still be given its own tone.
        let own = AppToneRow.applying(.tone(.professional), to: claude, in: .standard)
        #expect(own.plan(for: .aiPrompts, bundleID: claude.id).tone == .professional)
    }

    @Test("code editors and terminals show no menu and no tone, and an AI editor still shows Prompt as coming")
    func codeKind() throws {
        let code = try group(.code, in: ToneKinds.groups(settings: .standard, installed: mixed, includeEmpty: false))
        #expect(code.options.isEmpty && code.tone == nil && !ToneKind.code.hasOwnTone)
        #expect(code.note == ToneCopy.codeKindNote)
        let cursor = try #require(code.apps.first { $0.name == "Cursor" })
        let terminal = try #require(code.apps.first { $0.name == "Terminal" })
        for row in [cursor, terminal] {
            #expect(!row.usesTone && row.options.isEmpty && row.defaultTitle == "No tone (code)" && row.defaultNote == nil)
        }
        #expect(cursor.isAI && !terminal.isAI)
        #expect(ToneKinds.applying(.tone(.casual), to: .code, in: .standard) == .standard)
        #expect(AppToneRow.applying(.tone(.casual), to: cursor, in: .standard) == .standard)
        for row in code.apps {
            #expect(ToneSettings.standard.plan(for: .code, bundleID: row.id).tone == nil)
        }
    }

    // MARK: Hand-added apps and the old per-app list

    @Test("a hand-added app appears in its chosen kind without acquiring a tone override")
    func customApp() throws {
        let settings = ToneSettings.standard.addingApp("com.example.writer", to: .everythingElse)
        let groups = ToneKinds.groups(settings: settings, installed: FakeApps(ids: ["com.example.writer"]), includeEmpty: false)
        #expect(try group(.everythingElse, in: groups).apps.map(\.id) == ["com.example.writer"])
        #expect(settings.appChoices.isEmpty)
        let row = AppToneRow.customRow(bundleID: "com.example.writer", name: "Writer", in: .standard)
        #expect(row.selected == .useDefault && row.defaultTitle == "Default (Refined)")
        #expect(row.options.map(\.id) == ["default", "refined", "casual", "professional"])
        #expect(ToneKind.kind(forBundleID: "com.example.writer") == .everythingElse)
        #expect(ToneKind.kind(forBundleID: "com.example.chatgpt") == .aiTools)
    }

    @Test("a hand-added code editor or terminal gets no menu, no tone badge and no stored tone, even if one was stored")
    func customCodeApp() throws {
        // A stored tone for it (an old setting, or an edited file) must not show: the plan applies none there.
        let stored = ToneSettings.standard.settingApp(.tone(.casual), bundleIDs: ["org.alacritty"])
        let row = AppToneRow.customRow(bundleID: "org.alacritty", name: "Alacritty", in: stored)
        #expect(!row.usesTone && row.options.isEmpty && row.selected == .useDefault)
        #expect(row.defaultTitle == "No tone (code)" && row.defaultNote == nil && !row.isAI)
        #expect(AppToneRow.applying(.tone(.casual), to: row, in: .standard) == .standard)
        #expect(stored.plan(for: AppCategory.classify(bundleID: "org.alacritty"), bundleID: "org.alacritty").tone == nil)
        let groups = ToneKinds.groups(settings: stored, installed: FakeApps(ids: ["org.alacritty"]), includeEmpty: false)
        let code = try group(.code, in: groups)
        #expect(code.apps.map(\.id) == ["org.alacritty"])
        #expect(code.apps.allSatisfy { !$0.usesTone && $0.options.isEmpty && $0.selected == .useDefault })
        // A browser typed in by hand is not a code app and is not treated as one.
        #expect(AppToneRow.customRow(bundleID: "com.google.Chrome", name: "Chrome", in: .standard).usesTone)
    }

    @Test("picking a tone for an app sets every identifier of the app, and Default clears it")
    func picking() throws {
        let teams = AppToneRow.row(for: try #require(KnownWritingApps.app(forBundleID: "com.microsoft.teams2")), in: .standard)
        let set = AppToneRow.applying(.tone(.casual), to: teams, in: .standard)
        #expect(set.plan(for: .workMessages, bundleID: "com.microsoft.teams").tone == .casual)
        #expect(set.plan(for: .workMessages, bundleID: "com.microsoft.teams2").tone == .casual)
        let again = AppToneRow.row(for: try #require(KnownWritingApps.app(forBundleID: "com.microsoft.teams")), in: set)
        #expect(again.selected == .tone(.casual))
        #expect(AppToneRow.applying(.useDefault, to: again, in: set).appChoices.isEmpty)
    }

    @Test("a known app moves with every identifier and remains in the chosen group")
    func movingKnownApp() throws {
        let ids = ["com.microsoft.teams2", "com.microsoft.teams"]
        let settings = ToneSettings.standard.movingApp(to: .email, bundleIDs: ids)
        let groups = ToneKinds.groups(settings: settings, installed: mixed, includeEmpty: false)
        let email = try group(.email, in: groups)
        #expect(email.apps.contains { $0.name == "Microsoft Teams" && $0.defaultTone == .professional })
        #expect(try !group(.workMessages, in: groups).apps.contains { $0.name == "Microsoft Teams" })
        #expect(settings.plan(for: .workMessages, bundleID: ids[0]).tone == .professional)
        let reset = settings.movingApp(to: nil, bundleIDs: ids)
        #expect(reset.kind(for: ids[0]) == .workMessages)
    }

    @Test("an email app with no choice of its own follows Email and says so; a personal chat app says Casual only if Personal does")
    func appNotes() throws {
        let mail = AppToneRow.row(for: try #require(KnownWritingApps.app(forBundleID: "com.apple.mail")), in: .standard)
        #expect(mail.defaultTitle == "Default (Professional)" && mail.defaultNote == "Professional, from Email")
        let existing = ToneSettings.migrated(from: .init(cleanupLevel: nil, styles: [:], isExistingInstall: true))
        let whatsapp = AppToneRow.row(for: try #require(KnownWritingApps.app(forBundleID: "net.whatsapp.WhatsApp")), in: existing)
        #expect(whatsapp.defaultTitle == "Default (Casual)" && whatsapp.defaultNote == "Casual, from Personal messages")
    }

    @Test("only the local tone setting carries an app identifier; no copy does")
    func privacyShape() {
        let settings = ToneSettings.standard.settingApp(.tone(.casual), bundleIDs: ["com.example.writer"])
        #expect(settings.fingerprint.contains("com.example.writer"))
        let groups = ToneKinds.groups(settings: settings, installed: FakeApps(ids: []), includeEmpty: true)
        #expect(groups.compactMap(\.note).allSatisfy { !$0.contains("com.example") })
    }
}
