import Foundation
import Testing
@testable import MurmurCore

@Suite("File key store")
struct FileKeyStoreTests {
    private func makeStore() throws -> (FileKeyStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("file-key-store-\(UUID().uuidString)", isDirectory: true)
        let url = folder.appendingPathComponent("nested/account.keys")
        return (FileKeyStore(url: url), url)
    }

    @Test("reads nothing before anything is written, and makes no file")
    func emptyStore() throws {
        let (store, url) = try makeStore()
        #expect(try store.read(account: "account.session") == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a written item reads back, and items do not overwrite each other")
    func roundTrip() throws {
        let (store, _) = try makeStore()
        try store.write(Data("one".utf8), account: "account.session")
        try store.write(Data("two".utf8), account: "account.betaApproval")
        try store.write(Data("three".utf8), account: "account.session")
        #expect(try store.read(account: "account.session") == Data("three".utf8))
        #expect(try store.read(account: "account.betaApproval") == Data("two".utf8))
    }

    @Test("the file is readable only by its owner and leaves no temporary file behind")
    func ownerOnly() throws {
        let (store, url) = try makeStore()
        try store.write(Data("secret".utf8), account: "account.session")
        let mode = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue == 0o600)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("tmp").path))
    }

    @Test("a second store on the same file sees what the first wrote")
    func sharedFile() throws {
        let (store, url) = try makeStore()
        try store.write(Data("kept".utf8), account: "account.session")
        #expect(try FileKeyStore(url: url).read(account: "account.session") == Data("kept".utf8))
    }

    @Test("deleting removes only that item; deleting a missing item is not an error")
    func delete() throws {
        let (store, _) = try makeStore()
        try store.write(Data("a".utf8), account: "account.session")
        try store.write(Data("b".utf8), account: "account.betaApproval")
        try store.delete(account: "account.session")
        try store.delete(account: "never.there")
        #expect(try store.read(account: "account.session") == nil)
        #expect(try store.read(account: "account.betaApproval") == Data("b".utf8))
    }

    @Test("a damaged file is an error to read and is replaced by the next write")
    func damagedFile() throws {
        let (store, url) = try makeStore()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try store.read(account: "account.session") }
        try store.write(Data("fresh".utf8), account: "account.session")
        #expect(try store.read(account: "account.session") == Data("fresh".utf8))
    }

    @Test("the account stores keep their data in the app's folder by default, not the Keychain")
    func accountDefaultFollowsTheAppFolder() {
        #expect(FileKeyStore.account.fileURL.deletingLastPathComponent().path == AppPaths.supportDirectory.path)
        #expect(FileKeyStore.account.fileURL.lastPathComponent == "account.keys")
    }
}
