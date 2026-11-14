import AppKit
import FluidAudio
import MurmurCore
import Security
import ServiceManagement
import UserNotifications

/// The real pieces behind "Uninstall Hushy…": where this copy of the app keeps things, and the
/// system calls the plan's steps turn into. The decisions are in `UninstallPlanner` and
/// `UninstallExecutor` (MurmurCore), which are tested on temporary folders and fakes; nothing
/// here decides what is removed.
enum LiveUninstall {
    @MainActor
    static func roots(model: AppModel, removesSpeechModels: Bool, resetsPermissions: Bool = true) -> UninstallRoots {
        let environment = ProcessInfo.processInfo.environment
        let isOverridden = homeOverrides.contains { !(environment[$0] ?? "").isEmpty }
        let bundle = Bundle.main.bundleURL
        let home = FileManager.default.homeDirectoryForCurrentUser
        return UninstallRoots(
            home: home,
            supportDirectory: AppPaths.supportDirectory,
            supportIsOverridden: isOverridden,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? SingleInstance.bundleIdentifier,
            bundleURL: bundle.pathExtension == "app" ? bundle : nil,
            exportDirectory: model.settings.exportDirectory,
            speechModelFolderNames: speechModelFolderNames(home: home),
            removesSpeechModels: removesSpeechModels, resetsPermissions: resetsPermissions,
            isTestRun: isTestRun(
                environment: environment, arguments: CommandLine.arguments,
                isDisposableRun: model.isDisposableRun, hostsTests: NSClassFromString("XCTestCase") != nil))
    }

    /// The plan for this copy of the app. The planner's one question of the disk, whether a
    /// location touches the export folder, is answered with links followed and names in the
    /// letter case the volume stores.
    @MainActor
    static func plan(model: AppModel, removesSpeechModels: Bool, resetsPermissions: Bool) throws -> UninstallPlan {
        let fileSystem = LocalUninstallFileSystem()
        return try UninstallPlanner.plan(
            for: roots(model: model, removesSpeechModels: removesSpeechModels, resetsPermissions: resetsPermissions),
            resolving: { fileSystem.canonical($0) })
    }

    /// The variables that move the data folder (`AppPaths.supportDirectory`).
    private static let homeOverrides = ["HUSHY_HOME", "MURMUR_HOME"]
    /// The launch flags of the snapshot and mock-microphone modes (`Snapshots`, `MockMicArguments`).
    private static let testFlags = ["--snapshots", "--mock-mic", "--mock-mic-jobs", "--mock-mic-assemble"]

    /// Any sign that this is not a person's ordinary run of the app: a moved data folder, a
    /// throwaway settings suite, snapshot or mock-microphone mode, or a test process. Such a
    /// run may remove only the named files in its own data folder (`UninstallPlanner`).
    static func isTestRun(
        environment: [String: String], arguments: [String], isDisposableRun: Bool, hostsTests: Bool
    ) -> Bool {
        let variables = homeOverrides + ["MURMUR_DEFAULTS_SUITE"]
        return isDisposableRun || hostsTests
            || variables.contains { !(environment[$0] ?? "").isEmpty }
            || arguments.contains { testFlags.contains($0) }
    }

    /// The speech models this build downloads: the dictation model and its English fallback
    /// (`SpeechEngine.load`, `loadFallbackManager`). The model an earlier build used is not in
    /// the list: this build does not use it, so it is not Hushy's to remove.
    static let speechModelVersions: [AsrModelVersion] = [.ultra, SpeechEngine.driftFallbackVersion]

    /// The folders the app downloads speech models into: the models above, the vocabulary model
    /// (`prefetchVocabularyModel`) and the speaker models (`SpeakerDiarizer.loadedManager` and
    /// `loadedNemotron`). The speech engine chooses each one itself; the app never hands it a folder.
    static var speechModelFolders: [URL] {
        speechModelVersions.map { AsrModels.defaultCacheDirectory(for: $0) }
            + [
                CtcModels.defaultCacheDirectory(for: .ctc110m), DiarizerModels.defaultModelsDirectory(),
                MLModelConfigurationUtils.defaultModelsDirectory(for: .nemotron3Diarization),
            ]
    }

    /// Those folders as names inside the one folder the plan removes speech models from
    /// (`UninstallPlanner.speechModelsFolder`). Measured against the plan's folder and not the
    /// engine's, so the two cannot drift apart unseen: a model the engine keeps anywhere else
    /// comes back as a whole path, and the plan leaves it where it is and says so.
    static func speechModelFolderNames(home: URL) -> [String] {
        folderNames(of: speechModelFolders, inside: UninstallPlanner.speechModelsFolder(inHome: home))
    }

    /// Each folder as a name inside the speech engine's model folder. A nested one comes back
    /// with a `/`, and one outside it as its whole path; the plan leaves both alone. Only the
    /// paths are compared: no file is looked at.
    static func folderNames(of folders: [URL], inside modelFolder: URL) -> [String] {
        let root = parts(modelFolder)
        return folders.map { folder in
            let own = parts(folder)
            guard own.count > root.count, Array(own.prefix(root.count)) == root else { return folder.path }
            return own.dropFirst(root.count).joined(separator: "/")
        }
    }

    private static func parts(_ url: URL) -> [String] {
        url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    @MainActor
    static func executor(model: AppModel) -> UninstallExecutor {
        UninstallExecutor(fileSystem: LocalUninstallFileSystem(), operations: operations(model: model))
    }

    @MainActor
    private static func operations(model: AppModel) -> UninstallOperations {
        UninstallOperations(
            stopActivity: { try await model.prepareForUninstall() },
            resumeActivity: { await model.resumeAfterAbandonedUninstall() },
            signOut: { try await signOut() },
            unregisterLoginItem: { try unregisterLoginItem() },
            clearNotifications: { clearNotifications() },
            deleteKeychainItems: { try KeychainSweep.deleteAll(service: $0) },
            clearDefaults: { domain in
                UserDefaults.standard.removePersistentDomain(forName: domain)
                UserDefaults.standard.synchronize()
            },
            bundleIdentifier: { Bundle(url: $0)?.bundleIdentifier },
            moveToTrash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
            resetPermissions: { try await TCCReset.reset(bundleIdentifier: $0) })
    }

    /// How long the server is given to end this Mac's session before the uninstall moves on.
    private static let signOutSeconds = 5

    /// Ends this Mac's session only (the website and other Macs stay signed in), then forgets
    /// the account, its approval and its plan.
    private static func signOut() async throws {
        try await signOut(endServerSession: endServerSession) {
            AccountSessionKeeper.shared.forget()
            try BetaApprovalStore().clear()
            try AccountEntitlementStore().clear()
        }
    }

    /// This Mac forgets the account whatever the server said. A server that did not confirm is
    /// then reported (`UninstallSignOutNotConfirmed`) and not hidden; the uninstall goes on.
    static func signOut(endServerSession: () async -> Bool, forgetOnThisMac: () throws -> Void) async throws {
        let isConfirmed = await endServerSession()
        try forgetOnThisMac()
        if !isConfirmed { throw UninstallSignOutNotConfirmed() }
    }

    /// True when the server ended this Mac's session within `signOutSeconds`, or there was no
    /// session to end. False when the session could not be read, the server refused or could
    /// not be reached, or it took too long.
    private static func endServerSession() async -> Bool {
        let session: AccountSession?
        do { session = try AccountSessionStore().load() } catch { return false }
        guard let session else { return true }
        guard let configuration = AccountConfiguration() else { return false }
        let client = AccountClient(configuration: configuration)
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await client.signOutThisSession(session.accessToken)) != nil }
            group.addTask {
                try? await Task.sleep(for: .seconds(signOutSeconds))
                return false
            }
            let isConfirmed = await group.next() ?? false
            group.cancelAll()
            return isConfirmed
        }
    }

    private static func unregisterLoginItem() throws {
        let service = SMAppService.mainApp
        guard service.status == .enabled || service.status == .requiresApproval else { return }
        try service.unregister()
    }

    /// `UNUserNotificationCenter` traps without a bundle identifier (see `UserNotificationReadyNotifier`).
    private static func clearNotifications() {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }
}

/// Deletes every generic-password item of one Keychain service the app created, in the login
/// keychain and, when this build may use it, the data-protection keychain. Items are matched by
/// service alone, so nothing is read and macOS has no secret to ask the person for. Items synced
/// through iCloud are never matched: the recovery key a person saved to Passwords stays.
enum KeychainSweep {
    enum Failure: Error, Equatable {
        /// Not one of the services Hushy creates items under (`UninstallPlan.keychainServices`).
        case notHushysService(String)
    }

    /// An upper bound on the loop; the app keeps a handful of items per service.
    static let mostItems = 256

    /// What is asked of the Keychain, one query per keychain. Each names the item class, the
    /// service and "not synced", and nothing else: no account, no wildcard.
    static func queries(service: String, includesDataProtection: Bool) -> [[String: Any]] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
        ]
        guard includesDataProtection else { return [query] }
        return [query, query.merging([kSecUseDataProtectionKeychain as String: true]) { _, new in new }]
    }

    /// `delete` is `SecItemDelete` in the app and a recorder in tests.
    static func deleteAll(
        service: String,
        includesDataProtection: Bool = KeychainKeyStore.dataProtectionKeychainAvailable,
        delete: ([String: Any]) -> OSStatus = { SecItemDelete($0 as CFDictionary) }
    ) throws {
        guard UninstallPlan.keychainServices.contains(service) else { throw Failure.notHushysService(service) }
        for query in queries(service: service, includesDataProtection: includesDataProtection) {
            try deleteEvery(matching: query, delete: delete)
        }
    }

    /// The login keychain deletes one match per call and the data-protection keychain all of
    /// them; asking until nothing is left covers both.
    private static func deleteEvery(matching query: [String: Any], delete: ([String: Any]) -> OSStatus) throws {
        for _ in 0..<mostItems {
            let status = delete(query)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess else { throw KeyStoreError.unhandledStatus(status) }
        }
    }
}

/// Asks macOS to forget Hushy's permissions with `/usr/bin/tccutil reset All app.hushy.Hushy`.
/// The arguments are built here from the one fixed identifier; nothing else can reach the
/// command line. `run` is the real process in the app and a recorder in tests.
enum TCCReset {
    static let executable = "/usr/bin/tccutil"

    /// What the command did: its exit status and what it wrote.
    struct Result: Equatable {
        var status: Int32
        var output: String
    }

    enum Failure: Error, Equatable, LocalizedError {
        /// Not Hushy's own identifier (`UninstallPlan.permissionsBundleIdentifier`).
        case notHushysIdentifier(String)
        case couldNotStart(String)
        case failed(status: Int32, output: String)

        var errorDescription: String? {
            switch self {
            case .notHushysIdentifier: "not Hushy's own identifier"
            case .couldNotStart(let reason): "tccutil could not start: \(reason)"
            case .failed(let status, let output):
                output.isEmpty ? "tccutil exited with status \(status)" : "tccutil said: \(output)"
            }
        }
    }

    static func arguments(for bundleIdentifier: String) -> [String] { ["reset", "All", bundleIdentifier] }

    static func reset(
        bundleIdentifier: String,
        run: @Sendable (_ executable: String, _ arguments: [String]) async throws -> Result = runProcess
    ) async throws {
        guard bundleIdentifier == UninstallPlan.permissionsBundleIdentifier else {
            throw Failure.notHushysIdentifier(bundleIdentifier)
        }
        let result: Result
        do { result = try await run(executable, arguments(for: bundleIdentifier)) } catch {
            throw Failure.couldNotStart(error.localizedDescription)
        }
        guard result.status == 0 else { throw Failure.failed(status: result.status, output: result.output) }
    }

    /// Runs the command off the main thread and waits for it, reading what it wrote.
    @Sendable
    static func runProcess(executable: String, arguments: [String]) async throws -> Result {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return Result(status: process.terminationStatus, output: output)
        }.value
    }
}
