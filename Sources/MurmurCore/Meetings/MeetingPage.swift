import Foundation

/// The one page a meeting becomes: the person's own lines, then what was decided, who owes what by
/// when, what is still open, and the transcript underneath as evidence. Every row carries who wrote
/// it (you or the model) and, when it can be found, the moment it was said. Built by a pure
/// function from stored values, so the page, the tests and the snapshots all read the same thing.
public struct MeetingPage: Sendable, Equatable {
    public enum Author: Sendable, Equatable { case you, model }

    public struct Row: Sendable, Equatable, Identifiable {
        public let id: String
        public let text: String
        public let author: Author
        public let moment: MeetingMoment?

        public init(id: String, text: String, author: Author, moment: MeetingMoment?) {
            self.id = id
            self.text = text
            self.author = author
            self.moment = moment
        }
    }

    public struct Commitment: Sendable, Equatable, Identifiable {
        public var id: Int { itemIndex }
        public let itemIndex: Int
        public let task: String
        public let owner: String
        public let due: String
        public let isMine: Bool
        public let isDone: Bool
        public let moment: MeetingMoment?
        /// The fact behind the row, which a check-off changes; nil for a row not from facts.
        public var factUUID: String? = nil

        /// "Priya · by Friday", "You · by Friday", or only what is known.
        public var whoAndWhen: String {
            ActionItemDetail.secondaryText(owner: isMine ? "You" : owner, due: due)
        }
    }

    public let yourNotes: [Row]
    public let decisions: [Row]
    public let commitments: [Commitment]
    public let openQuestions: [Row]
    public let keyPoints: [Row]
    public let transcript: [MeetingLine]
    /// Distinct speakers in order of first appearance.
    public let speakers: [String]

    public var mine: [Commitment] { commitments.filter(\.isMine) }
    public var theirs: [Commitment] { commitments.filter { !$0.isMine } }
    public var hasTimedTranscript: Bool { !transcript.isEmpty }

    public static func build(
        rows: MeetingDigestRows, lines: [MeetingLine], jots: [MeetingJot], doneIndexes: Set<Int>, myNames: [String]
    ) -> MeetingPage {
        let locate = { (text: String, hint: Double?) in MeetingMomentLocator.moment(for: text, in: lines, hintSeconds: hint) }
        // A typed line that starts with "!" is a decision in the person's own words.
        let typedDecisions = jots.filter(\.isDecision).map { jot in
            Row(id: "d-jot-\(jot.id ?? 0)", text: jot.shownText, author: .you,
                moment: jot.atSeconds.map { locate(jot.text, $0) } ?? nil)
        }
        let notes = jots.map { jot in
            Row(id: "jot-\(jot.id ?? 0)-\(jot.createdAt.timeIntervalSince1970)", text: jot.shownText, author: .you,
                moment: jot.atSeconds.map { locate(jot.text, $0) } ?? nil)
        }
        // The model's restatement of a decision the person typed is dropped; their wording stays.
        let typedDecisionWords = typedDecisions.map { MeetingWords.content($0.text) }
        let decisions = rows.decisions
            .filter { decision in !typedDecisionWords.contains { MeetingWords.restates($0, MeetingWords.content(decision.text)) } }
            .enumerated().map { index, decision in
            Row(id: "decision-\(index)", text: decision.text, author: .model, moment: locate(decision.text, decision.atSeconds))
        }
        let commitments = rows.actionItems.map { item in
            Commitment(
                itemIndex: item.index, task: item.detail.task, owner: item.detail.owner, due: item.detail.due,
                isMine: item.detail.isOwned(by: myNames), isDone: item.isDone ?? doneIndexes.contains(item.index),
                moment: locate("\(item.detail.owner) \(item.detail.task)", item.atSeconds), factUUID: item.factUUID)
        }
        // A typed line that asks something is an open question in the person's own words.
        let askedByYou = jots.filter(\.isQuestion).map { jot in
            Row(id: "q-jot-\(jot.id ?? 0)", text: jot.shownText, author: .you, moment: jot.atSeconds.map { locate(jot.text, $0) } ?? nil)
        }
        let yours = askedByYou.map(\.text)
        let askedInDigest = rows.openQuestions.filter { MeetingWords.withoutRepeats(yours + [$0]).count > yours.count }
            .enumerated().map { index, question in
            Row(id: "q-\(index)", text: question, author: .model, moment: locate(question, nil))
        }
        let keyPoints = rows.keyPoints.enumerated().map { index, point in
            Row(id: "point-\(index)", text: point, author: .model, moment: locate(point, nil))
        }
        var seen = Set<String>()
        let speakers = lines.compactMap(\.speaker).filter { seen.insert($0).inserted }
        return MeetingPage(
            yourNotes: notes, decisions: typedDecisions + decisions, commitments: commitments,
            openQuestions: askedByYou + askedInDigest, keyPoints: keyPoints, transcript: lines, speakers: speakers)
    }

    /// The names that mean "me" in owner fields: "You", the Settings name and its first word.
    public static func myNames(userName: String) -> [String] {
        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        var names = ["You", "Me", "I"]
        if !name.isEmpty {
            names.append(name)
            if let first = name.split(separator: " ").first, first.count < name.count { names.append(String(first)) }
        }
        return names
    }
}
