import Foundation
import Testing
@testable import MurmurCore

@Suite("Media path rebase after rename")
struct MediaPathRebaseTests {
    @Test("old absolute audio paths move to the new data folder; others untouched")
    func rebases() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("rebase-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = try Store(url: scratch.appendingPathComponent("t.sqlite"))
        let old = "/Users/x/Library/Application Support/Murmur"
        let new = "/Users/x/Library/Application Support/Hushy"
        var moved = Dictation(rawText: "a", text: "a", durationSeconds: 1, status: .inserted)
        moved.audioPath = old + "/Audio/one.wav"
        var elsewhere = Dictation(rawText: "b", text: "b", durationSeconds: 1, status: .inserted)
        elsewhere.audioPath = "/tmp/other.wav"
        let a = try store.save(moved), b = try store.save(elsewhere)

        #expect(try store.rebaseMediaPaths(from: old, to: new) == 1)
        #expect(try store.rebaseMediaPaths(from: old, to: new) == 0)   // idempotent
        let all = try store.writer.read { try Dictation.fetchAll($0) }
        #expect(all.first { $0.id == a.id }?.audioPath == new + "/Audio/one.wav")
        #expect(all.first { $0.id == b.id }?.audioPath == "/tmp/other.wav")
    }
}

@Suite("Text retention")
struct TextRetentionTests {
    @Test("dictations older than the text window are deleted with their audio; newer stay")
    func expiresOldText() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ret-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = try Store(url: scratch.appendingPathComponent("t.sqlite"))
        let now = Date()
        var old = Dictation(createdAt: now.addingTimeInterval(-40 * 86_400), rawText: "old", text: "old", durationSeconds: 1, status: .inserted)
        old.audioPath = "/tmp/old.wav"
        let fresh = Dictation(createdAt: now.addingTimeInterval(-5 * 86_400), rawText: "new", text: "new", durationSeconds: 1, status: .inserted)
        _ = try store.save(old); _ = try store.save(fresh)

        let removed = try store.applyRetention(audioDays: nil, textDays: 30, now: now)
        #expect(removed == ["/tmp/old.wav"])
        let remaining = try store.writer.read { try Dictation.fetchAll($0) }.map(\.text)
        #expect(remaining == ["new"])
        #expect(try store.applyRetention(audioDays: nil, textDays: nil, now: now).isEmpty)
    }
}
