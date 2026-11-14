import MurmurCore
import SwiftUI

/// The "Share recap" control as it sits in the note header: closed, with each line it can show
/// after an action, and dimmed when a note has nothing to share. The open menu, the share sheet
/// and the mail draft are system UI and cannot be rendered here. Never reads a note or a
/// pasteboard; every state is a plain value.
extension Snapshots {
    static func renderShareRecap(scheme: ColorScheme, directory: URL) async {
        let rows: [(String, ShareRecapFeedback?, Bool)] = [
            ("closed", nil, true), ("copied", .copied, true), ("draft-opened", .draftOpened, true),
            ("too-long", .copiedForDraft, true), ("no-mail-app", .noMailApp, true), ("nothing", nil, false),
        ]
        let column = VStack(alignment: .trailing, spacing: 14) {
            ForEach(rows, id: \.0) { _, feedback, enabled in
                HStack(spacing: Theme.Space.xs) {
                    if let feedback { ShareRecapFeedbackLabel(feedback: feedback) }
                    ShareRecapLabel(isEnabled: enabled)
                }
            }
        }
        await capture(
            column.padding(24), name: "notes-share-recap-states", scheme: scheme,
            size: CGSize(width: 520, height: 260), directory: directory, fixedSize: true)
    }
}
