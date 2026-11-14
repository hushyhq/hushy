#if DEBUG
import Foundation
import MurmurCore

/// Rules that keep a run from writing anywhere outside the temp home. They are checked on the real
/// settings object, after the rig has configured it and before any scenario starts.
enum MockMicIsolation {
    /// What a note's finish would write outside the throwaway folder. Empty means isolated.
    static func exportViolations(exportsMarkdown: Bool, savesToAppleNotes: Bool,
                                 exportDirectory: URL, home: URL) -> [String] {
        var found: [String] = []
        if exportsMarkdown { found.append("Markdown export of finished notes is on") }
        if savesToAppleNotes { found.append("saving notes to Apple Notes is on") }
        if !isInside(exportDirectory, home) {
            found.append("the export folder is outside the temp home (\(exportDirectory.lastPathComponent))")
        }
        return found
    }

    /// The features the scenarios rely on must be free, so no entitlement check reads the Keychain
    /// (`app.hushy.account`) or the invite and debug-unlock defaults. A feature that stops being free stops the run.
    static func entitlementViolations(_ features: [ProFeature] = required) -> [String] {
        features.filter { !$0.isFree }.map { "\($0.rawValue) is not free, so checking it would read the Keychain and defaults" }
    }

    static let required: [ProFeature] = [.speakerLabels, .voiceSignatures, .systemAudio]

    static func isInside(_ child: URL, _ parent: URL) -> Bool {
        let childPath = canonicalPath(child)
        let parentPath = canonicalPath(parent)
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }

    /// Symlinks resolved on the deepest folder that exists, then the rest appended, so a folder that is
    /// not created yet (and `/private/...` spellings of `/tmp` and `/var`) compare the same as one that is.
    private static func canonicalPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        return rest.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
    }
}

/// The throwaway defaults suites a run creates (`app.hushy.mockmic.<pid>.<uuid>`). A run that is killed
/// or crashes cannot remove its own, so the next run removes those whose process is gone.
enum MockMicSuites {
    static let prefix = "app.hushy.mockmic."

    static func name(pid: Int32 = getpid()) -> String { "\(prefix)\(pid).\(UUID().uuidString)" }

    /// The throwaway suite of a run: an absolute path inside the temp home, so its preferences file lives
    /// there and goes with the home, and nothing is written to `~/Library/Preferences`.
    static func path(in home: URL) -> String { home.appendingPathComponent("mock-mic-defaults").path }

    /// Clears a path-named suite and deletes its file. Only a path ending in the suite's own name is touched.
    static func removePath(_ suite: String) {
        guard suite.hasSuffix("/mock-mic-defaults") else { return }
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(atPath: suite + ".plist")
    }

    /// The process that created `suite`; `nil` for the older name without one, which nothing owns.
    static func ownerPID(of suite: String) -> Int32? {
        guard suite.hasPrefix(prefix) else { return nil }
        let rest = suite.dropFirst(prefix.count)
        guard let dot = rest.firstIndex(of: ".") else { return nil }
        return Int32(rest[rest.startIndex..<dot])
    }

    /// Suites among the preference file names (`<suite>.plist`) that no live run owns.
    static func stale(inFiles files: [String], isAlive: (Int32) -> Bool) -> [String] {
        files.compactMap { file -> String? in
            guard file.hasPrefix(prefix), file.hasSuffix(".plist") else { return nil }
            let suite = String(file.dropLast(".plist".count))
            if let pid = ownerPID(of: suite), isAlive(pid) { return nil }
            return suite
        }
    }

    static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    /// Removes stale suites. Only the file names in the preferences folder are read, never their contents.
    @discardableResult
    static func sweep() -> Int {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return 0 }
        let folder = library.appendingPathComponent("Preferences", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let suites = stale(inFiles: files, isAlive: isAlive)
        for suite in suites { remove(suite) }
        return suites.count
    }

    /// Clears one of our suites and deletes its (now empty) preferences file, which `removePersistentDomain`
    /// alone leaves behind. Only a name with our prefix is ever touched.
    static func remove(_ suite: String) {
        guard suite.hasPrefix(prefix), !suite.contains("/") else { return }
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let file = library.appendingPathComponent("Preferences/\(suite).plist")
        try? FileManager.default.removeItem(at: file)
    }
}
#endif
