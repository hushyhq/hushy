import MurmurCore

extension CopyLast {
    /// The most recent dictation that has text (cancelled ones are skipped by the store).
    static func resolve(from store: Store) throws -> Outcome {
        resolve(lastText: try store.lastDictation()?.text)
    }
}
