import AppKit
import MurmurCore
import SwiftUI

/// The sheet behind Settings → About → "Uninstall Hushy…". The live flow in a sheet; what it
/// draws is `UninstallSheetContent`, which takes plain values so snapshots need no flow.
struct UninstallSheet: View {
    let flow: UninstallFlow

    var body: some View {
        UninstallSheetContent(
            phase: flow.phase, plan: flow.plan, inventory: flow.inventory, counts: flow.counts,
            export: flow.export, confirmation: flow.confirmation, activity: flow.activity,
            actions: UninstallSheetActions(
                send: { flow.handle($0) }, exportNotes: { flow.exportNotes() },
                setRemovesSpeechModels: { flow.setRemovesSpeechModels($0) },
                setResetsPermissions: { flow.setResetsPermissions($0) }, quit: { flow.quit() }))
            .interactiveDismissDisabled()
            .onAppear { flow.open() }
    }
}

/// What the sheet's buttons, keys and tick boxes do. Snapshots leave them all empty.
struct UninstallSheetActions {
    var send: (UninstallConfirmation.Input) -> Void = { _ in }
    var exportNotes: () -> Void = {}
    var setRemovesSpeechModels: (Bool) -> Void = { _ in }
    var setResetsPermissions: (Bool) -> Void = { _ in }
    var quit: () -> Void = {}
}

struct UninstallSheetContent: View {
    let phase: UninstallFlow.Phase
    let plan: UninstallPlan?
    let inventory: UninstallInventory?
    let counts: UninstallFlow.Counts
    let export: UninstallFlow.ExportResult?
    let confirmation: UninstallConfirmation
    var activity: [UninstallActivity] = []
    var showsEveryLocation = false
    var actions = UninstallSheetActions()

    static let width: CGFloat = 560

    /// What the sheet says when the app would not stop. Nothing was removed, but the app is not
    /// as it was: whatever had stopped before the one thing that would not is still stopped.
    static func abandonedDetail(_ reason: String) -> String {
        reason + " Nothing was removed. Hushy stopped some background work to prepare; quit and reopen it to carry on as before."
    }

    var body: some View {
        Group {
            switch phase {
            case .review:
                if let plan {
                    UninstallReview(
                        plan: plan, inventory: inventory, counts: counts, export: export,
                        confirmation: confirmation, activity: activity,
                        showsEveryLocation: showsEveryLocation, actions: actions)
                } else {
                    UninstallMessage(title: "Uninstall Hushy", detail: "Working out what Hushy keeps on this Mac…")
                }
            case .working:
                UninstallMessage(
                    title: "Removing Hushy", detail: "Stopping, signing out and removing its files. This takes a moment.",
                    showsProgress: true)
            case .finished(let report):
                UninstallFinished(report: report, plan: plan, quit: actions.quit)
            case .refused(let refusal):
                UninstallMessage(
                    title: "Hushy can't uninstall itself here",
                    detail: refusal.explanation + " Nothing was removed.",
                    button: ("Close", { actions.send(.cancelButton) }))
            case .abandoned(let reason):
                UninstallMessage(
                    title: "Hushy was not uninstalled",
                    detail: Self.abandonedDetail(reason),
                    button: ("Close", { actions.send(.cancelButton) }))
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: Self.width, alignment: .leading)
        .background(Theme.bgBase)
        .onExitCommand { actions.send(.escapeKey) }
    }
}

/// A title, one paragraph and at most one button: the waiting, working, refused and
/// not-stopped states.
private struct UninstallMessage: View {
    let title: String
    let detail: String
    var showsProgress = false
    var button: (title: String, action: () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(title).font(Theme.Font.title).foregroundStyle(Theme.textPrimary)
            HStack(spacing: Theme.Space.m) {
                if showsProgress { ProgressView().controlSize(.small) }
                Text(detail).font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let button {
                HStack {
                    Spacer()
                    Button(button.title, action: button.action)
                        .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

/// Before anything is removed: what goes, what stays, the export, and the confirmation.
private struct UninstallReview: View {
    let plan: UninstallPlan
    let inventory: UninstallInventory?
    let counts: UninstallFlow.Counts
    let export: UninstallFlow.ExportResult?
    let confirmation: UninstallConfirmation
    let activity: [UninstallActivity]
    let actions: UninstallSheetActions
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var showsEveryLocation: Bool

    /// The tallest the scrolling part may grow, so the buttons stay inside the Settings window.
    private static let listHeight: CGFloat = 400

    init(
        plan: UninstallPlan, inventory: UninstallInventory?, counts: UninstallFlow.Counts,
        export: UninstallFlow.ExportResult?, confirmation: UninstallConfirmation,
        activity: [UninstallActivity], showsEveryLocation: Bool, actions: UninstallSheetActions
    ) {
        self.plan = plan
        self.inventory = inventory
        self.counts = counts
        self.export = export
        self.confirmation = confirmation
        self.activity = activity
        self.actions = actions
        _showsEveryLocation = State(initialValue: showsEveryLocation)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Uninstall Hushy").font(Theme.Font.title).foregroundStyle(Theme.textPrimary)
                Text("This removes Hushy and everything it keeps on this Mac. It can't be undone.")
                    .font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
            }
            if plan.isTestRun {
                UninstallNotice(symbol: "testtube.2", lines: [
                    "This is a test run. Only this run's own files in \(plan.roots.supportDirectory.path) are removed.",
                    "Nothing in the Keychain, your Library, your login items or the Trash is touched, and Hushy does not quit.",
                ])
            }
            if !activity.isEmpty {
                UninstallNotice(symbol: "exclamationmark.circle.fill", lines: activity.map(\.sentence))
            }
            // `ImageRenderer` can't draw a scroll view, so snapshots lay the list out flat.
            if isSnapshot {
                lists
            } else {
                ScrollView(.vertical) { lists }.frame(maxHeight: Self.listHeight)
            }
            footer
        }
    }

    private var lists: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            SettingsGroup(title: "Removed") {
                if plan.isTestRun {
                    UninstallRow(
                        title: "This run's files", detail: plan.roots.supportDirectory.path,
                        trailing: size(.data, .models, .signIn), isPath: true)
                } else {
                    removedRows
                }
            }
            SettingsGroup(title: "Stays on this Mac") {
                ForEach(plan.kept) { kept in
                    UninstallRow(title: kept.title, detail: kept.location, trailing: kept.reason.label, isPath: true)
                }
                Text(alsoUntouched)
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
            }
            SettingsGroup(title: "Before you go") {
                SettingsRow(title: "Export your notes", detail: exportDetail) {
                    Button(export == nil ? "Export notes" : "Export again", action: actions.exportNotes)
                        .buttonStyle(SecondaryButtonStyle()).disabled(counts.notes == 0 && !counts.notesUnreadable)
                }
            }
            everyLocation
        }
    }

    @ViewBuilder private var removedRows: some View {
        UninstallRow(title: "History, notes and recordings", detail: dataDetail, trailing: size(.data))
        UninstallRow(title: "Writing models", detail: "The models that tidy up what you say.", trailing: size(.models))
        if offersSpeechModels { speechModelsRow }
        UninstallRow(
            title: "Settings and sign-in",
            detail: "Your preferences, your sign-in on this Mac, saved keys and Open at login.",
            trailing: size(.settings, .caches, .signIn))
        UninstallRow(title: "The Hushy app", detail: appDetail, trailing: nil)
    }

    /// The speech models have a line and a tick box of their own: they sit in the speech
    /// engine's folder, not Hushy's, and another app may be using the same ones.
    private var speechModelsRow: some View {
        let removes = plan.roots.removesSpeechModels
        return SettingsRow(title: "Speech models", detail: speechModelsDetail) {
            HStack(spacing: Theme.Space.m) {
                if removes, let size = size(.speechModels) {
                    Text(size).font(Theme.Font.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                }
                Toggle("Remove", isOn: Binding(get: { removes }, set: { actions.setRemovesSpeechModels($0) }))
                    .toggleStyle(.checkbox)
            }
        }
    }

    private var everyLocation: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button(showsEveryLocation ? "Hide the full list" : "Show every location (\(plan.steps.count))") {
                showsEveryLocation.toggle()
            }
            .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            if showsEveryLocation {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(plan.steps) { step in UninstallLocation(title: step.title, location: step.location) }
                }
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.bgSunken))
            }
        }
    }

    /// Cancel is the default button: Return and Escape both leave. Uninstalling takes a tick
    /// (two, when an export left notes unsaved) and then a click on a button that no key is
    /// bound to, and that stays off until the plan on screen has been measured.
    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if offersPermissions { permissionsToggle }
            acknowledgement(
                "I understand that this removes my history, notes and recordings from this Mac for good.",
                isOn: confirmation.isAcknowledged, input: .toggleAcknowledgement)
            if confirmation.needsUnsavedAcknowledgement {
                acknowledgement(
                    unsavedAcknowledgement, isOn: confirmation.acknowledgesUnsavedNotes,
                    input: .toggleUnsavedAcknowledgement)
            }
            HStack(spacing: Theme.Space.s) {
                if !confirmation.isMeasured {
                    Text("Measuring what will be removed…").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Uninstall Hushy") { actions.send(.uninstallButton) }
                    .buttonStyle(UninstallButtonStyle()).disabled(!confirmation.canUninstall)
                Button("Cancel") { actions.send(.defaultKey) }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
    }

    /// macOS keeps Microphone, Accessibility and the other permissions per app, so a later
    /// install would be treated as the same app unless they are reset. Ticked to begin with.
    private var permissionsToggle: some View {
        Toggle(isOn: Binding(get: { plan.roots.resetsPermissions }, set: { actions.setResetsPermissions($0) })) {
            Text("Also reset Hushy's permissions (Microphone, Accessibility and the rest)")
                .font(Theme.Font.body).foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.checkbox)
    }

    private func acknowledgement(_ text: String, isOn: Bool, input: UninstallConfirmation.Input) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { _ in actions.send(input) })) {
            Text(text).font(Theme.Font.body).foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.checkbox)
    }

    /// Names how many notes have no copy. When the notes could not be read at all there is no
    /// number to trust, so it says that instead.
    private var unsavedAcknowledgement: String {
        if export?.notesUnreadable == true {
            return "\(UninstallFlow.ExportResult.unreadable) I understand that they will be removed without a copy."
        }
        let notes = "\(confirmation.unsavedNotes.formatted()) note\(confirmation.unsavedNotes == 1 ? "" : "s")"
        return "\(notes) could not be exported. I understand that \(confirmation.unsavedNotes == 1 ? "it" : "they") will be removed without a copy."
    }

    /// True when the plan removes speech models or leaves them by the person's choice.
    private var offersSpeechModels: Bool {
        !plan.speechModelSteps.isEmpty || plan.kept.contains { $0.reason == .speechModelsLeftByChoice }
    }

    /// True when the plan resets the permissions or leaves them by the person's choice.
    private var offersPermissions: Bool {
        plan.steps.contains { if case .resetPermissions = $0.action { true } else { false } }
            || plan.kept.contains { $0.reason == .permissionsLeftByChoice }
    }

    private var speechModelsDetail: String {
        let shared = "They are in the speech engine's own folder, which other apps that use the same speech engine may share."
        return plan.roots.removesSpeechModels
            ? "\(shared) Untick to leave them in place."
            : "\(shared) They will be left in place."
    }

    private var alsoUntouched: String {
        plan.isTestRun
            ? "Nothing outside this run's data folder is touched."
            : UninstallPlan.alsoUntouched.joined(separator: " ")
    }

    private var dataDetail: String {
        let dictations = "\(counts.dictations.formatted()) dictation\(counts.dictations == 1 ? "" : "s")"
        let notes = counts.notesUnreadable
            ? "your notes" : "\(counts.notes.formatted()) note\(counts.notes == 1 ? "" : "s")"
        return "\(dictations) and \(notes), with their audio, your dictionary and everything Hushy learned from you."
    }

    private var appDetail: String {
        plan.steps.contains { $0.group == .app }
            ? "Moved to the Trash, and Hushy quits."
            : "This copy isn't running from an app, so it stays. Drag Hushy to the Trash yourself."
    }

    private var exportDetail: String {
        let history = "Dictation history has no export: copy anything you want to keep from History first."
        guard let export else {
            if counts.notesUnreadable {
                return "Hushy could not read your notes just now, so it cannot count them. \(history)"
            }
            return counts.notes == 0
                ? "There are no notes to export. \(history)"
                : "Saves every note as a Markdown file in your export folder. \(history)"
        }
        return export.sentence
    }

    private func size(_ groups: UninstallStep.Group...) -> String? {
        guard let inventory else { return "Measuring…" }
        let bytes = groups.reduce(Int64(0)) { $0 + inventory.bytes(in: $1) }
        return bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : nil
    }
}
