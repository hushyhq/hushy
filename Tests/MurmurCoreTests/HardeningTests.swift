import Foundation
import Testing

/// Sealed models only keep their promise if no other process can get into Hushy's memory. These checks read the
/// files that decide that (`scripts/check-hardening.sh` also checks a built bundle).
@Suite("Release hardening")
struct HardeningTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static let forbidden = [
        "com.apple.security.get-task-allow",
        "com.apple.security.cs.disable-library-validation",
        "com.apple.security.cs.allow-dyld-environment-variables",
    ]

    private static func entitlements(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test("the release entitlements grant no debugger, library or environment loophole")
    func entitlementsAreClosed() throws {
        let plist = try Self.entitlements(Self.root.appendingPathComponent("Resources/Murmur.entitlements"))
        for key in Self.forbidden {
            #expect(plist[key] as? Bool != true, "\(key) must not be set")
        }
    }

    @Test("release signing asks for the hardened runtime and never signs with --deep or get-task-allow")
    func signingFlags() throws {
        let script = try String(contentsOf: Self.root.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        #expect(script.contains("--options runtime"))
        // Every codesign call that signs the app itself uses the shared flags and the entitlements file.
        #expect(script.contains(#"codesign "${SIGN_FLAGS[@]}" --entitlements "$ROOT/Resources/Murmur.entitlements" "$APP""#))
        #expect(!script.contains("get-task-allow"))
        let signingLines = script.split(separator: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("codesign") }
        #expect(!signingLines.isEmpty)
        #expect(!signingLines.contains { $0.contains("--deep") })
    }

    private func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = Self.root.appendingPathComponent("scripts/check-hardening.sh")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test("scripts/check-hardening.sh passes on the repository and fails on each forbidden entitlement")
    func scriptCatchesEachKey() throws {
        let clean = try run([])
        #expect(clean.status == 0, "\(clean.output)")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hardening-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for key in Self.forbidden {
            let file = directory.appendingPathComponent("\(key).plist")
            try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>\(key)</key><true/></dict></plist>
            """.utf8).write(to: file)
            let result = try run(["--entitlements", file.path])
            #expect(result.status == 1, "\(key): \(result.output)")
            #expect(result.output.contains("FAIL"), "\(key)")
        }
        // The same keys set to false are fine.
        let off = directory.appendingPathComponent("off.plist")
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><false/></dict></plist>
        """.utf8).write(to: off)
        #expect(try run(["--entitlements", off.path]).status == 0)
    }
}
