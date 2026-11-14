import Foundation
import MurmurCore

/// The long-meeting digest eval's data (`Evals/meeting-eval/golden.json`, built by
/// `scripts/meeting-eval/build_meetings.py`) and its scoring. Pure: no model, no I/O.
struct MeetingGolden: Codable {
    let meetings: [Meeting]

    struct Person: Codable {
        let name: String
        let label: String
    }

    /// A gold item. `terms` are groups of alternatives: the item matches a text when every
    /// group has at least one alternative in it (lower-cased substring), so matching is tolerant
    /// of wording but not of content.
    struct Item: Codable {
        let id: String
        let owner: String?
        let kind: String?
        let terms: [[String]]
        let dueTerms: [String]?
        let staleDueTerms: [String]?
        let final: String?
        let position: Double
        let quartile: Int
        let lastTenMinutes: Bool
    }

    struct Meeting: Codable {
        let id: String
        let title: String
        let minutes: Int
        let style: String
        let people: [Person]
        let words: Int
        let transcript: String
        let actionItems: [Item]
        let superseded: [Item]
        let decisions: [Item]
        let distractors: [Item]

        /// The speaker turns as diarization stores them, rendered by the app's own
        /// `DiarizedDigest.transcript(from:)`: a mic-only or named meeting gets "Speaker N" labels
        /// in order of first appearance (nobody renamed yet); a two-channel meeting keeps "You" +
        /// "Speaker N". Assumes diarization found the right turns.
        var appPathTranscript: String {
            var numbers: [String: String] = [:]
            let segments = transcript.split(separator: "\n").enumerated().map { index, line -> NoteSegmentWithSpeaker in
                let colon = line.firstIndex(of: ":")
                let label = colon.map { String(line[..<$0]) }
                let text = colon.map { String(line[line.index(after: $0)...]).trimmingCharacters(in: .whitespaces) } ?? String(line)
                let stored: String? = label.map { label in
                    if style != "names" { return label }
                    if let known = numbers[label] { return known }
                    let next = "Speaker \(numbers.count + 1)"
                    numbers[label] = next
                    return next
                }
                return NoteSegmentWithSpeaker(
                    segment: NoteSegment(noteId: 0, speakerId: nil, startTime: Double(index), endTime: Double(index) + 1, text: text, ordinal: index),
                    speaker: stored.map { NoteSpeaker(noteId: 0, label: $0) })
            }
            return DiarizedDigest.transcript(from: segments) ?? plainTranscript
        }

        /// Who each diarization label is, as the user would name them: "Speaker k" (first
        /// appearance) → name for in-room meetings; the golden "Speaker N" → name otherwise.
        var renames: [(label: String, name: String)] {
            if style != "names" {
                return people.filter { $0.label != $0.name && $0.label != "You" }.map { ($0.label, $0.name) }
            }
            var order: [String] = []
            for line in transcript.split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let label = String(line[..<colon])
                if !order.contains(label) { order.append(label) }
            }
            return order.enumerated().map { ("Speaker \($0.offset + 1)", $0.element) }
        }

        /// The transcript as the app summarizes it today: note text with no speaker labels
        /// (diarization runs after the summary).
        var plainTranscript: String {
            transcript.split(separator: "\n").map { line in
                guard let colon = line.firstIndex(of: ":"),
                      people.contains(where: { $0.label == line[..<colon] }) else { return String(line) }
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }.joined(separator: " ")
        }
    }
}

/// One meeting's score for one digest.
struct MeetingScore: Codable {
    var goldActions = 0
    var actionsFound = 0          // task and owner right
    var actionTasksFound = 0      // task right, any owner
    var predictedActions = 0
    var predictedMatchingGold = 0 // predicted items whose task is a gold item's
    var smallTalkItems = 0        // predicted items that are a distractor
    var staleItems = 0            // predicted items that are a cancelled or superseded version
    var hallucinatedOwners = 0
    var goldDecisions = 0
    var decisionsFound = 0
    var corrections = 0
    var correctionsApplied = 0
    var duesChecked = 0
    var duesRight = 0
    /// Found / total, per quartile of the meeting (action items and decisions together).
    var quartileFound = [0, 0, 0, 0]
    var quartileTotal = [0, 0, 0, 0]
    var missed: [String] = []

    mutating func add(_ other: MeetingScore) {
        goldActions += other.goldActions; actionsFound += other.actionsFound; actionTasksFound += other.actionTasksFound
        predictedActions += other.predictedActions; predictedMatchingGold += other.predictedMatchingGold
        smallTalkItems += other.smallTalkItems; staleItems += other.staleItems; hallucinatedOwners += other.hallucinatedOwners
        goldDecisions += other.goldDecisions; decisionsFound += other.decisionsFound
        corrections += other.corrections; correctionsApplied += other.correctionsApplied
        duesChecked += other.duesChecked; duesRight += other.duesRight
        for q in 0..<4 { quartileFound[q] += other.quartileFound[q]; quartileTotal[q] += other.quartileTotal[q] }
        missed += other.missed
    }
}

enum MeetingScoring {
    static func matches(_ text: String, _ terms: [[String]]) -> Bool {
        let lower = text.lowercased()
        return !terms.isEmpty && terms.allSatisfy { group in group.contains { lower.contains($0.lowercased()) } }
    }

    /// Whether `item` names `owner`: the name as a word, or for the note owner ("You") a
    /// "You:" prefix or first-person/second-person wording.
    static func names(_ item: String, owner: String) -> Bool {
        if owner == "You" {
            return item.hasPrefix("You:") || Self.word(item, in: ["you", "me", "myself", "i", "user", "note owner"])
        }
        return word(item, in: [owner.lowercased()])
    }

    private static func word(_ text: String, in words: [String]) -> Bool {
        let tokens = Set(text.lowercased().components(separatedBy: CharacterSet.letters.inverted))
        return words.contains { candidate in
            candidate.contains(" ") ? text.lowercased().contains(candidate) : tokens.contains(candidate)
        }
    }

    /// The owner an item string assigns: "Owner: task" (the new format), else a leading
    /// capitalized name followed by "to"/"will"/"should"/"is"/"needs" (free-text items).
    static func statedOwner(_ item: String) -> String? {
        if let colon = item.firstIndex(of: ":"), item.distance(from: item.startIndex, to: colon) <= 30 {
            return String(item[..<colon]).trimmingCharacters(in: .whitespaces)
        }
        let words = item.split(separator: " ").map(String.init)
        guard let first = words.first, first.first?.isUppercase == true, words.count > 2 else { return nil }
        let verbs: Set<String> = ["to", "will", "should", "is", "needs", "must", "and", "owns", "takes", "'ll"]
        if verbs.contains(words[1].lowercased()) { return first }
        if words.count > 3, words[1].first?.isUppercase == true, verbs.contains(words[2].lowercased()) {
            return "\(first) \(words[1])"
        }
        return nil
    }

    private static let genericOwners: Set<String> = [
        "you", "i", "me", "we", "team", "the team", "everyone", "all", "unassigned", "none", "tbd", "someone", "group",
    ]

    /// An owner is hallucinated when it's not generic and some word of it never occurs in the
    /// transcript (labels included).
    static func isHallucinated(owner: String, transcript: String) -> Bool {
        let cleaned = owner.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        guard !cleaned.isEmpty, !genericOwners.contains(cleaned.lowercased()) else { return false }
        let known = Set(transcript.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted))
        let parts = cleaned.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 }
        return parts.contains { !known.contains($0) }
    }

    static func score(meeting: MeetingGolden.Meeting, summary: String, actionItems: [String], transcript: String) -> MeetingScore {
        var score = MeetingScore()
        scoreActions(meeting, actionItems, &score)
        scoreDecisions(meeting, summary, &score)
        scoreCorrections(meeting, actionItems, &score)
        score.predictedActions = actionItems.count
        for item in actionItems {
            if meeting.actionItems.contains(where: { matches(item, $0.terms) }) { score.predictedMatchingGold += 1 }
            if meeting.distractors.contains(where: { matches(item, $0.terms) }) { score.smallTalkItems += 1 }
            if let owner = statedOwner(item), isHallucinated(owner: owner, transcript: transcript) { score.hallucinatedOwners += 1 }
        }
        return score
    }

    private static func scoreActions(_ meeting: MeetingGolden.Meeting, _ predicted: [String], _ score: inout MeetingScore) {
        for gold in meeting.actionItems {
            score.goldActions += 1
            let candidates = predicted.filter { matches($0, gold.terms) }
            let owned = candidates.filter { names($0, owner: gold.owner ?? "") }
            let quartile = gold.quartile - 1
            score.quartileTotal[quartile] += 1
            if !candidates.isEmpty { score.actionTasksFound += 1 }
            if let found = owned.first {
                score.actionsFound += 1
                score.quartileFound[quartile] += 1
                if let due = gold.dueTerms, !due.isEmpty {
                    score.duesChecked += 1
                    if due.contains(where: { found.lowercased().contains($0) }) { score.duesRight += 1 }
                }
            } else {
                score.missed.append("\(meeting.id)/\(gold.id) Q\(gold.quartile)\(candidates.isEmpty ? "" : " (wrong owner)")")
            }
        }
    }

    private static func scoreDecisions(_ meeting: MeetingGolden.Meeting, _ summary: String, _ score: inout MeetingScore) {
        let lines = summary.split(separator: "\n").map(String.init)
        for gold in meeting.decisions {
            score.goldDecisions += 1
            let quartile = gold.quartile - 1
            score.quartileTotal[quartile] += 1
            if lines.contains(where: { matches($0, gold.terms) }) {
                score.decisionsFound += 1
                score.quartileFound[quartile] += 1
            } else {
                score.missed.append("\(meeting.id)/\(gold.id) Q\(gold.quartile) decision")
            }
        }
    }

    /// Cancelled: no item for it. Reassigned: the new owner has it and no item gives it to the
    /// old owner alone. Rescheduled: the item carries the new date, not the old one.
    private static func scoreCorrections(_ meeting: MeetingGolden.Meeting, _ predicted: [String], _ score: inout MeetingScore) {
        for old in meeting.superseded {
            score.corrections += 1
            let about = predicted.filter { matches($0, old.terms) }
            let final = old.final.flatMap { id in meeting.actionItems.first { $0.id == id } }
            var applied: Bool
            var stale: Int
            switch old.kind {
            case "cancelled":
                stale = about.count
                applied = about.isEmpty
            case "reassigned":
                let newOwner = final?.owner ?? ""
                stale = about.filter { names($0, owner: old.owner ?? "") && !names($0, owner: newOwner) }.count
                applied = stale == 0 && about.contains { names($0, owner: newOwner) }
            default: // rescheduled
                let due = final?.dueTerms ?? [], staleDue = final?.staleDueTerms ?? []
                stale = about.filter { item in staleDue.contains { item.lowercased().contains($0) } && !due.contains { item.lowercased().contains($0) } }.count
                applied = stale == 0 && about.contains { item in due.contains { item.lowercased().contains($0) } }
            }
            score.staleItems += stale
            if applied { score.correctionsApplied += 1 } else { score.missed.append("\(meeting.id)/\(old.id) correction (\(old.kind ?? "?"))") }
        }
    }
}
