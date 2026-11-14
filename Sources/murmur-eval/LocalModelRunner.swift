import Foundation
import MurmurCore

/// `murmur-eval local-model list|fetch|verify` — the `ModelRegistry` entries the app downloads,
/// fetched and checked with the app's own code (`ManagedAssetInstaller` over
/// `URLSessionDownloadTransport`: resumable, SHA-256 per file), so an eval run with
/// `--backend local` uses byte-identical files to what a user gets.
///
///   list                          entries, sizes, and this Mac's recommendation
///   fetch  [--local-model <id>] [--dir <dir>]   download (resumes a partial) into <HUSHY_HOME>/Models/<id>
///   verify [--local-model <id>] [--dir <dir>]   full SHA-256 check of every file
enum LocalModelRunner {
    static func run(_ args: Arguments) async throws {
        let action = args.positional.first ?? "list"
        switch action {
        case "list": list()
        case "fetch": try await fetch(args)
        case "verify": try verify(args)
        default:
            throw NSError(domain: "murmur-eval", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "usage: murmur-eval local-model list|fetch|verify [--local-model <id>] [--dir <dir>]",
            ])
        }
    }

    private static func list() {
        let machine = MachineProfile.current()
        let recommended = ModelTierPolicy.recommendedEntryID(for: machine)
        print("This Mac: \(machine.chipName.isEmpty ? "unknown chip" : machine.chipName), \(machine.physicalMemoryGB) GB → \(recommended)")
        for entry in ModelRegistry.entries {
            let mark = entry.id == recommended ? "*" : " "
            let installed = ManagedAssetInstaller.isInstalled(entry.files, in: ModelRegistry.directory(for: entry)) ? "installed" : "-"
            print("\(mark) \(entry.id)  \(ModelDownloadProgress.formatBytes(entry.downloadBytes))  \(entry.source.repo)@\(entry.source.revision.prefix(10))  \(entry.license.spdx)  \(installed)")
        }
    }

    private static func directory(_ args: Arguments, entry: LocalModelEntry) -> URL {
        args.string("dir").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? ModelRegistry.directory(for: entry)
    }

    private static func fetch(_ args: Arguments) async throws {
        let entry = try args.localModelEntry()
        let target = directory(args, entry: entry)
        print("Fetching \(entry.id) (\(ModelDownloadProgress.formatBytes(entry.downloadBytes))) from \(entry.source.repo)@\(entry.source.revision) into \(target.path)")
        let installer = ManagedAssetInstaller(downloader: AssetDownloader(transport: URLSessionDownloadTransport()))
        let start = Date()
        let lastPrinted = LockedValue<Int64>(0)
        try await installer.install(entry.files, into: target) { bytes in
            let step: Int64 = 100_000_000
            let shouldPrint = lastPrinted.update { value in
                guard bytes - value >= step || bytes == entry.downloadBytes else { return false }
                value = bytes
                return true
            }
            if shouldPrint { print("  \(ModelDownloadProgress.formatBytes(bytes)) of \(ModelDownloadProgress.formatBytes(entry.downloadBytes))") }
        }
        let seconds = Date().timeIntervalSince(start)
        print(String(format: "Done in %.0f s; every file matched its pinned SHA-256.", seconds))
    }

    private static func verify(_ args: Arguments) throws {
        let entry = try args.localModelEntry()
        let target = directory(args, entry: entry)
        let start = Date()
        let report = try ManagedAssetInstaller.verify(entry.files, in: target)
        let seconds = Date().timeIntervalSince(start)
        if report.isClean {
            print(String(format: "%@: %d files intact (%.1f s)", entry.id, report.verified, seconds))
        } else {
            for mismatch in report.mismatches { print("  \(mismatch.path): \(mismatch.reason)") }
            throw NSError(domain: "murmur-eval", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(entry.id): \(report.mismatches.count) file(s) damaged or missing"])
        }
    }
}

/// A tiny lock-protected value for progress callbacks.
final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func update<T>(_ body: (inout Value) -> T) -> T {
        lock.withLock { body(&value) }
    }
}
