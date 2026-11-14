import Foundation

/// Preparation is complete or absent; finishing never awaits I/O.
public struct PersonBlockAssembler: Sendable {
    public struct Prepared: Sendable {
        public let index: MemoryIndex
        public let app: String
        public let earlier: [String]
        public let paused: Bool
        public let learned: [LearnedItem]

        public init(index: MemoryIndex, app: String, earlier: [String], paused: Bool, learned: [LearnedItem] = []) {
            self.index = index
            self.app = app
            self.earlier = earlier
            self.paused = paused
            self.learned = learned
        }
    }

    public static func prepare(memory: MemoryStore, history: Store, app: String,
                               now: Date = Date()) async throws -> Prepared {
        let index = try await memory.index()
        let paused = try await memory.isPaused()
        // Oldest first, as in training: the newest sits nearest the transcript.
        let earlier = Array(try history.recentInApp(app, on: now).map(\.text).reversed())
        // The word table indexes itself on first use; do it here, not in `finish`.
        _ = LearningLexicon.isCommonWord("")
        return Prepared(index: index, app: app, earlier: earlier, paused: paused, learned: try history.learnedItems())
    }

    /// The learned-only block does not read Memory files, profile notes or prior dictations.
    public static func prepareLearned(history: Store, app: String) throws -> Prepared {
        _ = LearningLexicon.isCommonWord("")
        return Prepared(index: MemoryIndex(entries: []), app: app, earlier: [], paused: false,
                        learned: try history.learnedItems())
    }

    public static func finish(_ prepared: Prepared?, transcript: String) -> PersonBlock? {
        guard let prepared, !prepared.paused else { return nil }
        // Elsewhere Hushy leaves the heard word alone; naming the learned spelling would undo that.
        let activeTerms = prepared.learned.filter { $0.kind == .term && $0.status == .active && $0.applies(inApp: prepared.app) }
            .map { MemoryEntry(kind: .term, value: $0.value, heardAs: $0.heardAs,
                               createdAt: $0.createdAt, origin: .learned) }
        let forgotten = Set(prepared.learned.filter { $0.kind == .term && $0.status == .forgotten && $0.appBundleID == nil }.map { MemoryIndex.key($0.key) })
        let mergedEntries = prepared.index.entries.filter { entry in
            entry.kind != .term || entry.origin != .learned || !forgotten.contains(MemoryIndex.key(entry.value))
        }.map { entry in
            guard entry.kind == .term else { return entry }
            var merged = entry
            let aliases = activeTerms.filter { MemoryIndex.key($0.value) == MemoryIndex.key(entry.value) }.flatMap(\.heardAs)
            merged.heardAs = Array(Set(entry.heardAs + aliases)).sorted()
            return merged
        }
        let index = MemoryIndex(entries: mergedEntries + activeTerms)
        // Every profile note, in the order the file has them.
        let notes = index.entries.filter { $0.kind == .profile }.map(\.value)
        let profile = notes.isEmpty ? nil : notes.joined(separator: "; ")
        let ownStyle = index.stylesByApp[prepared.app]?.sorted { $0.createdAt > $1.createdAt }.first?.value
        let hint = PreferenceHints.from(prepared.learned, bundleID: prepared.app).promptLine
        // An explicit note wins as a whole: inferred habits cannot contradict what the
        // person chose, and parsing prose to detect conflicts would be unreliable.
        let style = ownStyle ?? hint
        // The three most recent in this app, oldest first, like the earlier dictations.
        let edits = (index.correctionsByApp[prepared.app] ?? []).enumerated()
            .sorted { ($0.element.createdAt, $0.offset) > ($1.element.createdAt, $1.offset) }
            .prefix(3).reversed().map(\.element)
            .compactMap { entry -> (before: String, after: String)? in
                guard let before = entry.before, let after = entry.after else { return nil }
                return (before, after)
            }
        let block = PersonBlock(profile: profile, style: style,
                                terms: TermRecall.recall(transcript, from: index).map(\.value),
                                earlier: prepared.earlier, edits: edits)
        return block.render() == nil ? nil : block
    }
}
