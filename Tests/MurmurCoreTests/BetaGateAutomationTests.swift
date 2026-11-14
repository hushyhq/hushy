import Foundation
import Testing
@testable import MurmurCore

/// The sign-in gate may be skipped only by a build made for automation. A downloaded app must
/// never open without sign-in because of an environment variable, a process name or a bundle name.
@Suite("Beta gate automation bypass", .serialized, .timeLimit(.minutes(1)))
struct BetaGateAutomationTests {
    private let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    private func bypasses(
        allowed: Bool, snapshot: Bool = false, bundle: String = "/Applications/Hushy.app",
        process: String = "Hushy", environment: [String: String] = [:]
    ) -> Bool {
        BetaGateAutomation.bypasses(
            buildAllowsBypass: allowed, snapshotRequested: snapshot, bundlePath: bundle,
            processName: process, environment: environment, temporaryDirectory: temp)
    }

    @Test("a shipped build never bypasses, whatever the environment says")
    func shippedBuildNeverBypasses() {
        let home = temp.appendingPathComponent("anything").path
        #expect(!bypasses(allowed: false, environment: ["HUSHY_HOME": home]))
        #expect(!bypasses(allowed: false, environment: ["MURMUR_HOME": home]))
        #expect(!bypasses(allowed: false, environment: ["HUSHY_HOME": "/private/tmp/x"]))
        #expect(!bypasses(allowed: false, bundle: "/x/Tests.xctest"))
        #expect(!bypasses(allowed: false, process: "murmur-eval"))
        #expect(!bypasses(allowed: false, snapshot: true))
    }

    @Test("an automation build bypasses for a disposable home, a test bundle, the eval tool or snapshots")
    func automationBuildBypasses() {
        #expect(bypasses(allowed: true, environment: ["HUSHY_HOME": temp.appendingPathComponent("run-1").path]))
        #expect(bypasses(allowed: true, environment: ["MURMUR_HOME": temp.appendingPathComponent("run-2").path]))
        #expect(bypasses(allowed: true, bundle: "/x/Tests.xctest"))
        #expect(bypasses(allowed: true, process: "murmur-eval"))
        #expect(bypasses(allowed: true, snapshot: true))
    }

    @Test("both spellings of /tmp count as disposable even after symlinks are resolved")
    func tmpSpellings() throws {
        for root in ["/tmp", "/private/tmp"] {
            let folder = URL(fileURLWithPath: root).appendingPathComponent("hushy-gate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            #expect(bypasses(allowed: true, environment: ["HUSHY_HOME": folder.path]), "\(root) existing folder")
            #expect(bypasses(allowed: true, environment: ["HUSHY_HOME": root + "/not-created-yet"]), "\(root) new folder")
        }
    }

    @Test("an ordinary home, an empty value or a lookalike path does not bypass")
    func ordinaryEnvironment() {
        let home = NSHomeDirectory() + "/Library/Application Support/Hushy"
        #expect(!bypasses(allowed: true, environment: ["HUSHY_HOME": home]))
        #expect(!bypasses(allowed: true, environment: ["HUSHY_HOME": ""]))
        #expect(!bypasses(allowed: true, environment: [:]))
        #expect(!bypasses(allowed: true, environment: ["HUSHY_HOME": "/tmpfoo/x"]))
        #expect(!bypasses(allowed: true, environment: ["HUSHY_HOME": "/Users/someone/tmp/x"]))
    }
}
