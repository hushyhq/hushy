import Foundation

/// The takes between a key release and their text being delivered, oldest first. Only the first one works: a later
/// take waits its turn (`DictationController.waitForTurn`), so words land in the order they were spoken and a take's
/// time budget starts only when it does.
struct TakeLine {
    private struct Entry {
        let id: UUID
        /// When this take must be done by, set once it starts. Past it, the take is stuck and a later one may go on.
        var mustEndBy: ContinuousClock.Instant?
    }

    private var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }
    func contains(_ id: UUID) -> Bool { entries.contains { $0.id == id } }
    func isFirst(_ id: UUID) -> Bool { entries.first?.id == id }
    func isLast(_ id: UUID) -> Bool { entries.last?.id == id }

    mutating func append(_ id: UUID) { entries.append(Entry(id: id, mustEndBy: nil)) }
    mutating func remove(_ id: UUID) { entries.removeAll { $0.id == id } }

    /// The take starts now and has until `limit` from `now`.
    mutating func start(_ id: UUID, limit: Duration, now: ContinuousClock.Instant = .now) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].mustEndBy = now.advanced(by: limit)
    }

    /// Drops the first take when it has run past its own limit and is not `id`, and returns it.
    mutating func dropStuckFirst(for id: UUID, now: ContinuousClock.Instant = .now) -> UUID? {
        guard let first = entries.first, first.id != id, let limit = first.mustEndBy, now > limit else { return nil }
        entries.removeFirst()
        return first.id
    }
}
