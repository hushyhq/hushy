import Foundation
import MurmurCore

/// The Mac's Spotlight index, asked through `NSMetadataQuery` (the index `mdfind` reads). No
/// shell, no command string: the predicate is built from validated words by `SpotlightPredicate`
/// and the query is scoped to the folders in the spec. Only file names, dates and content types
/// come back; the contents of files are never read.
struct SpotlightFileFinder: FileFinding {
    /// How a query is made; the app's is `NSMetadataQuery`, tests pass a fake that never touches an index.
    var makeDriver: @MainActor @Sendable (NSPredicate, [URL]) -> any MetadataQueryDriving = {
        NSMetadataQueryDriver(predicate: $0, roots: $1)
    }

    func search(_ spec: FileSearchSpec) async -> FileSearchResponse {
        if let root = spec.roots.first, spec.roots.count == 1, !FileManager.default.isReadableFile(atPath: root.path) {
            return .unavailable(.folderNotReadable)
        }
        let predicate = SpotlightPredicate.make(spec)
        return await Self.run(spec: spec, predicate: predicate, roots: spec.roots, make: makeDriver)
    }

    /// The whole query on the main actor: created, run, stopped and released there. `NSMetadataQuery`
    /// belongs to the thread that started it; releasing it from whichever thread finished the
    /// `await` (the old shape) deallocated it off the main thread. That is the best explanation we
    /// have for the build 1483 crash after "find my resume", not a proven one.
    @MainActor
    private static func run(
        spec: FileSearchSpec, predicate: NSPredicate, roots: [URL],
        make: @MainActor @Sendable (NSPredicate, [URL]) -> any MetadataQueryDriving
    ) async -> FileSearchResponse {
        let run = SpotlightRun(driver: make(predicate, roots), spec: spec)
        return await run.execute()
    }

    /// Whether Spotlight answers for anything at all: apps in the system folders are always
    /// indexed when indexing is on.
    func isIndexAvailable() async -> Bool {
        let roots = [URL(fileURLWithPath: "/System/Applications"), URL(fileURLWithPath: "/Applications")]
        let spec = FileSearchSpec(pass: .nameAny, termGroups: [], kind: .any, roots: roots, limit: 1, timeBox: .seconds(1))
        let predicate = NSPredicate(format: "%K == %@", "kMDItemContentType", "com.apple.application-bundle")
        if case .results(let list) = await Self.run(spec: spec, predicate: predicate, roots: roots, make: makeDriver),
           !list.isEmpty { return true }
        return false
    }
}

/// The few things `SpotlightRun` needs from a metadata query, so its notification, timeout and
/// cancellation handling can be tested with a fake that never touches an index.
@MainActor
protocol MetadataQueryDriving: AnyObject {
    /// Called once when the query has gathered everything. Setting nil removes the observer.
    func setFinishHandler(_ handler: (@MainActor () -> Void)?)
    func start() -> Bool
    func disableUpdates()
    func stop()
    /// How many results are available now (all of them, or what was gathered at the time box).
    var resultCount: Int { get }
    func candidate(at index: Int) -> FileCandidate?
}

/// The real thing: one `NSMetadataQuery` on the main run loop.
@MainActor
final class NSMetadataQueryDriver: MetadataQueryDriving {
    private let query = NSMetadataQuery()
    private var observer: NSObjectProtocol?

    init(predicate: NSPredicate, roots: [URL]) {
        query.predicate = predicate
        query.searchScopes = roots.map { $0 as NSURL }
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
    }

    func setFinishHandler(_ handler: (@MainActor () -> Void)?) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let handler else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
        ) { _ in MainActor.assumeIsolated { handler() } }
    }

    func start() -> Bool { query.start() }
    func disableUpdates() { query.disableUpdates() }
    func stop() { query.stop() }
    var resultCount: Int { query.resultCount }

    func candidate(at index: Int) -> FileCandidate? {
        guard let item = query.result(at: index) as? NSMetadataItem,
              let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
        let tree = item.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String] ?? []
        return FileCandidate(
            path: path,
            displayName: item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String,
            modified: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
            lastUsed: item.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date,
            kinds: FileKind.kinds(forContentTypeTree: tree),
            isFolder: tree.contains("public.folder"))
    }
}

/// One query, run to completion or to the time box, answered exactly once. Out-of-scope hits
/// (Library, hidden, app bundles, Hushy's folders) are dropped *before* the limit is applied, so
/// they can never crowd out a real match.
@MainActor
final class SpotlightRun {
    /// A bound on how many raw hits one run looks through.
    static let maxScanned = 20_000

    private let driver: any MetadataQueryDriving
    private let spec: FileSearchSpec
    private var continuation: CheckedContinuation<FileSearchResponse, Never>?
    private var timer: Task<Void, Never>?

    init(driver: any MetadataQueryDriving, spec: FileSearchSpec) {
        self.driver = driver
        self.spec = spec
    }

    func execute() async -> FileSearchResponse {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<FileSearchResponse, Never>) in
                self.continuation = continuation
                if Task.isCancelled {
                    finish()
                    return
                }
                driver.setFinishHandler { [weak self] in self?.finish() }
                let box = spec.timeBox
                timer = Task { [weak self] in
                    try? await Task.sleep(for: box)
                    guard !Task.isCancelled else { return }
                    self?.finish()
                }
                if !driver.start() { finish(failed: true) }
            }
        } onCancel: {
            Task { @MainActor in self.finish() }
        }
    }

    /// Stops the query and answers once, with what has been gathered so far.
    private func finish(failed: Bool = false) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        driver.setFinishHandler(nil)
        driver.disableUpdates()
        let list = failed ? [] : candidates()
        driver.stop()
        continuation.resume(returning: failed ? .unavailable(.failed) : .results(list))
    }

    private func candidates() -> [FileCandidate] {
        var out: [FileCandidate] = []
        for index in 0..<min(driver.resultCount, Self.maxScanned) {
            guard out.count < spec.limit else { break }
            guard let file = driver.candidate(at: index) else { continue }
            if !spec.homePath.isEmpty, FileScope.isExcluded(path: file.path, home: spec.homePath) { continue }
            out.append(file)
        }
        return out
    }
}
