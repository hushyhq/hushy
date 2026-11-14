import MurmurCore
import SwiftUI

struct TaskHandoffConfirmationView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isSnapshot) private var isSnapshot

    /// Must stay exactly true for `CodexHandoffRunner.arguments` and `timeout`: the person's own
    /// login, the read-only sandbox, and the 15-minute limit.
    static let disclosure = "Codex runs with your own login. It can read files on this Mac and send what it reads to OpenAI, but it cannot change files. It may keep running in the background for up to 15 minutes."
    /// The request scrolls inside this height, so a long one cannot push the buttons off screen.
    static let requestHeight: CGFloat = 160

    /// Names the file that will be run, so a tool the person did not expect is visible before
    /// they agree. The queued task carries this path and runs exactly this file.
    static func toolLine(_ path: String?) -> String {
        path.map { "Using \($0)" } ?? TaskHandoffUIModel.notFoundMessage
    }

    var body: some View {
        let proposal = app.handoff.proposal
        VStack(alignment: .leading, spacing: 18) {
            Text("Send task to Codex?").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.disclosure)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.toolLine(proposal?.executable))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Group {
                if isSnapshot {
                    // `ImageRenderer` draws neither a scroll view's content nor selectable text.
                    requestText(proposal).frame(maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView { requestText(proposal).textSelection(.enabled) }
                }
            }
            .frame(height: Self.requestHeight)
            .background(Theme.bgRaised)
            HStack {
                Button("Cancel") { app.handoff.cancelProposal(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                // No keyboard shortcut of any kind. Hushy's window comes forward when a task is
                // spoken, and a key meant for the app the person was typing in must not send it.
                Button("Queue task") { Task { await app.handoff.confirm() } }
                    .disabled(proposal?.executable == nil || app.handoff.isConfirming)
            }
            if let issue = app.handoff.issue { Text(issue).foregroundStyle(.red) }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func requestText(_ proposal: HandoffProposal?) -> some View {
        Text(proposal?.request ?? "")
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(12)
    }
}

struct TaskHandoffListView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isSnapshot) private var isSnapshot

    struct VisibleResult: Equatable {
        var text: String
        var isPartial: Bool
    }

    /// A result can be a megabyte, and one `Text` that long stalls the list while it is laid out.
    static let visibleResultCharacters = 20_000
    static let partialNote = "Showing the first part. Copy gives you all of it."
    static let clearQuestion = "Remove every task that is not running, with its result, and any saved task list that could not be read?"

    /// The part of a result that is drawn. Copy always takes the whole result.
    static func visiblePart(of result: String) -> VisibleResult {
        guard let end = result.index(result.startIndex, offsetBy: visibleResultCharacters, limitedBy: result.endIndex),
              end < result.endIndex else { return VisibleResult(text: result, isPartial: false) }
        return VisibleResult(text: String(result[..<end]), isPartial: true)
    }

    static func stateLabel(_ item: HandoffTask, isHeld: Bool) -> String {
        isHeld ? "Waiting. Click Run" : item.state.rawValue.capitalized
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Tasks").font(.title2.weight(.semibold))
                Spacer()
                if app.handoff.hasClearableTasks, !app.handoff.confirmingClear {
                    Button("Clear tasks") { app.handoff.confirmingClear = true }
                }
                Button("Done") { dismiss() }
            }
            if app.handoff.confirmingClear { clearConfirmation }
            if let notice = app.handoff.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            if app.handoff.items.isEmpty {
                Text("No tasks yet").foregroundStyle(.secondary)
            } else if isSnapshot {
                // `ImageRenderer` does not draw a scroll view's content.
                rows.frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView { rows }
            }
            if !app.handoff.isOn, app.handoff.items.contains(where: { $0.state == .waiting }) {
                Text("Background AI tasks are off. Waiting tasks will not start.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let issue = app.handoff.issue { Text(issue).foregroundStyle(.red) }
        }
        .padding(24)
        .frame(width: 560, height: 500)
        .task { if !isSnapshot { await app.handoff.refresh() } }
    }

    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(app.handoff.items) { item in
                taskRow(item, isHeld: item.state == .waiting && app.handoff.restored.contains(item.id))
            }
        }
    }

    /// Asked in place, in the list, so the tasks about to go are still in view.
    private var clearConfirmation: some View {
        HStack {
            Text(Self.clearQuestion)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Cancel") { app.handoff.confirmingClear = false }
            Button("Clear tasks", role: .destructive) { Task { await app.handoff.clearTasks() } }
        }
        .padding(12)
        .background(Theme.bgRaised)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func taskRow(_ item: HandoffTask, isHeld: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Codex · \(Self.stateLabel(item, isHeld: isHeld))").font(.headline)
                Spacer()
                if isHeld {
                    // Opens the confirmation sheet again; only Queue task there starts it.
                    Button("Run") { app.handoff.reconfirm(item) }
                }
                if item.state == .failed || item.state == .interrupted {
                    Button("Retry") { Task { await app.handoff.retry(item) } }
                }
                if item.state == .waiting || item.state == .running {
                    Button("Cancel") { Task { await app.handoff.cancel(item.id) } }
                } else {
                    Button("Delete") { Task { await app.handoff.delete(item.id) } }
                }
            }
            Text(item.request).lineLimit(2).foregroundStyle(.secondary)
            if item.state == .running {
                Text("Pauses while your Mac sleeps").font(.caption).foregroundStyle(.secondary)
            }
            if let result = item.result { resultView(result) }
            if let failure = item.failure { Text(failure).foregroundStyle(.red) }
        }
        .padding(12)
        .background(Theme.bgRaised)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func resultView(_ result: String) -> some View {
        let visible = Self.visiblePart(of: result)
        return DisclosureGroup("Open result") {
            ScrollView {
                Text(visible.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            if visible.isPartial {
                Text(Self.partialNote).font(.caption).foregroundStyle(.secondary)
            }
            Button("Copy result") { app.handoff.copyResult(result) }
        }
    }
}
