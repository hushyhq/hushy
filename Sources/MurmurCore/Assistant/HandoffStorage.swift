import Darwin
import Foundation

/// Where the tool works: one fresh, empty, owner-only folder per run, outside the app's data
/// folder. The tool can read what is near its working folder and send it to its provider, so
/// nothing of Hushy's may sit beside or above it. The folder goes when the run ends.
struct HandoffWorkFolders: Sendable {
    let root: URL

    func make(for id: UUID) throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        // A folder of this name left by an earlier run is not reused.
        try? files.removeItem(at: folder)
        try files.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return folder
    }

    func remove(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Removes folders a session that crashed or was force-quit left behind. Only entries named
    /// like a task are touched.
    func sweep() {
        let files = FileManager.default
        guard let names = try? files.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where UUID(uuidString: name) != nil {
            try? files.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
        }
    }
}

extension HandoffQueue {
    static let indexName = "index.json"
    static let corruptPrefix = "index.corrupt-"
    /// A saved index larger than this is not read. Results are capped at 1 MB each, so a list
    /// someone really built up stays far below it; a file above it is treated as unreadable.
    static let maxIndexBytes = 32 * 1_048_576

    /// What the index file held.
    enum SavedIndex {
        case missing
        /// Not a regular file, too large, or not a list of tasks.
        case unreadable
        /// The tasks that could be read, and how many entries could not.
        case tasks([HandoffTask], dropped: Int)
    }

    /// One entry of the saved list. An entry that is not a task is left out by itself, so one
    /// damaged entry does not cost the whole list.
    private struct Entry: Decodable {
        let task: HandoffTask?
        init(from decoder: Decoder) throws { task = try? HandoffTask(from: decoder) }
    }

    /// Reads the index without changing anything on disk. Only a regular file is opened (never a
    /// link, and never something that would make the open wait), and never more than `maxIndexBytes`.
    static func readIndex(in root: URL, limit: Int = maxIndexBytes) -> SavedIndex {
        let descriptor = open(root.appendingPathComponent(indexName).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return errno == ENOENT ? .missing : .unreadable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit,
              let data = try? handle.read(upToCount: limit + 1), data.count <= limit,
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return .unreadable }
        let tasks = entries.compactMap(\.task)
        return .tasks(tasks, dropped: entries.count - tasks.count)
    }

    /// The saved tasks, whether a file that could not be read was set aside to get them, and how
    /// many single entries were left out.
    ///
    /// An unreadable index used to stop the task list opening for good. It is now renamed
    /// `index.corrupt-<time>.json` (one is kept, an older one is replaced) and the list starts empty.
    static func loadIndex(
        in root: URL, now: Date = Date(), limit: Int = maxIndexBytes
    ) throws -> (items: [HandoffTask], setAside: Bool, dropped: Int) {
        switch readIndex(in: root, limit: limit) {
        case .missing: return ([], false, 0)
        case .tasks(let tasks, let dropped): return (tasks, false, dropped)
        case .unreadable:
            try setAside(root.appendingPathComponent(indexName), in: root, now: now)
            return ([], true, 0)
        }
    }

    /// Whether `root` holds anything Clear tasks would remove: a task that is not running, an
    /// index (or entries of one) that cannot be read, or an index set aside earlier. It only
    /// reads: no folder or file is made, and an unreadable index is left where it is.
    public static func storeHasClearableContent(in root: URL = HandoffQueue.defaultRoot) -> Bool {
        if hasSetAsideIndex(in: root) { return true }
        switch readIndex(in: root) {
        case .missing: return false
        case .unreadable: return true
        case .tasks(let tasks, let dropped): return dropped > 0 || tasks.contains { $0.state != .running }
        }
    }

    static func setAsideFiles(in root: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasPrefix(corruptPrefix) && $0.hasSuffix(".json") }.map { root.appendingPathComponent($0) }
    }

    static func hasSetAsideIndex(in root: URL) -> Bool { !setAsideFiles(in: root).isEmpty }

    static func removeSetAsideFiles(in root: URL) {
        for file in setAsideFiles(in: root) { try? FileManager.default.removeItem(at: file) }
    }

    private static func setAside(_ index: URL, in root: URL, now: Date) throws {
        removeSetAsideFiles(in: root)
        let aside = root.appendingPathComponent("\(corruptPrefix)\(Int(now.timeIntervalSince1970)).json")
        try FileManager.default.moveItem(at: index, to: aside)
        // A link or a special file is moved as it is; only a real file has a mode worth narrowing.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: aside.path)
    }

    /// Writes the index beside itself and renames it into place. The temporary file is created
    /// owner-only before any task text is written to it, so the text is never readable by others.
    static func save(_ items: [HandoffTask], to url: URL) throws {
        let data = try JSONEncoder().encode(items)
        let temporary = url.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: temporary)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            // The mode above is reduced by the umask but never widened; this makes it exact.
            guard fchmod(descriptor, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
