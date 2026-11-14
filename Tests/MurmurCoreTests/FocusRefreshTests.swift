import XCTest
@testable import MurmurCore

/// When a field found at paste time may replace what key-down saw. Key-down sometimes sees only a
/// container (a web area, a group) because the app's accessibility tree is not built yet; the
/// real field appears later. It is adopted only inside that container, in the same app and
/// window, and never when it may be a password field. Everything else stays "focus moved".
final class FocusRefreshTests: XCTestCase {
    private func mayAdopt(
        original: FocusAnswer = .unknown, hadElement: Bool = true, sameApp: Bool = true, sameWindow: Bool = true,
        current: FocusAnswer = .field, insideOriginal: Bool = true, security: FieldSecurity = .notSecure
    ) -> Bool {
        FocusRefresh.mayAdopt(original: original, hadElement: hadElement, sameApp: sameApp, sameWindow: sameWindow,
                              current: current, insideOriginal: insideOriginal, security: security)
    }

    func testAFieldInsideTheKeyDownContainerIsAdopted() {
        XCTAssertTrue(mayAdopt())
    }

    func testAFieldOutsideTheKeyDownContainerIsNotAdopted() {
        XCTAssertFalse(mayAdopt(insideOriginal: false))
    }

    func testAnotherWindowIsNeverAdopted() {
        XCTAssertFalse(mayAdopt(sameWindow: false))
    }

    func testAnotherAppIsNeverAdopted() {
        XCTAssertFalse(mayAdopt(sameApp: false))
    }

    func testOnlyARealFieldIsAdopted() {
        XCTAssertFalse(mayAdopt(current: .unknown))
        XCTAssertFalse(mayAdopt(current: .noField))
    }

    func testAPasswordFieldOrOneThatMightBeIsNeverAdoptedInsideAContainer() {
        XCTAssertFalse(mayAdopt(security: .secure))
        XCTAssertFalse(mayAdopt(security: .unknown), "a field whose security cannot be read keeps today's fail-closed path")
    }

    func testOnlyAnUncertainKeyDownAnswerIsRefreshed() {
        XCTAssertFalse(mayAdopt(original: .field))
        XCTAssertFalse(mayAdopt(original: .noField), "no text field at key-down is not rescued by a later one")
    }

    func testNothingAtKeyDownStillAdoptsALateFieldInTheSameWindow() {
        // Unchanged from before: there is no container to be inside of.
        XCTAssertTrue(mayAdopt(hadElement: false, insideOriginal: false))
        XCTAssertFalse(mayAdopt(hadElement: false, sameWindow: false, insideOriginal: false))
    }

    func testNothingAtKeyDownNeverAdoptsAFieldThatIsOrMightBeAPasswordField() {
        XCTAssertFalse(mayAdopt(hadElement: false, insideOriginal: false, security: .secure))
        XCTAssertFalse(mayAdopt(hadElement: false, insideOriginal: false, security: .unknown),
                       "a security read that failed or timed out is not a yes")
    }

    func testTheDefaultsRefuseAContainerCase() {
        XCTAssertFalse(FocusRefresh.mayAdopt(original: .unknown, hadElement: true, sameApp: true,
                                             sameWindow: true, current: .field))
    }

    // MARK: The parent chain

    /// A tree as child → parent. 1 is the root.
    private let parents = [5: 4, 4: 3, 3: 2, 2: 1, 9: 8, 8: 1]

    private func isInside(_ element: Int, _ ancestor: Int, limit: Int = FocusRefresh.ancestorLimit,
                          parents: [Int: Int]? = nil) -> Bool {
        let tree = parents ?? self.parents
        return FocusRefresh.isInside(element, ancestor: ancestor, limit: limit,
                                     parent: { tree[$0] }, isSame: { $0 == $1 })
    }

    func testAParentChainThatReachesTheContainerIsInside() {
        XCTAssertTrue(isInside(5, 2))
        XCTAssertTrue(isInside(5, 4), "the direct parent")
        XCTAssertTrue(isInside(5, 1))
    }

    func testAFieldInAnotherSubtreeIsNotInside() {
        XCTAssertFalse(isInside(9, 2))
        XCTAssertFalse(isInside(5, 8))
    }

    func testAnElementIsNotInsideItself() {
        XCTAssertFalse(isInside(2, 2))
    }

    func testAParentThatCannotBeReadEndsTheSearch() {
        XCTAssertFalse(isInside(5, 1, parents: [5: 4]), "the read of 4's parent failed")
        XCTAssertFalse(isInside(7, 1), "no parent at all")
    }

    func testTheSearchStopsAtTheBound() {
        XCTAssertTrue(isInside(5, 1, limit: 4))
        XCTAssertFalse(isInside(5, 1, limit: 3), "the container is four steps up")
        XCTAssertFalse(isInside(5, 4, limit: 0))
    }

    func testAParentCycleCannotRunForEver() {
        XCTAssertFalse(isInside(1, 99, parents: [1: 2, 2: 1]))
    }

    func testTheBoundIsNamed() {
        XCTAssertEqual(FocusRefresh.ancestorLimit, 24)
    }
}
