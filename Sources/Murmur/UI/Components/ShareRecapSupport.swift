import AppKit
import MurmurCore
import SwiftUI

/// Puts a recap on the pasteboard as plain text and HTML, so a mail app pastes it formatted and a
/// plain editor gets the plain text.
enum RecapPasteboard {
    @MainActor
    static func write(_ recap: MeetingRecap) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(recap.plainText, forType: .string)
        board.setString(recap.html, forType: .html)
    }
}

/// Opens a new message in the user's default mail app with the subject and body filled in and no
/// recipient. Hushy never sends it: the user reads the draft and presses Send, or closes it.
enum RecapMailDraft {
    @MainActor
    static func open(_ recap: MeetingRecap) -> ShareRecapFeedback {
        if let url = RecapMailto.url(subject: recap.subject, body: recap.plainText) {
            return launch(url) ? .draftOpened : .noMailApp
        }
        // Too long for a link: put the whole recap on the clipboard and open the draft empty.
        guard let bare = RecapMailto.url(subject: recap.subject, body: "") else { return .noMailApp }
        RecapPasteboard.write(recap)
        return launch(bare) ? .copiedForDraft : .noMailApp
    }

    @MainActor
    private static func launch(_ url: URL) -> Bool {
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { return false }
        return NSWorkspace.shared.open(url)
    }
}

/// Holds the view the share sheet points at, and the picker while it is on screen (the picker
/// keeps only a weak reference to its delegate).
@MainActor
final class ShareAnchor {
    fileprivate weak var view: NSView?
    private var picker: NSSharingServicePicker?
    private var delegate: RecapPickerDelegate?

    func present(_ recap: MeetingRecap) {
        guard let view else { return }
        let delegate = RecapPickerDelegate(subject: recap.subject)
        let picker = NSSharingServicePicker(items: [recap.plainText])
        picker.delegate = delegate
        self.delegate = delegate
        self.picker = picker
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}

/// Gives mail-style services the meeting title as their subject; the recap text is the body.
@MainActor
final class RecapPickerDelegate: NSObject, @preconcurrency NSSharingServicePickerDelegate {
    private let subject: String

    init(subject: String) { self.subject = subject }

    func sharingServicePicker(
        _ picker: NSSharingServicePicker, sharingServicesForItems items: [Any],
        proposedSharingServices proposedServices: [NSSharingService]
    ) -> [NSSharingService] {
        for service in proposedServices { service.subject = subject }
        return proposedServices
    }
}

/// An invisible view behind the control, only so the share sheet has something to anchor to.
struct ShareAnchorView: NSViewRepresentable {
    let anchor: ShareAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }
}
