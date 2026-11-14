import Foundation
import Testing
@testable import MurmurCore

/// The model Worker (`models-gate/src/allowlist.js`) serves only the files it lists, at the sizes it
/// lists. A registry model it does not know would download as 404 for everyone, so the two are checked
/// against each other here.
@Suite("Model host allowlist matches the registry")
struct ModelDownloadAllowlistTests {
    private static func allowlist() throws -> [String: [String: Int64]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("models-gate/src/allowlist.js")
        let text = try String(contentsOf: url, encoding: .utf8)
        var models: [String: [String: Int64]] = [:]
        var current: String?
        // Lines look like `  '<model>': Object.freeze({`, `    '<file>': <bytes>,` and `  }),`.
        for raw in text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let parts = raw.components(separatedBy: "'")
            if parts.count == 3, parts[0].isEmpty, parts[2] == ": Object.freeze({" {
                current = parts[1]
                models[parts[1]] = [:]
            } else if let current, parts.count == 3, parts[0].isEmpty, parts[2].hasPrefix(": "), parts[2].hasSuffix(","),
                      let size = Int64(parts[2].dropFirst(2).dropLast()) {
                models[current]?[parts[1]] = size
            } else if raw == "})," {
                current = nil
            }
        }
        return models
    }

    @Test("every file of every model on Hushy's host is allowlisted at its registered size", .enabled(if: PrivateFiles.present("models-gate/src/allowlist.js"), "needs a private file: models-gate/src/allowlist.js"))
    func registryIsAllowlisted() throws {
        let allowed = try Self.allowlist()
        let hosted = ModelRegistry.entries.filter { $0.files.contains { ModelDownloadHost.requiresAccount($0.remoteURL) } }
        #expect(hosted.count >= 3)
        for entry in hosted {
            let files = try #require(allowed[entry.id], "\(entry.id) is missing from models-gate/src/allowlist.js")
            for file in entry.files {
                #expect(files[file.relativePath] == file.bytes, "\(entry.id)/\(file.relativePath)")
                #expect(file.remoteURL.path == "/cleanup/\(entry.id)/\(file.relativePath)")
            }
        }
    }
}
