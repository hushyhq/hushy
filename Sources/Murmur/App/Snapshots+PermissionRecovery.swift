import SwiftUI

/// The existing Home window in each regrant state. Snapshot mode pins permissions, so no system
/// prompt is shown and the founder's actual TCC settings are never read into these scenes.
extension Snapshots {
    static func renderPermissionRecovery(model: AppModel, scheme: ColorScheme,
                                         size: CGSize, directory: URL) async {
        model.section = .home
        model.settings.sidebarCollapsed = false
        model.modelStatus.pinForSnapshot(.ready)
        model.permissions.pinForSnapshot(microphone: .granted, accessibility: .denied)
        await capture(MainView().environment(model), name: "permission-regrant-accessibility",
                      scheme: scheme, size: size, directory: directory)

        model.permissions.pinForSnapshot(microphone: .denied, accessibility: .denied)
        await capture(MainView().environment(model), name: "permission-regrant-both",
                      scheme: scheme, size: size, directory: directory)

        // The conditional stale-entry instruction is part of the Accessibility state; this
        // closer card view makes that sentence legible in the review set.
        model.permissions.pinForSnapshot(microphone: .granted, accessibility: .denied)
        let status = model.dictationReadiness()
        let copy = DictationHeroCopy.make(
            status: status, triggerGlyph: model.settings.triggerKey.glyph,
            modelState: .ready, download: nil, afterOnboarding: true)
        await capture(
            DictationHeroCard(copy: copy, kind: status.kind, triggerGlyph: model.settings.triggerKey.glyph,
                              content: .tryIt, onFix: {}, onCopy: { _ in }, onOpenInHistory: { _ in }, onUnlock: {})
                .padding(28).background(Theme.bgBase),
            name: "permission-regrant-stale-entry", scheme: scheme,
            size: CGSize(width: 740, height: 340), directory: directory, fixedSize: true)

        // Native macOS menus cannot be opened by ImageRenderer. Render the live menu's shared
        // first item alongside its adjacent status/actions in a menu-sized surface.
        // ImageRenderer cannot draw Buttons, so the scene shows the first item's title as text.
        let menu = VStack(alignment: .leading, spacing: 12) {
            Text(MenuBarCopy.allowAccessibility)
            Divider()
            Text(MenuBarCopy.statusLine(recordingNote: false, readiness: status))
            Text(MenuBarCopy.startHandsFree).foregroundStyle(Theme.textTertiary)
            Text("Open Hushy")
        }
        .font(.system(size: 14))
        .padding(16)
        .frame(width: 290, alignment: .leading)
        .background(Theme.bgRaised)
        await capture(menu.environment(model), name: "permission-regrant-menu-attention",
                      scheme: scheme, size: CGSize(width: 322, height: 210), directory: directory,
                      fixedSize: true)
        model.permissions.pinForSnapshot(microphone: .granted, accessibility: .granted)
    }
}
