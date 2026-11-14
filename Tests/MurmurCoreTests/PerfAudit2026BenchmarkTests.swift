import Foundation
import GRDB
import NaturalLanguage
import Testing
@testable import MurmurCore

/// Measurements for docs/engineering/perf-audit-2026-09.md, following the same convention as
/// `InsightsBenchmarkTests`/`StorePagingBenchmarkTests`: disabled by default (not part of the
/// quick gate or CI), printed to stdout when run explicitly. Every store used here is a
/// disposable SQLite file under the system temp directory (never `AppPaths`/`MURMUR_HOME`/the
/// user's real database) or an in-memory `Store()`.
///
/// `.disabled` traits skip regardless of `--filter`, so to get numbers, delete
/// `.disabled(...)` below locally, run `swift test -c release --filter PerfAudit2026BenchmarkTests`,
/// then revert — do not commit it enabled.
@Suite("Perf audit 2026-09 benchmarks", .disabled("run explicitly for perf numbers; not part of CI"))
struct PerfAudit2026BenchmarkTests {
    // MARK: - Helpers

    static func measureMs(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now()
        try body()
        let end = DispatchTime.now()
        return Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    static func measureUs(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now()
        try body()
        let end = DispatchTime.now()
        return Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000
    }

    /// Resident memory (bytes) of the current process, via `task_info`/`mach_task_basic_info` —
    /// the standard macOS approach for measuring a process's own footprint.
    static func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    static func scratchStore() throws -> (Store, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-perf-audit-\(UUID().uuidString)", isDirectory: true)
        let store = try Store(url: dir.appendingPathComponent("bench.sqlite"))
        return (store, dir)
    }

    // MARK: - 1. Dictation hot path: TextCleaner end to end at realistic lengths

    @Test("TextCleaner.clean: 12 / 40 / 120 word dictations, 500 iterations each")
    func hotPathCleanupScaling() {
        let short = "so um i think we should go with the medium plan actually no the large one"
        let medium = String(repeating: "we need to schedule the meeting for tuesday at three pm and invite sarah and tom, ", count: 4)
        let long = String(repeating: "the quarterly report shows revenue increased by fifteen percent and we spent forty five thousand dollars on marketing, ", count: 10)

        for (label, text) in [("~12 words", short), ("~40 words", medium), ("~120 words", long)] {
            let cleaner = TextCleaner(options: CleanupOptions(level: .clean))
            // Warm-up: RegexCache is a process-wide cache, so the very first call anywhere pays
            // compilation; warm it here so every case is measured warm, matching real usage
            // where cleanup has already run many times before a given dictation.
            _ = cleaner.clean(text)
            let iterations = 500
            let elapsedMs = Self.measureMs {
                for _ in 0..<iterations { _ = cleaner.clean(text) }
            }
            let perCallUs = (elapsedMs * 1000) / Double(iterations)
            print("[hotpath] TextCleaner.clean (\(label)): \(String(format: "%.1f", perCallUs)) us/call")
        }
    }

    // MARK: - 2. WordDiff LCS cost at realistic and worst-case lengths

    @Test("WordDiff.keptFlags: 40 / 120 / 300 word transcripts")
    func wordDiffScaling() {
        for wordCount in [40, 120, 300] {
            let original = (0..<wordCount).map { "word\($0)" }.joined(separator: " ")
            // Cleaned differs from original in ~10% of positions, matching typical cleanup edits
            // (not a pure no-op, not a full rewrite).
            let words = (0..<wordCount).map { $0 % 10 == 0 ? "changed\($0)" : "word\($0)" }
            let cleaned = words.joined(separator: " ")
            let iterations = 200
            let elapsedMs = Self.measureMs {
                for _ in 0..<iterations { _ = WordDiff.keptFlags(original: original, cleaned: cleaned) }
            }
            let perCallUs = (elapsedMs * 1000) / Double(iterations)
            print("[hotpath] WordDiff.keptFlags (\(wordCount) words): \(String(format: "%.1f", perCallUs)) us/call")
        }
    }

    // MARK: - 3. NLLanguageRecognizer: per-call construction + processString cost

    @Test("LanguageDetector.detect: cost of a fresh NLLanguageRecognizer per call")
    func languageDetectorPerCallCost() {
        let text = "We need to schedule the quarterly review for next Tuesday and invite the whole team."
        _ = LanguageDetector.detect(text) // warm up ICU/NL data loading once, like real usage.
        let iterations = 200
        let elapsedMs = Self.measureMs {
            for _ in 0..<iterations { _ = LanguageDetector.detect(text) }
        }
        let perCallUs = (elapsedMs * 1000) / Double(iterations)
        print("[hotpath] LanguageDetector.detect (fresh NLLanguageRecognizer/call): \(String(format: "%.1f", perCallUs)) us/call")

        // Compare against reusing a single NLLanguageRecognizer instance across calls (reset
        // between uses) to quantify how much of the cost is allocation vs analysis.
        let recognizer = NLLanguageRecognizer()
        let reusedMs = Self.measureMs {
            for _ in 0..<iterations {
                recognizer.reset()
                recognizer.processString(text)
                _ = recognizer.dominantLanguage
            }
        }
        let reusedUs = (reusedMs * 1000) / Double(iterations)
        print("[hotpath] NLLanguageRecognizer reused + reset(): \(String(format: "%.1f", reusedUs)) us/call")
    }

    // MARK: - 4. FTS search: hydration cost, rank-first vs current

    /// Old implementation, inlined verbatim (pre-perf-audit-2026-09 `Store.searchDictations`):
    /// a single query joining `dictation_fts` straight to `dictation.*`, filtering and then
    /// sorting the full joined+hydrated row set. Kept here only so this benchmark can report a
    /// true before/after against the new two-step `Store.searchDictations` below, without
    /// needing to `git stash` the production change to get a baseline number.
    private static func searchDictationsOldJoin(_ db: Database, query: String, limit: Int) throws -> [Dictation] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        let sql = """
            SELECT dictation.* FROM dictation
            JOIN dictation_fts ON dictation_fts.rowid = dictation.id
            WHERE dictation_fts MATCH ?
            ORDER BY dictation.createdAt DESC LIMIT ?
            """
        return try Dictation.fetchAll(db, sql: sql, arguments: [pattern, limit])
    }

    @Test("searchDictations (FTS5): old single-JOIN query vs new two-step, at realistic and high match rates")
    func searchDictationsScaling() throws {
        // matchRate 0.05: realistic ("quarterly report" mentioned in ~5% of dictations).
        // matchRate 0.60: stress case (a common word/name that shows up in most dictations),
        // where the plan's original 37-44ms estimate came from — see performance-plan.md §1.4.
        for (rowCount, matchRate) in [(20_000, 0.05), (50_000, 0.05), (50_000, 0.60)] {
            let (store, dir) = try Self.scratchStore()
            defer { try? FileManager.default.removeItem(at: dir) }
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            let matchEvery = max(1, Int(1.0 / matchRate))
            try store.writer.write { db in
                for index in 0..<rowCount {
                    let mentionsQuery = index % matchEvery == 0
                    let body = mentionsQuery
                        ? "quarterly report row \(index) about the project status"
                        : "unrelated note row \(index) about lunch plans and the weather"
                    var d = Dictation(
                        createdAt: base.addingTimeInterval(Double(index) * 30),
                        rawText: body, text: body.capitalized + ".",
                        durationSeconds: 3.0, status: .inserted)
                    try d.save(db)
                }
            }
            let matchCount = try store.writer.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dictation_fts WHERE dictation_fts MATCH ?", arguments: ["quarterly report"])
            } ?? 0
            let label = "\(rowCount) rows, \(matchCount) match (\(Int(matchRate * 100))%)"

            let oldMs = try store.writer.read { db in
                try Self.measureMs { _ = try Self.searchDictationsOldJoin(db, query: "quarterly report", limit: 100) }
            }
            let newMs = try Self.measureMs {
                _ = try store.searchDictations("quarterly report", limit: 100)
            }
            print("[fts] \(label): old (single JOIN, sort full hydrated set) = \(String(format: "%.1f", oldMs)) ms, new (rank ids first, hydrate only the page) = \(String(format: "%.1f", newMs)) ms")
        }
    }

    // MARK: - 5. EXPLAIN QUERY PLAN: confirm index usage for History/Notes/folders/speakers

    @Test("EXPLAIN QUERY PLAN: History, Notes search, folders, speaker segments")
    func explainQueryPlans() throws {
        let (store, dir) = try Self.scratchStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try store.writer.write { db in
            for index in 0..<2_000 {
                var d = Dictation(
                    createdAt: base.addingTimeInterval(Double(index) * 30),
                    rawText: "row \(index)", text: "Row \(index).",
                    appBundleID: index % 5 == 0 ? "com.a.app" : "com.b.app",
                    durationSeconds: 2.0,
                    status: index % 7 == 0 ? .failed : .inserted)
                try d.save(db)
            }
        }

        func explain(_ label: String, _ sql: String, _ args: StatementArguments = StatementArguments()) throws {
            try store.writer.read { db in
                let rows = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)", arguments: args)
                let plan = rows.map { $0["detail"] as String }.joined(separator: " | ")
                print("[explain] \(label): \(plan)")
            }
        }

        try explain(
            "History keyset page (createdAt DESC)",
            "SELECT * FROM dictation ORDER BY createdAt DESC, id DESC LIMIT 100")
        try explain(
            "History status filter",
            "SELECT * FROM dictation WHERE status = ? ORDER BY createdAt DESC LIMIT 100",
            ["failed"])
        try explain(
            "History app filter",
            "SELECT * FROM dictation WHERE appBundleID = ? ORDER BY createdAt DESC LIMIT 100",
            ["com.a.app"])
        try explain(
            "lastDictation (status != cancelled, text != '')",
            "SELECT * FROM dictation WHERE status != ? AND text != '' ORDER BY createdAt DESC LIMIT 1",
            ["cancelled"])
        try explain(
            "Notes search (FTS + rank)",
            "SELECT note.* FROM note JOIN note_fts ON note_fts.rowid = note.id WHERE note_fts MATCH ? ORDER BY rank LIMIT ?",
            ["test", 50])
        try explain(
            "Dictation search (FTS, current: order by createdAt)",
            "SELECT dictation.* FROM dictation JOIN dictation_fts ON dictation_fts.rowid = dictation.id WHERE dictation_fts MATCH ? ORDER BY dictation.createdAt DESC LIMIT ?",
            ["test", 100])
        try explain(
            "note_segment by noteId ordinal",
            "SELECT * FROM note_segment WHERE noteId = ? ORDER BY ordinal", [1])
        try explain(
            "noteCountsByFolder (GROUP BY folderId)",
            "SELECT folderId, COUNT(*) FROM note WHERE folderId IS NOT NULL GROUP BY folderId")
    }

    // MARK: - 6. Memory over a simulated 1-hour note

    @Test("Memory: simulated 1-hour note transcript + segments accumulation")
    func memoryOverOneHourNote() throws {
        let before = Self.residentMemoryBytes()

        // ~150 words/minute average speaking rate * 60 minutes, chunked into ~10s segments
        // (matching NoteRecorder's ChunkSplitter granularity from the streaming design doc).
        let totalWords = 150 * 60
        let segmentCount = 360 // one every ~10s across an hour
        var segments: [(start: Double, end: Double, text: String)] = []
        segments.reserveCapacity(segmentCount)
        var transcript = ""
        transcript.reserveCapacity(totalWords * 6)
        let wordsPerSegment = totalWords / segmentCount
        for i in 0..<segmentCount {
            let text = (0..<wordsPerSegment).map { "word\($0 + i * wordsPerSegment)" }.joined(separator: " ") + ". "
            transcript += text
            segments.append((start: Double(i) * 10, end: Double(i + 1) * 10, text: text))
        }

        let after = Self.residentMemoryBytes()
        let deltaMB = Double(after &- before) / 1_048_576
        print("[memory] 1-hour note (transcript + \(segmentCount) segments, \(totalWords) words): resident delta \(String(format: "%.2f", deltaMB)) MB")
        print("[memory] transcript length: \(transcript.count) chars, \(segments.count) segments retained")
        #expect(!transcript.isEmpty)
    }

    // MARK: - 7. Insights.compute at 100k rows (scale beyond the existing 50k benchmark)

    @Test("Store.computeInsights vs old full-fetch compute at 100k rows")
    func insightsAt100k() throws {
        let (store, dir) = try Self.scratchStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let apps = ["com.a.app", "com.b.app", "com.c.app", nil] as [String?]
        try store.writer.write { db in
            for index in 0..<100_000 {
                var d = Dictation(
                    createdAt: base.addingTimeInterval(Double(index) * 30),
                    rawText: "bench row \(index)", text: "Bench row \(index).",
                    appBundleID: apps[index % apps.count],
                    durationSeconds: 3.0, status: .inserted)
                try d.save(db)
            }
        }
        let oldMs = try Self.measureMs {
            let items = try store.allDictations()
            _ = Insights.compute(from: items)
        }
        let newMs = try Self.measureMs {
            _ = try store.computeInsights()
        }
        print("[insights] 100,000 rows: old (fetch+compute) = \(String(format: "%.0f", oldMs)) ms, new (SQL aggregates) = \(String(format: "%.0f", newMs)) ms")
    }
}
