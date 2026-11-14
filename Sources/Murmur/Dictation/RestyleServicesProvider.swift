import AppKit
import MurmurCore

/// The right-click Services items (`RestyleService`, declared in `Info.plist` under `NSServices`). The system calls
/// the method named by each item's `NSMessage` when the person picks it, with the selection on a pasteboard. Nothing
/// here runs, reads or watches until then.
///
/// A rewrite item puts the new text on the pasteboard and the app replaces the selection where it allows. A copy item
/// puts it on the clipboard and returns nothing, so the selection stays. When the guard refuses, nothing is put on the
/// pasteboard that was not already there: the calling app is handed back the text it sent, and the pill says why.
@MainActor
final class RestyleServicesProvider: NSObject {
    private weak var restyle: RestyleController?

    /// The longest the calling app is made to wait: the voice edit's longest wait (`VoiceEditor.budget`) and a margin.
    static let patience: Duration = .seconds(15)

    init(restyle: RestyleController) {
        self.restyle = restyle
        super.init()
    }

    /// Makes the items work for this app. Called once the app has launched.
    func register() {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    /// One Services call. The system asks for an answer before it returns, so this waits for the model with the
    /// run loop turning (the pill keeps drawing). The model's work runs off the main actor, so the wait never
    /// depends on the main actor being free.
    func run(_ item: RestyleService, pasteboard: NSPasteboard) {
        guard let restyle, let text = pasteboard.string(forType: .string),
              let run = restyle.startService(text: text) else { return }
        let answer = ServiceAnswer()
        let (style, selected, model) = (item.style, run.selection.text, run.model)
        Task.detached { answer.finish(with: await SelectionRestyler.restyle(selected, as: style, model: model)) }
        let replacement = restyle.finishService(item, run: run, outcome: answer.wait(up: Self.patience))
        guard item.delivery == .replaceSelection, let replacement else { return }
        pasteboard.clearContents()
        pasteboard.setString(replacement, forType: .string)
    }

    // MARK: The messages `Info.plist` names. Each is one line: the table in `RestyleService` is the single list.

    @objc func makeProfessional(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        run(.makeProfessional, pasteboard: pasteboard)
    }

    @objc func makeCasual(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        run(.makeCasual, pasteboard: pasteboard)
    }

    @objc func cleanUp(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        run(.cleanUp, pasteboard: pasteboard)
    }

    @objc func copyAsProfessional(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        run(.copyAsProfessional, pasteboard: pasteboard)
    }

    @objc func copyAsPrompt(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        run(.copyAsPrompt, pasteboard: pasteboard)
    }
}

/// The answer a Services call is waiting for, set by the model's task and read by the thread that waits.
private final class ServiceAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: RestyleOutcome?

    func finish(with outcome: RestyleOutcome) {
        lock.withLock { self.outcome = outcome }
    }

    /// Turns the run loop until the answer arrives. Nil when it did not arrive in time.
    func wait(up limit: Duration) -> RestyleOutcome? {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if let outcome = lock.withLock({ outcome }) { return outcome }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        return lock.withLock { outcome }
    }
}
