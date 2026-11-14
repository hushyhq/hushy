import Foundation
import os

/// The once-a-day count of Macs that use Hushy (contract v2: `admin/APP-FLAGS-CONTRACT.md`, "Daily count").
///
/// **No identifier of any kind.** The body is the app build and one flag, nothing else; the site counts
/// each request it receives and keeps no id, no hash and no address. What this Mac keeps for it is a
/// "sent first" flag and the last UTC day it sent, and nothing else.
public enum DailyCountBody {
    public static let version = 2

    /// What the site accepts for `build`: 1 to 16 characters from `A-Z a-z 0-9 . _ -`.
    public static func isValidBuild(_ build: String) -> Bool {
        (1...16).contains(build.utf8.count) && build.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A)
                || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D
        }
    }

    /// The exact request body, or nil when `build` is not one the site would accept.
    public static func text(build: String, first: Bool) -> String? {
        guard isValidBuild(build) else { return nil }
        return "{\"v\":\(version),\"build\":\"\(build)\",\"first\":\(first)}"
    }

    public static func encode(build: String, first: Bool) -> Data? {
        text(build: build, first: first).map { Data($0.utf8) }
    }
}

public enum DailyCountEndpoint {
    /// The site Worker, on the same host the app signs in through. Always https.
    public static let url = AccountConfiguration.defaultSiteURL.appending(path: "api/ping")
}

/// The words "See what's sent", the Privacy settings and onboarding use for the daily count. One place, so the
/// screens and a test agree.
public enum DailyCountDisclosure {
    public static let title = "A daily count"
    /// The Settings → Privacy & security switch (on by default, a switch of its own).
    public static let switchTitle = "Send a daily count"
    public static let switchDetail =
        "Once a day, Hushy tells us this Mac used it: just the app version and whether it's your first day. No ID, nothing you said."
    /// The one line in onboarding's privacy step.
    public static let onboardingLine =
        "Once a day Hushy also sends a count: this Mac used it, the app version and whether it's your first day. No ID, nothing you said. Turn it off in Settings."
    public static let summary =
        "Once a day, after you dictate, Hushy tells us this Mac used it, so we can count how many Macs use Hushy. "
        + "It has no name, no id and nothing about what you said. The whole message is:"
    /// Under the example in "See what's sent": it is on by default and has its own switch.
    public static let switchNote = "This is on by default and has its own switch in Settings → Privacy & security."
    public static let firstDayNote = "On the very first day, \"first\" is true. After that it is false."
    /// An example with the build this app really is, falling back to a typical one outside a bundle.
    public static func exampleBody(build: String?) -> String {
        DailyCountBody.text(build: build.flatMap { DailyCountBody.isValidBuild($0) ? $0 : nil } ?? "2622", first: false)
            ?? "{\"v\":2,\"build\":\"2622\",\"first\":false}"
    }
}

/// A calendar day in UTC as `yyyy-MM-dd`; text order is day order.
public struct DailyCountDay: Comparable, Hashable, Sendable {
    public let text: String

    public init(_ date: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        text = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Nil for anything that is not a plausible `yyyy-MM-dd`.
    init?(text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let month = Int(parts[1]), (1...12).contains(month), let day = Int(parts[2]), (1...31).contains(day)
        else { return nil }
        self.text = text
    }

    public static func < (lhs: DailyCountDay, rhs: DailyCountDay) -> Bool { lhs.text < rhs.text }
}

/// All a Mac keeps for the daily count.
public struct DailyCountState: Codable, Equatable, Sendable {
    /// True once a ping has been counted, so `first` is sent once in this install's life.
    public var sentFirst: Bool
    /// The UTC day (`yyyy-MM-dd`) of the last counted ping.
    public var lastSentDay: String?

    public init(sentFirst: Bool = false, lastSentDay: String? = nil) {
        self.sentFirst = sentFirst
        self.lastSentDay = lastSentDay
    }
}

/// The small file behind `DailyCountState`. A missing file is a fresh install. A file that exists but
/// cannot be read counts as "already sent first", so a damaged file can never make `first` go out twice.
public struct DailyCountStore: Sendable {
    public static let fileName = "daily-count.json"
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> DailyCountState {
        guard FileManager.default.fileExists(atPath: url.path) else { return DailyCountState() }
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(DailyCountState.self, from: data),
              state.lastSentDay.map({ DailyCountDay(text: $0) != nil }) ?? true else {
            return DailyCountState(sentFirst: true, lastSentDay: nil)
        }
        return state
    }

    public func save(_ state: DailyCountState) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Sends the daily count: at most one request per Mac per UTC day, after a delivered dictation, only
/// while "Send a daily count" is on (its own `MetricsSwitch`, on by default, separate from usage numbers),
/// and never in the dictation's way. `noteDeliveredDictation` returns at once; everything else happens on a background task.
///
/// - A request that fails is tried once more, at least `retryDelay` later the same UTC day, on the
///   next delivered dictation. After that it waits for tomorrow. A 4xx answer is not retried.
/// - Turning the switch off cancels a request in flight and stops everything at once. The flags stay
///   (they are not usage data), so turning it on again never counts a first day twice.
public final class DailyCountSender: @unchecked Sendable {
    public static let retryDelay: TimeInterval = 600
    private static let log = Logger(subsystem: "app.hushy", category: "daily-count")

    private struct Running { let id: UUID; let task: Task<Void, Never> }

    private let store: DailyCountStore?
    private let endpoint: URL?
    private let build: String?
    private let transport: MetricsTransport
    private let gate: MetricsSwitch
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var running: Running?
    private var cached: DailyCountState?
    private var settledDay: DailyCountDay?
    private var failures: (day: DailyCountDay, count: Int, at: Date)?

    /// - Parameters:
    ///   - store: nil makes the sender inert (disposable runs, snapshots).
    ///   - endpoint: nil makes it inert as well; only a plain `https` address is ever contacted.
    ///   - build: the app's `CFBundleVersion`; anything the site would refuse sends nothing.
    public init(
        store: DailyCountStore?, endpoint: URL? = DailyCountEndpoint.url, build: String?, gate: MetricsSwitch,
        transport: MetricsTransport = URLSessionMetricsTransport(), now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.endpoint = endpoint.flatMap { MetricsEndpoint.parse($0.absoluteString) }
        self.build = build.flatMap { DailyCountBody.isValidBuild($0) ? $0 : nil }
        self.transport = transport
        self.gate = gate
        self.now = now
        gate.whenTurnedOff { [weak self] in self?.cancel() }
    }

    public static func bundleBuild(in bundle: Bundle = .main) -> String? {
        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// A dictation was delivered (pasted or copied). Cheap: a flag check unless today still needs its count.
    public func noteDeliveredDictation() {
        let epoch = gate.epoch
        guard gate.allows(epoch: epoch), store != nil, endpoint != nil, build != nil else { return }
        let moment = now()
        let today = DailyCountDay(moment)
        lock.withLock {
            guard running == nil, settledDay != today else { return }
            if let failed = failures, failed.day == today, moment.timeIntervalSince(failed.at) < Self.retryDelay { return }
            let id = UUID()
            running = Running(id: id, task: Task.detached(priority: .utility) { [self] in
                await attempt(epoch: epoch, today: today)
                finish(id)
            })
        }
    }

    /// Waits for a request in flight (tests).
    public func waitUntilIdle() async {
        let task = lock.withLock { running?.task }
        await task?.value
    }

    private func cancel() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            defer { running = nil }
            return running?.task
        }
        task?.cancel()
    }

    private func finish(_ id: UUID) {
        lock.withLock { if running?.id == id { running = nil } }
    }

    private func settle(_ day: DailyCountDay) { lock.withLock { settledDay = day } }

    private func attempt(epoch: Int, today: DailyCountDay) async {
        guard gate.allows(epoch: epoch), let store, let endpoint, let build else { return }
        let state = lock.withLock { cached } ?? store.load()
        lock.withLock { cached = state }
        if let last = state.lastSentDay.flatMap({ DailyCountDay(text: $0) }), last >= today { return settle(today) }
        guard let body = DailyCountBody.encode(build: build, first: !state.sentFirst) else { return }
        let outcome = await transport.post(body, to: endpoint)
        // Off (and maybe on again) while the request was out: this answer belongs to a switch that is gone.
        guard !Task.isCancelled, gate.allows(epoch: epoch) else { return }
        switch outcome {
        case .accepted:
            let updated = DailyCountState(sentFirst: true, lastSentDay: today.text)
            lock.withLock { cached = updated; failures = nil }
            do { try store.save(updated) } catch { Self.log.error("daily count: could not save the marker (\(String(describing: type(of: error)), privacy: .public))") }
            settle(today)
        case .rejected:
            settle(today)   // the site said no; asking again cannot change that
        case .retryLater:
            let count = lock.withLock { () -> Int in
                let previous = failures.flatMap { $0.day == today ? $0.count : nil } ?? 0
                failures = (today, previous + 1, now())
                return previous + 1
            }
            if count >= 2 { settle(today) }   // the first try and one retry; tomorrow is next
        }
    }
}
