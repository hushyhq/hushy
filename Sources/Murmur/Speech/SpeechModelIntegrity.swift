import FluidAudio
import Foundation
import MurmurCore

/// Checksum verification for the Parakeet download. FluidAudio resumes (HTTP ranges), retries
/// and checks each file's *size* against Hugging Face's listing, but never a content hash; this
/// fetches the same listing (same host, same revision FluidAudio downloaded from) and compares
/// SHA-256 for LFS files and the git blob id for the small ones (`ChecksumManifest`).
///
/// "Pending" is remembered in UserDefaults from the moment a download starts until a clean
/// verification, so quitting between the download and the check still verifies on next launch.
struct SpeechModelIntegrity: Sendable {
    enum Outcome: Equatable, Sendable {
        case verified(Int)
        /// The listing couldn't be fetched (offline, rate-limited): not a failure.
        case unverified(String)
        /// Relative paths whose bytes don't match.
        case corrupted([String])
    }

    enum IntegrityError: LocalizedError {
        case corrupted

        var errorDescription: String? {
            "The downloaded speech model didn't match its published checksums, twice. Retry to download it again."
        }
    }

    let fetchManifest: @Sendable (AsrModelVersion) async throws -> ChecksumManifest
    let defaultsSuiteName: String?

    static let live = SpeechModelIntegrity(fetchManifest: { try await HuggingFaceChecksums.manifest(for: $0) }, defaultsSuiteName: nil)

    private var defaults: UserDefaults { defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }
    private func key(_ version: AsrModelVersion) -> String { "speechModelPendingVerification.\(String(describing: version))" }

    func isPending(_ version: AsrModelVersion) -> Bool { defaults.bool(forKey: key(version)) }
    func markPending(_ version: AsrModelVersion) { defaults.set(true, forKey: key(version)) }
    func clearPending(_ version: AsrModelVersion) { defaults.removeObject(forKey: key(version)) }

    func verify(version: AsrModelVersion, directory: URL) async -> Outcome {
        let manifest: ChecksumManifest
        do {
            manifest = try await fetchManifest(version)
        } catch {
            return .unverified(error.localizedDescription)
        }
        guard !manifest.entries.isEmpty else { return .unverified("empty checksum listing") }
        // ~600 MB of hashing: off the caller's executor, at utility priority.
        let task = Task.detached(priority: .utility) { try manifest.verify(directory: directory) }
        do {
            let report = try await task.value
            return report.isClean ? .verified(report.verified) : .corrupted(report.mismatches.map(\.path))
        } catch {
            return .unverified(error.localizedDescription)
        }
    }

    /// Deletes the whole compiled-model folder a bad file belongs to (`Encoder.mlmodelc/…` →
    /// `Encoder.mlmodelc`), so FluidAudio's own "all models present" check sees it missing and
    /// fetches it again; top-level files are deleted on their own.
    static func removeCorrupted(_ paths: [String], in directory: URL) {
        let targets = Set(paths.compactMap { $0.split(separator: "/").first.map(String.init) })
        for target in targets {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(target))
        }
    }
}

/// Fetches Hugging Face's recursive tree listing for a Parakeet repo — the one extra request
/// this adds, to the host the model already comes from. Follows `Link: rel="next"` paging.
enum HuggingFaceChecksums {
    static func repo(for version: AsrModelVersion) -> Repo? {
        switch version {
        case .ultra: .parakeetUltra
        case .v2: .parakeetV2
        case .v3: .parakeetV3
        default: nil
        }
    }

    struct UnsupportedVersion: Error {}

    static func manifest(for version: AsrModelVersion, session: URLSession = .shared) async throws -> ChecksumManifest {
        guard let repo = repo(for: version) else { throw UnsupportedVersion() }
        var next: URL? = try ModelRegistry.apiModels(repo.remotePath, "tree/\(repo.revision)?recursive=true")
        var entries: [ChecksumManifest.Entry] = []
        var pages = 0
        while let url = next, pages < 20 {
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            entries += try ChecksumManifest.parseHuggingFaceTree(data)
            next = nextPage(from: http.value(forHTTPHeaderField: "Link"))
            pages += 1
        }
        return ChecksumManifest(entries: entries)
    }

    /// `<https://…?cursor=…>; rel="next"` → the URL.
    static func nextPage(from link: String?) -> URL? {
        guard let link else { return nil }
        for part in link.split(separator: ",") where part.contains("rel=\"next\"") {
            guard let open = part.firstIndex(of: "<"), let close = part.firstIndex(of: ">") else { continue }
            return URL(string: String(part[part.index(after: open)..<close]))
        }
        return nil
    }
}

/// The real `SpeechModelDownloading`: the language setting picks the model, `SpeechEngine`
/// downloads (resuming), verifies and loads it.
@MainActor
final class SpeechEngineDownloads: SpeechModelDownloading {
    private let engine: SpeechEngine
    private let settings: AppSettings

    init(engine: SpeechEngine, settings: AppSettings) {
        self.engine = engine
        self.settings = settings
    }

    var isRequiredModelCached: Bool { SpeechEngine.isCached(settings.speechLanguageMode.modelVersion) }

    func prepareRequired() async throws {
        let mode = settings.speechLanguageMode
        try await engine.prepare(version: mode.modelVersion, driftGuard: mode.driftGuardEnabled)
    }

    func pauseRequired() async { await engine.pauseDownload() }

    var isVocabularyModelCached: Bool { SpeechEngine.isVocabularyModelCached }

    func prefetchVocabularyModel() async throws { try await engine.prefetchVocabularyModel() }
}
