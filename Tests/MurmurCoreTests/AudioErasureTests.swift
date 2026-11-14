import Foundation
import GRDB
import Testing
@testable import MurmurCore

/// Erase, retention and orphan cleanup must leave no voice recording or spoken text behind.
/// Invented text only; every file lives in a temp folder.
@Suite("Erase and retention remove audio and voice-action text")
struct AudioErasureTests {
    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-erase-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A stand-in for the Trash, so a test never fills the real one.
    private func bin() throws -> (dispose: (URL) throws -> Void, folder: URL) {
        let folder = try tempFolder()
        return ({ try FileManager.default.moveItem(at: $0, to: folder.appendingPathComponent($0.lastPathComponent)) }, folder)
    }

    @discardableResult
    private func touch(_ url: URL, age: TimeInterval = 0, now: Date) throws -> URL {
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    @Test("erasing all dictations returns the audio path of every row, not just the newest 500")
    func eraseReturnsEveryAudioPath() throws {
        let store = try Store()
        for index in 0..<650 {
            try store.save(Dictation(
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                rawText: "hello", text: "hello", durationSeconds: 1, audioPath: "/tmp/hushy-test/\(index).wav"))
        }
        try store.save(Dictation(rawText: "no audio", text: "no audio", durationSeconds: 1))

        let paths = try store.deleteAllDictations()

        #expect(paths.count == 650)
        #expect(Set(paths).count == 650)
        #expect(try store.recentDictations(limit: 10).isEmpty)
    }

    @Test("erasing history also removes voice-action records with their spoken text, but not the usage counter")
    func eraseRemovesActionRecords() throws {
        let store = try Store()
        let record = try store.save(ActionRecord(kind: .createReminder, title: "Call Priya", sourceText: "remind me to call Priya about the invoice"))
        try store.recordVoiceActionUse(VoiceActionUse(kind: .action, actionRecordID: record.id))

        try store.deleteAllDictations()

        #expect(try store.recentActions().isEmpty)
        #expect(try store.voiceActionsThisMonth() == 1, "the Free allowance is not reset by erasing history")
    }

    @Test("text retention removes voice-action records older than the cutoff and keeps newer ones")
    func retentionRemovesOldActionRecords() throws {
        let store = try Store()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try store.save(ActionRecord(createdAt: now.addingTimeInterval(-40 * 86_400), kind: .createReminder, title: "Old", sourceText: "an old spoken request"))
        let fresh = try store.save(ActionRecord(createdAt: now.addingTimeInterval(-2 * 86_400), kind: .createReminder, title: "Fresh", sourceText: "a recent spoken request"))

        _ = try store.applyRetention(audioDays: nil, textDays: 30, now: now)

        #expect(try store.recentActions().map(\.id) == [fresh.id])
    }

    @Test("retention with no text limit keeps voice-action records")
    func retentionKeepsActionsWhenTextKept() throws {
        let store = try Store()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try store.save(ActionRecord(createdAt: now.addingTimeInterval(-400 * 86_400), kind: .createReminder, title: "Old", sourceText: "x"))
        _ = try store.applyRetention(audioDays: 7, textDays: nil, now: now)
        #expect(try store.recentActions().count == 1)
    }

    @Test("removing a recording deletes both the plain file and its encrypted sibling")
    func removeDeletesEncryptedSibling() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        let plain = try touch(folder.appendingPathComponent("a.wav"), now: now)
        let sealed = try touch(folder.appendingPathComponent("a.wav.enc"), now: now)
        let other = try touch(folder.appendingPathComponent("b.wav.enc"), now: now)

        AudioFiles.remove(plain.path)

        #expect(!FileManager.default.fileExists(atPath: plain.path))
        #expect(!FileManager.default.fileExists(atPath: sealed.path))
        #expect(FileManager.default.fileExists(atPath: other.path), "another recording is untouched")
    }

    @Test("erase cleanup moves UUID-named recordings that have no row, plain and sealed, to the bin")
    func leftoversAreMoved() throws {
        let folder = try tempFolder()
        let (dispose, binFolder) = try bin()
        defer { for url in [folder, binFolder] { try? FileManager.default.removeItem(at: url) } }
        let plain = "\(UUID().uuidString).wav"
        let sealed = "\(UUID().uuidString.lowercased()).wav.enc"
        try touch(folder.appendingPathComponent(plain), now: Date())
        try touch(folder.appendingPathComponent(sealed), now: Date())

        let moved = AudioFiles.trashLeftovers(in: folder, dispose: dispose)

        #expect(moved == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: binFolder.path)) == [plain, sealed])
    }

    @Test("erase cleanup leaves every other name, subfolders and their UUID files alone")
    func leftoversOnlyMatchUUIDNames() throws {
        let folder = try tempFolder()
        let (dispose, binFolder) = try bin()
        defer { for url in [folder, binFolder] { try? FileManager.default.removeItem(at: url) } }
        let uuid = UUID().uuidString
        var untouched: [URL] = []
        for name in ["lecture.wav", "kept-sealed.wav.enc", "\(uuid).m4a", "\(uuid).wav.bak", "\(uuid)x.wav", "x\(uuid).wav", "\(uuid).WAV", ".wav", "\(uuid).wav.enc.enc"] {
            untouched.append(try touch(folder.appendingPathComponent(name), now: Date()))
        }
        let nested = folder.appendingPathComponent("\(UUID().uuidString).wav", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        untouched.append(try touch(nested.appendingPathComponent("\(UUID().uuidString).wav"), now: Date()))
        let outside = try tempFolder()
        defer { try? FileManager.default.removeItem(at: outside) }
        let target = try touch(outside.appendingPathComponent("\(UUID().uuidString).wav"), now: Date())
        let link = folder.appendingPathComponent("\(UUID().uuidString).wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let moved = AudioFiles.trashLeftovers(in: folder, dispose: dispose)

        #expect(moved == 0)
        for url in untouched + [target] {
            #expect(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) must stay")
        }
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
    }

    @Test("a leftover that cannot be moved is kept and not counted")
    func leftoverThatCannotMoveIsKept() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try touch(folder.appendingPathComponent("\(UUID().uuidString).wav"), now: Date())

        let moved = AudioFiles.trashLeftovers(in: folder) { _ in throw CocoaError(.fileWriteNoPermission) }

        #expect(moved == 0 && FileManager.default.fileExists(atPath: file.path))
    }

    @Test("a missing folder is not an error")
    func missingFolder() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-none-\(UUID().uuidString)")
        #expect(AudioFiles.trashLeftovers(in: missing, dispose: { _ in }) == 0)
    }
}
