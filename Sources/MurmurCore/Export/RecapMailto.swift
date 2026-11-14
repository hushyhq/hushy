import Foundation

/// A `mailto:` link that opens a new message in the user's mail app with the subject and body
/// filled in and no recipient. Hushy never sends the message: the user reads the draft and
/// presses Send in their own mail app, or closes it.
public enum RecapMailto {
    /// Mail apps accept long links, but some truncate or refuse past a point; past this the
    /// caller falls back to copying the recap and opening a draft with only the subject.
    static let maxLength = 24_000

    /// The link, or `nil` when it would be longer than `maxLength` characters.
    public static func url(subject: String, body: String) -> URL? {
        let crlfBody = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        let text = "mailto:?subject=\(encode(subject))&body=\(encode(crlfBody))"
        guard text.count <= maxLength else { return nil }
        return URL(string: text)
    }

    private static let allowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
