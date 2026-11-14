import MurmurCore
import SwiftUI

/// Invented action items for the snapshots (no real note is read).
enum ActionItemSnapshots {
    static let weeklySync = [
        ActionItemDetail(owner: "Priya", task: "Ship snapshot tooling", due: "by Friday"),
        ActionItemDetail(owner: "Leo", task: "Follow up with design on onboarding copy", due: ""),
        ActionItemDetail(owner: "", task: "Book the room for the offsite", due: "next week"),
        ActionItemDetail(owner: "Dana Whitfield-Okonkwo", task: "Send the revised budget to finance and the board with the new headcount table", due: "end of month"),
    ]
}

/// The note's action items card with owners and due dates (a note with fields), next to the same
/// card for an older note that has only lines. One item is checked off in each.
extension Snapshots {
    static func renderActionItems(scheme: ColorScheme, directory: URL) async {
        let with = weeklyCard(
            title: "With owners and dates",
            rows: ActionItemSnapshots.weeklySync.map { ($0.task, $0.owner, $0.due) })
        let without = weeklyCard(
            title: "An older note (lines only)",
            rows: ActionItemSnapshots.weeklySync.map { ($0.line, "", "") })
        await capture(
            VStack(alignment: .leading, spacing: Theme.Space.xl) { with; without }.padding(Theme.Space.xl),
            name: "notes-action-items", scheme: scheme, size: CGSize(width: 560, height: 560), directory: directory,
            fixedSize: true)
    }

    private static func weeklyCard(title: String, rows: [(String, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Eyebrow(title)
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        ActionItemRow(text: row.0, owner: row.1, due: row.2, isDone: index == 1, toggle: {})
                    }
                }
            }
        }
    }

    /// The Assistant column's open-items list (the Home card is the same component): fielded items
    /// with owner and due under the task, an older line-only note, and the user's own item first.
    static func renderOpenActionItems(scheme: ColorScheme, directory: URL) async {
        var recent = Note(id: 1, title: "Weekly sync", transcript: "t", status: .ready)
        recent.setActionItems(ActionItemSnapshots.weeklySync.map(\.line), details: ActionItemSnapshots.weeklySync)
        var mineNote = Note(id: 2, title: "Design review", transcript: "t", status: .ready)
        let mine = [ActionItemDetail(owner: "You", task: "Reply to the vendor about the contract", due: "tomorrow")]
        mineNote.setActionItems(mine.map(\.line), details: mine)
        var older = Note(id: 3, title: "Planning (older note)", transcript: "t", status: .ready)
        older.setActionItems(["Leo: Order the cake — Monday"], details: nil)
        let items = OpenActionItems.select(
            notes: [recent, mineNote, older], isDone: { _, _ in false },
            mine: OpenActionItems.myNames(userName: nil))
        let list = VStack(alignment: .leading, spacing: Theme.Space.s) {
            Eyebrow("Open action items")
            VStack(alignment: .leading, spacing: Theme.Space.s + 2) {
                ForEach(items) { item in
                    ActionItemToggleRow(
                        text: item.text, secondary: item.secondary, noteTitle: item.note.title, isDone: false, toggle: {})
                }
            }
        }
        await capture(
            list.padding(Theme.Space.xl).frame(width: 340, alignment: .leading),
            name: "assistant-open-action-items", scheme: scheme, size: CGSize(width: 340, height: 560),
            directory: directory, fixedSize: true)
    }
}
