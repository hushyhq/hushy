import Foundation
import Testing
@testable import MurmurCore

@Suite("UninstallExecutor")
struct UninstallExecutorTests {
    private let id = UninstallTestHome.bundleIdentifier

    /// A home with Hushy's files and with other apps' and the person's own files beside them.
    private func populate(_ test: UninstallTestHome) throws -> (hushy: [URL], unrelated: [URL]) {
        let hushy = try [
            test.write("Library/Application Support/Hushy/murmur.sqlite"),
            test.write("Library/Application Support/Hushy/Audio/one.wav"),
            test.write("Library/Application Support/Hushy/Models/writing/weights.bin"),
            test.write("Library/Application Support/Hushy/account.keys"),
            test.write("Library/Application Support/FluidAudio/Models/parakeet-one/model.bin"),
            test.write("Library/Application Support/FluidAudio/Models/parakeet-two/model.bin"),
            test.write("Library/Caches/\(id)/cache.db"),
            test.write("Library/HTTPStorages/\(id)/storage.db"),
            test.write("Library/HTTPStorages/\(id).binarycookies"),
            test.write("Library/Preferences/\(id).plist"),
            test.write("Library/Saved Application State/\(id).savedState/windows.plist"),
        ]
        let unrelated = try [
            test.write("Documents/Hushy/2026-01-01 0900 Planning.md"),
            test.write("Documents/letter.txt"),
            test.write("Library/Application Support/FluidAudio/Models/someone-elses-model/model.bin"),
            test.write("Library/Application Support/Other App/data.db"),
            test.write("Library/Application Support/HushyNotes/data.db"),
            test.write("Library/Caches/com.example.other/cache.db"),
            test.write("Library/Caches/\(id).other/cache.db"),
            test.write("Library/Preferences/com.example.other.plist"),
            test.write("Library/Preferences/\(id).helper.plist"),
            test.write("Library/Saved Application State/com.example.other.savedState/windows.plist"),
            test.write("Applications/Hushy.app/Contents/Info.plist"),
            test.write("Applications/Other.app/Contents/Info.plist"),
        ]
        return (hushy, unrelated)
    }

    @Test("running the plan on a populated home removes Hushy's files and leaves everything else")
    func removesOnlyHushy() async throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let files = try populate(test)
        let log = UninstallOperationLog()
        let plan = try UninstallPlanner.plan(for: test.roots())

        let report = await UninstallExecutor(fileSystem: LocalUninstallFileSystem(), operations: log.operations).run(plan)

        #expect(report.removedEverything)
        for url in files.hushy { #expect(!test.exists(url), "\(url.path) should be gone") }
        for url in files.unrelated { #expect(test.exists(url), "\(url.path) should still be there") }
        #expect(!test.exists(test.support))
        #expect(test.exists(test.speechModels))
        #expect(log.calls == [
            "stop", "signOut", "loginItem", "notifications",
            "keychain:app.hushy.connectors", "keychain:app.hushy.account", "keychain:app.hushy.model-keys",
            "keychain:app.hushy.encryption", "defaults:\(id)", "trash:\(test.bundle.path)", "tccutil:\(id)",
        ])
        // The app is handed to the injected Trash, never removed by the file system.
        #expect(test.exists(test.bundle))
    }

    @Test("a location with nothing at it is reported as nothing there, not as a failure")
    func missingItemsAreNotFailures() async throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let plan = try UninstallPlanner.plan(for: test.roots(bundle: .some(nil)))

        let report = await UninstallExecutor(
            fileSystem: LocalUninstallFileSystem(), operations: UninstallOperationLog().operations).run(plan)

        #expect(report.removedEverything)
        let fileOutcomes = report.entries.filter { $0.step.fileURL != nil }.map(\.outcome)
        #expect(!fileOutcomes.isEmpty)
        #expect(fileOutcomes.allSatisfy { $0 == .nothingThere })
    }

    @Test("a failing step does not stop the rest, and is reported with where it is")
    func failuresAreReportedAndTheRestRuns() async throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let files = try populate(test)
        let caches = test.library.appendingPathComponent("Caches/\(id)").path
        let log = UninstallOperationLog()
        log.failing = ["signOut", "keychain:app.hushy.connectors"]
        let plan = try UninstallPlanner.plan(for: test.roots())

        let report = await UninstallExecutor(
            fileSystem: FailingUninstallFileSystem(failing: [caches]), operations: log.operations).run(plan)

        #expect(!report.removedEverything)
        #expect(report.refusal == nil)
        #expect(report.entries.count == plan.steps.count)
        #expect(report.leftovers.map(\.step.action.label) == [
            "signOut", "keychain:app.hushy.connectors", "remove:\(caches)",
        ])
        #expect(report.leftovers.map(\.step.location).contains(caches))
        #expect(report.leftovers.allSatisfy { $0.outcome.explanation?.isEmpty == false })
        // Everything after each failure still ran.
        #expect(log.calls.contains("keychain:app.hushy.account"))
        #expect(log.calls.contains("keychain:app.hushy.encryption"))
        #expect(log.calls.contains("defaults:\(id)"))
        #expect(log.calls.contains("trash:\(test.bundle.path)"))
        #expect(test.exists(URL(fileURLWithPath: caches)))
        for url in files.hushy where !url.path.hasPrefix(caches) { #expect(!test.exists(url), "\(url.path)") }
        for url in files.unrelated { #expect(test.exists(url), "\(url.path)") }
    }

    @Test("a data folder that is a link to somewhere else is refused, both ends are left, and the key stays with them")
    func linkedDataFolderIsRefused() async throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let outside = try test.write("elsewhere/precious.txt", in: test.root)
        try FileManager.default.createDirectory(at: test.support.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: test.support, withDestinationURL: outside.deletingLastPathComponent())
        let plan = try UninstallPlanner.plan(for: test.roots())
        let log = UninstallOperationLog()

        let report = await UninstallExecutor(fileSystem: LocalUninstallFileSystem(), operations: log.operations).run(plan)

        #expect(test.exists(outside))
        #expect(test.exists(test.support))
        #expect(report.leftovers.map(\.outcome) == [.refused(.isALink(test.support.path)), .keptWithRecordings])
        #expect(report.leftovers.first?.step.location == test.support.path)
        #expect(!log.calls.contains("keychain:app.hushy.encryption"))
    }

    @Test("when the recordings cannot be removed, their encryption key is kept and the report says why")
    func keyIsKeptWhenDataRemovalFails() async throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        _ = try populate(test)
        let log = UninstallOperationLog()
        let plan = try UninstallPlanner.plan(for: test.roots())

        let report = await UninstallExecutor(
            fileSystem: FailingUninstallFileSystem(failing: [test.support.path]), operations: log.operations).run(plan)

        #expect(report.leftovers.map(\.step.action.label) == ["remove:\(test.support.path)", "keychain:app.hushy.encryption"])
        let key = try #require(report.leftovers.last)
        #expect(key.outcome == .keptWithRecordings)
        #expect(key.outcome.explanation?.contains("still readable with this key") == true)
        #expect(key.step.location.contains("app.hushy.encryption"))
        #expect(!log.calls.contains("keychain:app.hushy.encryption"))
        // The other keys, which protect nothing left behind, still went.
        #expect(log.calls.contains("keychain:app.hushy.connectors"))
        #expect(log.calls.contains("keychain:app.hushy.account"))
        #expect(log.calls.dropLast().last == "trash:\(test.bundle.path)")
    }

    @Test("a failure that is not about recordings does not keep the key")
    func keyGoesWhenOnlyACacheFails() async throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        _ = try populate(test)
        let log = UninstallOperationLog()
        log.failing = ["keychain:app.hushy.connectors"]
        let plan = try UninstallPlanner.plan(for: test.roots())

        _ = await UninstallExecutor(fileSystem: LocalUninstallFileSystem(), operations: log.operations).run(plan)

        #expect(log.calls.contains("keychain:app.hushy.encryption"))
    }

    @Test("a sign-out the server did not confirm is reported as this Mac only, and nothing else is held up")
    func unconfirmedSignOutIsSaidAndTheRestRuns() async throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let files = try populate(test)
        let log = UninstallOperationLog()
        log.signOutIsUnconfirmed = true
        let plan = try UninstallPlanner.plan(for: test.roots())

        let report = await UninstallExecutor(fileSystem: LocalUninstallFileSystem(), operations: log.operations).run(plan)

        let signOut = try #require(report.entries.first { $0.step.action == .signOut })
        #expect(signOut.outcome == .signedOutOnThisMacOnly)
        #expect(signOut.outcome.explanation?.contains("on this Mac only") == true)
        #expect(report.signedOutOnThisMacOnly)
        // Nothing is left on this Mac, so it is not a leftover; every other step still ran.
        #expect(report.leftovers.isEmpty)
        #expect(report.entries.filter { $0.step.action != .signOut }.allSatisfy { $0.outcome == .done || $0.outcome == .nothingThere })
        for url in files.hushy { #expect(!test.exists(url), "\(url.path) should be gone") }
        #expect(log.calls.contains("keychain:app.hushy.encryption"))
        #expect(log.calls.dropLast().last == "trash:\(test.bundle.path)")
    }

    @Test("a sign-out that fails outright is still a failure, with its reason")
    func failedSignOutIsAFailure() async throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let log = UninstallOperationLog()
        log.failing = ["signOut"]
        let plan = try UninstallPlanner.plan(for: test.roots())

        let report = await UninstallExecutor(fileSystem: LocalUninstallFileSystem(), operations: log.operations).run(plan)

        #expect(report.leftovers.map(\.outcome) == [.failed("It is in use.")])
        #expect(!report.signedOutOnThisMacOnly)
    }

    @Test("if Hushy will not stop, the uninstall is abandoned before anything is removed and the app is put back to work")
    func abandonedWhenStoppingFails() async throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let files = try populate(test)
        let plan = try UninstallPlanner.plan(for: test.roots())
        let stop = UninstallStopFailure(notStopped: "the recording in progress")
        let operations = UninstallOperationLog()
        var live = operations.operations
        live.stopActivity = {
            _ = try? await operations.operations.stopActivity()
            throw stop
        }
        let executor = UninstallExecutor(fileSystem: LocalUninstallFileSystem(), operations: live)

        let report = await executor.run(plan)

        #expect(report.abandoned == stop.errorDescription)
        #expect(report.abandoned?.contains("the recording in progress") == true)
        #expect(report.removedNothing)
        #expect(!report.removedEverything)
        #expect(report.entries.count == 1)
        #expect(operations.calls == ["stop", "resume"])
        for url in files.hushy + files.unrelated { #expect(test.exists(url), "\(url.path)") }
        // Nothing to tidy up after an uninstall that never started.
        let settled = await executor.settle(plan, after: report)
        #expect(settled.removedNothing)
        #expect(operations.calls == ["stop", "resume"])
    }

    @Test("an export folder that became a link into the data folder after the plan was built still stops the removal")
    func exportLinkFoundAtRemovalTime() async throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let exported = try test.write("Library/Application Support/Hushy/Exports/2026-01-01 0900 Planning.md")
        try test.write("Library/Application Support/Hushy/murmur.sqlite")
        // Built without looking at the disk, as if the link were made a moment later.
        let plan = try UninstallPlanner.plan(for: test.roots())
        try FileManager.default.createDirectory(at: test.export.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: test.export, withDestinationURL: exported.deletingLastPathComponent())
        let log = UninstallOperationLog()

        let report = await UninstallExecutor(fileSystem: LocalUninstallFileSystem(), operations: log.operations).run(plan)

        #expect(test.exists(exported))
        #expect(report.leftovers.map(\.outcome) == [.refused(.touchesExportFolder(test.support.path)), .keptWithRecordings])
    }

    @Test("an export folder written in another letter case stops the removal of the folder it names")
    func exportInAnotherCaseAtRemovalTime() async throws {
        let support = "/Users/someone/Library/Application Support/Hushy"
        let test = try UninstallTestHome()
        defer { test.remove() }
        var roots = test.roots(bundle: .some(nil))
        roots.home = URL(fileURLWithPath: "/Users/someone")
        roots.supportDirectory = URL(fileURLWithPath: support)
        let honest = try UninstallPlanner.plan(for: roots)
        roots.exportDirectory = URL(fileURLWithPath: "/Users/someone/LIBRARY/application support/HUSHY/exports")
        let stale = UninstallPlan(
            roots: roots, allowedRoots: honest.allowedRoots, steps: honest.steps, kept: honest.kept,
            requiredDataMarker: nil, isTestRun: false)
        let disk = FakeUninstallFileSystem([support: .folder, support + "/Exports": .folder])

        let report = await UninstallExecutor(fileSystem: disk, operations: UninstallOperationLog().operations).run(stale)

        #expect(disk.remaining.contains(support + "/Exports"))
        #expect(report.leftovers.first?.outcome == .refused(.touchesExportFolder(support)))
    }

    @Test("a folder on the way that links out of the home Library is refused")
    func linkedParentIsRefused() async throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let outside = try test.write("elsewhere/\(id)/cache.db", in: test.root)
        try FileManager.default.createDirectory(at: test.library, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: test.library.appendingPathComponent("Caches"),
            withDestinationURL: test.root.appendingPathComponent("elsewhere", isDirectory: true))
        let plan = try UninstallPlanner.plan(for: test.roots())
        let caches = test.library.appendingPathComponent("Caches/\(id)").path

        let report = await UninstallExecutor(
            fileSystem: LocalUninstallFileSystem(), operations: UninstallOperationLog().operations).run(plan)

        #expect(test.exists(outside))
        #expect(report.leftovers.map(\.outcome) == [.refused(.leadsOutside(caches))])
    }

    @Test("a link inside a removed folder goes, and what it points to stays")
    func linksInsideAreNotFollowed() async throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let outside = try test.write("elsewhere/precious.txt", in: test.root)
        try test.write("Library/Application Support/Hushy/murmur.sqlite")
        try FileManager.default.createSymbolicLink(
            at: test.support.appendingPathComponent("Audio"), withDestinationURL: outside.deletingLastPathComponent())
        let plan = try UninstallPlanner.plan(for: test.roots())

        let report = await UninstallExecutor(
            fileSystem: LocalUninstallFileSystem(), operations: UninstallOperationLog().operations).run(plan)

        #expect(report.removedEverything)
        #expect(!test.exists(test.support))
        #expect(test.exists(outside))
    }

    @Test("an override pointing at a folder that is not Hushy's refuses the whole uninstall")
    func unrelatedOverrideIsRefused() async throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let files = try populate(test)
        let unrelated = test.root.appendingPathComponent("projects", isDirectory: true)
        let project = try test.write("projects/Audio/song.wav", in: test.root)
        let log = UninstallOperationLog()
        let plan = try UninstallPlanner.plan(for: test.roots(support: unrelated, overridden: true))
        let executor = UninstallExecutor(fileSystem: LocalUninstallFileSystem(), operations: log.operations)

        let report = await executor.run(plan)

        #expect(executor.preflight(plan) == .notAHushyDataFolder(unrelated.path))
        #expect(report.refusal == .notAHushyDataFolder(unrelated.path))
        #expect(report.entries.isEmpty)
        #expect(!report.removedEverything)
        #expect(log.calls.isEmpty)
        #expect(test.exists(project))
        for url in files.hushy + files.unrelated { #expect(test.exists(url), "\(url.path)") }
    }

    @Test("an override that is a file or a link is refused; one that does not exist has nothing to lose")
    func overrideKinds() throws {
        let folder = URL(fileURLWithPath: "/tmp/hushy-fake/custom")
        let test = try UninstallTestHome()
        defer { test.remove() }
        let plan = try UninstallPlanner.plan(for: test.roots(support: folder, overridden: true))
        let operations = UninstallOperationLog().operations
        func preflight(_ kinds: [String: UninstallItemKind]) -> UninstallRefusal? {
            UninstallExecutor(fileSystem: FakeUninstallFileSystem(kinds), operations: operations).preflight(plan)
        }

        #expect(preflight([:]) == nil)
        #expect(preflight([folder.path: .folder, folder.path + "/murmur.sqlite": .file]) == nil)
        #expect(preflight([folder.path: .folder]) == .notAHushyDataFolder(folder.path))
        #expect(preflight([folder.path: .folder, folder.path + "/murmur.sqlite": .folder]) == .notAHushyDataFolder(folder.path))
        #expect(preflight([folder.path: .folder, folder.path + "/murmur.sqlite": .link]) == .notAHushyDataFolder(folder.path))
        #expect(preflight([folder.path: .link]) == .notAHushyDataFolder(folder.path))
        #expect(preflight([folder.path: .file]) == .notAHushyDataFolder(folder.path))
    }

    @Test("a test run loses only Hushy's own files in its folder, keeps the folder when anything else is in it, and touches nothing else")
    func testRunKeepsOtherFiles() async throws {
        let folder = "/tmp/hushy-fake/custom"
        let test = try UninstallTestHome()
        defer { test.remove() }
        let library = "/Users/someone/Library"
        let disk = FakeUninstallFileSystem([
            folder: .folder,
            "\(folder)/murmur.sqlite": .file,
            "\(folder)/murmur.sqlite-wal": .file,
            "\(folder)/Audio": .folder,
            "\(folder)/Audio/one.wav": .file,
            "\(folder)/Models": .folder,
            "\(folder)/account.keys": .file,
            "\(folder)/my-own-notes.txt": .file,
            "\(library)/Caches/\(id)": .folder,
            "\(library)/Preferences/\(id).plist": .file,
            "\(library)/Application Support/Hushy": .folder,
            "\(library)/Application Support/FluidAudio/Models/parakeet-one": .folder,
            "/Applications/Hushy.app": .folder,
        ])
        var roots = test.roots(support: URL(fileURLWithPath: folder), overridden: true)
        roots.home = URL(fileURLWithPath: "/Users/someone")
        roots.bundleURL = URL(fileURLWithPath: "/Applications/Hushy.app")
        let plan = try UninstallPlanner.plan(for: roots)
        let log = UninstallOperationLog()

        let report = await UninstallExecutor(fileSystem: disk, operations: log.operations).run(plan)

        #expect(disk.remaining == [
            folder, "\(folder)/my-own-notes.txt", "\(library)/Caches/\(id)", "\(library)/Preferences/\(id).plist",
            "\(library)/Application Support/Hushy", "\(library)/Application Support/FluidAudio/Models/parakeet-one",
            "/Applications/Hushy.app",
        ])
        #expect(report.leftovers.map(\.step.action.label) == ["removeIfEmpty:\(folder)"])
        #expect(report.leftovers.first?.step.location == folder)
        // No sign-out, Keychain, login item, notifications, settings or Trash: only the stop.
        #expect(log.calls == ["stop"])
    }

    @Test("a test run's folder holding only Hushy's files is removed once empty")
    func testRunFolderRemovedWhenEmpty() async throws {
        let folder = "/tmp/hushy-fake/custom"
        let test = try UninstallTestHome()
        defer { test.remove() }
        let disk = FakeUninstallFileSystem([
            folder: .folder, "\(folder)/murmur.sqlite": .file, "\(folder)/Notes": .folder, "\(folder)/Notes/1/a.wav": .file,
        ])
        let plan = try UninstallPlanner.plan(
            for: test.roots(support: URL(fileURLWithPath: folder), overridden: true, bundle: .some(nil)))
        let log = UninstallOperationLog()

        let report = await UninstallExecutor(fileSystem: disk, operations: log.operations).run(plan)

        #expect(report.removedEverything)
        #expect(disk.remaining.isEmpty)
        #expect(disk.removed.last == folder)
        #expect(log.calls == ["stop"])
    }

    @Test("in a test run, a step that reaches past the data folder is refused whatever built the plan")
    func testRunRefusesEverythingElse() async throws {
        let folder = "/tmp/hushy-fake/custom"
        let test = try UninstallTestHome()
        defer { test.remove() }
        var roots = test.roots(support: URL(fileURLWithPath: folder), overridden: true)
        roots.home = URL(fileURLWithPath: "/Users/someone")
        roots.bundleURL = URL(fileURLWithPath: "/Applications/Hushy.app")
        let honest = try UninstallPlanner.plan(for: roots)
        let reaching: [UninstallStep.Action] = [
            .signOut, .unregisterLoginItem, .clearNotifications,
            .deleteKeychainItems(service: "app.hushy.encryption"), .deleteKeychainItems(service: "app.hushy.connectors"),
            .clearDefaults(domain: id), .moveAppToTrash(URL(fileURLWithPath: "/Applications/Hushy.app")),
            .resetPermissions(bundleIdentifier: id),
            .removeItem(URL(fileURLWithPath: "/Users/someone/Library/Caches/\(id)")),
            .removeItem(URL(fileURLWithPath: "/Users/someone/Library/Application Support/Hushy")),
        ]
        let plan = UninstallPlan(
            roots: roots, allowedRoots: honest.allowedRoots,
            steps: reaching.map { UninstallStep($0, .settings, "Not the test run's") }, kept: [],
            requiredDataMarker: honest.requiredDataMarker, isTestRun: true)
        let disk = FakeUninstallFileSystem([
            folder: .folder, "\(folder)/murmur.sqlite": .file,
            "/Users/someone/Library/Caches/\(id)": .folder, "/Users/someone/Library/Application Support/Hushy": .folder,
            "/Applications/Hushy.app": .folder,
        ])
        let log = UninstallOperationLog()

        let report = await UninstallExecutor(fileSystem: disk, operations: log.operations).run(plan)

        #expect(report.entries.count == reaching.count)
        for entry in report.entries {
            guard case .refused = entry.outcome else {
                Issue.record("\(entry.step.action.label) was not refused: \(entry.outcome)")
                continue
            }
        }
        #expect(log.calls.isEmpty)
        #expect(disk.removed.isEmpty)
    }

    @Test("a step that is not inside the plan's own folders is refused, whatever built the plan")
    func refusesStepsOutsideThePlan() async throws {
        // An invented home on an in-memory disk: these steps name `/` and a relative path, and
        // must never be put to a real one.
        let home = "/Users/someone"
        let library = "\(home)/Library"
        let test = try UninstallTestHome()
        defer { test.remove() }
        var roots = test.roots()
        roots.home = URL(fileURLWithPath: home)
        roots.supportDirectory = URL(fileURLWithPath: "\(library)/Application Support/Hushy")
        roots.exportDirectory = URL(fileURLWithPath: "\(home)/Documents/Hushy")
        roots.bundleURL = URL(fileURLWithPath: "/Applications/Hushy.app")
        let honest = try UninstallPlanner.plan(for: roots)
        let present: [String: UninstallItemKind] = [
            "/": .folder, home: .folder, library: .folder, "\(home)/Documents": .folder,
            "\(home)/Documents/letter.txt": .file, "\(home)/Documents/Hushy": .folder,
            "\(library)/Caches": .folder, "\(library)/Caches/\(id)": .folder,
            "\(library)/Application Support": .folder, "/Applications/Other.app": .folder,
        ]
        let disk = FakeUninstallFileSystem(present)
        let bad: [UninstallStep.Action] = [
            .removeItem(URL(fileURLWithPath: "\(home)/Documents/letter.txt")),
            .removeItem(URL(fileURLWithPath: "\(home)/Documents/Hushy")),
            .removeItem(URL(fileURLWithPath: "\(library)/Caches")),
            .removeItem(URL(fileURLWithPath: library)),
            .removeItem(URL(fileURLWithPath: home)),
            .removeItem(URL(fileURLWithPath: "/")),
            .removeItem(URL(fileURLWithPath: "relative/path")),
            .removeItem(URL(fileURLWithPath: "\(library)/Caches/\(id)/../../../Documents/letter.txt")),
            .removeFolderIfEmpty(URL(fileURLWithPath: "\(home)/Documents")),
            .removeFolderIfEmpty(URL(fileURLWithPath: "\(library)/Application Support")),
            .clearDefaults(domain: "com.example.other"),
            .deleteKeychainItems(service: "com.example.other"),
            .moveAppToTrash(URL(fileURLWithPath: "/Applications/Other.app")),
            .moveAppToTrash(URL(fileURLWithPath: "\(home)/Documents")),
        ]
        let plan = UninstallPlan(
            roots: honest.roots, allowedRoots: honest.allowedRoots,
            steps: bad.map { UninstallStep($0, .caches, "Not Hushy's") }, kept: [], requiredDataMarker: nil,
            isTestRun: false)
        let log = UninstallOperationLog()

        let report = await UninstallExecutor(fileSystem: disk, operations: log.operations).run(plan)

        #expect(report.entries.count == bad.count)
        for entry in report.entries {
            guard case .refused = entry.outcome else {
                Issue.record("\(entry.step.action.label) was not refused: \(entry.outcome)")
                continue
            }
        }
        #expect(log.calls.isEmpty)
        #expect(disk.removed.isEmpty)
        #expect(disk.remaining == Set(present.keys))
    }

    @Test("allowed folders that are the disk root or one level deep allow nothing")
    func rootLikeAllowedFoldersAreIgnored() throws {
        let disk = FakeUninstallFileSystem(["/Users/someone/file": .file])
        let roots = [
            UninstallAllowedRoot(url: URL(fileURLWithPath: "/"), minimumDepth: 1),
            UninstallAllowedRoot(url: URL(fileURLWithPath: "/Users"), minimumDepth: 1),
        ]

        let refusal = UninstallPathPolicy.refusal(
            for: URL(fileURLWithPath: "/Users/someone/file"), allowedRoots: roots, fileSystem: disk)

        #expect(refusal == .outsideAllowedFolders("/Users/someone/file"))
    }

    @Test("the app is not moved to the Trash when the bundle is someone else's or a link")
    func trashOnlyTheApp() async throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        try test.write("Applications/Hushy.app/Contents/Info.plist")
        let plan = try UninstallPlanner.plan(for: test.roots())
        let log = UninstallOperationLog()
        log.bundleIdentifier = "com.example.other"

        let report = await UninstallExecutor(fileSystem: LocalUninstallFileSystem(), operations: log.operations).run(plan)

        #expect(report.leftovers.map(\.step.action.label) == ["trash:\(test.bundle.path)"])
        #expect(!log.calls.contains { $0.hasPrefix("trash:") })

        let linked = FakeUninstallFileSystem([test.bundle.path: .link])
        let linkedLog = UninstallOperationLog()
        let linkedReport = await UninstallExecutor(fileSystem: linked, operations: linkedLog.operations).run(plan)
        #expect(linkedReport.leftovers.map(\.outcome) == [.refused(.isALink(test.bundle.path))])
        #expect(!linkedLog.calls.contains { $0.hasPrefix("trash:") })
    }

    @Test("settling removes what the app wrote back, and never repeats the Keychain, the sign-out or the Trash")
    func settleRepeatsRemovalsOnly() async throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        _ = try populate(test)
        let log = UninstallOperationLog()
        let plan = try UninstallPlanner.plan(for: test.roots())
        let executor = UninstallExecutor(fileSystem: LocalUninstallFileSystem(), operations: log.operations)
        let report = await executor.run(plan)
        // The still-open app writes its settings and a cache back.
        let preferences = try test.write("Library/Preferences/\(id).plist")
        let cache = try test.write("Library/Caches/\(id)/cache.db")
        let before = log.calls

        let settled = await executor.settle(plan, after: report)

        #expect(settled.removedEverything)
        #expect(Array(log.calls.dropFirst(before.count)) == ["defaults:\(id)"])
        #expect(!test.exists(preferences))
        #expect(!test.exists(cache))
        #expect(test.exists(test.export))
    }

    @Test("settling does nothing after a refused run, or with a report from another plan")
    func settleNeedsAnAcceptedRun() async throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let cache = try test.write("Library/Caches/\(id)/cache.db")
        let unrelated = try test.write("projects/song.wav", in: test.root).deletingLastPathComponent()
        let log = UninstallOperationLog()
        let executor = UninstallExecutor(fileSystem: LocalUninstallFileSystem(), operations: log.operations)
        let refusedPlan = try UninstallPlanner.plan(for: test.roots(support: unrelated, overridden: true))
        let refused = await executor.run(refusedPlan)

        let afterRefusal = await executor.settle(refusedPlan, after: refused)
        let withoutRun = await executor.settle(refusedPlan, after: UninstallReport(refusal: nil, entries: []))

        #expect(afterRefusal.refusal != nil)
        #expect(withoutRun.refusal != nil)
        #expect(log.calls.isEmpty)
        #expect(test.exists(cache))
    }

    @Test("sizes are added up by group, with the writing models counted as models")
    func inventory() throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let plan = try UninstallPlanner.plan(for: test.roots())
        let disk = FakeUninstallFileSystem([:])
        disk.sizes = [
            test.support.path: 1_000,
            test.support.path + "/Models": 400,
            test.speechModels.path + "/parakeet-one": 50,
            test.speechModels.path + "/parakeet-two": 70,
            test.library.path + "/Caches/\(id)": 9,
            test.library.path + "/Preferences/\(id).plist": 2,
        ]

        let inventory = UninstallInventory.measure(plan, fileSystem: disk)

        #expect(inventory.bytes(in: .data) == 600)
        #expect(inventory.bytes(in: .models) == 400)
        #expect(inventory.bytes(in: .speechModels) == 120)
        #expect(inventory.bytes(in: .caches, .settings) == 11)
    }

    @Test("the real disk measures a folder by what is in it, and nothing as zero")
    func measuresRealFolders() throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        try test.write("Library/Caches/\(id)/a.bin", bytes: 5_000)
        try test.write("Library/Caches/\(id)/inner/b.bin", bytes: 9_000)
        let disk = LocalUninstallFileSystem()

        #expect(disk.byteSize(of: test.library.appendingPathComponent("Caches/\(id)")) >= 14_000)
        #expect(disk.byteSize(of: test.library.appendingPathComponent("Caches/nothing")) == 0)
        #expect(disk.kind(of: test.library.appendingPathComponent("Caches/\(id)")) == .folder)
        #expect(disk.kind(of: test.library.appendingPathComponent("Caches/\(id)/a.bin")) == .file)
        #expect(disk.kind(of: test.library.appendingPathComponent("Caches/nothing")) == .missing)
    }

    @Test("an empty folder is removed, and one with something in it is kept")
    func removesOnlyEmptyFolders() throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let disk = LocalUninstallFileSystem()
        let empty = test.root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let full = try test.write("full/file.txt", in: test.root).deletingLastPathComponent()

        #expect(try disk.removeFolderIfEmpty(at: empty))
        #expect(try disk.removeFolderIfEmpty(at: full) == false)
        #expect(!test.exists(empty))
        #expect(test.exists(full))
    }
}
