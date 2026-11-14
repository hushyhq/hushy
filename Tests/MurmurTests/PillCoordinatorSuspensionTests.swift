import Testing
@testable import Murmur

/// While the sign-in gate has the app suspended, no pill state change may bring the panel back.
@MainActor
@Suite("Pill coordinator while suspended", .serialized, .timeLimit(.minutes(1)))
struct PillCoordinatorSuspensionTests {
    @Test("hidden means no state change orders the panel front, until it is unhidden")
    func hiddenStaysHidden() {
        let coordinator = PillCoordinator(pill: PillModel(), fullScreenDetector: .never)
        #expect(coordinator.shouldOrderFront)
        coordinator.hide()
        #expect(!coordinator.shouldOrderFront)
        coordinator.unhide()
        #expect(coordinator.shouldOrderFront)
    }
}
