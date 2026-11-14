import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The app's side of usage numbers: the switch, what it gates, ordering around switch-off, the
/// held-dictation edit verdict, the one-time notice, and that a failure never escapes. Every test
/// uses a throwaway defaults suite and a temp folder; none touches the network.
@Suite("Usage numbers: recorder and settings", .timeLimit(.minutes(1)))
@MainActor
struct UsageMetricsRecorderTests {
    /// `on: nil` leaves the switch as a fresh install has it: no stored choice.
    private func makeSettings(seen: Bool = true, on: Bool? = true, name: String = "hushy-test-usage-\(UUID().uuidString)") -> (AppSettings, () -> Void) {
        let defaults = UserDefaults(suiteName: name)!
        let settings = AppSettings(defaults: defaults)
        settings.usageNumbersNoticeSeen = seen
        if let on { settings.shareUsageNumbers = on }
        return (settings, { defaults.removePersistentDomain(forName: name) })
    }

    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-usage-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0 != ".lock" }.sorted()
    }

    /// Tests often make a second recorder over the same folder (a relaunch) while the first is still alive.
    private func recorder(
        _ settings: AppSettings, _ folder: URL?, endpoint: URL? = nil, transport: MetricsTransport? = nil, lock: Bool = false
    ) -> UsageMetricsRecorder {
        UsageMetricsRecorder(settings: settings, directory: folder, endpoint: endpoint, transport: transport, takesStoreLock: lock)
    }

    /// Defaults that report, for every write, whether the gate was still on at that moment.
    final class ObservedDefaults: UserDefaults, @unchecked Sendable {
        var onWrite: ((String) -> Void)?
        override func set(_ value: Any?, forKey defaultName: String) { onWrite?(defaultName); super.set(value, forKey: defaultName) }
        override func set(_ value: Int, forKey defaultName: String) { onWrite?(defaultName); super.set(value, forKey: defaultName) }
        override func set(_ value: Bool, forKey defaultName: String) { onWrite?(defaultName); super.set(value, forKey: defaultName) }
    }

    private let pasted = DictationMetricInput(
        result: .pasted, modelOutcome: .used, backend: .apple, cleanupLevel: .clean, mode: nil, wordCount: 20,
        audioSeconds: 5, speechMilliseconds: 300, cleanupMilliseconds: 600, releaseToDeliveryMilliseconds: 900)

    // MARK: switch and gate

    @Test("it is off by default, and the notice is unseen on a fresh install")
    func defaults() {
        let name = "hushy-test-usage-defaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.shareUsageNumbers)
        #expect(!settings.usageNumbersNoticeSeen)
        #expect(!settings.usageGate.isOn)
        #expect(defaults.object(forKey: "shareUsageNumbers") == nil)       // reading the default stores no choice
    }

    @Test("a stored choice is kept across a relaunch, on or off")
    func storedChoiceIsKept() {
        for choice in [true, false] {
            let name = "hushy-test-usage-stored-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(choice, forKey: "shareUsageNumbers")
            defaults.set(true, forKey: "usageNumbersNoticeSeen")
            let settings = AppSettings(defaults: defaults)
            #expect(settings.shareUsageNumbers == choice)
            #expect(settings.usageGate.isOn == choice)
            settings.shareUsageNumbers = !choice                              // and a change is stored at once
            #expect(AppSettings(defaults: defaults).shareUsageNumbers == !choice)
        }
    }

    @Test("no stored choice means off: nothing is recorded, kept or sent, even after the notice was answered")
    func noStoredChoiceIsOffAndInert() async throws {
        let name = "hushy-test-usage-unset-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.usageNumbersNoticeSeen = true                                // "Get started", OK, or closing the sheet
        #expect(!settings.shareUsageNumbers && !settings.isSharingUsageNumbers && !settings.usageGate.isOn)
        let folder = try tempFolder()
        let transport = CountingTransport()
        let recorder = recorder(settings, folder, endpoint: URL(string: "https://metrics.example.com/b"), transport: transport)
        recorder.start()
        #expect(!recorder.isCollecting)
        recorder.recordDictation(pasted)
        #expect(recorder.holdDictation(pasted) == nil)
        recorder.record(.funnel(.firstDictation))
        recorder.record(.meeting(MeetingMetricEvent(outcome: .started, minutesRecorded: nil)))
        await recorder.flush()
        #expect(names(in: folder).isEmpty)
        #expect(await recorder.todaysLines().isEmpty)
        _ = await recorder.runDailyJobs(now: Date().addingTimeInterval(2 * 86_400))
        #expect(transport.count == 0)
        #expect(names(in: folder).isEmpty)
        #expect(defaults.object(forKey: "shareUsageNumbers") == nil)         // answering the notice is not a choice to share
    }

    @Test("an install that was sharing without a stored choice is off after the update, and what it had recorded is deleted")
    func unstoredSharingEndsOnUpdate() async throws {
        let name = "hushy-test-usage-update-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "usageNumbersNoticeSeen")                  // pressed OK with the old default left on
        defaults.set(3, forKey: "usageDataEpoch")
        let folder = try tempFolder()
        let old = folder.appendingPathComponent("e3", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old numbers".utf8).write(to: old.appendingPathComponent("journal.jsonl"))
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.shareUsageNumbers && !settings.usageGate.isOn)
        #expect(settings.usageGate.epoch == 4)                                // the old folder can no longer be read
        let recorder = recorder(settings, folder)
        recorder.start()
        recorder.recordDictation(pasted)
        await recorder.flush()
        #expect(!recorder.isCollecting && !recorder.needsNotice)
        #expect(names(in: folder).isEmpty)
    }

    @Test("the gate follows the setting in the same call, not a moment later")
    func gateIsSynchronous() {
        let (settings, cleanup) = makeSettings()
        defer { cleanup() }
        #expect(settings.usageGate.isOn)
        settings.shareUsageNumbers = false
        #expect(!settings.usageGate.isOn)
        settings.shareUsageNumbers = true
        #expect(settings.usageGate.isOn)
        settings.usageNumbersNoticeSeen = false
        #expect(!settings.usageGate.isOn)
    }

    @Test("nothing is recorded before the person has been shown the switch")
    func nothingBeforeNoticeSeen() async throws {
        let (settings, cleanup) = makeSettings(seen: false)
        defer { cleanup() }
        let folder = try tempFolder()
        let recorder = recorder(settings, folder)
        recorder.start()
        recorder.recordDictation(pasted)
        recorder.record(.funnel(.firstDictation))
        await recorder.flush()
        #expect(names(in: folder).isEmpty)
        #expect(await recorder.todaysLines().isEmpty)
    }

    @Test("nothing is recorded while the switch is off, even after the notice was seen")
    func nothingWhileOff() async throws {
        let (settings, cleanup) = makeSettings(seen: true, on: false)
        defer { cleanup() }
        let folder = try tempFolder()
        let recorder = recorder(settings, folder)
        recorder.start()
        recorder.recordDictation(pasted)
        await recorder.flush()
        #expect(names(in: folder).isEmpty)
    }

    @Test("with the switch on, a dictation is recorded and shows in today's numbers without any text")
    func recordsWhileOn() async throws {
        let (settings, cleanup) = makeSettings()
        defer { cleanup() }
        let folder = try tempFolder()
        let recorder = recorder(settings, folder)
        recorder.start()
        recorder.recordDictation(pasted)
        let lines = await recorder.todaysLines()
        #expect(lines.contains("Dictations: 1 in all"))
        #expect(lines.last == MetricsDisclosure.neverSent)
    }

    @Test("stopped for an uninstall, what was queued is written and nothing after it is; no later call waits for ever")
    func stopForUninstallTakesNothingMore() async throws {
        let (settings, cleanup) = makeSettings()
        defer { cleanup() }
        let folder = try tempFolder()
        let recorder = recorder(settings, folder)
        recorder.start()
        recorder.recordDictation(pasted)

        await recorder.stopForUninstall()
        #expect(await recorder.todaysLines().contains("Dictations: 1 in all"))
        let written = try FileManager.default.subpathsOfDirectory(atPath: folder.path).sorted()
        #expect(!written.isEmpty)

        recorder.recordDictation(pasted)
        recorder.record(.funnel(.firstDictation))
        #expect(recorder.holdDictation(pasted) == nil)
        await recorder.flush()
        recorder.flushForQuit()
        #expect(await recorder.runDailyJobs() == nil)
        await recorder.stopForUninstall()

        #expect(await recorder.todaysLines().contains("Dictations: 1 in all"))
        #expect(try FileManager.default.subpathsOfDirectory(atPath: folder.path).sorted() == written)
    }

    @Test("a stop that is no longer wanted when it gets there leaves the queue open, and a later one still closes it")
    func abandonedUninstallStopKeepsRecording() async throws {
        let (settings, cleanup) = makeSettings()
        defer { cleanup() }
        let folder = try tempFolder()
        let recorder = recorder(settings, folder)
        recorder.start()
        recorder.recordDictation(pasted)

        // The uninstall gave up waiting and the app went back to work before this finished.
        await recorder.stopForUninstall(isStillWanted: { false })

        recorder.recordDictation(pasted)
        await recorder.flush()
        #expect(await recorder.todaysLines().contains("Dictations: 2 in all"))

        await recorder.stopForUninstall()
        recorder.recordDictation(pasted)
        await recorder.flush()
        #expect(await recorder.todaysLines().contains("Dictations: 2 in all"))
    }

    @Test("turning it off empties the folder and drops what arrives after; turning it on starts fresh")
    func offWipes() async throws {
        let (settings, cleanup) = makeSettings()
        defer { cleanup() }
        let folder = try tempFolder()
        let recorder = recorder(settings, folder)
        recorder.start()
        recorder.recordDictation(pasted)
        _ = await recorder.todaysLines()
        settings.shareUsageNumbers = false
        recorder.recordDictation(pasted)                      // after the switch flipped: dropped
        await recorder.flush()
        #expect(names(in: folder).isEmpty)
        #expect(await recorder.todaysLines().isEmpty)
        settings.shareUsageNumbers = true
        #expect(await recorder.todaysLines().isEmpty)          // fresh
    }

    @Test("off then on starts a new data epoch: earlier numbers are unreachable at once, before any tidying, and the old folder is tidied")
    func offStartsNewEpoch() async throws {
        let (settings, cleanup) = makeSettings()
        defer { cleanup() }
        let folder = try tempFolder()
        let recorder = recorder(settings, folder)
        recorder.start()
        recorder.recordDictation(pasted)
        await recorder.flush()
        let epoch = settings.usageGate.epoch
        #expect(names(in: folder) == ["e\(epoch)"])
        settings.shareUsageNumbers = false
        settings.shareUsageNumbers = true
        #expect(settings.usageGate.epoch == epoch + 1)
        #expect(await recorder.todaysLines().isEmpty)                        // already unreachable (this flushes the queue too)
        #expect(names(in: folder).isEmpty)                                   // and the old folder has been tidied away
    }

    @Test("the epoch is saved with the switch, and a relaunch with the switch off starts a new one")
    func epochIsPersisted() {
        let name = "hushy-test-usage-epoch-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = AppSettings(defaults: defaults)
        first.usageNumbersNoticeSeen = true
        first.shareUsageNumbers = true
        let before = first.usageGate.epoch
        first.shareUsageNumbers = false
        #expect(defaults.integer(forKey: "usageDataEpoch") == before + 1)    // written in the same call as the switch
        first.shareUsageNumbers = true
        #expect(defaults.integer(forKey: "usageDataEpoch") == before + 1)
        // A crash with the switch on keeps the epoch; a relaunch after an off starts a newer one.
        #expect(AppSettings(defaults: defaults).usageGate.epoch == before + 1)
        first.shareUsageNumbers = false
        let relaunched = AppSettings(defaults: defaults)
        #expect(relaunched.usageGate.epoch == before + 3)                    // one for the off, one for the relaunch
        #expect(!relaunched.usageGate.isOn)
        #expect(defaults.integer(forKey: "usageDataEpoch") == relaunched.usageGate.epoch)
    }

    @Test("if the epoch cannot be saved and read back, the switch stays off, one plain status shows, and the next change retries")
    func storageFaultFailsClosed() {
        final class ForgetfulDefaults: UserDefaults, @unchecked Sendable {
            var forgets = false
            override func integer(forKey defaultName: String) -> Int {
                forgets && defaultName == "usageDataEpoch" ? -1 : super.integer(forKey: defaultName)
            }
        }
        let name = "hushy-test-usage-fault-\(UUID().uuidString)"
        guard let defaults = ForgetfulDefaults(suiteName: name) else { Issue.record("no defaults"); return }
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.usageNumbersNoticeSeen = true
        settings.shareUsageNumbers = true
        #expect(settings.usageGate.isOn && !settings.usageStorageFault)
        defaults.forgets = true
        settings.shareUsageNumbers = false
        #expect(settings.usageStorageFault)                                  // could not be confirmed
        settings.shareUsageNumbers = true
        #expect(settings.usageStorageFault && !settings.usageGate.isOn)      // still off: fail closed
        defaults.forgets = false
        settings.shareUsageNumbers = false
        settings.shareUsageNumbers = true
        #expect(!settings.usageStorageFault && settings.usageGate.isOn)      // saved now: sharing resumes
    }

    @Test("off closes the gate and advances the epoch in memory before anything is saved; on opens it only after both are saved")
    func gateClosesBeforeSavingAndOpensAfter() throws {
        let name = "hushy-test-usage-order-\(UUID().uuidString)"
        let defaults = try #require(ObservedDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.usageNumbersNoticeSeen = true
        settings.shareUsageNumbers = true
        #expect(settings.usageGate.isOn)
        let epoch = settings.usageGate.epoch
        var seen: [(key: String, gateOn: Bool, epoch: Int)] = []
        defaults.onWrite = { key in
            if key == "shareUsageNumbers" || key == "usageDataEpoch" { seen.append((key, settings.usageGate.isOn, settings.usageGate.epoch)) }
        }
        settings.shareUsageNumbers = false
        #expect(!seen.isEmpty && seen.allSatisfy { !$0.gateOn && $0.epoch == epoch + 1 })   // already off, epoch already up
        seen = []
        settings.shareUsageNumbers = true
        #expect(seen.map(\.key).contains("usageDataEpoch") && seen.allSatisfy { !$0.gateOn })   // still closed while saving
        #expect(settings.usageGate.isOn)                                                     // and open afterwards
    }

    @Test("with no saved epoch, or one lower than a folder on disk, the epoch starts above every folder and they are deleted before recording")
    func epochProvenanceLost() throws {
        for storedEpoch in [nil, 1] as [Int?] {
            let name = "hushy-test-usage-prov-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            if let storedEpoch { defaults.set(storedEpoch, forKey: "usageDataEpoch") }
            let settings = AppSettings(defaults: defaults)
            settings.usageNumbersNoticeSeen = true
            settings.shareUsageNumbers = true
            let folder = try tempFolder()
            for number in [0, 1, 7] {
                let old = folder.appendingPathComponent("e\(number)", isDirectory: true)
                try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
                try Data("old numbers".utf8).write(to: old.appendingPathComponent("journal.jsonl"))
            }
            let recorder = recorder(settings, folder)               // reconciles and tidies in its init
            #expect(settings.usageGate.epoch == 8)
            #expect(names(in: folder).isEmpty)                      // every old folder is gone before anything can record
            #expect(defaults.integer(forKey: "usageDataEpoch") == 8)
            recorder.recordDictation(pasted)
            #expect(settings.usageGate.isOn)
        }
    }

    @Test("a folder that belongs to this install (a saved epoch, equal to the folder) is kept across a relaunch")
    func epochMatchingFolderIsKept() throws {
        let name = "hushy-test-usage-keep-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = AppSettings(defaults: defaults)                    // saves the epoch
        first.usageNumbersNoticeSeen = true
        first.shareUsageNumbers = true                                 // a stored "on": the relaunch keeps the epoch
        let folder = try tempFolder()
        let current = folder.appendingPathComponent("e\(first.usageGate.epoch)", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        let relaunched = AppSettings(defaults: defaults)               // the epoch is now saved: provenance is known
        _ = recorder(relaunched, folder)
        #expect(names(in: folder) == ["e\(first.usageGate.epoch)"])
    }

    @Test("a metrics folder that exists but cannot be listed fails closed: an inert recorder that records, uploads and flushes nothing")
    func unreadableFolderIsInert() async throws {
        let name = "hushy-test-usage-unreadable-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)                 // epoch not saved yet: provenance unknown
        settings.usageNumbersNoticeSeen = true
        settings.shareUsageNumbers = true
        let folder = try tempFolder()
        let old = folder.appendingPathComponent("e0", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old numbers".utf8).write(to: old.appendingPathComponent("journal.jsonl"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        let recorder = recorder(settings, folder)
        #expect(!recorder.isCollecting)
        recorder.recordDictation(pasted)
        await recorder.flush()                                          // returns at once
        #expect(await recorder.todaysLines().isEmpty)
        #expect(await recorder.runDailyJobs() == nil)                   // nothing closed, nothing uploaded
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        #expect(names(in: folder) == ["e0"])                            // and the old folder was never used or touched
    }

    @Test("a clean-up that fails fails closed: the recorder stays inert and the old folder is not used")
    func failedCleanupIsInert() async throws {
        let name = "hushy-test-usage-cleanup-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.usageNumbersNoticeSeen = true
        settings.shareUsageNumbers = true
        let folder = try tempFolder()
        let old = folder.appendingPathComponent("e0", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let journal = old.appendingPathComponent("journal.jsonl")
        try Data("old numbers".utf8).write(to: journal)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: journal.path)   // cannot be deleted
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: journal.path) }
        let recorder = recorder(settings, folder)
        #expect(!recorder.isCollecting)
        recorder.recordDictation(pasted)
        await recorder.flush()
        #expect(await recorder.runDailyJobs() == nil)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: journal.path)
        let fresh = self.recorder(settings, folder)                     // the next launch cleans up and carries on
        #expect(fresh.isCollecting)
        #expect(names(in: folder).isEmpty)
    }

    @Test("a folder named with a huge number neither crashes the launch nor becomes the epoch")
    func hugeFolderNameAtLaunch() throws {
        let name = "hushy-test-usage-huge-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.usageNumbersNoticeSeen = true
        settings.shareUsageNumbers = true
        let folder = try tempFolder()
        for stray in ["e9223372036854775807", "e5"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(stray), withIntermediateDirectories: true)
        }
        let recorder = recorder(settings, folder)
        #expect(settings.usageGate.epoch == 6)                          // above the real e5, not near Int.max
        #expect(recorder.isCollecting)
        #expect(names(in: folder).isEmpty)
    }

    @Test("a second process cannot take the metrics folder: its recorder records, tidies and uploads nothing")
    func secondProcessIsInert() async throws {
        let (settings, cleanup) = makeSettings()
        defer { cleanup() }
        let folder = try tempFolder()
        let first = try #require(MetricsStoreLock(root: folder))
        #expect(MetricsStoreLock(root: folder) == nil)
        let second = recorder(settings, folder, lock: true)             // another process already holds it
        #expect(!second.isCollecting)
        second.recordDictation(pasted)
        await second.flush()
        #expect(names(in: folder).isEmpty)
        _ = first
    }

    @Test("opening the sheet records nothing: only closing it (or OK) answers the notice")
    func sheetDoesNotEnableRecordingWhileOpen() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Murmur/UI/Screens/UsageNumbers/UsageNumbersDisclosureView.swift"), encoding: .utf8)
        #expect(!source.contains(".onAppear { if !isSnapshot { model.settings.usageNumbersNoticeSeen"))
        #expect(source.contains(".onDisappear { if !isSnapshot { model.settings.usageNumbersNoticeSeen = true } }"))
        let (settings, cleanup) = makeSettings(seen: false)
        defer { cleanup() }
        #expect(!settings.usageGate.isOn)                               // while the notice or sheet is open
        settings.usageNumbersNoticeSeen = true                          // closing it
        #expect(settings.usageGate.isOn)
    }

    @Test("a preview read before an off-and-on is not returned")
    func previewDroppedAcrossOffOn() async throws {
        let (settings, cleanup) = makeSettings()
        defer { cleanup() }
        let folder = try tempFolder()
        let recorder = recorder(settings, folder)
        recorder.recordDictation(pasted)
        await recorder.flush()
        #expect(!(await recorder.todaysLines()).isEmpty)
        recorder.afterPreviewReadHook = { settings.shareUsageNumbers = false; settings.shareUsageNumbers = true }
        #expect(await recorder.todaysLines().isEmpty)
        recorder.afterPreviewReadHook = nil
        #expect(await recorder.todaysLines().isEmpty)                   // and the old numbers are gone for good
    }

    @Test("rapid off then on with the deletion still pending ends on: the old data is gone and the new data is kept")
    func rapidOffOn() async throws {
        let (settings, cleanup) = makeSettings()
        defer { cleanup() }
        let folder = try tempFolder()
        let recorder = recorder(settings, folder)
        recorder.start()
        recorder.recordDictation(pasted)                       // before the switch went off: must be deleted
        settings.shareUsageNumbers = false
        settings.shareUsageNumbers = true
        recorder.record(.funnel(.firstDictation))              // after it came back on: must survive
        await recorder.flush()
        let lines = await recorder.todaysLines()
        #expect(!lines.contains { $0.hasPrefix("Dictations:") })              // the earlier dictation is gone
        #expect(lines.contains { $0.hasPrefix("Setup steps reached:") && $0.contains("First dictation 1") })
        #expect(settings.usageGate.isOn)
    }

    @Test("at launch with the switch off, whatever an earlier run left behind is deleted")
    func startupPurge() async throws {
        let name = "hushy-test-usage-purge-\(UUID().uuidString)"
        let folder = try tempFolder()
        let (before, cleanupBefore) = makeSettings(name: name)
        let first = recorder(before, folder)
        first.start()
        first.recordDictation(pasted)
        _ = await first.todaysLines()
        #expect(!names(in: folder).isEmpty)
        // The switch was turned off in a run that never got to delete (a crash): only the stored value remains.
        UserDefaults(suiteName: name)?.set(false, forKey: "shareUsageNumbers")
        let (after, cleanupAfter) = makeSettings(seen: true, on: false, name: name)
        defer { cleanupAfter(); cleanupBefore() }
        let second = recorder(after, folder)
        second.start()
        await second.flush()
        #expect(names(in: folder).isEmpty)
    }

    @Test("an inert recorder (snapshots, disposable runs) never writes or sends anything")
    func inertRecorder() async throws {
        let (settings, cleanup) = makeSettings()
        defer { cleanup() }
        let recorder = recorder(settings, nil, endpoint: URL(string: "https://metrics.example.com/b"))
        recorder.start()
        recorder.recordDictation(pasted)
        #expect(!recorder.isUploadConfigured && !recorder.isCollecting && !recorder.needsNotice)
        #expect(await recorder.runDailyJobs() == nil)
        #expect(await recorder.todaysLines().isEmpty)
    }

    @Test("a broken folder is harmless: recording returns normally and nothing is surfaced")
    func failureIsHarmless() async throws {
        let (settings, cleanup) = makeSettings()
        defer { cleanup() }
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-usage-block-\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let recorder = recorder(settings, blocker)
        recorder.start()
        recorder.recordDictation(pasted)
        recorder.record(.meeting(MeetingMetricEvent(outcome: .started, minutesRecorded: nil)))
        recorder.record(.voiceAction(VoiceActionMetricEvent(outcome: .failed, failure: .timedOut)))
        await recorder.flush()
        #expect(await recorder.todaysLines().isEmpty)
        _ = await recorder.runDailyJobs()
    }

    @Test("with no endpoint the daily job never calls the transport, even with batches waiting")
    func noEndpointNoNetwork() async throws {
        let (settings, cleanup) = makeSettings()
        defer { cleanup() }
        let folder = try tempFolder()
        let transport = CountingTransport()
        let recorder = recorder(settings, folder, endpoint: nil, transport: transport)
        recorder.start()
        recorder.recordDictation(pasted)
        _ = await recorder.todaysLines()
        let report = await recorder.runDailyJobs(now: Date().addingTimeInterval(2 * 86_400))
        #expect(report?.skipped == .noEndpoint)
        #expect(transport.count == 0)
        #expect(!recorder.isUploadConfigured)
    }

    @Test("the shipped build setting is empty, so the default build reads as no endpoint")
    func shippedBuildHasNoEndpoint() {
        #expect(MetricsEndpoint.configured() == nil)
    }

    @Test("the setup steps reached before the welcome screen are counted once, when sharing starts")
    func replayOnFirstSeen() async throws {
        let (settings, cleanup) = makeSettings(seen: false)
        defer { cleanup() }
        settings.onboardingFunnel = OnboardingFunnel().marking(.onboardingStarted, at: Date()).marking(.microphoneGranted, at: Date())
        let folder = try tempFolder()
        let recorder = recorder(settings, folder)
        recorder.start()
        settings.usageNumbersNoticeSeen = true
        let lines = await recorder.todaysLines()
        #expect(lines.contains { $0.hasPrefix("Setup steps reached:") && $0.contains("Onboarding started 1") && $0.contains("Microphone allowed 1") })
    }

    // MARK: kept or edited

    @Test("a pasted dictation is recorded once, with the edit watcher's verdict")
    func heldThenResolved() async throws {
        let (settings, cleanup) = makeSettings()
        defer { cleanup() }
        let recorder = recorder(settings, try tempFolder())
        recorder.start()
        let token = try #require(recorder.holdDictation(pasted))
        await recorder.flush()
        #expect(await recorder.todaysLines().isEmpty)          // nothing yet: waiting for the verdict
        recorder.resolveDictation(token, verdict: .kept, coverage: .observed)
        recorder.resolveDictation(token, verdict: .edited, coverage: .observed)   // a repeat changes nothing
        let lines = await recorder.todaysLines()
        #expect(lines.contains("Kept without edits: 1 of 1 checked"))
        #expect(lines.contains("Dictations: 1 in all"))
    }

    @Test("quitting records a dictation still waiting as not checked")
    func quitBeforeVerdict() async throws {
        let (settings, cleanup) = makeSettings()
        defer { cleanup() }
        let recorder = recorder(settings, try tempFolder())
        recorder.start()
        _ = recorder.holdDictation(pasted)
        recorder.flushForQuit()
        let lines = await recorder.todaysLines()
        #expect(lines.contains("Dictations: 1 in all"))
        #expect(lines.contains("Not checked: 1"))
    }

    @Test("switching off forgets a dictation that was waiting, and its late verdict records nothing")
    func offWhileHeld() async throws {
        let (settings, cleanup) = makeSettings()
        defer { cleanup() }
        let recorder = recorder(settings, try tempFolder())
        recorder.start()
        let token = try #require(recorder.holdDictation(pasted))
        settings.shareUsageNumbers = false
        settings.shareUsageNumbers = true
        recorder.resolveDictation(token, verdict: .kept, coverage: .observed)
        #expect(await recorder.todaysLines().isEmpty)
    }

    // MARK: one-time notice

    @Test("the notice is for installs that finished setup before this existed, and only until they answer")
    func notice() throws {
        let (existing, cleanupExisting) = makeSettings(seen: false)
        defer { cleanupExisting() }
        existing.hasCompletedOnboarding = true
        let folder = try tempFolder()
        let recorder = recorder(existing, folder)
        #expect(recorder.needsNotice)
        #expect(!recorder.isCollecting)                         // nothing is recorded yet
        existing.usageNumbersNoticeSeen = true                  // OK, or opening the sheet
        #expect(!recorder.needsNotice && recorder.isCollecting)

        let (fresh, cleanupFresh) = makeSettings(seen: false)
        defer { cleanupFresh() }
        #expect(!fresh.hasCompletedOnboarding)
        #expect(!self.recorder(fresh, try tempFolder()).needsNotice)   // new installs see the welcome line instead
    }

    @Test("the notice switch is the Settings setting: it starts off, on records once answered, off stops and wipes, OK with it off leaves it off")
    func noticeSwitch() async throws {
        let (settings, cleanup) = makeSettings(seen: false, on: nil)
        defer { cleanup() }
        settings.hasCompletedOnboarding = true
        let folder = try tempFolder()
        let recorder = recorder(settings, folder)
        recorder.start()
        #expect(recorder.needsNotice && !settings.shareUsageNumbers)     // off by default, notice still showing
        settings.shareUsageNumbers = true                                // the notice's switch writes this binding
        #expect(!recorder.isCollecting)                                  // on, but not answered yet: still nothing
        settings.usageNumbersNoticeSeen = true                           // OK
        #expect(!recorder.needsNotice && recorder.isCollecting)          // notice answered once; recording started
        recorder.recordDictation(pasted)
        await recorder.flush()
        #expect(!names(in: folder).isEmpty)

        settings.shareUsageNumbers = false                               // off again, no dismissal needed
        #expect(!recorder.isCollecting)                                  // synchronous, like Settings
        recorder.recordDictation(pasted)
        await recorder.flush()
        #expect(names(in: folder).isEmpty)                               // nothing recorded, the earlier numbers wiped
        #expect(!recorder.needsNotice && !settings.shareUsageNumbers)    // dismissing with it off leaves it off, once
    }

    @Test("OK on the notice with the switch left as it came: nothing is ever recorded")
    func noticeOffThenOK() async throws {
        let (settings, cleanup) = makeSettings(seen: false, on: nil)
        defer { cleanup() }
        settings.hasCompletedOnboarding = true
        let folder = try tempFolder()
        let recorder = recorder(settings, folder)
        recorder.start()
        settings.usageNumbersNoticeSeen = true
        recorder.recordDictation(pasted)
        await recorder.flush()
        #expect(!recorder.needsNotice && !recorder.isCollecting)
        #expect(names(in: folder).isEmpty)
    }

    // MARK: hot path

    @Test("with sharing off the dictation path does no metrics work at all")
    func hotPathGateFirst() {
        final class Calls: @unchecked Sendable { var count = 0 }
        let calls = Calls()
        let hooks = DictationMetricsHooks(
            isCollecting: { false }, record: { _ in calls.count += 1 }, hold: { _ in calls.count += 1; return nil },
            resolve: { _, _, _, _ in calls.count += 1 }, cleanupBackend: { calls.count += 1; return .apple },
            modelState: { _, _ in calls.count += 1; return nil })
        let started = ContinuousClock.now
        for _ in 0..<1_000 {
            hooks.report(.pasted, nil, 50_000, Mode.builtIns(userName: "")[0], 600, LatencyBreakdown(releasedAt: Date()), Date())
        }
        #expect(calls.count == 0)
        #expect(started.duration(to: .now) < .milliseconds(100))
    }

    @Test("a long dictation costs the same to report as a short one: the word count is reused, never recomputed")
    func longDictationCost() {
        let longText = Array(repeating: "word", count: 200_000).joined(separator: " ")
        let started = ContinuousClock.now
        let presentation = DeliveryPresentation.make(.pasted, text: longText, usedContext: false, asHeard: false, words: 7)
        #expect(presentation.feedback == .pill(.done(words: 7, usedContext: false, asHeard: false)))   // the given count, not a recount
        #expect(started.duration(to: .now) < .milliseconds(50))
        let hooks = DictationMetricsHooks(isCollecting: { true }, record: { _ in }, hold: { _ in UUID() })
        let reportStart = ContinuousClock.now
        let token = hooks.report(.pasted, nil, 200_000, Mode.builtIns(userName: "")[0], 600, LatencyBreakdown(releasedAt: Date()), Date())
        #expect(token != nil)
        #expect(reportStart.duration(to: .now) < .milliseconds(50))
    }
}

private final class CountingTransport: MetricsTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func post(_ body: Data, to endpoint: URL) async -> MetricsTransportOutcome {
        lock.withLock { calls += 1 }
        return .accepted
    }
}
