import Foundation

/// Where the time went between key release and the text appearing, in milliseconds. Numbers only:
/// kept with the History entry so a slow dictation can explain itself. The stages follow one another,
/// so the four figures add up to the dictation's "Typed in" time, give or take a few milliseconds of rounding (`cleanupMs` leaves out the second pass).
public struct DictationTimeSplit: Codable, Sendable, Equatable, Hashable {
    /// Key release to the recognizer's final text.
    public let speechMs: Int
    /// Cleanup after the recognizer, without the second pass below.
    public let cleanupMs: Int
    /// Time the second cleanup pass (a different model asked about leftover filler) added after the release.
    /// Nil when no second pass ran.
    public let secondPassMs: Int?
    /// Handing the text to the app.
    public let insertMs: Int

    public init(speechMs: Int, cleanupMs: Int, secondPassMs: Int? = nil, insertMs: Int) {
        self.speechMs = max(0, speechMs)
        self.cleanupMs = max(0, cleanupMs)
        self.secondPassMs = secondPassMs.map { max(0, $0) }
        self.insertMs = max(0, insertMs)
    }

    /// From the three marked stages and what the cleanup model did for each group. Only a group cleaned after
    /// the release counts towards the second pass (`.fresh`, or a short dictation with no source): one served from
    /// the prewarm cost nothing after the release, and one still being waited on at release (`.prewarmAwaited`)
    /// ran partly before it, with no record of which pass the wait belonged to, so its wait stays in the cleanup
    /// figure. The figure never exceeds the cleanup stage itself.
    public init(speechMs: Int, cleanupStageMs: Int, insertMs: Int, groups: [GroupTrace]) {
        let second = groups.filter { $0.source == nil || $0.source == .fresh }.reduce(0) { $0 + ($1.secondPassMs ?? 0) }
        let counted = min(second, max(0, cleanupStageMs))
        self.init(
            speechMs: speechMs, cleanupMs: cleanupStageMs - counted, secondPassMs: counted > 0 ? counted : nil,
            insertMs: insertMs)
    }

    /// Seconds with one decimal ("5.7 s"): the unit History shows times in.
    public static func seconds(_ milliseconds: Int) -> String {
        tenthsText(roundedTenths(milliseconds))
    }

    private static func roundedTenths(_ milliseconds: Int) -> Int {
        Int((Double(max(0, milliseconds)) / 100).rounded(.toNearestOrAwayFromZero))
    }

    private static func tenthsText(_ tenths: Int) -> String { "\(tenths / 10).\(tenths % 10) s" }

    /// The parts in tenths of a second, in the order speech, cleanup, second pass (if any), typing, rounded so that
    /// they add up to the total as `seconds(totalMs)` shows it (largest remainder, so no part moves by a whole
    /// tenth). `totalMs` is the "Typed in" time; the parts are scaled to it if they differ by a few milliseconds.
    func displayedTenths(totalMs: Int) -> [Int] {
        let parts = [speechMs, cleanupMs] + (secondPassMs.map { [$0] } ?? []) + [insertMs]
        let sum = parts.reduce(0, +)
        let total = totalMs > 0 ? totalMs : sum
        let target = Self.roundedTenths(total)
        guard sum > 0 else { return parts.map { _ in 0 } }
        let exact = parts.map { Double($0) * Double(total) / Double(sum) / 100 }
        var tenths = exact.map { Int($0.rounded(.down)) }
        let order = exact.indices.sorted { (exact[$0] - exact[$0].rounded(.down)) > (exact[$1] - exact[$1].rounded(.down)) }
        var missing = target - tenths.reduce(0, +)
        for index in order where missing > 0 {
            tenths[index] += 1
            missing -= 1
        }
        return tenths
    }

    /// The quiet line under History's stats row. `totalMs` is the dictation's "Typed in" time, so the parts shown
    /// add up to the total shown.
    public func plainLine(totalMs: Int) -> String {
        let tenths = displayedTenths(totalMs: totalMs)
        var next = tenths.makeIterator()
        func part(_ name: String) -> String { "\(name) \(Self.tenthsText(next.next() ?? 0))" }
        var parts = [part("recognition"), part("cleanup")]
        if secondPassMs != nil { parts.append(part("second cleanup pass")) }
        parts.append(part("typing"))
        return "After release: " + parts.joined(separator: " · ")
    }
}
