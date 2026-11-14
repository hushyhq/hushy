import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The diagnostics file attached to a feedback email must carry numbers and settings only.
struct FeedbackDiagnosticsTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static let facts = FeedbackFacts(
        version: "1.4", build: "2500", macOS: "15.6.1", chip: "Apple M4 Pro", memoryGB: 24,
        cleanupSetting: "local", cleanupInUse: "local", cleanupModelID: "hushy-cleanup-2b-r5d2blr2-4bit",
        microphone: .granted, accessibility: .denied)

    /// Lines as `composedMessage` could return them, good and bad, all from the last hour.
    static let fixtureLines: [FeedbackLogLine] = [
        "key-down: microphone opened in 14 ms, focused app read in 3 ms",
        "gate pass peak 0.0810 rms 0.0140 floor 0.00090 hi 0.42 (312 frames) threshold 0.00123 active 45%",
        "dictation 2100 ms audio · speech 83 ms · cleanup 41 ms · insert 9 ms · total 133 ms · model=true "
            + "why=used · delivery=pasted focus=field landing=not-checked "
            + "Hi Priya, I said meet me at noon ada.lovelace@example.com /Users/ada/Documents/plan.txt why=lunch",
        "dictation 900 ms audio · speech 50 ms · cleanup 20 ms · insert 5 ms · total 75 ms · model=false "
            + "why=rejected-by-guard(added-words) · delivery=copied reason=target-changed:app focus=unknown",
        "gate <private> peak 0.0020 rms 0.0004 floor 0.00030 hi 0.10 (40 frames) threshold 0.00123 active 0%",
        "Hi Priya, I said meet me at noon",
        "spoken: let's ship it on Friday",
        "account signed in as ada.lovelace@example.com",
        "transcription failed: The file “plan.txt” couldn’t be opened at /Users/ada/Library/Caches/x",
        "capture \"Ada's AirPods Pro\" · bluetooth · 16000 Hz · 1 ch",
        "key-down: microphone opened in 14 ms, focused app read in 3 ms /Users/ada",
    ].enumerated().map { index, message in
        FeedbackLogLine(date: now.addingTimeInterval(Double(index) - 3_600), subsystem: "app.hushy", message: message)
    }

    static let forbidden = ["Priya", "meet me", "noon", "ship it", "Friday", "@", "ada", "Ada", "/Users",
                            "plan.txt", "AirPods", "lunch", "Library", "signed in"]

    @Test func fileKeepsTimingsAndDropsWordsEmailsAndPaths() throws {
        let file = FeedbackDiagnostics.file(facts: Self.facts, lines: Self.fixtureLines, reach: .lastThreeDays, now: Self.now)
        for text in Self.forbidden {
            #expect(!file.contains(text), "diagnostics leaked \(text)")
        }
        #expect(file.contains("key-down: microphone opened in 14 ms, focused app read in 3 ms"))
        #expect(file.contains("gate pass peak 0.0810 rms 0.0140 floor 0.00090 hi 0.42 (312 frames) threshold 0.00123 active 45%"))
        #expect(file.contains("dictation 2100 ms audio · speech 83 ms · cleanup 41 ms · insert 9 ms · total 133 ms · "
            + "model=true why=used delivery=pasted focus=field landing=not-checked\n"))
        #expect(file.contains("why=rejected-by-guard(added-words) delivery=copied reason=target-changed:app focus=unknown"))
        #expect(file.contains("gate <private> peak 0.0020 rms 0.0004 floor 0.00030 hi 0.10 (40 frames) threshold 0.00123 active 0%"))
        #expect(file.contains("App: 1.4 (2500)"))
        #expect(file.contains("Cleanup model: hushy-cleanup-2b-r5d2blr2-4bit"))
        #expect(file.contains("Microphone access: granted"))
        #expect(file.contains("Accessibility access: not granted"))
        #expect(file.components(separatedBy: "\n").filter { $0.contains("  ") }.count == 5)
        try Self.writeSampleIfAsked(file)
    }

    @Test func headerValuesThatAreNotPlainIdentifiersBecomeUnknown() {
        var facts = Self.facts
        facts.chip = "/Users/ada/chip"
        facts.cleanupModelID = "ada.lovelace@example.com"
        facts.version = "1.4 because Ada said so, twice"
        let file = FeedbackDiagnostics.file(facts: facts, lines: [], reach: .unavailable, now: Self.now)
        #expect(!file.contains("ada"))
        #expect(!file.contains("Ada"))
        #expect(file.contains("Chip: unknown"))
        #expect(file.contains("Cleanup model: unknown"))
        #expect(file.contains("No timing lines found."))
        #expect(file.contains("macOS did not allow reading it"))
    }

    @Test func linesOutsideTheWindowOrFromOtherAppsAreLeftOut() {
        let line = "key-down: microphone opened in 99 ms, focused app read in 4 ms"
        let lines = [
            FeedbackLogLine(date: Self.now.addingTimeInterval(-4 * 86_400), subsystem: "app.hushy", message: line),
            FeedbackLogLine(date: Self.now.addingTimeInterval(-60), subsystem: "com.example.other", message: line),
            FeedbackLogLine(date: Self.now.addingTimeInterval(60), subsystem: "app.hushy", message: line),
        ]
        #expect(FeedbackDiagnostics.safeLines(lines, now: Self.now).isEmpty)
    }

    @Test func onlyTheNewestLinesAreKeptWhenThereAreTooMany() {
        let lines = (0..<(FeedbackDiagnostics.maxLines + 10)).map { index in
            FeedbackLogLine(date: Self.now.addingTimeInterval(Double(index) - 50_000), subsystem: "app.hushy",
                            message: "key-down: microphone opened in \(index) ms, focused app read in 1 ms")
        }
        let kept = FeedbackDiagnostics.safeLines(lines, now: Self.now)
        #expect(kept.count == FeedbackDiagnostics.maxLines)
        #expect(kept.last?.contains("opened in \(FeedbackDiagnostics.maxLines + 9) ms") == true)
    }

    /// Every delivery summary the app writes survives the allowlist, so a new value is noticed here
    /// instead of silently vanishing from the file.
    @Test func everyDeliverySummaryTheAppWritesIsKept() {
        let results: [DeliveryResult] = [
            .pasted, .pastedReturnSkipped(nil), .pastedReturnSkipped(.window), .returnSent, .returnWithheld(nil),
            .returnWithheld(.field), .copied(.fieldClosed), .heldForSecureField(nil), .noField(copied: true),
            .noField(copied: false), .unknownConfirmed, .unknownConfirmedReturnSkipped(.app), .unknownUnreadable,
            .unknownUnreadableReturnSkipped(nil), .unknownNotLanded, .unknownCancelled, .dispatchFailed(copied: true),
            .dispatchFailed(copied: false), .cancelled,
        ]
        for result in results {
            for token in result.logSummary.split(separator: " ") {
                #expect(FeedbackLogTokens.isKnown(String(token)), "dropped \(token) from \(result.logSummary)")
            }
        }
        for outcome in ModelOutcome.allCases {
            #expect(FeedbackLogTokens.isKnown("why=\(outcome.rawValue)"))
        }
        #expect(!FeedbackLogTokens.isKnown("why=hello"))
        #expect(!FeedbackLogTokens.isKnown("delivery=Priya"))
    }

    @Test func mailtoLinkEncodesEveryReservedCharacter() throws {
        let url = try #require(FeedbackMail.mailtoURL(body: "a&b=c+d #e\nf?g"))
        #expect(url.absoluteString == "mailto:support@tryhushy.com?subject=Hushy%20feedback&body=a%26b%3Dc%2Bd%20%23e%0Af%3Fg")
    }

    @Test func attachmentIsWrittenWithAPlainNameInsideTheGivenFolder() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("feedback-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = try FeedbackMail.writeAttachment("numbers\n", in: temp)
        #expect(file.lastPathComponent == "Hushy diagnostics.txt")
        #expect(file.path.hasPrefix(temp.path))
        #expect(try String(contentsOf: file, encoding: .utf8) == "numbers\n")
        #expect(FeedbackMail.fallbackBody("Hi", hasAttachment: true).contains("Hushy diagnostics.txt"))
        #expect(FeedbackMail.fallbackBody("Hi", hasAttachment: false) == "Hi")
    }

    /// `HUSHY_FEEDBACK_SNAPSHOTS=<dir> swift test --filter Feedback` writes the fixture file for review.
    private static func writeSampleIfAsked(_ file: String) throws {
        guard let path = ProcessInfo.processInfo.environment["HUSHY_FEEDBACK_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try file.write(to: directory.appendingPathComponent("sample-diagnostics.txt"), atomically: true, encoding: .utf8)
    }
}
