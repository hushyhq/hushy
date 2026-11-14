import AppKit
import Foundation
import Testing
@testable import Murmur

/// "Keep dictations on the clipboard" (Settings → Writing): default ON, persisted, and flowing to
/// the one system paster through `SettingsSync` (UI → AppSettings → SettingsSync → delivery).
@Suite("Keep dictations on the clipboard — setting")
@MainActor
struct KeepOnClipboardSettingTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "hushy-test-keep-clipboard-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("defaults OFF: a pasted dictation does not replace the user's clipboard")
    func defaultsOff() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!AppSettings(defaults: defaults).keepDictationsOnClipboard)
    }

    @Test("an explicit ON persists")
    func persistsOn() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        AppSettings(defaults: defaults).keepDictationsOnClipboard = true
        #expect(AppSettings(defaults: defaults).keepDictationsOnClipboard)
    }

    @Test("an explicit OFF persists")
    func persistsOff() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.keepDictationsOnClipboard = true
        settings.keepDictationsOnClipboard = false
        #expect(!AppSettings(defaults: defaults).keepDictationsOnClipboard)
    }

    @Test("SettingsSync hands the setting to the paster")
    func syncsToPaster() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("app.hushy.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let paster = ClipboardPaster(pasteboard: pasteboard, postKey: { _, _ in true })
        SettingsSync.applyClipboard(keep: true, to: paster)
        #expect(paster.keepsPastedText)
        SettingsSync.applyClipboard(keep: false, to: paster)
        #expect(!paster.keepsPastedText)
    }
}
