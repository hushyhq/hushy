import Foundation
import Testing
@testable import MurmurCore

/// One-shot seeding helper for the task's manual verification step (seed a HUSHY_HOME-style
/// temp store with fake rows, then inspect it with `sqlite3` outside of Swift Testing's
/// process). Disabled so it never runs as part of the normal suite/CI; enabled and re-run by
/// hand only when that manual check needs to be regenerated.
@Suite("Manual verification seed (not part of CI coverage)")
struct ManualVerificationSeedTests {
    @Test("seeds /tmp/hushy-manual-verify with fake dictation rows", .disabled("manual-only helper"))
    func seedManualVerificationStore() throws {
        let root = URL(fileURLWithPath: "/tmp/hushy-manual-verify", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try Store(url: root.appendingPathComponent("murmur.sqlite"))
        for index in 0..<3 {
            _ = try store.save(Dictation(
                rawText: "raw \(index)", text: "hello world \(index)", durationSeconds: 2, status: .inserted))
        }
    }
}
