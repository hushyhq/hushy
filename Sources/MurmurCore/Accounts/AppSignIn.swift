import Foundation

/// The shape of the two values that cross between the app, the site page and the site's Worker:
/// 32 bytes as unpadded base64url (43 characters). Used for the app's secret, its challenge (the
/// SHA-256 of the secret) and the hand-off id. Anything else is refused at both ends.
public enum AppSignInShape {
    public static func isValue(_ text: String) -> Bool {
        text.utf8.count == 43 && text.utf8.allSatisfy { byte in
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
        }
    }
}

/// The address the browser opens when the site's sign-in page is done: `hushy://sign-in?id=<id>`.
/// It carries the hand-off id and nothing else; the id is useless without the secret the app
/// kept in memory when it started.
public enum AppSignInCallback {
    public static let scheme = "hushy"
    public static let host = "sign-in"

    /// The hand-off id, or `nil` when the address is not exactly the app's own callback.
    public static func id(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
              url.user == nil, url.password == nil, url.port == nil,
              url.path.isEmpty || url.path == "/",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.count == 1, items[0].name == "id",
              let id = items[0].value, AppSignInShape.isValue(id) else { return nil }
        return id
    }
}
