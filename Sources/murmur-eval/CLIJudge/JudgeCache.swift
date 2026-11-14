import CryptoKit
import Foundation

/// On-disk verdict cache keyed by (backend, model, prompt hash), so rerunning `murmur-eval
/// judge` against the same golden set and backend costs nothing after the first pass. Lives
/// under `.build/judge-cache/` by default — a build artifact directory already gitignored and
/// already scoped to "things this repo can regenerate", which a verdict cache is.
struct JudgeCache {
    let directory: URL

    init(directory: URL = JudgeCache.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/judge-cache", isDirectory: true)
    }

    /// Cache key: `backend/model/sha256(prompt)`. The hash covers the whole rendered prompt (not
    /// just the case ID) so a rubric or prompt-template change invalidates the cache
    /// automatically instead of silently serving a stale verdict for the same case ID.
    func key(backend: String, model: String, prompt: String) -> String {
        let digest = SHA256.hash(data: Data(prompt.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(backend)__\(model)__\(hex)"
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent("\(key).json", isDirectory: false)
    }

    func load(_ key: String) -> JudgeVerdict? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(JudgeVerdict.self, from: data)
    }

    func store(_ verdict: JudgeVerdict, for key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(verdict)
        try data.write(to: fileURL(for: key), options: .atomic)
    }
}
