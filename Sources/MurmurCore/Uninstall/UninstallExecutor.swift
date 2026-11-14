import Foundation

/// Everything an uninstall does that is not a file removal, injected so tests never touch the
/// real Keychain, preferences, login items or Trash.
public struct UninstallOperations: Sendable {
    /// Stops recording, imports, downloads and the models, and returns only when they have
    /// stopped. Throws (see `UninstallStopFailure`) when something would not stop in time.
    public var stopActivity: @Sendable () async throws -> Void
    /// Puts the app back to work after `stopActivity` failed: nothing was removed.
    public var resumeActivity: @Sendable () async -> Void
    /// Forgets the account on this Mac and ends its session on the server. Throws
    /// `UninstallSignOutNotConfirmed` when this Mac forgot the account but the server was not told.
    public var signOut: @Sendable () async throws -> Void
    public var unregisterLoginItem: @Sendable () async throws -> Void
    public var clearNotifications: @Sendable () async throws -> Void
    public var deleteKeychainItems: @Sendable (_ service: String) async throws -> Void
    public var clearDefaults: @Sendable (_ domain: String) async throws -> Void
    /// The bundle identifier written in the app at `url`, or nil when it is not an app.
    public var bundleIdentifier: @Sendable (_ url: URL) -> String?
    public var moveToTrash: @Sendable (_ url: URL) async throws -> Void
    /// Resets every permission macOS holds for the app with this identifier. Throws when macOS
    /// refuses or the command fails. The executor only ever passes
    /// `UninstallPlan.permissionsBundleIdentifier`.
    public var resetPermissions: @Sendable (_ bundleIdentifier: String) async throws -> Void

    public init(
        stopActivity: @escaping @Sendable () async throws -> Void,
        resumeActivity: @escaping @Sendable () async -> Void,
        signOut: @escaping @Sendable () async throws -> Void,
        unregisterLoginItem: @escaping @Sendable () async throws -> Void,
        clearNotifications: @escaping @Sendable () async throws -> Void,
        deleteKeychainItems: @escaping @Sendable (_ service: String) async throws -> Void,
        clearDefaults: @escaping @Sendable (_ domain: String) async throws -> Void,
        bundleIdentifier: @escaping @Sendable (_ url: URL) -> String?,
        moveToTrash: @escaping @Sendable (_ url: URL) async throws -> Void,
        resetPermissions: @escaping @Sendable (_ bundleIdentifier: String) async throws -> Void
    ) {
        self.stopActivity = stopActivity
        self.resumeActivity = resumeActivity
        self.signOut = signOut
        self.unregisterLoginItem = unregisterLoginItem
        self.clearNotifications = clearNotifications
        self.deleteKeychainItems = deleteKeychainItems
        self.clearDefaults = clearDefaults
        self.bundleIdentifier = bundleIdentifier
        self.moveToTrash = moveToTrash
        self.resetPermissions = resetPermissions
    }
}

/// This Mac forgot the account, but the server could not be told to end the session. The
/// uninstall goes on: being offline never stops it.
public struct UninstallSignOutNotConfirmed: Error, Equatable, Sendable {
    public init() {}
}

/// What happened, step by step.
public struct UninstallReport: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case done
        /// The account is forgotten on this Mac, but the server did not hear of it.
        case signedOutOnThisMacOnly
        /// There was nothing at the location to remove.
        case nothingThere
        case failed(String)
        case refused(UninstallRefusal)
        /// The recording-encryption key, kept on purpose because recordings could not be removed.
        case keptWithRecordings

        /// One sentence for the person; nil when there is nothing to say.
        public var explanation: String? {
            switch self {
            case .done, .nothingThere: nil
            case .signedOutOnThisMacOnly:
                "Hushy's server could not be reached, so you were signed out on this Mac only."
            case .failed(let message): message
            case .refused(let refusal): refusal.explanation
            case .keptWithRecordings:
                "Kept on purpose: the recordings that were left behind are encrypted, and are still readable with this key."
            }
        }
    }

    public struct Entry: Sendable, Equatable, Identifiable {
        public let step: UninstallStep
        public let outcome: Outcome
        public var id: String { step.id }

        public init(step: UninstallStep, outcome: Outcome) {
            self.step = step
            self.outcome = outcome
        }

        public var isLeftover: Bool {
            switch outcome {
            // Signed out on this Mac only is said in the report, but leaves nothing on this Mac.
            case .done, .nothingThere, .signedOutOnThisMacOnly: false
            case .failed, .refused, .keptWithRecordings: true
            }
        }
    }

    /// Set when the whole uninstall was refused and no step ran.
    public let refusal: UninstallRefusal?
    /// Set when the app could not be stopped: why, in a sentence. Nothing was removed.
    public let abandoned: String?
    public let entries: [Entry]

    public init(refusal: UninstallRefusal?, abandoned: String? = nil, entries: [Entry]) {
        self.refusal = refusal
        self.abandoned = abandoned
        self.entries = entries
    }

    /// What could not be removed, each with where it is.
    public var leftovers: [Entry] { entries.filter(\.isLeftover) }
    /// True when the sign-out did not reach the server.
    public var signedOutOnThisMacOnly: Bool { entries.contains { $0.outcome == .signedOutOnThisMacOnly } }
    public var removedEverything: Bool { refusal == nil && abandoned == nil && leftovers.isEmpty }
    /// True when no removal was attempted: the plan was refused, or the app would not stop.
    public var removedNothing: Bool { refusal != nil || abandoned != nil }
}

/// Runs a plan: every step, in order, and nothing that is not in it. A step that fails or is
/// refused is recorded and the rest still run.
public struct UninstallExecutor: Sendable {
    public let fileSystem: any UninstallFileSystem
    public let operations: UninstallOperations

    public init(fileSystem: any UninstallFileSystem, operations: UninstallOperations) {
        self.fileSystem = fileSystem
        self.operations = operations
    }

    /// The reason nothing may run, or nil. A data folder chosen by `HUSHY_HOME` / `MURMUR_HOME`
    /// must be a real folder holding Hushy's database; a missing folder has nothing to lose.
    public func preflight(_ plan: UninstallPlan) -> UninstallRefusal? {
        guard let marker = plan.requiredDataMarker else { return nil }
        let folder = UninstallPathPolicy.child(of: marker, "..")
        switch fileSystem.kind(of: folder) {
        case .missing: return nil
        case .folder: return fileSystem.kind(of: marker) == .file ? nil : .notAHushyDataFolder(folder.path)
        case .file, .link: return .notAHushyDataFolder(folder.path)
        }
    }

    public func run(_ plan: UninstallPlan) async -> UninstallReport {
        if let refusal = preflight(plan) { return UninstallReport(refusal: refusal, entries: []) }
        return await run(plan.steps, of: plan)
    }

    /// Repeats the removals and the settings just before the app quits, in case the app wrote
    /// something back while it was still open. Does nothing unless `report` is what `run` gave
    /// for a plan it accepted.
    public func settle(_ plan: UninstallPlan, after report: UninstallReport) async -> UninstallReport {
        guard !report.removedNothing, report.entries.map(\.step) == plan.steps else {
            return UninstallReport(refusal: report.refusal ?? .notPartOfThePlan("settle"), entries: [])
        }
        return await run(plan.stepsRepeatedAtQuit, of: plan)
    }

    private func run(_ steps: [UninstallStep], of plan: UninstallPlan) async -> UninstallReport {
        var entries: [UninstallReport.Entry] = []
        for step in steps {
            let outcome = await outcome(of: step, in: plan, after: entries)
            entries.append(UninstallReport.Entry(step: step, outcome: outcome))
            // The app would not stop: give up before anything is removed, and put it back to work.
            if step.mustSucceedFirst, outcome != .done {
                await operations.resumeActivity()
                let reason = outcome.explanation ?? "Hushy could not be stopped."
                return UninstallReport(refusal: nil, abandoned: reason, entries: entries)
            }
        }
        return UninstallReport(refusal: nil, entries: entries)
    }

    /// The checks that depend on the plan as a whole, then the step itself.
    private func outcome(
        of step: UninstallStep, in plan: UninstallPlan, after entries: [UninstallReport.Entry]
    ) async -> UninstallReport.Outcome {
        if plan.isTestRun {
            switch step.action {
            case .stopActivity, .removeItem, .removeFolderIfEmpty: break
            default: return .refused(.notPartOfThePlan(step.location))
            }
        }
        // Recordings that could not be removed stay readable: their key is not deleted.
        if step.onlyAfterDataRemoved, entries.contains(where: { $0.step.removesData && $0.isLeftover }) {
            return .keptWithRecordings
        }
        return await perform(step, in: plan)
    }

    private func perform(_ step: UninstallStep, in plan: UninstallPlan) async -> UninstallReport.Outcome {
        switch step.action {
        case .stopActivity: return await attempt(operations.stopActivity)
        case .signOut: return await signOut()
        case .unregisterLoginItem: return await attempt(operations.unregisterLoginItem)
        case .clearNotifications: return await attempt(operations.clearNotifications)
        case .deleteKeychainItems(let service):
            guard UninstallPlan.keychainServices.contains(service) else { return .refused(.notPartOfThePlan(service)) }
            return await attempt { try await operations.deleteKeychainItems(service) }
        case .clearDefaults(let domain):
            guard domain == plan.roots.bundleIdentifier else { return .refused(.notPartOfThePlan(domain)) }
            return await attempt { try await operations.clearDefaults(domain) }
        case .removeItem(let url): return removeItem(url, in: plan)
        case .removeFolderIfEmpty(let url): return removeFolderIfEmpty(url, in: plan)
        case .moveAppToTrash(let url): return await moveAppToTrash(url, in: plan)
        case .resetPermissions(let id): return await resetPermissions(id, in: plan)
        }
    }

    private func removeItem(_ url: URL, in plan: UninstallPlan) -> UninstallReport.Outcome {
        if let refusal = UninstallPathPolicy.refusal(for: url, allowedRoots: plan.allowedRoots, fileSystem: fileSystem) {
            return .refused(refusal)
        }
        // Being deep enough in an allowed folder is not enough: it must be a location named in full.
        guard let named = try? UninstallPlanner.removableLocations(for: plan.roots),
              named.contains(where: { UninstallPathPolicy.isSame($0, url) })
        else { return .refused(.notPartOfThePlan(url.path)) }
        guard fileSystem.kind(of: url) != .missing else { return .nothingThere }
        guard !touchesExportFolder(url, in: plan) else { return .refused(.touchesExportFolder(url.path)) }
        do {
            try fileSystem.removeItem(at: url)
            return .done
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Asked of the disk as it is now, whatever the plan was built from.
    private func touchesExportFolder(_ url: URL, in plan: UninstallPlan) -> Bool {
        UninstallPathPolicy.relation(
            of: url, toExport: plan.roots.exportDirectory, resolving: fileSystem.canonical) != .apart
    }

    /// Only the plan's own data folder, only when it is a real folder, and only when empty.
    private func removeFolderIfEmpty(_ url: URL, in plan: UninstallPlan) -> UninstallReport.Outcome {
        guard UninstallPathPolicy.isPlain(url), UninstallPathPolicy.isSame(url, plan.roots.supportDirectory) else {
            return .refused(.notPartOfThePlan(url.path))
        }
        switch fileSystem.kind(of: url) {
        case .missing: return .nothingThere
        case .link: return .refused(.isALink(url.path))
        case .file: return .refused(.notPartOfThePlan(url.path))
        case .folder: break
        }
        guard !touchesExportFolder(url, in: plan) else { return .refused(.touchesExportFolder(url.path)) }
        do {
            return try fileSystem.removeFolderIfEmpty(at: url)
                ? .done : .failed("The folder still holds files Hushy did not create, so it was kept.")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Only a real `.app` folder that says it is this app goes to the Trash.
    private func moveAppToTrash(_ url: URL, in plan: UninstallPlan) async -> UninstallReport.Outcome {
        guard UninstallPathPolicy.isPlain(url), url.pathExtension == "app",
              plan.roots.bundleURL.map({ UninstallPathPolicy.isSame($0, url) }) ?? false
        else { return .refused(.notPartOfThePlan(url.path)) }
        switch fileSystem.kind(of: url) {
        case .missing: return .nothingThere
        case .link: return .refused(.isALink(url.path))
        case .file: return .refused(.notPartOfThePlan(url.path))
        case .folder: break
        }
        guard operations.bundleIdentifier(url) == plan.roots.bundleIdentifier else {
            return .refused(.notPartOfThePlan(url.path))
        }
        return await attempt { try await operations.moveToTrash(url) }
    }

    /// Only Hushy's own fixed identifier, never anything the plan or the environment holds. If
    /// macOS refuses or the command fails, the report says so and where to remove Hushy by hand.
    private func resetPermissions(_ id: String, in plan: UninstallPlan) async -> UninstallReport.Outcome {
        guard id == UninstallPlan.permissionsBundleIdentifier, plan.roots.bundleIdentifier == id else {
            return .failed(Self.permissionsNotReset(detail: "this is not Hushy's own identifier"))
        }
        do {
            try await operations.resetPermissions(UninstallPlan.permissionsBundleIdentifier)
            return .done
        } catch {
            return .failed(Self.permissionsNotReset(detail: error.localizedDescription))
        }
    }

    /// What the report says when the permissions could not be reset.
    public static func permissionsNotReset(detail: String) -> String {
        "macOS did not reset Hushy's permissions (\(detail)). Remove Hushy yourself in System Settings, "
            + "Privacy & Security, under Microphone and Accessibility."
    }

    /// A server that was not reached is said as it is, and is not a failure: the rest still runs.
    private func signOut() async -> UninstallReport.Outcome {
        do {
            try await operations.signOut()
            return .done
        } catch is UninstallSignOutNotConfirmed {
            return .signedOutOnThisMacOnly
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func attempt(_ work: @Sendable () async throws -> Void) async -> UninstallReport.Outcome {
        do {
            try await work()
            return .done
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
