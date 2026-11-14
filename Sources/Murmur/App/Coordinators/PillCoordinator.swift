import AppKit
import Observation

/// Owns the floating pill window and keeps its size and click-through behaviour in sync
/// with the pill's state.
@MainActor
final class PillCoordinator {
    private let pill: PillModel
    private var panel: PillPanel?
    private var selfDismissTask: Task<Void, Never>?
    private let distractionDetector: PillDistractionDetector
    private var distractionWatcher: PillDistractionWatcher?
    /// Speaks a recovery row as it appears, and whether VoiceOver is running (a row that still has
    /// its action then waits instead of timing out). Tests pass fakes.
    private let announce: @MainActor (String) -> Void
    private let voiceOverRunning: @MainActor () -> Bool
    private let makePanel: @MainActor (PillModel) -> PillPanel
    private let copy: @MainActor (String, Bool) -> Void

    /// While hidden (the sign-in gate has the app suspended) no state change may bring the panel back.
    private(set) var isHidden = false
    var shouldOrderFront: Bool { !isHidden }

    func hide() { isHidden = true; panel?.orderOut(nil) }
    func unhide() { isHidden = false; panel?.orderFrontRegardless() }

    /// `distractionDetector` is the Mac's window list and power assertions; tests pass `.never`.
    /// `makePanel` and `copy` are the Mac's own in the app. The pill preview gives a panel placed
    /// clear of the real pill and a copy that goes nowhere, so it can never write the clipboard.
    init(
        pill: PillModel, distractionDetector: PillDistractionDetector = .live(),
        announce: @escaping @MainActor (String) -> Void = PillAnnouncer.post,
        voiceOverRunning: @escaping @MainActor () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled },
        makePanel: @escaping @MainActor (PillModel) -> PillPanel = { PillPanel(model: $0) },
        copy: @escaping @MainActor (_ text: String, _ markTransient: Bool) -> Void = { TextInserter.copy($0, markTransient: $1) }
    ) {
        self.pill = pill
        self.distractionDetector = distractionDetector
        self.announce = announce
        self.voiceOverRunning = voiceOverRunning
        self.makePanel = makePanel
        self.copy = copy
    }

    /// A dictation that was not pasted, or produced no text, is said aloud as its row appears. The
    /// pill cannot take focus, so VoiceOver would otherwise never come across it.
    func announceRecovery() {
        if let words = pill.recoveryAnnouncement { announce(words) }
    }

    func show(
        onTapIdle: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onHide: @escaping () -> Void = {}
    ) {
        let panel = makePanel(pill)
        self.panel = panel
        // A deliberate copy (the held row's Copy): the model moves the row to "Copied" itself.
        // The held (password-field) row's Copy: the only way that text reaches the clipboard, and
        // marked so clipboard-history managers don't keep it.
        pill.onCopy = { [copy] text in copy(text, true) }
        // A copy the user asked for (the no-field card's Copy): a normal clipboard write, not the
        // transient mark the password-held row uses.
        pill.onPlainCopy = { [copy] text in copy(text, false) }
        pill.onStop = onStop
        pill.onTapIdle = onTapIdle
        pill.onDismiss = { [weak pill] in pill?.state = .idle }
        pill.onCancel = onCancel
        pill.onDragChanged = { [weak panel] in panel?.dragChanged() }
        pill.onDragEnded = { [weak panel] in panel?.dragEnded() }
        pill.onResetPosition = { [weak panel] in panel?.resetPosition() }
        pill.onHide = onHide
        panel.orderFrontRegardless()
        // Apply the current state now: observation only reports changes, so without this the
        // idle pill stayed click-through (no taps, no drag) until the first state change.
        apply(pill.state)
        track()
        trackDistractionPolling()
        watchDistraction()
    }

    /// The idle pill hides while video plays, a call is active, or the frontmost app is full screen.
    private func watchDistraction() {
        let watcher = PillDistractionWatcher(
            detector: distractionDetector,
            workspaceNotifications: NSWorkspace.shared.notificationCenter,
            shouldPoll: { [weak pill] in
                guard let pill else { return false }
                return pill.showWhenIdle && pill.hideIdleDuringVideoOrFullScreen
            }
        ) { [weak pill] snapshot in
            pill?.fullScreenDisplayIDs = snapshot.fullScreenDisplayIDs
            pill?.videoPlaying = snapshot.videoPlaying
        }
        distractionWatcher = watcher
        watcher.start()
    }

    /// Older tests pass `.never` on the window list only.
    convenience init(
        pill: PillModel, fullScreenDetector: FullScreenDetector,
        announce: @escaping @MainActor (String) -> Void = PillAnnouncer.post,
        voiceOverRunning: @escaping @MainActor () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled },
        makePanel: @escaping @MainActor (PillModel) -> PillPanel = { PillPanel(model: $0) },
        copy: @escaping @MainActor (_ text: String, _ markTransient: Bool) -> Void = { TextInserter.copy($0, markTransient: $1) }
    ) {
        self.init(
            pill: pill,
            distractionDetector: PillDistractionDetector {
                PillDistraction(
                    fullScreenDisplayIDs: fullScreenDetector.fullScreenDisplayIDs(),
                    videoPlaying: false)
            },
            announce: announce,
            voiceOverRunning: voiceOverRunning,
            makePanel: makePanel,
            copy: copy)
    }

    private func track() {
        withObservationTracking {
            _ = pill.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.apply(self.pill.state)
                self.track()
            }
        }
    }

    private func trackDistractionPolling() {
        withObservationTracking {
            _ = (pill.showWhenIdle, pill.hideIdleDuringVideoOrFullScreen)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.distractionWatcher?.refreshPollingPolicy()
                self?.trackDistractionPolling()
            }
        }
    }

    private func apply(_ state: PillState) {
        panel?.setInteractive(state.isInteractive)
        panel?.setState(state)
        // The keyboard is the panel's only while a name's spelling is open; any other state gives it back.
        panel?.releaseKeyboardUnlessEditing()
        scheduleSelfDismiss(state)
        announceRecovery()
        if case .listening = state { panel?.reposition() }
        // Re-assert topmost placement on every state change, not just at launch — otherwise a
        // window raised elsewhere while the pill sits idle can end up stacked above it even
        // though the pill's level hasn't changed.
        if shouldOrderFront { panel?.orderFrontRegardless() }
    }

    /// Clears rows nobody else times (`PillModel.selfDismissDelay`), unless the pill has moved on.
    /// A row holding words that were not pasted waits while the pointer is over it or its capsule
    /// (`selfDismissDecision`).
    private func scheduleSelfDismiss(_ state: PillState) {
        selfDismissTask?.cancel()
        guard var delay = pill.selfDismissDelay else { return }
        let revision = pill.stateRevision
        selfDismissTask = Task { [weak pill] in
            while true {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let pill, pill.stateRevision == revision else { return }
                switch pill.state.selfDismissDecision(pointerOverCard: pill.isPointerOverCard || pill.isHovered || pill.isTypingName,
                                                      voiceOverRunning: voiceOverRunning()) {
                case .dismiss:
                    pill.state = .idle
                    return
                case .wait(let again):
                    delay = again
                }
            }
        }
    }
}
