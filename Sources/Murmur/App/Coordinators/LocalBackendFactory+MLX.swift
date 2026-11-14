import Foundation
import HushyModelsMLX
import MurmurCore
import os

extension LocalBackendFactory {
    /// The shipping factory: `LocalCleanupBackend` (MLX, speculation on) in front of Apple FM.
    /// The only place in the app that imports HushyModelsMLX.
    static var mlx: LocalBackendFactory {
        LocalBackendFactory(
            isRuntimeAvailable: { LocalCleanupBackend.runtimeAvailable },
            make: { entry, directory, fallback, idleSeconds, callLog, keys in
                let log = Logger(subsystem: "app.hushy", category: "cleanup-model")
                let chain = LocalCleanupBackend.chain(
                    entry: entry, directory: directory, fallback: fallback, idleSeconds: idleSeconds, callLog: callLog, keys: keys,
                    onUnload: { reason in log.notice("cleanup model unloaded why=\(reason.rawValue, privacy: .public)") })
                return Built(model: chain.model, residency: chain.local.residency, memory: chain.mlx)
            })
    }
}
