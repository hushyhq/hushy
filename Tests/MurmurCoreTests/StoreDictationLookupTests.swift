import Foundation
import Testing
@testable import MurmurCore

/// Reading one dictation by its identifier (History's "open this one"). In-memory store,
/// invented text.
@Suite("Store — one dictation by id")
struct StoreDictationLookupTests {
    @Test("a stored dictation is read back by its id, and a deleted or unknown id reads as nil")
    func lookup() throws {
        let store = try Store()
        let saved = try store.save(Dictation(
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), rawText: "thanks that works for me",
            text: "Thanks, that works for me.", appBundleID: "com.apple.mail", appName: "Mail", durationSeconds: 2))
        let id = try #require(saved.id)

        let found = try store.dictation(id: id)
        #expect(found?.text == "Thanks, that works for me.")
        #expect(found?.createdAt == saved.createdAt)
        #expect(try store.dictation(id: id + 999) == nil)

        try store.deleteDictation(id: id)
        #expect(try store.dictation(id: id) == nil)
    }

    @Test("reading by id changes nothing")
    func readOnly() throws {
        let store = try Store()
        let saved = try store.save(Dictation(rawText: "one two", text: "One two.", durationSeconds: 1))
        let before = try store.recentDictations()
        _ = try store.dictation(id: try #require(saved.id))
        #expect(try store.recentDictations() == before)
    }
}
