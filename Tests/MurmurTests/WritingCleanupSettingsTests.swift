import Foundation
import Testing
import MurmurCore
@testable import Murmur

@Suite("Writing tone settings")
@MainActor
struct WritingCleanupSettingsTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let name = "hushy-test-writing-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test("a first launch is Refined everywhere, running the cleanup pass")
    func freshDefaults() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.toneSettings == .standard)
        #expect(settings.dictationLevel == .polished)
        #expect(settings.noteCleanupLevel == .clean)
        #expect(settings.cleanupOptions.level == .polished)
        #expect(settings.consumeActiveMode(bundleID: nil).cleanupLevel == .polished)
    }

    @Test("the selection reaches a Default session and survives a reload", arguments: ToneChoice.allCases)
    func selectionReachesSession(choice: ToneChoice) throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.toneSettings.choice = choice
        let expected: CleanupLevel = choice == .asSpoken ? .verbatim : .polished
        #expect(settings.previewActiveMode(bundleID: nil).cleanupLevel == expected)
        let captured = settings.consumeActiveMode(bundleID: nil)
        #expect(captured.cleanupLevel == expected)
        settings.toneSettings.choice = choice == .asSpoken ? .refined : .asSpoken
        #expect(captured.cleanupLevel == expected)
        #expect(AppSettings(defaults: defaults).toneSettings.choice == settings.toneSettings.choice)
    }

    @Test("an app or website on As spoken gets a word-for-word session; others, and a mode picked for one dictation, do not")
    func asSpokenLaneReachesSession() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.toneSettings = ToneSettings.standard.settingApp(.asSpoken, bundleIDs: ["com.apple.Notes"])
            .settingSite(.asSpoken, key: "google-docs")
        #expect(settings.consumeActiveMode(bundleID: "com.apple.Notes").cleanupLevel == .verbatim)
        #expect(settings.consumeActiveMode(bundleID: "com.google.Chrome", site: "google-docs").cleanupLevel == .verbatim)
        #expect(settings.consumeActiveMode(bundleID: "com.google.Chrome").cleanupLevel == .polished)
        #expect(settings.consumeActiveMode(bundleID: "com.apple.mail").cleanupLevel == .polished)
        // A mode picked from the pill for the next dictation keeps its own level, and only for that one.
        settings.manualModeOverrideID = Mode.BuiltInID.email
        #expect(settings.consumeActiveMode(bundleID: "com.apple.Notes").cleanupLevel == .clean)
        #expect(settings.consumeActiveMode(bundleID: "com.apple.Notes").cleanupLevel == .verbatim)
        // Survives a relaunch.
        #expect(AppSettings(defaults: defaults).toneSettings == settings.toneSettings)
    }

    @Test("a tone for one kind of app survives a reload")
    func overrideSurvives() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.toneSettings = settings.toneSettings.settingTone(.casual, for: .workMessages)
            .settingApp(.tone(.professional), bundleIDs: ["net.whatsapp.WhatsApp"])
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.toneSettings.tone(for: .workMessages) == .casual)
        #expect(reloaded.toneSettings.tone(for: .email) == .professional)
        #expect(reloaded.toneSettings.appTone(for: "net.whatsapp.WhatsApp") == .professional)
    }

    @Test("custom and explicitly edited Default presets retain their chosen level")
    func customPresets() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let custom = MurmurCore.Mode(name: "Code", icon: "textformat", cleanupLevel: .verbatim, appBundleIDs: ["example.editor"])
        settings.modes.append(custom)
        #expect(settings.consumeActiveMode(bundleID: "example.editor").cleanupLevel == .verbatim)
        settings.manualModeOverrideID = custom.id
        #expect(settings.consumeActiveMode(bundleID: nil).cleanupLevel == .verbatim)
        #expect(settings.manualModeOverrideID == nil)
        let defaultIndex = try #require(settings.modes.firstIndex { $0.id == MurmurCore.Mode.BuiltInID.default })
        settings.modes[defaultIndex].cleanupLevel = .verbatim
        #expect(settings.consumeActiveMode(bundleID: nil).cleanupLevel == .verbatim)
    }

    @Test("a transform on Default retains its preset cleanup level")
    func defaultTransform() {
        var mode = MurmurCore.Mode.builtIns(userName: "")[0]
        mode.prompt = "Format as a short email."
        #expect(mode.resolvingAppCleanupLevel(.polished) == mode)
        var duplicate = mode
        duplicate.id = UUID()
        duplicate.prompt = nil
        #expect(duplicate.resolvingAppCleanupLevel(.polished) == duplicate)
    }

    // MARK: Earlier settings

    @Test("earlier settings are mapped once, with As spoken kept and the old styles carried over")
    func migratesEarlierSettings() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("verbatim", forKey: "cleanupLevel")
        defaults.set(["email": "excited", "workMessages": "casual", "other": "veryCasual"], forKey: "styles")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.toneSettings.isAsSpoken)
        #expect(settings.toneSettings.tone(for: .workMessages) == .casual)
        #expect(settings.toneSettings.keptLayout(for: .email) == .excited)
        #expect(settings.toneSettings.keptLayout(for: .other) == .veryCasual)
        // Mapped once: later changes to the old keys are ignored, and the old keys are left alone.
        defaults.set("clean", forKey: "cleanupLevel")
        #expect(AppSettings(defaults: defaults).toneSettings == settings.toneSettings)
        #expect(defaults.string(forKey: "cleanupLevel") == "clean")
        #expect(defaults.dictionary(forKey: "styles") != nil)
    }

    @Test("someone who finished onboarding without touching a style keeps casual personal messages")
    func untouchedExisting() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "hasCompletedOnboarding")
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.toneSettings.isAsSpoken)
        #expect(settings.toneSettings.tone(for: .personalMessages) == .casual)
        #expect(settings.toneSettings.layout(for: .personalMessages) == .casual)
        #expect(settings.toneSettings.tone(for: .email) == .professional)
    }

    @Test("a new install is not mapped later, when onboarding finishes")
    func freshInstallStaysFresh() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        _ = AppSettings(defaults: defaults)
        defaults.set(true, forKey: "hasCompletedOnboarding")
        #expect(AppSettings(defaults: defaults).toneSettings == .standard)
    }
}
