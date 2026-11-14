import Foundation

/// The last answer to "is the service open to everyone?" (`AccountClient.serviceIsOpen`), kept with
/// the time it was read. While the answer is open, every signed-in account has Pro
/// (`Entitlements.proActiveUntil`); this record is what lets that survive offline use.
///
/// A failed read never reaches this store, so "use the last known answer" is what the rest of the
/// app sees. A closed answer replaces an open one at once: no free Pro.
public struct OpenServiceAnswer: Codable, Equatable, Sendable {
    public let open: Bool
    public let checkedAt: Date
    public init(open: Bool, checkedAt: Date) { self.open = open; self.checkedAt = checkedAt }
}

public struct OpenServiceStore: @unchecked Sendable {
    public static let key = "service.openAnswer"
    /// How long an open answer counts without being read again. The app asks at launch and daily,
    /// so this only matters for a Mac that stays offline for a month.
    public static let offlineGrace: TimeInterval = 30 * 86_400

    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func last() -> OpenServiceAnswer? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(OpenServiceAnswer.self, from: data)
    }

    public func record(open: Bool, now: Date = Date()) {
        guard let data = try? JSONEncoder().encode(OpenServiceAnswer(open: open, checkedAt: now)) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// When the free Pro of an open service lapses unless the answer is read again, or `nil` if the
    /// last answer was closed, there is none, or it is older than the grace.
    public func activeUntil(now: Date = Date()) -> Date? {
        guard let answer = last(), answer.open else { return nil }
        let until = answer.checkedAt.addingTimeInterval(Self.offlineGrace)
        return now < until ? until : nil
    }
}
