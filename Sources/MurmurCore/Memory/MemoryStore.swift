import Foundation
import os

/// What became of one change to memory.
public enum MemoryWrite: Sendable, Equatable {
    case written
    /// The word was already there, whatever its capitals: that entry was updated instead.
    case merged
    /// The word is under "Forgotten", and only the person can bring it back (`restore`).
    case forgotten
    /// The profile is at its size cap.
    case full
    /// Nothing to write: the text was blank.
    case empty
    /// No entry has that id any more.
    case missing
}

/// What became of something learned from the person's edits.
public enum MemoryLearning: Sendable, Equatable {
    case kept(MemoryWrite)
    /// Refused where the existing learning is refused: "Learn from my edits" off, an excluded
    /// app, a secure field, a password manager, code, another language.
    case refused(LearningRefusal)
    case paused
}

/// How long a change the person made is kept. Theirs to choose: nothing expires unless they say so.
public enum MemoryLife: Int, Sendable, CaseIterable {
    case never = 0
    case days90 = 90
    case days30 = 30

    var days: Int? { self == .never ? nil : rawValue }
}

/// The memory folder. The files are the truth and the index is rebuilt from them, so an edit
/// made in any text editor counts the next time memory is used.
public actor MemoryStore {
    public let root: URL
    private let now: @Sendable () -> Date
    private var snapshot = MemoryIndex(entries: [])
    private var signature: [String: String] = [:]

    public init(root: URL = AppPaths.memoryDirectory, now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root
        self.now = now
    }

    private static let stores = OSAllocatedUnfairLock<[String: MemoryStore]>(initialState: [:])

    /// The one store for a folder. The Memory pane and the dictation path both take theirs from
    /// here, so neither can write over what the other has just read.
    public static func shared(root: URL = AppPaths.memoryDirectory) -> MemoryStore {
        stores.withLock { stores in
            let key = root.standardizedFileURL.path
            if let store = stores[key] { return store }
            let store = MemoryStore(root: root)
            stores[key] = store
            return store
        }
    }

    public func index() throws -> MemoryIndex {
        try reloadIfChanged()
        return snapshot
    }

    public func isPaused() throws -> Bool {
        try reloadIfChanged()
        return try read(MemoryFiles.profile).isPaused
    }

    public func setPaused(_ paused: Bool) throws {
        var document = try read(MemoryFiles.profile)
        document.setPaused(paused)
        try write(document, at: MemoryFiles.profile)
        try reload()
    }

    /// Adds an entry the person asked for. A word that is already there is updated, not added twice.
    @discardableResult
    public func add(_ entry: MemoryEntry) throws -> MemoryWrite {
        try reloadIfChanged()
        var copy = entry
        switch copy.kind {
        case .term:
            let key = MemoryIndex.key(copy.value)
            if snapshot.forgottenKeys.contains(key) { return .forgotten }
            if let existing = snapshot.termsByKey[key]?.first { return try merge(copy, into: existing) }
        case .profile:
            copy.value = String(copy.value.prefix(profileRoom(besides: nil)))
            if copy.value.isEmpty { return entry.value.isEmpty ? .empty : .full }
        case .correction:
            if let existing = snapshot.entries.first(where: { $0.isSameChange(as: copy) }) { return try renew(existing, at: copy.createdAt) }
        case .forgotten, .style:
            break
        }
        return try append(copy)
    }

    /// The one way anything learned from the person's edits reaches memory: refused wherever the
    /// existing learning is (`LearningGate`), and while memory is paused.
    @discardableResult
    public func learn(_ entry: MemoryEntry, context: LearningContext) throws -> MemoryLearning {
        if let refusal = LearningGate.refusal(context) { return .refused(refusal) }
        if try isPaused() { return .paused }
        var learned = entry
        learned.origin = .learned
        return .kept(try add(learned))
    }

    @discardableResult
    public func update(_ entry: MemoryEntry) throws -> MemoryWrite {
        try reloadIfChanged()
        guard let old = snapshot.entries.first(where: { $0.id == entry.id }) else { return .missing }
        var copy = entry
        copy.kind = old.kind
        // Changed by the person: it is theirs from here on.
        copy.origin = .typed
        if copy.kind == .term {
            let key = MemoryIndex.key(copy.value)
            if snapshot.forgottenKeys.contains(key) { return .forgotten }
            if let other = snapshot.termsByKey[key]?.first(where: { $0.id != old.id }) {
                try remove(old)
                return try merge(copy, into: other)
            }
        }
        if copy.kind == .profile { copy.value = String(copy.value.prefix(profileRoom(besides: old.id))) }
        if copy.kind != .correction, copy.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        let oldPath = MemoryFiles.path(for: old), newPath = MemoryFiles.path(for: copy)
        if oldPath == newPath {
            // An edit keeps the entry's line where it is in the file.
            var document = try read(oldPath)
            document.replace(copy)
            try write(document, at: oldPath)
        } else {
            try write(copy, into: newPath)
            try remove(old)
        }
        try reload()
        return .written
    }

    /// Removes an entry. A word leaves a line under "Forgotten", so it is never learned again.
    public func forget(id: UUID) throws {
        try reloadIfChanged()
        guard let entry = snapshot.entries.first(where: { $0.id == id }), entry.kind != .forgotten else { return }
        try remove(entry)
        if entry.kind == .term {
            try write(MemoryEntry(kind: .forgotten, value: entry.value, createdAt: now()), into: MemoryFiles.terms)
        }
        try reload()
    }

    /// The person takes a word back out of "Forgotten": it is a word Hushy knows again.
    @discardableResult
    public func restore(id: UUID) throws -> MemoryWrite {
        try reloadIfChanged()
        guard let entry = snapshot.entries.first(where: { $0.id == id && $0.kind == .forgotten }) else { return .missing }
        let key = MemoryIndex.key(entry.value)
        for tombstone in snapshot.entries where tombstone.kind == .forgotten && MemoryIndex.key(tombstone.value) == key {
            try remove(tombstone)
        }
        try reload()
        return try add(MemoryEntry(id: entry.id, kind: .term, value: entry.value, createdAt: now()))
    }

    /// Removes every file. Pause is a choice, not a memory, so it outlives the erase.
    public func eraseAll() throws {
        let paused = (try? read(MemoryFiles.profile).isPaused) ?? false
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        try write(try read(MemoryFiles.terms), at: MemoryFiles.terms)
        if paused { try setPaused(true) }
        try reload()
    }

    /// Removes the changes older than `life`. `.never`, the default, removes nothing: what Hushy
    /// keeps stays until the person deletes it. Returns how many went.
    @discardableResult
    public func prune(_ life: MemoryLife) throws -> Int {
        guard let days = life.days else { return 0 }
        try reloadIfChanged()
        let cutoff = now().addingTimeInterval(-Double(days) * 86_400)
        let expired = snapshot.entries.filter { $0.kind == .correction && $0.createdAt < cutoff }
        guard !expired.isEmpty else { return 0 }
        var document = try read(MemoryFiles.corrections)
        for entry in expired { document.remove(id: entry.id) }
        try write(document, at: MemoryFiles.corrections)
        try reload()
        return expired.count
    }

    /// A learned word as the old database had it, for telling which entries written before
    /// origins were recorded came from the first copy of learned words.
    public struct ImportedWord: Hashable, Sendable {
        let key: String
        let date: Date
    }

    /// The learned words in use in the old database, as `importLegacy` would have copied them.
    public static func importedWords(in store: Store) throws -> Set<ImportedWord> {
        Set(try store.learnedItems().filter { $0.kind == .term && $0.status == .active && $0.appBundleID == nil }.map {
            ImportedWord(key: MemoryIndex.key($0.value), date: MemoryEntry.toTheSecond($0.createdAt))
        })
    }

    /// "Delete learning data": everything Hushy learned goes from every file, and every change
    /// it kept. What the person typed or changed, and the words under "Forgotten", stay. An
    /// entry from before origins were recorded goes only when it is one of `imported` (the same
    /// word with the same date); otherwise it is taken to be the person's.
    public func forgetLearned(imported: Set<ImportedWord> = []) throws {
        try reloadIfChanged()
        for path in filePaths() where path != MemoryFiles.corrections {
            var document = try read(path)
            let learned = document.entries.filter { entry in
                if entry.origin == .learned { return true }
                return entry.origin == nil && entry.kind == .term
                    && imported.contains(ImportedWord(key: MemoryIndex.key(entry.value), date: entry.createdAt))
            }
            guard !learned.isEmpty else { continue }
            for entry in learned { document.remove(id: entry.id) }
            try write(document, at: path)
        }
        if exists(MemoryFiles.corrections) {
            try write(MemoryDocument(MemoryFiles.starter(for: MemoryFiles.corrections), file: .corrections), at: MemoryFiles.corrections)
        }
        try reload()
    }

    /// Only the first import creates terms.md; later changes to SQLite never overwrite hand edits.
    public func importLegacy(from store: Store) throws {
        guard !exists(MemoryFiles.terms) else { return }
        let old = try store.learnedItems().filter { $0.kind == .term && $0.appBundleID == nil }
        var document = try read(MemoryFiles.terms)
        for item in old where item.status == .active {
            document.append(MemoryEntry(kind: .term, value: item.value, heardAs: item.heardAs, createdAt: item.createdAt,
                                        origin: .learned))
        }
        for item in old where item.status == .forgotten {
            document.append(MemoryEntry(kind: .forgotten, value: item.value, createdAt: item.createdAt))
        }
        try write(document, at: MemoryFiles.terms)
        for path in [MemoryFiles.profile, MemoryFiles.corrections] where !exists(path) {
            try write(try read(path), at: path)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(MemoryFiles.styleFolder, isDirectory: true),
                                                withIntermediateDirectories: true)
        try reload()
    }

    // MARK: Changes

    private func append(_ entry: MemoryEntry) throws -> MemoryWrite {
        let isBlank = entry.kind != .correction && entry.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isBlank { return .empty }
        try write(entry, into: MemoryFiles.path(for: entry))
        try reload()
        return .written
    }

    /// The entry that is there keeps its id, date and place; it takes the new spelling and
    /// gains whatever the new one was heard as.
    private func merge(_ entry: MemoryEntry, into existing: MemoryEntry) throws -> MemoryWrite {
        var merged = existing
        merged.value = entry.value
        // Added by the person, it is theirs; learned again, it stays whose it was.
        if entry.origin == .typed { merged.origin = .typed }
        merged.appBundleID = entry.appBundleID ?? existing.appBundleID
        var seen = Set(existing.heardAs.map(MemoryIndex.key))
        merged.heardAs += entry.heardAs.filter { seen.insert(MemoryIndex.key($0)).inserted }
        var document = try read(MemoryFiles.terms)
        document.replace(merged)
        try write(document, at: MemoryFiles.terms)
        try reload()
        return .merged
    }

    /// The same change made again is one line, dated when it was last made.
    private func renew(_ existing: MemoryEntry, at date: Date) throws -> MemoryWrite {
        var renewed = existing
        renewed.createdAt = date
        var document = try read(MemoryFiles.corrections)
        document.replace(renewed)
        try write(document, at: MemoryFiles.corrections)
        try reload()
        return .merged
    }

    private func write(_ entry: MemoryEntry, into path: String) throws {
        var document = try read(path)
        document.append(entry)
        try write(document, at: path)
    }

    private func remove(_ entry: MemoryEntry) throws {
        let path = MemoryFiles.path(for: entry)
        var document = try read(path)
        document.remove(id: entry.id)
        try write(document, at: path)
    }

    /// How many more characters the profile may take, not counting the note being replaced.
    private func profileRoom(besides id: UUID?) -> Int {
        let used = snapshot.entries.filter { $0.kind == .profile && $0.id != id }.reduce(0) { $0 + $1.value.count }
        return max(0, MemoryDocument.profileLimit - used)
    }

    // MARK: Files

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    /// A missing file reads as a new one, with its opening note. One that is there but cannot be
    /// read as text throws: treating it as empty would let the next write replace what the
    /// person put in it.
    private func read(_ path: String) throws -> MemoryDocument {
        let file = MemoryFiles.file(at: path)
        guard exists(path) else { return MemoryDocument(MemoryFiles.starter(for: path), file: file) }
        return MemoryDocument(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), file: file)
    }

    private func write(_ document: MemoryDocument, at path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(document.text.utf8).write(to: url, options: .atomic)
    }

    private func reloadIfChanged() throws {
        if try signatures(of: filePaths()) != signature { try reload() }
    }

    /// Reads every file. A line the person typed by hand gets its hidden note here, once, so it
    /// has the same id and date from then on; what they typed is not altered.
    private func reload() throws {
        var entries: [MemoryEntry] = []
        for path in filePaths() {
            var document = try read(path)
            if document.adopt(now: now()) { try write(document, at: path) }
            entries += document.entries
        }
        snapshot = MemoryIndex(entries: entries)
        signature = try signatures(of: filePaths())
    }

    private func signatures(of paths: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for path in paths {
            let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)
            result[path] = "\(attributes[.size] ?? 0):\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        }
        return result
    }

    private func filePaths() -> [String] {
        let top = [MemoryFiles.profile, MemoryFiles.terms, MemoryFiles.corrections].filter(exists)
        let folder = root.appendingPathComponent(MemoryFiles.styleFolder).path
        let styles = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return top + styles.filter { $0.hasSuffix(".md") }.sorted().map { MemoryFiles.styleFolder + "/" + $0 }
    }
}
