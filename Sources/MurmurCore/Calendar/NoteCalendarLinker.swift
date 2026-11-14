import Foundation

/// Looks up the meeting a note that is just starting belongs to. Never throws, never prompts for
/// calendar access, and gives up after `lookupTimeout`: a note that cannot be matched is simply
/// named as it is today. Event titles and attendee names pass through here; none are logged.
public enum NoteCalendarLinker {
    public static let lookupTimeout: TimeInterval = 3

    public static func match(
        startedAt: Date, reader: any CalendarReading, timeout: TimeInterval = lookupTimeout
    ) async -> NoteCalendarMatch? {
        await withTimeout(timeout) {
            // Reading is only ever done with a grant that already exists; the prompt belongs to the
            // Settings toggle, never to starting a recording.
            guard await reader.authorization().canRead else { return nil }
            // Everything the matcher could pick overlaps [start, start + tolerance]: in progress
            // at the start, or beginning within the early-start window.
            let upper = startedAt.addingTimeInterval(CalendarEventMatcher.earlyStartTolerance + 1)
            guard let events = try? await reader.events(from: startedAt, to: upper) else { return nil }
            return CalendarEventMatcher.event(overlapping: startedAt, in: events).flatMap { NoteCalendarMatch(event: $0) }
        }
    }

    /// Runs `work` but stops waiting for it after `seconds`. The work is not cancellable when it is
    /// blocked in a synchronous EventKit call, so it is left to finish on its own and its result
    /// dropped; a late answer can never reach the caller.
    private static func withTimeout(
        _ seconds: TimeInterval, _ work: @escaping @Sendable () async -> NoteCalendarMatch?
    ) async -> NoteCalendarMatch? {
        await withCheckedContinuation { (continuation: CheckedContinuation<NoteCalendarMatch?, Never>) in
            let gate = OnceGate(continuation)
            let worker = Task { gate.resume(await work()) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                gate.resume(nil)
                worker.cancel()
            }
        }
    }
}

/// Resumes a continuation exactly once, whichever of the lookup and the timer finishes first.
private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NoteCalendarMatch?, Never>?

    init(_ continuation: CheckedContinuation<NoteCalendarMatch?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: NoteCalendarMatch?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
