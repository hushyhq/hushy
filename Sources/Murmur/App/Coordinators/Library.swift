import Foundation
import GRDB
import MurmurCore
import Observation
import os

/// Live, read-mostly view of everything stored on disk, kept current by database
/// observation, plus the user actions that change it. Views read from here; nothing
/// else caches copies of this data.
@MainActor
@Observable
final class Library {
    private(set) var dictations: [Dictation] = []
    private(set) var notes: [Note] = []
    private(set) var folders: [NoteFolder] = []
    /// Notes with no folder — only used to decide whether Notes offers an "Unfiled" chip
    /// (folder chips carry no counts; see DECISIONS.md, "Sidebar badges: only actionable counts").
    private(set) var unfiledNoteCount: Int = 0
    private(set) var dictionary: [DictionaryEntry] = []
    private(set) var snippets: [Snippet] = []
    /// Everything learned from the user's edits (terms and style signals, tombstones included),
    /// newest first. See `Library+Learning.swift` for the UI-facing API.
    private(set) var learnedItems: [LearnedItem] = []
    private(set) var backwardTermReviews: [LearnedItem] = []
    private(set) var keepHeardEntries: [KeepHeardEntry] = []
    private(set) var insights: Insights = .empty
    /// Completed action-item indexes per note id (index into that note's `actionItems` array).
    /// A note with no entry here has nothing checked off. Kept current by observation, like
    /// `notes`, so Home's "Open action items" card and the Notes detail checkboxes agree.
    private(set) var doneActionItemsByNote: [Int64: Set<Int>] = [:]
    /// Confirmed voice actions (calendar/reminder/shortcut), newest first — merged into the
    /// shared Home/History timeline alongside dictations and notes (see `Timeline.merge`).
    private(set) var actionRecords: [ActionRecord] = []
    /// Set when the database couldn't be opened and we are running in memory.
    let storeError: String?
    let store: Store
    /// Hushy's `Audio/` folder, which "Erase dictation history" clears of recordings no row names.
    /// Nil in tests that give no folder, so an erase there never reaches the real one.
    @ObservationIgnored let audioDirectory: URL?
    /// How a leftover recording leaves the folder; a test swaps in a stand-in for the Trash.
    @ObservationIgnored var disposeAudio: (URL) throws -> Void = AudioFiles.moveToTrash

    /// The Memory half of the last "Delete learning data", kept so a test can wait for it.
    @ObservationIgnored var learningDeletion: Task<Void, Never>?

    /// Called whenever the dictionary or snippets change, so the dictation path stays in sync.
    @ObservationIgnored var onPersonalizationChange: ((Personalizer) -> Void)?
    /// History rows changed (a dictation saved, edited, deleted, erased): the personal lexicon rebuilds.
    @ObservationIgnored var onHistoryChange: (() -> Void)?
    /// "Erase dictation history" or "Delete learning data" ran: the personal lexicon erases its pack state file
    /// (screen sightings and pack choices) and rebuilds from what is left.
    @ObservationIgnored var onLexiconErase: (() -> Void)?
    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    @ObservationIgnored private let log = Logger(subsystem: "app.hushy", category: "library")

    /// `encryptsData`: data encryption is on, so the store makes no unencrypted pre-upgrade copy.
    init(encryptsData: Bool) {
        audioDirectory = AppPaths.audioDirectory
        do {
            store = try StoreOpener.open(url: AppPaths.database) { try Store(url: $0, preMigrationBackup: !encryptsData) }
            storeError = nil
        } catch {
            // The file is left exactly as it was. The app stays usable in memory, but this
            // session is not saved: `AppModel.launch` tells the person, and Settings shows it.
            let openError = error.localizedDescription
            do {
                store = try Store()
                storeError = openError
            } catch {
                // An in-memory GRDB store failing means something is deeply wrong (out of
                // memory, SQLite itself broken): crash with the cause instead of a bare
                // force-unwrap trap, so the report says what happened.
                fatalError("Hushy: cannot open database (\(openError)) and the in-memory fallback failed: \(error.localizedDescription)")
            }
        }
    }

    /// A library over a store the caller made (tests: none of them opens the real database path).
    init(store: Store, audioDirectory: URL? = nil) {
        self.store = store
        storeError = nil
        self.audioDirectory = audioDirectory
    }

    func startObserving() {
        let writer = store.writer
        // Load the learning word list off the main actor before learned items first need it.
        Task.detached(priority: .utility) { _ = WordFrequency.shared.entryCount }
        observe(ValueObservation.tracking { db in
            try Dictation.order(Column("createdAt").desc).limit(500).fetchAll(db)
        }, in: writer) { [weak self] in
            self?.dictations = $0
            self?.onHistoryChange?()
        }
        observe(ValueObservation.tracking { db in
            try Note.order(Column("createdAt").desc).fetchAll(db)
        }, in: writer) { [weak self] in self?.notes = $0 }
        observe(ValueObservation.tracking { db in
            try NoteFolder.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
        }, in: writer) { [weak self] in self?.folders = $0 }
        observe(ValueObservation.tracking { db in
            try Note.filter(Column("folderId") == nil).fetchCount(db)
        }, in: writer) { [weak self] in self?.unfiledNoteCount = $0 }
        observe(ValueObservation.tracking { db in
            try NoteActionItemStatus.filter(Column("isDone") == true).fetchAll(db)
        }, in: writer) { [weak self] rows in
            self?.doneActionItemsByNote = Dictionary(grouping: rows, by: \.noteId)
                .mapValues { Set($0.map(\.itemIndex)) }
        }
        observe(ValueObservation.tracking { db in
            try DictionaryEntry.order(Column("createdAt").desc).fetchAll(db)
        }, in: writer) { [weak self] in
            self?.dictionary = $0
            self?.personalizationChanged()
        }
        observe(ValueObservation.tracking { db in
            try Snippet.order(Column("createdAt").desc).fetchAll(db)
        }, in: writer) { [weak self] in
            self?.snippets = $0
            self?.personalizationChanged()
        }
        observe(ValueObservation.tracking { db in
            try Store.learnedItems(db)
        }, in: writer) { [weak self] in
            self?.learnedItems = $0
            self?.personalizationChanged()
        }
        observe(ValueObservation.tracking { db in
            try ActionRecord.order(Column("createdAt").desc).limit(500).fetchAll(db)
        }, in: writer) { [weak self] in self?.actionRecords = $0 }
        observe(ValueObservation.tracking { db in
            try KeepHeardEntry.order(Column("lastSeenAt").desc).fetchAll(db)
        }, in: writer) { [weak self] in self?.keepHeardEntries = $0 }
        observe(ValueObservation.tracking { db in
            try Store.backwardTermReviews(db)
        }, in: writer) { [weak self] in self?.backwardTermReviews = $0 }
        observeInsights(in: writer)
    }

    /// Insights get their own observation (distinct from `observe`, above) because the
    /// aggregate SQL query only needs to run off the main actor and debounced: GRDB's
    /// `ValueObservation` already tracks just the tables the query reads (here, `dictation`),
    /// so this fires exactly when `dictations` would, but at a fraction of the cost — `Store
    /// .computeInsights` is SQL `COUNT`/`SUM`/`GROUP BY` aggregates instead of a full-table
    /// fetch plus an in-memory recompute (previously ~406-411 ms at 50k rows; see
    /// docs/engineering/performance-plan.md item 2).
    private func observeInsights(in writer: any DatabaseWriter) {
        let observation = ValueObservation.tracking { db in
            try Store.computeInsights(db, now: Date(), calendar: .current)
        }
        let scheduler = DispatchQueue(label: "app.hushy.insights-observation", qos: .utility)
        // Coalesces bursts of writes (e.g. a batch delete, or several dictations in quick
        // succession) into one recompute per quiet period, instead of one per row change:
        // each new value cancels and restarts the debounce wait, so only the last value in a
        // burst is ever applied.
        let debounceInterval: Duration = .milliseconds(400)
        let applyTask = DebouncedApply(interval: debounceInterval) { [weak self] (value: Insights) in
            self?.insights = value
        }
        let task = Task { [log] in
            do {
                for try await value in observation.values(in: writer, scheduling: .async(onQueue: scheduler)) {
                    applyTask.schedule(value)
                }
            } catch {
                log.error("insights observation failed: \(error.localizedDescription)")
            }
        }
        observers.append(task)
    }

    /// Recomputes the insights once, for `now`. The observation above only fires when the
    /// dictation table changes, so after midnight with nothing new said, the streak and day
    /// counts would still be the ones computed yesterday. `DayClock.onDayChange` calls this.
    func refreshInsights(now: Date, calendar: Calendar) {
        let store = store
        Task { [weak self, log] in
            do {
                let value = try await store.writer.read { db in
                    try Store.computeInsights(db, now: now, calendar: calendar)
                }
                self?.insights = value
            } catch {
                log.error("insights refresh failed: \(error.localizedDescription)")
            }
        }
    }

    private func personalizationChanged() {
        // Active learned terms join the user's own entries (which win on conflicts), so they are
        // boosted in ASR, applied as safe replacements and protected from model rewrites.
        onPersonalizationChange?(LearnedPersonalization.personalizer(
            dictionary: dictionary, snippets: snippets, learned: learnedItems))
    }

    private func observe<Value: Sendable>(
        _ observation: ValueObservation<ValueReducers.Fetch<Value>>,
        in writer: any DatabaseWriter,
        apply: @escaping @MainActor (Value) -> Void
    ) {
        let task = Task { [log] in
            do {
                for try await value in observation.values(in: writer) { apply(value) }
            } catch {
                log.error("observation failed: \(error.localizedDescription)")
            }
        }
        observers.append(task)
    }

    // MARK: Actions

    func deleteDictation(_ item: Dictation) {
        guard let id = item.id else { return }
        guard perform("delete dictation", { try store.deleteDictation(id: id) }) else { return }
        if let path = item.audioPath { AudioFiles.remove(path) }
    }

    /// Deletes several dictations in one transaction, then removes their audio files.
    func deleteDictations(_ items: [Dictation]) {
        let ids = items.compactMap(\.id)
        guard !ids.isEmpty else { return }
        var audioPaths: [String] = []
        perform("delete dictations") { audioPaths = try store.deleteDictations(ids: ids) }
        AudioFiles.remove(paths: audioPaths)
    }

    /// "Erase dictation history": every dictation row, and the audio of every one of them.
    /// The recordings go only once the rows are gone, so a failed erase never leaves rows
    /// pointing at deleted audio. The person asked for all of it, so recordings no row names
    /// (UUID `.wav` and `.wav.enc` files in `Audio/`) go to the Trash too.
    func eraseDictationHistory() {
        var paths: [String] = []
        guard perform("erase dictation history", { paths = try store.deleteAllDictations() }) else { return }
        onLexiconErase?()
        AudioFiles.remove(paths: paths)
        if let audioDirectory {
            let moved = AudioFiles.trashLeftovers(in: audioDirectory, dispose: disposeAudio)
            if moved > 0 { log.notice("moved \(moved) leftover recording(s) to the Trash") }
        }
        perform("clear the database log after erase") { try store.truncateWAL() }
    }

    func recover(_ item: Dictation) {
        // Nothing to copy (a take whose words were never read): an empty copy would only clear the clipboard.
        guard DictationRecovery.action(for: item) == .copy else { return }
        var copy = item
        copy.status = .notInserted
        perform("recover dictation") { _ = try store.save(copy) }
        TextInserter.copy(item.text)
    }

    func deleteNote(_ note: Note) {
        guard let id = note.id else { return }
        guard perform("delete note", { try store.deleteNote(id: id) }) else { return }
        // Usually inside the audio folder below; a note without one keeps it where its folder would be.
        NoteStyleFile(note: note)?.remove()
        if let path = note.audioPath { try? FileManager.default.removeItem(atPath: path) }
    }

    func rename(_ note: Note, to title: String) {
        var copy = note
        copy.title = title
        perform("rename note") { _ = try store.save(copy) }
    }

    /// Summarizes the note again from its turns, "Name: text" when several people spoke (renamed
    /// speakers by name). Check-offs stay on their tasks (`DiarizedDigest.mergeItems`); the title
    /// changes only if it's still the default.
    func resummarize(_ note: Note) {
        guard let id = note.id else { return }
        Task {
            let turns = (try? store.transcript(noteId: id))?.rendered
            let digest = await SmartCleaner.summarize(turns ?? note.transcript, fallbackTitle: note.title)
            perform("save summary") {
                try store.updateNoteDigest(id: id) { stored, done in
                    guard stored.status == .ready else { return nil }
                    var copy = stored
                    copy.summary = digest.summary
                    let merged = DiarizedDigest.mergeList(
                        stored.actionItems, details: stored.actionItemDetails, done: done,
                        labelled: digest.actionItems, labelledDetails: digest.actionDetails)
                    copy.setActionItems(merged.items, details: merged.details)
                    if copy.title.hasPrefix("Note · ") { copy.title = digest.title }
                    return (copy, merged.done)
                }
            }
        }
    }

    func exportNote(_ note: Note, to directory: URL) -> URL? {
        var result: URL?
        let done = note.id.flatMap { doneActionItemsByNote[$0] } ?? []
        let turns = note.id.flatMap { try? store.transcript(noteId: $0) }
        perform("export note") { result = try MarkdownExporter.export(note, transcript: turns, to: directory, done: done) }
        return result
    }

    /// A note's stored timed rows — word-level for an imported file, speaker-turn-level for a
    /// diarized live recording (see `NoteSegmentWithSpeaker`) — for SRT/VTT/timestamped-text
    /// export. Empty for a note with neither (a live recording with no diarization run).
    func segments(_ note: Note) -> [NoteSegmentWithSpeaker] {
        guard let id = note.id else { return [] }
        return (try? store.noteSegments(noteId: id)) ?? []
    }

    /// The rows SRT, WebVTT and timestamped text are made from: the note's timed turns (word by word
    /// where the words were kept, both sides of a call), else a legacy note's stored segments.
    func timedRows(_ note: Note) -> [NoteSegmentWithSpeaker] {
        guard let id = note.id else { return [] }
        let rows = (try? store.transcript(noteId: id))?.timedRows(noteId: id) ?? []
        return rows.isEmpty ? segments(note) : rows
    }

    func exportTranscript(_ note: Note, format: NoteTranscriptExporter.Format, to directory: URL) -> URL? {
        var result: URL?
        let rows = timedRows(note)
        perform("export transcript") { result = try NoteTranscriptExporter.export(note, segments: rows, format: format, to: directory) }
        return result
    }

    // MARK: Folders

    /// Creates a folder. Returns the store error (empty/duplicate name) to the caller instead
    /// of only logging it, since folder creation is driven by an inline text field the user
    /// expects immediate feedback from.
    @discardableResult
    func createFolder(name: String) -> Result<NoteFolder, Error> {
        do {
            return .success(try store.createFolder(name: name))
        } catch {
            log.error("create folder failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    @discardableResult
    func renameFolder(_ folder: NoteFolder, to name: String) -> Result<NoteFolder, Error> {
        guard let id = folder.id else { return .failure(Store.FolderError.notFound) }
        do {
            return .success(try store.renameFolder(id: id, to: name))
        } catch {
            log.error("rename folder failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    /// Deletes the folder; its notes are kept and become unfiled (`ON DELETE SET NULL`).
    func deleteFolder(_ folder: NoteFolder) {
        guard let id = folder.id else { return }
        perform("delete folder") { try store.deleteFolder(id: id) }
    }

    func moveNote(_ note: Note, toFolder folder: NoteFolder?) {
        guard let id = note.id else { return }
        perform("move note") { try store.moveNote(id: id, toFolder: folder?.id) }
    }

    /// Whether action item `itemIndex` of `note` is checked off.
    func isActionItemDone(_ note: Note, itemIndex: Int) -> Bool {
        guard let id = note.id else { return false }
        return doneActionItemsByNote[id]?.contains(itemIndex) ?? false
    }

    /// Toggles one action item's completion for `note`, persisting it so it survives relaunch.
    func toggleActionItemDone(_ note: Note, itemIndex: Int) {
        guard let id = note.id else { return }
        let isDone = !isActionItemDone(note, itemIndex: itemIndex)
        perform("toggle action item") { try store.setActionItemDone(noteId: id, itemIndex: itemIndex, isDone: isDone) }
    }

    /// Runs a store operation and logs failures instead of silently dropping them.
    @discardableResult
    private func perform(_ action: String, _ body: () throws -> Void) -> Bool {
        do {
            try body()
            return true
        } catch {
            log.error("\(action, privacy: .public) failed: \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Speaker labels & voice signatures

extension Library {
    /// Renames a speaker within a note — every segment referencing it picks up the new name on
    /// next read — and carries the rename into the note's summary and action items (no model
    /// call; `DigestSpeakerRename`). Free-tier feature.
    func renameSpeaker(id: Int64, to displayName: String) {
        perform("rename speaker") { try store.renameSpeakerUpdatingDigest(id: id, to: displayName) }
    }

    /// Merges `sourceId`'s turns into `targetId` and removes `sourceId` — the common
    /// over-segmentation correction ("these two speakers are actually the same person").
    func mergeSpeakers(sourceId: Int64, intoTargetId targetId: Int64) {
        perform("merge speakers") { try store.mergeSpeakersUpdatingDigest(sourceId: sourceId, intoTargetId: targetId) }
    }

    /// Confirms a speaker's "Is this Dana?" suggestion: links the voice, names the speaker and
    /// carries the name into the summary and action items. Returns the voice id (so the caller can
    /// fold the note's audio into it), or `nil` when nothing was confirmed. Pro-gated by the caller
    /// (the suggestion banner only renders when `Entitlements.has(.voiceSignatures)`).
    @discardableResult
    func confirmSpeakerVoiceSuggestion(speakerId: Int64) -> Int64? {
        do {
            return try store.confirmSpeakerVoiceSuggestionApplyingName(id: speakerId)
        } catch {
            log.error("confirm voice suggestion failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Dismisses a speaker's "Is this Dana?" suggestion without linking it.
    func dismissSpeakerVoiceSuggestion(speakerId: Int64) {
        perform("dismiss voice suggestion") { try store.dismissSpeakerVoiceSuggestion(id: speakerId) }
    }

    /// Links a speaker directly to an existing voice (picked from a menu, not a suggestion).
    func setSpeakerVoice(speakerId: Int64, voiceId: Int64?) {
        perform("link speaker to voice") { try store.setSpeakerVoice(id: speakerId, voiceId: voiceId) }
    }

    /// All saved voice signatures, for the Voices management list and the "link to…" menu.
    func voices() -> [Voice] {
        (try? store.voices()) ?? []
    }

    func renameVoice(id: Int64, to name: String) {
        perform("rename voice") { try store.renameVoice(id: id, to: name) }
    }

    func deleteVoice(id: Int64) {
        perform("delete voice") { try store.deleteVoice(id: id) }
    }

    func deleteAllVoices() {
        perform("delete all voices") { try store.deleteAllVoices() }
    }
}

// MARK: - History paging

extension Library {
    /// One page of History, newest first, after `cursor`. See `HistoryPager`, which drives
    /// this from the History screen with keyset pagination instead of loading everything.
    func dictationPage(
        after cursor: Store.DictationCursor?, filter: Store.DictationPageFilter,
        dateRange: Store.DictationDateRange? = nil, pageSize: Int
    ) -> (items: [Dictation], hasMore: Bool) {
        (try? store.dictationPage(after: cursor, filter: filter, dateRange: dateRange, pageSize: pageSize)) ?? ([], false)
    }
}

/// Applies only the most recent of a burst of values, waiting for `interval` of quiet before
/// calling `apply`. Each `schedule` call cancels any pending apply and restarts the wait, so a
/// rapid sequence of database writes (a batch delete, several dictations back to back) produces
/// one `apply` call instead of one per value.
private final class DebouncedApply<Value: Sendable>: @unchecked Sendable {
    private let interval: Duration
    private let apply: @MainActor (Value) -> Void
    private let lock = NSLock()
    private var pendingTask: Task<Void, Never>?

    init(interval: Duration, apply: @escaping @MainActor (Value) -> Void) {
        self.interval = interval
        self.apply = apply
    }

    func schedule(_ value: Value) {
        lock.lock()
        pendingTask?.cancel()
        pendingTask = Task { [interval, apply] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await MainActor.run { apply(value) }
        }
        lock.unlock()
    }
}
