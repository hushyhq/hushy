import AppKit
import MurmurCore
import SwiftUI

/// Home's Quick Look for a dictation: a floating panel centred over the main window showing the
/// same `HistoryDetailPane` History uses. Esc or Space closes it; ←/↑ and →/↓ step through the
/// feed (`QuickLookNavigation`) without closing, cross-fading the content. One panel at a time —
/// opening another dictation reuses it. It's a child of the main window, so it stays above it,
/// moves with it, and inherits the app's light/dark appearance.
@MainActor
@Observable
final class DictationQuickLook: NSObject, NSWindowDelegate {
    /// The dictation shown (and highlighted in the feed). Stays set after the panel closes, so
    /// Space on the feed reopens it, Finder-style; Esc in the feed clears it.
    private(set) var currentID: Int64?
    private(set) var isOpen = false

    /// The feed's current dictation order, re-read on every step so new dictations count.
    @ObservationIgnored var order: () -> [Int64] = { [] }
    @ObservationIgnored private var panel: QuickLookPanel?
    @ObservationIgnored private var keyMonitor: Any?

    static let defaultSize = NSSize(width: 560, height: 640)

    /// Opens (or retargets) the panel on `id`. Clicking the row that's already open closes it.
    func toggle(_ id: Int64, model: AppModel) {
        if isOpen, currentID == id {
            close()
        } else {
            open(id, model: model)
        }
    }

    func open(_ id: Int64, model: AppModel) {
        withAnimation(Theme.fade) { currentID = id }
        let panel = self.panel ?? makePanel(model: model)
        self.panel = panel
        if !isOpen {
            place(panel)
            installKeyMonitor()
            isOpen = true
        }
        panel.makeKeyAndOrderFront(nil)
    }

    /// Selects without opening (keyboard stepping in the feed while the panel is closed).
    func select(_ id: Int64?) {
        withAnimation(Theme.fade) { currentID = id }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        removeKeyMonitor()
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    func step(_ direction: QuickLookNavigation.Direction) {
        guard let next = QuickLookNavigation.neighbor(of: currentID, inOrder: order(), direction: direction) else {
            NSSound.beep()
            return
        }
        withAnimation(Theme.fade) { currentID = next }
    }

    /// Position of the current dictation in the feed, e.g. (2, 7), for the panel's header.
    var position: (index: Int, count: Int)? {
        let ids = order()
        guard let currentID, let index = ids.firstIndex(of: currentID) else { return nil }
        return (index + 1, ids.count)
    }

    // MARK: Window

    private func makePanel(model: AppModel) -> QuickLookPanel {
        let panel = QuickLookPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.title = "Dictation"
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = true
        panel.minSize = NSSize(width: 420, height: 400)
        panel.animationBehavior = .utilityWindow
        // nil appearance = follow the app's, which is what the main window follows too.
        panel.appearance = nil
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: QuickLookContent(quickLook: self)
                .environment(model)
                .tint(Theme.phosphor))
        return panel
    }

    /// Centres the panel over the main window and attaches it as a child window.
    private func place(_ panel: NSPanel) {
        let parent = NSApp.windows.first { ($0.identifier?.rawValue.hasPrefix("main") ?? false) && $0.isVisible }
            ?? NSApp.mainWindow ?? NSApp.keyWindow
        guard let parent, parent !== panel else {
            panel.center()
            return
        }
        let size = panel.frame.size
        let origin = NSPoint(x: parent.frame.midX - size.width / 2, y: parent.frame.midY - size.height / 2)
        panel.setFrameOrigin(origin)
        if panel.parent !== parent { parent.addChildWindow(panel, ordered: .above) }
    }

    func windowWillClose(_ notification: Notification) {
        // The title bar's close button.
        isOpen = false
        removeKeyMonitor()
        if let panel { panel.parent?.removeChildWindow(panel) }
    }

    // MARK: Keys

    /// Esc/Space close; arrows step. Only for key events aimed at the panel and with no
    /// command/control/option held, so ⌘C, ⌘W and text selection keep working.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            else { return event }
            switch event.keyCode {
            case 53, 49: self.close()                // Esc, Space
            case 123, 126: self.step(.previous)      // ←, ↑
            case 124, 125: self.step(.next)          // →, ↓
            default: return event
            }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// A panel that can become key (so it receives Esc/arrows) without being a document window.
final class QuickLookPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The panel's content: a slim header (position in the feed, step buttons, key hints) over the
/// shared `HistoryDetailPane`, cross-faded per dictation.
struct QuickLookContent: View {
    let quickLook: DictationQuickLook
    @Environment(AppModel.self) private var model
    /// Snapshot rendering only: the dictation to show, bypassing the live controller.
    var snapshotDictation: Dictation?

    private var dictation: Dictation? {
        if let snapshotDictation { return snapshotDictation }
        guard let id = quickLook.currentID else { return nil }
        return model.library.dictations.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                if let dictation {
                    HistoryDetailPane(dictation: dictation)
                        .id(dictation.id)
                        .transition(.opacity)
                } else {
                    Text("This dictation was deleted.")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(Theme.bgBase)
        .frame(minWidth: 420, minHeight: 400)
        .onChange(of: dictation?.id) { _, id in
            // Deleted from the pane (or elsewhere): nothing left to look at.
            if id == nil, snapshotDictation == nil { quickLook.close() }
        }
    }

    /// Sits in the transparent title bar, to the right of the traffic lights.
    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            if let position = quickLook.position {
                Text("\(position.index) of \(position.count) today")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            Text("← → to step · Esc to close")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            IconButton(symbol: "chevron.up", help: "Previous dictation (↑)") { quickLook.step(.previous) }
            IconButton(symbol: "chevron.down", help: "Next dictation (↓)") { quickLook.step(.next) }
        }
        .padding(.leading, 80)
        .padding(.trailing, Theme.Space.s)
        .frame(height: 30)
        .padding(.top, 2)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }
}
