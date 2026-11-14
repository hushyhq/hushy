import Foundation

/// Picks which mode applies to a dictation: a manual override (the user picked one from the
/// pill's mode chip for the *next* dictation) beats a per-app assignment, which beats the
/// Default mode. Pure and stateless — `ModeStore`/`DictationController` own the manual-override
/// lifecycle (it is consumed by the next dictation and then cleared, like a one-shot).
public enum ModeResolver {
    /// - Parameters:
    ///   - manualOverride: A mode explicitly chosen from the mode chip for the next dictation,
    ///     if any. Wins over any app assignment.
    ///   - bundleID: The focused app's bundle identifier, if known.
    ///   - modes: All modes (built-in + user-created), in display order.
    ///   - defaultMode: Fallback when nothing else matches (normally `Mode.builtIns`'s Default).
    public static func resolve(
        manualOverride: Mode?, bundleID: String?, modes: [Mode], defaultMode: Mode
    ) -> Mode {
        if let manualOverride { return manualOverride }
        if let bundleID, let assigned = modes.first(where: { $0.appBundleIDs.contains(bundleID) }) {
            return assigned
        }
        return defaultMode
    }
}
