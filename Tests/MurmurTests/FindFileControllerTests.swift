import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// "Find my file" through the voice-action controller: a fake index, a fake Finder and an
/// in-memory store. Nothing here searches a real folder or touches Finder. The Task 114 rules
/// apply: one usage event per real attempt (a category only), one monthly use per delivered answer,
/// nothing written to the pill by a cancelled or superseded search, and nothing acts but one clear
/// name match.
@Suite("Find my file: controller", .serialized)
@MainActor
struct FindFileControllerTests {
    private static let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    @MainActor
    final class FakeLauncher: FileLaunching {
        var existing: Set<String> = []
        private(set) var revealed: [String] = []
        private(set) var opened: [String] = []
        func exists(_ path: String) -> Bool { existing.contains(path) }
        func reveal(_ path: String) { revealed.append(path) }
        func open(_ path: String) -> Bool {
            opened.append(path)
            return true
        }
    }

    private final class Metrics: @unchecked Sendable { var list: [VoiceActionMetricEvent] = [] }

    @MainActor
    struct Rig {
        let controller: VoiceActionsController
        let pill = PillModel()
        let store: Store
        let launcher = FakeLauncher()
        private let metrics = Metrics()
        private let saved: (FileFindEngine, any FileLaunching, URL)

        var events: [VoiceActionMetricEvent] { metrics.list }

        init(files: [FileCandidate], contents: [String: String] = [:], delay: Duration = .zero) throws {
            saved = (FileServices.engine, FileServices.launcher, FileServices.home)
            store = try Store()
            let integrity = SpeechModelIntegrity(
                fetchManifest: { _ in throw CocoaError(.fileReadUnknown) }, defaultsSuiteName: "hushy-test-\(UUID().uuidString)")
            controller = VoiceActionsController(
                hotkeys: ActionHotkeyMonitor(), pill: pill,
                speech: SpeechEngine(status: SpeechModelStatus(), integrity: integrity),
                modelStatus: SpeechModelStatus(), store: store, calendarBackend: FakeCalendarBackend(),
                shortcutsBackend: FakeShortcutsBackend(installedShortcuts: []), linkBackend: FakeLinkBackend())
            controller.isEntitled = { false }
            let sink = metrics
            controller.onMetric = { sink.list.append($0) }
            launcher.existing = Set(files.map(\.path))
            FileServices.home = FindFileControllerTests.home
            FileServices.engine = FileFindEngine(
                finder: InMemoryFileFinder(files: files, contents: contents, delay: delay), home: FindFileControllerTests.home)
            FileServices.launcher = launcher
        }

        func restore() {
            FileServices.engine = saved.0
            FileServices.launcher = saved.1
            FileServices.home = saved.2
        }

        func say(_ words: String) async {
            controller.transcribeSamples = { _ in words }
            await controller.process([0.1], followUp: nil)
        }

        var files: FileResultsContent? {
            if case .answer(let card) = pill.state, case .files(let content) = card.phase { content } else { nil }
        }

        var failure: String? {
            if case .answer(let card) = pill.state, case .failure(let failure) = card.phase { failure.message } else { nil }
        }

        var uses: Int { (try? store.voiceActionsThisMonth()) ?? -1 }
    }

    private func file(_ relative: String, day: Int = 20, kinds: Set<FileKind> = [.pdf, .document]) -> FileCandidate {
        FileCandidate(
            path: Self.home.path + "/" + relative,
            modified: Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: day, hour: 12)), kinds: kinds)
    }

    @Test("one clear winner is shown in Finder once, counts one use and one event, and does not open")
    func oneWinner() async throws {
        let resume = file("Documents/Jobs/Resume.pdf")
        let rig = try Rig(files: [resume])
        defer { rig.restore() }
        await rig.say("can you find and fetch my resume")
        #expect(rig.launcher.revealed == [resume.path])
        #expect(rig.launcher.opened.isEmpty)
        #expect(rig.files?.rows.map(\.path) == [resume.path])
        #expect(rig.events == [VoiceActionMetricEvent(outcome: .succeeded, failure: nil)])
        #expect(rig.uses == 1)
        let records = try rig.store.recentActions()
        #expect(records.count == 1)
        #expect(records.first?.title == "Showed a file in Finder")
        #expect(records.first?.sourceText == "")
        #expect(records.first?.detail == "On this Mac")
    }

    @Test("a spoken open opens the one clear winner, and a click on a card file only reveals or opens that file")
    func openVerb() async throws {
        let resume = file("Documents/Jobs/Resume.pdf")
        let rig = try Rig(files: [resume])
        defer { rig.restore() }
        await rig.say("open my resume")
        #expect(rig.launcher.opened == [resume.path])
        #expect(rig.launcher.revealed.isEmpty)
        #expect(rig.uses == 1)
        rig.controller.revealFile(rowID: 0)
        #expect(rig.launcher.revealed == [resume.path])
        #expect(rig.uses == 1, "a click is not a new attempt")
        #expect(rig.events.count == 1)
    }

    @Test("a script is shown in Finder, never opened")
    func scriptNeverOpens() async throws {
        let script = file("Documents/resume-builder.command", kinds: [])
        let rig = try Rig(files: [script])
        defer { rig.restore() }
        await rig.say("open my resume")
        #expect(rig.launcher.opened.isEmpty)
        #expect(rig.launcher.revealed == [script.path])
    }

    @Test("several matches act on nothing, count once, and wait for a pick")
    func several() async throws {
        let rig = try Rig(files: [file("Documents/Invoice acme.pdf", day: 10), file("Documents/Invoice dana.pdf", day: 11)])
        defer { rig.restore() }
        await rig.say("open my invoices")
        #expect(rig.launcher.revealed.isEmpty && rig.launcher.opened.isEmpty)
        #expect(rig.files?.rows.count == 2)
        #expect(rig.events == [VoiceActionMetricEvent(outcome: .succeeded, failure: nil)])
        #expect(rig.uses == 1)
        #expect(try rig.store.recentActions().isEmpty)
    }

    @Test("a match found only in the file text acts on nothing")
    func contentOnly() async throws {
        let notes = file("Documents/Notes on onboarding.docx", kinds: [.document])
        let rig = try Rig(files: [notes], contents: [notes.path: "Kafka consumer groups"])
        defer { rig.restore() }
        await rig.say("find the doc about kafka")
        #expect(rig.launcher.revealed.isEmpty && rig.launcher.opened.isEmpty)
        #expect(rig.files?.text == FileCardText.mentionsOne)
        #expect(rig.uses == 1)
    }

    @Test("nothing found: one failed-not-found event, no use, no effect, plain words")
    func nothing() async throws {
        let rig = try Rig(files: [file("Documents/Resume.pdf")])
        defer { rig.restore() }
        await rig.say("find my visa pdf")
        #expect(rig.failure == "I couldn't find a file like that.")
        #expect(rig.events == [VoiceActionMetricEvent(outcome: .failed, failure: .notFound)])
        #expect(rig.uses == 0)
        #expect(rig.launcher.revealed.isEmpty && rig.launcher.opened.isEmpty)
    }

    @Test("a cancelled search writes nothing to the pill, reports nothing itself and acts on nothing")
    func cancelled() async throws {
        let rig = try Rig(files: [file("Documents/Resume.pdf")], delay: .seconds(5))
        defer { rig.restore() }
        let task = Task { @MainActor in await rig.say("find my resume") }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await task.value
        #expect(rig.files == nil && rig.failure == nil)
        #expect(rig.events.isEmpty, "esc reports the cancel once, in cancelProcessing")
        #expect(rig.uses == 0)
        #expect(rig.launcher.revealed.isEmpty)
    }

    @Test("a search superseded by a newer utterance leaves the newer pill alone and acts on nothing")
    func superseded() async throws {
        let rig = try Rig(files: [file("Documents/Resume.pdf")], delay: .milliseconds(150))
        defer { rig.restore() }
        let older = Task { @MainActor in await rig.say("find my resume") }
        try? await Task.sleep(for: .milliseconds(40))
        rig.controller.supersedePresentation()
        rig.pill.state = .error("newer")
        await older.value
        #expect(rig.pill.state == .error("newer"))
        #expect(rig.events.isEmpty && rig.uses == 0)
        #expect(rig.launcher.revealed.isEmpty)
    }

    @Test("usage events carry a category only, whatever the outcome")
    func eventsAreCategories() {
        let outcomes: [FileFindOutcome] = [
            .foundOne(file("Documents/Secret acme plan.pdf"), matchedBy: .name), .none, .unavailable(.slow),
            .unavailable(.indexOff), .unavailable(.folderNotReadable), .unavailable(.failed),
        ]
        let events = outcomes.map(VoiceActionsController.metric(for:))
        #expect(events.map(\.outcome) == [.succeeded, .failed, .failed, .failed, .failed, .failed])
        #expect(events.map(\.failure) == [nil, .notFound, .timedOut, .backendFailed, .permissionDenied, .backendFailed])
    }
}
