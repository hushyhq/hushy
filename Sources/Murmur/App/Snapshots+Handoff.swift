import MurmurCore
import SwiftUI

extension Snapshots {
    private static let listSize = CGSize(width: 600, height: 550)

    static func renderHandoff(model: AppModel, scheme: ColorScheme, directory: URL) async {
        let proposal = HandoffProposal(tool: .codex, request: "Research how paper kites are folded and write a short summary.",
                                       executable: "/opt/homebrew/bin/codex")
        model.handoff.pinForSnapshot([], proposal: proposal)
        await capture(TaskHandoffConfirmationView().environment(model), name: "handoff-confirm",
                      scheme: scheme, size: CGSize(width: 500, height: 420), directory: directory)
        let waiting = task("Compare invented kite shapes.", .waiting)
        let running = task("Summarize imaginary field notes.", .running)
        var done = task("Explain a paper kite design.", .done)
        done.result = "An invented paper kite can use a diamond frame and a ribbon tail."
        var failed = task("Review a made-up sketch.", .failed)
        failed.failure = "Timed out"
        let everyState = [waiting, running, done, failed]
        await list(everyState, name: "handoff-list", model: model, scheme: scheme, directory: directory)
        await list([], name: "handoff-empty", model: model, scheme: scheme, directory: directory)

        // A waiting task an earlier session left behind: it starts only from its Run button.
        let left = task("Outline an invented kite festival.", .waiting)
        await list([left, done], restored: [left.id, done.id], name: "handoff-waiting-run", model: model, scheme: scheme, directory: directory)
        // Clear tasks, asked in place before anything is removed.
        await list(everyState, confirmingClear: true, name: "handoff-clear-confirm", model: model, scheme: scheme, directory: directory)
        // The installed tool lacks an option Hushy depends on, so the task was not run.
        var outdated = task("List made-up kite colours.", .failed)
        outdated.failure = "Update Codex to use background tasks."
        await list([outdated], name: "handoff-update-codex", model: model, scheme: scheme, directory: directory)
        model.handoff.pinForSnapshot([])
    }

    private static func task(_ request: String, _ state: HandoffTask.State) -> HandoffTask {
        var item = HandoffTask(tool: .codex, request: request)
        item.state = state
        return item
    }

    private static func list(
        _ tasks: [HandoffTask], restored: Set<UUID> = [], confirmingClear: Bool = false, name: String,
        model: AppModel, scheme: ColorScheme, directory: URL
    ) async {
        model.handoff.pinForSnapshot(tasks, restored: restored, confirmingClear: confirmingClear)
        await capture(TaskHandoffListView().environment(model), name: name,
                      scheme: scheme, size: listSize, directory: directory)
    }
}
