import AppKit

/// Keeps exactly one live Hushy on the Mac. A second copy (a debug build from `.build`, a bundle
/// in a scratch folder, an agent's test launch) would register the same hotkey, capture the mic
/// and paste into the founder's apps — so a new instance yields to one that is already running.
/// Snapshot runs are exempt: they never call `AppModel.launch()` and hide themselves instead.
enum SingleInstance {
    struct RunningApp: Equatable {
        let pid: pid_t
        let bundleIdentifier: String?
        let executableName: String?
        /// The process is a pill preview (`--pill-preview`): the same binary, but no hotkey, no
        /// microphone and no pasting, so it is not "another Hushy" and nothing yields to it.
        var isPillPreview = false
    }

    static let bundleIdentifier = "app.hushy.Hushy"
    static let executableNames: Set<String> = ["Hushy", "Murmur"]

    /// The other live instance this process should yield to, if any.
    static func instanceToYieldTo(currentPID: pid_t, running: [RunningApp]) -> RunningApp? {
        running.first { app in
            guard app.pid != currentPID, !app.isPillPreview else { return false }
            if app.bundleIdentifier == bundleIdentifier { return true }
            return app.executableName.map(executableNames.contains) ?? false
        }
    }

    static func currentlyRunning() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map { app in
            let candidate = RunningApp(pid: app.processIdentifier, bundleIdentifier: app.bundleIdentifier,
                                       executableName: app.executableURL?.lastPathComponent)
            return marked(candidate, arguments: ProcessArguments.of(pid:))
        }
    }

    /// `app` with `isPillPreview` set from its launch arguments. Only a process that looks like
    /// Hushy is asked for them; one whose arguments cannot be read counts as a real Hushy.
    static func marked(_ app: RunningApp, arguments: (pid_t) -> [String]?) -> RunningApp {
        let looksLikeHushy = app.bundleIdentifier == bundleIdentifier || app.executableName.map(executableNames.contains) ?? false
        guard looksLikeHushy, let launched = arguments(app.pid) else { return app }
        var app = app
        app.isPillPreview = PillPreviewArguments.requested(launched)
        return app
    }

    /// Brings the existing instance forward and quits this one. Returns true when it yielded.
    @MainActor
    static func yieldIfAnotherInstanceIsRunning() -> Bool {
        let current = ProcessInfo.processInfo.processIdentifier
        guard let other = instanceToYieldTo(currentPID: current, running: currentlyRunning()) else { return false }
        NSRunningApplication(processIdentifier: other.pid)?.activate()
        NSApp.terminate(nil)
        return true
    }
}
