import Foundation
import Testing
@testable import Murmur

/// The Settings window's structure (experience plan 2026-10-25, section 3.2): six panes, the
/// frozen Notes & meetings settings behind one Advanced switch, and old saved pane names still
/// landing somewhere sensible.
@MainActor
@Suite("Settings panes")
struct SettingsPaneTests {
    private func freshDefaults() -> (UserDefaults, String) {
        let name = "hushy-test-settings-panes-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("a release build shows six panes, in the order a person needs them")
    func sixPanes() {
        let panes = SettingsPane.visible(showsNotesAndMeetings: false).filter { $0.rawValue != "developer" }
        #expect(panes.map(\.title) == ["General", "Privacy", "Voice actions · beta", "Account", "About", "Advanced"])
    }

    @Test("the preview switch adds Notes & meetings and nothing else")
    func previewAddsOnePane() {
        let off = SettingsPane.visible(showsNotesAndMeetings: false)
        let on = SettingsPane.visible(showsNotesAndMeetings: true)
        #expect(!off.contains(.notesAndMeetings))
        #expect(on.contains(.notesAndMeetings))
        #expect(on.count == off.count + 1)
    }

    @Test("a pane name saved by the ten-pane window lands where its controls moved")
    func savedNamesMigrate() {
        #expect(SettingsPane(savedValue: "system") == .general)
        #expect(SettingsPane(savedValue: "writing") == .general)
        #expect(SettingsPane(savedValue: "privacySecurity") == .privacy)
        #expect(SettingsPane(savedValue: "pro") == .account)
        #expect(SettingsPane(savedValue: "meetings") == .notesAndMeetings)
        #expect(SettingsPane(savedValue: "voices") == .notesAndMeetings)
        #expect(SettingsPane(savedValue: "aiConnections") == .advanced)
        #expect(SettingsPane(savedValue: "about") == .about)
        #expect(SettingsPane(savedValue: "nonsense") == nil)
    }

    @Test("notes and meetings preview is off until chosen, and the choice persists")
    func previewSetting() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.notesAndMeetingsPreview)
        settings.notesAndMeetingsPreview = true
        #expect(AppSettings(defaults: defaults).notesAndMeetingsPreview)
        settings.notesAndMeetingsPreview = false
        #expect(!AppSettings(defaults: defaults).notesAndMeetingsPreview)
    }

    @Test("hiding a pane keeps what it stored")
    func hidingKeepsValues() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.recordCallAudio = false
        settings.notesAndMeetingsPreview = true
        settings.notesAndMeetingsPreview = false
        #expect(AppSettings(defaults: defaults).recordCallAudio == false)
    }
}
