import Foundation
import Testing
@testable import Murmur

@Suite("Crash reports", .timeLimit(.minutes(1)))
@MainActor
struct CrashReporterTests {
    /// A stack tree in the layout Apple's forum samples show (`callStacks`, `threadAttributed`), with
    /// fields we never send: UUIDs, addresses, a full path as the binary name.
    private static let stackTree = Data(#"{"callStackPerThread":true,"callStacks":[{"threadAttributed":true,"callStackRootFrames":[{"binaryUUID":"private","address":4300,"binaryName":"/Applications/Hushy.app/Contents/MacOS/Hushy","offsetIntoBinaryTextSegment":42,"sampleCount":1,"subFrames":[{"binaryName":"libsystem_kernel.dylib","offsetIntoBinaryTextSegment":7,"binaryUUID":"private"}]}]}],"note":"/Users/person/secret.txt"}"#.utf8)
    private let payload = [CrashInput(exceptionType: "1", exceptionCode: "0", signal: "11",
                                      terminationReason: "Namespace DYLD, Library missing /Users/person/lib.dylib",
                                      stackTree: stackTree, build: "34", os: "macOS 15.4 (24E248)", arch: "arm64")]
    private func scrub(_ crashes: [CrashInput], chip: String = "Apple M4") -> Data? {
        CrashReportScrubber.report(from: crashes, appVersion: "1.2", fallbackBuild: "0", chip: chip)
    }

    private func fixture() throws -> (AppSettings, URL, () -> Void) {
        let name = "hushy-crash-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        let settings = AppSettings(defaults: defaults)
        return (settings, folder, {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: folder)
        })
    }

    private func files(_ folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    @Test("MetricKit payload is reduced to the Worker schema and hides extra data")
    func scrubber() throws {
        let data = try #require(scrub(payload))
        let report = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(report.keys) == Set(["v", "app", "os", "arch", "chip", "diagnostics"]))
        let app = try #require(report["app"] as? [String: String])
        #expect(app == ["version": "1.2", "build": "34"])
        #expect(report["os"] as? String == "macOS 15.4 (24E248)")
        #expect(report["arch"] as? String == "arm64")
        #expect(report["chip"] as? String == "Apple M4")
        let diagnostics = try #require(report["diagnostics"] as? [[String: Any]])
        let diagnostic = try #require(diagnostics.first)
        #expect(Set(diagnostic.keys) == Set(["exceptionType", "exceptionCode", "signal", "terminationReason", "callStackTree"]))
        #expect(diagnostic["signal"] as? String == "11")
        #expect(diagnostic["terminationReason"] as? String == "Namespace DYLD, Library missing [path]")
        let tree = try #require(diagnostic["callStackTree"] as? [String: Any])
        let threads = try #require(tree["callStackPerThread"] as? [[String: Any]])
        let frames = try #require(threads.first?["callStackRootFrames"] as? [[String: Any]])
        let frame = try #require(frames.first)
        #expect(Set(frame.keys) == Set(["binaryName", "offsetIntoBinaryTextSegment", "sampleCount", "subFrames"]))
        #expect(frame["binaryName"] as? String == "Hushy")
        let wire = String(decoding: data, as: UTF8.self)
        let child = try #require((frame["subFrames"] as? [[String: Any]])?.first)
        #expect(Set(child.keys) == Set(["binaryName", "offsetIntoBinaryTextSegment"]))
        for secret in ["private", "person", "/Users/", "/Applications/", "address", "threadAttributed", "note"] {
            #expect(!wire.contains(secret))
        }
    }

    @Test("The newer thread list name is read too; a tree with no known thread list sends nothing")
    func otherLayouts() throws {
        let newer = Data(#"{"callStackThreads":[{"callStackRootFrames":[{"binaryName":"Hushy","offsetIntoBinaryTextSegment":9}]}]}"#.utf8)
        var crash = payload[0]
        crash.stackTree = newer
        #expect(scrub([crash]) != nil)
        crash.stackTree = Data(#"{"somethingElse":[]}"#.utf8)
        #expect(scrub([crash]) == nil)
    }

    @Test("Off by default: neither a queue nor a request exists")
    func off() throws {
        let (settings, folder, cleanup) = try fixture()
        defer { cleanup() }
        let transport = ProbeTransport()
        let reporter = MetricKitCrashReporter(settings: settings, directory: folder, transport: transport)
        #expect(!settings.shareCrashReports)
        reporter.start()
        reporter.accept(payload)
        #expect(files(folder).isEmpty)
        #expect(transport.count == 0)
    }

    @Test("Turning sharing off clears queued reports")
    func turningOffClearsQueue() throws {
        let (settings, folder, cleanup) = try fixture()
        defer { cleanup() }
        settings.crashConsentVersion = AppSettings.currentCrashConsentVersion
        settings.shareCrashReports = true
        let reporter = MetricKitCrashReporter(settings: settings, directory: folder, transport: ProbeTransport())
        reporter.accept(payload)
        #expect(files(folder).count == 1)
        settings.shareCrashReports = false
        #expect(files(folder).isEmpty)
    }

    @Test("A retry sends the exact scrubbed request body and removes the queued file")
    func retryAndRequest() async throws {
        let (settings, folder, cleanup) = try fixture()
        defer { cleanup() }
        settings.crashConsentVersion = AppSettings.currentCrashConsentVersion
        settings.shareCrashReports = true
        let transport = ProbeTransport(statuses: [503, 204])
        let reporter = MetricKitCrashReporter(settings: settings, directory: folder, transport: transport,
                                               retryDelay: { _ in })
        reporter.accept(payload)
        #expect(files(folder).count == 1)
        await reporter.sendQueued()
        #expect(transport.count == 2)
        #expect(files(folder).isEmpty)
        let request = try #require(transport.requests.first)
        #expect(request.url == MetricKitCrashReporter.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(object.keys) == Set(["v", "app", "os", "arch", "chip", "diagnostics"]))
        #expect((object["app"] as? [String: String])?["build"] == "34")
        #expect(object["os"] as? String == "macOS 15.4 (24E248)")
        #expect(object["arch"] as? String == "arm64")
        #expect(object["chip"] as? String != nil)
        #expect((object["diagnostics"] as? [[String: Any]])?.count == 1)
        let info = Bundle.main.infoDictionary
        let expected = CrashReportScrubber.report(
            from: payload, appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            fallbackBuild: "unknown", chip: object["chip"] as? String ?? "unknown")
        #expect(body == expected)
    }

    @Test("Reports older than seven days are dropped before upload")
    func expiration() async throws {
        let (settings, folder, cleanup) = try fixture()
        defer { cleanup() }
        settings.crashConsentVersion = AppSettings.currentCrashConsentVersion
        settings.shareCrashReports = true
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stale = folder.appendingPathComponent("100-old.json")
        try Data("{}".utf8).write(to: stale)
        let transport = ProbeTransport()
        let reporter = MetricKitCrashReporter(settings: settings, directory: folder,
                                               now: { Date(timeIntervalSince1970: 100 + 8 * 86_400) }, transport: transport)
        await reporter.sendQueued()
        #expect(files(folder).isEmpty)
        #expect(transport.count == 0)
    }
}

private final class ProbeTransport: CrashReportTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []
    private var statuses: [Int]
    init(statuses: [Int] = [204]) { self.statuses = statuses }
    var requests: [URLRequest] { lock.withLock { storedRequests } }
    var count: Int { lock.withLock { storedRequests.count } }
    func send(_ request: URLRequest) async throws -> Int {
        lock.withLock {
            storedRequests.append(request)
            return statuses.isEmpty ? 204 : statuses.removeFirst()
        }
    }
}
