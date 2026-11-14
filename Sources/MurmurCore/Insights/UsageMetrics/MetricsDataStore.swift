import Foundation
import os

/// Where usage numbers live on disk: one folder per data epoch (`e0`, `e1`, ...) under `root`.
/// The journal, the active-day list, the saved batch IDs, the queue and the upload bookkeeping all
/// sit inside the folder of the epoch they were written in, and every reader resolves the folder
/// from the epoch it was handed. The epoch goes up whenever sharing is switched off
/// (`MetricsSwitch`), so after an off-and-on the current folder is new and empty and nothing older
/// is reachable. Collecting garbage (`collectGarbage`) removes the folders of earlier epochs and
/// anything else in `root`; if it fails, only disk space is wasted.
public final class MetricsDataStore: @unchecked Sendable {
    private static let log = Logger(subsystem: "app.hushy", category: "usage-metrics")

    public let root: URL
    private let policy: MetricsQueuePolicy
    private let lock = NSLock()
    private var queues: [Int: MetricsBatchQueue] = [:]

    public init(root: URL, policy: MetricsQueuePolicy = .standard) {
        self.root = root
        self.policy = policy
    }

    public static func folderName(for epoch: Int) -> String { "e\(epoch)" }

    public func directory(for epoch: Int) -> URL {
        root.appendingPathComponent(Self.folderName(for: epoch), isDirectory: true)
    }

    /// The queue of closed batches inside that epoch's folder (one instance per epoch).
    public func queue(for epoch: Int) -> MetricsBatchQueue {
        lock.withLock {
            if let existing = queues[epoch] { return existing }
            let created = MetricsBatchQueue(directory: directory(for: epoch), policy: policy)
            queues[epoch] = created
            return created
        }
    }

    public func uploadStateURL(for epoch: Int) -> URL {
        directory(for: epoch).appendingPathComponent(UsageMetricsService.uploadStateName)
    }

    /// Epoch numbers above this are not real: a folder named like one is treated as stray and
    /// deleted, and the epoch itself is clamped to it when restored (`MetricsSwitch`), so adding one
    /// can never overflow.
    public static let maximumEpoch = 1_000_000_000

    /// The number in an epoch folder's name (`e7` is 7); nil for anything else, including a number
    /// above `maximumEpoch` or too long to be a number.
    static func epochNumber(ofFolder name: String) -> Int? {
        guard name.hasPrefix("e"), (2...11).contains(name.count), name.dropFirst().allSatisfy(\.isASCII),
              name.dropFirst().allSatisfy(\.isNumber), let number = Int(name.dropFirst()), number <= maximumEpoch else { return nil }
        return number
    }

    /// What a look at the metrics folder found.
    public enum Scan: Equatable, Sendable {
        /// The folder was read (or does not exist yet): the highest epoch folder in it, if any.
        case readable(highest: Int?)
        /// The folder exists but could not be listed. Callers must not go on as if it were empty.
        case unreadable
    }

    /// Reads the folder once. A folder that does not exist yet is fine (nothing to find); one that
    /// exists and cannot be listed is `.unreadable`.
    public func scan() -> Scan {
        guard FileManager.default.fileExists(atPath: root.path) else { return .readable(highest: nil) }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return .unreadable }
        return .readable(highest: names.compactMap(Self.epochNumber(ofFolder:)).max())
    }

    /// True when `root` holds anything older than `epoch`, or anything that is not an epoch folder.
    public func hasGarbage(keeping epoch: Int) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).contains { isGarbage($0, keeping: epoch) }
    }

    /// Garbage is a folder with a number LOWER than `epoch`, or something that is not an epoch
    /// folder at all. Never the folder of `epoch` itself, never a higher one: epochs only go up, so
    /// a caller holding a stale epoch (an off and on happened since it was read) cannot delete a
    /// newer folder, and no lock between collection and epoch changes is needed.
    private func isGarbage(_ name: String, keeping epoch: Int) -> Bool {
        name == MetricsStoreLock.fileName ? false : (Self.epochNumber(ofFolder: name).map { $0 < epoch } ?? true)
    }

    /// Removes the garbage described above. Each removal is attempted on its own; failures are
    /// logged (a stage name and an error type, never a name or a path) and counted. A folder that
    /// exists but cannot be listed counts as one failure; one that does not exist is nothing to clean.
    @discardableResult
    public func collectGarbage(keeping epoch: Int) -> Int {
        let files = FileManager.default
        var failures = 0
        guard files.fileExists(atPath: root.path) else { return 0 }
        guard let names = try? files.contentsOfDirectory(atPath: root.path) else {
            Self.log.error("usage metrics: tidy could not list the folder")
            return 1
        }
        for name in names where isGarbage(name, keeping: epoch) {
            do { try files.removeItem(at: root.appendingPathComponent(name)) } catch {
                failures += 1
                Self.log.error("usage metrics: tidy failed (\(String(describing: type(of: error)), privacy: .public))")
            }
        }
        lock.withLock { queues = queues.filter { $0.key >= epoch } }
        return failures
    }
}

/// An exclusive lock on the usage-numbers folder, held for the life of the process. Hushy already
/// quits a second copy at launch (`SingleInstance`), but a second process can exist briefly before
/// it yields; one that cannot take this lock gets no metrics store at all (it neither records, tidies
/// nor uploads), so two processes can never disagree about the epoch folders.
public final class MetricsStoreLock: @unchecked Sendable {
    static let fileName = ".lock"
    private let descriptor: Int32

    /// Nil when another process holds the lock (or it cannot be created).
    public init?(root: URL) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(root.appendingPathComponent(Self.fileName).path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        descriptor = fd
    }

    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
