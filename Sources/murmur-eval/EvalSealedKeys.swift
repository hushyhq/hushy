import Foundation
import MurmurCore

/// Measurement tools open a sealed model with a key from a file, never from the Keychain or the network:
/// `HUSHY_SEALED_KEY_FILE` names a file holding the base64 key `hushy-model-seal` wrote.
struct EvalSealedKeys: SealedKeySource {
    let key: Data

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> EvalSealedKeys? {
        guard let path = environment["HUSHY_SEALED_KEY_FILE"], !path.isEmpty,
              let text = try? String(contentsOfFile: path, encoding: .utf8),
              let key = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              key.count == SealedFormat.keySize else { return nil }
        return EvalSealedKeys(key: key)
    }

    func key(modelID: String, refetch: Bool) async throws -> Data { key }
    func report(modelID: String, issue: ModelKeyIssue?) {}
}
