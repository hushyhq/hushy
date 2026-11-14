import AppKit
import SwiftUI

/// Shows the relaunch prompt. A protocol so the coordinator is testable without a window.
@MainActor
protocol UpdateReadyPresenting: AnyObject {
    func present(_ prompt: UpdateReadyPrompt, relaunch: @escaping () -> Void, later: @escaping () -> Void)
    func dismiss()
}

/// A small floating card at the top right of the main display. It never takes focus from what
/// the person is typing into, and it stays until they answer it.
@MainActor
final class UpdateReadyPanelPresenter: UpdateReadyPresenting {
    private var panel: NSPanel?
    private var hosting: NSHostingView<UpdateReadyView>?

    func present(_ prompt: UpdateReadyPrompt, relaunch: @escaping () -> Void, later: @escaping () -> Void) {
        dismiss()
        let view = UpdateReadyView(
            prompt: prompt, onRelaunch: relaunch, onLater: later,
            onExpandedChange: { [weak self] _ in
                // After SwiftUI has laid the new state out.
                DispatchQueue.main.async { self?.fitToContent() }
            })
        let hosting = NSHostingView(rootView: view)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
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
            let size = hosting.fittingSize
            panel.setFrameOrigin(NSPoint(x: area.maxX - size.width - 16, y: area.maxY - size.height - 16))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        self.hosting = hosting
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
    }

    /// Resizes to the card, keeping its top-left corner where it is.
    private func fitToContent() {
        guard let panel, let hosting else { return }
        let size = hosting.fittingSize
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
    }
}

/// Holds the update that is downloaded and waiting for a relaunch. "Later" leaves it waiting
/// (Sparkle installs it when Hushy quits); asking for updates again brings the prompt back.
@MainActor
final class PendingUpdateCoordinator {
    private let presenter: any UpdateReadyPresenting
    private var pending: (prompt: UpdateReadyPrompt, install: () -> Void)?

    init(presenter: any UpdateReadyPresenting) { self.presenter = presenter }

    var hasPendingUpdate: Bool { pending != nil }

    /// An update was downloaded and will install when Hushy quits; ask once about relaunching.
    func updateReady(_ prompt: UpdateReadyPrompt, install: @escaping () -> Void) {
        pending = (prompt, install)
        showPrompt()
    }

    /// For "Check for Updates…" while an update is already waiting. Returns true if it showed the prompt.
    func remindIfPending() -> Bool {
        guard pending != nil else { return false }
        showPrompt()
        return true
    }

    private func showPrompt() {
        guard let pending else { return }
        presenter.present(pending.prompt, relaunch: { [weak self] in
            self?.presenter.dismiss()
            pending.install()
        }, later: { [weak self] in
            self?.presenter.dismiss()
        })
    }
}
