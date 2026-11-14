import Foundation

/// The app's own version/build, read from the main bundle's `Info.plist` — a single place
/// Settings (sidebar footer, About pane) reads instead of each call site poking
/// `Bundle.main.infoDictionary` directly.
public enum AppVersion {
    /// `CFBundleShortVersionString`, e.g. "1.4.2". Falls back to "—" if unavailable (a snapshot
    /// or test host without a populated Info.plist).
    public static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    /// `CFBundleVersion` (the build number), e.g. "142".
    public static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    /// What Settings shows: "1.4.2 (142)", or just the version if the build number is missing
    /// or identical to it.
    public static var displayString: String {
        guard buildNumber != "—", buildNumber != shortVersion else { return shortVersion }
        return "\(shortVersion) (\(buildNumber))"
    }

    /// The Settings sidebar footer: "Hushy 1.4.2", or "Hushy · development build" when the
    /// bundle carries no version (a `swift run` binary), rather than a dangling "Hushy —".
    public static var footerString: String {
        shortVersion == "—" ? "Hushy · development build" : "Hushy \(shortVersion)"
    }
}
