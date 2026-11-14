import AppKit
import MurmurCore
import SwiftUI

/// The feedback sheet's words, kept here so a test can read them.
enum FeedbackCopy {
    static let menuItem = "Send Feedback…"
    static let windowTitle = "Send Feedback"
    static let title = "Send feedback"
    static let intro = "Tell us what went wrong or what could be better. Your mail app opens with the message, so you can read it before you send it."
    static let placeholder = "What happened?"
    static let attach = "Attach diagnostics"
    static let attachDetail = "App and Mac details, and timings from the last 3 days. No words you said or typed."
    static let compose = "Create Email"
    static let preparing = "Preparing…"
    static let aboutDetail = "Tell us what went wrong or what could be better."
    static let attachFailed = "Hushy could not write the diagnostics file. Turn off Attach diagnostics and try again."
    static let mailFailed = "No mail app opened. You can write to \(FeedbackMail.recipient) from any email account."
}

/// One text box and the diagnostics tick box; the email itself is written in the person's own
/// mail app (`FeedbackMail`). Shown as a sheet from Settings → About and as a small window
/// from the menu bar menu, which cannot hold a sheet.
struct FeedbackSheet: View {
    static let windowID = "feedback"

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var showsTitle = true
    @State private var message = ""
    @State private var attachDiagnostics = true
    @State private var isPreparing = false
    @State private var error: String?
    /// Reading the log; cancelled when the person closes the sheet first, so no email opens late.
    @State private var preparation: Task<Void, Never>?

    var body: some View {
        FeedbackSheetContent(
            message: $message, attachDiagnostics: $attachDiagnostics, showsTitle: showsTitle,
            isPreparing: isPreparing, error: error, cancel: { dismiss() }, compose: compose)
            .onDisappear { preparation?.cancel() }
    }

    private func compose() {
        let body = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !isPreparing else { return }
        isPreparing = true
        error = nil
        let facts = attachDiagnostics ? FeedbackFacts.current(model) : nil
        preparation = Task {
            defer { isPreparing = false }
            var attachment: URL?
            if let facts {
                guard let file = await Self.writeDiagnostics(facts) else {
                    error = FeedbackCopy.attachFailed
                    return
                }
                attachment = file
            }
            guard !Task.isCancelled else { return }
            if FeedbackMail.compose(body: body, attachment: attachment) == .failed {
                error = FeedbackCopy.mailFailed
            } else {
                dismiss()
            }
        }
    }

    /// Reads the log and writes the file off the main thread: the log takes seconds to read.
    private static func writeDiagnostics(_ facts: FeedbackFacts) async -> URL? {
        await Task.detached(priority: .userInitiated) {
            let log = FeedbackLogReader.read()
            let text = FeedbackDiagnostics.file(facts: facts, lines: log.lines, reach: log.reach, now: Date())
            return try? FeedbackMail.writeAttachment(text)
        }.value
    }
}

extension FeedbackFacts {
    @MainActor
    static func current(_ model: AppModel) -> FeedbackFacts {
        let cleanup = model.cleanupModel
        let system = ProcessInfo.processInfo.operatingSystemVersion
        model.permissions.refresh()
        return FeedbackFacts(
            version: AppVersion.shortVersion, build: AppVersion.buildNumber,
            macOS: "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)",
            chip: cleanup.machine.chipName, memoryGB: cleanup.machine.physicalMemoryGB,
            cleanupSetting: model.settings.cleanupBackend.rawValue,
            cleanupInUse: cleanup.effective.kind, cleanupModelID: cleanup.selectedEntry.id,
            microphone: Permission(model.permissions.microphone),
            accessibility: Permission(model.permissions.accessibility))
    }
}

private extension FeedbackFacts.Permission {
    init(_ status: Permissions.Status) {
        switch status {
        case .granted: self = .granted
        case .denied: self = .denied
        case .notDetermined: self = .notAsked
        }
    }
}

private extension EffectiveCleanupBackend {
    var kind: String {
        switch self {
        case .apple: "apple"
        case .local: "local"
        case .rules: "rules"
        }
    }
}

/// The sheet's look, with no behaviour of its own, so snapshots can render every state.
struct FeedbackSheetContent: View {
    @Environment(\.isSnapshot) private var isSnapshot
    @Binding var message: String
    @Binding var attachDiagnostics: Bool
    var showsTitle = true
    var isPreparing = false
    var error: String?
    var cancel: () -> Void = {}
    var compose: () -> Void = {}

    static let width: CGFloat = 460

    private var isEmpty: Bool { message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if showsTitle {
                    Text(FeedbackCopy.title).font(Theme.Font.title).foregroundStyle(Theme.textPrimary)
                }
                Text(FeedbackCopy.intro).font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            messageBox
            diagnosticsChoice
            if let error {
                Text(error).font(Theme.Font.caption).foregroundStyle(Theme.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .padding(Theme.Space.xl)
        .frame(width: Self.width)
        .background(Theme.bgBase)
    }

    private var messageBox: some View {
        FeedbackMessageBox(message: $message, placeholder: FeedbackCopy.placeholder)
    }

    private var diagnosticsChoice: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Toggle(FeedbackCopy.attach, isOn: $attachDiagnostics).toggleStyle(.checkbox)
                .font(Theme.Font.body).foregroundStyle(Theme.textPrimary)
            Text(FeedbackCopy.attachDetail).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
        }
    }

    private var buttons: some View {
        HStack(spacing: Theme.Space.s) {
            if isPreparing {
                // An image render cannot draw the spinner; the word alone stands in for it there.
                if !isSnapshot { ProgressView().controlSize(.small) }
                Text(FeedbackCopy.preparing).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button("Cancel", action: cancel).buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            Button(FeedbackCopy.compose, action: compose).buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(isEmpty || isPreparing)
        }
    }
}
