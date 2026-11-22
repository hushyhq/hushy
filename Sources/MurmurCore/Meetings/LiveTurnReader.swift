import Foundation

/// What the live screen shows of a recording in progress: the note's capture turns (`origin == .capture`), by `t0`,
/// read from the store, which is the only place they live. Each refresh asks only for rows it has not seen (one
/// indexed lookup that is empty most seconds) and reads everything again only when the rows were replaced (a new note,
/// or an assembly). Words are dropped: the screen shows text.
public struct LiveTurnReader: Sendable {
    public private(set) var noteId: Int64?
    public private(set) var turns: [NoteTurn] = []
    private var lastId: Int64 = 0

    public init() {}

    /// Brings `turns` up to date with the store; true when they changed.
    @discardableResult
    public mutating func refresh(noteId: Int64, store: Store) throws -> Bool {
        if self.noteId != noteId { self = LiveTurnReader(); self.noteId = noteId }
        let added = try store.turns(noteId: noteId, origin: .capture, afterId: lastId)
        let count = try store.turnCount(noteId: noteId, origin: .capture)
        if count != turns.count + added.count {
            let all = try store.turns(noteId: noteId, origin: .capture, afterId: 0)
            let changed = all.map(\.id) != turns.map(\.id)
            turns = all.map(Self.shown)
            lastId = all.compactMap(\.id).max() ?? 0
            return changed
        }
        guard !added.isEmpty else { return false }
        turns = (turns + added.map(Self.shown)).sorted { ($0.t0 ?? 0, $0.ordinal) < ($1.t0 ?? 0, $1.ordinal) }
        lastId = max(lastId, added.compactMap(\.id).max() ?? 0)
        return true
    }

    private static func shown(_ turn: NoteTurn) -> NoteTurn {
        var turn = turn
        turn.words = nil
        return turn
    }
}
