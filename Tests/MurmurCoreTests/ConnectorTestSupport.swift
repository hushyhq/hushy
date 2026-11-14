import Foundation
@testable import MurmurCore

/// Shared fakes for the calendar connector tests: made-up client ids (never real ones), a
/// settable clock, and session builders over `InMemoryKeyStore` + `RecordingTransport`.
enum ConnectorFixtures {
    static let epoch = Date(timeIntervalSince1970: 1_790_000_000)

    static var configuration: CalendarConnectorConfiguration {
        CalendarConnectorConfiguration(infoDictionary: [
            CalendarConnectorConfiguration.googleClientIDKey: "test-google-client-id",
            CalendarConnectorConfiguration.googleClientSecretKey: "test-google-desktop-secret",
            CalendarConnectorConfiguration.microsoftClientIDKey: "test-microsoft-client-id",
        ])
    }

    static var google: OAuthClientConfiguration { configuration.client(for: .google)! }
    static var microsoft: OAuthClientConfiguration { configuration.client(for: .microsoft)! }

    static func tokens(access: String = "access-1", refresh: String? = "refresh-1", expiresIn: TimeInterval, now: Date = epoch) -> OAuthTokenSet {
        OAuthTokenSet(accessToken: access, refreshToken: refresh, expiresAt: now.addingTimeInterval(expiresIn), scope: nil)
    }

    static func tokenJSON(access: String = "access-2", refresh: String? = nil, expiresIn: String = "3600", scope: String? = nil) -> HTTPResponse {
        var fields = ["\"access_token\": \"\(access)\"", "\"token_type\": \"Bearer\"", "\"expires_in\": \(expiresIn)"]
        if let refresh { fields.append("\"refresh_token\": \"\(refresh)\"") }
        if let scope { fields.append("\"scope\": \"\(scope)\"") }
        return .json("{\(fields.joined(separator: ", "))}")
    }

    static func session(
        _ client: OAuthClientConfiguration = google, transport: RecordingTransport, store: OAuthTokenStore,
        clock: TestClock = TestClock(), accountEmail: String? = nil
    ) -> OAuthSession {
        OAuthSession(
            account: CalendarAccountID(provider: client.provider, id: "acct-1"),
            client: OAuthTokenClient(configuration: client, transport: transport),
            store: store, accountEmail: accountEmail, clock: { clock.now })
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = ConnectorFixtures.epoch) { current = start }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

extension HTTPRequest {
    var queryItems: [String: String] {
        var result: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { result[item.name] = item.value ?? "" }
        return result
    }
}
