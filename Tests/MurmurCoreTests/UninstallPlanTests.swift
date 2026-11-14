import Foundation
import Testing
@testable import MurmurCore

@Suite("UninstallPlan")
struct UninstallPlanTests {
    private let id = UninstallTestHome.bundleIdentifier

    private func files(_ plan: UninstallPlan) -> [String] {
        plan.steps.compactMap { $0.fileURL?.path }
    }

    @Test("the standard plan lists exactly the app's own locations, in order")
    func listsExactLocations() throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let library = test.library.path

        let plan = try UninstallPlanner.plan(for: test.roots())

        #expect(plan.labels == [
            "stop",
            "signOut",
            "loginItem",
            "notifications",
            "keychain:app.hushy.connectors",
            "keychain:app.hushy.account",
            "keychain:app.hushy.model-keys",
            "remove:\(library)/Application Support/Hushy",
            "keychain:app.hushy.encryption",
            "remove:\(library)/Application Support/FluidAudio/Models/parakeet-one",
            "remove:\(library)/Application Support/FluidAudio/Models/parakeet-two",
            "remove:\(library)/Caches/\(id)",
            "remove:\(library)/HTTPStorages/\(id)",
            "remove:\(library)/HTTPStorages/\(id).binarycookies",
            "remove:\(library)/Cookies/\(id).binarycookies",
            "remove:\(library)/WebKit/\(id)",
            "defaults:\(id)",
            "remove:\(library)/Preferences/\(id).plist",
            "remove:\(library)/Saved Application State/\(id).savedState",
            "trash:\(test.bundle.path)",
            "tccutil:\(id)",
        ])
        #expect(plan.requiredDataMarker == nil)
        #expect(!plan.isTestRun)
        #expect(plan.allowed == ["\(library) depth 2"])
        #expect(plan.kept == [UninstallKept(title: "Your export folder", location: test.export.path, reason: .exportFolder)])
    }

    @Test("every file the plan removes is at least two folders inside the home Library")
    func removalsStayInsideLibrary() throws {
        let test = try UninstallTestHome()
        defer { test.remove() }

        let plan = try UninstallPlanner.plan(for: test.roots())

        for path in files(plan) {
            let depth = UninstallPathPolicy.depth(of: URL(fileURLWithPath: path), below: test.library)
            #expect((depth ?? 0) >= 2, "\(path)")
        }
    }

    @Test("the Keychain services are the ones the app writes to")
    func keychainServicesMatchTheWriters() {
        #expect(UninstallPlan.keychainServices.contains(KeychainKeyStore.encryptionService))
        #expect(UninstallPlan.keychainServices.contains(OAuthTokenStore.keychainService))
        #expect(UninstallPlan.keychainServices.contains(SealedFormat.keychainService), "sealed model keys are removed too")
        #expect(UninstallPlan.keychainServices.allSatisfy { $0.hasPrefix("app.hushy.") })
    }

    @Test("the one-by-one list names the database, the recordings and the sign-in file")
    func dataFolderChildrenMatchTheWriters() {
        let names = UninstallPlanner.dataFolderChildren.map(\.name)
        #expect(names.contains(AppPaths.database.lastPathComponent))
        #expect(names.contains(AppPaths.audioDirectory.lastPathComponent))
        #expect(names.contains(AppPaths.notesAudioDirectory.lastPathComponent))
        #expect(names.contains(AppPaths.memoryDirectory.lastPathComponent))
        #expect(names.contains(FileKeyStore.account.fileURL.lastPathComponent))
        #expect(names.contains("Models"))
        #expect(names.contains(PreMeetingsBackup.fileName))
        #expect(UninstallPlanner.dataMarkerName == AppPaths.database.lastPathComponent)
        #expect(Set(names).count == names.count)
    }

    @Test("the export folder is never in a plan, wherever it is", arguments: [
        "Documents/Hushy",
        "Library/Application Support/Hushy/Exports",
        "Library/Application Support/Hushy",
        "Library/Application Support",
        "Library/Caches/app.hushy.Hushy",
        "Library/Caches/app.hushy.Hushy/inner",
        "Library",
        "",
    ])
    func exportFolderIsNeverRemoved(relativeExport: String) throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let export = relativeExport.isEmpty ? test.home : test.home.appendingPathComponent(relativeExport, isDirectory: true)

        let plan = try UninstallPlanner.plan(for: test.roots(export: export))

        for step in plan.steps {
            let url: URL? = switch step.action {
            case .removeItem(let url), .removeFolderIfEmpty(let url), .moveAppToTrash(let url): url
            default: nil
            }
            guard let url else { continue }
            #expect(!UninstallPathPolicy.isSame(url, export), "\(url.path) is the export folder")
            #expect(!UninstallPathPolicy.isInside(export, url), "\(url.path) holds the export folder")
            if step.fileURL != nil {
                #expect(!UninstallPathPolicy.isInside(url, export), "\(url.path) is inside the export folder")
            }
        }
        #expect(plan.kept.first == UninstallKept(title: "Your export folder", location: export.path, reason: .exportFolder))
    }

    @Test("an export folder inside the data folder turns the removal into the app's own files, one by one")
    func exportInsideDataFolder() throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let export = test.support.appendingPathComponent("Notes", isDirectory: true)

        let plan = try UninstallPlanner.plan(for: test.roots(export: export))

        let removed = files(plan)
        #expect(!removed.contains(test.support.path))
        #expect(removed.contains(test.support.appendingPathComponent("murmur.sqlite").path))
        #expect(removed.contains(test.support.appendingPathComponent("Audio").path))
        #expect(!removed.contains(export.path))
        #expect(plan.kept.contains(UninstallKept(title: "Note recordings", location: export.path, reason: .insideExportFolder)))
        #expect(!plan.labels.contains("removeIfEmpty:\(test.support.path)"))
        // The standard folder needs no marker even when it goes file by file.
        #expect(plan.requiredDataMarker == nil)
    }

    /// Every kind of step a test run must never contain.
    private func touchesOnlyItsOwnFolder(_ plan: UninstallPlan, folder: URL) -> Bool {
        plan.steps.allSatisfy { step in
            switch step.action {
            case .stopActivity: true
            case .removeItem(let url): UninstallPathPolicy.depth(of: url, below: folder) == 1
            case .removeFolderIfEmpty(let url): UninstallPathPolicy.isSame(url, folder)
            case .signOut, .unregisterLoginItem, .clearNotifications, .deleteKeychainItems, .clearDefaults, .moveAppToTrash,
                .resetPermissions: false
            }
        }
    }

    @Test("a data folder chosen by HUSHY_HOME is a test run: only its named files, and it must hold the database")
    func overriddenDataFolderIsATestRun() throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let custom = test.root.appendingPathComponent("custom-data", isDirectory: true)

        let plan = try UninstallPlanner.plan(for: test.roots(support: custom, overridden: true))

        let children = UninstallPlanner.dataFolderChildren.map { "remove:" + custom.appendingPathComponent($0.name).path }
        #expect(plan.labels == ["stop"] + children + ["removeIfEmpty:\(custom.path)"])
        #expect(plan.isTestRun)
        #expect(plan.requiredDataMarker?.path == custom.appendingPathComponent("murmur.sqlite").path)
        #expect(plan.allowed == ["\(custom.path) depth 1"])
        #expect(touchesOnlyItsOwnFolder(plan, folder: custom))
    }

    @Test("a test run has no Keychain step", arguments: [true, false])
    func testRunHasNoKeychainStep(flagged: Bool) throws {
        let plan = try testRunPlan(flagged: flagged)
        #expect(!plan.labels.contains { $0.hasPrefix("keychain:") })
        #expect(!plan.kept.contains { $0.reason == .recordingsStay })
    }

    @Test("a test run removes nothing in the home Library: no caches, cookies, saved state or speech models", arguments: [true, false])
    func testRunLeavesTheLibrary(flagged: Bool) throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let plan = try testRunPlan(flagged: flagged, in: test)
        #expect(!files(plan).contains { $0.hasPrefix(test.library.path + "/") || $0 == test.library.path })
        #expect(!plan.allowed.contains { $0.hasPrefix(test.library.path) })
        #expect(plan.speechModelSteps.isEmpty)
    }

    @Test("a test run does not clear settings", arguments: [true, false])
    func testRunLeavesSettings(flagged: Bool) throws {
        let plan = try testRunPlan(flagged: flagged)
        #expect(!plan.labels.contains { $0.hasPrefix("defaults:") })
        #expect(!files(plan).contains { $0.hasSuffix(".plist") })
    }

    @Test("a test run leaves the login item, the notifications and the sign-in on the server", arguments: [true, false])
    func testRunLeavesLoginItemAndAccount(flagged: Bool) throws {
        let plan = try testRunPlan(flagged: flagged)
        #expect(!plan.labels.contains("loginItem"))
        #expect(!plan.labels.contains("notifications"))
        #expect(!plan.labels.contains("signOut"))
    }

    @Test("a test run never moves the app to the Trash", arguments: [true, false])
    func testRunLeavesTheApp(flagged: Bool) throws {
        let plan = try testRunPlan(flagged: flagged)
        #expect(!plan.labels.contains { $0.hasPrefix("trash:") })
        #expect(plan.isTestRun)
    }

    /// A test run two ways: flagged (snapshot, test, mock microphone, another settings suite)
    /// with its own folder, or only an environment override.
    private func testRunPlan(flagged: Bool, in home: UninstallTestHome? = nil) throws -> UninstallPlan {
        let test = try home ?? UninstallTestHome()
        defer { if home == nil { test.remove() } }
        let custom = test.root.appendingPathComponent("custom-data", isDirectory: true)
        let plan = try UninstallPlanner.plan(for: test.roots(support: custom, overridden: true, isTestRun: flagged))
        #expect(touchesOnlyItsOwnFolder(plan, folder: custom))
        return plan
    }

    @Test("a test run on the real data folder is refused: it has nothing of its own to remove")
    func testRunWithoutItsOwnFolder() throws {
        let test = try UninstallTestHome()
        defer { test.remove() }

        #expect(throws: UninstallRefusal.testRunWithoutItsOwnFolder) {
            try UninstallPlanner.plan(for: test.roots(isTestRun: true))
        }
    }

    @Test("an override that names the standard folder is still a test run")
    func overrideOfTheStandardFolder() throws {
        let test = try UninstallTestHome()
        defer { test.remove() }

        let plan = try UninstallPlanner.plan(for: test.roots(overridden: true))

        #expect(plan.isTestRun)
        #expect(!files(plan).contains(test.support.path))
        #expect(touchesOnlyItsOwnFolder(plan, folder: test.support))
        #expect(plan.requiredDataMarker?.path == test.support.appendingPathComponent("murmur.sqlite").path)
    }

    @Test("the recording-encryption key comes after the recordings and waits for them")
    func encryptionKeyFollowsTheData() throws {
        let test = try UninstallTestHome()
        defer { test.remove() }

        let plan = try UninstallPlanner.plan(for: test.roots())

        let key = try #require(plan.labels.firstIndex(of: "keychain:app.hushy.encryption"))
        let data = try #require(plan.labels.firstIndex(of: "remove:\(test.support.path)"))
        #expect(key > data)
        #expect(plan.steps[key].onlyAfterDataRemoved)
        #expect(plan.steps.filter(\.onlyAfterDataRemoved).count == 1)
        #expect(plan.steps[data].removesData)
    }

    @Test("when recordings are kept, their encryption key is kept too")
    func encryptionKeyStaysWithKeptRecordings() throws {
        let test = try UninstallTestHome()
        defer { test.remove() }

        let whole = try UninstallPlanner.plan(for: test.roots(export: test.support))
        let audio = try UninstallPlanner.plan(for: test.roots(export: test.support.appendingPathComponent("Audio")))
        let elsewhere = try UninstallPlanner.plan(for: test.roots(export: test.support.appendingPathComponent("Exports")))

        for plan in [whole, audio] {
            #expect(!plan.labels.contains("keychain:app.hushy.encryption"))
            #expect(plan.kept.contains { $0.reason == .recordingsStay })
        }
        #expect(elsewhere.labels.contains("keychain:app.hushy.encryption"))
    }

    @Test("an export folder that is a link into the data folder keeps the data folder from going whole")
    func exportLinkedIntoDataFolder() throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let target = test.support.appendingPathComponent("Exports", isDirectory: true)
        let disk = FakeUninstallFileSystem([:])
        disk.realPaths = [test.export.path: target.path]

        let plan = try UninstallPlanner.plan(for: test.roots(), resolving: disk.canonical)

        #expect(!files(plan).contains(test.support.path))
        #expect(files(plan).contains(test.support.appendingPathComponent("murmur.sqlite").path))
        #expect(!plan.labels.contains("removeIfEmpty:\(test.support.path)"))
        for path in files(plan) {
            #expect(!(target.path == path || target.path.hasPrefix(path + "/")), "\(path) holds the linked export folder")
        }
    }

    @Test("an export folder that is a link to the whole data folder, or to a recordings folder, keeps it")
    func exportLinkedOntoDataFolder() throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let whole = FakeUninstallFileSystem([:])
        whole.realPaths = [test.export.path: test.support.path]
        let notes = FakeUninstallFileSystem([:])
        notes.realPaths = [test.export.path: test.support.appendingPathComponent("Notes").path]

        let keepsAll = try UninstallPlanner.plan(for: test.roots(), resolving: whole.canonical)
        let keepsNotes = try UninstallPlanner.plan(for: test.roots(), resolving: notes.canonical)

        #expect(!files(keepsAll).contains { $0 == test.support.path || $0.hasPrefix(test.support.path + "/") })
        #expect(keepsAll.kept.contains { $0.location == test.support.path && $0.reason == .insideExportFolder })
        #expect(!files(keepsNotes).contains(test.support.path))
        #expect(!files(keepsNotes).contains(test.support.appendingPathComponent("Notes").path))
        #expect(files(keepsNotes).contains(test.support.appendingPathComponent("Audio").path))
        #expect(keepsNotes.kept.contains { $0.reason == .recordingsStay })
    }

    @Test("an export folder written in another letter case is still the same folder", arguments: [
        "Library/Application Support/Hushy/EXPORTS",
        "library/application support/hushy/exports",
        "LIBRARY/APPLICATION SUPPORT/HUSHY",
        "Library/Application Support/hushy/notes",
        "Library/caches/APP.HUSHY.HUSHY",
    ])
    func exportInAnotherCase(relativeExport: String) throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let export = test.home.appendingPathComponent(relativeExport, isDirectory: true)
        let folded = UninstallPathPolicy.folded(export)

        let plan = try UninstallPlanner.plan(for: test.roots(export: export))

        for path in files(plan) {
            let target = UninstallPathPolicy.folded(URL(fileURLWithPath: path))
            #expect(target != folded, "\(path) is the export folder")
            #expect(!(folded.count > target.count && Array(folded.prefix(target.count)) == target), "\(path) holds the export folder")
            #expect(!(target.count > folded.count && Array(target.prefix(folded.count)) == folded), "\(path) is inside the export folder")
        }
    }

    @Test("an accented name written in either form is the same name")
    func foldsTheTwoFormsOfAnAccent() {
        let composed = URL(fileURLWithPath: "/Users/someone/Documents/Caf\u{00E9}")
        let decomposed = URL(fileURLWithPath: "/Users/someone/Documents/Cafe\u{0301}")

        #expect(UninstallPathPolicy.folded(composed) == UninstallPathPolicy.folded(decomposed))
        #expect(UninstallPathPolicy.relation(of: composed, toExport: decomposed, resolving: { $0 }) == .same)
    }

    @Test("the real disk names a path through its links, and in the letter case it is stored in")
    func canonicalOnTheRealDisk() throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let real = try test.write("Library/Application Support/Hushy/Exports/note.md").deletingLastPathComponent()
        try FileManager.default.createDirectory(at: test.export.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: test.export, withDestinationURL: real)
        let disk = LocalUninstallFileSystem()

        #expect(disk.canonical(test.export).path == disk.canonical(real).path)
        #expect(disk.canonical(test.export.appendingPathComponent("not/there")).path == disk.canonical(real).path + "/not/there")
        #expect(UninstallPathPolicy.relation(of: test.support, toExport: test.export, resolving: disk.canonical) == .holdsExport)
        #expect(UninstallPathPolicy.relation(of: test.support, toExport: test.export, resolving: { $0 }) == .apart)

        let plan = try UninstallPlanner.plan(for: test.roots(), resolving: disk.canonical)
        #expect(!files(plan).contains(test.support.path))

        // Only where the volume does not tell letter case apart: the stored spelling comes back.
        let shouted = URL(fileURLWithPath: real.path.replacingOccurrences(of: "Exports", with: "EXPORTS"))
        if FileManager.default.fileExists(atPath: shouted.path) {
            #expect(disk.canonical(shouted).path == disk.canonical(real).path)
        }
    }

    @Test("a home folder that is empty, the disk root or one level deep is refused", arguments: ["/", "/Users", ""])
    func refusesRootLikeHome(path: String) throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        var roots = test.roots()
        roots.home = URL(fileURLWithPath: path.isEmpty ? "/" : path)

        #expect(throws: UninstallRefusal.self) { try UninstallPlanner.plan(for: roots) }
    }

    @Test("a data folder that is the home folder, above it, or a system folder is refused")
    func refusesUnusableDataFolder() throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let candidates = [
            test.home, test.root, URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/tmp"), test.library,
            test.library.appendingPathComponent("Application Support", isDirectory: true),
            test.home.appendingPathComponent("Documents/..", isDirectory: true),
        ]
        for candidate in candidates {
            #expect(throws: UninstallRefusal.unusableDataFolder(candidate.path)) {
                try UninstallPlanner.plan(for: test.roots(support: candidate, overridden: true))
            }
        }
    }

    @Test("a bundle identifier that could be a path is refused", arguments: ["", "Hushy", "../..", "app.hushy/../x", "app..Hushy", "app.hushy.Hushy/"])
    func refusesBadBundleIdentifier(identifier: String) throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        var roots = test.roots()
        roots.bundleIdentifier = identifier

        #expect(throws: UninstallRefusal.invalidBundleIdentifier(identifier)) { try UninstallPlanner.plan(for: roots) }
    }

    @Test("a speech model name that is not one plain folder name is kept, and repeats are listed once")
    func speechModelNames() throws {
        let test = try UninstallTestHome()
        defer { test.remove() }

        let plan = try UninstallPlanner.plan(for: test.roots(speech: ["parakeet-one", "..", "nested/160ms", "parakeet-one", ""]))

        #expect(plan.speechModelSteps.map(\.action.label) == ["remove:" + test.speechModels.appendingPathComponent("parakeet-one").path])
        #expect(plan.kept.filter { $0.reason == .notAPlainFolderName }.count == 3)
        // The speech engine's own folders are never removed, only the models inside.
        #expect(!files(plan).contains(test.speechModels.path))
        #expect(!files(plan).contains(test.speechModels.deletingLastPathComponent().path))
    }

    @Test("the speech models are their own group, and stay when the person chooses to leave them")
    func speechModelsCanBeLeft() throws {
        let test = try UninstallTestHome()
        defer { test.remove() }

        let removing = try UninstallPlanner.plan(for: test.roots())
        let leaving = try UninstallPlanner.plan(for: test.roots(removesSpeechModels: false))

        #expect(removing.speechModelSteps.count == 2)
        #expect(removing.steps.filter { $0.group == .models }.isEmpty)
        #expect(leaving.speechModelSteps.isEmpty)
        #expect(!files(leaving).contains { $0.contains("/FluidAudio/") })
        #expect(leaving.kept.filter { $0.reason == .speechModelsLeftByChoice }.map(\.location) == [
            test.speechModels.path + "/parakeet-one", test.speechModels.path + "/parakeet-two",
        ])
        // Nothing else about the plan changes.
        #expect(leaving.labels == removing.labels.filter { !$0.contains("/FluidAudio/") })
    }

    @Test("the app is only moved to the Trash when it runs from an app bundle")
    func bundleOnlyWhenItIsAnApp() throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let isTrash: (UninstallStep) -> Bool = { if case .moveAppToTrash = $0.action { true } else { false } }

        let unbundled = try UninstallPlanner.plan(for: test.roots(bundle: .some(test.root.appendingPathComponent("debug"))))
        let missing = try UninstallPlanner.plan(for: test.roots(bundle: .some(nil)))

        #expect(!unbundled.steps.contains(where: isTrash))
        #expect(!missing.steps.contains(where: isTrash))
    }

    @Test("the removals and the settings are repeated before quitting, and nothing else")
    func stepsRepeatedAtQuit() throws {
        let test = try UninstallTestHome()
        defer { test.remove() }

        let plan = try UninstallPlanner.plan(for: test.roots())

        let repeated = plan.stepsRepeatedAtQuit.map(\.action.label)
        #expect(repeated == plan.labels.filter { $0.hasPrefix("remove:") || $0.hasPrefix("defaults:") })
        #expect(repeated.count == 11)
    }

    @Test("every step says where its thing is")
    func stepsHaveLocations() throws {
        let test = try UninstallTestHome()
        defer { test.remove() }

        let plan = try UninstallPlanner.plan(for: test.roots())

        #expect(plan.steps.allSatisfy { !$0.location.isEmpty && !$0.title.isEmpty })
        #expect(Set(plan.steps.map(\.id)).count == plan.steps.count)
    }
}

@Suite("UninstallConfirmation")
struct UninstallConfirmationTests {
    private func measured() -> UninstallConfirmation {
        var confirmation = UninstallConfirmation()
        confirmation.measured()
        return confirmation
    }

    @Test("pressing Uninstall before ticking the acknowledgement does nothing")
    func needsAcknowledgement() {
        var confirmation = measured()

        #expect(!confirmation.canUninstall)
        #expect(confirmation.handle(.uninstallButton) == .stay)
        #expect(confirmation.handle(.toggleAcknowledgement) == .stay)
        #expect(confirmation.canUninstall)
        #expect(confirmation.handle(.uninstallButton) == .uninstall)
    }

    @Test("the button stays off until the plan on screen has been measured, and goes off again when the plan changes")
    func needsTheMeasuredPlan() {
        var confirmation = UninstallConfirmation()
        _ = confirmation.handle(.toggleAcknowledgement)

        #expect(!confirmation.canUninstall)
        #expect(confirmation.handle(.uninstallButton) == .stay)
        confirmation.measured()
        #expect(confirmation.canUninstall)
        confirmation.planChanged()
        #expect(!confirmation.canUninstall)
        #expect(confirmation.handle(.uninstallButton) == .stay)
        confirmation.measured()
        #expect(confirmation.handle(.uninstallButton) == .uninstall)
    }

    @Test("notes an export could not save need their own acknowledgement, afresh for each export")
    func unsavedNotesNeedASecondAcknowledgement() {
        var confirmation = measured()
        _ = confirmation.handle(.toggleAcknowledgement)

        confirmation.exportFinished(unsaved: 3)
        #expect(confirmation.needsUnsavedAcknowledgement)
        #expect(confirmation.unsavedNotes == 3)
        #expect(confirmation.handle(.uninstallButton) == .stay)
        _ = confirmation.handle(.toggleUnsavedAcknowledgement)
        #expect(confirmation.canUninstall)

        confirmation.exportFinished(unsaved: 1)
        #expect(!confirmation.canUninstall)
        #expect(confirmation.handle(.uninstallButton) == .stay)

        confirmation.exportFinished(unsaved: 0)
        #expect(!confirmation.needsUnsavedAcknowledgement)
        #expect(confirmation.handle(.uninstallButton) == .uninstall)
    }

    @Test("the second acknowledgement cannot be ticked ahead of an export that fails")
    func unsavedAcknowledgementCannotBeBanked() {
        var confirmation = measured()
        _ = confirmation.handle(.toggleAcknowledgement)
        _ = confirmation.handle(.toggleUnsavedAcknowledgement)

        confirmation.exportFinished(unsaved: 2)

        #expect(!confirmation.acknowledgesUnsavedNotes)
        #expect(confirmation.handle(.uninstallButton) == .stay)
    }

    @Test("Return and Escape cancel in every state, and never uninstall")
    func defaultKeyNeverUninstalls() {
        for acknowledged in [false, true] {
            for key in [UninstallConfirmation.Input.defaultKey, .escapeKey, .cancelButton] {
                var confirmation = measured()
                if acknowledged { _ = confirmation.handle(.toggleAcknowledgement) }
                #expect(confirmation.handle(key) == .cancel)
            }
        }
    }

    @Test("no run of inputs without the Uninstall button ever uninstalls")
    func onlyTheButtonUninstalls() {
        let others = UninstallConfirmation.Input.allCases.filter { $0 != .uninstallButton }
        for first in others {
            for second in others {
                for third in others {
                    var confirmation = measured()
                    let decisions = [first, second, third].map { confirmation.handle($0) }
                    #expect(!decisions.contains(.uninstall))
                }
            }
        }
    }

    @Test("un-ticking the acknowledgement locks the button again")
    func untickLocks() {
        var confirmation = measured()
        _ = confirmation.handle(.toggleAcknowledgement)
        _ = confirmation.handle(.toggleAcknowledgement)

        #expect(confirmation.handle(.uninstallButton) == .stay)
    }
}
