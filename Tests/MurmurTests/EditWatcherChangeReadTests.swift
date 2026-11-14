import Foundation
import Testing
import MurmurCore
@testable import Murmur

/// A chat box (Claude, ChatGPT, Slack, Messages) empties when its message is sent. The watcher also reads the field
/// each time the field reports a change (`LiveEditWatch.readOnChange`), so a fix sent between two scheduled looks, or
/// after a Return the app empties the box on, is seen as it stood the moment before.
@Suite("Edit watcher: change reads", .serialized)
@MainActor
struct EditWatcherChangeReadTests {
    let original = "Please call Pria tomorrow morning about the quarterly budget review before we send it."
    let fixed = "Please call Priya tomorrow morning about the quarterly budget review before we send it."
    let app = "com.anthropic.claudefordesktop"

    /// A fake field the test changes by hand; counts every read.
    final class Field {
        var value: String?
        var coverage: DictationEditObservation.Coverage = .observed
        var reads = 0
        init(_ value: String?) { self.value = value }
        func read() -> EditWatcher.ReadResult { reads += 1; return .init(fieldValue: value, coverage: coverage) }
    }

    /// The field's change reports: the watch's handler, and whether it was stopped.
    final class Reports {
        var handler: (@MainActor () -> Void)?
        var subscribed = 0
        var stopped = 0
        /// The field changes to `value` and says so.
        @MainActor func change(_ field: Field, to value: String?) {
            field.value = value
            handler?()
        }
    }

    final class Heard { var diagnosis: LearningDiagnosis? }

    /// Watches `field` to the end. `beforeLook` runs as the schedule wakes for its n-th look (1 is the 0.5 s look; 13
    /// is the 8 s verdict look; 14 the 12 s look). With `reports` nil the field reports nothing (today's behaviour).
    @discardableResult
    private func watch(
        _ field: Field, store: Store, id: Int64, reports: Reports?, learning: Bool = true,
        beforeLook: @escaping @MainActor (Int) throws -> Void
    ) async -> LearningDiagnosis? {
        let input = EditWatcher.LearningInput(raw: original, context: LearningContext(appBundleID: app))
        var count = 0
        let heard = Heard()
        await EditWatcher.observe(
            inserted: original, dictationID: id, store: store, learning: learning ? input : nil, app: app,
            report: { heard.diagnosis = $0 },
            readField: { field.read() },
            subscribeChanges: { handler in
                guard let reports else { return {} }
                reports.subscribed += 1
                reports.handler = handler
                return { reports.stopped += 1; reports.handler = nil }
            },
            sleep: { _ in count += 1; try beforeLook(count) }).value
        return heard.diagnosis
    }

    private func taught(_ diagnosis: LearningDiagnosis?) -> Bool {
        switch diagnosis?.outcome {
        case .candidate, .learned, .kept, .alreadyLearned: true
        default: false
        }
    }

    private func saved(_ store: Store) throws -> Int64 {
        try #require(store.save(Dictation(rawText: original, text: original, durationSeconds: 1)).id)
    }

    @Test("a fix made after the verdict look and sent with a click is learned from the change read before the clear")
    func lateFixSentWithAClick() async throws {
        let store = try Store()
        let reports = Reports()
        let field = Field(original)
        // Between the 8 s and 12 s looks: the person fixes the name, then clicks Send and the box empties.
        let diagnosis = await watch(field, store: store, id: try saved(store), reports: reports) { n in
            if n == 14 {
                reports.change(field, to: fixed)
                reports.change(field, to: "")
            }
        }
        #expect(taught(diagnosis), "\(String(describing: diagnosis?.line))")
        #expect(diagnosis?.changeLooks == 2)
        #expect(diagnosis?.beforeClear == 1)
        #expect(diagnosis?.line.contains("on-change=2 before-clear=1") == true)
    }

    @Test("the same fix, from a field that reports nothing, is lost: the schedule never sees it")
    func sameFixWithoutReports() async throws {
        let store = try Store()
        let field = Field(original)
        let diagnosis = await watch(field, store: store, id: try saved(store), reports: nil) { n in
            if n == 14 { field.value = "" }   // fixed and sent between the 8 s and 12 s looks, unseen
        }
        #expect(!taught(diagnosis))
        #expect(diagnosis?.line.contains("on-change") == false, "no change reads, so the line is as before")
    }

    @Test("a fix sent before the verdict look: the verdict says fieldCleared, the change read still teaches")
    func clearedBeforeTheVerdict() async throws {
        let store = try Store()
        let reports = Reports()
        let field = Field(original)
        // After the 6 s look and before the 8 s verdict look (the gap where today only the Return read can help).
        let diagnosis = await watch(field, store: store, id: try saved(store), reports: reports) { n in
            if n == 13 {
                reports.change(field, to: fixed)
                reports.change(field, to: "")
            }
        }
        #expect(diagnosis?.coverage == DictationEditObservation.Coverage.fieldCleared.rawValue)
        #expect(taught(diagnosis), "\(String(describing: diagnosis?.line))")
    }

    @Test("a name typed letter by letter and sent at once is learned, not held back as half typed")
    func typedLetterByLetter() async throws {
        let store = try Store()
        let reports = Reports()
        let field = Field(original)
        let diagnosis = await watch(field, store: store, id: try saved(store), reports: reports) { n in
            if n == 14 {
                for typed in ["P", "Pr", "Pri", "Priy", "Priya"] {
                    reports.change(field, to: original.replacingOccurrences(of: "Pria", with: typed))
                }
                reports.change(field, to: "")
            }
        }
        #expect(taught(diagnosis), "\(String(describing: diagnosis?.line))")
    }

    @Test("once the person dictates again, what the field shows is Hushy's text, not their fix, and teaches nothing")
    func nextDictationIsNotTheirEdit() async throws {
        let store = try Store()
        let reports = Reports()
        let field = Field(original)
        let id = try saved(store)
        let diagnosis = await watch(field, store: store, id: id, reports: reports) { n in
            if n == 14 {
                // A second dictation is pasted over the name (a fix by voice): Hushy wrote it, the person did not type it.
                // Saved before it is pasted; a few ms back covers the store's date precision in a test this fast.
                _ = try store.save(Dictation(createdAt: Date().addingTimeInterval(-0.005), rawText: "Priya", text: "Priya", durationSeconds: 1))
                reports.change(field, to: fixed)
                reports.change(field, to: "")
            }
        }
        #expect(!taught(diagnosis), "\(String(describing: diagnosis?.line))")
    }

    @Test("a message sent as it was pasted teaches nothing")
    func sentAsPasted() async throws {
        let store = try Store()
        let reports = Reports()
        let field = Field(original)
        let diagnosis = await watch(field, store: store, id: try saved(store), reports: reports) { n in
            if n == 4 { reports.change(field, to: "") }
        }
        #expect(diagnosis?.outcome == .noChange)
    }

    @Test("a watch that only takes the verdict never listens for changes")
    func verdictOnlyDoesNotListen() async throws {
        let store = try Store()
        let reports = Reports()
        await watch(Field(original), store: store, id: try saved(store), reports: reports, learning: false) { _ in }
        #expect(reports.subscribed == 0)
    }

    @Test("listening stops when the watch ends, and a report after that reads nothing")
    func stopsAtTheEnd() async throws {
        let store = try Store()
        let reports = Reports()
        let field = Field(original)
        var handler: (@MainActor () -> Void)?
        await watch(field, store: store, id: try saved(store), reports: reports) { n in
            if n == 1 { handler = reports.handler }
        }
        #expect(reports.subscribed == 1)
        #expect(reports.stopped == 1)
        let before = field.reads
        handler?()
        #expect(field.reads == before)
    }

    @Test("change reads stop at the cap, on a secure field, and after a read that fails")
    func bounds() async throws {
        let store = try Store()
        let capped = Reports()
        let busy = Field(original)
        var taken = -1
        await watch(busy, store: store, id: try saved(store), reports: capped) { n in
            if n == 2 {
                let before = busy.reads
                for _ in 0..<(LearningReadSchedule.maxChangeReads + 20) { capped.handler?() }
                taken = busy.reads - before
            }
        }
        #expect(taken == LearningReadSchedule.maxChangeReads)

        let secure = Reports()
        let password = Field(original)
        taken = -1
        await watch(password, store: store, id: try saved(store), reports: secure) { n in
            if n == 1 { password.coverage = .secure; password.value = nil }
            if n == 2 {
                let before = password.reads
                secure.handler?()
                taken = password.reads - before
            }
        }
        #expect(taken == 0, "a field once seen secure is not read again")

        let hung = Reports()
        let stalled = Field(original)
        taken = -1
        await watch(stalled, store: store, id: try saved(store), reports: hung) { n in
            if n == 2 {
                stalled.coverage = .fieldUnreadable
                stalled.value = nil
                let before = stalled.reads
                for _ in 0..<5 { hung.handler?() }
                taken = stalled.reads - before
            }
        }
        #expect(taken == 1, "one failed change read ends change reads for the watch")
    }
}
