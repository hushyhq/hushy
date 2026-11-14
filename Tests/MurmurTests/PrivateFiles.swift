import Foundation

/// Files the maintainers keep out of the public source: development, held-out and sealed eval sets, and the
/// code of the hosted services. A test that reads one is skipped when the file is absent, so `swift test`
/// passes on the public tree and still runs in full where the files exist.
enum PrivateFiles {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func present(_ paths: String...) -> Bool {
        paths.allSatisfy { FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent($0).path) }
    }
}
