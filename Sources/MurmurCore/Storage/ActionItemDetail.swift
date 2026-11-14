import Foundation

/// One action item as fields: who, what, by when, each as the summary wrote it (the due date is a
/// phrase like "by Friday", never parsed into a date). Stored next to the one-line strings in
/// `Note.actionItems` so old notes, check-offs (keyed by index) and every reader of the strings
/// keep working. Personal data: never log or put it in metrics.
public struct ActionItemDetail: Codable, Sendable, Equatable, Hashable {
    /// The person it is for; empty when nobody took it.
    public var owner: String
    public var task: String
    /// "by Friday", "next week"; empty when no time was said.
    public var due: String

    public init(owner: String = "", task: String, due: String = "") {
        self.owner = owner
        self.task = task
        self.due = due
    }

    /// The one-line form kept in `Note.actionItems`: "Priya: Send the deck — by Friday". No owner
    /// prefix without an owner, no suffix without a due date or when the task already says it.
    public var line: String {
        var text = task
        if !due.isEmpty, !task.localizedCaseInsensitiveContains(due) { text += " — \(due)" }
        return owner.isEmpty ? text : "\(owner): \(text)"
    }

    /// "Priya · by Friday", or only what is there; empty when neither is. The secondary text under
    /// a task wherever the app lists one (the note, the Assistant's open items).
    public static func secondaryText(owner: String, due: String) -> String {
        [owner, due].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public var secondaryText: String { Self.secondaryText(owner: owner, due: due) }

    /// Whether the owner field names one of `names` (ignoring case and spaces): "You", the user's
    /// own name from Settings. An empty owner is nobody's, and an owner is never inferred from the
    /// task's sentence.
    public func isOwned(by names: [String]) -> Bool {
        let who = owner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !who.isEmpty && names.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == who }
    }

    /// `details` if they line up with `count` items (same count, so item `i` is item `i`), else nil.
    /// The one definition of that rule; everything that pairs fields with lines goes through it.
    public static func aligned(_ details: [ActionItemDetail]?, count: Int) -> [ActionItemDetail]? {
        details?.count == count ? details : nil
    }

    /// An item known only as a sentence (an old note, or an item kept from one): the whole line is
    /// the task, with no owner or due date.
    public static func plain(_ line: String) -> ActionItemDetail { ActionItemDetail(task: line) }
}

extension Note {
    /// The action items as fields, or nil for a note that has only the strings (every note from
    /// before migration v18, and any summary that came from the extractive fallback).
    ///
    /// The one place the invariant lives: the details are returned only while they have exactly
    /// as many entries as `actionItems`, item `i` of one being item `i` of the other. Anything
    /// that changes the count (`actionItems.didSet`), and anything that sets the two together
    /// (`setActionItems`), keeps it; a stored list that disagrees reads as nil, never as a wrong
    /// owner on the wrong item.
    public var actionItemDetails: [ActionItemDetail]? {
        ActionItemDetail.aligned(storedActionItemDetails, count: actionItems.count)
    }

    /// Replaces the items and their fields together. `details` must line up with `items`; a list
    /// of the wrong length is dropped and the note keeps the strings alone.
    public mutating func setActionItems(_ items: [String], details: [ActionItemDetail]?) {
        storedActionItemDetails = nil
        actionItems = items
        storedActionItemDetails = ActionItemDetail.aligned(details, count: items.count)
    }

    /// Sets the items from a summary's output (the lines, and the fields when it has them).
    public mutating func setActionItems(from output: ExtractiveSummarizer.Output) {
        setActionItems(output.actionItems, details: output.actionDetails)
    }

    /// Item `index` as fields: the stored ones, or the whole line as the task for a note without.
    public func actionItemDetail(at index: Int) -> ActionItemDetail? {
        guard actionItems.indices.contains(index) else { return nil }
        return actionItemDetails?[index] ?? .plain(actionItems[index])
    }
}
