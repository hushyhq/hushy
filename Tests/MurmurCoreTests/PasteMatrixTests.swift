import XCTest
@testable import MurmurCore

/// The paste matrix (`docs/engineering/PASTE-MATRIX.md`) and the guarantee behind it: whatever the field,
/// the key, the focus and the app do, a dictation ends confirmed in the field, on the clipboard, held for a
/// password field, or reported as pasted without a check (and then only in History). The last group is
/// named exactly, so it cannot grow unnoticed.
@MainActor
final class PasteMatrixTests: XCTestCase {
    private var docURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/engineering/PASTE-MATRIX.md")
    }

    func testThereAreThirtyDistinctApps() {
        XCTAssertEqual(PasteMatrix.apps.count, 30)
        XCTAssertEqual(Set(PasteMatrix.apps.map(\.bundleID)).count, 30)
        XCTAssertEqual(Set(PasteMatrix.apps.map(\.name)).count, 30)
    }

    func testTheCommittedTableIsWhatTheCodeDoes() async throws {
        let table = await PasteMatrix.markdown()
        let doc = try String(contentsOf: docURL, encoding: .utf8)
        let start = try XCTUnwrap(doc.range(of: PasteMatrix.markerStart), "the doc needs the start marker")
        let end = try XCTUnwrap(doc.range(of: PasteMatrix.markerEnd), "the doc needs the end marker")
        if ProcessInfo.processInfo.environment["HUSHY_WRITE_PASTE_MATRIX"] == "1" {
            let rewritten = doc.replacingCharacters(in: start.upperBound..<end.lowerBound, with: "\n\(table)\n")
            try rewritten.write(to: docURL, atomically: true, encoding: .utf8)
            return
        }
        let committed = doc[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(committed, table, "regenerate with HUSHY_WRITE_PASTE_MATRIX=1 and read the diff")
    }

    func testAKnownFieldThatReadsCatchesALostPasteAndAnUncertainOneKeepsTheWords() async throws {
        let notes = try XCTUnwrap(PasteMatrix.apps.first { $0.name == "Notes" })
        let lostAndReads = PasteMatrix.Scenario(lands: false, readable: true)
        let lostAndBlind = PasteMatrix.Scenario(lands: false, readable: false)
        let notesLostReads = await PasteMatrix.run(notes, lostAndReads)
        XCTAssertEqual(notesLostReads.answer, .field)
        XCTAssertEqual(notesLostReads.outcome, .caught)
        let notesLostBlind = await PasteMatrix.run(notes, lostAndBlind)
        XCTAssertEqual(notesLostBlind.outcome, .historyOnly, "a known field that cannot be read cannot be checked")

        let slack = try XCTUnwrap(PasteMatrix.apps.first { $0.name == "Slack" })
        let slackLostReads = await PasteMatrix.run(slack, lostAndReads)
        XCTAssertEqual(slackLostReads.answer, .unknown)
        XCTAssertEqual(slackLostReads.outcome, .caught)
        let slackLostBlind = await PasteMatrix.run(slack, lostAndBlind)
        XCTAssertEqual(slackLostBlind.outcome, .keptOnClipboard, "an uncertain target keeps the words whenever it cannot tell")
    }

    func testAnElectronTextAreaBehindAHiddenInputIsNeverCalledLost() async throws {
        let electronApps = PasteMatrix.apps.filter { $0.surface == .electronTextArea }
        XCTAssertEqual(electronApps.map(\.name), ["Visual Studio Code", "Cursor"])
        for app in electronApps {
            for scenario in PasteMatrix.Scenario.all {
                let run = await PasteMatrix.run(app, scenario)
                let label = "\(app.name): \(scenario.title)"
                XCTAssertEqual(run.answer, .field, "Accessibility reports a text area there, so key-down is sure of it: \(label)")
                XCTAssertEqual(run.outcome, .historyOnly, "its count stays empty either way, so nothing can be said: \(label)")
            }
        }
    }

    func testABrowserPageIsNotWatchedEvenWhenItsFieldReads() async throws {
        let safari = try XCTUnwrap(PasteMatrix.apps.first { $0.name == "Safari" })
        let mail = try XCTUnwrap(PasteMatrix.apps.first { $0.name == "Mail" })
        XCTAssertEqual(safari.surface, mail.surface, "the same WebKit text input")
        let lostAndReads = PasteMatrix.Scenario(lands: false, readable: true)
        let safariRun = await PasteMatrix.run(safari, lostAndReads)
        XCTAssertEqual(safariRun.outcome, .historyOnly, "any page may draw its own editor behind a hidden input")
        let mailRun = await PasteMatrix.run(mail, lostAndReads)
        XCTAssertEqual(mailRun.outcome, .caught, "a native app with a WebKit composer is watched")
    }

    func testNoAppThatCannotBeWatchedIsEverCalledLostOrConfirmedByTheSecondLook() async {
        for app in PasteMatrix.apps where app.surface.role == "AXTextArea" && !app.isWatched {
            for scenario in PasteMatrix.Scenario.all {
                let run = await PasteMatrix.run(app, scenario)
                XCTAssertNotEqual(run.outcome, .caught, "\(app.name): \(scenario.title)")
                XCTAssertNotEqual(run.outcome, .confirmed, "\(app.name): \(scenario.title)")
            }
        }
    }

    func testOnlyTheAllowlistedAppsAreWatchedAndTheRestNeverRaiseTheAlarm() async {
        let watched = PasteMatrix.apps.filter(\.isWatched).map(\.name)
        XCTAssertEqual(Set(watched), ["TextEdit", "Notes", "Mail"])
        for app in PasteMatrix.apps where !app.isWatched {
            for scenario in PasteMatrix.Scenario.all {
                let run = await PasteMatrix.run(app, scenario)
                if run.answer == .field { XCTAssertNotEqual(run.outcome, .caught, "\(app.name): \(scenario.title)") }
            }
        }
    }

    func testAComposerWhereReturnSendsIsNotWatchedSoItsOwnReturnCannotRaiseTheAlarm() async throws {
        let messages = try XCTUnwrap(PasteMatrix.apps.first { $0.name == "Messages" })
        XCTAssertEqual(messages.surface, .appKitText, "a field Hushy is sure of, and one whose Return empties it")
        let landsReads = PasteMatrix.Scenario(lands: true, readable: true)
        let run = await PasteMatrix.run(messages, landsReads)
        XCTAssertEqual(run.answer, .field)
        XCTAssertNotEqual(run.outcome, .caught)
    }

    func testNoScenarioEverConfirmsAPasteThatDidNotLand() async {
        for app in PasteMatrix.apps {
            for scenario in PasteMatrix.Scenario.all where !scenario.lands {
                let run = await PasteMatrix.run(app, scenario)
                XCTAssertNotEqual(run.outcome, .confirmed, "\(app.name): \(scenario.title)")
            }
        }
    }

    func testEveryCombinationEndsConfirmedOnTheClipboardHeldOrNamedHistoryOnly() async {
        var historyOnly = 0
        var total = 0
        for answer in [FocusAnswer.field, .unknown, .noField] {
            for scenario in PasteMatrix.Scenario.all {
                for secure in [false, true] {
                    for moved in [false, true] {
                        for key in [true, false] {
                            total += 1
                            let outcome = await PasteMatrix.deliver(
                                answer: answer, scenario: scenario, secure: secure, moved: moved, pasteKeySucceeds: key)
                            let label = "\(answer) \(scenario.title) secure=\(secure) moved=\(moved) key=\(key)"
                            if outcome == .historyOnly {
                                historyOnly += 1
                                XCTAssertEqual(answer, .field, label)
                                XCTAssertFalse(scenario.readable && !scenario.lands, "a lost paste in a readable field is caught: \(label)")
                                XCTAssertFalse(secure || moved || !key, label)
                            }
                            if outcome == .confirmed { XCTAssertTrue(scenario.lands && scenario.readable, label) }
                            if outcome == .held { XCTAssertTrue(secure, label) }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(total, 96)
        XCTAssertGreaterThan(historyOnly, 0, "the known-field, unreadable case exists and is the one named residual")
    }
}
