import Foundation

public enum CalendarConnectorError: Error, Sendable, Equatable {
    /// Non-2xx from the calendar API other than a 401 (which becomes `.reauthorizationRequired`).
    case httpStatus(Int)
    /// Not JSON, or not the documented shape.
    case malformedResponse
    /// A pagination link pointed somewhere other than the provider's API host; not followed, so
    /// the bearer token is never sent elsewhere.
    case untrustedNextLink
}

/// Shared plumbing for the two readers: bearer-authorized GET with one refresh-and-retry on
/// 401, and defensive JSON helpers.
enum ConnectorRequest {
    /// Upper bound on pages per `events(from:to:)` (250 events each), and on body size.
    static let maxPages = 20
    static let maxBodyBytes = 4 * 1024 * 1024

    static func get(
        _ url: URL, extraHeaders: [String: String] = [:], session: OAuthSession, transport: any HTTPTransport
    ) async throws -> Data {
        var token = try await session.validAccessToken()
        for attempt in 0..<2 {
            var headers = extraHeaders
            headers["Authorization"] = "Bearer \(token)"
            headers["Accept"] = "application/json"
            let response = try await transport.send(HTTPRequest(method: .get, url: url, headers: headers))
            if response.statusCode == 401 {
                guard attempt == 0 else { throw OAuthError.reauthorizationRequired }
                token = try await session.validAccessToken(forceRefresh: true)
                continue
            }
            guard response.isSuccess else { throw CalendarConnectorError.httpStatus(response.statusCode) }
            guard response.body.count <= maxBodyBytes else { throw CalendarConnectorError.malformedResponse }
            return response.body
        }
        throw OAuthError.reauthorizationRequired
    }

    static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard data.count <= maxBodyBytes,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw CalendarConnectorError.malformedResponse }
        return object
    }

    static func joinedLocation(_ parts: [String?]) -> String {
        parts.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Local midnight of a `yyyy-MM-dd` date in `timeZone` — the way EventKit reports all-day
    /// events, so an all-day event read through any path lands on the same instants.
    static func allDayDate(_ text: String, timeZone: TimeZone) -> Date? {
        let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == parts[2]
        else { return nil }
        return date
    }
}
