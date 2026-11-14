import Foundation
import MurmurCore

extension DictationController {
    /// Re-runs transcription and cleanup on a failed dictation's saved audio, using the
    /// current cleanup settings and personalizer, and updates the row in place. Never pastes:
    /// the point is to give the user text they can copy, not a surprise insertion into
    /// whatever app now has focus.
    func retryTranscription(for dictation: Dictation) {
        guard let id = dictation.id, retryingDictationID == nil, !isBusy,
              let audioPath = dictation.audioPath else { return }
        retryingDictationID = id
        onSaved?()
        let store = self.store
        let pipelineSettings = retrySettings(for: dictation)
        Task {
            defer {
                self.retryingDictationID = nil
                self.onSaved?()
            }
            do {
                let samples = try WAVWriter.read(URL(fileURLWithPath: audioPath), key: self.encryption.currentKey)
                let result = try await self.pipeline.run(samples: samples, settings: pipelineSettings)
                guard !result.raw.isEmpty else {
                    try store.updateTranscription(id: id, rawText: "", text: "", status: .failed)
                    self.flashNotice("Still couldn't make out any words in that recording")
                    return
                }
                let status: Dictation.Status = result.text.isEmpty ? .failed : .notInserted
                try store.updateTranscription(
                    id: id, rawText: result.raw, text: result.text, status: status,
                    cleanupOutcome: CleanupOutcomeSummary(groups: result.groups, level: pipelineSettings.cleanupOptions.level)?.code)
            } catch {
                self.log.error("retry transcription failed: \(error.localizedDescription)")
                self.flashError("Couldn't retry — the recording may be missing")
            }
        }
    }
}
