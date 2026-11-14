import Foundation
import MurmurCore
import Testing
@testable import Murmur

@Suite("Keep as heard review")
@MainActor
struct KeepHeardReviewTests {
    private func entry(_ id: Int64, status: KeepHeardEntry.Status = .active) -> KeepHeardEntry {
        KeepHeardEntry(id: id, appBundleID: "app.quillpad.mail", heardKey: "text", writtenKey: "next",
                       heard: "text", written: "Next", source: "boost", status: status)
    }

    @Test("Active app exceptions show; tombstones hide")
    func visibility() {
        let review = KeepHeardReview(forget: { _ in }, restore: { _ in })
        let rows = review.rows(entries: [entry(1), entry(2, status: .forgotten)])
        #expect(rows.map(\.entry.id) == [1])
        #expect(rows.first?.forgotten == false)
    }

    @Test("Forget leaves an Undo row and Undo restores its exact snapshot")
    func forgetAndUndo() {
        var forgotten: [KeepHeardEntry] = []
        var restored: [KeepHeardEntry] = []
        let review = KeepHeardReview(forget: { forgotten.append($0) }, restore: { restored.append($0) })
        let original = entry(1)
        review.forget(original)
        #expect(forgotten == [original])
        #expect(review.rows(entries: [entry(1, status: .forgotten)]).first?.forgotten == true)
        review.undo(1)
        #expect(restored == [original])
        #expect(review.rows(entries: [original]).first?.forgotten == false)
    }

    @Test("Delete all removes stale Undo rows")
    func deletedRows() {
        let review = KeepHeardReview(forget: { _ in }, restore: { _ in })
        review.forget(entry(1))
        #expect(review.rows(entries: []).isEmpty)
    }

    @Test("Learned style names are readable rather than raw signal keys")
    func styleNames() {
        for (key, phrase) in [("noGreeting", "leave out greetings"), ("noExclamation", "leave out exclamation marks"),
                              ("signOff:,", "end sign-offs")] {
            let item = LearnedItem(kind: .styleSignal, key: "format:\(key)", value: "format:\(key)",
                                   appBundleID: "app.quillpad.mail", status: .active)
            #expect(LearnedPresentation.styleSentence(item, appName: "Quillpad")?.contains(phrase) == true)
        }
    }

}
