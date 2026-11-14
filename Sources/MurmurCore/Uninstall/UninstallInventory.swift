import Foundation

/// How much each group of the plan holds on disk, for the list shown before anything is removed.
public struct UninstallInventory: Sendable, Equatable {
    public var bytes: [UninstallStep.Group: Int64]

    public init(bytes: [UninstallStep.Group: Int64] = [:]) {
        self.bytes = bytes
    }

    public func bytes(in groups: UninstallStep.Group...) -> Int64 {
        groups.reduce(0) { $0 + (bytes[$1] ?? 0) }
    }

    /// Adds up the plan's files and folders. When the data folder goes as one folder, the writing
    /// models inside it are counted as models rather than as history.
    public static func measure(_ plan: UninstallPlan, fileSystem: any UninstallFileSystem) -> UninstallInventory {
        var bytes: [UninstallStep.Group: Int64] = [:]
        for step in plan.steps {
            guard let url = step.fileURL else { continue }
            var size = fileSystem.byteSize(of: url)
            if UninstallPathPolicy.isSame(url, plan.roots.supportDirectory) {
                let models = fileSystem.byteSize(of: UninstallPathPolicy.child(of: url, "Models"))
                bytes[.models, default: 0] += models
                size = max(0, size - models)
            }
            bytes[step.group, default: 0] += size
        }
        return UninstallInventory(bytes: bytes)
    }
}
