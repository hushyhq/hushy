import AppKit
import MurmurCore
import SwiftUI

/// Which apps are installed, asked by identifier through Launch Services. No folder is scanned and
/// no permission is involved; only the known writing apps are ever asked about.
struct SystemInstalledApps: InstalledApps {
    func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    func displayName(_ bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// The last look at the installed apps (`AppCatalog`), which screens refresh off the main thread.
    func discoveredApps() -> [InstalledAppInfo] { InstalledAppCatalog.shared.snapshot() }
}

/// A fixed set of installed apps, for snapshots.
struct FixedInstalledApps: InstalledApps {
    let ids: Set<String>
    var names: [String: String] = [:]
    /// Apps found by looking, as opposed to asked for by identifier.
    var found: [InstalledAppInfo] = []
    func discoveredApps() -> [InstalledAppInfo] { found }
    func isInstalled(_ bundleID: String) -> Bool { ids.contains(bundleID) || found.contains { $0.bundleID == bundleID } }
    func displayName(_ bundleID: String) -> String? {
        found.first { $0.bundleID == bundleID }?.name ?? (ids.contains(bundleID) ? (names[bundleID] ?? bundleID) : nil)
    }
}
