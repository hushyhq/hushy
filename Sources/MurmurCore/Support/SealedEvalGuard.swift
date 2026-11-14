import CryptoKit
import Foundation

/// Keeps sealed held-out eval sets away from anything that tunes: prompt/threshold tuning runs,
/// dev-set evals, judge calibration, and every synthetic-data generator
/// (`docs/product/LOCAL-MODEL-RESEARCH.md` §4.2: seal the actions held-out set before any
/// synthetic data exists; builders never read it).
///
/// A path is refused when its file name (as given or after resolving symlinks) starts with a
/// sealed prefix, **or** when the file's SHA-256 equals a sealed set's pinned hash — so a renamed copy
/// is refused too. Only the orchestrator's `murmur-eval tools --heldout <path>` opens the actions
/// held-out set, and it must match the pinned hash exactly (tampering is detected).
///
/// The sealed data itself lives only on a private branch; main-bound branches carry nothing but the
/// hash below and `Evals/sealed-sets.json`.
public enum SealedEvalGuard {
    public struct SealedSet: Sendable, Equatable {
        public let fileName: String
        public let sha256: String
        public let caseCount: Int
    }

    /// The actions held-out set (tools-v1 cases). Pinned when it was sealed; see
    /// `Evals/sealed-sets.json` (kept equal by `SealedEvalGuardTests`).
    public static let actionsHeldout = SealedSet(
        fileName: "actions-heldout.json",
        sha256: "4ab6d22af5c794fd8fcf7b9bc35e1816f515c90afd1e809904233e4d067c3040",
        caseCount: 303)

    /// The meeting-digest held-out set: 6 meetings written by an independent author who never saw
    /// the dev meetings (`Evals/meeting-eval`) or the digest prompts. Pinned when it was sealed.
    public static let meetingHeldout = SealedSet(
        fileName: "meeting-heldout.json",
        sha256: "edea8757abb16279b97460e9dc5fa191c0c571a0af6312746396e678b28fd251",
        caseCount: 6)

    /// Name prefixes no tuning path may touch: the actions held-out set (and its README), the
    /// cleanup held-out sets (`heldout-v2*`) and the meeting held-out set (and its plans), each on
    /// its own branch.
    /// `voicelab-` is intentionally absent: `Evals/voicelab-prompts.json` is on this branch.
    /// Training and the judges refuse it by substring. `ab-`, `eval-long64-b` and `longb` match
    /// no checked-in file here.
    public static let sealedPrefixes = [
        "actions-heldout", "heldout-v2", "meeting-heldout", "ab-", "eval-long64-b", "longb",
    ]

    public static let sealedHashes: Set<String> = [actionsHeldout.sha256, meetingHeldout.sha256]

    public enum Refusal: Error, Equatable, LocalizedError, Sendable {
        case sealedPath(path: String, purpose: String)
        case sealedContent(path: String, purpose: String)
        case notTheSealedSet(path: String, expected: String, actual: String)

        public var errorDescription: String? {
            switch self {
            case .sealedPath(let path, let purpose):
                "refused: \(path) is a sealed held-out set and \(purpose) may never read it (see .claude/AGENTS.md, sealed eval sets)"
            case .sealedContent(let path, let purpose):
                "refused: \(path) has the same contents as a sealed held-out set; \(purpose) may never read it"
            case .notTheSealedSet(let path, let expected, let actual):
                "refused: \(path) is not the sealed held-out set (SHA-256 \(actual), pinned \(expected)); it was edited or is the wrong file"
            }
        }
    }

    /// Whether the file name is a sealed set's, as given or after resolving symlinks. Only the
    /// last component counts for prefixes: directories can be named after branches. The
    /// `runs/sealed` subtree is always refused, including through a symlink.
    public static func isSealedPath(_ url: URL) -> Bool {
        [url.standardizedFileURL, url.resolvingSymlinksInPath()].contains { candidate in
            let name = candidate.lastPathComponent.lowercased()
            let components = candidate.pathComponents.map { $0.lowercased() }
            let inSealedRuns = zip(components, components.dropFirst()).contains { $0.0 == "runs" && $0.1 == "sealed" }
            return inSealedRuns || sealedPrefixes.contains { name.hasPrefix($0) }
        }
    }

    /// Whether the file's bytes hash to a pinned sealed set (catches renamed copies).
    public static func isSealedContent(_ url: URL) -> Bool {
        guard let hash = sha256(of: url) else { return false }
        return sealedHashes.contains(hash)
    }

    /// Throws unless `url` is safe for tuning, dev evals or data generation. `purpose` names the
    /// caller in the refusal ("murmur-eval tools (dev)", "synthetic-data generator").
    public static func assertTuningSafe(_ url: URL, purpose: String) throws {
        if isSealedPath(url) { throw Refusal.sealedPath(path: url.path, purpose: purpose) }
        if isSealedContent(url) { throw Refusal.sealedContent(path: url.path, purpose: purpose) }
    }

    /// The orchestrator path: `url` must be byte-identical to the sealed actions held-out set.
    public static func assertIsSealedActionsHeldout(_ url: URL) throws {
        try assertIsSealed(actionsHeldout, url)
    }

    /// The orchestrator path for `murmur-eval meeting --heldout`: the pinned meeting held-out set.
    public static func assertIsSealedMeetingHeldout(_ url: URL) throws {
        try assertIsSealed(meetingHeldout, url)
    }

    static func assertIsSealed(_ set: SealedSet, _ url: URL) throws {
        let actual = sha256(of: url) ?? "unreadable"
        guard actual == set.sha256 else {
            throw Refusal.notTheSealedSet(path: url.path, expected: set.sha256, actual: actual)
        }
    }

    /// Hex SHA-256 of a regular file; nil for directories, missing or oversized files.
    public static func sha256(of url: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              size.intValue <= maxHashedBytes,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return sha256(of: data)
    }

    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Eval sets are small; anything bigger (audio, model weights) is not hashed.
    static let maxHashedBytes = 50 * 1024 * 1024
}
