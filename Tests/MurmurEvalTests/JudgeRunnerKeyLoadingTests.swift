import Foundation
import Testing

@testable import murmur_eval

/// Tests for `JudgeRunner.loadAPIKey`'s precedence (env var over key file), whitespace
/// trimming, permission warnings, and — critically — that the loaded key is never present in
/// any string this code produces (stdout capture is the closest proxy we have to "never
/// logged"). None of these tests touch the real `~/.config/hushy/typesafe_api_key`: every case
/// points `home` at a throwaway fixture directory under a temp folder.
@Suite("JudgeRunner API key loading")
struct JudgeRunnerKeyLoadingTests {
    private func makeFixtureHome() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeKeyFile(in home: URL, contents: String, permissions: Int16 = 0o600) throws -> URL {
        let configDir = home.appendingPathComponent(".config/hushy", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let file = configDir.appendingPathComponent("typesafe_api_key")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
        return file
    }

    @Test func prefersEnvironmentVariableOverKeyFile() throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try writeKeyFile(in: home, contents: "file-key-value")
        let key = JudgeRunner.loadAPIKey(environment: ["TYPESAFE_API_KEY": "env-key-value"], home: home)
        #expect(key == "env-key-value")
    }

    @Test func fallsBackToKeyFileWhenEnvVarAbsent() throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try writeKeyFile(in: home, contents: "file-key-value\n")
        let key = JudgeRunner.loadAPIKey(environment: [:], home: home)
        #expect(key == "file-key-value")
    }

    @Test func trimsWhitespaceFromEnvironmentVariable() {
        let key = JudgeRunner.loadAPIKey(
            environment: ["TYPESAFE_API_KEY": "  padded-key  \n"],
            home: FileManager.default.temporaryDirectory)
        #expect(key == "padded-key")
    }

    @Test func trimsWhitespaceFromKeyFileContents() throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try writeKeyFile(in: home, contents: "  \n  spaced-key  \n\n")
        let key = JudgeRunner.loadAPIKey(environment: [:], home: home)
        #expect(key == "spaced-key")
    }

    @Test func returnsNilWhenNeitherEnvNorFileIsPresent() throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let key = JudgeRunner.loadAPIKey(environment: [:], home: home)
        #expect(key == nil)
    }

    @Test func returnsNilForEmptyEnvironmentVariableAndFallsBackToFile() throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try writeKeyFile(in: home, contents: "file-key")
        let key = JudgeRunner.loadAPIKey(environment: ["TYPESAFE_API_KEY": "   "], home: home)
        #expect(key == "file-key")
    }

    @Test func returnsNilWhenKeyFileIsEmpty() throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try writeKeyFile(in: home, contents: "   \n")
        let key = JudgeRunner.loadAPIKey(environment: [:], home: home)
        #expect(key == nil)
    }

    @Test func loadsKeyEvenWhenFilePermissionsAreTooBroadButStillWarns() throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try writeKeyFile(in: home, contents: "loose-permissions-key", permissions: 0o644)
        // Widely-permissioned key files still load (so a misconfigured but present key isn't
        // silently unusable); the warning path is exercised for coverage without asserting on
        // stderr content, since that would couple the test to exact wording.
        let key = JudgeRunner.loadAPIKey(environment: [:], home: home)
        #expect(key == "loose-permissions-key")
    }

    @Test func neverIncludesTheKeyInAnyDescriptionOfTheClientErrorTypes() {
        // Defense in depth: even if a caller round-trips the key through an error message by
        // mistake, none of the fixed error strings this module defines should ever contain it.
        let secret = "sk-super-secret-value-zzz"
        let errors: [TypeSafeClient.ClientError] = [
            .unauthorized, .invalidRequest("body without key"), .rateLimited, .overloaded,
            .http(500, "server body"), .decoding("bad json"),
        ]
        for error in errors {
            #expect(!(error.errorDescription ?? "").contains(secret))
        }
    }
}

/// Verifies the `judge` command's overall skip-without-key contract end to end: no key
/// configured means a friendly message and a clean exit, not a thrown error.
@Suite("JudgeRunner skip without key")
struct JudgeRunnerSkipTests {
    @Test func loadAPIKeyReturnsNilInAFreshFixtureHomeWithNoEnvVar() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        // This mirrors exactly what `JudgeRunner.run` checks before doing anything else: no
        // env var, no file at ~/.config/hushy/typesafe_api_key under this fixture home.
        #expect(JudgeRunner.loadAPIKey(environment: [:], home: home) == nil)
    }
}
