import Foundation

/// Which sentence groups of a dictation may be cleaned while the person is still speaking.
///
/// It is fed the transcript of everything heard so far, each time the recogniser has a newer one, and hands out the
/// groups worth cleaning now. The rules:
/// - Only a closed group is handed out: a group of `TextSegmentation.groups` other than the last. The last group is
///   still being spoken, and a "no, I mean…" may yet reach back into it.
/// - A group is handed out once. Its text is the key the cleaner matches at the key release (`SmartCleaner.cleanEarly`),
///   so a group whose text later changes is simply never matched; nothing here has to undo it.
/// - A group still waiting when a newer transcript no longer has it is withdrawn: cleaning it would be wasted work.
/// - After `close()` (the key release) nothing more is handed out.
///
/// It decides what to clean, never what is delivered: the delivered text is always the cleaning of the final transcript's
/// own groups, and an early result is used only where it is the same call (see `SmartCleaner.cleanEarly`).
public struct EarlyCleanupQueue: Sendable, Equatable {
    /// How many transcripts in a row must show a group, closed and unchanged, before it is handed out.
    public let sightings: Int
    public private(set) var isClosed = false
    /// Groups handed out so far, in order.
    public private(set) var started: [String] = []
    /// Transcripts taken in before the release.
    public private(set) var transcripts = 0
    /// Groups that were waiting when a newer transcript dropped them.
    public private(set) var withdrawn = 0
    private var seen: [String: Int] = [:]
    private var waiting: [String] = []

    public init(sightings: Int = 1) {
        self.sightings = max(1, sightings)
    }

    /// Takes the transcript of everything heard so far.
    public mutating func heard(_ transcript: String) {
        guard !isClosed else { return }
        transcripts += 1
        let groups = TextSegmentation.groups(transcript)
        let closed = groups.count > 1 ? groups.filter { !$0.isTail }.map(\.text) : []
        var counts: [String: Int] = [:]
        for text in closed where counts[text] == nil { counts[text] = (seen[text] ?? 0) + 1 }
        seen = counts
        let kept = waiting.filter { counts[$0] != nil }
        withdrawn += waiting.count - kept.count
        waiting = kept
        for text in closed where (counts[text] ?? 0) >= sightings && !started.contains(text) && !waiting.contains(text) {
            waiting.append(text)
        }
    }

    /// The next group to clean, oldest first, or nil when none is waiting.
    public mutating func next() -> String? {
        guard !isClosed, !waiting.isEmpty else { return nil }
        let text = waiting.removeFirst()
        started.append(text)
        return text
    }

    /// The key was released: nothing more is handed out.
    public mutating func close() {
        isClosed = true
        waiting.removeAll()
    }
}
