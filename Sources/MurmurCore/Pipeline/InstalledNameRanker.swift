import Foundation
import Synchronization

/// How many dictations were made into one app on one day (a UTC day start). Counts only: never text.
public struct AppUseDay: Sendable, Equatable {
    public let day: Date
    public let uses: Int

    public init(day: Date, uses: Int) {
        self.day = day
        self.uses = uses
    }
}

/// What the app already knows about which installed apps this person uses. All of it is an identifier, a date or a
/// count; the caller reads it once a day, not per dictation.
public struct InstalledNameSignals: Sendable, Equatable {
    /// Dictations per day per app, from the History store (counts only).
    public var dictationDays: [String: [AppUseDay]]
    /// When Launch Services last saw each app opened (Spotlight's last-used date); needs no permission.
    public var lastOpened: [String: Date]
    /// Apps running now, and any that started since.
    public var running: Set<String>

    public static let empty = InstalledNameSignals()

    public init(
        dictationDays: [String: [AppUseDay]] = [:], lastOpened: [String: Date] = [:], running: Set<String> = []
    ) {
        self.dictationDays = dictationDays
        self.lastOpened = lastOpened
        self.running = running
    }
}

/// Orders the installed apps by how likely the person is to say their names, so the cap on app names
/// (`PipelineSettings.maxInstalledNameTerms`) cuts the apps they never use instead of the last ones alphabetically.
///
/// score(app) = usageWeight  * ln(1 + sum over days of uses * 2^(-age / halfLife))     dictated into, decayed
///            + openedWeight * 2^(-(now - lastOpened) / halfLife)                       Launch Services, in 0...1
///            + runningWeight * (running now ? 1 : 0)
///
/// The half-life is three weeks, so an app not touched for a quarter keeps about 5% of its weight. The log keeps one
/// very busy app from outranking everything else by count alone. An app with no signal scores 0, and equal scores keep
/// the order the apps came in (the scan order), so the result is deterministic. Cost: O(n) to score and O(n log n)
/// to sort, plus O(days) per app with History; `RankedInstalledApps` runs it only when the installed list, the
/// signals or the day change, never per dictation.
public enum InstalledNameRanker {
    public static let halfLifeDays = 21.0
    public static let usageWeight = 1.0
    public static let openedWeight = 1.0
    public static let runningWeight = 0.5

    /// 1 for something that happened now, 0.5 one half-life ago. A date in the future counts as now.
    static func decay(from date: Date, to now: Date) -> Double {
        let ageDays = max(0, now.timeIntervalSince(date)) / 86_400
        return exp2(-ageDays / halfLifeDays)
    }

    public static func score(_ bundleID: String, signals: InstalledNameSignals, now: Date) -> Double {
        let decayedUses = (signals.dictationDays[bundleID] ?? []).reduce(0.0) {
            $0 + Double(max(0, $1.uses)) * decay(from: $1.day, to: now)
        }
        var score = usageWeight * log(1 + decayedUses)
        if let opened = signals.lastOpened[bundleID] { score += openedWeight * decay(from: opened, to: now) }
        if signals.running.contains(bundleID) { score += runningWeight }
        return score
    }

    /// Every app, most relevant first; ties keep the incoming order.
    public static func rank(_ apps: [InstalledAppInfo], signals: InstalledNameSignals, now: Date) -> [InstalledAppInfo] {
        guard signals != .empty, apps.count > 1 else { return apps }
        let scored = apps.enumerated().map { (index: $0.offset, score: score($0.element.bundleID, signals: signals, now: now)) }
        let order = scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return order.map { apps[$0.index] }
    }
}

/// The ranked installed apps, kept between dictations. The order is recomputed only when the installed list changes,
/// new signals arrive, an app starts running or the day changes; a dictation just reads it.
public final class RankedInstalledApps: Sendable {
    private struct Key: Equatable {
        let source: [InstalledAppInfo]
        let day: Int
        let revision: Int
    }

    private struct State {
        var signals = InstalledNameSignals.empty
        var revision = 0
        var loadedAt: Date?
        var isLoading = false
        var key: Key?
        var ranked: [InstalledAppInfo] = []
    }

    private let state = Mutex(State())
    /// The signals are read again at most this often.
    public static let signalsMaxAge: TimeInterval = 86_400

    public init() {}

    /// The apps in rank order (the incoming order while no signals have loaded).
    public func apps(from installed: [InstalledAppInfo], now: Date = Date()) -> [InstalledAppInfo] {
        state.withLock { state in
            let key = Key(source: installed, day: Int(now.timeIntervalSince1970 / 86_400), revision: state.revision)
            if state.key == key { return state.ranked }
            state.ranked = InstalledNameRanker.rank(installed, signals: state.signals, now: now)
            state.key = key
            return state.ranked
        }
    }

    /// True once per `signalsMaxAge`: the caller that gets true must read the signals and call `load`.
    public func beginReload(now: Date = Date()) -> Bool {
        state.withLock { state in
            if state.isLoading { return false }
            if let last = state.loadedAt, now.timeIntervalSince(last) < Self.signalsMaxAge { return false }
            state.isLoading = true
            return true
        }
    }

    /// Takes freshly read signals, running apps included (so an app that quit since the last load drops out).
    public func load(_ signals: InstalledNameSignals, now: Date = Date()) {
        state.withLock { state in
            if signals != state.signals { state.revision += 1 }
            state.signals = signals
            state.loadedAt = now
            state.isLoading = false
        }
    }

    /// A read that failed: try again at the next chance instead of waiting a day.
    public func abandonReload() {
        state.withLock { $0.isLoading = false }
    }

    /// An app started running. Cheap; re-ranks at the next read only if the app was not known to be running.
    public func noteRunning(_ bundleID: String) {
        state.withLock { state in
            if state.signals.running.insert(bundleID).inserted { state.revision += 1 }
        }
    }
}
