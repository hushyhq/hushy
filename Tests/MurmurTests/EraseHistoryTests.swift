import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// "Erase dictation history" and single deletes must leave no recording on disk. Temp folders
/// and an in-memory store only; the real app folder is never touched.
@Suite("Erase dictation history and delete")
@MainActor
struct EraseHistoryTests {
    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-erase-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("erasing history deletes the audio of every dictation, including those past the 500 the Library holds")
    func eraseDeletesEveryRecording() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try Store()
        let library = Library(store: store)
        let total = 560
        var paths: [String] = []
        for index in 0..<total {
            let file = folder.appendingPathComponent("\(index).wav")
            try Data("x".utf8).write(to: file)
            paths.append(file.path)
            try store.save(Dictation(
                createdAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)),
                rawText: "hi", text: "Hi.", durationSeconds: 1, audioPath: file.path))
        }
        library.startObserving()
        for _ in 0..<300 where library.dictations.count < 500 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(library.dictations.count == 500, "the Library only holds the newest 500")

        library.eraseDictationHistory()

        let left = paths.filter { FileManager.default.fileExists(atPath: $0) }
        #expect(left.isEmpty, "\(left.count) recordings were left on disk")
        #expect(try store.recentDictations(limit: 1).isEmpty)
    }

    @Test("deleting a dictation removes its encrypted recording as well")
    func deleteRemovesEncryptedSibling() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try Store()
        let library = Library(store: store)
        let plain = folder.appendingPathComponent("one.wav")
        let sealed = folder.appendingPathComponent("one.wav.enc")
        try Data("x".utf8).write(to: sealed)
        let saved = try store.save(Dictation(rawText: "hi", text: "Hi.", durationSeconds: 1, audioPath: plain.path))

        library.deleteDictation(saved)

        #expect(!FileManager.default.fileExists(atPath: sealed.path))
    }

    @Test("deleting several dictations removes their encrypted recordings as well")
    func deleteManyRemovesEncryptedSiblings() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try Store()
        let library = Library(store: store)
        var saved: [Dictation] = []
        var sealedFiles: [URL] = []
        for index in 0..<3 {
            let sealed = folder.appendingPathComponent("\(index).wav.enc")
            try Data("x".utf8).write(to: sealed)
            sealedFiles.append(sealed)
            saved.append(try store.save(Dictation(rawText: "hi", text: "Hi.", durationSeconds: 1, audioPath: folder.appendingPathComponent("\(index).wav").path)))
        }

        library.deleteDictations(saved)

        #expect(sealedFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test("a delete that fails keeps the recording, so the row never points at a deleted file")
    func failedDeleteKeepsTheRecording() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try Store()
        let library = Library(store: store)
        let file = folder.appendingPathComponent("one.wav")
        try Data("x".utf8).write(to: file)
        let saved = try store.save(Dictation(rawText: "hi", text: "Hi.", durationSeconds: 1, audioPath: file.path))
        try store.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER block_delete BEFORE DELETE ON dictation BEGIN SELECT RAISE(ABORT, 'blocked'); END")
        }

        library.deleteDictation(saved)

        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try store.recentDictations(limit: 1).count == 1)
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    private struct HushyHome {
        let root: URL
        var audio: URL { root.appendingPathComponent("Audio", isDirectory: true) }
        var notes: URL { root.appendingPathComponent("Notes", isDirectory: true) }
        let bin: URL
        func cleanUp() { for url in [root, bin] { try? FileManager.default.removeItem(at: url) } }
    }

    private func makeHome() throws -> HushyHome {
        let root = try tempFolder()
        let bin = try tempFolder()
        return HushyHome(root: root, bin: bin)
    }

    private func makeLibrary(_ store: Store, _ home: HushyHome) -> Library {
        let library = Library(store: store, audioDirectory: home.audio)
        let bin = home.bin
        library.disposeAudio = { try FileManager.default.moveItem(at: $0, to: bin.appendingPathComponent($0.lastPathComponent)) }
        return library
    }

    @Test("an erase removes UUID-named recordings that no row names, and leaves other names, subfolders and Notes alone")
    func eraseRemovesLeftoversOnly() throws {
        let home = try makeHome()
        defer { home.cleanUp() }
        let store = try Store()
        let library = makeLibrary(store, home)
        let withRow = home.audio.appendingPathComponent("\(UUID().uuidString).wav")
        let leftover = home.audio.appendingPathComponent("\(UUID().uuidString).wav")
        let leftoverSealed = home.audio.appendingPathComponent("\(UUID().uuidString).wav.enc")
        let foreign = home.audio.appendingPathComponent("lecture-recording.wav")
        let nested = home.audio.appendingPathComponent("imports/\(UUID().uuidString).wav")
        let note = home.notes.appendingPathComponent("\(UUID().uuidString).wav")
        let outside = home.root.appendingPathComponent("\(UUID().uuidString).wav")
        for url in [withRow, leftover, leftoverSealed, foreign, nested, note, outside] { try touch(url) }
        try store.save(Dictation(rawText: "hi", text: "Hi.", durationSeconds: 1, audioPath: withRow.path))

        library.eraseDictationHistory()

        for gone in [withRow, leftover, leftoverSealed] {
            #expect(!FileManager.default.fileExists(atPath: gone.path), "\(gone.lastPathComponent) should be gone")
        }
        for kept in [foreign, nested, note, outside] {
            #expect(FileManager.default.fileExists(atPath: kept.path), "\(kept.lastPathComponent) must stay")
        }
    }

    @Test("a failed erase leaves every recording, leftovers included")
    func failedEraseKeepsLeftovers() throws {
        let home = try makeHome()
        defer { home.cleanUp() }
        let store = try Store()
        let library = makeLibrary(store, home)
        let leftover = home.audio.appendingPathComponent("\(UUID().uuidString).wav")
        try touch(leftover)
        try store.save(Dictation(rawText: "hi", text: "Hi.", durationSeconds: 1))
        try store.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER block_delete BEFORE DELETE ON dictation BEGIN SELECT RAISE(ABORT, 'blocked'); END")
        }

        library.eraseDictationHistory()

        #expect(FileManager.default.fileExists(atPath: leftover.path))
    }

    @Test("a launch never removes a recording: opening and observing the library moves nothing")
    func launchRemovesNothing() async throws {
        let home = try makeHome()
        defer { home.cleanUp() }
        let store = try Store()
        let library = makeLibrary(store, home)
        let files = (0..<3).map { _ in home.audio.appendingPathComponent("\(UUID().uuidString).wav") }
        for url in files { try touch(url) }

        library.startObserving()
        try await Task.sleep(for: .milliseconds(300))

        for url in files { #expect(FileManager.default.fileExists(atPath: url.path)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.bin.path).isEmpty)
    }

    @Test("after an erase the erased text is not left in the database log file")
    func eraseClearsTheWriteAheadLog() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("murmur.sqlite")
        let store = try Store(url: url)
        let library = Library(store: store)
        let secret = "zebra-quokka-7731"
        try store.save(Dictation(rawText: secret, text: secret, durationSeconds: 1))
        let walBefore = try Data(contentsOf: URL(fileURLWithPath: url.path + "-wal"))
        #expect(walBefore.range(of: Data(secret.utf8)) != nil, "the test needs the text in the log to begin with")

        library.eraseDictationHistory()

        let walAfter = (try? Data(contentsOf: URL(fileURLWithPath: url.path + "-wal"))) ?? Data()
        #expect(walAfter.range(of: Data(secret.utf8)) == nil)
        #expect(try Data(contentsOf: url).range(of: Data(secret.utf8)) == nil)
    }
}
