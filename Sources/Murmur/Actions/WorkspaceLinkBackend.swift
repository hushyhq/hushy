import AppKit
import MurmurCore
import OSLog

/// Opens links and apps through `NSWorkspace` (`ProposedAction.Kind.openLink`). The default
/// browser opens links unless the user named one ("open gmail in safari"); an unknown browser
/// name falls back to the default rather than failing. Navigation only: nothing on the page is
/// read, clicked or typed into.
struct WorkspaceLinkBackend: LinkOpeningBackend {
    static let log = Logger(subsystem: "app.hushy", category: "voice-actions")

    /// Spoken browser names → bundle identifiers.
    static let browsers: [String: String] = [
        "safari": "com.apple.Safari",
        "chrome": "com.google.Chrome",
        "arc": "company.thebrowser.Browser",
        "firefox": "org.mozilla.firefox",
        "edge": "com.microsoft.edgemac",
        "brave": "com.brave.Browser",
    ]

    func open(url: URL, browser: String?) async throws -> String? {
        let workspace = NSWorkspace.shared
        if let browser, let bundleID = Self.browsers[browser.lowercased()],
           let app = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            do {
                _ = try await workspace.open([url], withApplicationAt: app, configuration: configuration)
                return nil
            } catch {
                // The named browser couldn't take it; the default browser still can, and the
                // done chip says so (below) rather than letting it pass as the one asked for.
            }
        }
        guard workspace.open(url) else { throw ActionExecutionError.backendFailed("Couldn't open \(url.host ?? "the link")") }
        return browser == nil ? nil : "your default browser"
    }

    func openApp(named name: String) async throws {
        let workspace = NSWorkspace.shared
        // Regular apps only: a helper process ("Google Chrome Helper") has nothing to bring forward.
        let runningApps = workspace.runningApplications.compactMap { app -> (NSRunningApplication, AppNameMatcher.Candidate)? in
            guard app.activationPolicy == .regular, let name = app.localizedName else { return nil }
            return (app, .init(name: name, bundleID: app.bundleIdentifier))
        }
        let running = AppNameMatcher.best(spoken: name, among: runningApps.map(\.1))
            .flatMap { match in runningApps.first(where: { $0.1 == match })?.0 }
        // A running app goes through Launch Services too. `NSRunningApplication.activate()` is
        // ignored unless the caller is the active app, which Hushy never is while the pill is up.
        guard let appURL = running?.bundleURL ?? Self.applicationURL(named: name) else {
            throw Self.noConfidentApp(heard: name, running: runningApps.map(\.1))
        }
        // A fixed category only: the spoken name and the matched app never go to the log.
        Self.log.info("open app: matched an installed app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await workspace.openApplication(at: appURL, configuration: configuration)
        } catch {
            throw ActionExecutionError.backendFailed("Couldn't open \(name)")
        }
        // Launch Services reports success once the app is running, not once it is in front, so
        // check before the pill says "Opened". A cold launch is trusted: it can take seconds.
        guard let running else { return }
        if await Self.cameToFront(running.processIdentifier) { return }
        running.activate()
        guard await Self.cameToFront(running.processIdentifier, within: .milliseconds(500)) else {
            throw ActionExecutionError.backendFailed("Couldn't bring \(name) to the front")
        }
    }

    static func cameToFront(_ pid: pid_t, within timeout: Duration = .milliseconds(1500)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    /// Find an installed app without trusting the spoken text as a path. Launch Services handles
    /// the common fixed bundle IDs; scanning covers renamed/nonstandard apps such as Antigravity.
    static func applicationURL(named name: String, folders: [URL] = applicationFolders) -> URL? {
        let workspace = NSWorkspace.shared
        if let bundleID = AppNameMatcher.knownBundleID(for: name),
           let url = workspace.urlForApplication(withBundleIdentifier: bundleID) { return url }
        let apps = installedApps(folders: folders)
        guard let match = AppNameMatcher.best(spoken: name, among: apps.map(\.0)) else { return nil }
        return apps.first(where: { $0.0 == match })?.1
    }

    /// Whether a spoken name could be an app on this Mac: one the matcher knows, or one that is
    /// installed or running and at least close. False when nothing resembles it, which means the
    /// sentence was probably not "open <app>" at all.
    static func recognisesApp(
        heard name: String, running: [AppNameMatcher.Candidate]? = nil, folders: [URL] = applicationFolders
    ) -> Bool {
        if AppNameMatcher.knownBundleID(for: name) != nil { return true }
        let running = running ?? NSWorkspace.shared.runningApplications.compactMap { app -> AppNameMatcher.Candidate? in
            guard app.activationPolicy == .regular, let appName = app.localizedName else { return nil }
            return .init(name: appName, bundleID: app.bundleIdentifier)
        }
        let known = running + installedApps(folders: folders).map(\.0)
        if case .nothingClose = AppNameMatcher.resolve(spoken: name, among: known) { return false }
        return true
    }

    /// Nothing was sure: the closest apps among the running and installed ones, or plain
    /// "not found" when none is close (`AppNameMatcher.resolve`).
    static func noConfidentApp(
        heard name: String, running: [AppNameMatcher.Candidate], folders: [URL] = applicationFolders
    ) -> ActionExecutionError {
        let known = running + installedApps(folders: folders).map(\.0)
        switch AppNameMatcher.resolve(spoken: name, among: known) {
        case .confident(let match): return .closestApps(heard: name, apps: [match.name])
        case .suggestions(let list): return .closestApps(heard: name, apps: list.map(\.name))
        case .nothingClose: return .notFound(name)
        }
    }

    /// Every `.app` directly in the folders, and one level down (`/Applications/Setapp/Foo.app`),
    /// without a recursive scan.
    static func installedApps(folders: [URL] = applicationFolders) -> [(AppNameMatcher.Candidate, URL)] {
        var apps: [(AppNameMatcher.Candidate, URL)] = []
        for folder in folders {
            guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for item in items {
                if item.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                    apps.append((.init(name: item.deletingPathExtension().lastPathComponent), item))
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          let children = try? FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                    for app in children where app.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                        apps.append((.init(name: app.deletingPathExtension().lastPathComponent), app))
                    }
                }
            }
        }
        return apps
    }

    static let applicationFolders = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: "/System/Applications/Utilities"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ]
}
