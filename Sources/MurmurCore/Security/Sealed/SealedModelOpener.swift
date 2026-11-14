import Foundation

public enum SealedModelError: Error, Equatable, LocalizedError {
    /// The key on this Mac, and a fresh one from the host, both fail to open the downloaded files.
    case keyMismatch

    public var errorDescription: String? {
        "Hushy's model key does not match the downloaded model. Verify or re-download the model in Settings."
    }
}

/// Opens a sealed model folder's plaintext stream with the right key, in memory only.
public enum SealedModelOpener {
    /// Takes the stored key (or fetches it), checks it against the files' first chunk, and on a mismatch asks the
    /// host for a fresh key once. A second mismatch is reported (`ModelKeyIssue.mismatch`) and thrown.
    public static func open(
        directory: URL, modelID: String, keys: any SealedKeySource, parallelism: Int = 4
    ) async throws -> SealedPlainStream {
        let reader = try SealedWeightsReader(directory: directory, modelID: modelID)
        var key = try await keys.key(modelID: modelID, refetch: false)
        do {
            try reader.verifyKey(key)
        } catch let error as SealedWeightsError where error.isKeyMismatchCandidate {
            key = try await keys.key(modelID: modelID, refetch: true)
            do {
                try reader.verifyKey(key)
            } catch let again as SealedWeightsError where again.isKeyMismatchCandidate {
                keys.report(modelID: modelID, issue: .mismatch)
                throw SealedModelError.keyMismatch
            }
        }
        keys.report(modelID: modelID, issue: nil)
        return try reader.plainStream(key: key, parallelism: parallelism)
    }
}
