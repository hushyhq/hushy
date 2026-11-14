import MurmurCore
import os

/// What the dictation path tells the pill's motion work, and logs for it. Nothing here changes
/// when anything happens: the microphone starts where it always did, cleanup runs as it always
/// did, and the pill is only told afterwards.
extension DictationController {
    private static let startLog = Logger(subsystem: "app.hushy", category: "dictation")

    /// An audio level arrived for the current recording: the first one logs the start line.
    func noteFirstAudio() {
        guard let line = startTiming?.audioArrived() else { return }
        Self.startLog.notice("\(line, privacy: .public)")
    }

    /// The recording stopped. A start line that was never logged (no audio ever arrived) is logged
    /// now, with a dash for the audio.
    func noteRecordingEnded() {
        guard let line = startTiming?.ended() else { return }
        Self.startLog.notice("\(line, privacy: .public)")
    }

    /// The listener handed to cleanup for one wait: it tells the pill how far cleanup has got.
    ///
    /// The cleaner calls it and carries on. It only schedules the pill's update on the main actor
    /// and returns, so cleanup never waits on the pill, and it reads nothing back. The wait is
    /// named by the pill's state revision at this moment: a report that arrives after the pill
    /// has moved on (pasted, cancelled, failed) is dropped.
    static func progressObserver(for pill: PillModel) -> CleanupProgressObserver {
        let revision = pill.stateRevision
        return { [weak pill] report in
            Task { @MainActor in pill?.noteCleanupProgress(report, revision: revision) }
        }
    }
}
