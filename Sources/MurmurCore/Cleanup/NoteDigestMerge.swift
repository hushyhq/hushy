import Foundation

/// The deterministic parts of `NoteSummarizer`: rendering piece notes for the merge call,
/// dropping the duplicates chunk overlap creates, the fallback merge when the merge call fails,
/// extractive notes for a piece whose calls failed, and the final note fields.
enum NoteDigestMerge {
    static let maxKeyPoints = 8
    static let maxDecisions = 8
    static let maxActionItems = 20

    // MARK: - Final note fields

    /// Title, a bullet summary (key points, then "Decided: …" lines) and action item strings
    /// ("Owner: Task — due").
    static func output(_ digest: MeetingDigest, fallbackTitle: String) -> ExtractiveSummarizer.Output {
        let title = oneLine(digest.title)
        let points = unique(digest.keyPoints.map(oneLine)).prefix(maxKeyPoints).map { "- \(Punctuation.stripTrailing($0))" }
        let decisions = unique(digest.decisions.map(oneLine)).prefix(maxDecisions).map { "- Decided: \(Punctuation.stripTrailing($0))" }
        let details = uniqueItems(digest.actionItems).prefix(maxActionItems).map(detail)
        return ExtractiveSummarizer.Output(
            title: title.isEmpty ? fallbackTitle : Punctuation.stripTrailing(title),
            summary: (points + decisions).joined(separator: "\n"),
            actionItems: details.map(\.line), actionDetails: details)
    }

    /// "Priya: Send the deck to legal — by Friday". No owner prefix when nobody took it.
    static func render(_ item: DigestActionItem) -> String { detail(item).line }

    /// The item as fields, tidied the way the one-line form needs: one line each, the task
    /// capitalised without its final full stop, and a placeholder owner or due date ("TBD") empty.
    static func detail(_ item: DigestActionItem) -> ActionItemDetail {
        var task = Punctuation.stripTrailing(oneLine(item.task))
        task = task.prefix(1).uppercased() + task.dropFirst()
        let due = Punctuation.stripTrailing(oneLine(item.due))
        return ActionItemDetail(
            owner: namedOwner(item.owner) ?? "", task: task, due: placeholderDues.contains(due.lowercased()) ? "" : due)
    }

    private static let placeholderOwners: Set<String> = [
        "", "none", "nobody", "n/a", "na", "unknown", "unassigned", "tbd", "unspecified", "not specified", "anyone",
    ]

    private static let placeholderDues: Set<String> = [
        "", "none", "n/a", "na", "tbd", "pending", "not specified", "unspecified", "no date", "not said", "unknown",
    ]

    /// Models sometimes break a string across lines (around a quoted word); a note line is one line.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "-" }.joined(separator: " ")
    }

    static func namedOwner(_ owner: String) -> String? {
        let trimmed = Punctuation.stripTrailing(oneLine(owner))
        return placeholderOwners.contains(trimmed.lowercased()) ? nil : trimmed
    }

    // MARK: - Merge input

    /// Piece notes as the merge call reads them, in meeting order, then the numbered
    /// candidate action items (`candidates(_:)`) tagged with the part they came from.
    static func render(_ parts: [MeetingPartNotes]) -> String {
        let notes = parts.enumerated().map { index, part in
            var lines = ["Part \(index + 1) of \(parts.count):"]
            lines += section("Decisions", part.decisions)
            lines += section("Changes", part.changes)
            lines += section("Key points", part.keyPoints)
            return lines.joined(separator: "\n")
        }
        let items = candidates(parts).enumerated().map { number, candidate in
            "\(number + 1). \(listLine(candidate.item)) [part \(candidate.part + 1)]"
        }
        let list = items.isEmpty ? "Action items noted during the meeting: none" :
            "Action items noted during the meeting, in order:\n" + items.joined(separator: "\n")
        return (notes + [list]).joined(separator: "\n\n")
    }

    /// Every part's items in meeting order; a later item for the same task (same wording, any
    /// owner) replaces the earlier one in place — the later part heard the latest version.
    static func candidates(_ parts: [MeetingPartNotes]) -> [(item: DigestActionItem, part: Int)] {
        var result: [(item: DigestActionItem, part: Int)] = []
        for (index, part) in parts.enumerated() {
            for item in part.actionItems where !item.task.trimmingCharacters(in: .whitespaces).isEmpty {
                if let existing = result.firstIndex(where: { similar($0.item.task, item.task) }) {
                    result[existing] = (item, index)
                } else {
                    result.append((item, index))
                }
            }
        }
        return result
    }

    /// The merge answer applied to the candidates: owner/date updates and drops by number. A
    /// drop needs evidence — a later part's changes mention the task, or another item is
    /// nearly the same task — because a small model otherwise drops items it merely skipped.
    static func apply(_ merge: MeetingMerge, to parts: [MeetingPartNotes]) -> MeetingDigest {
        let numbered = candidates(parts)
        var items = numbered.map(\.item)
        for update in merge.updates where items.indices.contains(update.item - 1) {
            let owner = update.owner.trimmingCharacters(in: .whitespaces), due = update.due.trimmingCharacters(in: .whitespaces)
            if !owner.isEmpty { items[update.item - 1].owner = owner }
            if !due.isEmpty { items[update.item - 1].due = due }
        }
        let dropped = Set(merge.dropItems.map { $0 - 1 }.filter { index in
            guard numbered.indices.contains(index) else { return false }
            let task = numbered[index].item.task
            let later = parts.dropFirst(numbered[index].part).flatMap(\.changes)
            return later.contains { mentions($0, task) }
                || numbered.indices.contains { $0 != index && similar(numbered[$0].item.task, task, threshold: 0.4) }
        })
        let kept = items.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
        return MeetingDigest(title: merge.title, keyPoints: merge.keyPoints, decisions: merge.decisions, actionItems: kept)
    }

    private static func section(_ name: String, _ items: [String]) -> [String] {
        let kept = items.map(oneLine).filter { !$0.isEmpty }
        return kept.isEmpty ? [] : ["\(name):"] + kept.map { "- \($0)" }
    }

    private static func listLine(_ item: DigestActionItem) -> String {
        let owner = namedOwner(item.owner) ?? "(no owner)"
        let due = oneLine(item.due)
        return "\(owner): \(oneLine(item.task))" + (placeholderDues.contains(due.lowercased()) ? "" : " (due: \(due))")
    }

    /// A merged half, as one "part" for the next merge; `changes` are the half's own, so a later
    /// half's changes can still reach it.
    static func partNotes(from digest: MeetingDigest, changes: [String]) -> MeetingPartNotes {
        MeetingPartNotes(decisions: digest.decisions, actionItems: digest.actionItems, changes: changes, keyPoints: digest.keyPoints)
    }

    /// Drops items a piece repeats from the piece before it (the overlap is read twice).
    static func dedupedAcrossOverlap(_ parts: [MeetingPartNotes]) -> [MeetingPartNotes] {
        var result: [MeetingPartNotes] = []
        for part in parts {
            guard let previous = result.last else { result.append(part); continue }
            var copy = part
            copy.actionItems = part.actionItems.filter { item in !previous.actionItems.contains { sameItem($0, item) } }
            copy.decisions = part.decisions.filter { decision in !previous.decisions.contains { similar($0, decision) } }
            result.append(copy)
        }
        return result
    }

    // MARK: - Speaker names

    /// "Speaker N" → the name most parts gave it (ties and name clashes left unresolved).
    static func speakerNames(_ parts: [MeetingPartNotes]) -> [String: String] {
        var votes: [String: [String: Int]] = [:]
        for entry in parts.flatMap(\.speakers) {
            let label = entry.label.trimmingCharacters(in: .whitespaces), name = entry.name.trimmingCharacters(in: .whitespaces)
            guard label.range(of: #"^Speaker \d+$"#, options: .regularExpression) != nil,
                  !name.isEmpty, name.range(of: #"^Speaker \d+$"#, options: .regularExpression) == nil else { continue }
            votes[label, default: [:]][name, default: 0] += 1
        }
        var names: [String: String] = [:]
        for (label, counts) in votes {
            let ranked = counts.sorted { $0.value > $1.value }
            if ranked.count == 1 || ranked[0].value > ranked[1].value { names[label] = ranked[0].key }
        }
        // Two labels resolved to the same name: trust neither.
        let clashes = Dictionary(grouping: names, by: \.value).filter { $0.value.count > 1 }.keys
        return names.filter { !clashes.contains($0.value) }
    }

    /// Owners given as a numbered label take the name the transcript revealed for it: `known`
    /// (`SpeakerNameInference`) first, else what the pieces said.
    static func namingOwners(_ parts: [MeetingPartNotes], known: [String: String] = [:]) -> [MeetingPartNotes] {
        let names = known.merging(speakerNames(parts)) { inferred, _ in inferred }
        guard !names.isEmpty else { return parts }
        return parts.map { part in
            var copy = part
            copy.actionItems = naming(part.actionItems, names)
            return copy
        }
    }

    static func naming(_ items: [DigestActionItem], _ names: [String: String]) -> [DigestActionItem] {
        items.map { item in
            var named = item
            if let name = names[item.owner.trimmingCharacters(in: .whitespaces)] { named.owner = name }
            return named
        }
    }

    // MARK: - Fallbacks

    /// When the merge call fails: every candidate item (later versions replacing earlier),
    /// every decision, key points from every part in turn. Free-text changes can't be applied
    /// without the model.
    static func merge(_ parts: [MeetingPartNotes]) -> MeetingDigest {
        MeetingDigest(
            title: "", keyPoints: roundRobin(parts.map(\.keyPoints), limit: maxKeyPoints),
            decisions: unique(parts.flatMap(\.decisions)), actionItems: candidates(parts).map(\.item))
    }

    /// Notes for a piece whose model calls failed: its extractive summary and commitment-like
    /// sentences (no owners).
    static func extractiveNotes(_ piece: String) -> MeetingPartNotes {
        let summary = ExtractiveSummarizer.summarize(piece, fallbackTitle: "")
        let points = summary.summary.split(separator: "\n").map { String($0.dropFirst(2)) }
        let items = summary.actionItems.prefix(4).map { DigestActionItem(owner: "", task: $0, due: "") }
        return MeetingPartNotes(decisions: [], actionItems: Array(items), changes: [], keyPoints: Array(points.prefix(3)))
    }

    /// Takes one from each list in turn, so a long meeting's later parts get key points too.
    static func roundRobin(_ lists: [[String]], limit: Int) -> [String] {
        var result: [String] = []
        var round = 0
        while result.count < limit, lists.contains(where: { $0.count > round }) {
            for list in lists where list.count > round && result.count < limit { result.append(list[round]) }
            round += 1
        }
        return unique(result)
    }

    // MARK: - Similarity

    static func sameItem(_ a: DigestActionItem, _ b: DigestActionItem) -> Bool {
        (namedOwner(a.owner) ?? "").lowercased() == (namedOwner(b.owner) ?? "").lowercased() && similar(a.task, b.task)
    }

    /// Word-set overlap (Jaccard) of at least `threshold` on content words, unless the lines differ in
    /// a name, a number, a date or a time, or in what they end on (`DigestDistinctions`): then they
    /// are different items however many words they share.
    static func similar(_ a: String, _ b: String, threshold: Double = 0.6) -> Bool {
        guard !DigestDistinctions.conflict(a, b) else { return false }
        let left = contentWords(a), right = contentWords(b)
        guard !left.isEmpty, !right.isEmpty else { return a.lowercased() == b.lowercased() }
        return Double(left.intersection(right).count) / Double(left.union(right).count) >= threshold
    }

    /// Whether `text` names `task`: at least two of the task's content words (one for a one-word
    /// task), by a crude stem (no plural "s", first five letters), so "log pull" matches "pull
    /// the error logs".
    static func mentions(_ text: String, _ task: String) -> Bool {
        let stems = { (words: Set<String>) in
            Set(words.filter { $0.count > 2 }.map { String(($0.hasSuffix("s") ? String($0.dropLast()) : $0).prefix(5)) })
        }
        let taskStems = stems(contentWords(task)), textStems = stems(contentWords(text))
        return taskStems.intersection(textStems).count >= min(2, taskStems.count) && !taskStems.isEmpty
    }

    private static func contentWords(_ text: String) -> Set<String> { Set(orderedContentWords(text)) }

    /// The content words in the order they are said.
    static func orderedContentWords(_ text: String) -> [String] {
        let stop: Set<String> = ["the", "a", "an", "to", "for", "of", "and", "on", "in", "by", "with", "it", "that", "this"]
        return text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stop.contains($0) }
    }

    static func unique(_ texts: [String]) -> [String] {
        var kept: [String] = []
        for text in texts.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !text.isEmpty {
            if !kept.contains(where: { similar($0, text, threshold: 0.8) }) { kept.append(text) }
        }
        return kept
    }

    static func uniqueItems(_ items: [DigestActionItem]) -> [DigestActionItem] {
        var kept: [DigestActionItem] = []
        for item in items where !item.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !kept.contains(where: { sameItem($0, item) }) { kept.append(item) }
        }
        return kept
    }
}
