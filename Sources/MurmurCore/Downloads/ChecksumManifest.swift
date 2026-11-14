import CryptoKit
import Foundation

/// Streaming file hashes (1 MB at a time, so a 600 MB model never sits in memory).
public enum FileDigest {
    private static let chunkSize = 1 << 20

    public static func sha256(of url: URL) throws -> String {
        var hasher = SHA256()
        try stream(url) { hasher.update(data: $0) }
        return hex(hasher.finalize())
    }

    /// Git's blob id: SHA-1 of `"blob <size>\0" + contents`. Hugging Face reports this as the
    /// `oid` of small (non-LFS) files, so it's the only checksum it publishes for them.
    public static func gitBlobSHA1(of url: URL) throws -> String {
        let size = ((try FileManager.default.attributesOfItem(atPath: url.path))[.size] as? NSNumber)?.int64Value ?? 0
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(size)\0".utf8))
        try stream(url) { hasher.update(data: $0) }
        return hex(hasher.finalize())
    }

    private static func stream(_ url: URL, _ body: (Data) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            body(chunk)
        }
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// The published checksums for a model repo, parsed from Hugging Face's tree listing
/// (`/api/models/<repo>/tree/<revision>?recursive=true`): each file's path and size, the SHA-256
/// of LFS files (`lfs.oid`) and the git blob id of the rest (`oid`).
///
/// This is how Hushy verifies the Parakeet download that FluidAudio performs: FluidAudio checks
/// sizes and resumes/retries, but publishes no content hash; the listing is fetched from the
/// same host the files came from, at the same revision.
public struct ChecksumManifest: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public enum Digest: Equatable, Sendable {
            case sha256(String)
            case gitBlobSHA1(String)
        }

        public let path: String
        public let size: Int64
        public let digest: Digest

        public init(path: String, size: Int64, digest: Digest) {
            self.path = path
            self.size = size
            self.digest = digest
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public enum ParseError: Error, Equatable {
        case notAListing
    }

    /// Parses one page of the tree listing. Directories are skipped (a recursive listing already
    /// includes their files); entries without a usable checksum are skipped too.
    public static func parseHuggingFaceTree(_ data: Data) throws -> [Entry] {
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ParseError.notAListing
        }
        return items.compactMap { item in
            guard item["type"] as? String == "file", let path = item["path"] as? String else { return nil }
            let size = (item["size"] as? NSNumber)?.int64Value ?? -1
            if let lfs = item["lfs"] as? [String: Any], let oid = lfs["oid"] as? String, !oid.isEmpty {
                let lfsSize = (lfs["size"] as? NSNumber)?.int64Value ?? size
                return Entry(path: path, size: lfsSize, digest: .sha256(oid.lowercased()))
            }
            guard let oid = item["oid"] as? String, !oid.isEmpty else { return nil }
            return Entry(path: path, size: size, digest: .gitBlobSHA1(oid.lowercased()))
        }
    }

    /// A file that is on disk but doesn't match the manifest.
    public struct Mismatch: Equatable, Sendable {
        public let path: String
        public let reason: String
    }

    public struct Report: Equatable, Sendable {
        /// Files present locally and checked.
        public let verified: Int
        public let mismatches: [Mismatch]
        public var isClean: Bool { mismatches.isEmpty }
    }

    /// Checks every manifest file that exists under `directory` (files the framework chose not
    /// to download are not required here — its own "all models present" check owns that).
    /// Size is compared first (cheap), then the hash.
    public func verify(directory: URL) throws -> Report {
        var verified = 0
        var mismatches: [Mismatch] = []
        for entry in entries {
            let url = directory.appendingPathComponent(entry.path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? -1
            if entry.size >= 0, size != entry.size {
                mismatches.append(Mismatch(path: entry.path, reason: "size \(size), expected \(entry.size)"))
                continue
            }
            let matches: Bool = switch entry.digest {
            case .sha256(let expected): try FileDigest.sha256(of: url) == expected
            case .gitBlobSHA1(let expected): try FileDigest.gitBlobSHA1(of: url) == expected
            }
            if matches {
                verified += 1
            } else {
                mismatches.append(Mismatch(path: entry.path, reason: "checksum mismatch"))
            }
        }
        return Report(verified: verified, mismatches: mismatches)
    }
}
