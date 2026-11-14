import Foundation
import Testing
@testable import MurmurCore

@Suite("Training pair shipping parity")
struct TrainingPairLayoutTests {
    @Test func flattenedCommandLayoutIsNotATrainingTarget() {
        let raw = "Pack the charger, new paragraph, label the spare cable."
        let draft = TextCleaner(options: CleanupOptions(level: .clean)).clean(raw).text
        #expect(draft.contains("\n\n"))
        #expect(TrainingPairCheck.check(raw: raw, target: draft, level: .clean).rejection == nil)
        let flattened = draft.replacingOccurrences(of: "\n\n", with: " ")
        #expect(TrainingPairCheck.check(raw: raw, target: flattened, level: .clean).rejection == SpokenLayoutGuard.reason)
    }

    @Test func requestMetadataMatchesAlwaysCleanGate() {
        #expect(TrainingPairCheck.check(raw: "The package arrived.", target: "The package arrived.", level: .clean).modelAsked)
        #expect(!TrainingPairCheck.check(raw: "the package arrived", target: "the package arrived", level: .verbatim).modelAsked)
    }
}
