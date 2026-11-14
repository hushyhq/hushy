import MurmurCore
import SwiftUI

/// The sidebar's feedback button and the Send feedback sheet (`feedback-*`, light and dark): the footer
/// row at the sidebar's width (open and collapsed, a founding member and not), then every state of the sheet.
/// `HUSHY_SNAPSHOT_ONLY=feedback-` renders just these. The text and address are invented.
extension Snapshots {
    private static let sampleMessage = "Dictation is quick in Mail, but in Slack the pill sometimes stays on Cleaning up for a few seconds before it pastes."
    private static let sampleAccount = SendFeedbackAccount.signedIn(email: "sam@example.com")

    static func renderFeedback(model: AppModel, scheme: ColorScheme, directory: URL) async {
        let sidebar = CGSize(width: AssistantPane.sidebarWidth, height: 56)
        for (name, collapsed, plan) in [("footer-founding", false, SnapshotPlan.founding), ("footer-free", false, .free), ("footer-collapsed", true, .founding)] {
            let size = collapsed ? CGSize(width: AssistantPane.collapsedSidebarWidth, height: 150) : sidebar
            await capture(
                SidebarFooter(collapsed: collapsed).environment(model).environment(\.snapshotPlan, plan).background(Theme.bgSunken),
                name: "feedback-\(name)", scheme: scheme, size: size, directory: directory, fixedSize: true)
        }
        let states: [(String, String, SendFeedbackModel.Phase, SendFeedbackAccount)] = [
            ("sheet", sampleMessage, .editing, sampleAccount),
            ("sheet-empty", "", .editing, sampleAccount),
            ("sheet-sending", sampleMessage, .sending, sampleAccount),
            ("sheet-sent", sampleMessage, .sent, sampleAccount),
            ("sheet-failed", sampleMessage, .failed(.couldNotSend), sampleAccount),
            ("sheet-daily-limit", sampleMessage, .failed(.dailyLimit), sampleAccount),
            ("sheet-sign-in-needed", sampleMessage, .failed(.signInNeeded), sampleAccount),
            ("sheet-signed-out", "", .editing, .signedOut),
        ]
        for (name, text, phase, account) in states {
            await capture(
                SendFeedbackContent(
                    message: .constant(text), includeAppInfo: .constant(true), phase: phase, account: account,
                    characterCount: text.count, canSend: !text.isEmpty && phase != .sending),
                name: "feedback-\(name)", scheme: scheme, size: CGSize(width: SendFeedbackContent.width, height: 1), directory: directory)
        }
    }
}
