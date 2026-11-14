import MurmurCore
import SwiftUI

// The smaller pieces of the uninstall sheet (`UninstallSheet`): rows, notices, the report and
// the button.

extension UninstallKept.Reason {
    /// Why it stays, in a word or two beside the path.
    var label: String? {
        switch self {
        case .exportFolder: nil
        case .insideExportFolder: "In your export folder"
        case .holdsExportFolder: "Holds your export folder"
        case .notAPlainFolderName: "Not Hushy's alone"
        case .speechModelsLeftByChoice: "Your choice"
        case .recordingsStay: "Recordings stay"
        case .permissionsLeftByChoice: "Your choice"
        }
    }
}

/// One line of the removed or kept list: what it is, a sentence or a path, and a size.
struct UninstallRow: View {
    let title: String
    let detail: String
    let trailing: String?
    var isPath = false

    var body: some View {
        SettingsRow(title: title, detail: detail) {
            if let trailing {
                Text(trailing).font(Theme.Font.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
            }
        }
        .textSelection(.enabled)
        .help(isPath ? detail : "")
    }
}

/// One exact location, in the full list and in the report of what was left.
struct UninstallLocation: View {
    let title: String
    let location: String
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text(title).font(Theme.Font.caption).foregroundStyle(Theme.textPrimary)
            Text(location).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let note {
                Text(note).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A few lines the person should read before the lists: a test run, or work in progress.
struct UninstallNotice: View {
    let symbol: String
    let lines: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: symbol).foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                ForEach(lines, id: \.self) { line in
                    Text(line).font(Theme.Font.body).foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.bgSunken))
    }
}

/// After the removal: done, or exactly what is still there and where. A test run ends with
/// Close, not Quit: it removed only its own files and the app stays open.
struct UninstallFinished: View {
    let report: UninstallReport
    let plan: UninstallPlan?
    let quit: () -> Void

    private var isTestRun: Bool { plan?.isTestRun ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: report.removedEverything ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(report.removedEverything ? Theme.success : Theme.warning)
                Text(title).foregroundStyle(Theme.textPrimary)
            }
            .font(Theme.Font.title)
            Text(detail).font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !report.leftovers.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    ForEach(report.leftovers) { entry in
                        UninstallLocation(
                            title: entry.step.title, location: entry.step.location, note: entry.outcome.explanation)
                    }
                }
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.bgSunken))
            }
            HStack {
                Spacer()
                Button(isTestRun ? "Close" : "Quit Hushy", action: quit)
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var title: String {
        let subject = isTestRun ? "The test run's files were" : "Hushy was"
        return report.removedEverything
            ? (isTestRun ? "The test run's files have been removed" : "Hushy has been removed")
            : "\(subject) removed, with \(leftoverCount) left behind"
    }

    private var leftoverCount: String {
        report.leftovers.count == 1 ? "one thing" : "\(report.leftovers.count) things"
    }

    var detail: String {
        if isTestRun {
            let folder = plan?.roots.supportDirectory.path ?? "its data folder"
            let rest = "Nothing else on this Mac was touched. Hushy is still open, without this run's files: quit it when you are done."
            return report.removedEverything
                ? "This run's own files are gone from \(folder). \(rest)"
                : "These could not be removed from \(folder). \(rest)"
        }
        let export = plan.map { " Your export folder is still at \($0.roots.exportDirectory.path)." } ?? ""
        // Not something left on this Mac, so it is said here and not in the list below.
        let signOut = report.signedOutOnThisMacOnly
            ? " " + (UninstallReport.Outcome.signedOutOnThisMacOnly.explanation ?? "") : ""
        guard !report.removedEverything else {
            return "Its data, models, settings and sign-in are gone from this Mac.\(signOut)\(export)"
        }
        let keptKey = report.leftovers.contains { $0.outcome == .keptWithRecordings }
            ? " Recordings were left behind, so their encryption key was kept too: they are still readable with it."
            : ""
        return "Everything else is gone. These could not be removed; you can remove them yourself.\(keptKey)\(signOut)\(export)"
    }
}

/// The destructive button: red ink on a hairline, never filled, so it is not the eye's first stop.
struct UninstallButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.error)
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.s)
            .background(Capsule().fill(hovering || configuration.isPressed ? Theme.error.opacity(0.1) : .clear))
            .overlay(Capsule().strokeBorder(Theme.error.opacity(0.6), lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
            .animation(Theme.fade, value: hovering)
    }
}
