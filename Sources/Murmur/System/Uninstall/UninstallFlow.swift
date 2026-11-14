import Foundation
import MurmurCore
import Observation

/// "Uninstall Hushy…" from the moment the sheet opens: shows the plan, offers the note export,
/// takes the confirmation, runs the plan and reports what could not be removed. Everything it
/// touches comes through `Dependencies`, so tests and snapshots run it on fakes.
@MainActor
@Observable
final class UninstallFlow: Identifiable {
    enum Phase: Equatable {
        case review
        case working
        case finished(UninstallReport)
        /// Nothing was removed, and nothing will be.
        case refused(UninstallRefusal)
        /// The app would not stop, so nothing was removed. The sentence says what could not be
        /// stopped; what had already stopped by then is not put back.
        case abandoned(String)
    }

    struct Counts: Equatable {
        var dictations = 0
        var notes = 0
        /// The notes could not be read from the database: `notes` is only what was on screen.
        var notesUnreadable = false
    }

    struct ExportResult: Equatable {
        let exported: Int
        let failed: Int
        let folder: URL
        /// The notes could not be read from the database, so none was exported. `failed` is
        /// then every note Hushy knew of, and never zero.
        var notesUnreadable = false
    }

    struct Dependencies {
        var plan: @MainActor (_ removesSpeechModels: Bool, _ resetsPermissions: Bool) throws -> UninstallPlan
        var preflight: @MainActor (UninstallPlan) -> UninstallRefusal?
        var counts: @MainActor () -> Counts
        var activity: @MainActor () -> [UninstallActivity]
        var measure: @Sendable (UninstallPlan) async -> UninstallInventory
        var exportNotes: @MainActor () -> ExportResult
        var run: @Sendable (UninstallPlan) async -> UninstallReport
        var settle: @Sendable (UninstallPlan, UninstallReport) async -> Void
        /// A test run has ended and the app stays open: opens again what `run` closed to stop it.
        var endTestRun: @MainActor () -> Void
        var quit: @MainActor () -> Void
        var now: @MainActor () -> Date
    }

    /// How long a running removal, or the last pass before quitting, may keep ⌘Q waiting.
    static let quitPatience: TimeInterval = 20

    private(set) var phase: Phase = .review
    /// The plan on screen. It is the plan that runs: see `confirm`.
    private(set) var plan: UninstallPlan?
    /// Nil until the sizes of the plan on screen have been added up.
    private(set) var inventory: UninstallInventory?
    private(set) var counts = Counts()
    private(set) var export: ExportResult?
    private(set) var confirmation = UninstallConfirmation()
    /// The tick box on the speech models' line. Off leaves them where they are.
    private(set) var removesSpeechModels = true
    /// The tick box on the permissions line. Off leaves macOS's list of permissions for Hushy.
    private(set) var resetsPermissions = true
    /// How many of the flow's own tasks (measuring, the removal, the last pass before quitting)
    /// have started and not yet ended. Tests wait on it rather than guessing how long work takes.
    private(set) var tasksInFlight = 0
    /// Closes the sheet. Cancel, Return and Escape all end here.
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private var isQuitting = false
    /// ⌘Q arrived while the removal was running: quit as soon as it has finished.
    @ObservationIgnored private var quitsWhenFinished = false
    /// When the removal, or the last pass before quitting, started; nil when neither is running.
    @ObservationIgnored private var busySince: Date?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// What is going on in the app right now that the uninstall would cut short.
    var activity: [UninstallActivity] { dependencies.activity() }

    /// Builds the plan and starts adding up sizes. Removes nothing. Only the first call does anything.
    func open() {
        guard plan == nil, phase == .review else { return }
        rebuildPlan()
        if phase == .review { counts = dependencies.counts() }
    }

    /// The tick box on the speech models' line: a different plan goes on screen, unmeasured.
    func setRemovesSpeechModels(_ removes: Bool) {
        guard phase == .review, plan != nil, removes != removesSpeechModels else { return }
        removesSpeechModels = removes
        rebuildPlan()
    }

    /// The tick box on the permissions line: a different plan goes on screen, unmeasured.
    func setResetsPermissions(_ resets: Bool) {
        guard phase == .review, plan != nil, resets != resetsPermissions else { return }
        resetsPermissions = resets
        rebuildPlan()
    }

    /// Every key and button of the review goes through `UninstallConfirmation`, where Return
    /// cancels. Once the removal has started nothing here can stop or restart it.
    func handle(_ input: UninstallConfirmation.Input) {
        switch phase {
        case .working, .finished: return
        case .refused, .abandoned:
            switch input {
            case .cancelButton, .defaultKey, .escapeKey: onClose?()
            case .toggleAcknowledgement, .toggleUnsavedAcknowledgement, .uninstallButton: break
            }
        case .review:
            guard let plan else { return }
            switch confirmation.handle(input) {
            case .stay: break
            case .cancel: onClose?()
            case .uninstall: confirm(plan)
            }
        }
    }

    /// Saves every note into the export folder with the exporter the Notes screen uses. Notes
    /// that could not be saved have to be acknowledged, by number, before the uninstall.
    func exportNotes() {
        guard phase == .review else { return }
        let result = dependencies.exportNotes()
        export = result
        confirmation.exportFinished(unsaved: result.failed)
    }

    /// After the report: removes anything the still-open app wrote back, then quits. Does
    /// nothing before the removal has finished. A test run neither settles nor quits: its
    /// button closes the sheet.
    func quit() {
        guard case .finished(let report) = phase, let plan, !isQuitting else { return }
        guard !plan.isTestRun else {
            onClose?()
            return
        }
        isQuitting = true
        busySince = dependencies.now()
        let settle = dependencies.settle
        let quit = dependencies.quit
        perform {
            await settle(plan, report)
            quit()
        }
    }

    /// ⌘Q once an uninstall has started. True when the uninstall does the quitting: after the
    /// report it makes its last pass and quits, and while the removal is running it quits as
    /// soon as that ends. False hands the quit back to the app as an ordinary one: nothing was
    /// removed, it is a test run, or the uninstall has been busy for longer than
    /// `quitPatience`. A removal that hangs can therefore never leave ⌘Q dead.
    func handleAppQuit() -> Bool {
        guard plan?.isTestRun == false else { return false }
        if let busySince, dependencies.now().timeIntervalSince(busySince) > Self.quitPatience { return false }
        switch phase {
        case .review, .refused, .abandoned:
            return false
        case .working:
            quitsWhenFinished = true
            return true
        case .finished:
            quit()
            return true
        }
    }

    /// Builds the plan for the choices on screen and shows it, or the reason there is none.
    private func rebuildPlan() {
        do {
            let plan = try dependencies.plan(removesSpeechModels, resetsPermissions)
            if let refusal = dependencies.preflight(plan) {
                self.plan = plan
                phase = .refused(refusal)
                return
            }
            show(plan)
        } catch {
            phase = .refused((error as? UninstallRefusal) ?? .unusableHome(""))
        }
    }

    /// Puts a plan on screen. The Uninstall button stays off until this very plan has been
    /// measured; sizes that arrive for a plan no longer on screen are dropped.
    private func show(_ plan: UninstallPlan) {
        self.plan = plan
        inventory = nil
        confirmation.planChanged()
        let measure = dependencies.measure
        perform {
            let measured = await measure(plan)
            guard self.plan == plan, self.phase == .review else { return }
            self.inventory = measured
            self.confirmation.measured()
        }
    }

    /// The plan is built once more at the moment of confirming. If what it is built from
    /// changed while the sheet was open (the export folder, say), the new plan goes on screen,
    /// unmeasured, and nothing runs: a plan the person has not seen is never the one that runs.
    private func confirm(_ shown: UninstallPlan) {
        guard let current = try? dependencies.plan(removesSpeechModels, resetsPermissions), current == shown else {
            rebuildPlan()
            return
        }
        start(shown)
    }

    private func start(_ plan: UninstallPlan) {
        phase = .working
        busySince = dependencies.now()
        let run = dependencies.run
        perform { self.finish(with: await run(plan)) }
    }

    /// Every task the flow starts goes through here, so `tasksInFlight` counts it.
    private func perform(_ work: @escaping @MainActor () async -> Void) {
        tasksInFlight += 1
        Task {
            await work()
            self.tasksInFlight -= 1
        }
    }

    private func finish(with report: UninstallReport) {
        busySince = nil
        if let refusal = report.refusal {
            phase = .refused(refusal)
        } else if let reason = report.abandoned {
            phase = .abandoned(reason)
        } else {
            phase = .finished(report)
            // A test run does not quit, so the app it stopped must not be left closed for good.
            if plan?.isTestRun == true { dependencies.endTestRun() }
            if quitsWhenFinished { quit() }
        }
        quitsWhenFinished = false
    }
}

extension UninstallFlow.Dependencies {
    /// The running app.
    @MainActor
    static func live(model: AppModel) -> UninstallFlow.Dependencies {
        let executor = LiveUninstall.executor(model: model)
        return UninstallFlow.Dependencies(
            plan: { try LiveUninstall.plan(model: model, removesSpeechModels: $0, resetsPermissions: $1) },
            preflight: { executor.preflight($0) },
            counts: {
                let stored = try? model.store.notes(limit: .max)
                return UninstallFlow.Counts(
                    dictations: model.library.insights.totalDictations,
                    notes: stored?.count ?? model.library.notes.count, notesUnreadable: stored == nil)
            },
            activity: { model.uninstallActivity },
            measure: { plan in
                await Task.detached(priority: .utility) {
                    UninstallInventory.measure(plan, fileSystem: LocalUninstallFileSystem())
                }.value
            },
            exportNotes: {
                exportNotes(
                    read: { try model.store.notes(limit: .max) }, known: model.library.notes.count,
                    folder: model.settings.exportDirectory, save: { model.exportNote($0) != nil })
            },
            run: { await executor.run($0) },
            settle: { plan, report in _ = await executor.settle(plan, after: report) },
            endTestRun: { model.resumeAfterTestRunUninstall() },
            // `exit` rather than a normal quit: quitting saves window positions and settings,
            // which would put back two of the files that were just removed.
            quit: { exit(0) },
            now: { Date() })
    }

    /// Saves every note in the database, not only the ones the Notes screen has loaded. When
    /// the database cannot be read nothing is saved, and the result says so: every note Hushy
    /// knew of (`known`), and at least one, counts as not saved, so the person has to
    /// acknowledge it before the notes are removed.
    @MainActor
    static func exportNotes(
        read: () throws -> [Note], known: Int, folder: URL, save: (Note) -> Bool
    ) -> UninstallFlow.ExportResult {
        guard let notes = try? read() else {
            return UninstallFlow.ExportResult(exported: 0, failed: max(1, known), folder: folder, notesUnreadable: true)
        }
        let exported = notes.filter(save).count
        return UninstallFlow.ExportResult(exported: exported, failed: notes.count - exported, folder: folder)
    }
}

extension UninstallFlow.ExportResult {
    /// What the export did, for the line under "Export your notes".
    var sentence: String {
        guard !notesUnreadable else { return Self.unreadable }
        let saved = "Saved \(exported.formatted()) note\(exported == 1 ? "" : "s") to \(folder.path)."
        return failed == 0 ? saved : "\(saved) \(failed.formatted()) could not be saved."
    }

    static let unreadable = "Hushy could not read your notes, so none of them were exported."
}
