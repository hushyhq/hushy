import AppKit
import Foundation

/// Hands a feedback message to the person's own mail app. Hushy sends nothing itself: the mail
/// app opens a new email to support, the person reads it (and the attached diagnostics file)
/// and sends it, or doesn't.
enum FeedbackMail {
    static let recipient = "support@tryhushy.com"
    static let subject = "Hushy feedback"
    static let attachmentName = "Hushy diagnostics.txt"

    enum Outcome: Equatable {
        /// A new email with the file attached (or no file asked for).
        case composed
        /// Only a `mailto:` link worked, which cannot carry a file: the file is shown in Finder
        /// and the email says to attach it.
        case composedWithoutAttachment
        case failed
    }

    /// Writes the diagnostics text to a folder of its own under `directory`, so the attachment
    /// has a plain name and two sends never share a file.
    static func writeAttachment(_ text: String, in directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let folder = directory.appendingPathComponent("Hushy feedback \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(attachmentName)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// The body for a `mailto:` link that cannot attach the file.
    static func fallbackBody(_ body: String, hasAttachment: Bool) -> String {
        guard hasAttachment else { return body }
        return body + "\n\n(Please attach \"\(attachmentName)\". Hushy has shown it in Finder.)"
    }

    /// `mailto:` with every character outside the unreserved set percent-encoded, so `&`, `=`,
    /// `+`, `#` or a line break in the message cannot cut it short or change its meaning.
    static func mailtoURL(body: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return URL(string: "mailto:\(recipient)?subject=\(encode(subject))&body=\(encode(body))")
    }

    @MainActor
    static func compose(body: String, attachment: URL?) -> Outcome {
        let items: [Any] = [body] + (attachment.map { [$0] } ?? [])
        if let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: items) {
            service.recipients = [recipient]
            service.subject = subject
            service.perform(withItems: items)
            return .composed
        }
        guard let url = mailtoURL(body: fallbackBody(body, hasAttachment: attachment != nil)),
              NSWorkspace.shared.open(url) else { return .failed }
        guard let attachment else { return .composed }
        NSWorkspace.shared.activateFileViewerSelecting([attachment])
        return .composedWithoutAttachment
    }
}
