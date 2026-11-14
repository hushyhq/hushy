import Foundation
@testable import MurmurCore

/// A throwaway home folder under the temporary directory, removed by `remove()`.
struct UninstallTestHome {
    static let bundleIdentifier = "app.hushy.Hushy"
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hushy-uninstall-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    var library: URL { home.appendingPathComponent("Library", isDirectory: true) }
    var support: URL { library.appendingPathComponent("Application Support/Hushy", isDirectory: true) }
    var speechModels: URL { library.appendingPathComponent("Application Support/FluidAudio/Models", isDirectory: true) }
    var export: URL { home.appendingPathComponent("Documents/Hushy", isDirectory: true) }
    var bundle: URL { home.appendingPathComponent("Applications/Hushy.app", isDirectory: true) }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func roots(
        support: URL? = nil, overridden: Bool = false, bundle: URL?? = .none, export: URL? = nil,
        speech: [String] = ["parakeet-one", "parakeet-two"], removesSpeechModels: Bool = true,
        resetsPermissions: Bool = true, isTestRun: Bool = false
    ) -> UninstallRoots {
        UninstallRoots(
            home: home, supportDirectory: support ?? self.support, supportIsOverridden: overridden,
            bundleIdentifier: Self.bundleIdentifier, bundleURL: bundle ?? self.bundle,
            exportDirectory: export ?? self.export, speechModelFolderNames: speech,
            removesSpeechModels: removesSpeechModels, resetsPermissions: resetsPermissions, isTestRun: isTestRun)
    }

    /// Writes a small file with invented content, creating the folders above it.
    @discardableResult
    func write(_ relativePath: String, in base: URL? = nil, bytes: Int = 16) throws -> URL {
        let url = (base ?? home).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
}

/// Records every non-file operation instead of doing it. `failing` names the calls that throw.
final class UninstallOperationLog: @unchecked Sendable {
    struct Failure: Error, LocalizedError {
        let errorDescription: String? = "It is in use."
    }

    private let lock = NSLock()
    private var recorded: [String] = []
    var failing: Set<String> = []
    var bundleIdentifier: String? = UninstallTestHome.bundleIdentifier
    /// True when the sign-out forgets the account on this Mac but the server does not answer.
    var signOutIsUnconfirmed = false

    var calls: [String] { lock.withLock { recorded } }

    private func record(_ call: String) throws {
        lock.withLock { recorded.append(call) }
        if failing.contains(call) { throw Failure() }
    }

    var operations: UninstallOperations {
        UninstallOperations(
            stopActivity: { try self.record("stop") },
            resumeActivity: { try? self.record("resume") },
            signOut: {
                try self.record("signOut")
                if self.signOutIsUnconfirmed { throw UninstallSignOutNotConfirmed() }
            },
            unregisterLoginItem: { try self.record("loginItem") },
            clearNotifications: { try self.record("notifications") },
            deleteKeychainItems: { try self.record("keychain:\($0)") },
            clearDefaults: { try self.record("defaults:\($0)") },
            bundleIdentifier: { _ in self.bundleIdentifier },
            moveToTrash: { try self.record("trash:\($0.path)") },
            resetPermissions: { try self.record("tccutil:\($0)") })
    }
}

/// An in-memory disk: paths and what is at them.
final class FakeUninstallFileSystem: UninstallFileSystem, @unchecked Sendable {
    struct Failure: Error, LocalizedError {
        let errorDescription: String? = "You do not have permission."
    }

    private let lock = NSLock()
    private var kinds: [String: UninstallItemKind]
    private var removedPaths: [String] = []
    var failing: Set<String> = []
    var sizes: [String: Int64] = [:]
    /// Paths that are really another path: a link, or the same folder written in another case.
    /// The longest matching start of a path is replaced.
    var realPaths: [String: String] = [:]

    init(_ kinds: [String: UninstallItemKind]) {
        self.kinds = kinds
    }

    func canonical(_ url: URL) -> URL {
        let path = url.path
        let match = realPaths.keys.filter { path == $0 || path.hasPrefix($0 + "/") }.max { $0.count < $1.count }
        guard let match, let real = realPaths[match] else { return url }
        return URL(fileURLWithPath: real + path.dropFirst(match.count), isDirectory: false)
    }

    var removed: [String] { lock.withLock { removedPaths } }
    var remaining: Set<String> { lock.withLock { Set(kinds.keys) } }

    func kind(of url: URL) -> UninstallItemKind { lock.withLock { kinds[url.path] ?? .missing } }

    func resolvingLinks(_ url: URL) -> URL { url }

    func removeItem(at url: URL) throws {
        if failing.contains(url.path) { throw Failure() }
        lock.withLock {
            kinds = kinds.filter { $0.key != url.path && !$0.key.hasPrefix(url.path + "/") }
            removedPaths.append(url.path)
        }
    }

    func removeFolderIfEmpty(at url: URL) throws -> Bool {
        try lock.withLock {
            if failing.contains(url.path) { throw Failure() }
            guard !kinds.keys.contains(where: { $0.hasPrefix(url.path + "/") }) else { return false }
            kinds[url.path] = nil
            removedPaths.append(url.path)
            return true
        }
    }

    func byteSize(of url: URL) -> Int64 { sizes[url.path] ?? 0 }
}

/// The real disk, except that removing the named paths fails.
struct FailingUninstallFileSystem: UninstallFileSystem {
    let base = LocalUninstallFileSystem()
    let failing: Set<String>

    func kind(of url: URL) -> UninstallItemKind { base.kind(of: url) }
    func resolvingLinks(_ url: URL) -> URL { base.resolvingLinks(url) }
    func canonical(_ url: URL) -> URL { base.canonical(url) }
    func removeItem(at url: URL) throws {
        if failing.contains(url.path) { throw FakeUninstallFileSystem.Failure() }
        try base.removeItem(at: url)
    }
    func removeFolderIfEmpty(at url: URL) throws -> Bool { try base.removeFolderIfEmpty(at: url) }
    func byteSize(of url: URL) -> Int64 { base.byteSize(of: url) }
}

extension UninstallStep.Action {
    /// A step as one line of text, so tests compare places and not how a URL was built.
    var label: String {
        switch self {
        case .stopActivity: "stop"
        case .signOut: "signOut"
        case .unregisterLoginItem: "loginItem"
        case .clearNotifications: "notifications"
        case .deleteKeychainItems(let service): "keychain:\(service)"
        case .removeItem(let url): "remove:\(url.path)"
        case .removeFolderIfEmpty(let url): "removeIfEmpty:\(url.path)"
        case .clearDefaults(let domain): "defaults:\(domain)"
        case .moveAppToTrash(let url): "trash:\(url.path)"
        case .resetPermissions(let id): "tccutil:\(id)"
        }
    }
}

extension UninstallPlan {
    var labels: [String] { steps.map(\.action.label) }
    var allowed: [String] { allowedRoots.map { "\($0.url.path) depth \($0.minimumDepth)" } }
}
