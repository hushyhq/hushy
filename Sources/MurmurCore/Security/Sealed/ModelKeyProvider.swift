import Foundation
import Synchronization

/// What is wrong with a sealed model's key, in words the app can show.
public enum ModelKeyIssue: Equatable, Sendable {
    /// No key on this Mac and none could be fetched (signed out, offline, or the host has none yet).
    case missing(reason: String)
    /// The stored key does not open the downloaded files, and a fresh one did not either.
    case mismatch

    public var summary: String {
        switch self {
        case .missing(let reason): "Hushy's model key is not on this Mac yet (\(reason))."
        case .mismatch: "Hushy's model key does not match the downloaded model."
        }
    }
}

/// Fetches a sealed model's key from the model host.
public protocol ModelKeyFetching: Sendable {
    func fetchKey(modelID: String) async throws -> Data
}

/// What the loader asks for. `refetch` means the key it has did not open the files: ask the host again.
public protocol SealedKeySource: Sendable {
    func key(modelID: String, refetch: Bool) async throws -> Data
    func report(modelID: String, issue: ModelKeyIssue?)
}

public enum ModelKeyError: Error, Equatable, LocalizedError {
    case notPublished
    case tryLater
    case unavailable(Int)
    case badResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .notPublished: "The model host has no key for this model yet."
        case .tryLater: "Too many requests; try again in a minute."
        case .unavailable(let code): "The model host could not give the key (\(code))."
        case .badResponse: "The model host sent a key that is not valid."
        case .network(let why): "Could not reach the model host (\(why))."
        }
    }
}

/// `GET https://models.tryhushy.com/keys/<model id>` with the account's token. The answer is never cached
/// (ephemeral session, no URL cache) and never logged.
public struct ModelKeyClient: ModelKeyFetching {
    public static let endpoint = URL(string: "https://\(ModelDownloadHost.host)/keys/")!

    public protocol HTTP: Sendable {
        func get(_ request: URLRequest) async throws -> (Data, Int)
    }

    struct Ephemeral: HTTP {
        func get(_ request: URLRequest) async throws -> (Data, Int) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    private let authorizer: any DownloadAuthorizing
    private let http: any HTTP

    public init(authorizer: any DownloadAuthorizing) {
        self.init(authorizer: authorizer, http: Ephemeral())
    }

    init(authorizer: any DownloadAuthorizing, http: any HTTP) {
        self.authorizer = authorizer
        self.http = http
    }

    public func fetchKey(modelID: String) async throws -> Data {
        let token = try await authorizer.accessToken(rejecting: nil)
        var (body, status) = try await send(modelID, token: token)
        if status == 401 {
            let fresh = try await authorizer.accessToken(rejecting: token)
            guard fresh != token else { throw AssetDownloadError.signInRequired }
            (body, status) = try await send(modelID, token: fresh)
            if status == 401 { throw AssetDownloadError.signInRequired }
        }
        switch status {
        case 200: return try Self.parse(body)
        case 404: throw ModelKeyError.notPublished
        case 429: throw ModelKeyError.tryLater
        default: throw ModelKeyError.unavailable(status)
        }
    }

    private func send(_ modelID: String, token: String) async throws -> (Data, Int) {
        var request = URLRequest(url: Self.endpoint.appendingPathComponent(modelID))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        do {
            return try await http.get(request)
        } catch {
            throw ModelKeyError.network((error as? URLError)?.code.rawValue.description ?? "request failed")
        }
    }

    static func parse(_ body: Data) throws -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let text = object["key"] as? String, let key = Data(base64Encoded: text),
              key.count == SealedFormat.keySize else { throw ModelKeyError.badResponse }
        return key
    }
}

/// The app's one source of sealed-model keys: the store first, the host when the store has none (or when the
/// stored key did not open the files). Concurrent requests for one model share one fetch.
public final class ModelKeyProvider: SealedKeySource, @unchecked Sendable {
    private let store: any ModelKeyStoring
    private let fetcher: (any ModelKeyFetching)?
    private let issues = Mutex<[String: ModelKeyIssue]>([:])
    private let inFlight = Mutex<[String: Task<Data, Error>]>([:])
    /// Keys held for this run. A Keychain that will not save (locked, missing, or asking for a password) must not
    /// keep a downloaded model from opening; the key is then fetched again next launch.
    private let memory = Mutex<[String: Data]>([:])
    private let listener = Mutex<(@Sendable (String, ModelKeyIssue?) -> Void)?>(nil)

    /// Called (on any thread) whenever a model's key issue appears, changes or clears.
    public var onIssueChange: (@Sendable (String, ModelKeyIssue?) -> Void)? {
        get { listener.withLock { $0 } }
        set { listener.withLock { $0 = newValue } }
    }

    public init(store: any ModelKeyStoring, fetcher: (any ModelKeyFetching)?) {
        self.store = store
        self.fetcher = fetcher
    }

    public func key(modelID: String, refetch: Bool = false) async throws -> Data {
        if !refetch {
            if let held = memory.withLock({ $0[modelID] }) { return held }
            if let stored = try? store.key(for: modelID), stored.count == SealedFormat.keySize {
                memory.withLock { $0[modelID] = stored }
                return stored
            }
        }
        guard let fetcher else {
            let error = ModelKeyError.notPublished
            report(modelID: modelID, issue: .missing(reason: "not signed in"))
            throw error
        }
        let task: Task<Data, Error> = inFlight.withLock { running in
            if let existing = running[modelID] { return existing }
            let created = Task { try await fetcher.fetchKey(modelID: modelID) }
            running[modelID] = created
            return created
        }
        do {
            let key = try await task.value
            inFlight.withLock { _ = $0.removeValue(forKey: modelID) }
            memory.withLock { $0[modelID] = key }
            try? store.save(key, for: modelID)
            report(modelID: modelID, issue: nil)
            return key
        } catch {
            inFlight.withLock { _ = $0.removeValue(forKey: modelID) }
            report(modelID: modelID, issue: .missing(reason: Self.reason(error)))
            throw error
        }
    }

    /// Makes sure a key is stored: used right after sign-in and before a sealed model's download.
    public func ensure(modelID: String) async throws {
        _ = try await key(modelID: modelID, refetch: false)
    }

    public func hasStoredKey(modelID: String) -> Bool {
        memory.withLock { $0[modelID] } != nil || ((try? store.key(for: modelID)) ?? nil)?.count == SealedFormat.keySize
    }

    public func forget(modelID: String) {
        memory.withLock { _ = $0.removeValue(forKey: modelID) }
        try? store.remove(modelID: modelID)
    }

    public func report(modelID: String, issue: ModelKeyIssue?) {
        let changed = issues.withLock { all -> Bool in
            let before = all[modelID]
            all[modelID] = issue
            return before != issue
        }
        if changed { onIssueChange?(modelID, issue) }
    }

    public func issue(for modelID: String) -> ModelKeyIssue? {
        issues.withLock { $0[modelID] }
    }

    private static func reason(_ error: Error) -> String {
        if let download = error as? AssetDownloadError {
            switch download {
            case .signInRequired: return "sign in to Hushy"
            case .accountUnavailable: return "the account service could not be reached"
            default: break
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? "unknown"
    }
}
