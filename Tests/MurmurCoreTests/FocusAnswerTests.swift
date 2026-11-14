import XCTest
@testable import MurmurCore

final class FocusAnswerTests: XCTestCase {
    @MainActor func testSilentAppPastesAndKeepsClipboardWhenLandingCannotBeRead() async {
        let focus = FakeFocus()
        focus.fields[FakeFocus.mailPID] = nil // app and system AX queries returned no element
        let bound = focus.bind()
        let answer = FocusAnswer.classify(role: nil, subrole: nil, valueSettable: false,
                                          hasSelectedTextRange: false, bundleID: FakeFocus.mail)
        let paster = FakePaster()
        let result = await TargetedDelivery.deliver(
            text: "Vela trims the amber sail.", pressReturn: false, answer: answer,
            check: { TargetGuard.check(bound, reader: focus) }, landing: { nil }, paster: paster)
        paster.settle()
        XCTAssertEqual(answer, .unknown)
        XCTAssertEqual(result, .unknownUnreadable)
        XCTAssertEqual(paster.events, ["stage", "⌘V"])
        XCTAssertEqual(paster.clipboard, "Vela trims the amber sail.")
    }

    @MainActor func testSecureFocusAndFinderDesktopNeverPaste() async {
        let focus = FakeFocus()
        focus.security[100] = .secure
        let bound = focus.bind()
        let securePaster = FakePaster()
        let secure = await TargetedDelivery.deliver(
            text: "words", pressReturn: false, answer: .unknown,
            check: { TargetGuard.check(bound, reader: focus) }, landing: { nil }, paster: securePaster)
        XCTAssertEqual(secure, .heldForSecureField(nil))
        XCTAssertEqual(securePaster.events, [])

        focus.front = (FakeFocus.mailPID, "com.apple.finder")
        focus.fields[FakeFocus.mailPID] = nil
        let desktop = focus.bind()
        let finderAnswer = FocusAnswer.classify(role: nil, subrole: nil, valueSettable: false,
                                                hasSelectedTextRange: false, bundleID: "com.apple.finder")
        let finderPaster = FakePaster()
        let finder = await TargetedDelivery.deliver(
            text: "words", pressReturn: false, answer: finderAnswer,
            check: { TargetGuard.check(desktop, reader: focus) }, landing: { nil },
            noFieldClipboard: .copyAutomatically, paster: finderPaster)
        XCTAssertEqual(finder, .noField(copied: true))
        XCTAssertEqual(finderPaster.events, ["copy"])
    }

    func testRoleFamiliesAndEvidence() {
        for role in ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"] {
            XCTAssertEqual(FocusAnswer.classify(role: role, subrole: nil, valueSettable: true,
                                                hasSelectedTextRange: false, bundleID: nil), .field, role)
        }
        XCTAssertEqual(FocusAnswer.classify(role: "AXTextField", subrole: nil, valueSettable: false,
                                            hasSelectedTextRange: false, bundleID: nil), .unknown)
        XCTAssertEqual(FocusAnswer.classify(role: "AXTextField", subrole: nil, valueSettable: false,
                                            hasSelectedTextRange: true, bundleID: nil), .field)
        let controls = ["AXButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXSwitch",
                        "AXImage", "AXVideo", "AXMenuBar", "AXList", "AXTable", "AXOutline", "AXPopUpButton",
                        "AXTab", "AXLink", "AXProgressIndicator"]
        for role in controls {
            XCTAssertEqual(FocusAnswer.classify(role: role, subrole: nil, valueSettable: false,
                                                hasSelectedTextRange: false, bundleID: nil), .noField, role)
            // A settable value on a concrete control is not evidence of an editor.
            XCTAssertEqual(FocusAnswer.classify(role: role, subrole: nil, valueSettable: true,
                                                hasSelectedTextRange: false, bundleID: nil), .noField, role)
            XCTAssertEqual(FocusAnswer.classify(role: role, subrole: nil, valueSettable: false,
                                                hasSelectedTextRange: true, bundleID: nil), .unknown, role)
        }
        // A highlighted item in a web autocomplete list can hold focus while the caret is in the input.
        for role in ["AXMenu", "AXMenuItem"] {
            XCTAssertEqual(FocusAnswer.classify(role: role, subrole: nil, valueSettable: false,
                                                hasSelectedTextRange: false, bundleID: nil), .unknown, role)
        }
        // An element whose role could not be read is not "nothing focused", in Finder either.
        XCTAssertEqual(FocusAnswer.classify(role: "", subrole: nil, valueSettable: false,
                                            hasSelectedTextRange: false, bundleID: "com.apple.finder"), .unknown)
        XCTAssertEqual(FocusAnswer.classify(role: "AXScrollArea", subrole: nil, valueSettable: true,
                                            hasSelectedTextRange: false, bundleID: "com.apple.finder"), .unknown)
        for role in ["AXWindow", "AXGroup", "AXScrollArea", "AXApplication", "AXLayoutArea",
                     "AXLayoutItem", "AXSheet", "AXDrawer", "AXToolbar", "AXTabGroup",
                     "AXSplitter", "AXStaticText", "AXWebArea", "AXRow", "AXCell", "AXMystery"] {
            XCTAssertEqual(FocusAnswer.classify(role: role, subrole: nil, valueSettable: false,
                                                hasSelectedTextRange: false, bundleID: nil), .unknown, role)
        }
        XCTAssertEqual(FocusAnswer.classify(role: nil, subrole: nil, valueSettable: false,
                                            hasSelectedTextRange: false, bundleID: nil), .unknown)
        XCTAssertEqual(FocusAnswer.classify(role: nil, subrole: nil, valueSettable: false,
                                            hasSelectedTextRange: false, bundleID: nil,
                                            positivelyNoWindow: true), .noField)
        XCTAssertEqual(FocusAnswer.classify(role: nil, subrole: nil, valueSettable: false,
                                            hasSelectedTextRange: false, bundleID: "com.apple.finder"), .noField)
        // Finder draws no text of its own: its containers are not somewhere to type, a rename is.
        for role in ["AXScrollArea", "AXGroup", "AXWindow", "AXBrowser"] {
            XCTAssertEqual(FocusAnswer.classify(role: role, subrole: nil, valueSettable: false,
                                                hasSelectedTextRange: false, bundleID: "com.apple.finder"), .noField, role)
        }
        XCTAssertEqual(FocusAnswer.classify(role: "AXMystery", subrole: nil, valueSettable: false,
                                            hasSelectedTextRange: false, bundleID: "com.apple.finder"), .unknown)
        XCTAssertEqual(FocusAnswer.classify(role: "AXTextField", subrole: nil, valueSettable: true,
                                            hasSelectedTextRange: true, bundleID: "com.apple.finder"), .field)
        XCTAssertEqual(FocusAnswer.classify(role: "AXWebArea", subrole: nil, valueSettable: false,
                                            hasSelectedTextRange: false, bundleID: nil), .unknown)
        XCTAssertEqual(FocusAnswer.classify(role: "AXMystery", subrole: nil, valueSettable: false,
                                            hasSelectedTextRange: false, bundleID: nil), .unknown)
        XCTAssertEqual(FocusAnswer.classify(role: "AXMystery", subrole: nil, valueSettable: true,
                                            hasSelectedTextRange: false, bundleID: nil), .unknown)
        XCTAssertEqual(FocusAnswer.classify(role: "AXMystery", subrole: nil, valueSettable: false,
                                            hasSelectedTextRange: true, bundleID: nil), .unknown)
    }

    /// Every role the classifier treats as "no field": a concrete control that is not somewhere to
    /// type, whether or not its value can be set (a slider's can). Nothing is pasted or sent there.
    @MainActor func testEachConcreteControlIsNoFieldAndIsNeverPastedInto() async {
        let noFieldRoles = [
            "AXButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXSwitch", "AXImage", "AXVideo",
            "AXMenuBar", "AXList", "AXTable", "AXOutline", "AXPopUpButton", "AXTab", "AXLink",
            "AXProgressIndicator",
        ]
        for role in noFieldRoles {
            for valueSettable in [false, true] {
                let answer = FocusAnswer.classify(role: role, subrole: nil, valueSettable: valueSettable,
                                                  hasSelectedTextRange: false, bundleID: "com.example.app")
                XCTAssertEqual(answer, .noField, "\(role) settable=\(valueSettable)")
            }
        }
        let paster = FakePaster()
        let result = await TargetedDelivery.deliver(
            text: "Vela trims the amber sail.", pressReturn: true,
            answer: FocusAnswer.classify(role: "AXSlider", subrole: nil, valueSettable: true,
                                         hasSelectedTextRange: false, bundleID: "com.example.app"),
            check: { .unchanged }, landing: { nil }, noFieldClipboard: .copyAutomatically, paster: paster)
        XCTAssertEqual(result, .noField(copied: true))
        XCTAssertEqual(paster.events, ["copy"], "no ⌘V and no Return")
    }

    /// An ordinary text field and a text area are still a field: pasted straight in, with no
    /// landing check and nothing left on the clipboard.
    @MainActor func testOrdinaryTextFieldAndTextAreaAreStillPastedInto() async {
        for role in ["AXTextField", "AXTextArea"] {
            let answer = FocusAnswer.classify(role: role, subrole: nil, valueSettable: true,
                                              hasSelectedTextRange: true, bundleID: "com.example.app")
            XCTAssertEqual(answer, .field, role)
            let paster = FakePaster()
            var landingReads = 0
            let result = await TargetedDelivery.deliver(
                text: "Vela trims the amber sail.", pressReturn: false, answer: answer,
                check: { .unchanged }, landing: { landingReads += 1; return nil }, paster: paster)
            paster.settle()
            XCTAssertEqual(result, .pasted, role)
            XCTAssertEqual(landingReads, 0, role)
            XCTAssertEqual(paster.events, ["stage", "⌘V"], role)
            XCTAssertEqual(paster.clipboard, paster.userClipboard, role)
        }
    }

    func testOwnWindowUsesFirstResponder() {
        XCTAssertEqual(FocusAnswer.classify(role: "AXWindow", subrole: nil, valueSettable: false,
                                            hasSelectedTextRange: false, bundleID: "app", ownWindowTextView: true), .field)
        XCTAssertEqual(FocusAnswer.classify(role: "AXTextField", subrole: nil, valueSettable: true,
                                            hasSelectedTextRange: true, bundleID: "app", ownWindowTextView: false), .noField)
    }

    func testLateFieldOnlyWithinOriginalAppAndWindow() {
        XCTAssertTrue(FocusRefresh.mayAdopt(original: .unknown, hadElement: false,
                                             sameApp: true, sameWindow: true, current: .field))
        XCTAssertFalse(FocusRefresh.mayAdopt(original: .unknown, hadElement: false,
                                              sameApp: false, sameWindow: true, current: .field))
        XCTAssertFalse(FocusRefresh.mayAdopt(original: .unknown, hadElement: false,
                                              sameApp: true, sameWindow: false, current: .field))
        XCTAssertFalse(FocusRefresh.mayAdopt(original: .unknown, hadElement: true,
                                              sameApp: true, sameWindow: true, current: .field))
        XCTAssertFalse(FocusRefresh.mayAdopt(original: .noField, hadElement: false,
                                              sameApp: true, sameWindow: true, current: .field))
    }
}
