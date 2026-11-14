import AppKit
import MurmurCore

/// What is going on in the app that an uninstall would cut short, for the review to say so
/// before the person confirms.
enum UninstallActivity: Equatable {
    case recording
    case savingNote
    case importing

    /// One sentence for the review, saying what will happen to it.
    var sentence: String {
        switch self {
        case .recording: "A recording is in progress. It will be stopped and discarded, not saved."
        case .savingNote: "A note is being saved. Uninstalling waits for it to finish, then removes it with the rest."
        case .importing: "A file is being imported. The import will be stopped, and the unfinished part is discarded."
        }
    }
}

/// The app's side of "Uninstall Hushy…": stopping everything that writes to disk before the
/// first removal, and going back to work if something would not stop.
extension AppModel {
    var uninstallActivity: [UninstallActivity] {
        var activity: [UninstallActivity] = []
        if recorder.isRecording { activity.append(.recording) }
        if recorder.isFinishing || recorder.retryingNoteID != nil || recorder.isFinalizing { activity.append(.savingNote) }
        if importQueue.isBusy { activity.append(.importing) }
        return activity
    }

    /// Closes every way in, then stops what is running one named step at a time, each with a
    /// time limit. Returns only when nothing is left that could write into the folders about to
    /// be removed. Throws `UninstallStopFailure`, with nothing removed, when a step does not
    /// finish in time; the executor then calls `resumeAfterAbandonedUninstall`.
    func prepareForUninstall(limit: Duration = UninstallStopper.stepLimit) async throws {
        beginUninstall()
        try await UninstallStopper.stop(uninstallStopSteps, limit: limit)
        NSApp.windows.first { $0.identifier?.rawValue == "main" }?.close()
    }

    /// Something would not stop, so nothing was removed: the hotkeys, call detection, the pill
    /// and the downloads come back, and quitting is an ordinary quit again. What the steps
    /// before it did (a recording discarded, imports dropped, the assistant shut down) is not
    /// undone, which is why the sheet asks the person to quit and reopen.
    func resumeAfterAbandonedUninstall() {
        endAbandonedUninstall()
        downloads.start()
    }

    /// A test run has removed its own files and the app stays open: the ways in open again and
    /// quitting is an ordinary quit. The downloads stay stopped, so nothing is fetched back into
    /// the folder that was just emptied.
    func resumeAfterTestRunUninstall() {
        endAbandonedUninstall()
    }

    /// In the order they are run. The recording goes before usage numbers, which still record
    /// that it was discarded; usage numbers go last, because their queue does not reopen.
    private var uninstallStopSteps: [UninstallStopStep] {
        [
            UninstallStopStep("the dictation in progress") { [weak self] in await self?.waitForDictationToEnd() },
            UninstallStopStep("the recording in progress", checking: { [weak self] isStillWanted in
                await self?.discardRecordingForUninstall(isStillWanted: isStillWanted)
            }),
            UninstallStopStep("the file import", checking: { [weak self] isStillWanted in
                await self?.stopImportsForUninstall(isStillWanted: isStillWanted)
            }),
            UninstallStopStep("the assistant", checking: { [weak self] isStillWanted in
                await self?.shutAssistantForUninstall(isStillWanted: isStillWanted)
            }),
            UninstallStopStep("the model downloads") { [weak self] in await self?.stopDownloadsForUninstall() },
            UninstallStopStep("the writing model") { [weak self] in await self?.cleanupModel.memoryPressure(.critical) },
            UninstallStopStep("the usage numbers", checking: { [weak self] isStillWanted in
                await self?.stopUsageNumbersForUninstall(isStillWanted: isStillWanted)
            }),
        ]
    }

    /// `beginUninstall` cancelled the dictation; one that was already being written to history
    /// is given the time to finish.
    private func waitForDictationToEnd() async {
        while dictation.isBusy {
            try? await Task.sleep(for: Self.uninstallPoll)
        }
    }

    /// The recording is discarded, as the review said: its audio and its row are removed here
    /// rather than left half-written for the removal that follows. Both acts come after a wait
    /// and are asked for again each time: if the step ran out of time and the uninstall was
    /// abandoned, the recording goes on, or its row and audio stay for Notes to pick up.
    private func discardRecordingForUninstall(isStillWanted: @escaping UninstallStopStep.StillWanted) async {
        let isWanted = { isStillWanted() && self.isUninstalling }
        guard let note = await recorder.discardForUninstall(isStillWanted: isWanted), isWanted() else { return }
        library.deleteNote(note)
        if selectedNoteID == note.id { selectedNoteID = nil }
    }

    /// A step that ran past its time limit is left to finish by itself. If this one finishes
    /// after the uninstall was abandoned, it must not close the queue of an app that is back at work.
    private func stopUsageNumbersForUninstall(isStillWanted: @escaping UninstallStopStep.StillWanted) async {
        await usageMetrics.stopForUninstall { isStillWanted() && self.isUninstalling }
    }

    /// These two act at once and cannot take it back (queued imports dropped, an unsaved chat's
    /// scratch folder removed). A step that only gets its turn after it has run out of time
    /// does nothing.
    private func stopImportsForUninstall(isStillWanted: @escaping UninstallStopStep.StillWanted) async {
        guard isStillWanted(), isUninstalling else { return }
        await importQueue.stopAll()
    }

    private func shutAssistantForUninstall(isStillWanted: @escaping UninstallStopStep.StillWanted) async {
        guard isStillWanted(), isUninstalling else { return }
        assistant.shutdown()
    }

    private func stopDownloadsForUninstall() async {
        downloads.stopAll()
        await speech.pauseDownload()
    }

    private static let uninstallPoll: Duration = .milliseconds(100)
}
