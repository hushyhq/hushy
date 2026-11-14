import Foundation
import Testing
@testable import MurmurCore

/// The wire contract between the app and the server. `Tests/Fixtures/usage-batch-v4.json` is the exact body
/// the app sends for the fully populated fixture batch. This test fails if the app stops writing those bytes;
/// the site Worker's tests (`site/worker/usage.test.js`) read the same file and must accept it, so the two
/// sides cannot drift apart unseen. To update the file after a deliberate schema change, run this suite once
/// with `HUSHY_WRITE_USAGE_FIXTURE=1`, then review the diff.
@Suite("Usage metrics: wire contract with the server", .timeLimit(.minutes(1)))
struct UsageBatchContractTests {
    static let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/usage-batch-v4.json")

    @Test("the committed body is what the app writes for the fully populated batch, and it reads back to the same batch")
    func committedBody() throws {
        let body = try UsageMetricsFixtures.fullyPopulatedBatch().encodedBody()
        if ProcessInfo.processInfo.environment["HUSHY_WRITE_USAGE_FIXTURE"] == "1" { try body.write(to: Self.fixtureURL) }
        let committed = try Data(contentsOf: Self.fixtureURL)
        #expect(committed == body, "the app's batch changed: update Tests/Fixtures/usage-batch-v4.json and the server's schema together")
        let decoded = try JSONDecoder().decode(DailyMetricsBatch.self, from: committed)
        #expect(try decoded.encodedBody() == committed)
        #expect(decoded.schemaVersion == 4 && decoded.editRate?.total ?? 0 > 0)
    }

    @Test("the body stays under the size the server accepts")
    func size() throws {
        #expect(try UsageMetricsFixtures.fullyPopulatedBatch().encodedBody().count < MetricsLimits.maximumEncodedBatchBytes)
    }
}
