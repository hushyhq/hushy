import AppKit
import SwiftUI

/// The card for a dictation key another app may share: one line of what is wrong, and two answers.
struct RivalKeyView: View {
    static let width: CGFloat = 340

    let offer: RivalKeyOffer
    var onSwitch: () -> Void
    var onKeep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(RivalKeyCopy.title(offer: offer))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(RivalKeyCopy.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: Theme.Space.s) {
                Button(action: onSwitch) {
                    Text(RivalKeyCopy.switchButton(offer: offer)).frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                Button(action: onKeep) {
                    Text(RivalKeyCopy.keepButton(offer: offer)).frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(Theme.Space.l)
        .frame(width: Self.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.sheet).fill(Theme.bgRaised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sheet).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// A floating card at the top right of the main display, like the update card. It never takes focus
/// from what the person is typing into, and it stays until they answer it or the other app quits.
@MainActor
final class RivalKeyPanelPresenter: RivalKeyPresenting {
    private var panel: NSPanel?

    func present(_ offer: RivalKeyOffer, switchKey: @escaping () -> Void, keepKey: @escaping () -> Void) {
        dismiss()
        let hosting = NSHostingView(rootView: RivalKeyView(offer: offer, onSwitch: switchKey, onKeep: keepKey))
        let size = hosting.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: area.maxX - size.width - 16, y: area.maxY - size.height - 16))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}
