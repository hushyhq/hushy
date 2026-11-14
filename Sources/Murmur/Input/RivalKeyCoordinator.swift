import AppKit
import os

/// Shows the shared-key card. A protocol so the coordinator is testable without a window.
@MainActor
protocol RivalKeyPresenting: AnyObject {
    func present(_ offer: RivalKeyOffer, switchKey: @escaping () -> Void, keepKey: @escaping () -> Void)
    func dismiss()
}

/// Tells the person, as soon as Hushy starts or a rival dictation app launches, that another app
/// may be listening on Hushy's key, and moves Hushy to another key in one click. It reads the list
/// of running apps and nothing else about them; it never touches a rival's settings.
@MainActor
final class RivalKeyCoordinator {
    private let settings: AppSettings
    private let presenter: any RivalKeyPresenting
    private let runningBundleIDs: () -> Set<String>
    private let log = Logger(subsystem: "app.hushy", category: "hotkey")
    private var observers: [NSObjectProtocol] = []
    /// The offer on screen, so the same pair is not drawn twice.
    private(set) var showing: RivalKeyOffer?

    init(settings: AppSettings, presenter: any RivalKeyPresenting,
         runningBundleIDs: @escaping () -> Set<String> = { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }) {
        self.settings = settings
        self.presenter = presenter
        self.runningBundleIDs = runningBundleIDs
    }

    /// Checks now (first run, or any launch of Hushy) and then on every app launch and quit.
    func start(workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        guard observers.isEmpty else { return }
        evaluate(running: runningBundleIDs())
        let launched = workspaceNotifications.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.appLaunched(bundleID: id) }
        }
        let quit = workspaceNotifications.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.appQuit(bundleID: id) }
        }
        observers = [launched, quit]
    }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        dismissCard()
    }

    /// The launch notice can arrive before the app shows in the running list, so it is added.
    func appLaunched(bundleID: String?) {
        evaluate(running: runningBundleIDs().union(bundleID.map { [$0] } ?? []))
    }

    /// The same for a quit that has not left the list yet. A card for an app that is gone closes.
    func appQuit(bundleID: String?) {
        evaluate(running: runningBundleIDs().subtracting(bundleID.map { [$0] } ?? []))
    }

    /// The person's one-click answer: Hushy moves to the suggested key. The change reaches the
    /// event tap through `SettingsSync`, the same path as the Settings picker.
    func switchKey() {
        guard let offer = showing else { return }
        guard settings.triggerKey == offer.current else { return dismissCard() }
        log.notice("shared key: switched from \(offer.current.rawValue, privacy: .public) to \(offer.suggested.rawValue, privacy: .public) for \(offer.rivals.map(\.id).joined(separator: ","), privacy: .public)")
        settings.triggerKey = offer.suggested
        dismissCard()
    }

    /// "Keep my key": remembered per rival, so only a different app brings the card back.
    func keepKey() {
        guard let offer = showing else { return }
        log.notice("shared key: kept \(offer.current.rawValue, privacy: .public) for \(offer.rivals.map(\.id).joined(separator: ","), privacy: .public)")
        settings.keptSharedKeyWith.formUnion(offer.rivals.map(\.id))
        dismissCard()
    }

    private func evaluate(running: Set<String>) {
        let offer = RivalDictationApps.offer(
            running: running, trigger: settings.triggerKey, dismissed: settings.keptSharedKeyWith)
        guard offer != showing else { return }
        guard let offer else { return dismissCard() }
        showing = offer
        log.notice("shared key: \(offer.rivals.map(\.id).joined(separator: ","), privacy: .public) may share \(offer.current.rawValue, privacy: .public)")
        presenter.present(offer, switchKey: { [weak self] in self?.switchKey() },
                          keepKey: { [weak self] in self?.keepKey() })
    }

    private func dismissCard() {
        guard showing != nil else { return }
        showing = nil
        presenter.dismiss()
    }
}
