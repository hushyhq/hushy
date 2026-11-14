import SwiftUI

/// The launch moment (`PrivacyIntro`): the first thing in the main window each launch, covering
/// it for about 2.5 s. Snapshot mode never plays it, so both of its moments are drawn directly:
/// `launch-mark` (the Hushy tile alone, the first ~0.9 s) and `launch-promise` (the lock and the
/// line). The mark must be the Wave-H tile, never a symbol or a hand-drawn copy.
extension Snapshots {
    static func renderLaunch(scheme: ColorScheme, directory: URL) async {
        let size = CGSize(width: 1320, height: 900)
        await capture(
            PrivacyIntroContent(locked: false, showLine: false),
            name: "launch-mark", scheme: scheme, size: size, directory: directory, fixedSize: true)
        await capture(
            PrivacyIntroContent(locked: true, showLine: true),
            name: "launch-promise", scheme: scheme, size: size, directory: directory, fixedSize: true)
    }
}
