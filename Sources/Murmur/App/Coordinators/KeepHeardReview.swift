import MurmurCore
import Observation

/// Undo state for app-specific exceptions. Database rows remain Library's source of truth.
@MainActor
@Observable
final class KeepHeardReview {
    struct Row: Identifiable {
        let entry: KeepHeardEntry
        let forgotten: Bool
        var id: Int64 { entry.id ?? -1 }
    }

    private var snapshots: [Int64: KeepHeardEntry] = [:]
    @ObservationIgnored private let forgetEntry: (KeepHeardEntry) -> Void
    @ObservationIgnored private let restoreEntry: (KeepHeardEntry) -> Void

    init(forget: @escaping (KeepHeardEntry) -> Void, restore: @escaping (KeepHeardEntry) -> Void) {
        forgetEntry = forget
        restoreEntry = restore
    }

    func rows(entries: [KeepHeardEntry]) -> [Row] {
        entries.compactMap { entry in
            guard let id = entry.id else { return nil }
            if let before = snapshots[id], entry.status == .forgotten {
                return Row(entry: before, forgotten: true)
            }
            return entry.status == .active ? Row(entry: entry, forgotten: false) : nil
        }
    }

    func forget(_ entry: KeepHeardEntry) {
        guard let id = entry.id else { return }
        snapshots[id] = snapshots[id] ?? entry
        forgetEntry(entry)
    }

    func undo(_ id: Int64) {
        guard let before = snapshots.removeValue(forKey: id) else { return }
        restoreEntry(before)
    }
}
