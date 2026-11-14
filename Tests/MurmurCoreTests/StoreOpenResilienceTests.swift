import Foundation
import GRDB
import Testing
@testable import MurmurCore

/// A database that cannot open must never turn into silent data loss, and must never be
/// rewritten or removed by the attempt to open it.
@Suite("Opening the on-disk store")
struct StoreOpenResilienceTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hushy-open-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("murmur.sqlite")
    }

    @Test("a file another connection holds locked for a moment still opens, because the store waits")
    func waitsForABusyFile() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let holder = try DatabaseQueue(path: url.path)
        try holder.write { try $0.execute(sql: "CREATE TABLE seed (id INTEGER)") }

        let locked = DispatchSemaphore(value: 0)
        let release = DispatchQueue(label: "hushy.test.lock")
        release.async {
            try? holder.writeWithoutTransaction { db in
                try db.execute(sql: "BEGIN EXCLUSIVE")
                locked.signal()
                Thread.sleep(forTimeInterval: 0.6)
                try db.execute(sql: "COMMIT")
            }
        }
        locked.wait()

        #expect(throws: Never.self) { _ = try Store(url: url) }
    }

    @Test("a transient open failure is retried before the open is given up")
    func retriesTransientFailures() throws {
        var calls = 0
        let store = try StoreOpener.open(url: tempFile(), attempts: 3, retryDelay: 0) { _ in
            calls += 1
            if calls < 3 { throw DatabaseError(resultCode: .SQLITE_BUSY) }
            return try Store()
        }
        #expect(calls == 3)
        #expect(try store.recentDictations(limit: 1).isEmpty)
    }

    @Test("an open that keeps failing throws instead of returning a store, after every attempt")
    func givesUpLoudly() throws {
        var calls = 0
        #expect(throws: DatabaseError.self) {
            _ = try StoreOpener.open(url: tempFile(), attempts: 3, retryDelay: 0) { _ in
                calls += 1
                throw DatabaseError(resultCode: .SQLITE_BUSY)
            }
        }
        #expect(calls == 3)
    }

    @Test("a file that is not a database fails on the first attempt, with no retry delay")
    func notADatabaseIsNotRetried() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("this is plain text, not a database file, and long enough to fill a header....".utf8).write(to: url)
        var calls = 0

        #expect(throws: DatabaseError.self) {
            _ = try StoreOpener.open(url: url, attempts: 3, retryDelay: 0) { target in
                calls += 1
                return try Store(url: target)
            }
        }
        #expect(calls == 1)
    }

    @Test("a database that cannot be read is left byte for byte as it was")
    func failedOpenLeavesFileAlone() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let garbage = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try garbage.write(to: url)

        #expect(throws: (any Error).self) { _ = try StoreOpener.open(url: url, attempts: 2, retryDelay: 0) }

        #expect(try Data(contentsOf: url) == garbage)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(names == ["murmur.sqlite"], "nothing was moved, renamed or added: \(names)")
    }
}
