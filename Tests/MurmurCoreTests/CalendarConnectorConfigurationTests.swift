import Foundation
import Testing
@testable import MurmurCore

@Suite("Calendar connector configuration")
struct CalendarConnectorConfigurationTests {
    typealias Config = CalendarConnectorConfiguration

    @Test("placeholders, empty, missing and malformed values → not configured (rows hidden)")
    func absent() {
        for info: [String: Any]? in [
            nil, [:],
            [Config.googleClientIDKey: "__GOOGLE_OAUTH_CLIENT_ID__", Config.microsoftClientIDKey: "__MICROSOFT_OAUTH_CLIENT_ID__"],
            [Config.googleClientIDKey: "", Config.microsoftClientIDKey: "   "],
            [Config.googleClientIDKey: "has space", Config.microsoftClientIDKey: "a|b"],
            [Config.googleClientIDKey: 42, Config.microsoftClientIDKey: String(repeating: "a", count: 300)],
        ] {
            let config = Config(infoDictionary: info)
            #expect(config.client(for: .google) == nil)
            #expect(config.client(for: .microsoft) == nil)
            #expect(config.availableProviders.isEmpty)
        }
    }

    @Test("the shipped Info.plist placeholders read as not configured")
    func shippedPlist() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let info = try #require(NSDictionary(contentsOf: plist) as? [String: Any])
        #expect(info[Config.googleClientIDKey] as? String == "__GOOGLE_OAUTH_CLIENT_ID__")
        #expect(Config(infoDictionary: info).availableProviders.isEmpty)
    }

    @Test("real-looking ids → configured with the decided endpoints and read-only scopes")
    func configured() throws {
        let config = ConnectorFixtures.configuration
        #expect(config.availableProviders == [.google, .microsoft])
        let google = try #require(config.client(for: .google))
        #expect(google.clientID == "test-google-client-id" && google.clientSecret == "test-google-desktop-secret")
        #expect(google.authorizationURL.absoluteString == "https://accounts.google.com/o/oauth2/v2/auth")
        #expect(google.tokenURL.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(google.scopes == ["https://www.googleapis.com/auth/calendar.events.readonly"])
        #expect(google.extraAuthorizationParameters == ["access_type": "offline"])
        #expect(google.redirectURI(port: 5000).absoluteString == "http://127.0.0.1:5000/callback")
        #expect(google.revocationURL?.absoluteString == "https://oauth2.googleapis.com/revoke")

        let microsoft = try #require(config.client(for: .microsoft))
        #expect(microsoft.clientSecret == nil)
        #expect(microsoft.scopes == ["Calendars.Read", "offline_access"])
        #expect(microsoft.authorizationURL.absoluteString == "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")
        #expect(microsoft.tokenURL.absoluteString == "https://login.microsoftonline.com/common/oauth2/v2.0/token")
        // 127.0.0.1, never localhost: a browser resolving localhost may try [::1] first.
        #expect(microsoft.redirectURI(port: 5000).absoluteString == "http://127.0.0.1:5000/callback")
        #expect(microsoft.loopbackHost == "127.0.0.1" && microsoft.revocationURL == nil)
    }

    @Test("no write or mail scope is ever requested")
    func readOnlyScopes() {
        for scope in Config.googleScopes + Config.microsoftScopes {
            let lower = scope.lowercased()
            #expect(!lower.contains("write") && !lower.contains("mail") && !lower.hasSuffix("/auth/calendar") && !lower.hasSuffix("calendar.events"))
            #expect(lower.hasSuffix("readonly") || lower.hasSuffix(".read") || lower == "offline_access")
        }
    }

    @Test("Microsoft never has a secret; Google secret needs a Google id")
    func secrets() {
        let config = Config(infoDictionary: [
            Config.googleClientSecretKey: "orphan-secret", Config.microsoftClientIDKey: "ms-id",
        ])
        #expect(config.googleClientSecret == nil && config.client(for: .google) == nil)
        #expect(config.client(for: .microsoft)?.clientSecret == nil)
        #expect(Config(infoDictionary: [Config.googleClientIDKey: "g-id"]).client(for: .google)?.clientSecret == nil)
    }

    @Test("calendar connectors are free")
    func free() {
        #expect(ProFeature.calendarConnectors.isFree)
        #expect(Entitlements.has(.calendarConnectors))
    }
}
