import XCTest
@testable import MurmurCore

/// A fake desktop: which app is frontmost, which field/window each app focuses, which elements
/// are destroyed and which are password fields. Elements are plain Ints.
@MainActor
final class FakeFocus: FocusReading {
    typealias Element = Int

    static let mailPID: Int32 = 42
    static let chatPID: Int32 = 7
    static let mail = "com.example.mail"
    static let chat = "com.example.chat"

    var front: (processID: Int32, bundleID: String?)? = (mailPID, mail)
    var running: Set<Int32> = [mailPID, chatPID]
    var fields: [Int32: Int] = [mailPID: 100, chatPID: 200]
    var windows: [Int32: Int] = [mailPID: 1, chatPID: 2]
    var destroyed: Set<Int> = []
    var security: [Int: FieldSecurity] = [:]
    private(set) var reads = 0

    func frontmostApp() -> (processID: Int32, bundleID: String?)? { reads += 1; return front }
    func isRunning(processID: Int32) -> Bool { running.contains(processID) }
    func focusedField(processID: Int32) -> Int? { fields[processID] }
    func focusedWindow(processID: Int32) -> Int? { windows[processID] }
    func isAlive(_ element: Int) -> Bool { !destroyed.contains(element) }
    func security(_ element: Int) -> FieldSecurity { security[element] ?? .notSecure }
    func isSame(_ lhs: Int, _ rhs: Int) -> Bool { lhs == rhs }

    /// The key-down capture, like `FocusTarget.current()`.
    func bind() -> BoundFocus<Int> {
        let pid = front?.processID
        let field = pid.flatMap { fields[$0] }
        return BoundFocus(processID: pid, bundleID: front?.bundleID, field: field, window: pid.flatMap { windows[$0] },
                          fieldIsSecure: field.map { security($0) == .secure } ?? false)
    }

    func switchToChat() { front = (Self.chatPID, Self.chat) }
}

@MainActor
final class TargetGuardTests: XCTestCase {
    private var focus: FakeFocus!
    private var bound: BoundFocus<Int>!

    override func setUp() async throws {
        focus = FakeFocus()
        bound = focus.bind()
    }

    private func verdict() -> TargetVerdict { TargetGuard.check(bound, reader: focus) }

    // MARK: Same app, same field

    func testSameAppSameFieldIsUnchanged() {
        XCTAssertEqual(verdict(), .unchanged)
    }

    func testBoundFieldThatReadsSecureIsHeld() {
        focus.security[100] = .secure
        bound = focus.bind()
        XCTAssertEqual(verdict(), .secureField(change: nil))
    }

    func testBoundFieldWithUnreadableSubroleStillPastes() {
        // An odd AX bridge (Java, some Electron builds) must not lose every dictation.
        focus.security[100] = .unknown
        bound = focus.bind()
        XCTAssertEqual(verdict(), .unchanged)
    }

    func testSameFieldCheckReadsOnlyFocusNotSecurityAgain() {
        // Security of the key-down field is read once at key-down; the release-path re-check
        // stays one focus read.
        focus.security[100] = .secure // changed after key-down: not re-read
        XCTAssertEqual(verdict(), .unchanged)
    }

    // MARK: Another app

    func testSwitchingAppsIsAppChange() {
        focus.switchToChat()
        XCTAssertEqual(verdict(), .changed(.app))
    }

    func testSwitchingToAPasswordFieldInAnotherAppIsHeld() {
        focus.switchToChat()
        focus.security[200] = .secure
        XCTAssertEqual(verdict(), .secureField(change: .app))
    }

    func testSwitchingToAFieldOfUnknownSecurityFailsClosed() {
        focus.switchToChat()
        focus.security[200] = .unknown
        XCTAssertEqual(verdict(), .secureField(change: .app))
    }

    func testNothingFrontmostIsAppChange() {
        focus.front = nil
        XCTAssertEqual(verdict(), .changed(.app))
    }

    func testBoundAppQuitIsFieldClosed() {
        focus.running.remove(FakeFocus.mailPID)
        focus.switchToChat()
        XCTAssertEqual(verdict(), .changed(.fieldClosed))
    }

    func testReusedProcessIDWithAnotherBundleIsAppChange() {
        focus.front = (FakeFocus.mailPID, "com.example.other")
        XCTAssertEqual(verdict(), .changed(.app))
    }

    func testNoFrontmostAppAtKeyDownNeverMatches() {
        focus.front = nil
        bound = focus.bind()
        focus.front = (FakeFocus.mailPID, FakeFocus.mail)
        XCTAssertEqual(verdict(), .changed(.app))
    }

    // MARK: Same app, another field

    func testClickingAnotherFieldInTheSameAppIsFieldChange() {
        focus.fields[FakeFocus.mailPID] = 101
        XCTAssertEqual(verdict(), .changed(.field))
    }

    func testFocusOnNoFieldInTheSameAppIsFieldChange() {
        focus.fields[FakeFocus.mailPID] = nil
        XCTAssertEqual(verdict(), .changed(.field))
    }

    func testOriginalFieldDestroyedIsFieldClosed() {
        focus.destroyed.insert(100)
        focus.fields[FakeFocus.mailPID] = 101
        XCTAssertEqual(verdict(), .changed(.fieldClosed))
    }

    func testOriginalFieldDestroyedWithNothingFocusedIsFieldClosed() {
        focus.destroyed.insert(100)
        focus.fields[FakeFocus.mailPID] = nil
        XCTAssertEqual(verdict(), .changed(.fieldClosed))
    }

    func testMovingToAPasswordFieldInTheSameAppIsHeld() {
        focus.fields[FakeFocus.mailPID] = 101
        focus.security[101] = .secure
        XCTAssertEqual(verdict(), .secureField(change: .field))
    }

    func testFocusLeavingAndComingBackBeforeThePasteIsUnchanged() {
        // Hands-free: the user wandered off mid-recording and came back before finishing.
        focus.switchToChat()
        XCTAssertEqual(verdict(), .changed(.app))
        focus.front = (FakeFocus.mailPID, FakeFocus.mail)
        XCTAssertEqual(verdict(), .unchanged)
    }

    // MARK: Apps without field identity (window fallback)

    private func bindWithoutFieldIdentity() {
        focus.fields[FakeFocus.mailPID] = nil
        bound = focus.bind()
        XCTAssertNil(bound.field)
    }

    func testNoFieldIdentitySameWindowIsUnchanged() {
        bindWithoutFieldIdentity()
        XCTAssertEqual(verdict(), .unchanged)
    }

    func testNoFieldIdentityFieldAppearingLaterIsUnchanged() {
        bindWithoutFieldIdentity()
        focus.fields[FakeFocus.mailPID] = 150 // Electron's tree settled after key-down.
        XCTAssertEqual(verdict(), .unchanged)
    }

    func testNoFieldIdentityOtherWindowIsWindowChange() {
        bindWithoutFieldIdentity()
        focus.windows[FakeFocus.mailPID] = 3
        XCTAssertEqual(verdict(), .changed(.window))
    }

    func testNoFieldIdentityWindowClosedIsFieldClosed() {
        bindWithoutFieldIdentity()
        focus.destroyed.insert(1)
        focus.windows[FakeFocus.mailPID] = 3
        XCTAssertEqual(verdict(), .changed(.fieldClosed))
    }

    func testNoFieldIdentityOtherWindowWithPasswordFieldIsHeld() {
        bindWithoutFieldIdentity()
        focus.windows[FakeFocus.mailPID] = 3
        focus.fields[FakeFocus.mailPID] = 150
        focus.security[150] = .secure
        XCTAssertEqual(verdict(), .secureField(change: .window))
    }

    func testNoFieldIdentityPasswordFieldInSameWindowIsHeld() {
        bindWithoutFieldIdentity()
        focus.fields[FakeFocus.mailPID] = 150
        focus.security[150] = .secure
        XCTAssertEqual(verdict(), .secureField(change: nil))
    }

    func testNoFieldOrWindowIdentityFallsBackToSameApp() {
        focus.fields[FakeFocus.mailPID] = nil
        focus.windows[FakeFocus.mailPID] = nil
        bound = focus.bind()
        focus.windows[FakeFocus.mailPID] = 9
        XCTAssertEqual(verdict(), .unchanged)
        focus.switchToChat()
        XCTAssertEqual(verdict(), .changed(.app))
    }

    func testLogReasonsAreStable() {
        XCTAssertEqual(TargetChange.allCases.map(\.rawValue), ["app", "window", "field", "field-closed"])
    }
}
