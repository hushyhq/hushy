import Foundation
import OSLog

/// Reads Hushy's own unified-log lines (`subsystem == "app.hushy"`, the lines `Logger` already
/// writes) for the feedback diagnostics file. The system-wide store reaches back three days;
/// when macOS will not open it, the lines since this launch are read instead, and the file says
/// so. Slow (seconds), so it runs off the main thread. Lines go through `FeedbackLogFilter`
/// before anything is written.
enum FeedbackLogReader {
    static func read(now: Date = Date()) -> (lines: [FeedbackLogLine], reach: FeedbackLogReach) {
        let since = now.addingTimeInterval(-FeedbackDiagnostics.window)
        if let store = try? OSLogStore(scope: .system), let lines = entries(in: store, since: since) {
            return (lines, .lastThreeDays)
        }
        if let store = try? OSLogStore(scope: .currentProcessIdentifier), let lines = entries(in: store, since: since) {
            return (lines, .thisSession)
        }
        return ([], .unavailable)
    }

    private static func entries(in store: OSLogStore, since: Date) -> [FeedbackLogLine]? {
        let predicate = NSPredicate(format: "subsystem == %@", FeedbackDiagnostics.subsystem)
        guard let entries = try? store.getEntries(at: store.position(date: since), matching: predicate) else { return nil }
        return entries.compactMap { entry in
            guard let log = entry as? OSLogEntryLog else { return nil }
            return FeedbackLogLine(date: log.date, subsystem: log.subsystem, message: log.composedMessage)
        }
    }
}
