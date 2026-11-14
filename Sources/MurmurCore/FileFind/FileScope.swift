import Foundation

/// Where a file search may look, and what it never returns. The Spotlight query is scoped and
/// filtered the same way, but this runs on every result in code, whatever the finder did.
public enum FileScope {
    /// Folders directly under the home folder that are never searched.
    static let excludedTopLevel: Set<String> = ["library", "applications"]

    /// Folder names that are never searched, at any depth: caches and dependency folders, and
    /// Hushy's own folders.
    static let excludedAnywhere: Set<String> = ["node_modules", "caches", "deriveddata", "pods", "site-packages", "hushy"]

    /// Bundle-like folders whose insides are not the person's files.
    static let excludedExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "xcodeproj", "xcworkspace", "photoslibrary", "musiclibrary",
        "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "dsym", "kext", "lproj", "sparsebundle",
    ]

    /// True for a path outside `home`, under a hidden folder, under Library, inside an app
    /// bundle, a cache or a build folder, or inside one of Hushy's own folders.
    public static func isExcluded(path: String, home: String) -> Bool {
        let homePrefix = home.hasSuffix("/") ? home : home + "/"
        guard path.hasPrefix(homePrefix) else { return true }
        let relative = path.dropFirst(homePrefix.count)
        let parts = relative.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return true }
        // Every folder above the file, and the file itself when hidden or a bundle.
        for (index, part) in parts.enumerated() {
            if part.hasPrefix(".") { return true }
            let lowered = part.lowercased()
            let isLeaf = index == parts.count - 1
            if !isLeaf, excludedAnywhere.contains(lowered) { return true }
            if index == 0, excludedTopLevel.contains(lowered) { return true }
            let ext = (lowered as NSString).pathExtension
            if excludedExtensions.contains(ext) { return true }
        }
        return false
    }

    /// The folders a request searches: the one it names, or the home folder (the Library and
    /// the rest are cut by `isExcluded`).
    public static func roots(for location: FileLocation?, home: URL) -> [URL] {
        guard let location else { return [home] }
        return [home.appendingPathComponent(location.folderName, isDirectory: true)]
    }

    /// Files that run something when opened (scripts, installers, apps, workflows). Open never
    /// opens these; the card shows them in Finder instead.
    static let runsWhenOpened: Set<String> = [
        "command", "sh", "zsh", "bash", "csh", "tcsh", "fish", "tool", "app", "pkg", "mpkg", "dmg", "workflow",
        "action", "terminal", "scpt", "scptd", "applescript", "jar", "exe", "bat", "cmd", "msi", "run", "wflow",
        "osax", "saver", "prefpane", "service", "kext", "xpc", "url", "webloc", "inetloc", "fileloc", "py", "pl",
        "rb", "js", "ps1", "vbs",
    ]

    public static func runsWhenOpened(path: String) -> Bool {
        runsWhenOpened.contains((path as NSString).pathExtension.lowercased())
    }
}
