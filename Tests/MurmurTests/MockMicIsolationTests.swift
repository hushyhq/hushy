#if DEBUG
import Foundation
import MurmurCore
import Testing
@testable import Murmur

@Suite("Mock microphone: isolation from the real machine")
@MainActor
struct MockMicIsolationTests {
    private let home = URL(fileURLWithPath: "/private/tmp/hushy-home", isDirectory: true)

    /// Settings over a throwaway suite; `cleanup` removes its plist.
    private func freshSettings() throws -> (settings: AppSettings, cleanup: () -> Void) {
        let name = "app.hushy.test.isolation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return (AppSettings(defaults: defaults, calendarAuthorization: .notDetermined),
                { defaults.removePersistentDomain(forName: name) })
    }

    @Test("the app's own defaults would export every note into the real Documents folder")
    func defaultsAreNotIsolated() throws {
        let (settings, cleanup) = try freshSettings()
        defer { cleanup() }
        #expect(settings.exportNotesToMarkdown)
        #expect(!MockMicRig.violations(of: settings).isEmpty)
    }

    @Test("the rig turns the export and Apple Notes saving off and points the export folder into the temp home")
    func rigIsolatesSettings() throws {
        let (settings, cleanup) = try freshSettings()
        defer { cleanup() }
        MockMicRig.isolate(settings)
        #expect(!settings.exportNotesToMarkdown)
        #expect(!settings.saveNotesToAppleNotes)
        #expect(MockMicIsolation.isInside(settings.exportDirectory, AppPaths.supportDirectory))
        #expect(MockMicRig.violations(of: settings).isEmpty)
    }

    @Test("a run is refused while either export is on, or the export folder is outside the home")
    func eachViolationIsReported() {
        let inside = home.appendingPathComponent("export")
        #expect(MockMicIsolation.exportViolations(exportsMarkdown: false, savesToAppleNotes: false,
                                                  exportDirectory: inside, home: home).isEmpty)
        #expect(MockMicIsolation.exportViolations(exportsMarkdown: true, savesToAppleNotes: false,
                                                  exportDirectory: inside, home: home).count == 1)
        #expect(MockMicIsolation.exportViolations(exportsMarkdown: false, savesToAppleNotes: true,
                                                  exportDirectory: inside, home: home).count == 1)
        let documents = URL(fileURLWithPath: "/Users/someone/Documents/Hushy", isDirectory: true)
        #expect(MockMicIsolation.exportViolations(exportsMarkdown: false, savesToAppleNotes: false,
                                                  exportDirectory: documents, home: home).count == 1)
        #expect(MockMicIsolation.exportViolations(exportsMarkdown: true, savesToAppleNotes: true,
                                                  exportDirectory: documents, home: home).count == 3)
    }

    @Test("a sibling folder with the home's name as a prefix is not inside the home")
    func prefixSiblingIsOutside() {
        let sibling = URL(fileURLWithPath: "/private/tmp/hushy-home-other/export", isDirectory: true)
        #expect(!MockMicIsolation.isInside(sibling, home))
        #expect(MockMicIsolation.isInside(home, home))
    }

    @Test("the features the scenarios use are free, so no entitlement check can reach the Keychain")
    func requiredFeaturesAreFree() {
        #expect(MockMicIsolation.entitlementViolations().isEmpty)
        #expect(MockMicIsolation.entitlementViolations([.voiceSignatures, .voiceActions]).isEmpty, "voice actions are free too")
    }

    @Test("a suite belongs to the process whose id it carries; the older unnumbered name belongs to nobody")
    func suiteOwner() {
        #expect(MockMicSuites.ownerPID(of: MockMicSuites.name(pid: 4242)) == 4242)
        #expect(MockMicSuites.ownerPID(of: "app.hushy.mockmic.5E1D0C5A-0000-4000-8000-000000000000") == nil)
        #expect(MockMicSuites.ownerPID(of: "app.hushy.mockmic.test.5E1D0C5A-0000-4000-8000-000000000000") == nil)
        #expect(MockMicSuites.ownerPID(of: "app.hushy.other.1.x") == nil)
    }

    @Test("only suites of finished runs are swept, and unrelated preference files are left alone")
    func staleSuites() {
        let live = MockMicSuites.name(pid: 100)
        let dead = MockMicSuites.name(pid: 200)
        let legacy = "app.hushy.mockmic.5E1D0C5A-0000-4000-8000-000000000000"
        let files = ["\(live).plist", "\(dead).plist", "\(legacy).plist", "app.hushy.Hushy.plist",
                     "app.hushy.mockmic.300.x.lock", "com.apple.finder.plist"]
        let stale = MockMicSuites.stale(inFiles: files) { $0 == 100 }
        #expect(Set(stale) == [dead, legacy])
    }

    @Test("this process counts as alive and an unused id does not")
    func liveness() {
        #expect(MockMicSuites.isAlive(getpid()))
        #expect(!MockMicSuites.isAlive(Int32.max - 1))
    }

    @Test("removing a suite deletes its preferences file, not only its keys")
    func removeDeletesFile() async throws {
        let suite = "\(MockMicSuites.prefix)test-remove.\(UUID().uuidString)"
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suite).plist")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(1, forKey: "k")
        defaults.synchronize()
        for _ in 0..<40 where !FileManager.default.fileExists(atPath: file.path) { try await Task.sleep(for: .milliseconds(50)) }
        MockMicSuites.remove(suite)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("a name outside the prefix is never touched")
    func removeIgnoresOtherNames() {
        let other = "app.hushy.test.isolation.keep.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: other)!
        defaults.set(1, forKey: "k")
        MockMicSuites.remove(other)
        #expect(defaults.integer(forKey: "k") == 1)
        defaults.removePersistentDomain(forName: other)
        try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(other).plist"))
    }

    @Test("the run's suite is a file inside the temp home and removing it leaves nothing behind")
    func pathSuiteLivesInTheHome() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mockmic-suite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let suite = MockMicSuites.path(in: home)
        #expect(MockMicIsolation.isInside(URL(fileURLWithPath: suite), home))
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(7, forKey: "k")
        defaults.synchronize()
        MockMicSuites.removePath(suite)
        #expect(!FileManager.default.fileExists(atPath: suite + ".plist"))
        #expect(UserDefaults(suiteName: suite)?.object(forKey: "k") == nil)
        MockMicSuites.removePath(suite)
    }

    @Test("a path that is not the run's suite is never removed")
    func removePathGuard() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("keep-\(UUID().uuidString)")
        try Data("x".utf8).write(to: URL(fileURLWithPath: file.path + ".plist"))
        defer { try? FileManager.default.removeItem(atPath: file.path + ".plist") }
        MockMicSuites.removePath(file.path)
        #expect(FileManager.default.fileExists(atPath: file.path + ".plist"))
    }
}
#endif
