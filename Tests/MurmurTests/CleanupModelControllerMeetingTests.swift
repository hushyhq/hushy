import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// Which model note and meeting summaries use, and that the 4B is never loaded a second time for them.
extension CleanupModelControllerTests {
    private static let pro24 = MachineProfile(physicalMemoryGB: 24, chip: .pro, chipName: "Apple M4 Pro")
    private static let pro16 = MachineProfile(physicalMemoryGB: 16, chip: .pro, chipName: "Apple M4 Pro")

    private func summaryCall(_ rig: Rig) async throws -> String {
        try await rig.controller.meeting.respond(
            instructions: "Write meeting notes.", prompt: "Transcript", schema: SmartCleaner.cleanedSchema, options: .greedy)
    }

    @Test("24 GB Pro with the 4B: summaries use the loaded 4B, one instance, no Apple FM")
    func fourBSharesItsInstance() async throws {
        let rig = rig(choice: .local, machine: Self.pro24, useIntentModels: true, alsoInstalled: [ModelRegistry.hushyCleanup4B])
        rig.downloads.start()
        await settle()
        #expect(rig.controller.effective == .local(ModelRegistry.hushyCleanup4B))
        #expect(rig.controller.meeting.route == .sharedLocal)
        let dictation = try await answer(rig.controller.backend)
        let first = try await summaryCall(rig), second = try await summaryCall(rig)
        #expect(dictation == #"{"text":"local:\#(ModelRegistry.hushyCleanup4B)"}"#)
        #expect(first == dictation && second == dictation, "the same model answered the summaries")
        #expect(rig.locals.all.count == 1, "one model built for cleanup and meetings together; no second load")
        #expect(rig.locals.all.first?.calls == 3)
        #expect(rig.apple.calls == 0)
    }

    @Test("16 GB Pro with the 2B: summaries stay on Apple FM and the 2B is not used")
    func twoBLeavesMeetingsOnApple() async throws {
        let rig = rig(choice: .local, machine: Self.pro16, useIntentModels: true, alsoInstalled: [ModelRegistry.hushyCleanup2BIntent])
        rig.downloads.start()
        await settle()
        #expect(rig.controller.effective == .local(ModelRegistry.hushyCleanup2BIntent))
        #expect(rig.controller.meeting.route == .apple)
        #expect(try await summaryCall(rig) == #"{"text":"apple"}"#)
        #expect(rig.locals.all.first?.calls == 0)
        #expect(rig.locals.all.count == 1)
    }

    @Test("the 4B still downloading: the 2B answers dictation, summaries stay on Apple FM until the 4B is ready")
    func standInThen4B() async throws {
        let rig = rig(choice: .local, holds: true, machine: Self.pro24, useIntentModels: true,
                      alsoInstalled: [ModelRegistry.hushyCleanup2BIntent])
        rig.downloads.start()
        await settle()
        #expect(rig.controller.effective == .local(ModelRegistry.hushyCleanup2BIntent))
        #expect(rig.controller.meeting.route == .apple)
        rig.fetch.release()
        await settle()
        #expect(rig.controller.effective == .local(ModelRegistry.hushyCleanup4B))
        #expect(rig.controller.meeting.route == .sharedLocal)
    }

    @Test("when the 4B cannot run (memory pressure), a summary call is answered by Apple FM through the cleanup chain")
    func fourBFails() async throws {
        let rig = rig(choice: .local, machine: Self.pro24, useIntentModels: true, alsoInstalled: [ModelRegistry.hushyCleanup4B])
        rig.downloads.start()
        await settle()
        rig.controller.memoryPressure(.critical)
        #expect(rig.controller.meeting.route == .sharedLocal, "still routed to the 4B; the chain falls back per call")
        #expect(try await summaryCall(rig) == #"{"text":"apple"}"#)
        #expect(rig.locals.all.first?.calls == 0)
        #expect(rig.locals.all.count == 1)
    }

    @Test("switching cleanup to Apple Intelligence or back to the 4B re-routes summaries without a restart")
    func followsTheSetting() async throws {
        let rig = rig(choice: .local, machine: Self.pro24, useIntentModels: true, alsoInstalled: [ModelRegistry.hushyCleanup4B])
        rig.downloads.start()
        await settle()
        #expect(rig.controller.meeting.route == .sharedLocal)
        rig.controller.choose(.apple)
        #expect(rig.controller.meeting.route == .apple)
        #expect(try await summaryCall(rig) == #"{"text":"apple"}"#)
        rig.controller.choose(.rules)
        #expect(rig.controller.meeting.route == .apple, "rules-only cleanup does not turn summaries off")
        rig.controller.choose(.local)
        await settle()
        #expect(rig.controller.meeting.route == .sharedLocal)
    }
}
