import Foundation
import Testing

@testable import MurmurCore

@Suite("Tone setting")
struct ToneSettingsTests {
    // MARK: Default and resolution

    @Test("the default is Refined everywhere except email, which starts on Professional; cleanup is on")
    func defaultIsRefined() {
        let settings = ToneSettings.standard
        #expect(!settings.isAsSpoken)
        #expect(settings.choice == .refined)
        for context in StyleContext.allCases {
            #expect(settings.tone(for: context) == (context == .email ? .professional : .refined), "\(context)")
            #expect(settings.layout(for: context) == .formal)
            #expect(settings.hasOverride(for: context) == (context == .email))
        }
        #expect(settings.isShippedTone(for: .email))
        #expect(!settings.isShippedTone(for: .other))
        #expect(settings.appChoices.isEmpty)
    }

    @Test("a tone is the cleanup pass plus the tone: every kind of app gets the model level and its tone")
    func planForEachCategory() {
        for category in AppCategory.allCases where category != .code {
            let plan = ToneSettings.standard.plan(for: category)
            #expect(plan.level == .polished, "\(category)")
            #expect(plan.tone == (StyleContext.from(category) == .email ? .professional : .refined))
            #expect(plan.style?.context == StyleContext.from(category))
        }
    }

    @Test("an app's own tone wins over its kind of app, which wins over the default")
    func precedence() {
        var settings = ToneSettings.standard
        settings.choice = .casual
        settings = settings.settingTone(.professional, for: .workMessages)
        let slack = "com.tinyspeck.slackmacgap"
        // Default, then the kind of app, then the app.
        #expect(settings.plan(for: .other, bundleID: "com.example.notes").tone == .casual)
        #expect(settings.plan(for: .workMessages, bundleID: slack).tone == .professional)
        settings = settings.settingApp(.tone(.refined), bundleIDs: [slack])
        #expect(settings.plan(for: .workMessages, bundleID: slack).tone == .refined)
        #expect(settings.plan(for: .workMessages, bundleID: slack).layout == .formal)
        #expect(settings.plan(for: .workMessages, bundleID: "com.microsoft.teams2").tone == .professional)
        // The app's tone brings its own layout, even where a layout from before was kept.
        let earlier = ToneSettings.Earlier(cleanupLevel: nil, styles: ["personalMessages": "veryCasual"], isExistingInstall: true)
        let kept = ToneSettings.migrated(from: earlier).settingApp(.tone(.casual), bundleIDs: ["net.whatsapp.WhatsApp"])
        #expect(kept.plan(for: .personalMessages, bundleID: "net.whatsapp.WhatsApp").layout == .casual)
        #expect(kept.plan(for: .personalMessages, bundleID: "com.apple.MobileSMS").layout == .veryCasual)
        // Clearing the app's choice goes back to the kind of app.
        settings = settings.settingApp(nil, bundleIDs: [slack])
        #expect(settings.plan(for: .workMessages, bundleID: slack).tone == .professional)
    }

    @Test("moving an app changes its group tone, its own tone still wins, and reset restores classification")
    func moveAndReset() {
        let id = "com.example.writer"
        var settings = ToneSettings.standard.settingTone(.casual, for: .personalMessages)
        settings = settings.movingApp(to: .personalMessages, bundleIDs: [id])
        #expect(settings.plan(for: .other, bundleID: id).tone == .casual)
        settings = settings.settingApp(.tone(.professional), bundleIDs: [id])
        #expect(settings.plan(for: .other, bundleID: id).tone == .professional)
        settings = settings.settingApp(nil, bundleIDs: [id])
        #expect(settings.plan(for: .other, bundleID: id).tone == .casual)
        settings = settings.movingApp(to: nil, bundleIDs: [id])
        #expect(settings.plan(for: .other, bundleID: id).tone == .refined)
        let browser = settings.movingApp(to: .email, bundleIDs: ["com.google.Chrome"])
        #expect(browser.plan(for: .other, bundleID: "com.google.Chrome").tone == .refined)
        let code = settings.movingApp(to: .email, bundleIDs: ["com.apple.Terminal"])
        #expect(code.plan(for: .code, bundleID: "com.apple.Terminal").tone == nil)
    }

    @Test("placement and added apps persist; older group tones migrate without new keys")
    func appPlacementStorage() throws {
        let id = "com.example.widget"
        let settings = ToneSettings.standard.settingTone(.casual, for: .email).addingApp(id, to: .email)
        let restored = try JSONDecoder().decode(ToneSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored == settings)
        #expect(restored.plan(for: .other, bundleID: id).tone == .casual)
        #expect(restored.fingerprint != ToneSettings.standard.fingerprint)
        let legacy = Data(#"{"isAsSpoken":false,"defaultTone":"refined","overrides":{"email":"casual"},"keptLayouts":{},"apps":{"com.example.writer":"professional"}}"#.utf8)
        let migrated = try JSONDecoder().decode(ToneSettings.self, from: legacy)
        #expect(migrated.tone(for: .email) == .casual)
        #expect(migrated.appTone(for: "com.example.writer") == .professional)
        #expect(migrated.appKinds.isEmpty && migrated.addedApps.isEmpty)
    }

    @Test("an app choice gives a code editor no tone; browsers, As spoken and an unknown focus are unchanged")
    func appChoiceBoundaries() {
        let ids = ["com.apple.Terminal", "com.google.Chrome", "com.example.app"]
        let settings = ToneSettings.standard.settingApp(.tone(.casual), bundleIDs: ids)
        #expect(settings.plan(for: .code, bundleID: ids[0]).tone == nil)
        #expect(settings.plan(for: .code, bundleID: ids[0]).level == .polished)
        #expect(settings.plan(for: .other, bundleID: ids[1]).tone == .refined)
        #expect(settings.plan(for: .other, bundleID: ids[2]).tone == .casual)
        #expect(settings.plan(for: .other, bundleID: nil).tone == .refined)
        var spoken = settings
        spoken.choice = .asSpoken
        #expect(spoken.plan(for: .other, bundleID: ids[2]).tone == nil)
        #expect(spoken.plan(for: .other, bundleID: ids[2]).level == .verbatim)
    }

    @Test("a prompt choice is not a tone: the tone pass follows the kind, and the register is Prompt")
    func promptChoice() throws {
        #expect(AppWriting(rawValue: "prompt") == .prompt)
        #expect(!AppWriting.prompt.isAvailable)
        #expect(AppWriting.tone(.casual).isAvailable)
        let settings = ToneSettings.standard.settingApp(.prompt, bundleIDs: ["com.example.ai"])
        #expect(settings.appTone(for: "com.example.ai") == nil)
        #expect(settings.plan(for: .other, bundleID: "com.example.ai").tone == .refined)
        #expect(settings.register(for: .other, bundleID: "com.example.ai") == .prompt)
        // Never in a browser (a tab can be anything) or in code, and never while As spoken is on.
        #expect(settings.register(for: .code, bundleID: "com.example.ai") == nil)
        var spoken = settings
        spoken.isAsSpoken = true
        #expect(spoken.register(for: .other, bundleID: "com.example.ai") == nil)
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(ToneSettings.self, from: data).appChoices["com.example.ai"] == .prompt)
    }

    @Test("settings saved before per-app tones still load, and an empty app list adds nothing to what is saved")
    func oldDataLoads() throws {
        let old = Data(#"{"isAsSpoken":false,"defaultTone":"casual","overrides":{"email":"professional"},"keptLayouts":{}}"#.utf8)
        let decoded = try JSONDecoder().decode(ToneSettings.self, from: old)
        #expect(decoded.defaultTone == .casual)
        #expect(decoded.appChoices.isEmpty)
        #expect(!String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("apps"))
        let unknown = Data(#"{"isAsSpoken":false,"defaultTone":"refined","overrides":{},"keptLayouts":{},"apps":{"a.b":"casual","c.d":"loud"}}"#.utf8)
        #expect(try JSONDecoder().decode(ToneSettings.self, from: unknown).appChoices == ["a.b": .tone(.casual)])
    }

    @Test("a different tone for one kind of app wins there and nowhere else")
    func overrideResolution() {
        var settings = ToneSettings.standard
        settings.choice = .casual
        settings = settings.settingTone(.professional, for: .email)
        #expect(settings.tone(for: .email) == .professional)
        #expect(settings.plan(for: .email).tone == .professional)
        #expect(settings.plan(for: .email).layout == .formal)
        #expect(settings.tone(for: .personalMessages) == .casual)
        #expect(settings.plan(for: .workMessages).tone == .casual)
        #expect(settings.plan(for: .workMessages).layout == .casual)
        settings = settings.settingTone(nil, for: .email)
        #expect(settings.tone(for: .email) == .casual)
        #expect(!settings.hasOverride(for: .email))
    }

    @Test("changing the default leaves an explicit choice for a place alone")
    func defaultChangeKeepsOverride() {
        var settings = ToneSettings.standard.settingTone(.casual, for: .personalMessages)
        settings.choice = .professional
        #expect(settings.tone(for: .personalMessages) == .casual)
        #expect(settings.tone(for: .email) == .professional)
    }

    @Test("As spoken is the only way to skip cleanup, and nothing is applied then")
    func asSpoken() {
        var settings = ToneSettings.standard.settingTone(.casual, for: .personalMessages)
        settings.choice = .asSpoken
        #expect(settings.isAsSpoken)
        #expect(settings.dictationLevel == .verbatim)
        #expect(settings.noteCleanupLevel == .verbatim)
        for category in AppCategory.allCases {
            let plan = settings.plan(for: category)
            #expect(plan.level == .verbatim)
            #expect(plan.tone == nil)
            #expect(plan.style == nil)
        }
        // The tone chosen before is remembered for when someone switches back.
        settings.choice = .professional
        #expect(!settings.isAsSpoken)
        #expect(settings.dictationLevel == .polished)
        #expect(settings.tone(for: .personalMessages) == .casual)
    }

    @Test("every tone runs the model level; only As spoken does not")
    func levels() {
        for choice in ToneChoice.allCases {
            var settings = ToneSettings.standard
            settings.choice = choice
            #expect(settings.dictationLevel == (choice == .asSpoken ? .verbatim : .polished), "\(choice)")
            #expect(settings.noteCleanupLevel == (choice == .asSpoken ? .verbatim : .clean), "\(choice)")
        }
    }

    // MARK: Code and modes

    @Test("code editors and terminals get the grammar-repair level, with no tone and no layout")
    func codeContext() {
        let plan = ToneSettings.standard.settingTone(.casual, for: .other).plan(for: .code)
        #expect(plan.tone == nil)
        #expect(plan.style == nil)
        #expect(plan.level == .polished)
    }

    @Test("every mode keeps its own level; the stock Default mode already follows the person's setting, in code apps too")
    func modeLevels() {
        let builtIns = Mode.builtIns(userName: "")
        var defaultMode = builtIns[0]
        defaultMode.cleanupLevel = .polished
        let code = ToneSettings.standard.plan(for: .code)
        let prose = ToneSettings.standard.plan(for: .other)
        #expect(code.level(for: defaultMode) == .polished)
        #expect(prose.level(for: defaultMode) == .polished)
        var cleaned = defaultMode
        cleaned.cleanupLevel = .clean
        #expect(code.level(for: cleaned) == .clean)
        var verbatim = defaultMode
        verbatim.cleanupLevel = .verbatim
        #expect(code.level(for: verbatim) == .verbatim)
        let custom = Mode(name: "Mine", icon: "star", cleanupLevel: .polished)
        #expect(code.level(for: custom) == .polished)
        var transform = builtIns[0]
        transform.cleanupLevel = .polished
        transform.prompt = "Make it short."
        #expect(code.level(for: transform) == .polished)
    }

    // MARK: Layouts kept from the old Style page

    @Test("a kept layout is used until a tone is picked for that place")
    func keptLayout() {
        let earlier = ToneSettings.Earlier(
            cleanupLevel: "clean", styles: ["personalMessages": "veryCasual"], isExistingInstall: true)
        let settings = ToneSettings.migrated(from: earlier)
        #expect(settings.keptLayout(for: .personalMessages) == .veryCasual)
        #expect(settings.layout(for: .personalMessages) == .veryCasual)
        #expect(settings.plan(for: .personalMessages).layout == .veryCasual)
        #expect(settings.plan(for: .personalMessages).tone == .refined)
        let replaced = settings.settingTone(.casual, for: .personalMessages)
        #expect(replaced.keptLayout(for: .personalMessages) == nil)
        #expect(replaced.layout(for: .personalMessages) == .casual)
    }

    // MARK: Storage

    @Test("the setting survives encoding and ignores values it does not know")
    func codable() throws {
        var settings = ToneSettings.standard.settingTone(.professional, for: .email)
        settings.choice = .casual
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(ToneSettings.self, from: data) == settings)
        let odd = Data(#"{"isAsSpoken":false,"defaultTone":"loud","overrides":{"email":"casual","nowhere":"casual","other":"shouty"},"keptLayouts":{"other":"nope"}}"#.utf8)
        let decoded = try JSONDecoder().decode(ToneSettings.self, from: odd)
        #expect(decoded.defaultTone == .refined)
        #expect(decoded.tone(for: .email) == .casual)
        #expect(!decoded.hasOverride(for: .other))
        #expect(decoded.keptLayout(for: .other) == nil)
    }

    @Test("the fingerprint changes whenever anything a person can change does")
    func fingerprint() {
        var seen: Set<String> = [ToneSettings.standard.fingerprint]
        var settings = ToneSettings.standard
        settings.choice = .casual
        seen.insert(settings.fingerprint)
        settings.choice = .asSpoken
        seen.insert(settings.fingerprint)
        seen.insert(ToneSettings.standard.settingTone(.casual, for: .email).fingerprint)
        seen.insert(ToneSettings.standard.settingTone(.casual, for: .workMessages).fingerprint)
        #expect(seen.count == 5)
    }

    // MARK: Migration from the cleanup level and writing styles

    private func earlier(_ level: String?, _ styles: [String: String] = [:], existing: Bool = true) -> ToneSettings.Earlier {
        ToneSettings.Earlier(cleanupLevel: level, styles: styles, isExistingInstall: existing)
    }

    @Test("a first launch starts from the defaults, whatever the old defaults were")
    func freshInstall() {
        #expect(ToneSettings.migrated(from: earlier(nil, [:], existing: false)).tone(for: .email) == .professional)
        #expect(ToneSettings.migrated(from: earlier(nil, [:], existing: false)) == .standard)
        #expect(ToneSettings.migrated(from: earlier("verbatim", ["email": "excited"], existing: false)) == .standard)
    }

    @Test("As spoken stays As spoken; Cleaned up and Polished become Refined")
    func levelMapping() {
        #expect(ToneSettings.migrated(from: earlier("verbatim")).isAsSpoken)
        for level in ["clean", "polished", nil] {
            let migrated = ToneSettings.migrated(from: earlier(level))
            #expect(!migrated.isAsSpoken, "\(String(describing: level))")
            #expect(migrated.defaultTone == .refined)
        }
        #expect(ToneSettings.migrated(from: earlier("something else")).isAsSpoken == false)
    }

    @Test("someone who never touched a style keeps casual personal messages and formal everywhere else")
    func untouchedExistingInstall() {
        let migrated = ToneSettings.migrated(from: earlier(nil))
        #expect(migrated.tone(for: .personalMessages) == .casual)
        #expect(migrated.tone(for: .workMessages) == .refined)
        #expect(migrated.tone(for: .email) == .professional)
        #expect(migrated.isShippedTone(for: .email))
        #expect(migrated.tone(for: .other) == .refined)
        #expect(StyleContext.allCases.allSatisfy { migrated.keptLayout(for: $0) == nil })
    }

    @Test("every old style in every place maps to the same layout, so capitals and punctuation do not move")
    func layoutIsPreserved() {
        for context in StyleContext.allCases {
            for style in WritingStyle.allCases {
                let migrated = ToneSettings.migrated(from: earlier("clean", [context.rawValue: style.rawValue]))
                #expect(migrated.layout(for: context) == style, "\(context) \(style)")
            }
        }
    }

    @Test("old style to tone: Formal is Refined, Casual is Casual, very casual and Excited keep their layout")
    func styleMapping() {
        let table: [(WritingStyle, DictationTone, WritingStyle?)] = [
            (.formal, .refined, nil),
            (.casual, .casual, nil),
            (.veryCasual, .refined, .veryCasual),
            (.excited, .refined, .excited),
        ]
        for (style, tone, kept) in table {
            let migrated = ToneSettings.migrated(from: earlier("clean", ["workMessages": style.rawValue]))
            #expect(migrated.tone(for: .workMessages) == tone, "\(style)")
            #expect(migrated.keptLayout(for: .workMessages) == kept, "\(style)")
        }
    }

    @Test("a stored choice the same as the old default is the same as no choice, except for email")
    func explicitDefaults() {
        let explicit = ToneSettings.migrated(from: earlier("clean", ["personalMessages": "casual", "workMessages": "formal"]))
        #expect(explicit == ToneSettings.migrated(from: earlier("clean")))
    }

    @Test("anyone who chose a style for email keeps it; only an untouched email starts on Professional")
    func emailKeepsAChoice() {
        let untouched = ToneSettings.migrated(from: earlier("clean"))
        #expect(untouched.tone(for: .email) == .professional)
        let formal = ToneSettings.migrated(from: earlier("clean", ["email": "formal"]))
        #expect(formal.tone(for: .email) == .refined)
        #expect(formal.layout(for: .email) == .formal)
        #expect(formal.hasOverride(for: .email) && !formal.isShippedTone(for: .email))
        let casual = ToneSettings.migrated(from: earlier("clean", ["email": "casual"]))
        #expect(casual.tone(for: .email) == .casual)
        for style in ["veryCasual", "excited"] {
            let kept = ToneSettings.migrated(from: earlier("clean", ["email": style]))
            #expect(kept.tone(for: .email) == .refined)
            #expect(kept.keptLayout(for: .email)?.rawValue == style)
        }
        #expect(ToneSettings.migrated(from: earlier("verbatim")).isAsSpoken)
        #expect(ToneSettings.migrated(from: earlier("verbatim")).tone(for: .email) == .professional)
    }

    @Test("unknown stored styles fall back to the old default for that place")
    func unknownStyle() {
        let migrated = ToneSettings.migrated(from: earlier("clean", ["email": "shouting", "nowhere": "casual"]))
        #expect(migrated == ToneSettings.migrated(from: earlier("clean")))
    }
}
