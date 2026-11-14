import Foundation

/// Recognises a browser tab that is a live call (Google Meet, the Zoom web client, Webex) from its window
/// title alone, so the tab uses Work messages like the Zoom and Webex apps do.
///
/// A call is matched only by a closed set of whole-title shapes, after the browser's own suffix is removed.
/// A word like "meet" or "Zoom Meeting" inside a longer title is not a call: it is a note, a document or a
/// page about one ("Google Meet notes - Google Docs", "Zoom Meeting agenda - Notion", "Meet - project
/// notes"). Known document and note sites are checked first by the caller, and where the title cannot be
/// told apart from such a page the answer is not a call (Everything else). Title shapes:
///
/// - Google Meet: `Meet - abc-defg-hij` (the meeting code, three-four-three letters), or a title that is
///   only `Meet` or `Google Meet`.
/// - Zoom web client: `Zoom Meeting`, `Zoom Workplace`, `Zoom`, `Launch Meeting - Zoom`, `Join Meeting - Zoom`.
/// - Webex: `Webex`, `Webex Meeting(s)`, `Cisco Webex Meetings`.
///
/// These shapes are the ones the products are known to use; they have not been checked against a live
/// account here, so a variant that is not listed is simply treated as an ordinary page.
enum MeetingTab {
    private static let meetCode = try! NSRegularExpression(
        pattern: #"^meet\s[-–—]\s[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: [.caseInsensitive])
    private static let wholeTitles: Set<String> = [
        "meet", "google meet",
        "zoom meeting", "zoom workplace", "zoom", "launch meeting - zoom", "join meeting - zoom",
        "webex", "webex meeting", "webex meetings", "cisco webex meetings",
    ]

    static func isCall(windowTitle: String) -> Bool {
        let title = WebCodeEditor.pageTitle(from: windowTitle).trimmingCharacters(in: .whitespaces)
        let lowered = title.lowercased().replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
        if wholeTitles.contains(lowered) { return true }
        return meetCode.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
    }
}
