import Foundation
import Security
import Testing
@testable import Murmur
@testable import MurmurCore

/// The app's own pieces of "Uninstall Hushy…" that can be checked without the system: what is
/// asked of the Keychain (the call itself is a recorder here, never `SecItemDelete`), what counts
/// as a test run, which speech models are Hushy's to remove, and what a sign-out reports.
@Suite("Uninstall: Keychain queries, test runs, speech models and sign-out")
struct UninstallLiveTests {
    /// Stands in for `SecItemDelete`: records every query and answers from a script.
    final class Recorder {
        var queries: [[String: Any]] = []
        var answers: [OSStatus]

        init(answers: [OSStatus] = []) {
            self.answers = answers
        }

        func delete(_ query: [String: Any]) -> OSStatus {
            queries.append(query)
            return answers.isEmpty ? errSecItemNotFound : answers.removeFirst()
        }
    }

    private let service = OAuthTokenStore.keychainService

    // MARK: Keychain

    @Test("a query names the item class, the service and not-synced, and nothing else", arguments: UninstallPlan.keychainServices)
    func queryIsNarrow(service: String) {
        let queries = KeychainSweep.queries(service: service, includesDataProtection: false)

        #expect(queries.count == 1)
        let query = queries[0]
        #expect(Set(query.keys) == [kSecClass as String, kSecAttrService as String, kSecAttrSynchronizable as String])
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == service)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
    }

    @Test("with the data-protection keychain there is a second query, the same but for that keychain")
    func dataProtectionAddsOneQuery() {
        let queries = KeychainSweep.queries(service: service, includesDataProtection: true)

        #expect(queries.count == 2)
        #expect(queries[0][kSecUseDataProtectionKeychain as String] == nil)
        #expect(queries[1][kSecUseDataProtectionKeychain as String] as? Bool == true)
        for query in queries {
            #expect(query[kSecAttrService as String] as? String == service)
            #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
            #expect(query[kSecAttrAccount as String] == nil)
            #expect(query[kSecMatchLimit as String] == nil)
        }
    }

    @Test("no query ever asks for synced items, so a recovery key in iCloud Keychain is never matched")
    func syncedItemsAreNeverAsked() {
        for service in UninstallPlan.keychainServices {
            for query in KeychainSweep.queries(service: service, includesDataProtection: true) {
                let synced = query[kSecAttrSynchronizable as String]
                #expect(synced as? Bool == false)
                #expect(synced as? String != kSecAttrSynchronizableAny as String)
            }
        }
    }

    @Test("a service that is not one of Hushy's is refused before anything is asked of the Keychain", arguments: [
        "", "com.apple.account", "app.hushy", "app.hushy.connectors.other", "*",
    ])
    func otherServicesAreRefused(service: String) {
        let recorder = Recorder()

        #expect(throws: KeychainSweep.Failure.notHushysService(service)) {
            try KeychainSweep.deleteAll(service: service, includesDataProtection: true, delete: recorder.delete)
        }
        #expect(recorder.queries.isEmpty)
    }

    @Test("each keychain is asked until nothing is left, with the same narrow query every time")
    func deletesUntilNothingIsLeft() throws {
        let recorder = Recorder(answers: [errSecSuccess, errSecSuccess, errSecItemNotFound, errSecSuccess])

        try KeychainSweep.deleteAll(service: service, includesDataProtection: true, delete: recorder.delete)

        // Login keychain: two items and "nothing left". Data protection: one item and "nothing left".
        #expect(recorder.queries.count == 5)
        #expect(recorder.queries.prefix(3).allSatisfy { $0[kSecUseDataProtectionKeychain as String] == nil })
        #expect(recorder.queries.suffix(2).allSatisfy { $0[kSecUseDataProtectionKeychain as String] as? Bool == true })
        #expect(recorder.queries.allSatisfy { $0[kSecAttrService as String] as? String == service })
    }

    @Test("a Keychain error is reported, and a keychain that never empties is not asked for ever")
    func errorsAndBounds() throws {
        let failing = Recorder(answers: [errSecInteractionNotAllowed])
        #expect(throws: KeyStoreError.self) {
            try KeychainSweep.deleteAll(service: service, includesDataProtection: false, delete: failing.delete)
        }
        #expect(failing.queries.count == 1)

        let endless = Recorder(answers: Array(repeating: errSecSuccess, count: KeychainSweep.mostItems * 2))
        try KeychainSweep.deleteAll(service: service, includesDataProtection: false, delete: endless.delete)
        #expect(endless.queries.count == KeychainSweep.mostItems)
    }

    // MARK: Test runs

    @Test("an ordinary run of the app is not a test run")
    func ordinaryRun() {
        #expect(!LiveUninstall.isTestRun(
            environment: ["HOME": "/Users/someone", "HUSHY_HOME": ""], arguments: ["/Applications/Hushy.app/Contents/MacOS/Hushy"],
            isDisposableRun: false, hostsTests: false))
    }

    @Test("a moved data folder or a throwaway settings suite makes a test run", arguments: [
        "HUSHY_HOME", "MURMUR_HOME", "MURMUR_DEFAULTS_SUITE",
    ])
    func environmentMakesATestRun(variable: String) {
        #expect(LiveUninstall.isTestRun(
            environment: [variable: "/tmp/somewhere"], arguments: [], isDisposableRun: false, hostsTests: false))
    }

    @Test("snapshot and mock-microphone modes make a test run", arguments: [
        "--snapshots", "--mock-mic", "--mock-mic-jobs", "--mock-mic-assemble",
    ])
    func launchFlagMakesATestRun(flag: String) {
        #expect(LiveUninstall.isTestRun(
            environment: [:], arguments: ["Hushy", flag, "/tmp/out"], isDisposableRun: false, hostsTests: false))
    }

    @Test("a disposable run and a test process are test runs")
    func disposableAndTestProcess() {
        #expect(LiveUninstall.isTestRun(environment: [:], arguments: [], isDisposableRun: true, hostsTests: false))
        #expect(LiveUninstall.isTestRun(environment: [:], arguments: [], isDisposableRun: false, hostsTests: true))
    }

    // MARK: Sign-out

    private struct StoreFailure: Error {}

    @Test("a server that confirmed is a plain sign-out, after this Mac forgot the account")
    func confirmedSignOut() async throws {
        var forgot = 0

        try await LiveUninstall.signOut(endServerSession: { true }, forgetOnThisMac: { forgot += 1 })

        #expect(forgot == 1)
    }

    @Test("a server that did not confirm is reported, and this Mac has forgotten the account all the same")
    func unconfirmedSignOutIsReported() async {
        var forgot = 0

        await #expect(throws: UninstallSignOutNotConfirmed()) {
            try await LiveUninstall.signOut(endServerSession: { false }, forgetOnThisMac: { forgot += 1 })
        }

        #expect(forgot == 1)
    }

    @Test("an account this Mac could not forget is a failure in its own right, whatever the server said")
    func forgettingThatFailsIsTheFailure() async {
        for confirmed in [true, false] {
            await #expect(throws: StoreFailure.self) {
                try await LiveUninstall.signOut(endServerSession: { confirmed }, forgetOnThisMac: { throw StoreFailure() })
            }
        }
    }

    // MARK: Speech models

    @Test("the model an earlier build used is not in the list: it is not Hushy's to remove")
    func supersededModelIsLeft() {
        let versions = LiveUninstall.speechModelVersions.map { String(describing: $0) }

        #expect(versions == ["ultra", String(describing: SpeechEngine.driftFallbackVersion)])
        #expect(!versions.contains("v3"))
    }

    @Test("the speech engine keeps its models in the folder the plan removes them from, so each is one plain name")
    func engineAndPlanAgreeOnTheFolder() {
        // Paths only: nothing in the home folder is read.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folder = UninstallPlanner.speechModelsFolder(inHome: home)

        let names = LiveUninstall.speechModelFolderNames(home: home)

        #expect(names.count == LiveUninstall.speechModelVersions.count + 3)
        #expect(names.allSatisfy(UninstallPlanner.isPlainFolderName), "\(names)")
        #expect(LiveUninstall.speechModelFolders.allSatisfy {
            $0.deletingLastPathComponent().standardizedFileURL.path == folder.path
        })
    }

    @Test("if the engine kept its models anywhere else, none would be a plain name and the plan would leave them all")
    func aDriftedFolderIsLeftAlone() throws {
        let elsewhere = URL(fileURLWithPath: "/Users/someone-else", isDirectory: true)

        let names = LiveUninstall.speechModelFolderNames(home: elsewhere)

        #expect(names == LiveUninstall.speechModelFolders.map(\.path))
        #expect(!names.contains(where: UninstallPlanner.isPlainFolderName))
        let plan = try UninstallPlanner.plan(for: UninstallRoots(
            home: elsewhere, supportDirectory: elsewhere.appendingPathComponent("Library/Application Support/Hushy"),
            supportIsOverridden: false, bundleIdentifier: "app.hushy.Hushy", bundleURL: nil,
            exportDirectory: elsewhere.appendingPathComponent("Documents/Hushy"), speechModelFolderNames: names))
        #expect(plan.speechModelSteps.isEmpty)
        #expect(plan.kept.filter { $0.reason == .notAPlainFolderName }.map(\.location) == names)
    }

    @Test("model folders become names inside the speech engine's folder, by path alone")
    func folderNamesArePathArithmetic() {
        let root = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Engine/Models", isDirectory: true)
        let names = LiveUninstall.folderNames(
            of: [
                root.appendingPathComponent("speech-a", isDirectory: true),
                root.appendingPathComponent("nested/speech-b", isDirectory: true),
                URL(fileURLWithPath: "/Users/someone/Elsewhere/speech-c", isDirectory: true),
                root,
            ],
            inside: root)

        #expect(names == ["speech-a", "nested/speech-b", "/Users/someone/Elsewhere/speech-c", root.path])
        // Only the first is a plain name; the planner leaves the others where they are.
        #expect(names.map(UninstallPlanner.isPlainFolderName) == [true, false, false, false])
    }
}

/// The `tccutil` call behind the permissions reset. The process is a recorder: no test runs it.
@Suite("Uninstall: the tccutil command line")
struct TCCResetTests {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []
        var result = TCCReset.Result(status: 0, output: "")
        var throwsOnRun = false
        struct CouldNotStart: Error, LocalizedError { var errorDescription: String? { "no such file" } }

        var calls: [[String]] { lock.withLock { recorded } }

        func run(_ executable: String, _ arguments: [String]) throws -> TCCReset.Result {
            lock.withLock { recorded.append([executable] + arguments) }
            if throwsOnRun { throw CouldNotStart() }
            return result
        }
    }

    @Test("it runs /usr/bin/tccutil reset All app.hushy.Hushy and nothing else")
    func exactCommandLine() async throws {
        let recorder = Recorder()

        try await TCCReset.reset(bundleIdentifier: "app.hushy.Hushy", run: recorder.run)

        #expect(recorder.calls == [["/usr/bin/tccutil", "reset", "All", "app.hushy.Hushy"]])
    }

    @Test("another identifier is refused before any command is run", arguments: [
        "com.apple.Safari", "", "All", "app.hushy.Hushy ", "app.hushy.Hushy.helper",
    ])
    func otherIdentifiersAreRefused(identifier: String) async {
        let recorder = Recorder()

        await #expect(throws: TCCReset.Failure.notHushysIdentifier(identifier)) {
            try await TCCReset.reset(bundleIdentifier: identifier, run: recorder.run)
        }
        #expect(recorder.calls.isEmpty)
    }

    @Test("a command that exits with an error is a failure that carries what it said")
    func failingExit() async {
        let recorder = Recorder()
        recorder.result = TCCReset.Result(status: 70, output: "tccutil: Failed to reset")

        await #expect(throws: TCCReset.Failure.failed(status: 70, output: "tccutil: Failed to reset")) {
            try await TCCReset.reset(bundleIdentifier: "app.hushy.Hushy", run: recorder.run)
        }
    }

    @Test("a command that cannot start is a failure")
    func cannotStart() async {
        let recorder = Recorder()
        recorder.throwsOnRun = true

        await #expect(throws: TCCReset.Failure.couldNotStart("no such file")) {
            try await TCCReset.reset(bundleIdentifier: "app.hushy.Hushy", run: recorder.run)
        }
    }
}
