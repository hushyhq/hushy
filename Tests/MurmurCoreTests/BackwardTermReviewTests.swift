import Foundation
import GRDB
import Testing
@testable import MurmurCore

@Suite("Backwards-learned terms get one review")
struct BackwardTermReviewTests {
    @Test func dictionaryHearingIsSurfacedWithoutDeletingAndChoicePersists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backward-review-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("test.sqlite")
        let store = try Store(url: url)
        let id = try store.writer.write { db in
            var dictionary = DictionaryEntry(term: "Codex")
            try dictionary.insert(db)
            var item = LearnedItem(kind: .term, key: "codec", value: "codec", heardAs: ["Codex"], status: .active)
            try item.insert(db)
            return item.id!
        }
        #expect(try store.backwardTermReviews().map(\.id) == [id])
        #expect(try store.learnedItems().first?.status == .active)
        try store.resolveBackwardTermReview(id: id, forget: false)
        #expect(try store.backwardTermReviews().isEmpty)
        #expect(try store.learnedItems().first?.status == .active)
        #expect(try Store(url: url).backwardTermReviews().isEmpty)
        // Later observations must not ask the same question again.
        try store.writer.write { db in
            try db.execute(sql: "UPDATE learnedItem SET observations = observations + 1 WHERE id = ?", arguments: [id])
        }
        #expect(try store.backwardTermReviews().isEmpty)
        try store.deleteAllLearnedItems()
        #expect(try store.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM learnedTermReview") } == 0)
    }

    @Test func forgetIsExplicitAndUnrelatedOrSameSpellingTermsAreNotFlagged() throws {
        let store = try Store()
        try store.writer.write { db in
            var dictionary = DictionaryEntry(term: "Codex")
            try dictionary.insert(db)
            for (term, heard) in [("codec", "Codex"), ("Codex", "codex"), ("Priya", "Pria")] {
                var item = LearnedItem(kind: .term, key: term.lowercased(), value: term, heardAs: [heard], status: .active)
                try item.insert(db)
            }
        }
        let review = try #require(store.backwardTermReviews().first)
        #expect(try store.backwardTermReviews().count == 1)
        try store.resolveBackwardTermReview(id: try #require(review.id), forget: true)
        #expect(try store.backwardTermReviews().isEmpty)
        #expect(try store.learnedItems().first { $0.id == review.id }?.status == .forgotten)
    }

    @Test func twoLearnedTermsThatUndoEachOtherAskAboutTheNewerOnly() throws {
        let older = Date(timeIntervalSince1970: 1_900_000_000)
        let items = [
            LearnedItem(id: 1, kind: .term, key: "velora", value: "Velora", heardAs: ["Valora"], status: .active,
                        createdAt: older),
            LearnedItem(id: 2, kind: .term, key: "valora", value: "Valora", heardAs: ["Velora"], status: .candidate,
                        createdAt: older.addingTimeInterval(86_400)),
            LearnedItem(id: 3, kind: .term, key: "nerula", value: "Nerula", heardAs: ["Nerulla"], status: .active,
                        createdAt: older.addingTimeInterval(2 * 86_400)),
        ]
        #expect(BackwardTermReview.pending(items: items, dictionary: [], reviewed: []).map(\.id) == [2])
        #expect(BackwardTermReview.pending(items: items, dictionary: [], reviewed: [2]).isEmpty)
        let forgottenFirst = [Learner.forget(items[0]), items[1], items[2]]
        #expect(BackwardTermReview.pending(items: forgottenFirst, dictionary: [], reviewed: []).isEmpty)
    }

    @Test func keepingTheNewerOfTwoOppositeTermsForgetsTheOlder() throws {
        let store = try Store()
        let older = Date(timeIntervalSince1970: 1_900_000_000)
        let ids = try store.writer.write { db -> (Int64, Int64) in
            var first = LearnedItem(kind: .term, key: "velora", value: "Velora", heardAs: ["Valora"], status: .active, createdAt: older)
            try first.insert(db)
            var second = LearnedItem(kind: .term, key: "valora", value: "Valora", heardAs: ["Velora"], status: .active,
                                     createdAt: older.addingTimeInterval(86_400))
            try second.insert(db)
            return (try #require(first.id), try #require(second.id))
        }
        #expect(try store.backwardTermReviews().map(\.id) == [ids.1])
        try store.resolveBackwardTermReview(id: ids.1, forget: false)
        let items = try store.learnedItems()
        #expect(items.first { $0.id == ids.0 }?.status == .forgotten)
        #expect(items.first { $0.id == ids.1 }?.status == .active)
        #expect(try store.backwardTermReviews().isEmpty)
    }
}
