import CryptoKit
import Foundation
import MurmurCore
import Observation
import os

/// Owns the "Encrypt data on this Mac" feature end to end: the DEK, the toggle's persisted
/// state, and running the migration that encrypts (or decrypts) every audio file when the
/// setting changes. `DictationController`/`NoteRecorder` read `currentKey` to decide whether to
/// write new audio encrypted; `AudioPlayer` and retry paths read it to decrypt for playback.
///
/// This intentionally does *not* encrypt the SQLite database file itself (see
/// `.claude/DECISIONS.md` / the security review notes for why: SQLCipher's SPM story is too
/// new and its OpenSSL build dependency too heavy to hang a shipping app on as of this build).
/// It does turn on `PRAGMA secure_delete` (in `Store.init`) so deleted rows are overwritten
/// rather than merely unlinked, and it encrypts every audio file, which is where the literal
/// recorded speech actually lives on disk.
@MainActor
@Observable
final class EncryptionController {
    enum MigrationState: Equatable {
        case idle
        case running(AudioEncryptionMigrator.Progress)
        case failed(String)
    }

    private(set) var migrationState: MigrationState = .idle
    /// Mirrors `AppSettings.encryptDataAtRest`; the source of truth for persistence is still
    /// `AppSettings` (UserDefaults), this just avoids every call site needing to reach through.
    private(set) var isEnabled: Bool

    @ObservationIgnored private let keyManager: EncryptionKeyManager
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let log = Logger(subsystem: "app.hushy", category: "encryption")

    init(settings: AppSettings, keyManager: EncryptionKeyManager = EncryptionKeyManager(keyStore: KeychainKeyStore())) {
        self.settings = settings
        self.keyManager = keyManager
        self.isEnabled = settings.encryptDataAtRest
    }

    /// The key to encrypt/decrypt *new or existing* audio with, or nil when encryption is off.
    /// `DictationController`/`NoteRecorder` pass this straight to `WAVWriter`. This intentionally
    /// does NOT check `FeatureFlags.recordingEncryption` — `isEnabled` (mirroring
    /// `AppSettings.encryptDataAtRest`) is the only gate. That way, a machine that had encryption
    /// turned on before the feature was flag-gated (or by a developer with the flag on) keeps
    /// decrypting its files even if the flag is later off; the flag only gates *offering* the
    /// toggle and starting a new `enable()` migration, never reading what's already encrypted.
    var currentKey: SymmetricKey? {
        guard isEnabled else { return nil }
        return try? keyManager.loadOrCreateKey()
    }

    /// Exposes the DEK manager itself (not gated by `isEnabled`) for callers that need the app's
    /// encryption key for something other than audio files — currently `VoiceSignatureStore`
    /// (voice-signature embeddings, see that type's doc comment for why it reuses this key
    /// unconditionally rather than the recording-encryption toggle).
    var voiceSignatureStore: VoiceSignatureStore { VoiceSignatureStore(keyManager: keyManager) }

    /// A one-time recovery key string for display in Settings ("Save to iCloud Keychain" /
    /// "Copy"), or nil if no key has been generated yet (encryption never turned on).
    func recoveryKeyForDisplay() -> String? {
        try? keyManager.recoveryKeyString()
    }

    /// Turns encryption on: generates the key if needed, then encrypts every existing audio
    /// file under Audio/ and Notes/. Safe to call again if a previous run was interrupted.
    /// Gated on `FeatureFlags.recordingEncryption` — the Settings UI only calls this from the
    /// DEBUG Developer pane, but this guard makes the controller itself inert too, in case some
    /// other call site is ever added.
    func enable() async {
        guard FeatureFlags.recordingEncryption else { return }
        guard !isEnabled || migrationState != .idle else { return }
        do {
            let key = try keyManager.loadOrCreateKey()
            let directories = [AppPaths.audioDirectory, AppPaths.notesAudioDirectory]
            await runMigration(direction: .encrypt, directories: directories, key: key)
            if case .failed = migrationState { return }
            isEnabled = true
            settings.encryptDataAtRest = true
        } catch {
            migrationState = .failed(error.localizedDescription)
            log.error("enabling encryption failed: \(error.localizedDescription)")
        }
    }

    /// Turns encryption off: decrypts every audio file back to plaintext, then removes the DEK
    /// from the Keychain. The recovery key the user saved becomes useless at that point — this
    /// is surfaced in the confirmation copy shown before calling this.
    func disable() async {
        guard isEnabled, migrationState == .idle, let key = try? keyManager.loadOrCreateKey() else { return }
        let directories = [AppPaths.audioDirectory, AppPaths.notesAudioDirectory]
        await runMigration(direction: .decrypt, directories: directories, key: key)
        if case .failed = migrationState { return }
        isEnabled = false
        settings.encryptDataAtRest = false
        try? keyManager.deleteKey()
    }

    private enum MigrationDirection: Sendable { case encrypt, decrypt }

    private func runMigration(direction: MigrationDirection, directories: [URL], key: SymmetricKey) async {
        migrationState = .running(AudioEncryptionMigrator.Progress(filesTotal: 0, filesDone: 0, lastError: nil))
        let progressBox = ProgressReporter { [weak self] progress in
            Task { @MainActor in self?.migrationState = .running(progress) }
        }
        do {
            let final = try await Task.detached(priority: .utility) { () -> AudioEncryptionMigrator.Progress in
                let onProgress: @Sendable (AudioEncryptionMigrator.Progress) -> Void = { progress in
                    progressBox.report(progress)
                }
                switch direction {
                case .encrypt:
                    return try AudioEncryptionMigrator.encryptAll(under: directories, key: key, onProgress: onProgress)
                case .decrypt:
                    return try AudioEncryptionMigrator.decryptAll(under: directories, key: key, onProgress: onProgress)
                }
            }.value
            if let error = final.lastError {
                migrationState = .failed(error)
            } else {
                migrationState = .idle
            }
        } catch {
            migrationState = .failed(error.localizedDescription)
        }
    }
}

/// Forwards progress callbacks from a detached background task to a `@MainActor` handler,
/// without requiring the background closure to capture any main-actor-isolated state directly
/// (which Swift 6 strict concurrency rejects for a `@Sendable` closure).
private final class ProgressReporter: @unchecked Sendable {
    private let handler: @Sendable (AudioEncryptionMigrator.Progress) -> Void

    init(handler: @escaping @Sendable (AudioEncryptionMigrator.Progress) -> Void) {
        self.handler = handler
    }

    func report(_ progress: AudioEncryptionMigrator.Progress) {
        handler(progress)
    }
}
