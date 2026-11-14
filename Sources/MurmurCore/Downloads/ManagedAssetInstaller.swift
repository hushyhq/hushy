import Foundation
import Synchronization

/// Installs a `.files` asset (the MLX cleanup model) into its directory with `AssetDownloader`:
/// file by file, each resumable and SHA-256-verified before it is kept, with one cumulative byte
/// count for progress. Also answers "is it installed?" (cheap: every file present at its exact
/// size) and "is it intact?" (full SHA-256 of every file, for Settings → Verify).
public struct ManagedAssetInstaller: Sendable {
    public let downloader: AssetDownloader

    public init(downloader: AssetDownloader) {
        self.downloader = downloader
    }

    /// Fetches every file not yet in place. `onProgress` gets the bytes on disk across the whole
    /// asset (finished files + the current file's partial), so it never goes backwards on resume.
    public func install(
        _ files: [DownloadableAsset.File], into directory: URL,
        onProgress: @escaping @Sendable (Int64) -> Void = { _ in }
    ) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let done = Mutex<Int64>(0)
        for file in files {
            try Task.checkCancellation()
            let before = done.withLock { $0 }
            try await downloader.fetch(file, into: directory) { received in
                onProgress(before + min(received, file.bytes))
            }
            done.withLock { $0 += file.bytes }
            onProgress(done.withLock { $0 })
        }
    }

    /// Every file present at its exact size (no hashing: this runs at launch and on every
    /// Settings render). A tampered file of the right size is caught by `verify` and by the
    /// downloader, which hashes each file before moving it into place.
    public static func isInstalled(_ files: [DownloadableAsset.File], in directory: URL) -> Bool {
        !files.isEmpty && files.allSatisfy { file in
            let url = directory.appendingPathComponent(file.relativePath)
            return AssetDownloader.size(of: url) == file.bytes
                && !FileManager.default.fileExists(atPath: AssetDownloader.partialURL(for: url).path)
        }
    }

    /// Bytes already on disk for this asset (complete files + partials) — where a resumed
    /// download starts its progress from.
    public static func bytesOnDisk(_ files: [DownloadableAsset.File], in directory: URL) -> Int64 {
        files.reduce(0) { total, file in
            let url = directory.appendingPathComponent(file.relativePath)
            let complete = AssetDownloader.size(of: url)
            return total + (complete == file.bytes ? complete : min(file.bytes, AssetDownloader.size(of: AssetDownloader.partialURL(for: url))))
        }
    }

    /// Full integrity check: every file present, right size, right SHA-256.
    public static func verify(_ files: [DownloadableAsset.File], in directory: URL) throws -> ChecksumManifest.Report {
        let manifest = ChecksumManifest(entries: files.map {
            ChecksumManifest.Entry(path: $0.relativePath, size: $0.bytes, digest: .sha256($0.sha256))
        })
        let report = try manifest.verify(directory: directory)
        let missing = files.filter {
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.relativePath).path)
        }.map { ChecksumManifest.Mismatch(path: $0.relativePath, reason: "missing") }
        return ChecksumManifest.Report(verified: report.verified, mismatches: report.mismatches + missing)
    }

    /// Deletes the asset's directory (partials included).
    public static func remove(_ directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}
