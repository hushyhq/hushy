import AppKit
import Foundation
import Sparkle

/// "Check for Updates…" (app menu, Settings → About). Sparkle 2 is linked and wired, but
/// stays inert until the build carries a real appcast URL and EdDSA public key — see
/// docs/guide/RELEASE.md. An unconfigured build never starts Sparkle's updater (which would
/// log errors and, via `SPUStandardUpdaterController`, show a "contact the developer" alert);
/// it explains instead.
@MainActor
protocol UpdateChecker: AnyObject {
    /// True when this build can actually reach an appcast.
    var isConfigured: Bool { get }
    /// One line for Settings → About: what will happen when the user clicks the button.
    var statusText: String { get }
    /// "Install updates automatically": new versions download in the background and Hushy asks
    /// once to relaunch. Sparkle keeps the choice (`SUAutomaticallyUpdate`); the build's
    /// Info.plist makes it on by default. Always false when the build has no update feed.
    var installsAutomatically: Bool { get set }
    /// Runs a user-initiated check, or explains why it can't.
    func checkForUpdates()
}

/// The Sparkle keys as they appear in this build's Info.plist, validated. Pure and
/// dependency-free so the "is this build configured?" rule is unit-testable.
struct UpdateFeedConfiguration: Equatable {
    static let feedURLKey = "SUFeedURL"
    static let publicKeyKey = "SUPublicEDKey"
    /// `Resources/Info.plist` ships these tokens; `scripts/build-app.sh` substitutes them from
    /// `HUSHY_APPCAST_URL` / `HUSHY_SPARKLE_PUBLIC_KEY` (or leaves them empty).
    static let placeholderPrefix = "__"

    let feedURL: URL?
    let publicKey: String?

    init(feedURL: String?, publicKey: String?) {
        self.feedURL = Self.validFeedURL(feedURL)
        self.publicKey = Self.validPublicKey(publicKey)
    }

    init(infoDictionary: [String: Any]?) {
        self.init(
            feedURL: infoDictionary?[Self.feedURLKey] as? String,
            publicKey: infoDictionary?[Self.publicKeyKey] as? String)
    }

    var isConfigured: Bool { feedURL != nil && publicKey != nil }

    private static func validFeedURL(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              !raw.hasPrefix(placeholderPrefix),
              let url = URL(string: raw), url.scheme == "https", url.host != nil
        else { return nil }
        return url
    }

    /// Sparkle's EdDSA public keys are 32 bytes, base64-encoded (44 characters).
    private static func validPublicKey(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              !raw.hasPrefix(placeholderPrefix),
              let data = Data(base64Encoded: raw), data.count == 32
        else { return nil }
        return raw
    }
}

/// Sparkle-backed checker. Constructed only for a configured build (see `make(for:)`).
///
/// Updates are found on Sparkle's schedule and, with "Install updates automatically" on,
/// downloaded and staged without any window. Sparkle then tells its delegate the update will
/// install when Hushy quits; that is where the relaunch prompt comes from. The standard user
/// driver still handles everything else: a person's own "Check for Updates…", and the ask-first
/// flow when the switch is off or Hushy can't replace itself.
@MainActor
final class SparkleUpdateChecker: NSObject, UpdateChecker, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    private let pending: PendingUpdateCoordinator
    private(set) var isConfigured = false
    private var startError: String?

    /// Returns a working Sparkle checker when the bundle is configured and the updater starts,
    /// otherwise an `UnconfiguredUpdateChecker` carrying the reason. Never throws, never alerts.
    static func make(for bundle: Bundle = .main) -> any UpdateChecker {
        let configuration = UpdateFeedConfiguration(infoDictionary: bundle.infoDictionary)
        guard configuration.isConfigured else { return UnconfiguredUpdateChecker() }
        return SparkleUpdateChecker(presenter: UpdateReadyPanelPresenter())
    }

    private init(presenter: any UpdateReadyPresenting) {
        pending = PendingUpdateCoordinator(presenter: presenter)
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        do {
            try controller.updater.start()
            isConfigured = true
        } catch {
            // Misconfigured feed/key: stay inert and report, rather than letting Sparkle alert.
            NSLog("Hushy: Sparkle updater failed to start: \(error.localizedDescription)")
            startError = error.localizedDescription
        }
    }

    var installsAutomatically: Bool {
        get { isConfigured && controller.updater.automaticallyDownloadsUpdates }
        set {
            guard isConfigured else { return }
            if newValue { controller.updater.automaticallyChecksForUpdates = true }
            controller.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    var statusText: String {
        if let startError { return "Updates couldn't start: \(startError)" }
        return UpdateCopy.statusText(
            installsAutomatically: installsAutomatically,
            checksAutomatically: controller.updater.automaticallyChecksForUpdates)
    }

    func checkForUpdates() {
        guard isConfigured else {
            UnconfiguredUpdateChecker.explain(detail: startError)
            return
        }
        if pending.remindIfPending() { return }
        controller.checkForUpdates(nil)
    }

    // MARK: SPUUpdaterDelegate

    /// An update was downloaded in the background and is staged to install when Hushy quits.
    /// Taking it over means Sparkle shows nothing itself; we ask once whether to relaunch now.
    func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let notes = UpdateReleaseNotes.make(
            description: item.itemDescription, format: item.itemDescriptionFormat,
            link: item.releaseNotesURL ?? item.fullReleaseNotesURL)
        pending.updateReady(UpdateReadyPrompt(notes: notes), install: immediateInstallHandler)
        return true
    }
}

/// Dev/unsigned builds, and any build whose Info.plist still carries the placeholders.
@MainActor
final class UnconfiguredUpdateChecker: UpdateChecker {
    static let message = "Updates aren't configured in this build"

    var isConfigured: Bool { false }
    var installsAutomatically: Bool {
        get { false }
        set {}
    }
    var statusText: String { "\(Self.message). Release builds check for updates with Sparkle." }

    func checkForUpdates() { Self.explain(detail: nil) }

    static func explain(detail: String?) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
            ?? "This copy of Hushy has no update feed. Download new versions from where you got this one."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }
}
