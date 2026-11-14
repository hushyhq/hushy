import Foundation

/// What a person sends colleagues after a meeting: the title, when and how long, who was there,
/// the summary and the action items. The transcript is left out unless the caller asks for it.
///
/// Built from a note as stored, with nothing inferred: the summary and action items are the
/// strings the summarizer wrote, and "who was there" is only the speakers the user confirmed (see
/// `RecapAttendees`). Calendar attendees are never read here, since they are suggestions for the
/// user to pick from, not people known to have spoken. Nothing leaves the Mac from this type: it
/// only produces text, and the caller decides where that text goes.
public struct MeetingRecap: Equatable, Sendable {
    public let title: String
    public let dateText: String
    /// "32 min", or empty for a note with no recorded length.
    public let lengthText: String
    public let attendees: [String]
    /// The summary's lines with their "- " bullet markers removed.
    public let summaryPoints: [String]
    /// One line per item as stored ("Priya: Send the deck — by Friday").
    public let actionItems: [String]
    /// Whether each item (same order as `actionItems`) is checked off.
    public let actionDone: [Bool]
    /// The items as fields, same order, when the note has them; used for the rich-text output.
    public let actionDetails: [ActionItemDetail]?
    /// The full transcript, only when the caller asked for it.
    public let transcript: String?

    static let fallbackTitle = "Meeting recap"

    /// The recap for `note`, or `nil` when there is none: the note is not `.ready` (still
    /// recording, processing, or failed), or there is nothing to share (no summary, no action
    /// items, and no transcript asked for).
    ///
    /// - `speakers` are the note's speakers; `ownerName` is the user's own name from Settings, used
    ///   for the note owner's track (labelled "You"), which is never written as "You" to others.
    /// - `doneItems` are the checked-off action-item indexes (stored apart from the note).
    /// - `turns` is the note's transcript from its turns (`Store.transcript(noteId:)`); without it the
    ///   stored cache of the same turns is used.
    public static func make(
        from note: Note, turns: NoteTranscript? = nil, speakers: [NoteSpeaker] = [], ownerName: String? = nil, doneItems: Set<Int> = [],
        includeTranscript: Bool = false, locale: Locale = .current, timeZone: TimeZone = .current
    ) -> MeetingRecap? {
        guard note.status == .ready else { return nil }
        let points = summaryLines(note.summary)
        // Positions of the items with text, so check-offs and fields stay on the right item.
        let kept = note.actionItems.indices.filter { !trimmed(note.actionItems[$0]).isEmpty }
        let items = kept.map { trimmed(note.actionItems[$0]) }
        let body = trimmed(turns?.rendered ?? note.transcript)
        let transcript = includeTranscript && !body.isEmpty ? body : nil
        guard !points.isEmpty || !items.isEmpty || transcript != nil else { return nil }
        let title = trimmed(note.title)
        return MeetingRecap(
            title: title.isEmpty ? fallbackTitle : title,
            dateText: note.createdAt.formatted(
                Date.FormatStyle(date: .long, time: .shortened, locale: locale, timeZone: timeZone)),
            lengthText: note.durationSeconds >= 1 ? DurationLabelFormatter.label(seconds: note.durationSeconds) : "",
            attendees: RecapAttendees.names(from: speakers, ownerName: ownerName),
            summaryPoints: points, actionItems: items, actionDone: kept.map { doneItems.contains($0) },
            actionDetails: note.actionItemDetails.map { details in kept.map { details[$0] } },
            transcript: transcript)
    }

    /// The distinct speakers in a note's stored segments, in first-appearance order.
    public static func speakers(in segments: [NoteSegmentWithSpeaker]) -> [NoteSpeaker] {
        var seen = Set<Int64>()
        return segments.compactMap(\.speaker).filter { speaker in
            guard let id = speaker.id else { return true }
            return seen.insert(id).inserted
        }
    }

    /// The email subject and the heading of every output.
    public var subject: String { title }

    /// "October 5, 2026 at 9:03 AM · 32 min".
    var metaLine: String { [dateText, lengthText].filter { !$0.isEmpty }.joined(separator: " · ") }

    static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static let bulletMarkers = ["- ", "• ", "* "]

    private static func summaryLines(_ summary: String) -> [String] {
        summary.components(separatedBy: .newlines).map(trimmed).compactMap { line in
            let marker = bulletMarkers.first { line.hasPrefix($0) }
            let text = marker.map { trimmed(String(line.dropFirst($0.count))) } ?? line
            return text.isEmpty ? nil : text
        }
    }
}

/// Who a recap says was there: speakers the user named themselves, plus the note owner. Reuses
/// `NoteSpeaker.hasRealName` and `hasGenericLabel`, the same tests the speaker menu applies.
enum RecapAttendees {
    static func names(from speakers: [NoteSpeaker], ownerName: String?) -> [String] {
        var seen = Set<String>()
        return speakers.compactMap { name(of: $0, ownerName: ownerName) }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    private static func name(of speaker: NoteSpeaker, ownerName: String?) -> String? {
        // A name the user typed. A pending suggestion (`suggestedVoiceId`) is never read here.
        if speaker.hasRealName { return speaker.displayName.map(MeetingRecap.trimmed) }
        // "Speaker N" with no name of its own is somebody the user has not identified.
        guard !speaker.hasGenericLabel else { return nil }
        // The owner's own track: labelled with their name, or "You", which means nothing to a reader.
        let label = MeetingRecap.trimmed(speaker.label)
        guard label.caseInsensitiveCompare("You") == .orderedSame else { return label.isEmpty ? nil : label }
        let owner = MeetingRecap.trimmed(ownerName ?? "")
        return owner.isEmpty ? nil : owner
    }
}
