#if DEBUG
import Foundation

enum MockMicStatus: String, Codable, Equatable {
    case pass, fail, skipped
    /// Numbers were measured but nothing was enforced (external clips).
    case reported
    /// The capture was silent: a microphone-permission block.
    case blocked
}

struct MockMicCheck: Codable, Equatable {
    var name: String
    var passed: Bool
    /// False for external clips, where thresholds are reported but not enforced.
    var enforced: Bool
    var value: String
    var threshold: String?
}

struct MockMicScenarioResult: Codable, Equatable {
    var id: String
    var title: String
    var status: MockMicStatus
    var seconds: Double
    var detail: String
    var checks: [MockMicCheck]
    var metrics: [String: Double]
    /// Reference and output text. Present for synthetic clips only.
    var texts: [String: String]?

    var summaryLine: String {
        let label = status.rawValue.uppercased()
        let detailPart = detail.isEmpty ? "" : "  \(detail)"
        return "[\(label)] \(id) (\(String(format: "%.1f", seconds)) s)\(detailPart)"
    }
}

struct MockMicReport: Codable, Equatable {
    var version: Int
    var source: String
    var scoring: String
    var device: String?
    var cleanupBackend: String
    var scenarios: [MockMicScenarioResult]

    static func status(for checks: [MockMicCheck]) -> MockMicStatus {
        let enforced = checks.filter(\.enforced)
        if enforced.isEmpty { return .reported }
        return enforced.allSatisfy(\.passed) ? .pass : .fail
    }

    var exitCode: Int32 {
        let statuses = scenarios.map(\.status)
        // A run that produced no scenario at all proved nothing, so it is a failure, not "skipped".
        if statuses.isEmpty { return MockMicExit.failed }
        if statuses.contains(.blocked) { return MockMicExit.blocked }
        if statuses.contains(.fail) { return MockMicExit.failed }
        if statuses.allSatisfy({ $0 == .skipped }) { return MockMicExit.skipped }
        return MockMicExit.ok
    }

    func with(scenarios: [MockMicScenarioResult]) -> MockMicReport {
        var copy = self
        copy.scenarios = scenarios
        return copy
    }

    func withoutTexts() -> MockMicReport {
        with(scenarios: scenarios.map { result in
            var copy = result
            copy.texts = nil
            return copy
        })
    }

    func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try jsonString().write(to: directory.appendingPathComponent("mock-mic.json"), atomically: true, encoding: .utf8)
    }
}
#endif
