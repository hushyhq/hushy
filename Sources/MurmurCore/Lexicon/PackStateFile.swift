import Foundation
import os

/// What Hushy keeps about domain packs between launches: the person's choice per pack and the pack names the
/// screen showed on which days (`PackEvidence`, indices only). History evidence is not kept here; it is read again
/// from History each time, so erasing History erases it.
///
/// A small JSON file beside the database (`lexicon-packs.json`), not a table: the schema is frozen for v26–v29 and
/// this needs no query. Everything in it can be erased (`erase`), and nothing in it leaves the Mac.
public struct PackState: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var choice: PackChoice = .automatic
        /// The pack version the indices in `screen` refer to; screen evidence for another version is dropped.
        public var packVersion: String
        public var screen: PackEvidence = PackEvidence()
    }

    public var version = 1
    public var packs: [String: Entry] = [:]

    public init() {}

    public func choice(for packID: String) -> PackChoice { packs[packID]?.choice ?? .automatic }

    public func screenEvidence(for pack: DomainPack) -> PackEvidence {
        guard let entry = packs[pack.id], entry.packVersion == pack.version else { return PackEvidence() }
        return entry.screen
    }

    /// Adds the names the screen showed today. Nothing is kept for a pack the person switched off.
    public mutating func recordScreen(_ hits: Set<Int>, for pack: DomainPack, at date: Date, calendar: Calendar = .current) {
        guard !hits.isEmpty, choice(for: pack.id) != .off else { return }
        var entry = packs[pack.id] ?? Entry(packVersion: pack.version)
        if entry.packVersion != pack.version { entry = Entry(choice: entry.choice, packVersion: pack.version) }
        entry.screen.record(hits, on: PackEvidence.dayKey(date, calendar: calendar))
        packs[pack.id] = entry
    }

    public mutating func setChoice(_ choice: PackChoice, for pack: DomainPack) {
        var entry = packs[pack.id] ?? Entry(packVersion: pack.version)
        entry.choice = choice
        if choice == .off { entry.screen = PackEvidence() }
        packs[pack.id] = entry
    }

    /// Forgets every screen sighting and every choice.
    public mutating func eraseAll() { packs = [:] }
}

/// Reads and writes `PackState` atomically. Off the dictation hot path: callers use it from a background task.
public struct PackStateFile: Sendable {
    public let url: URL
    private static let log = Logger(subsystem: "app.hushy", category: "lexicon")

    public init(url: URL = AppPaths.supportDirectory.appendingPathComponent("lexicon-packs.json")) {
        self.url = url
    }

    /// The saved state, or an empty one when there is no file or it cannot be read (logged, never thrown: the
    /// worst case is that packs switch on again from evidence).
    public func load() -> PackState {
        guard let data = try? Data(contentsOf: url) else { return PackState() }
        do {
            return try JSONDecoder().decode(PackState.self, from: data)
        } catch {
            Self.log.error("lexicon pack state unreadable: \(error.localizedDescription, privacy: .public)")
            return PackState()
        }
    }

    public func save(_ state: PackState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    public func erase() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

/// The one owner of the pack state file in a running app: loads it once, folds in screen sightings, saves after
/// each change. An actor, so a sighting recorded after a dictation and a choice made in Settings cannot overwrite
/// each other.
public actor PackStateKeeper {
    private let file: PackStateFile
    private var state: PackState?
    private let packs: [DomainPack]
    private var matchers: [PackMatcher]?
    /// The newest erase. A sighting read before it (a lower epoch) is dropped, so an erase is never undone by a
    /// dictation that was still being processed.
    private var epoch = 0
    private static let log = Logger(subsystem: "app.hushy", category: "lexicon")

    public init(file: PackStateFile = PackStateFile(), packs: [DomainPack] = DomainPackCatalog.usable) {
        self.file = file
        self.packs = packs
    }

    public var current: PackState {
        if let state { return state }
        let loaded = file.load()
        state = loaded
        return loaded
    }

    /// Records which pack names `terms` (the screen terms of one dictation) name. Returns true when something new
    /// was kept, so the caller knows a rebuild may switch a pack on. Counts only: the terms themselves are not kept.
    @discardableResult
    public func recordScreen(_ terms: [String], at date: Date = Date(), epoch read: Int = 0) -> Bool {
        guard !terms.isEmpty, read >= epoch else { return false }
        let text = terms.joined(separator: " , ")
        var updated = current
        let matchers = self.matchers ?? packs.map(PackMatcher.init(pack:))
        self.matchers = matchers
        for (pack, matcher) in zip(packs, matchers) {
            updated.recordScreen(matcher.hits(in: text), for: pack, at: date)
        }
        return commit(updated)
    }

    public func setChoice(_ choice: PackChoice, forPack id: String) {
        guard let pack = packs.first(where: { $0.id == id }) else { return }
        var updated = current
        updated.setChoice(choice, for: pack)
        commit(updated)
    }

    /// "Erase": every sighting and every choice; packs go back to following the evidence (History still counts).
    public func eraseAll(epoch next: Int? = nil) {
        epoch = max(epoch, next ?? epoch + 1)
        state = PackState()
        do { try file.erase() } catch {
            Self.log.error("lexicon pack state erase failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @discardableResult
    private func commit(_ updated: PackState) -> Bool {
        guard updated != state else { return false }
        state = updated
        do { try file.save(updated) } catch {
            Self.log.error("lexicon pack state save failed: \(error.localizedDescription, privacy: .public)")
        }
        return true
    }
}
