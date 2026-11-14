import Foundation

/// What the model wrote about one meeting, as typed rows rather than summary text. This is the
/// seam for the own-model branch (`feat/meetings-own-model`): it will store decisions and action
/// items as rows and hand them over through a `MeetingDigestSource`. Until then,
/// `StoredSummaryDigest` reads them back out of the summary lines `NoteDigestMerge` writes
/// ("- Decided: …") and the note's action-item fields.
public struct MeetingDigestRows: Sendable, Equatable {
    public struct Decision: Sendable, Equatable, Hashable {
        public var text: String
        /// Recording time the decision was made, when the source knows it; otherwise the page
        /// finds the moment in the transcript (`MeetingMomentLocator`).
        public var atSeconds: Double?
        public init(text: String, atSeconds: Double? = nil) {
            self.text = text
            self.atSeconds = atSeconds
        }
    }

    public struct ActionItem: Sendable, Equatable, Hashable {
        /// Index into `Note.actionItems`, which is what check-offs are keyed by.
        public var index: Int
        public var detail: ActionItemDetail
        public var atSeconds: Double?
        public init(index: Int, detail: ActionItemDetail, atSeconds: Double? = nil) {
            self.index = index
            self.detail = detail
            self.atSeconds = atSeconds
        }
    }

    public var keyPoints: [String]
    public var decisions: [Decision]
    public var actionItems: [ActionItem]
    public var openQuestions: [String]

    public init(keyPoints: [String] = [], decisions: [Decision] = [], actionItems: [ActionItem] = [], openQuestions: [String] = []) {
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
    }

    public var isEmpty: Bool { keyPoints.isEmpty && decisions.isEmpty && actionItems.isEmpty && openQuestions.isEmpty }
}

/// Where a meeting page gets its model-written rows. Swap the implementation, not the page.
public protocol MeetingDigestSource: Sendable {
    func rows(for note: Note) -> MeetingDigestRows
}

/// Today's source: the rows recovered from the note's stored summary and action-item fields.
public struct StoredSummaryDigest: MeetingDigestSource {
    public init() {}

    public func rows(for note: Note) -> MeetingDigestRows {
        var rows = MeetingDigestRows()
        for raw in note.summary.components(separatedBy: "\n") {
            let line = Self.bulletless(raw)
            guard !line.isEmpty, !Self.isSectionHeading(line) else { continue }
            if let decision = Self.decisionText(line) {
                rows.decisions.append(.init(text: decision))
            } else if line.hasSuffix("?") {
                rows.openQuestions.append(line)
            } else {
                rows.keyPoints.append(line)
            }
        }
        rows.actionItems = note.actionItems.indices.map { index in
            let detail = note.actionItemDetail(at: index)
                ?? ActionItemDetail(owner: "", task: note.actionItems[index], due: "")
            return .init(index: index, detail: detail)
        }
        return rows
    }

    static func bulletless(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        for bullet in ["- ", "• ", "* "] where text.hasPrefix(bullet) {
            text = String(text.dropFirst(bullet.count))
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// "Decided: ship Friday" and "Decision: ship Friday" are decisions.
    static func decisionText(_ line: String) -> String? {
        for prefix in ["Decided:", "Decision:", "Decided -", "Agreed:"] where line.lowercased().hasPrefix(prefix.lowercased()) {
            let text = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    /// Long-meeting summaries can carry their own section headings ("Decisions", "## Topics").
    static func isSectionHeading(_ line: String) -> Bool {
        line.hasPrefix("#") || ["decisions", "key points", "action items", "summary"].contains(line.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":")))
    }
}
