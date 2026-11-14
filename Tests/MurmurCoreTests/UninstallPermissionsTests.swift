import Foundation
import Testing
@testable import MurmurCore

/// The last step of the uninstall: macOS forgets Hushy's permissions (`tccutil reset All
/// app.hushy.Hushy`). The command is a recorder here; no test runs `tccutil`.
@Suite("Uninstall: resetting Hushy's permissions")
struct UninstallPermissionsTests {
    private let id = UninstallTestHome.bundleIdentifier
    private var reset: UninstallStep.Action { .resetPermissions(bundleIdentifier: id) }

    private func run(_ plan: UninstallPlan, _ log: UninstallOperationLog) async -> UninstallReport {
        await UninstallExecutor(fileSystem: FakeUninstallFileSystem([:]), operations: log.operations).run(plan)
    }

    @Test("ticked, the reset is the last step of the plan and the last thing the executor does")
    func tickedRunsLast() async throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let plan = try UninstallPlanner.plan(for: test.roots())
        let log = UninstallOperationLog()

        let report = await run(plan, log)

        #expect(plan.steps.last?.action == reset)
        #expect(plan.steps.filter { $0.action == reset }.count == 1)
        #expect(log.calls.last == "tccutil:app.hushy.Hushy")
        #expect(log.calls.filter { $0.hasPrefix("tccutil") }.count == 1)
        #expect(report.entries.last?.outcome == .done)
        #expect(report.removedEverything)
        #expect(!plan.kept.contains { $0.reason == .permissionsLeftByChoice })
    }

    @Test("unticked, the plan has no reset, the executor never asks for one, and the sheet's list says they stay")
    func untickedDoesNotRun() async throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let plan = try UninstallPlanner.plan(for: test.roots(resetsPermissions: false))
        let log = UninstallOperationLog()

        let report = await run(plan, log)

        #expect(!plan.labels.contains { $0.hasPrefix("tccutil") })
        #expect(!log.calls.contains { $0.hasPrefix("tccutil") })
        #expect(plan.kept.contains { $0.reason == .permissionsLeftByChoice })
        #expect(report.removedEverything)
    }

    @Test("a test run never resets permissions: its plan has no such step", arguments: [
        (false, true), (true, true),
    ])
    func testRunPlanHasNoReset(isTestRun: Bool, overridden: Bool) throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let scratch = test.root.appendingPathComponent("scratch-home", isDirectory: true)
        let roots = test.roots(support: overridden ? scratch : nil, overridden: overridden, isTestRun: isTestRun)

        let plan = try UninstallPlanner.plan(for: roots)

        #expect(plan.isTestRun)
        #expect(!plan.labels.contains { $0.hasPrefix("tccutil") })
    }

    @Test("a test run refuses the reset even if a plan carrying it is handed over, and tccutil is not asked")
    func testRunExecutorRefuses() async throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let scratch = test.root.appendingPathComponent("scratch-home", isDirectory: true)
        let roots = test.roots(support: scratch, overridden: true)
        let honest = try UninstallPlanner.plan(for: roots)
        let plan = UninstallPlan(
            roots: roots, allowedRoots: honest.allowedRoots,
            steps: [UninstallStep(reset, .settings, "Permissions")], kept: [],
            requiredDataMarker: nil, isTestRun: true)
        let log = UninstallOperationLog()

        let report = await run(plan, log)

        #expect(log.calls.isEmpty)
        guard case .refused = report.entries.first?.outcome else {
            Issue.record("the reset was not refused: \(String(describing: report.entries.first?.outcome))")
            return
        }
    }

    @Test("a failed reset is reported plainly, with where to remove Hushy by hand, and the rest still ran")
    func failureIsReported() async throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let plan = try UninstallPlanner.plan(for: test.roots())
        let log = UninstallOperationLog()
        log.failing = ["tccutil:app.hushy.Hushy"]

        let report = await run(plan, log)

        #expect(!report.removedEverything)
        #expect(report.leftovers.map(\.step.action) == [reset])
        let message = try #require(report.leftovers.first?.outcome.explanation)
        #expect(message.contains("did not reset Hushy's permissions"))
        #expect(message.contains("System Settings"))
        #expect(message.contains("Privacy & Security"))
        #expect(message.contains("Microphone and Accessibility"))
        #expect(log.calls.contains("defaults:\(id)"))
        #expect(log.calls.last == "tccutil:\(id)")
    }

    @Test("only Hushy's own identifier is ever passed on: another one in a plan is not run and is reported")
    func otherIdentifiersAreNeverPassed() async throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let roots = test.roots()
        let honest = try UninstallPlanner.plan(for: roots)
        for other in ["com.apple.Safari", "app.hushy.Hushy.helper", "", "All"] {
            let plan = UninstallPlan(
                roots: roots, allowedRoots: honest.allowedRoots,
                steps: [UninstallStep(.resetPermissions(bundleIdentifier: other), .settings, "Permissions")],
                kept: [], requiredDataMarker: nil, isTestRun: false)
            let log = UninstallOperationLog()

            let report = await run(plan, log)

            #expect(log.calls.isEmpty, "\(other)")
            #expect(report.leftovers.count == 1, "\(other)")
            #expect(report.leftovers.first?.outcome.explanation?.contains("System Settings") == true)
        }
    }

    @Test("a copy of the app with another identifier is not given a reset at all")
    func otherAppGetsNoReset() throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        var roots = test.roots()
        roots.bundleIdentifier = "com.example.Other"

        let plan = try UninstallPlanner.plan(for: roots)

        #expect(!plan.labels.contains { $0.hasPrefix("tccutil") })
    }

    @Test("the last pass before quitting does not ask again")
    func settleDoesNotRepeatIt() async throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let plan = try UninstallPlanner.plan(for: test.roots())
        let log = UninstallOperationLog()
        let executor = UninstallExecutor(fileSystem: FakeUninstallFileSystem([:]), operations: log.operations)

        let report = await executor.run(plan)
        _ = await executor.settle(plan, after: report)

        #expect(log.calls.filter { $0.hasPrefix("tccutil") }.count == 1)
    }
}
