import Foundation
import MurmurCore

/// Saving a finished dictation: its History row, and its audio when audio retention is on.
/// Always off the hot path, after the pill has shown the outcome.
extension DictationController {
    @discardableResult
    func persist(_ dictation: Dictation, samples: [Float], settings: SessionSettings) async -> Int64? {
        await save(dictation, samples: samples, settings: settings)?.id
    }

    /// Saves the row and, when audio retention is on, its audio.
    ///
    /// A Try again run (`SessionSettings.retryOf`) is the same dictation as its failed first
    /// attempt, so it fills in the row that attempt saved, keeping its place in History and the
    /// audio file it already has, and writes nothing new. However a retry ends (text, another
    /// failure, Esc), there is one row and at most one audio file for that recording.
    ///
    /// That row may have changed while the retry ran: deleted in History or by retention, or
    /// filled in by History's own Retry. Then it is left as it is (`Store.fillFailedDictation`),
    /// and the retry's result is saved as a fresh row with no audio: never under the old id, and
    /// never with a second audio file or a path to one that is gone.
    func save(_ dictation: Dictation, samples: [Float], settings: SessionSettings) async -> Dictation? {
        let keepAudio = settings.retainAudio && self.settings.audioRetentionDays != 0
        let store = self.store
        let key = encryption.currentKey
        let firstAttempt = await settings.retryOf?.value
        let saved = await Task.detached(priority: .utility) { () -> Dictation? in
            var record = dictation
            if let firstID = firstAttempt?.id {
                do {
                    if let filled = try store.fillFailedDictation(id: firstID, with: record) { return filled }
                } catch {
                    NSLog("Hushy: failed to update a retried dictation: \(error.localizedDescription)")
                }
            } else if keepAudio, firstAttempt == nil {
                let url = AppPaths.audioDirectory.appendingPathComponent("\(UUID().uuidString).wav")
                do {
                    try WAVWriter.write(samples, to: url, key: key)
                    record.audioPath = url.path
                } catch {
                    NSLog("Hushy: failed to preserve dictation audio: \(error.localizedDescription)")
                }
            }
            do {
                let saved = try store.save(record)
                if saved.status == .cancelled { Self.dropCancelledTakesPastTheLimit(store) }
                return saved
            } catch {
                NSLog("Hushy: failed to save dictation: \(error.localizedDescription)")
                return nil
            }
        }.value
        onSaved?()
        return saved
    }

    @discardableResult
    func saveAudioOnly(samples: [Float], target: FocusTarget, duration: TimeInterval,
                       settings: SessionSettings, status: Dictation.Status) async -> Dictation? {
        let dictation = Dictation(rawText: "", text: "", appBundleID: target.bundleID, appName: target.appName,
                                  durationSeconds: duration, status: status, appCategory: target.category.rawValue)
        return await save(dictation, samples: samples, settings: settings)
    }

    func saveCancelled(samples: [Float], target: FocusTarget, duration: TimeInterval,
                               settings: SessionSettings) async {
        let raw = await rereadCancelled(samples)
        let text = raw.isEmpty ? "" : TextCleaner(options: settings.cleanupOptions).clean(raw).text
        let dictation = Dictation(
            rawText: raw, text: text, appBundleID: target.bundleID, appName: target.appName,
            durationSeconds: duration, status: .cancelled, appCategory: target.category.rawValue)
        await persist(dictation, samples: samples, settings: settings)
    }

    /// Cancelled takes are a bounded safety net (`Store.cancelledTakeLimits`): past it the oldest go, with their audio.
    nonisolated private static func dropCancelledTakesPastTheLimit(_ store: Store) {
        do {
            for path in try store.trimCancelledTakes() { try? FileManager.default.removeItem(atPath: path) }
        } catch {
            NSLog("Hushy: failed to trim cancelled takes: \(error.localizedDescription)")
        }
    }
}
