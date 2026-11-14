import Foundation

/// How a `shortcuts run` process ending maps to an outcome. Pure, so the rule is tested without
/// running anything.
///
/// A Shortcut is the person's own automation. Once it has started, Hushy cannot tell what it did:
/// a run that timed out or exited with an error may have sent a message or changed a file before
/// it stopped. So those are `.mayHaveRun`, which is never retried and never reported as plainly
/// failed. Only a process that never started is a plain failure, because nothing ran.
public enum ShortcutRunOutcome {
    /// The error for how the process ended, or nil when it finished cleanly (exit status 0).
    public static func error(started: Bool, timedOut: Bool, exitStatus: Int32) -> ActionExecutionError? {
        guard started else { return .backendFailed("Couldn't start Shortcuts") }
        if timedOut { return .mayHaveRun(.timedOut) }
        return exitStatus == 0 ? nil : .mayHaveRun(.didNotFinish)
    }
}
