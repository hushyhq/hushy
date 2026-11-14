import CryptoKit
import Foundation
import MurmurCore

/// Machine-readable evidence for golden runs. Never stores real user dictations.
enum GoldenReport {
    static func write(title: String, results: [Runners.CaseResult], args: Arguments) throws {
        guard let path = args.string("report") else { return }
        let golden = args.string("golden").map { URL(fileURLWithPath: $0) } ?? Paths.golden
        let hash = SHA256.hash(data: try Data(contentsOf: golden)).map { String(format: "%02x", $0) }.joined()
        let cases: [[String: Any]] = results.map { result in
            ["id": result.item.id, "tag": result.item.tag, "gate": result.item.gate as Any? ?? NSNull(), "input": result.input,
             "expected": result.item.expected, "accepted": result.item.accepted,
             "actual": result.output.text, "passed": result.passed,
             "pressEnter": result.output.pressEnter,
             "expectedPressEnter": result.item.expectedPressEnter ?? false, "exactText": result.item.exactText ?? false,
             "latencyMs": result.latency, "usedModel": result.output.usedModel,
             "rejection": result.output.rejection as Any? ?? NSNull(),
             "voice": result.voice as Any? ?? NSNull(),
             "groups": result.output.groups.map { group -> [String: Any] in
                 ["words": group.words, "outcome": group.outcome.rawValue, "guardCode": group.guardCode?.rawValue as Any? ?? NSNull(),
                  "edited": group.edited, "modelMs": group.modelMs as Any? ?? NSNull(),
                  "source": group.source?.rawValue as Any? ?? NSNull()]
             },
             "failureClass": result.passed ? NSNull() : (CleanupOutcomeReport.failureClass(result) as Any),
             "rejectedAnswerPasses": result.rejectedAnswer.map { result.matches($0) } as Any? ?? NSNull()]
        }
        var payload: [String: Any] = [
            "schemaVersion": 1, "scoringVersion": "layout-and-command-v2", "title": title,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "arguments": Array(CommandLine.arguments.dropFirst()),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "modelAvailable": SmartCleaner.isModelAvailable, "backend": LanguageModels.current.identifier,
            "goldenSHA256": hash, "gitRevision": try command(["rev-parse", "HEAD"]),
            "gitStatus": try command(["status", "--short"]),
            "passed": results.filter(\.passed).count, "total": results.count, "cases": cases,
        ]
        if args.command == "e2e" {
            let settings = try Runners.audioCleanupSettings(args)
            payload["cleanupSettings"] = Runners.cleanupSettingsMetadata(settings?.cleanupOptions)
            payload["cleanupStrategy"] = settings.map {
                Runners.audioCleanupStrategy(args, settings: $0).rawValue
            } as Any? ?? NSNull()
        }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
    }

    private static func command(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw EvalError.missing("Cannot record git provenance") }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
