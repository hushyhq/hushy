import Foundation
import Observation
import Testing
@testable import Murmur
@testable import MurmurCore

/// The flow behind "Uninstall Hushy…", on fakes: an invented home folder, a counter where the
/// executor would be, and no Trash, Keychain, preferences or quit anywhere near it.
@MainActor
@Suite("Uninstall flow", .timeLimit(.minutes(1)))
struct UninstallFlowTests {
    /// What the fake dependencies were asked to do, and what they answer. Observable, so a test
    /// can wait for a change instead of polling for it.
    @MainActor
    @Observable
    final class Calls {
        var runs = 0
        var settles = 0
        var quits = 0
        var exports = 0
        var closes = 0
        var ranPlans: [UninstallPlan] = []
        /// While true the measurement, or the run, does not return.
        var holdsMeasurement = false
        var holdsRun = false
        /// While true the measurement of a plan that removes the speech models does not return.
        var holdsSpeechModelMeasurement = false
        var exportFailures = 0
        /// True when the export finds the database unreadable.
        var exportIsUnreadable = false
        /// Stands in for `AppModel.isUninstalling`: set when the run stops the app, as
        /// `prepareForUninstall` sets it, and cleared by `endTestRun`.
        var isUninstalling = false
        var testRunEnds = 0
        var exportDirectory = URL(fileURLWithPath: "/Users/someone/Documents/Hushy", isDirectory: true)
        var isTestRun = false
        var activity: [UninstallActivity] = []
        var now = Date(timeIntervalSince1970: 1_000_000)
        var abandons: String?
        /// The hold each waiting task is waiting on.
        private var waiting: [UUID: @MainActor () -> Bool] = [:]
        /// How many of the flow's tasks a measurement or run is holding right now. A task whose
        /// hold has been lifted no longer counts, even before it has woken to notice.
        var held: Int { waiting.values.count { $0() } }

        /// Returns once the hold is off.
        func wait(while isOn: @escaping @MainActor () -> Bool) async {
            let id = UUID()
            waiting[id] = isOn
            while isOn() { try? await Task.sleep(for: .milliseconds(1)) }
            waiting[id] = nil
        }

        /// The fake removal, in one hop to the main actor (each hop can wait seconds behind other
        /// suites): records the run, waits while it is held, then answers.
        func run(_ plan: UninstallPlan, refusal: UninstallRefusal?) async -> UninstallReport {
            runs += 1
            ranPlans.append(plan)
            await wait { self.holdsRun }
            if let refusal { return UninstallReport(refusal: refusal, entries: []) }
            isUninstalling = true
            if let abandons { return UninstallReport(refusal: nil, abandoned: abandons, entries: []) }
            return UninstallReport(refusal: nil, entries: plan.steps.map { UninstallReport.Entry(step: $0, outcome: .done) })
        }
    }

    private func roots(_ calls: Calls, removesSpeechModels: Bool, resetsPermissions: Bool = true) -> UninstallRoots {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let standard = home.appendingPathComponent("Library/Application Support/Hushy", isDirectory: true)
        return UninstallRoots(
            home: home,
            supportDirectory: calls.isTestRun ? URL(fileURLWithPath: "/Users/someone/Scratch/trial", isDirectory: true) : standard,
            supportIsOverridden: calls.isTestRun, bundleIdentifier: "app.hushy.Hushy",
            bundleURL: URL(fileURLWithPath: "/Applications/Hushy.app", isDirectory: true),
            exportDirectory: calls.exportDirectory, speechModelFolderNames: ["speech-model"],
            removesSpeechModels: removesSpeechModels, resetsPermissions: resetsPermissions, isTestRun: calls.isTestRun)
    }

    /// Sizes that say which plan they were measured for.
    nonisolated private static func inventory(for plan: UninstallPlan) -> UninstallInventory {
        UninstallInventory(bytes: [.data: 1_000, .speechModels: plan.speechModelSteps.isEmpty ? 0 : 500])
    }

    private func makeFlow(
        preflight: UninstallRefusal? = nil, planError: UninstallRefusal? = nil, runRefusal: UninstallRefusal? = nil
    ) -> (UninstallFlow, Calls) {
        let calls = Calls()
        let flow = UninstallFlow(dependencies: UninstallFlow.Dependencies(
            plan: { removesSpeechModels, resetsPermissions in
                if let planError { throw planError }
                return try UninstallPlanner.plan(
                    for: self.roots(calls, removesSpeechModels: removesSpeechModels, resetsPermissions: resetsPermissions))
            },
            preflight: { _ in preflight },
            counts: { UninstallFlow.Counts(dictations: 12, notes: 3) },
            activity: { calls.activity },
            measure: { plan in
                await calls.wait {
                    calls.holdsMeasurement || (calls.holdsSpeechModelMeasurement && !plan.speechModelSteps.isEmpty)
                }
                return Self.inventory(for: plan)
            },
            exportNotes: {
                calls.exports += 1
                if calls.exportIsUnreadable {
                    return UninstallFlow.ExportResult(
                        exported: 0, failed: 3, folder: calls.exportDirectory, notesUnreadable: true)
                }
                return UninstallFlow.ExportResult(
                    exported: 3 - calls.exportFailures, failed: calls.exportFailures, folder: calls.exportDirectory)
            },
            run: { plan in await calls.run(plan, refusal: runRefusal) },
            settle: { _, _ in await MainActor.run { calls.settles += 1 } },
            endTestRun: {
                calls.testRunEnds += 1
                calls.isUninstalling = false
            },
            quit: { calls.quits += 1 },
            now: { calls.now }))
        flow.onClose = { calls.closes += 1 }
        return (flow, calls)
    }

    /// Lets every task the flow has started run as far as it can, for checking that nothing
    /// happened: each one has ended, or is held by a fake (a held measurement or run).
    private func drain(_ flow: UninstallFlow, _ calls: Calls) async {
        await wait { flow.tasksInFlight == calls.held }
    }

    /// Waits for something the flow's own tasks (measuring, running, settling) will make true.
    /// It wakes when the flow or the fakes change, never on a clock: other suites can keep the
    /// main actor busy for seconds at a time (headless clicks spin the run loop on it), and
    /// waiting costs a few turns of the main actor however long each turn takes.
    private func wait(until done: @escaping @MainActor () -> Bool) async {
        while !done() {
            await withCheckedContinuation { (changed: CheckedContinuation<Void, Never>) in
                withObservationTracking { _ = done() } onChange: { changed.resume() }
            }
        }
    }

    /// Opens the sheet and waits for the plan on screen to be measured.
    private func openMeasured(_ flow: UninstallFlow) async {
        flow.open()
        await wait { flow.confirmation.isMeasured }
    }

    /// Ticks the box, presses Uninstall and waits for the removal to end.
    private func uninstall(_ flow: UninstallFlow) async {
        await openMeasured(flow)
        flow.handle(.toggleAcknowledgement)
        flow.handle(.uninstallButton)
        await wait { flow.phase != .working && flow.phase != .review }
    }

    @Test("opening builds the plan, counts and sizes, and removes nothing")
    func openOnlyLooks() async throws {
        let (flow, calls) = makeFlow()

        flow.open()
        #expect(!flow.confirmation.isMeasured)
        await wait { flow.inventory != nil }

        let plan = try #require(flow.plan)
        #expect(flow.phase == .review)
        #expect(!plan.steps.isEmpty)
        #expect(flow.counts == UninstallFlow.Counts(dictations: 12, notes: 3))
        #expect(flow.inventory == Self.inventory(for: plan))
        #expect(flow.confirmation.isMeasured)
        #expect(calls.runs == 0)
        #expect(calls.quits == 0)
    }

    @Test("Return closes the sheet and never uninstalls, even with the box ticked")
    func defaultKeyCancels() async {
        for acknowledged in [false, true] {
            let (flow, calls) = makeFlow()
            await openMeasured(flow)
            if acknowledged { flow.handle(.toggleAcknowledgement) }

            flow.handle(.defaultKey)
            await drain(flow, calls)

            #expect(calls.closes == 1)
            #expect(calls.runs == 0)
            #expect(flow.phase == .review)
        }
    }

    @Test("Escape and Cancel close the sheet without uninstalling")
    func escapeAndCancelClose() async {
        for input in [UninstallConfirmation.Input.escapeKey, .cancelButton] {
            let (flow, calls) = makeFlow()
            await openMeasured(flow)
            flow.handle(.toggleAcknowledgement)

            flow.handle(input)
            await drain(flow, calls)

            #expect(calls.closes == 1)
            #expect(calls.runs == 0)
        }
    }

    @Test("the Uninstall button does nothing until the box is ticked")
    func buttonNeedsTheTick() async {
        let (flow, calls) = makeFlow()
        await openMeasured(flow)

        flow.handle(.uninstallButton)
        await drain(flow, calls)

        #expect(calls.runs == 0)
        #expect(flow.phase == .review)
    }

    @Test("the Uninstall button does nothing until the plan on screen has been measured")
    func buttonNeedsTheMeasurement() async {
        let (flow, calls) = makeFlow()
        calls.holdsMeasurement = true
        flow.open()
        flow.handle(.toggleAcknowledgement)

        flow.handle(.uninstallButton)
        await drain(flow, calls)
        #expect(!flow.confirmation.canUninstall)
        #expect(calls.runs == 0)
        #expect(flow.phase == .review)

        calls.holdsMeasurement = false
        await wait { flow.confirmation.isMeasured }
        flow.handle(.uninstallButton)
        await wait { calls.runs > 0 }
        #expect(calls.runs == 1)
    }

    @Test("ticking the box and pressing Uninstall runs the plan on screen once and shows the report")
    func confirmedUninstallRuns() async {
        let (flow, calls) = makeFlow()
        await openMeasured(flow)
        let shown = flow.plan
        flow.handle(.toggleAcknowledgement)

        flow.handle(.uninstallButton)
        #expect(flow.phase == .working)
        // Nothing pressed while it works starts it again, cancels it or closes the sheet.
        flow.handle(.uninstallButton)
        flow.handle(.defaultKey)
        flow.handle(.escapeKey)
        await wait { flow.phase != .working }

        guard case .finished(let report) = flow.phase else {
            Issue.record("expected a report, got \(flow.phase)")
            return
        }
        #expect(report.removedEverything)
        #expect(calls.runs == 1)
        #expect(calls.ranPlans == [shown].compactMap { $0 })
        #expect(calls.closes == 0)
        #expect(calls.quits == 0)
    }

    @Test("unticking the speech models shows a plan without them, unmeasured, and that plan is the one that runs")
    func speechModelsCanBeLeft() async throws {
        let (flow, calls) = makeFlow()
        await openMeasured(flow)
        #expect(flow.plan?.speechModelSteps.count == 1)
        #expect(flow.removesSpeechModels)
        flow.handle(.toggleAcknowledgement)

        calls.holdsMeasurement = true
        flow.setRemovesSpeechModels(false)
        let shown = try #require(flow.plan)
        #expect(shown.speechModelSteps.isEmpty)
        #expect(shown.kept.contains { $0.reason == .speechModelsLeftByChoice })
        #expect(flow.inventory == nil)
        #expect(!flow.confirmation.canUninstall)
        flow.handle(.uninstallButton)
        await drain(flow, calls)
        #expect(calls.runs == 0)

        calls.holdsMeasurement = false
        await wait { flow.confirmation.isMeasured }
        #expect(flow.inventory == Self.inventory(for: shown))
        flow.handle(.uninstallButton)
        await wait { flow.phase != .working && flow.phase != .review }
        #expect(calls.ranPlans == [shown])
    }

    @Test("the permissions reset is ticked to begin with; unticking shows a plan without it that is the one that runs")
    func permissionsCanBeLeft() async throws {
        let (flow, calls) = makeFlow()
        await openMeasured(flow)
        #expect(flow.resetsPermissions)
        #expect(flow.plan?.steps.last?.action == .resetPermissions(bundleIdentifier: UninstallPlan.permissionsBundleIdentifier))
        flow.handle(.toggleAcknowledgement)

        calls.holdsMeasurement = true
        flow.setResetsPermissions(false)
        let shown = try #require(flow.plan)
        #expect(!flow.resetsPermissions)
        #expect(!shown.steps.contains { if case .resetPermissions = $0.action { true } else { false } })
        #expect(shown.kept.contains { $0.reason == .permissionsLeftByChoice })
        #expect(!flow.confirmation.canUninstall)

        calls.holdsMeasurement = false
        await wait { flow.confirmation.isMeasured }
        flow.handle(.uninstallButton)
        await wait { flow.phase != .working && flow.phase != .review }
        #expect(calls.ranPlans == [shown])
    }

    @Test("sizes that arrive for a plan no longer on screen are dropped")
    func staleSizesAreDropped() async throws {
        let (flow, calls) = makeFlow()
        calls.holdsSpeechModelMeasurement = true
        flow.open()
        flow.setRemovesSpeechModels(false)
        let shown = try #require(flow.plan)

        // The plan on screen is measured first; the sizes of the one it replaced arrive after.
        await wait { flow.confirmation.isMeasured }
        calls.holdsSpeechModelMeasurement = false
        await drain(flow, calls)

        #expect(flow.inventory == Self.inventory(for: shown))
        #expect(flow.inventory?.bytes(in: .speechModels) == 0)
    }

    @Test("notes an export could not save need a second tick, naming how many, before the button works")
    func unsavedNotesNeedASecondTick() async {
        let (flow, calls) = makeFlow()
        calls.exportFailures = 2
        await openMeasured(flow)
        flow.handle(.toggleAcknowledgement)

        flow.exportNotes()
        #expect(flow.confirmation.unsavedNotes == 2)
        #expect(flow.confirmation.needsUnsavedAcknowledgement)
        flow.handle(.uninstallButton)
        await drain(flow, calls)
        #expect(calls.runs == 0)
        #expect(flow.phase == .review)

        flow.handle(.toggleUnsavedAcknowledgement)
        flow.handle(.uninstallButton)
        await wait { calls.runs > 0 }
        #expect(calls.runs == 1)
    }

    @Test("notes that could not be read are a failed export: the second tick is needed, and the line says so")
    func unreadableNotesNeedTheSecondTick() async {
        let (flow, calls) = makeFlow()
        calls.exportIsUnreadable = true
        await openMeasured(flow)
        flow.handle(.toggleAcknowledgement)

        flow.exportNotes()

        #expect(flow.export?.notesUnreadable == true)
        #expect(flow.export?.sentence == "Hushy could not read your notes, so none of them were exported.")
        #expect(flow.confirmation.needsUnsavedAcknowledgement)
        flow.handle(.uninstallButton)
        await drain(flow, calls)
        #expect(calls.runs == 0)

        flow.handle(.toggleUnsavedAcknowledgement)
        flow.handle(.uninstallButton)
        await wait { calls.runs > 0 }
        #expect(calls.runs == 1)
    }

    @Test("a database that cannot be read exports nothing and counts every known note, and at least one, as not saved")
    func aStoreThatThrowsIsAFailedExport() throws {
        let store = try Store()
        _ = try store.save(Note(title: "Planning", status: .ready))
        // A closed database answers every later read with an error.
        try store.writer.close()
        #expect(throws: (any Error).self) { try store.notes(limit: .max) }
        let folder = URL(fileURLWithPath: "/Users/someone/Documents/Hushy", isDirectory: true)
        var saved = 0

        for (known, failed) in [(12, 12), (0, 1)] {
            let result = UninstallFlow.Dependencies.exportNotes(
                read: { try store.notes(limit: .max) }, known: known, folder: folder,
                save: { _ in
                    saved += 1
                    return true
                })

            #expect(result == UninstallFlow.ExportResult(exported: 0, failed: failed, folder: folder, notesUnreadable: true))
        }
        #expect(saved == 0)
    }

    @Test("a database that can be read exports every note in it and counts the ones the exporter could not save")
    func aReadableStoreExportsEveryNote() throws {
        let store = try Store()
        for title in ["One", "Two", "Three"] { _ = try store.save(Note(title: title, status: .ready)) }
        let folder = URL(fileURLWithPath: "/Users/someone/Documents/Hushy", isDirectory: true)

        let result = UninstallFlow.Dependencies.exportNotes(
            read: { try store.notes(limit: .max) }, known: 0, folder: folder, save: { $0.title != "Two" })

        #expect(result == UninstallFlow.ExportResult(exported: 2, failed: 1, folder: folder))
        #expect(result.sentence == "Saved 2 notes to /Users/someone/Documents/Hushy. 1 could not be saved.")
    }

    @Test("an export that then saves every note takes the second tick away again")
    func aCleanExportClearsTheSecondTick() async {
        let (flow, calls) = makeFlow()
        calls.exportFailures = 1
        await openMeasured(flow)
        flow.exportNotes()
        #expect(flow.confirmation.needsUnsavedAcknowledgement)

        calls.exportFailures = 0
        flow.exportNotes()

        #expect(!flow.confirmation.needsUnsavedAcknowledgement)
        #expect(flow.export?.failed == 0)
    }

    @Test("if the plan changed while the sheet was open, the new plan is shown and nothing runs unseen")
    func aChangedPlanIsShownNotRun() async throws {
        let (flow, calls) = makeFlow()
        await openMeasured(flow)
        flow.handle(.toggleAcknowledgement)
        let moved = URL(fileURLWithPath: "/Users/someone/Desktop/Notes", isDirectory: true)

        calls.exportDirectory = moved
        calls.holdsMeasurement = true
        flow.handle(.uninstallButton)
        await drain(flow, calls)

        #expect(calls.runs == 0)
        #expect(flow.phase == .review)
        #expect(flow.plan?.roots.exportDirectory == moved)
        #expect(!flow.confirmation.canUninstall)

        calls.holdsMeasurement = false
        await wait { flow.confirmation.isMeasured }
        flow.handle(.uninstallButton)
        await wait { calls.runs > 0 }
        #expect(calls.ranPlans.map(\.roots.exportDirectory) == [moved])
    }

    @Test("when the app would not stop, the sheet says what did not stop and nothing quits")
    func abandonedSaysWhy() async {
        let (flow, calls) = makeFlow()
        let reason = UninstallStopFailure(notStopped: "the file import").localizedDescription
        calls.abandons = reason

        await uninstall(flow)

        #expect(flow.phase == .abandoned(reason))
        #expect(reason.contains("the file import"))
        #expect(!flow.handleAppQuit())
        flow.quit()
        await drain(flow, calls)
        #expect(calls.settles == 0)
        #expect(calls.quits == 0)
        flow.handle(.uninstallButton)
        #expect(calls.runs == 1)
        flow.handle(.defaultKey)
        #expect(calls.closes == 1)
    }

    @Test("the not-stopped sheet says nothing was removed and that some work stays stopped, not that Hushy runs as before")
    func abandonedWordingIsTrue() {
        let reason = UninstallStopFailure(notStopped: "the file import").localizedDescription

        let detail = UninstallSheetContent.abandonedDetail(reason)

        #expect(detail == "Hushy could not stop the file import in time. Nothing was removed. "
            + "Hushy stopped some background work to prepare; quit and reopen it to carry on as before.")
        #expect(!detail.contains("running as before"))
    }

    @Test("the report says when the sign-out reached this Mac only, and a test run's ending does not call Hushy stopped")
    func reportWording() throws {
        let plan = try UninstallPlanner.plan(for: UninstallSnapshotFixtures.roots())
        let testRun = try UninstallPlanner.plan(for: UninstallSnapshotFixtures.testRunRoots())
        let note = "Hushy's server could not be reached, so you were signed out on this Mac only."
        func detail(_ report: UninstallReport, _ plan: UninstallPlan) -> String {
            UninstallFinished(report: report, plan: plan, quit: {}).detail
        }

        let hereOnly = UninstallSnapshotFixtures.report(plan, leftovers: false, signOut: .signedOutOnThisMacOnly)
        #expect(hereOnly.removedEverything)
        #expect(detail(hereOnly, plan).contains(note))
        #expect(detail(UninstallSnapshotFixtures.report(plan, leftovers: true, signOut: .signedOutOnThisMacOnly), plan).contains(note))
        #expect(!detail(UninstallSnapshotFixtures.report(plan, leftovers: false), plan).contains("signed out"))
        let ended = detail(UninstallSnapshotFixtures.report(testRun, leftovers: false), testRun)
        #expect(ended.contains("Hushy is still open, without this run's files"))
        #expect(!ended.contains("stopped"))
    }

    @Test("Quit settles first, then quits, and only after a finished uninstall")
    func quitAfterTheReport() async {
        let (flow, calls) = makeFlow()
        await openMeasured(flow)

        flow.quit()
        await drain(flow, calls)
        #expect(calls.settles == 0)
        #expect(calls.quits == 0)

        flow.handle(.toggleAcknowledgement)
        flow.handle(.uninstallButton)
        await wait { flow.phase != .working }
        flow.quit()
        flow.quit()
        await wait { calls.quits > 0 }

        #expect(calls.settles == 1)
        #expect(calls.quits == 1)
    }

    @Test("a test run says so in its plan, and neither settles nor quits when it ends")
    func aTestRunNeverQuits() async throws {
        let (flow, calls) = makeFlow()
        calls.isTestRun = true

        await uninstall(flow)

        let plan = try #require(flow.plan)
        #expect(plan.isTestRun)
        guard case .finished = flow.phase else {
            Issue.record("expected a report, got \(flow.phase)")
            return
        }
        #expect(!flow.handleAppQuit())
        flow.quit()
        await drain(flow, calls)
        #expect(calls.settles == 0)
        #expect(calls.quits == 0)
        #expect(calls.closes == 1)
    }

    @Test("a test run that has ended is no longer uninstalling: the app it stopped is opened again, once")
    func aTestRunEndsTheUninstall() async {
        let (flow, calls) = makeFlow()
        calls.isTestRun = true

        await uninstall(flow)

        #expect(calls.runs == 1)
        #expect(!calls.isUninstalling)
        #expect(calls.testRunEnds == 1)
        flow.quit()
        await drain(flow, calls)
        #expect(calls.testRunEnds == 1)
        #expect(calls.closes == 1)
    }

    @Test("an ordinary uninstall stays stopped until it quits, and one that was refused has nothing to open again")
    func onlyATestRunIsOpenedAgain() async {
        let (flow, calls) = makeFlow()
        await uninstall(flow)
        #expect(calls.isUninstalling)
        #expect(calls.testRunEnds == 0)

        let (refused, refusedCalls) = makeFlow(runRefusal: .notAHushyDataFolder("/Users/someone/Scratch/trial"))
        refusedCalls.isTestRun = true
        await uninstall(refused)
        #expect(refusedCalls.testRunEnds == 0)
    }

    @Test("⌘Q before the uninstall starts is an ordinary quit")
    func quitKeyBeforeStarting() async {
        let (flow, calls) = makeFlow()
        #expect(!flow.handleAppQuit())
        await openMeasured(flow)
        flow.handle(.toggleAcknowledgement)

        #expect(!flow.handleAppQuit())
        await drain(flow, calls)
        #expect(calls.quits == 0)
    }

    @Test("⌘Q while the removal runs waits for it, then settles and quits")
    func quitKeyWhileWorking() async {
        let (flow, calls) = makeFlow()
        calls.holdsRun = true
        await openMeasured(flow)
        flow.handle(.toggleAcknowledgement)
        flow.handle(.uninstallButton)
        await wait { calls.runs > 0 }

        #expect(flow.handleAppQuit())
        await drain(flow, calls)
        #expect(calls.quits == 0)

        calls.holdsRun = false
        await wait { calls.quits > 0 }
        #expect(calls.settles == 1)
        #expect(calls.quits == 1)
    }

    @Test("⌘Q after the report settles and quits, like the sheet's own button")
    func quitKeyAfterTheReport() async {
        let (flow, calls) = makeFlow()
        await uninstall(flow)

        #expect(flow.handleAppQuit())
        await wait { calls.quits > 0 }

        #expect(calls.settles == 1)
        #expect(calls.quits == 1)
    }

    @Test("a removal that has run too long hands ⌘Q back as an ordinary quit")
    func quitKeyIsNeverLeftDead() async {
        let (flow, calls) = makeFlow()
        calls.holdsRun = true
        await openMeasured(flow)
        flow.handle(.toggleAcknowledgement)
        flow.handle(.uninstallButton)
        await wait { calls.runs > 0 }

        calls.now += UninstallFlow.quitPatience - 1
        #expect(flow.handleAppQuit())
        calls.now += 2
        #expect(!flow.handleAppQuit())

        calls.holdsRun = false
        await wait { flow.phase != .working }
    }

    @Test("a last pass before quitting that has run too long hands ⌘Q back too")
    func quitKeyDuringASlowLastPass() async {
        let (flow, calls) = makeFlow()
        await uninstall(flow)
        flow.quit()

        calls.now += UninstallFlow.quitPatience + 1

        #expect(!flow.handleAppQuit())
        await wait { calls.quits > 0 }
    }

    @Test("a refused data folder shows why, and no button can start the removal")
    func refusedBeforeAnything() async {
        let refusal = UninstallRefusal.notAHushyDataFolder("/Users/someone/Projects")
        let (flow, calls) = makeFlow(preflight: refusal)

        flow.open()
        flow.handle(.toggleAcknowledgement)
        flow.handle(.uninstallButton)
        flow.setRemovesSpeechModels(false)
        await drain(flow, calls)

        #expect(flow.phase == .refused(refusal))
        #expect(calls.runs == 0)
        #expect(calls.closes == 0)
        #expect(!flow.handleAppQuit())
        flow.handle(.defaultKey)
        #expect(calls.closes == 1)
    }

    @Test("a plan that cannot be built, or a run that refuses, ends in the refused state")
    func refusalsFromThePlanAndTheRun() async {
        let (unbuilt, _) = makeFlow(planError: .unusableHome("/"))
        unbuilt.open()
        #expect(unbuilt.phase == .refused(.unusableHome("/")))

        let refusal = UninstallRefusal.notAHushyDataFolder("/Users/someone/Projects")
        let (flow, calls) = makeFlow(runRefusal: refusal)
        await uninstall(flow)

        #expect(flow.phase == .refused(refusal))
        flow.quit()
        await drain(flow, calls)
        #expect(calls.quits == 0)
    }

    @Test("exporting notes uses the app's exporter and says where they went")
    func exportIsOffered() async {
        let (flow, calls) = makeFlow()
        await openMeasured(flow)

        flow.exportNotes()

        #expect(calls.exports == 1)
        #expect(flow.export == UninstallFlow.ExportResult(exported: 3, failed: 0, folder: calls.exportDirectory))
        #expect(!flow.confirmation.needsUnsavedAcknowledgement)
        #expect(flow.phase == .review)
    }

    @Test("work in progress is read when the review asks, and each kind says what happens to it")
    func activityIsShown() {
        let (flow, calls) = makeFlow()
        flow.open()
        #expect(flow.activity.isEmpty)

        calls.activity = [.recording, .savingNote, .importing]

        #expect(flow.activity == [.recording, .savingNote, .importing])
        #expect(UninstallActivity.recording.sentence.contains("discarded, not saved"))
        #expect(UninstallActivity.savingNote.sentence.contains("waits for it to finish"))
        #expect(UninstallActivity.importing.sentence.contains("stopped"))
    }

    @Test("the snapshot fixtures plan an invented Mac, keep its export folder, and cover every state")
    func snapshotFixtures() throws {
        let plan = try UninstallPlanner.plan(for: UninstallSnapshotFixtures.roots())
        let testRun = try UninstallPlanner.plan(for: UninstallSnapshotFixtures.testRunRoots())

        #expect(plan.steps.allSatisfy { $0.fileURL.map { $0.path.hasPrefix("/Users/you/Library/") } ?? true })
        #expect(plan.kept.first?.location == "/Users/you/Documents/Hushy")
        #expect(UninstallSnapshotFixtures.report(plan, leftovers: true).leftovers.count == 2)
        #expect(UninstallSnapshotFixtures.report(plan, leftovers: false).removedEverything)
        #expect(testRun.isTestRun)
        #expect(testRun.steps.allSatisfy { $0.fileURL.map { $0.path.hasPrefix("/Users/you/Scratch/hushy-trial/") } ?? true })
        let keptKey = UninstallSnapshotFixtures.reportKeepingKey(plan).leftovers
        #expect(keptKey.contains { $0.outcome == .keptWithRecordings })
        #expect(keptKey.contains { $0.step.removesData })

        let names = UninstallSnapshotFixtures.states().map { $0.0 }
        #expect(Set(names).count == names.count)
        for name in [
            "measuring", "speech-models-kept", "export-failed", "notes-unreadable", "recording-in-progress",
            "test-run", "test-run-done", "signed-out-here-only", "key-kept", "not-stopped",
        ] {
            #expect(names.contains(name))
        }
        let measuring = try #require(UninstallSnapshotFixtures.states().first { $0.0 == "measuring" }?.1)
        #expect(measuring.confirmation.isAcknowledged)
        #expect(!measuring.confirmation.canUninstall)
        let exportFailed = try #require(UninstallSnapshotFixtures.states().first { $0.0 == "export-failed" }?.1)
        #expect(exportFailed.confirmation.unsavedNotes == 3)
        #expect(!exportFailed.confirmation.canUninstall)
    }
}
