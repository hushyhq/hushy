import Foundation

/// The second look at a paste into a field Hushy is sure of needs two things: an app where a lost paste leaves
/// the count of the focused text area exactly as it was, and a read of that field from before the paste. The
/// read is the one made at key-down, so nothing is read between the end of cleanup and ⌘V.
///
/// A false "not pasted" makes people paste twice, so the look is an allowlist: an app is unwatched until it is
/// named here. A denylist of browsers, Electron and the like failed review three times, each time on an app type
/// nobody had listed (Chromium browsers off the browser list, terminals that host agent composers).
public enum FieldWatch {
    /// Apple text views where a lost paste provably leaves the count unchanged and a landed one changes it, and
    /// where the person's own Return cannot turn a landed paste into an unchanged field: Return adds a line
    /// there (it never sends and never clears), so an empty field that took the paste still counts one more.
    ///
    /// - TextEdit: an `NSTextView`; the count is the document length.
    /// - Notes: a text view of the document; Return starts a new line.
    /// - Mail: the message body of a compose window, an editable WebKit view inside a native app that Hushy does
    ///   not treat as a page; Return starts a new line, and Send is ⇧⌘D.
    ///
    /// Left out on purpose. Messages: Return sends and empties the composer, so a landed paste followed by the
    /// person's Return reads 0 then 0, the picture of a lost paste. Xcode: the same, in its assistant composer.
    /// Pages and Microsoft Word: custom-drawn editors whose count is not reported. Terminals (Terminal, iTerm2,
    /// Ghostty, Warp) and the agent composers that run inside them keep the same character count after a paste.
    /// Every browser, and every Electron, CEF or WebView2 app: any page or panel may draw its editor behind a
    /// hidden input that reads empty whether or not the paste landed.
    public static let watchedApps: Set<String> = ["com.apple.TextEdit", "com.apple.Notes", "com.apple.mail"]

    public static func watches(bundleID: String?) -> Bool {
        bundleID.map(watchedApps.contains) ?? false
    }

    /// The key-down read of a known field in a watched app. `read` runs only then: an app that is not watched is
    /// not read, and neither is a target captured for anything but a dictation (paste last and the voice-action
    /// fallback bind to focus at the moment they paste and nothing looks at that paste again).
    public static func baseline(
        answer: FocusAnswer, bundleID: String?, forDictation: Bool, read: () -> LandingProbe?
    ) -> LandingProbe? {
        guard forDictation, answer == .field, watches(bundleID: bundleID) else { return nil }
        return read()
    }
}
