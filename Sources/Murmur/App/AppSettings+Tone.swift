import Foundation
import MurmurCore

extension AppSettings {
    /// The stored tone setting, or, the first time this version runs, the one earlier settings
    /// map to (`ToneSettings.migrated`). Saved straight away so it is decided exactly once: a
    /// later change to the old keys, or finishing onboarding, can never run the mapping again.
    static func loadToneSettings(_ defaults: UserDefaults) -> ToneSettings {
        if let data = defaults.data(forKey: toneSettingsKey),
           let stored = try? JSONDecoder().decode(ToneSettings.self, from: data) {
            return stored
        }
        let earlierStyles = defaults.dictionary(forKey: "styles") as? [String: String] ?? [:]
        let earlier = ToneSettings.Earlier(
            cleanupLevel: defaults.string(forKey: "cleanupLevel"),
            styles: earlierStyles,
            isExistingInstall: defaults.bool(forKey: "hasCompletedOnboarding")
                || defaults.string(forKey: "cleanupLevel") != nil || !earlierStyles.isEmpty)
        let migrated = ToneSettings.migrated(from: earlier)
        if let data = try? JSONEncoder().encode(migrated) { defaults.set(data, forKey: toneSettingsKey) }
        return migrated
    }
}
