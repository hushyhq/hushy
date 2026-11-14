import Foundation
import Synchronization

/// What the Mac says about one installed app, from its own Info.plist: nothing else is read. The
/// name, bundle identifier and declared category are never logged, metered or sent anywhere; the
/// identifier is stored only where a tone setting already stores it (an app's own tone).
public struct InstalledAppInfo: Equatable, Sendable {
    public let bundleID: String
    public let name: String
    /// `LSApplicationCategoryType`, as the app declares it (for example "public.app-category.productivity").
    public let declaredCategory: String?

    public init(bundleID: String, name: String, declaredCategory: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.declaredCategory = declaredCategory
    }
}

/// Where an installed app that is not in the known table goes, decided from what it declares about itself.
///
/// Only a clear signal places an app. A category that does not say "somewhere you write" leaves the app
/// unplaced, and an unplaced app is never guessed into a kind: it shows under Everything else only once
/// the person has dictated into it or added it by hand.
///
///   declared category                         placed in
///   social-networking                         Personal messages
///   productivity                              Everything else
///   developer-tools, name reads as code       Code editors & terminals (no tone)
///   developer-tools, anything else            Everything else
///   utilities or none, name is a terminal or editor  Code editors & terminals (no tone)
///   every other category (business, games, graphics, music, video, finance, news, ...)  unplaced
///
/// A name alone never makes an app code. The name and the declared category must agree: an app that declares
/// a prose or social category ("Notes for Vim users", productivity) is placed by what it declares, because
/// losing cleanup in a prose app is as wrong as cleaning up a terminal. A name needs a category that does not
/// contradict it: developer tools, utilities (where many terminals sit) or none. The words are whole words, and
/// a weak word ("studio", "code") counts only inside a known tool name ("Android Studio", "RStudio", "Xcode",
/// "VS Code") and only for a declared developer tool, so "Studio Display" is not code.
///
/// Business is unplaced on purpose: it covers chat and meeting apps, but also accounting and CRM tools.
/// The known table places the chat and meeting apps people use (Slack, Teams, Zoom, Webex, Linear).
public enum DeclaredAppCategory {
    public static let socialNetworking = "public.app-category.social-networking"
    public static let productivity = "public.app-category.productivity"
    public static let developerTools = "public.app-category.developer-tools"

    public static let utilities = "public.app-category.utilities"

    /// The kind the app is offered under, or nil when it cannot be placed with confidence.
    public static func kind(for app: InstalledAppInfo) -> ToneKind? {
        let declared = app.declaredCategory
        let tokens = words(in: app)
        // The name and the declared category must agree before an unknown app is treated as code.
        if declared == nil || declared == utilities || declared == developerTools {
            if !Set(tokens).isDisjoint(with: strongCodeWords) || tokens.contains(where: isTermSuffixWord) { return .code }
            if declared == developerTools, namesCodeTool(tokens) { return .code }
        }
        switch declared {
        case socialNetworking: return .personalMessages
        case productivity, developerTools: return .everythingElse
        default: return nil
        }
    }

    /// Words that name a terminal or a text editor outright. Matched as whole words of the name and the identifier.
    private static let strongCodeWords: Set<String> = [
        "terminal", "shell", "tty", "vim", "neovim", "nvim", "emacs", "ssh",
    ]

    /// A terminal named like iTerm, xterm or WezTerm: a word that ends in "term" (optionally followed by a version
    /// digit) with something in front of it. The bare word "term" does not count ("Long Term Planner"), and neither
    /// does a time word in front ("longterm", "midterm").
    static func isTermSuffixWord(_ token: String) -> Bool {
        var word = Substring(token)
        while let last = word.last, last.isNumber { word = word.dropLast() }
        guard word.hasSuffix("term"), word.count > 4 else { return false }
        let prefix = String(word.dropLast(4))
        return !["long", "short", "mid", "near", "full", "half"].contains(prefix)
    }
    /// Whole words that name a code tool on their own, when the app declares itself a developer tool.
    private static let codeToolWords: Set<String> = ["code", "ide", "idea", "repl", "xcode", "vscode", "rstudio"]
    /// Weak words ("studio", "editor") that name a code tool only next to one of these.
    private static let codeToolQualifiers: [String: Set<String>] = [
        "studio": ["android", "visual", "r", "arduino", "unity", "flutter"],
        "editor": ["code", "text", "source"],
    ]

    private static func namesCodeTool(_ tokens: [String]) -> Bool {
        if !Set(tokens).isDisjoint(with: codeToolWords) { return true }
        for (index, token) in tokens.enumerated() {
            guard let qualifiers = codeToolQualifiers[token] else { continue }
            let neighbours = [index > 0 ? tokens[index - 1] : nil, index + 1 < tokens.count ? tokens[index + 1] : nil]
            if neighbours.contains(where: { $0.map(qualifiers.contains) ?? false }) { return true }
        }
        return false
    }

    /// The whole words of the app's name and identifier, in order, lower-case. camelCase is split ("iTerm", "MacVim").
    private static func words(in app: InstalledAppInfo) -> [String] {
        let text = "\(app.name) \(app.bundleID)"
        var spaced = ""
        var previous: Character = " "
        for character in text {
            if character.isUppercase, previous.isLowercase { spaced.append(" ") }
            spaced.append(character)
            previous = character
        }
        return spaced.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}

/// What the classifier knows about apps its own table does not: a social app, or a code tool that must never be
/// given a tone. Held in memory only. Empty until the first look finishes, and then the classifier behaves exactly
/// as it always did for every app it knows.
///
/// Three sources; they never contradict each other because they all come from
/// `DeclaredAppCategory`.
/// - `scanned`: the result of the latest full look. A new look replaces only this.
/// - `added`: apps that started running, read one by one. Kept when a look finishes, so an app that launched
///   while a look was running (an editor outside the scanned folders) is never forgotten by that look. A later
///   look drops the ones whose app no longer exists (`forget`).
/// - `pending`: an app that has just started and whose Info.plist has not been read yet. For these few
///   milliseconds the classifier answers "code", which means no tone: text left as spoken is always acceptable,
///   and a terminal must never be given a tone. The answer is replaced as soon as the read finishes, or dropped
///   if the read fails.
public enum DiscoveredAppKinds {
    private struct State {
        var scanned: [String: AppCategory] = [:]
        var scannedIDs: Set<String> = []
        var added: [String: AppCategory] = [:]
        var addedIDs: Set<String> = []
        /// Reads still outstanding per identifier: two launches of one app can both be pending.
        var pending: [String: Int] = [:]
    }

    private static let state = Mutex(State())

    /// Replaces the result of the last full look. Apps added since stay.
    public static func replace(with apps: [InstalledAppInfo]) {
        let entries = entries(for: apps)
        let ids = Set(apps.map { $0.bundleID.lowercased() })
        state.withLock { $0.scanned = entries; $0.scannedIDs = ids }
    }

    /// Adds one app, for one that has just started running; it also ends its pending answer (a successful read
    /// settles the app, whatever other reads of it are still running).
    public static func add(_ app: InstalledAppInfo) {
        let entries = entries(for: [app])
        let id = app.bundleID.lowercased()
        state.withLock { state in
            state.added.merge(entries) { _, new in new }
            state.addedIDs.insert(id)
            state.pending[id] = nil
        }
    }

    /// An app has started running and its Info.plist is about to be read (cheap, safe on any thread). Counts one
    /// outstanding read for the app. Returns false, and counts nothing, for an app already decided.
    @discardableResult
    public static func markPending(bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return state.withLock { state in
            guard !state.scannedIDs.contains(id), !state.addedIDs.contains(id) else { return false }
            state.pending[id, default: 0] += 1
            return true
        }
    }

    /// One read ended without an answer (no Info.plist, or too large). The app stays pending until its LAST
    /// outstanding read ends this way; after that it is an ordinary app.
    public static func finishPending(bundleID: String) {
        let id = bundleID.lowercased()
        state.withLock { state in
            guard let count = state.pending[id] else { return }
            state.pending[id] = count > 1 ? count - 1 : nil
        }
    }

    /// Forgets apps that were added one by one and no longer exist. A later look decides about them if they are
    /// still installed.
    public static func forget(bundleIDs: Set<String>) {
        let ids = Set(bundleIDs.map { $0.lowercased() })
        state.withLock { state in
            for id in ids { state.added[id] = nil; state.addedIDs.remove(id) }
        }
    }

    /// Forgets everything. For tests.
    public static func reset() {
        state.withLock { $0 = State() }
    }

    public static func category(forLowercasedID id: String) -> AppCategory? {
        state.withLock { $0.added[id] ?? $0.scanned[id] ?? ($0.pending[id] != nil ? .code : nil) }
    }

    private static func entries(for apps: [InstalledAppInfo]) -> [String: AppCategory] {
        var result: [String: AppCategory] = [:]
        for app in apps where !AppCategory.isBrowser(app.bundleID) {
            switch DeclaredAppCategory.kind(for: app) {
            case .code: result[app.bundleID.lowercased()] = .code
            case .personalMessages: result[app.bundleID.lowercased()] = .personalMessages
            default: break
            }
        }
        return result
    }
}

/// Reads the installed apps' own Info.plist files, folder by folder, off the main thread. No permission is
/// involved (these folders are readable by every app), nothing is kept on disk, and nothing is sent.
///
/// Bounded on purpose, so a strange folder cannot make the look slow or large:
/// - `maxPlistBytes` (512 KiB): an Info.plist larger than this is not read. Real ones are a few KiB to about
///   100 KiB; the app is then an ordinary, unplaced one.
/// - `maxEntriesPerFolder` (2,000): at most this many entries are looked at in any one folder.
/// - `maxSubfolders` (40): at most this many sub-folders (Utilities and the like) are opened per root, one level only.
public enum InstalledAppScanner {
    public static let maxPlistBytes = 512 * 1024
    public static let maxEntriesPerFolder = 2_000
    public static let maxSubfolders = 40

    public static func defaultRoots() -> [URL] {
        [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }

    /// Every app found in the roots and one folder level below each (Utilities and the like); the first copy of an
    /// identifier wins when two exist.
    public static func scan(
        roots: [URL] = defaultRoots(), fileManager: FileManager = .default,
        maxEntries: Int = maxEntriesPerFolder, maxFolders: Int = maxSubfolders
    ) -> [InstalledAppInfo] {
        var seen = Set<String>()
        var result: [InstalledAppInfo] = []
        for root in roots {
            for url in appBundles(in: root, fileManager: fileManager, maxEntries: maxEntries, maxFolders: maxFolders) {
                guard let info = read(url), seen.insert(info.bundleID).inserted else { continue }
                result.append(info)
            }
        }
        return result
    }

    /// The entries of one folder, at most `maxEntriesPerFolder`, never descending.
    private static func entries(of folder: URL, fileManager: FileManager, maxEntries: Int) -> [(url: URL, isFolder: Bool)] {
        guard let enumerator = fileManager.enumerator(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]) else { return [] }
        var result: [(URL, Bool)] = []
        for case let url as URL in enumerator {
            if result.count >= maxEntries { break }
            result.append((url, (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true))
        }
        return result.sorted { $0.0.lastPathComponent < $1.0.lastPathComponent }
    }

    private static func appBundles(in root: URL, fileManager: FileManager, maxEntries: Int, maxFolders: Int) -> [URL] {
        var bundles: [URL] = []
        var opened = 0
        for child in entries(of: root, fileManager: fileManager, maxEntries: maxEntries) {
            if child.url.pathExtension == "app" {
                bundles.append(child.url)
            } else if child.isFolder, opened < maxFolders {
                opened += 1
                bundles += entries(of: child.url, fileManager: fileManager, maxEntries: maxEntries).map(\.url).filter { $0.pathExtension == "app" }
            }
        }
        return bundles
    }

    /// One app's Info.plist, or nil for an app with no identifier, one that never has a window, or a plist larger
    /// than `maxPlistBytes`. Does file work: call it off the main thread.
    public static func read(_ appURL: URL) -> InstalledAppInfo? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let size = (try? plistURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxPlistBytes,
              let data = try? Data(contentsOf: plistURL, options: .mappedIfSafe),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = plist["CFBundleIdentifier"] as? String, !id.isEmpty else { return nil }
        if plist["LSBackgroundOnly"] as? Bool == true || plist["LSBackgroundOnly"] as? String == "1" { return nil }
        let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        return InstalledAppInfo(bundleID: id, name: name, declaredCategory: plist["LSApplicationCategoryType"] as? String)
    }
}

/// The apps installed on this Mac, as the tone screens and the classifier need them. The list is held in memory
/// only; nothing about the apps is logged, counted, stored on disk or sent.
///
/// A full look runs off the caller's thread (`refresh`), at most once in `maxAge`. An app that starts running is
/// added at once (`noteLaunched`): its name is marked pending synchronously (the classifier then answers "code",
/// which gives no tone, until the read ends), and its Info.plist is read on a background task. Publishing the
/// result of a full look keeps every app added while the look was running.
public final class InstalledAppCatalog: Sendable {
    private struct State {
        var scanned: [InstalledAppInfo] = []
        /// Apps that started running, with the place they were launched from, so a later look can see they are gone.
        var launched: [(info: InstalledAppInfo, url: URL)] = []
        var lastLook: Date?
        var isLooking = false
    }

    private let state = Mutex(State())
    private let scan: @Sendable () -> [InstalledAppInfo]
    private let read: @Sendable (URL) -> InstalledAppInfo?
    private let exists: @Sendable (URL) -> Bool
    /// A full look is repeated at most this often, however many screens ask.
    public static let maxAge: TimeInterval = 60

    public init(
        scan: @escaping @Sendable () -> [InstalledAppInfo] = { InstalledAppScanner.scan() },
        read: @escaping @Sendable (URL) -> InstalledAppInfo? = { InstalledAppScanner.read($0) },
        exists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) {
        self.scan = scan
        self.read = read
        self.exists = exists
    }

    /// The last look plus the apps that started since, at once and without file work.
    public func snapshot() -> [InstalledAppInfo] {
        state.withLock { state in
            let known = Set(state.scanned.map(\.bundleID))
            return state.scanned + state.launched.map(\.info).filter { !known.contains($0.bundleID) }
        }
    }

    /// Looks again unless a recent look exists. Returns whether the list changed.
    @discardableResult
    public func refresh(now: @Sendable () -> Date = { Date() }) async -> Bool {
        let shouldLook = state.withLock { state -> Bool in
            if state.isLooking { return false }
            if let last = state.lastLook, now().timeIntervalSince(last) < Self.maxAge { return false }
            state.isLooking = true
            return true
        }
        guard shouldLook else { return false }
        let scan = self.scan
        let exists = self.exists
        let launched = state.withLock { $0.launched }
        // File work, off the caller: the look itself, and whether each app that started earlier still exists.
        let (found, gone) = await Task.detached(priority: .utility) {
            (scan(), Set(launched.filter { !exists($0.url) }.map(\.info.bundleID)))
        }.value
        // Replaces the scanned part only: apps added while the look was running stay known. Apps that started
        // earlier and are gone are dropped (their saved tone stays in the setting).
        DiscoveredAppKinds.replace(with: found)
        DiscoveredAppKinds.forget(bundleIDs: gone.subtracting(found.map(\.bundleID)))
        return state.withLock { state in
            state.launched.removeAll { gone.contains($0.info.bundleID) }
            let changed = state.scanned != found
            state.scanned = found
            state.lastLook = now()
            state.isLooking = false
            return changed
        }
    }

    /// An app has started running. Cheap and safe on any thread, including the main one: the file read happens on
    /// a background task, and until it ends the classifier gives the app no tone.
    @discardableResult
    public func noteLaunched(bundleID: String, at url: URL) -> Task<Void, Never> {
        let marked = DiscoveredAppKinds.markPending(bundleID: bundleID)
        let read = self.read
        return Task.detached(priority: .userInitiated) { [self] in
            guard let info = read(url) else {
                if marked { DiscoveredAppKinds.finishPending(bundleID: bundleID) }
                return
            }
            DiscoveredAppKinds.add(info)
            state.withLock { state in
                state.launched.removeAll { $0.info.bundleID == info.bundleID }
                state.launched.append((info, url))
            }
        }
    }
}
