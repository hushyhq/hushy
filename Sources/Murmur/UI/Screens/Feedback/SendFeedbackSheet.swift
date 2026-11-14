import MurmurCore
import SwiftUI

/// The sheet behind the sidebar's feedback button: one text box, the version tick, Send. It posts to the
/// site (`FeedbackClient`), which emails the founder with the person's own address as Reply-To.
struct SendFeedbackSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(BetaGateController.self) private var gate
    @Environment(\.dismiss) private var dismiss
    @State private var feedback: SendFeedbackModel?
    @State private var sending: Task<Void, Never>?

    var body: some View {
        Group {
            if let feedback {
                SendFeedbackContent(
                    message: Bindable(feedback).message, includeAppInfo: Bindable(feedback).includeAppInfo,
                    phase: feedback.phase, account: feedback.account,
                    characterCount: feedback.characterCount, canSend: feedback.canSend,
                    cancel: { dismiss() },
                    send: { sending = Task { await feedback.submit() } },
                    openAccount: { dismiss(); model.openAccountSettings() })
            }
        }
        .onAppear {
            guard feedback == nil else { return }
            let session = gate.currentSession ?? (try? AccountSessionStore().load())
            feedback = .live(account: session.map { .signedIn(email: $0.email) } ?? .signedOut, fallback: session)
        }
        .onDisappear { sending?.cancel() }
    }
}

/// The sheet's look, with no behaviour of its own, so snapshots can render every state.
struct SendFeedbackContent: View {
    @Environment(\.isSnapshot) private var isSnapshot
    @Binding var message: String
    @Binding var includeAppInfo: Bool
    var phase: SendFeedbackModel.Phase
    var account: SendFeedbackAccount
    var characterCount = 0
    var canSend = true
    var cancel: () -> Void = {}
    var send: () -> Void = {}
    var openAccount: () -> Void = {}

    static let width = FeedbackSheetContent.width

    private var isSent: Bool { phase == .sent }
    private var isSending: Bool { phase == .sending }
    private var needsSignIn: Bool { account == .signedOut || phase == .failed(.signInNeeded) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(SendFeedbackCopy.title).font(Theme.Font.title).foregroundStyle(Theme.textPrimary)
                if !isSent { Text(SendFeedbackCopy.intro).font(Theme.Font.body).foregroundStyle(Theme.textSecondary) }
            }
            if isSent {
                sentNote
            } else if account == .signedOut {
                Text(SendFeedbackCopy.signedOut).font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                form
            }
            buttons
        }
        .padding(Theme.Space.xl)
        .frame(width: Self.width)
        .background(Theme.bgBase)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                FeedbackMessageBox(message: $message, placeholder: SendFeedbackCopy.placeholder, isDisabled: isSending)
                if SendFeedbackCopy.showsCounter(characterCount) {
                    Text(SendFeedbackCopy.counter(characterCount)).font(Theme.Font.caption)
                        .foregroundStyle(characterCount > FeedbackLimits.maxCharacters ? Theme.error : Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                infoToggle
                Text(SendFeedbackCopy.includeInfoDetail).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 20)
            }
            if case .signedIn(let email) = account {
                Text(SendFeedbackCopy.replyLine(email: email)).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
            if case .failed(let failure) = phase {
                Text(SendFeedbackCopy.failure(failure)).font(Theme.Font.caption).foregroundStyle(Theme.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var infoToggle: some View {
        if isSnapshot {
            // An image render cannot draw a native checkbox; this stands in for it there.
            HStack(spacing: 6) {
                Image(systemName: includeAppInfo ? "checkmark.square.fill" : "square").foregroundStyle(Theme.phosphor)
                Text(SendFeedbackCopy.includeInfo).font(Theme.Font.body).foregroundStyle(Theme.textPrimary)
            }
        } else {
            Toggle(SendFeedbackCopy.includeInfo, isOn: $includeAppInfo).toggleStyle(.checkbox)
                .font(Theme.Font.body).foregroundStyle(Theme.textPrimary).disabled(isSending)
        }
    }

    private var sentNote: some View {
        Label {
            Text(SendFeedbackCopy.sent).font(Theme.Font.body).foregroundStyle(Theme.textPrimary)
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        }
    }

    private var buttons: some View {
        HStack(spacing: Theme.Space.s) {
            if isSending {
                // An image render cannot draw the spinner; the word alone stands in for it there.
                if !isSnapshot { ProgressView().controlSize(.small) }
                Text(SendFeedbackCopy.sending).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if isSent {
                Button(SendFeedbackCopy.done, action: cancel).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            } else {
                Button(SendFeedbackCopy.cancel, action: cancel).buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                if needsSignIn {
                    Button(SendFeedbackCopy.openAccount, action: openAccount).buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(isFailed ? SendFeedbackCopy.retry : SendFeedbackCopy.send, action: send)
                        .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(!canSend)
                }
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }
}
