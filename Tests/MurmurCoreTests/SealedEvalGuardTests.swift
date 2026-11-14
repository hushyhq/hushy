import Foundation
import Testing
@testable import MurmurCore

/// The sealed-held-out guard: tuning paths refuse sealed sets by name and by content, the
/// orchestrator path accepts only the pinned file, and the sealed data never lands on this branch.
@Suite("Sealed eval guard")
struct SealedEvalGuardTests {
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sealed-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("sealed prefixes and the runs/sealed subtree are refused")
    func sealedNames() {
        for path in ["Evals/actions-heldout.json", "/tmp/x/Actions-Heldout-v2.json", "actions-heldout.README.md", "Evals/heldout-v2-clean.json",
                     "Evals/meeting-heldout.json", "/tmp/Meeting-Heldout.json",
                     "Evals/ab-session.jsonl", "Evals/eval-long64-b1.jsonl", "/tmp/longb-notes.jsonl", "Evals/runs/sealed/private.jsonl",
                     "/tmp/Runs/Sealed/nested/dev.json"] {
            #expect(SealedEvalGuard.isSealedPath(URL(fileURLWithPath: path)), "\(path)")
            #expect(throws: SealedEvalGuard.Refusal.self) { try SealedEvalGuard.assertTuningSafe(URL(fileURLWithPath: path), purpose: "test") }
        }
        // This very worktree is `.claude/worktrees/actions-heldout`: directories must not count.
        for path in ["/w/.claude/worktrees/actions-heldout/Evals/actions-tools-dev.json", "Evals/actions-golden.json", "Evals/sealed-sets.json", "Evals/runs/sealed-copy/dev.json"] {
            #expect(!SealedEvalGuard.isSealedPath(URL(fileURLWithPath: path)), "\(path)")
        }
    }

    @Test("a symlink to a sealed name is refused")
    func symlink() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("actions-heldout.json")
        try Data("{}".utf8).write(to: target)
        let link = directory.appendingPathComponent("dev.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(SealedEvalGuard.isSealedPath(link))
    }

    @Test("a renamed copy is caught by its SHA-256, which must be the pinned hash")
    func contentHash() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let innocent = directory.appendingPathComponent("innocent.json")
        try Data("not sealed".utf8).write(to: innocent)
        #expect(!SealedEvalGuard.isSealedContent(innocent))
        #expect(throws: Never.self) { try SealedEvalGuard.assertTuningSafe(innocent, purpose: "test") }
        #expect(throws: SealedEvalGuard.Refusal.self) { try SealedEvalGuard.assertIsSealedActionsHeldout(innocent) }
        #expect(SealedEvalGuard.sha256(of: Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(SealedEvalGuard.sha256(of: directory) == nil)
    }

    @Test("the pinned hash is a real SHA-256 and matches Evals/sealed-sets.json", .enabled(if: PrivateFiles.present("Evals/sealed-sets.json"), "needs a private file: Evals/sealed-sets.json"))
    func manifest() throws {
        let pinned = SealedEvalGuard.actionsHeldout
        #expect(pinned.sha256.count == 64 && pinned.sha256.allSatisfy(\.isHexDigit))
        #expect(pinned.caseCount >= 300)
        let url = Self.packageRoot.appendingPathComponent("Evals/sealed-sets.json")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let sets = try #require(object["sets"] as? [[String: Any]])
        let entry = try #require(sets.first { $0["file"] as? String == pinned.fileName })
        #expect(entry["sha256"] as? String == pinned.sha256)
        #expect(entry["cases"] as? Int == pinned.caseCount)
    }

    @Test("the meeting held-out set is pinned in the manifest, and only the pinned file passes", .enabled(if: PrivateFiles.present("Evals/sealed-sets.json"), "needs a private file: Evals/sealed-sets.json"))
    func meetingManifest() throws {
        let pinned = SealedEvalGuard.meetingHeldout
        #expect(pinned.sha256.count == 64 && pinned.sha256.allSatisfy(\.isHexDigit))
        #expect(SealedEvalGuard.sealedHashes.contains(pinned.sha256))
        let url = Self.packageRoot.appendingPathComponent("Evals/sealed-sets.json")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let sets = try #require(object["sets"] as? [[String: Any]])
        let entry = try #require(sets.first { $0["file"] as? String == pinned.fileName })
        #expect(entry["sha256"] as? String == pinned.sha256)
        #expect(entry["cases"] as? Int == pinned.caseCount)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = directory.appendingPathComponent("other.json")
        try Data("{}".utf8).write(to: other)
        #expect(throws: SealedEvalGuard.Refusal.self) { try SealedEvalGuard.assertIsSealedMeetingHeldout(other) }
    }

    @Test("no sealed set is checked in on this branch")
    func sealedDataIsAbsent() throws {
        let evals = Self.packageRoot.appendingPathComponent("Evals", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: evals.path)
        let sealed = names.filter { SealedEvalGuard.isSealedPath(evals.appendingPathComponent($0)) }
        #expect(sealed.isEmpty, "sealed files on a main-bound branch: \(sealed)")
        for name in names where name.hasSuffix(".json") && !name.lowercased().hasPrefix("voicelab-") {
            let url = evals.appendingPathComponent(name)
            guard !SealedEvalGuard.isSealedPath(url) else { continue }
            #expect(!SealedEvalGuard.isSealedContent(url), "\(name) has sealed contents")
        }
    }
}
