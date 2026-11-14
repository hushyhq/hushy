import Foundation
import Testing
import MurmurCore
@testable import Murmur

/// "Use American spelling" (Voice & style → Style) defaults from the system locale's region and
/// persists the user's explicit choice. See docs/product/US-ENGLISH-ACCURACY.md §5 and
/// .claude/DECISIONS.md for why the default is region-based rather than always-on/off.
@Suite("American spelling setting")
@MainActor
struct AmericanSpellingSettingTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "hushy-test-american-spelling-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("defaults ON for a US system region")
    func defaultsOnForUS() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, systemRegion: .unitedStates)
        #expect(settings.americanSpelling)
    }

    @Test("defaults OFF for a non-US system region", arguments: [
        Locale.Region.unitedKingdom, .india, .ireland, .canada, .australia,
    ])
    func defaultsOffForNonUS(region: Locale.Region) {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, systemRegion: region)
        #expect(!settings.americanSpelling)
    }

    @Test("defaults OFF when the system region is unknown")
    func defaultsOffWhenRegionUnknown() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, systemRegion: nil)
        #expect(!settings.americanSpelling)
    }

    @Test("the user's explicit choice persists across launches, overriding the locale default")
    func persistsExplicitChoice() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        // Starts ON (US region default), user turns it off, and that sticks even though the
        // region-derived default would still say ON.
        let settings = AppSettings(defaults: defaults, systemRegion: .unitedStates)
        #expect(settings.americanSpelling)
        settings.americanSpelling = false
        let reloaded = AppSettings(defaults: defaults, systemRegion: .unitedStates)
        #expect(!reloaded.americanSpelling)

        // Starts OFF (non-US region default), user turns it on, and that sticks even though the
        // region-derived default would still say OFF.
        let (defaults2, name2) = makeDefaults()
        defer { defaults2.removePersistentDomain(forName: name2) }
        let settingsUK = AppSettings(defaults: defaults2, systemRegion: .unitedKingdom)
        #expect(!settingsUK.americanSpelling)
        settingsUK.americanSpelling = true
        let reloadedUK = AppSettings(defaults: defaults2, systemRegion: .unitedKingdom)
        #expect(reloadedUK.americanSpelling)
    }

    @Test("cleanupOptions carries the setting through to the cleanup pipeline")
    func flowsIntoCleanupOptions() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, systemRegion: .unitedStates)
        #expect(settings.cleanupOptions.americanSpelling)
        settings.americanSpelling = false
        #expect(!settings.cleanupOptions.americanSpelling)
    }
}
