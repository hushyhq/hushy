import Foundation

/// Client ids for the direct calendar connectors, read from the app's Info.plist, where
/// `scripts/build-app.sh` substitutes them from the release environment
/// (`docs/product/CONNECTORS.md` §6.7–6.8). A value that is empty, still a `__…__`
/// placeholder, or not a plausible client id is **absent**, and that provider's Connectors row is
/// hidden. Nothing here is a real id; the repo never carries one.
public struct CalendarConnectorConfiguration: Sendable, Equatable {
    public static let googleClientIDKey = "HushyGoogleOAuthClientID"
    public static let googleClientSecretKey = "HushyGoogleOAuthClientSecret"
    public static let microsoftClientIDKey = "HushyMicrosoftOAuthClientID"

    /// Exactly the read-only scopes decided in §1.1.2 item 2. No write or mail scopes, ever.
    public static let googleScopes = ["https://www.googleapis.com/auth/calendar.events.readonly"]
    public static let microsoftScopes = ["Calendars.Read", "offline_access"]

    public let googleClientID: String?
    public let googleClientSecret: String?
    public let microsoftClientID: String?

    public init(infoDictionary: [String: Any]?) {
        func value(_ key: String) -> String? { Self.usable(infoDictionary?[key] as? String) }
        googleClientID = value(Self.googleClientIDKey)
        // The Desktop-client "secret" is only meaningful alongside a Google client id.
        googleClientSecret = googleClientID == nil ? nil : value(Self.googleClientSecretKey)
        microsoftClientID = value(Self.microsoftClientIDKey)
    }

    /// The running app's configuration.
    public static var main: CalendarConnectorConfiguration {
        CalendarConnectorConfiguration(infoDictionary: Bundle.main.infoDictionary)
    }

    /// Providers with a client id in this build, in display order — the rows the pane may show.
    public var availableProviders: [CalendarProvider] {
        CalendarProvider.allCases.filter { client(for: $0) != nil }
    }

    public func client(for provider: CalendarProvider) -> OAuthClientConfiguration? {
        switch provider {
        case .google:
            guard let googleClientID else { return nil }
            return OAuthClientConfiguration(
                provider: .google, clientID: googleClientID, clientSecret: googleClientSecret,
                authorizationURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
                scopes: Self.googleScopes,
                extraAuthorizationParameters: ["access_type": "offline"],
                loopbackHost: "127.0.0.1",
                revocationURL: URL(string: "https://oauth2.googleapis.com/revoke")!)
        case .microsoft:
            guard let microsoftClientID else { return nil }
            return OAuthClientConfiguration(
                provider: .microsoft, clientID: microsoftClientID, clientSecret: nil,
                authorizationURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
                tokenURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
                scopes: Self.microsoftScopes,
                // 127.0.0.1, not localhost (IPv6 squatting); register `http://127.0.0.1` in Entra.
                // No revocation endpoint: Microsoft disconnect is local-only.
                loopbackHost: "127.0.0.1",
                revocationURL: nil)
        }
    }

    /// Trimmed value, or nil when empty, a `__PLACEHOLDER__`, or outside the character set real
    /// client ids/secrets use (`[A-Za-z0-9._-]`, ≤ 256) — so a mangled build setting disables the
    /// provider rather than producing a broken authorize URL.
    static func usable(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.hasPrefix("__"), value.hasSuffix("__") { return nil }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard value.count <= 256, value.allSatisfy(allowed.contains) else { return nil }
        return value
    }
}

extension CalendarConnectorConfiguration: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "CalendarConnectorConfiguration(google: \(googleClientID != nil), microsoft: \(microsoftClientID != nil))"
    }

    public var debugDescription: String { description }
}
