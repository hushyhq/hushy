import Foundation
import Testing
@testable import Murmur

/// Covers `ProjectVocabularyScanner`'s pure scanning behavior: which directories/files it skips,
/// which identifiers it extracts, and that it stays bounded. Uses a real temporary directory
/// (not the app's own Application Support folder) so this never touches user data.
@Suite("ProjectVocabularyScanner")
struct ProjectVocabularyScannerTests {
    private func makeTempProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-scan-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("extracts camelCase, PascalCase and snake_case identifiers")
    func extractsIdentifiers() throws {
        let root = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "function getUserById(user_id) {\n  const MAX_RETRIES = 5\n  class UserProfile {}\n}",
            to: root.appendingPathComponent("index.ts"))

        let result = ProjectVocabularyScanner.scan(root: root)
        #expect(result.vocabulary.identifiers.contains("getUserById"))
        #expect(result.vocabulary.identifiers.contains("user_id"))
        #expect(result.vocabulary.identifiers.contains("UserProfile"))
        #expect(result.vocabulary.identifiers.contains("MAX_RETRIES"))
    }

    @Test("excludes short plain-lowercase words and stop words")
    func excludesNoise() throws {
        let root = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("if (x) { return const let function }", to: root.appendingPathComponent("a.ts"))

        let result = ProjectVocabularyScanner.scan(root: root)
        #expect(!result.vocabulary.identifiers.contains("if"))
        #expect(!result.vocabulary.identifiers.contains("return"))
        #expect(!result.vocabulary.identifiers.contains("const"))
        #expect(!result.vocabulary.identifiers.contains("function"))
        #expect(!result.vocabulary.identifiers.contains("x"))
    }

    @Test("collects file names including non-source extensions")
    func collectsFileNames() throws {
        let root = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("export default function App() {}", to: root.appendingPathComponent("App.tsx"))
        try write("# Notes", to: root.appendingPathComponent("README.md"))

        let result = ProjectVocabularyScanner.scan(root: root)
        #expect(result.vocabulary.fileNames.contains("App.tsx"))
        #expect(result.vocabulary.fileNames.contains("README.md"))
    }

    @Test("skips node_modules, .git and build directories entirely")
    func skipsIgnoredDirectories() throws {
        let root = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("const shouldNeverAppear = 1", to: root.appendingPathComponent("node_modules/pkg/index.js"))
        try write("const alsoHidden = 1", to: root.appendingPathComponent(".git/hooks/pre-commit.js"))
        try write("const buildOnly = 1", to: root.appendingPathComponent("build/out.js"))
        try write("const realCode = 1", to: root.appendingPathComponent("src/main.js"))

        let result = ProjectVocabularyScanner.scan(root: root)
        #expect(!result.vocabulary.identifiers.contains("shouldNeverAppear"))
        #expect(!result.vocabulary.identifiers.contains("alsoHidden"))
        #expect(!result.vocabulary.identifiers.contains("buildOnly"))
        #expect(result.vocabulary.identifiers.contains("realCode"))
        #expect(!result.vocabulary.fileNames.contains("index.js"))
    }

    @Test("does not read binary file contents for identifiers")
    func skipsBinaryContents() throws {
        let root = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let imageURL = root.appendingPathComponent("logo.png")
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: imageURL)

        let result = ProjectVocabularyScanner.scan(root: root)
        #expect(result.vocabulary.fileNames.contains("logo.png"))
    }

    @Test("an empty directory scans cleanly with no identifiers or crash")
    func emptyDirectory() throws {
        let root = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = ProjectVocabularyScanner.scan(root: root)
        #expect(result.vocabulary.isEmpty)
        #expect(result.filesScanned == 0)
    }

    @Test("a nonexistent root scans to empty rather than crashing")
    func nonexistentRoot() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        let result = ProjectVocabularyScanner.scan(root: missing)
        #expect(result.vocabulary.isEmpty)
    }
}
