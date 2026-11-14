import XCTest
@testable import MurmurCore

/// The one log line written when Hushy could not tell whether a text field had focus. It must let
/// the next report be diagnosed without the person's words: which query failed and how, what kind
/// of element was seen, which app. Never text, a window title or a field's value.
final class PasteDiagnosisTests: XCTestCase {
    private func diagnosis(
        bundleID: String? = "com.example.browser", role: String? = "AXWebArea", subrole: String? = nil
    ) -> PasteDiagnosis {
        PasteDiagnosis(
            bundleID: bundleID, category: AppCategory.aiPrompts.rawValue,
            focus: .init(query: .app, appError: 0, system: .skipped, role: role, subrole: subrole,
                         settable: .no, range: .error(-25205)),
            adopted: false, before: .count(-25205), after: .notRead, signal: nil)
    }

    func testTheLineNamesEveryFieldInAFixedOrder() {
        XCTAssertEqual(
            diagnosis().line,
            "paste-diagnosis app=com.example.browser category=aiPrompts focus=unknown query=app app-err=ok "
                + "sys-err=skipped role=AXWebArea subrole=none settable=0 range=err:unsupported no-window=0 adopted=no "
                + "before=count:unsupported after=none signal=none")
    }

    func testNothingFocusedAndBothQueriesFailed() {
        let line = PasteDiagnosis(
            bundleID: "com.example.chat", category: "other",
            focus: .init(query: .none, appError: -25212, system: .error(-25204), role: nil, subrole: nil,
                         settable: .no, range: .no),
            adopted: false, before: .noElement, after: .noElement, signal: nil).line
        XCTAssertTrue(line.contains("query=none app-err=no-value sys-err=err:cannot-complete role=none"), line)
        XCTAssertTrue(line.contains("before=no-element after=no-element"), line)
    }

    func testCopyOnlyLineNamesTheNoFieldAnswerAndRole() {
        let line = PasteDiagnosis(
            bundleID: "com.meta.endo", category: "other", answer: .noField,
            focus: .init(query: .app, appError: 0, system: .skipped, role: "AXButton", subrole: nil,
                         settable: .no, range: .error(-25212)),
            adopted: false, before: .notRead, after: .notRead, signal: nil).line
        XCTAssertTrue(line.contains("focus=no-field query=app app-err=ok sys-err=skipped role=AXButton"), line)
        XCTAssertTrue(line.contains("before=none after=none"), line)
    }

    func testALateFieldAndTheSignalThatConfirmed() {
        let line = PasteDiagnosis(
            bundleID: "com.example.browser", category: "other",
            focus: .init(query: .system, appError: -25204, system: .ok, role: "AXGroup", subrole: "AXLandmarkMain",
                         settable: .yes, range: .yes),
            adopted: true, before: .ok, after: .ok, signal: .caret).line
        XCTAssertTrue(line.contains("query=system app-err=cannot-complete sys-err=ok role=AXGroup subrole=AXLandmarkMain"), line)
        XCTAssertTrue(line.contains("settable=1 range=1 no-window=0 adopted=late-field before=ok after=ok signal=caret"), line)
    }

    func testEveryProbeStatusHasAFixedWord() {
        let words = [PasteDiagnosis.Probe.notRead, .ok, .targetMoved, .noElement, .otherElement, .security(nil),
                     .security(-25204), .count(-25200), .valueType, .valueLong].map(\.token)
        XCTAssertEqual(words, ["none", "ok", "verdict", "no-element", "other-element", "security:secure",
                               "security:cannot-complete", "count:failure", "value-type", "value-long"])
    }

    func testTheSystemQueryThatAnsweredForAnotherProcessIsNamed() {
        XCTAssertEqual(PasteDiagnosis.SystemQuery.otherProcess.token, "other-pid")
    }

    func testKnownAccessibilityErrorsAreNamedAndUnknownOnesKeepTheirNumber() {
        XCTAssertEqual(PasteDiagnosis.errorName(0), "ok")
        XCTAssertEqual(PasteDiagnosis.errorName(-25211), "api-disabled")
        XCTAssertEqual(PasteDiagnosis.errorName(-25202), "invalid-element")
        XCTAssertEqual(PasteDiagnosis.errorName(-25208), "not-implemented")
        XCTAssertEqual(PasteDiagnosis.errorName(-31337), "-31337")
    }

    // MARK: The reads of one landing check

    private let pasted = PastedText(length: 27)

    func testNoReadsAtAllIsNoneOnBothSides() {
        let reads = LandingReadLog()
        XCTAssertEqual(reads.before, .notRead)
        XCTAssertEqual(reads.after, .notRead)
        XCTAssertNil(reads.signal(pasted: pasted))
    }

    func testTheFirstReadIsBeforeAndTheLastIsAfter() {
        var reads = LandingReadLog()
        reads.record(LandingProbe(characterCount: 3, selectedLength: 0, caretLocation: 3), .ok)
        XCTAssertEqual(reads.before, .ok)
        XCTAssertEqual(reads.after, .notRead, "the paste did not get as far as a second read")
        reads.record(LandingProbe(characterCount: 3, selectedLength: 0, caretLocation: 3), .ok)
        XCTAssertNil(reads.signal(pasted: pasted))
        reads.record(LandingProbe(characterCount: 30, selectedLength: 0, caretLocation: 30), .ok)
        XCTAssertEqual(reads.signal(pasted: pasted), .count)
        reads.record(nil, .otherElement)
        XCTAssertEqual(reads.after, .otherElement)
        XCTAssertNil(reads.signal(pasted: pasted))
    }

    func testTheSignalIsTheCaretOnlyWhenItAdvancedByThePaste() {
        var reads = LandingReadLog()
        reads.record(LandingProbe(characterCount: nil, selectedLength: 0, caretLocation: 3), .ok)
        reads.record(LandingProbe(characterCount: nil, selectedLength: 0, caretLocation: 9), .ok)
        XCTAssertNil(reads.signal(pasted: pasted))
        reads.record(LandingProbe(characterCount: nil, selectedLength: 0, caretLocation: 30), .ok)
        XCTAssertEqual(reads.signal(pasted: pasted), .caret)
    }

    func testAnUnreadableFieldKeepsWhyOnEachSide() {
        var reads = LandingReadLog()
        reads.record(nil, .count(-25204))
        reads.record(nil, .noElement)
        XCTAssertEqual(reads.before, .count(-25204))
        XCTAssertEqual(reads.after, .noElement)
        XCTAssertNil(reads.signal(pasted: pasted))
    }

    // MARK: Nothing free-form passes through

    func testARoleIsLettersAndDigitsOnlyAndAtMostFortyCharacters() {
        let role = "AX Secret Draft: “Dear Dana, the offer is 40,000”/and-more-text-that-goes-on-and-on"
        let token = PasteDiagnosis.identifier(role)
        XCTAssertEqual(token.count, PasteDiagnosis.tokenLimit)
        XCTAssertTrue(token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }, token)
        XCTAssertFalse(diagnosis(role: role).line.contains("Dana,"))
        XCTAssertFalse(diagnosis(role: role).line.contains("“"))
    }

    func testAMissingOrEmptyRoleIsNoneAndOneWithNoUsableCharacterIsOther() {
        XCTAssertEqual(PasteDiagnosis.identifier(nil), "none")
        XCTAssertEqual(PasteDiagnosis.identifier(""), "none")
        XCTAssertEqual(PasteDiagnosis.identifier("— · —"), "other")
        XCTAssertEqual(PasteDiagnosis.identifier("日本語"), "other")
    }

    func testABundleIdentifierKeepsDotsAndHyphensAndIsCapped() {
        XCTAssertEqual(PasteDiagnosis.bundleToken("com.example.app-beta"), "com.example.app-beta")
        XCTAssertEqual(PasteDiagnosis.bundleToken("com.example/../../etc passwd"), "com.example....etcpasswd")
        XCTAssertEqual(PasteDiagnosis.bundleToken(nil), "none")
        let long = "com.example.webapp." + String(repeating: "a1b2-", count: 20)
        XCTAssertEqual(PasteDiagnosis.bundleToken(long).count, PasteDiagnosis.tokenLimit)
    }

    func testTheLineIsOneLineOfKeyValueWordsWhateverItIsGiven() {
        let line = PasteDiagnosis(
            bundleID: "com.example app\nsecond line", category: "ai prompts\n",
            focus: .init(query: .app, appError: 0, system: .skipped, role: "AX\nRole value=typed text", subrole: "a=b c",
                         settable: .error(7), range: .yes),
            adopted: false, before: .ok, after: .ok, signal: .count).line
        XCTAssertFalse(line.contains("\n"))
        let fields = line.split(separator: " ").dropFirst()
        XCTAssertEqual(fields.count, 15)
        for field in fields {
            XCTAssertEqual(field.split(separator: "=", omittingEmptySubsequences: false).count, 2, String(field))
        }
    }
}
