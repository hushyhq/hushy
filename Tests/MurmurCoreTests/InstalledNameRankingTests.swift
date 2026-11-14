import Foundation
import Testing
@testable import MurmurCore

/// Invented app names only. The ranking decides which installed names survive the cap of
/// `PipelineSettings.maxInstalledNameTerms`; these tests build a crowded Mac and check who survives.
@Suite("Installed names are ranked before the cap", .serialized)
struct InstalledNameRankingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    /// `count` distinctive names in alphabetical (scan) order: Zorbix001, Zorbix002, ...
    private func crowdedMac(_ count: Int = 300) -> [InstalledAppInfo] {
        (1...count).map { InstalledAppInfo(bundleID: "test.zorbix\($0)", name: "Zorbix" + String(format: "%03d", $0)) }
    }

    private func uses(_ n: Int, daysAgo: Double = 0) -> [AppUseDay] {
        [AppUseDay(day: now.addingTimeInterval(-daysAgo * day), uses: n)]
    }

    private func installedTerms(_ apps: [InstalledAppInfo]) -> [String] {
        PipelineSettings(installedApps: apps).vocabulary.terms.filter(\.installedApp).map(\.text)
    }

    // MARK: The cap, before and after

    @Test("an app used often but alphabetically last makes the cut")
    func heavilyUsedLastMakesTheCut() {
        let apps = crowdedMac()
        let favourite = apps.last!
        #expect(!installedTerms(apps).contains(favourite.name), "without ranking the cap cuts it")
        let signals = InstalledNameSignals(dictationDays: [favourite.bundleID: uses(40, daysAgo: 1)])
        let ranked = InstalledNameRanker.rank(apps, signals: signals, now: now)
        #expect(ranked.first == favourite)
        let terms = installedTerms(ranked)
        #expect(terms.contains(favourite.name))
        #expect(terms.count == PipelineSettings.maxInstalledNameTerms)
    }

    @Test("a never-used app drops when the Mac has more than the cap")
    func neverUsedDrops() {
        let apps = crowdedMac()
        let lastKept = apps[PipelineSettings.maxInstalledNameTerms - 1]
        #expect(installedTerms(apps).contains(lastKept.name), "today the 150th in scan order is kept")
        let used = apps.suffix(5)
        let signals = InstalledNameSignals(dictationDays: Dictionary(uniqueKeysWithValues: used.map { ($0.bundleID, uses(3, daysAgo: 2)) }))
        let terms = installedTerms(InstalledNameRanker.rank(apps, signals: signals, now: now))
        #expect(!terms.contains(lastKept.name))
        #expect(used.allSatisfy { terms.contains($0.name) })
        #expect(terms.count == PipelineSettings.maxInstalledNameTerms)
    }

    @Test("ordinary-word names are still filtered, and do not take a slot from a distinctive name")
    func ordinaryWordsStayOut() {
        var apps = crowdedMac(200)
        apps.append(InstalledAppInfo(bundleID: "test.notes", name: "Notes"))
        apps.append(InstalledAppInfo(bundleID: "test.mail", name: "Mail"))
        let signals = InstalledNameSignals(
            dictationDays: ["test.notes": uses(500), "test.mail": uses(500)], running: ["test.notes"])
        let ranked = InstalledNameRanker.rank(apps, signals: signals, now: now)
        #expect(Set(ranked.prefix(2).map(\.name)) == ["Notes", "Mail"])
        let terms = installedTerms(ranked)
        #expect(!terms.contains("Notes"))
        #expect(!terms.contains("Mail"))
        #expect(terms.count == PipelineSettings.maxInstalledNameTerms)
    }

    // MARK: Stability and the score

    @Test("equal scores keep the incoming order, and ranking twice changes nothing")
    func stableForTies() {
        let apps = crowdedMac(40)
        let tiedIDs = [apps[30], apps[3], apps[17]].map(\.bundleID)
        let signals = InstalledNameSignals(dictationDays: Dictionary(uniqueKeysWithValues: tiedIDs.map { ($0, uses(2)) }))
        let ranked = InstalledNameRanker.rank(apps, signals: signals, now: now)
        #expect(ranked.prefix(3).map(\.bundleID) == [apps[3], apps[17], apps[30]].map(\.bundleID))
        #expect(Array(ranked.dropFirst(3)).map(\.bundleID) == apps.map(\.bundleID).filter { !tiedIDs.contains($0) })
        #expect(InstalledNameRanker.rank(ranked, signals: signals, now: now) == ranked)
        #expect(InstalledNameRanker.rank(apps, signals: signals, now: now) == ranked)
    }

    @Test("with no signal the scan order stands")
    func noSignalsKeepsScanOrder() {
        let apps = crowdedMac(25)
        #expect(InstalledNameRanker.rank(apps, signals: .empty, now: now) == apps)
        #expect(InstalledNameRanker.rank(apps, signals: InstalledNameSignals(running: ["test.nothere"]), now: now) == apps)
    }

    @Test("use decays with a three-week half-life: recent light use outranks old heavy use")
    func decay() {
        let half = InstalledNameRanker.halfLifeDays
        let oneHalfLife = InstalledNameRanker.score("a", signals: InstalledNameSignals(dictationDays: ["a": uses(10, daysAgo: half)]), now: now)
        let fresh = InstalledNameRanker.score("a", signals: InstalledNameSignals(dictationDays: ["a": uses(10)]), now: now)
        #expect(abs(oneHalfLife - log(1 + 5)) < 1e-9)
        #expect(abs(fresh - log(1 + 10)) < 1e-9)
        let signals = InstalledNameSignals(dictationDays: ["old": uses(10, daysAgo: 80), "new": uses(2, daysAgo: 1)])
        let ranked = InstalledNameRanker.rank(
            [InstalledAppInfo(bundleID: "old", name: "Old"), InstalledAppInfo(bundleID: "new", name: "New")], signals: signals, now: now)
        #expect(ranked.map(\.bundleID) == ["new", "old"])
    }

    @Test("last opened (Launch Services) and running apps lift an app that was never dictated into")
    func openedAndRunning() {
        let apps = crowdedMac(10)
        let signals = InstalledNameSignals(
            lastOpened: [apps[8].bundleID: now.addingTimeInterval(-2 * day), apps[6].bundleID: now.addingTimeInterval(-200 * day)],
            running: [apps[9].bundleID])
        let ranked = InstalledNameRanker.rank(apps, signals: signals, now: now).map(\.bundleID)
        #expect(Array(ranked.prefix(3)) == [apps[8], apps[9], apps[6]].map(\.bundleID))
    }

    @Test("a future date counts as now, and a negative count as none")
    func clockSkew() {
        let future = InstalledNameSignals(lastOpened: ["a": now.addingTimeInterval(5 * day)])
        #expect(InstalledNameRanker.score("a", signals: future, now: now) == InstalledNameRanker.openedWeight)
        let negative = InstalledNameSignals(dictationDays: ["a": uses(-4)])
        #expect(InstalledNameRanker.score("a", signals: negative, now: now) == 0)
    }

    @Test("ranking 5,000 apps stays cheap")
    func scales() {
        let apps = crowdedMac(5_000)
        let signals = InstalledNameSignals(dictationDays: Dictionary(uniqueKeysWithValues: apps.indices.filter { $0 % 7 == 0 }.map { (apps[$0].bundleID, uses($0 % 13 + 1, daysAgo: Double($0 % 60))) }))
        let start = Date()
        let ranked = InstalledNameRanker.rank(apps, signals: signals, now: now)
        #expect(ranked.count == 5_000)
        #expect(Date().timeIntervalSince(start) < 1.0)
    }

    // MARK: The cache

    @Test("the order is recomputed when the list, the signals or the day change, and not otherwise")
    func cache() {
        let cache = RankedInstalledApps()
        let apps = crowdedMac(20)
        #expect(cache.apps(from: apps, now: now) == apps)
        cache.load(InstalledNameSignals(dictationDays: [apps[19].bundleID: uses(9)]), now: now)
        let ranked = cache.apps(from: apps, now: now)
        #expect(ranked.first == apps[19])
        #expect(cache.apps(from: apps, now: now) == ranked)
        // A new list is ranked too: the app is still first, the new app lands after the unsignalled ones.
        let more = apps + [InstalledAppInfo(bundleID: "test.zorbix999", name: "Zorbix999")]
        #expect(cache.apps(from: more, now: now).first == apps[19])
        #expect(cache.apps(from: more, now: now).last?.bundleID == "test.zorbix999")
        cache.noteRunning(apps[2].bundleID)
        #expect(cache.apps(from: apps, now: now).prefix(2).map(\.bundleID) == [apps[19].bundleID, apps[2].bundleID])
        // The same use five months later weighs less than a fresh running app; the day key re-ranks it.
        let later = now.addingTimeInterval(150 * day)
        #expect(cache.apps(from: apps, now: later).first == apps[2])
    }

    @Test("signals are read once a day, one reader at a time")
    func reloadSchedule() {
        let cache = RankedInstalledApps()
        #expect(cache.beginReload(now: now))
        #expect(!cache.beginReload(now: now), "a read is already under way")
        cache.abandonReload()
        #expect(cache.beginReload(now: now), "a failed read is tried again")
        cache.load(.empty, now: now)
        #expect(!cache.beginReload(now: now.addingTimeInterval(RankedInstalledApps.signalsMaxAge - 60)))
        #expect(cache.beginReload(now: now.addingTimeInterval(RankedInstalledApps.signalsMaxAge + 60)))
    }

    // MARK: Reading the counts

    @Test("History gives counts per app and day: counted dictations in the window, never Hushy itself or text")
    func storeCounts() throws {
        let store = try Store()
        let at = Date()
        func save(_ app: String?, daysAgo: Double, status: Dictation.Status = .inserted) throws {
            _ = try store.save(Dictation(
                createdAt: at.addingTimeInterval(-daysAgo * day), rawText: "one two", text: "one two", appBundleID: app,
                appName: nil, durationSeconds: 1, fixes: 0, status: status))
        }
        try save("test.zorbix1", daysAgo: 0.1)
        try save("test.zorbix1", daysAgo: 0.2)
        try save("test.zorbix1", daysAgo: 5)
        try save("test.zorbix2", daysAgo: 3)
        try save("test.zorbix2", daysAgo: 3, status: .failed)
        try save("test.zorbix3", daysAgo: Double(Store.appUsageWindowDays + 10))
        try save(Insights.ownBundleID, daysAgo: 1)
        try save(nil, daysAgo: 1)
        let days = try store.appUseDays(now: at)
        #expect(days["test.zorbix1"]?.map(\.uses).reduce(0, +) == 3)
        #expect(days["test.zorbix2"]?.map(\.uses).reduce(0, +) == 1)
        #expect(days["test.zorbix3"] == nil)
        #expect(days[Insights.ownBundleID] == nil)
        #expect(days.count == 2)
        let ranked = InstalledNameRanker.rank(
            [InstalledAppInfo(bundleID: "test.zorbix2", name: "Zorbix2"), InstalledAppInfo(bundleID: "test.zorbix1", name: "Zorbix1")],
            signals: InstalledNameSignals(dictationDays: days), now: at)
        #expect(ranked.map(\.bundleID) == ["test.zorbix1", "test.zorbix2"])
    }
}
