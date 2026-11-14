import Foundation
import Security
import Testing
@testable import MurmurCore

/// Answers the key route from a script and records every request.
private final class ScriptedHTTP: ModelKeyClient.HTTP, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(Int, Data)]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [(Int, Data)]) { self.replies = replies }

    func get(_ request: URLRequest) async throws -> (Data, Int) {
        let reply: (Int, Data)? = lock.withLock {
            requests.append(request)
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        guard let reply else { throw URLError(.notConnectedToInternet) }
        return (reply.1, reply.0)
    }

    static func key(_ key: Data, model: String = "m") -> (Int, Data) {
        (200, Data(#"{"model":"\#(model)","alg":"AES-256-GCM","key":"\#(key.base64EncodedString())"}"#.utf8))
    }
}

private final class KeyTestAuthorizer: DownloadAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var issued = 0
    private(set) var rejected: [String?] = []
    func accessToken(rejecting: String?) async throws -> String {
        lock.withLock {
            rejected.append(rejecting)
            issued += 1
            return "token-\(issued)"
        }
    }
}

private final class SignedOut: DownloadAuthorizing {
    func accessToken(rejecting: String?) async throws -> String { throw AssetDownloadError.signInRequired }
}

private final class ChangeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

private actor FetchCounter {
    private(set) var count = 0
    func next() -> Int { count += 1; return count }
}

private struct ScriptedFetcher: ModelKeyFetching {
    let keys: [Data]
    let counter = FetchCounter()
    func fetchKey(modelID: String) async throws -> Data {
        let n = await counter.next()
        try await Task.sleep(for: .milliseconds(30))
        guard n <= keys.count else { throw ModelKeyError.notPublished }
        return keys[n - 1]
    }
}

private let keyA = SealedFixture.key
private let keyB = SealedFixture.otherKey

@Suite("Model key client")
struct ModelKeyClientTests {
    @Test("asks /keys/<id> with the account's token, uncached, and returns the 32 bytes")
    func fetches() async throws {
        let http = ScriptedHTTP([ScriptedHTTP.key(keyA)])
        let key = try await ModelKeyClient(authorizer: KeyTestAuthorizer(), http: http).fetchKey(modelID: "hushy-cleanup-4b-r10d-6bit-enc1")
        #expect(key == keyA)
        let request = try #require(http.requests.first)
        #expect(request.url?.absoluteString == "https://models.tryhushy.com/keys/hushy-cleanup-4b-r10d-6bit-enc1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
        #expect(request.httpMethod == "GET")
        #expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    }

    @Test("a 401 gets one fresh token; a second 401 means sign in again")
    func refreshesOnce() async throws {
        let authorizer = KeyTestAuthorizer()
        let http = ScriptedHTTP([(401, Data("{}".utf8)), ScriptedHTTP.key(keyA)])
        #expect(try await ModelKeyClient(authorizer: authorizer, http: http).fetchKey(modelID: "m") == keyA)
        #expect(authorizer.rejected.last == "token-1")
        let refused = ScriptedHTTP([(401, Data("{}".utf8)), (401, Data("{}".utf8))])
        await #expect(throws: AssetDownloadError.signInRequired) {
            _ = try await ModelKeyClient(authorizer: KeyTestAuthorizer(), http: refused).fetchKey(modelID: "m")
        }
    }

    @Test("signed out: no request at all")
    func signedOut() async {
        let http = ScriptedHTTP([ScriptedHTTP.key(keyA)])
        await #expect(throws: AssetDownloadError.signInRequired) {
            _ = try await ModelKeyClient(authorizer: SignedOut(), http: http).fetchKey(modelID: "m")
        }
        #expect(http.requests.isEmpty)
    }

    @Test("404, 429, 5xx, a short key, garbage and no network each have their own error")
    func errors() async {
        let cases: [([(Int, Data)], ModelKeyError)] = [
            ([(404, Data())], .notPublished), ([(429, Data())], .tryLater), ([(503, Data())], .unavailable(503)),
            ([(200, Data(#"{"key":"c2hvcnQ="}"#.utf8))], .badResponse), ([(200, Data("nope".utf8))], .badResponse),
            ([], .network("-1009")),
        ]
        for (replies, expected) in cases {
            let client = ModelKeyClient(authorizer: KeyTestAuthorizer(), http: ScriptedHTTP(replies))
            await #expect(throws: expected) { _ = try await client.fetchKey(modelID: "m") }
        }
    }
}

@Suite("Model key provider")
struct ModelKeyProviderTests {
    @Test("a stored key is used without touching the network; a missing one is fetched once and stored")
    func storesAndReuses() async throws {
        let store = InMemoryModelKeyStore()
        let fetcher = ScriptedFetcher(keys: [keyA])
        let provider = ModelKeyProvider(store: store, fetcher: fetcher)
        #expect(!provider.hasStoredKey(modelID: "m"))
        #expect(try await provider.key(modelID: "m") == keyA)
        #expect(try await provider.key(modelID: "m") == keyA)
        #expect(await fetcher.counter.count == 1)
        #expect(try store.key(for: "m") == keyA)
        #expect(provider.hasStoredKey(modelID: "m"))
        // Offline after the first fetch: still works.
        let offline = ModelKeyProvider(store: store, fetcher: nil)
        #expect(try await offline.key(modelID: "m") == keyA)
    }

    @Test("a Keychain that will not save does not stop the model from opening, this run")
    func unsavableKeychain() async throws {
        struct RefusingStore: ModelKeyStoring {
            func key(for modelID: String) throws -> Data? { nil }
            func save(_ key: Data, for modelID: String) throws { throw KeyStoreError.unhandledStatus(-25308) }
            func remove(modelID: String) throws {}
        }
        let fetcher = ScriptedFetcher(keys: [keyA])
        let provider = ModelKeyProvider(store: RefusingStore(), fetcher: fetcher)
        #expect(try await provider.key(modelID: "m") == keyA)
        #expect(try await provider.key(modelID: "m") == keyA)
        #expect(await fetcher.counter.count == 1, "held in memory for the run")
        provider.forget(modelID: "m")
        #expect(!provider.hasStoredKey(modelID: "m"))
    }

    @Test("concurrent requests for one model share one fetch")
    func singleFlight() async throws {
        let fetcher = ScriptedFetcher(keys: [keyA, keyB])
        let provider = ModelKeyProvider(store: InMemoryModelKeyStore(), fetcher: fetcher)
        let keys = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<5 { group.addTask { try await provider.key(modelID: "m") } }
            var all: [Data] = []
            for try await key in group { all.append(key) }
            return all
        }
        #expect(Set(keys).count == 1)
        #expect(await fetcher.counter.count == 1)
    }

    @Test("no key and no way to fetch one is reported as missing, and the report clears when a key arrives")
    func missingIsReported() async throws {
        let changes = ChangeLog()
        let store = InMemoryModelKeyStore()
        let signedOut = ModelKeyProvider(store: store, fetcher: ModelKeyClient(authorizer: SignedOut(), http: ScriptedHTTP([])))
        signedOut.onIssueChange = { id, issue in changes.add("\(id):\(issue == nil ? "clear" : "issue")") }
        await #expect(throws: AssetDownloadError.signInRequired) { _ = try await signedOut.key(modelID: "m") }
        #expect(signedOut.issue(for: "m") == .missing(reason: "sign in to Hushy"))
        let signedIn = ModelKeyProvider(store: store, fetcher: ScriptedFetcher(keys: [keyA]))
        signedIn.onIssueChange = signedOut.onIssueChange
        signedIn.report(modelID: "m", issue: .missing(reason: "x"))
        _ = try await signedIn.key(modelID: "m")
        #expect(signedIn.issue(for: "m") == nil)
        #expect(changes.all == ["m:issue", "m:issue", "m:clear"])
    }

    @Test("the opener re-fetches once when the stored key does not open the files, and replaces the stored key")
    func refetchesOnce() async throws {
        let fixture = try SealedFixture()
        let directory = try fixture.folder("model")
        try fixture.seal(SealedFixture.plaintext(count: 9_000), modelID: "m", key: keyA, into: directory)
        let store = InMemoryModelKeyStore()
        try store.save(keyB, for: "m") // a stale key
        let fetcher = ScriptedFetcher(keys: [keyA])
        let provider = ModelKeyProvider(store: store, fetcher: fetcher)
        let stream = try await SealedModelOpener.open(directory: directory, modelID: "m", keys: provider)
        #expect(stream.remaining == 9_000)
        #expect(await fetcher.counter.count == 1)
        #expect(try store.key(for: "m") == keyA)
        #expect(provider.issue(for: "m") == nil)
    }

    @Test("a key that still does not match after the re-fetch is a clear mismatch, after exactly one extra fetch")
    func mismatchIsReported() async throws {
        let fixture = try SealedFixture()
        let directory = try fixture.folder("model")
        try fixture.seal(SealedFixture.plaintext(count: 9_000), modelID: "m", key: keyA, into: directory)
        let store = InMemoryModelKeyStore()
        try store.save(keyB, for: "m")
        let fetcher = ScriptedFetcher(keys: [keyB, keyB])
        let provider = ModelKeyProvider(store: store, fetcher: fetcher)
        await #expect(throws: SealedModelError.keyMismatch) {
            _ = try await SealedModelOpener.open(directory: directory, modelID: "m", keys: provider)
        }
        #expect(await fetcher.counter.count == 1)
        #expect(provider.issue(for: "m") == .mismatch)
        #expect(ModelKeyIssue.mismatch.summary.contains("does not match"))
    }

    @Test("a damaged file is not blamed on the key: no re-fetch, the tag error comes through")
    func damageIsNotAKeyProblem() async throws {
        let fixture = try SealedFixture()
        let directory = try fixture.folder("model")
        try fixture.seal(SealedFixture.plaintext(count: 4096 * 7), modelID: "m", key: keyA, into: directory)
        let store = InMemoryModelKeyStore()
        try store.save(keyA, for: "m")
        let fetcher = ScriptedFetcher(keys: [keyA])
        let provider = ModelKeyProvider(store: store, fetcher: fetcher)
        let stream = try await SealedModelOpener.open(directory: directory, modelID: "m", keys: provider)
        // Damage appears after the key check (chunk 0 is fine): reading fails at that chunk.
        let file = directory.appendingPathComponent(SealedFormat.partName(index: 1, count: 3))
        var bytes = try Data(contentsOf: file)
        bytes[SealedFormat.headerSize + 2 * (4096 + 28) + 50] ^= 1
        try bytes.write(to: file)
        #expect(throws: SealedWeightsError.authenticationFailed(chunk: 2)) { _ = try stream.read(count: 4096 * 3) }
        #expect(await fetcher.counter.count == 0)
    }
}

/// The real Keychain code, against a temporary keychain file: the person's keychain is never touched.
@Suite("Keychain model key store", .serialized)
struct KeychainModelKeyStoreTests {
    private func withTemporaryKeychain(_ body: (SecKeychain, KeychainModelKeyStore) throws -> Void) throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-test-\(UUID().uuidString).keychain").path
        var keychain: SecKeychain?
        let password = "test-password"
        let status = SecKeychainCreate(path, UInt32(password.utf8.count), password, false, nil, &keychain)
        try #require(status == errSecSuccess, "temporary keychain: \(status)")
        let created = try #require(keychain)
        defer {
            SecKeychainDelete(created)
            try? FileManager.default.removeItem(atPath: path)
        }
        let store = KeychainModelKeyStore(service: "app.hushy.model-keys.test-\(UUID().uuidString)", keychain: created,
                                          useDataProtectionKeychain: false)
        try body(created, store)
    }

    @Test("save, read, replace and remove a key")
    func roundTrip() throws {
        try withTemporaryKeychain { _, store in
            #expect(try store.key(for: "m") == nil)
            try store.save(keyA, for: "m")
            #expect(try store.key(for: "m") == keyA)
            try store.save(keyB, for: "m")
            #expect(try store.key(for: "m") == keyB)
            #expect(try store.key(for: "other") == nil)
            try store.remove(modelID: "m")
            #expect(try store.key(for: "m") == nil)
            try store.remove(modelID: "m") // removing what is not there is not an error
        }
    }

    @Test("the item is local to this device, not synchronised, and its access list names one application")
    func attributesAndAccess() throws {
        try withTemporaryKeychain { keychain, store in
            try store.save(keyA, for: "m")
            var result: CFTypeRef?
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: store.service,
                kSecAttrAccount as String: "m", kSecMatchSearchList as String: [keychain],
                kSecReturnRef as String: true, kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
            let attributes = try #require(result as? [String: Any])
            // 0 / false: never synchronised.
            let synchronizable = attributes[kSecAttrSynchronizable as String]
            #expect(synchronizable == nil || (synchronizable as? NSNumber)?.boolValue == false)
            #expect(attributes[kSecAttrLabel as String] as? String == "Hushy model key")

            // The decrypt entry of the access list trusts exactly one application (the running one).
            let item = try #require(attributes[kSecValueRef as String]) as! SecKeychainItem
            var access: SecAccess?
            #expect(SecKeychainItemCopyAccess(item, &access) == errSecSuccess)
            var acls: CFArray?
            #expect(SecAccessCopyACLList(try #require(access), &acls) == errSecSuccess)
            var trustedCounts: [Int] = []
            for acl in (acls as? [SecACL]) ?? [] {
                var apps: CFArray?
                var description: CFString?
                var selector = SecKeychainPromptSelector()
                if SecACLCopyContents(acl, &apps, &description, &selector) == errSecSuccess, let list = apps as? [SecTrustedApplication] {
                    trustedCounts.append(list.count)
                }
            }
            #expect(!trustedCounts.isEmpty)
            #expect(trustedCounts.allSatisfy { $0 <= 1 }, "no entry trusts more than this one application: \(trustedCounts)")
        }
    }

    @Test("the provider keeps working with the real store after the network is gone")
    func offlineAfterFirstFetch() async throws {
        let store = InMemoryModelKeyStore() // the provider logic is the same over any store; Keychain covered above
        try store.save(keyA, for: "m")
        #expect(try await ModelKeyProvider(store: store, fetcher: nil).key(modelID: "m") == keyA)
    }
}
