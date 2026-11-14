import Foundation

/// Which backend dictation cleanup runs on (M5). Hushy picks it for each Mac; there is no Settings
/// control for it. Scoped to dictation cleanup: voice actions and modes keep Apple FM (MLX actions are
/// M8, not measured in the app yet). Note and meeting summaries share the cleanup model when it is the
/// local 4B and keep Apple FM otherwise (`MeetingLanguageModel`).
public enum CleanupBackendChoice: String, CaseIterable, Identifiable, Sendable {
    case apple, local, rules

    public var id: String { rawValue }
}

/// Where the chosen local model is.
public enum LocalModelInstall: Equatable, Sendable {
    case notInstalled
    /// Bytes on disk of `total`; `secondsRemaining` once there is a measured rate.
    case downloading(received: Int64, total: Int64, secondsRemaining: TimeInterval?)
    case paused(received: Int64, total: Int64, reason: PauseReason)
    case failed(String)
    case ready

    public enum PauseReason: String, Equatable, Sendable {
        case user, meteredNetwork = "metered", offline
        /// Hushy's model host serves only a signed-in account; the download continues after sign-in.
        case signedOut = "signed-out"
        /// The host's download limit for now (a daily limit); the download continues by itself later.
        case downloadLimit = "limit"
    }

    public var isReady: Bool { self == .ready }
}

/// The backend dictation cleanup actually runs on right now.
public enum EffectiveCleanupBackend: Equatable, Sendable {
    case apple
    /// The local model (by registry id) → Apple FM → rules.
    case local(String)
    case rules

    public var logLabel: String {
        switch self {
        case .apple: "apple"
        case .local(let id): "local:\(id)"
        case .rules: "rules"
        }
    }

    /// Choice + install state → backend. Choosing the local model before any local model is ready
    /// runs the simple rule-based fixes, never Apple Intelligence (TRY-88): a person who asked for
    /// Hushy's model gets Hushy's model or the plain fixes, and the switch happens the moment the
    /// files are ready — no restart. (The controller passes `.ready` with a stand-in's entry while
    /// an installed model can cover the wait.) `localAvailable` is false when the runtime can't run
    /// it (no `mlx.metallib`); that Mac keeps Apple Intelligence.
    public static func resolve(
        choice: CleanupBackendChoice, install: LocalModelInstall, entryID: String, localAvailable: Bool = true
    ) -> EffectiveCleanupBackend {
        switch choice {
        case .apple: .apple
        case .rules: .rules
        case .local:
            if !localAvailable { .apple } else if install.isReady { .local(entryID) } else { .rules }
        }
    }
}
