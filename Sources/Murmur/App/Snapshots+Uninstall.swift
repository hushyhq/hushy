import MurmurCore
import SwiftUI

/// Settings → About → "Uninstall Hushy…": the review (measuring with the button off, measured,
/// speech models left in place, notes exported, an export that left notes unsaved, notes that
/// could not be read, a recording in progress, the full list of locations, ready to confirm, a
/// test run), the removal in progress, and how it ends (clean, signed out on this Mac only, with
/// things left behind, the encryption key kept, the test run's own ending, not stopped, refused).
/// Every state is a plain value: the plan comes from the pure planner over an invented home
/// folder, so nothing is read from this Mac and nothing is removed.
extension Snapshots {
    static func renderUninstall(scheme: ColorScheme, directory: URL) async {
        for (name, sheet) in UninstallSnapshotFixtures.states() {
            await capture(
                sheet, name: "uninstall-\(name)", scheme: scheme,
                size: CGSize(width: UninstallSheetContent.width, height: 120), directory: directory)
        }
    }
}

@MainActor
enum UninstallSnapshotFixtures {
    /// Every captured state, by the name after `uninstall-`. Empty if the planner refuses the
    /// invented Mac, which the fixture test would catch.
    static func states() -> [(String, UninstallSheetContent)] {
        guard let plan = try? UninstallPlanner.plan(for: roots()),
              let unbundled = try? UninstallPlanner.plan(for: roots(bundle: nil)),
              let keepsPermissions = try? UninstallPlanner.plan(for: roots(resetsPermissions: false)),
              let keepsSpeech = try? UninstallPlanner.plan(for: roots(removesSpeechModels: false)),
              let testRun = try? UninstallPlanner.plan(for: testRunRoots())
        else { return [] }
        return reviewStates(
            plan, unbundled: unbundled, keepsSpeech: keepsSpeech, keepsPermissions: keepsPermissions, testRun: testRun)
            + endStates(plan, testRun: testRun)
    }

    private static func reviewStates(
        _ plan: UninstallPlan, unbundled: UninstallPlan, keepsSpeech: UninstallPlan, keepsPermissions: UninstallPlan,
        testRun: UninstallPlan
    ) -> [(String, UninstallSheetContent)] {
        let exported = UninstallFlow.ExportResult(exported: 37, failed: 0, folder: plan.roots.exportDirectory)
        let partly = UninstallFlow.ExportResult(exported: 34, failed: 3, folder: plan.roots.exportDirectory)
        return [
            // The Uninstall button is off: the plan has not been measured yet.
            ("measuring", review(plan, confirmation: confirmation(isMeasured: false, isAcknowledged: true), inventory: nil)),
            ("review", review(plan)),
            ("speech-models-kept", review(keepsSpeech)),
            ("permissions-kept", review(keepsPermissions)),
            ("review-exported", review(plan, export: exported)),
            // Three notes could not be saved: a second tick box, naming the number, and the button off.
            ("export-failed", review(
                plan, confirmation: confirmation(isAcknowledged: true, unsaved: 3), export: partly)),
            // The database could not be read: nothing was exported, and the second tick says so.
            ("notes-unreadable", review(
                plan, confirmation: confirmation(isAcknowledged: true, unsaved: 37),
                export: UninstallFlow.ExportResult(
                    exported: 0, failed: 37, folder: plan.roots.exportDirectory, notesUnreadable: true))),
            ("recording-in-progress", review(plan, activity: [.recording, .importing])),
            ("review-locations", review(plan, showsEveryLocation: true)),
            ("ready", review(plan, confirmation: confirmation(isAcknowledged: true), export: exported)),
            ("not-an-app", review(unbundled)),
            ("test-run", review(testRun, inventory: testRunInventory)),
        ]
    }

    private static func endStates(_ plan: UninstallPlan, testRun: UninstallPlan) -> [(String, UninstallSheetContent)] {
        [
            ("working", sheet(.working, plan)),
            ("done", sheet(.finished(report(plan, leftovers: false)), plan)),
            ("signed-out-here-only", sheet(.finished(report(plan, leftovers: false, signOut: .signedOutOnThisMacOnly)), plan)),
            ("leftovers", sheet(.finished(report(plan, leftovers: true)), plan)),
            ("key-kept", sheet(.finished(reportKeepingKey(plan)), plan)),
            ("test-run-done", sheet(.finished(report(testRun, leftovers: false)), testRun)),
            ("not-stopped", sheet(.abandoned(UninstallStopFailure(notStopped: "the file import").localizedDescription), plan)),
            ("permissions-not-reset", sheet(.finished(reportFailingPermissions(plan)), plan)),
            ("refused", sheet(.refused(.notAHushyDataFolder("/Users/you/Projects")), plan)),
        ]
    }

    /// An invented Mac. Only names: the planner never looks at a file.
    static func roots(
        bundle: URL? = URL(fileURLWithPath: "/Applications/Hushy.app"), removesSpeechModels: Bool = true,
        resetsPermissions: Bool = true
    ) -> UninstallRoots {
        let home = URL(fileURLWithPath: "/Users/you", isDirectory: true)
        return UninstallRoots(
            home: home,
            supportDirectory: home.appendingPathComponent("Library/Application Support/Hushy", isDirectory: true),
            supportIsOverridden: false, bundleIdentifier: SingleInstance.bundleIdentifier, bundleURL: bundle,
            exportDirectory: home.appendingPathComponent("Documents/Hushy", isDirectory: true),
            speechModelFolderNames: ["parakeet-ultra", "parakeet-english", "vocabulary", "speakers"],
            removesSpeechModels: removesSpeechModels, resetsPermissions: resetsPermissions)
    }

    /// The same Mac with the data folder moved by `HUSHY_HOME`: a test run.
    static func testRunRoots() -> UninstallRoots {
        var roots = UninstallSnapshotFixtures.roots()
        roots.supportDirectory = URL(fileURLWithPath: "/Users/you/Scratch/hushy-trial", isDirectory: true)
        roots.supportIsOverridden = true
        roots.isTestRun = true
        return roots
    }

    static let inventory = UninstallInventory(bytes: [
        .data: 2_140_000_000, .models: 1_730_000_000, .speechModels: 640_000_000, .settings: 48_000,
        .caches: 12_400_000,
    ])

    static let testRunInventory = UninstallInventory(bytes: [.data: 3_400_000, .models: 0, .signIn: 2_000])

    /// The confirmation in a given state, reached the way the sheet reaches it.
    static func confirmation(
        isMeasured: Bool = true, isAcknowledged: Bool = false, unsaved: Int = 0
    ) -> UninstallConfirmation {
        var confirmation = UninstallConfirmation()
        if isMeasured { confirmation.measured() }
        if isAcknowledged { _ = confirmation.handle(.toggleAcknowledgement) }
        if unsaved > 0 { confirmation.exportFinished(unsaved: unsaved) }
        return confirmation
    }

    private static func review(
        _ plan: UninstallPlan, confirmation: UninstallConfirmation = UninstallSnapshotFixtures.confirmation(),
        inventory: UninstallInventory? = UninstallSnapshotFixtures.inventory, export: UninstallFlow.ExportResult? = nil,
        activity: [UninstallActivity] = [], showsEveryLocation: Bool = false
    ) -> UninstallSheetContent {
        UninstallSheetContent(
            phase: .review, plan: plan, inventory: inventory,
            counts: UninstallFlow.Counts(dictations: 1_204, notes: 37), export: export,
            confirmation: confirmation, activity: activity, showsEveryLocation: showsEveryLocation)
    }

    static func sheet(_ phase: UninstallFlow.Phase, _ plan: UninstallPlan) -> UninstallSheetContent {
        UninstallSheetContent(
            phase: phase, plan: plan, inventory: nil, counts: UninstallFlow.Counts(), export: nil,
            confirmation: UninstallConfirmation())
    }

    /// Every step done, or two of them left: one the system would not remove, one that is a link.
    /// `signOut` is how the sign-out ended.
    static func report(
        _ plan: UninstallPlan, leftovers: Bool, signOut: UninstallReport.Outcome = .done
    ) -> UninstallReport {
        let entries = plan.steps.map { step -> UninstallReport.Entry in
            var outcome = step.action == .signOut ? signOut : UninstallReport.Outcome.done
            if leftovers, step.title == "Caches" {
                outcome = .failed("The folder is in use by another program.")
            } else if leftovers, step.title == "Saved window positions" {
                outcome = .refused(.isALink(step.location))
            }
            return UninstallReport.Entry(step: step, outcome: outcome)
        }
        return UninstallReport(refusal: nil, entries: entries)
    }

    /// The data folder could not be removed, so the key that reads its recordings was kept.
    static func reportKeepingKey(_ plan: UninstallPlan) -> UninstallReport {
        let entries = plan.steps.map { step -> UninstallReport.Entry in
            var outcome = UninstallReport.Outcome.done
            if step.removesData {
                outcome = .failed("A file in the folder is in use by another program.")
            } else if step.onlyAfterDataRemoved {
                outcome = .keptWithRecordings
            }
            return UninstallReport.Entry(step: step, outcome: outcome)
        }
        return UninstallReport(refusal: nil, entries: entries)
    }

    /// Everything else was removed, but macOS refused to reset the permissions.
    static func reportFailingPermissions(_ plan: UninstallPlan) -> UninstallReport {
        let entries = plan.steps.map { step -> UninstallReport.Entry in
            guard case .resetPermissions = step.action else { return UninstallReport.Entry(step: step, outcome: .done) }
            return UninstallReport.Entry(
                step: step, outcome: .failed(UninstallExecutor.permissionsNotReset(detail: "tccutil exited with status 1")))
        }
        return UninstallReport(refusal: nil, entries: entries)
    }
}
