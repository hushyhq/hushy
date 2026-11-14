import AppKit
import CoreServices
import MurmurCore

/// The Mac side of `InstalledAppCatalog`: it starts the first look and listens for apps that start running.
/// Nothing about the apps is logged, counted, stored on disk or sent. The notification handler does no file
/// work: it marks the app pending (the classifier gives it no tone for the few milliseconds the read takes) and
/// hands the Info.plist read to a background task.
extension InstalledAppCatalog {
    static let shared = InstalledAppCatalog()

    func start() {
        Task { await refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil
        ) { [self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier, let url = app.bundleURL else { return }
            noteLaunched(bundleID: id, at: url)
        }
    }
}

/// The Mac side of `RankedInstalledApps`: what the person actually uses, read once a day. Reads dictation counts per
/// app and day from History (never text), the date Launch Services last saw each app opened (Spotlight metadata, no
/// permission), and the apps running now. Nothing is logged, stored or sent.
extension RankedInstalledApps {
    static let shared = RankedInstalledApps()

    func start(store: Store) {
        Task { await refreshIfStale(store: store) }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil
        ) { [self] note in
            guard let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            else { return }
            noteRunning(id)
        }
    }

    /// Reads the signals if they are over a day old. Safe to call at every key-down: a fresh answer costs a lock.
    func refreshIfStale(store: Store, catalog: InstalledAppCatalog = .shared) async {
        guard beginReload() else { return }
        let installed = catalog.snapshot().map(\.bundleID)
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let signals = await Task.detached(priority: .utility) { () -> InstalledNameSignals? in
            guard let days = try? store.appUseDays() else { return nil }
            return InstalledNameSignals(
                dictationDays: days, lastOpened: Self.lastOpenedDates(of: installed), running: running)
        }.value
        if let signals { load(signals) } else { abandonReload() }
    }

    /// Spotlight's last-used date per installed app. Does file-index work: call it off the main thread.
    private static func lastOpenedDates(of bundleIDs: [String]) -> [String: Date] {
        var dates: [String: Date] = [:]
        for id in bundleIDs {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
                  let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL),
                  let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date else { continue }
            dates[id] = date
        }
        return dates
    }
}
