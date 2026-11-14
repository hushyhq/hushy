import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
import MurmurCore
@testable import Murmur

/// A fix sent with Return can be gone from the field before the next scheduled look. Return in
/// the watched app takes one extra look at once (`EditWatcher.returnPressed`).
@Suite("Edit watcher: the Return read", .serialized)
@MainActor
struct EditWatcherReturnReadTests {
    let original = "Please call Pria tomorrow morning about the quarterly budget review before we send it."
    let fixed = "Please call Priya tomorrow morning about the quarterly budget review before we send it."
    let app = "com.example.chat"

    /// A fake field the test changes by hand; counts every read.
    final class Field {
        var value: String?
        var coverage: DictationEditObservation.Coverage = .observed
        var reads = 0
        init(_ value: String?) { self.value = value }
        func read() -> EditWatcher.ReadResult { reads += 1; return .init(fieldValue: value, coverage: coverage) }
    }

    final class Heard { var diagnosis: LearningDiagnosis? }

    /// Watches `field` to the end; `beforeLook` runs as the schedule wakes for its n-th look (1 is
    /// the 0.5 s look). Returns what the watch came to.
    @discardableResult
    private func watch(
        _ field: Field, store: Store, id: Int64, learning: Bool = true, allowed: @escaping @MainActor () -> Bool = { true },
        beforeLook: @escaping @MainActor (Int) throws -> Void
    ) async -> LearningDiagnosis? {
        var input = EditWatcher.LearningInput(raw: original, context: LearningContext(appBundleID: app))
        input.isStillAllowed = allowed
        var count = 0
        let heard = Heard()
        await EditWatcher.observe(
            inserted: original, dictationID: id, store: store, learning: learning ? input : nil, app: app,
            report: { heard.diagnosis = $0 },
            readField: { field.read() },
            sleep: { _ in count += 1; try beforeLook(count) }).value
        return heard.diagnosis
    }

    /// Whether the watch wrote anything the person's fix taught.
    private func taught(_ diagnosis: LearningDiagnosis?) -> Bool {
        switch diagnosis?.outcome {
        case .candidate, .learned, .kept, .alreadyLearned: true
        default: false
        }
    }

    private func saved(_ store: Store) throws -> Int64 {
        try #require(store.save(Dictation(rawText: original, text: original, durationSeconds: 1)).id)
    }

    @Test("a fix made and sent before the first scheduled look is learned from the Return read")
    func fixSeenOnlyAtReturn() async throws {
        let store = try Store()
        let id = try saved(store)
        let field = Field(fixed)   // fixed at 0.2 s
        // Return at 0.3 s takes a look; the app empties the field at 0.35 s; the 0.5 s look finds it empty.
        let diagnosis = await watch(field, store: store, id: id) { n in
            if n == 1 {
                EditWatcher.returnPressed(frontmostBundleID: app)
                field.value = ""
            }
        }
        #expect(taught(diagnosis), "the Return read saw the fix; later empty reads cannot erase it: \(String(describing: diagnosis?.line))")
    }

    @Test("without the Return read the same fix is lost")
    func sameFixWithoutReturn() async throws {
        let store = try Store()
        let id = try saved(store)
        let field = Field(fixed)
        let diagnosis = await watch(field, store: store, id: id) { n in if n == 1 { field.value = "" } }
        #expect(!taught(diagnosis), "\(String(describing: diagnosis?.line))")
    }

    @Test("the Return read is one extra read, taken at once, ahead of the scheduled look it overlaps")
    func order() async throws {
        let store = try Store()
        let id = try saved(store)
        let field = Field(original)
        var readsAtReturn = -1
        var readsAfterReturn = -1
        await watch(field, store: store, id: id) { n in
            if n == 3 {
                readsAtReturn = field.reads
                EditWatcher.returnPressed(frontmostBundleID: app)
                readsAfterReturn = field.reads
            }
        }
        #expect(readsAtReturn == 2)
        #expect(readsAfterReturn == 3, "Return reads the field before the schedule's next look")
        #expect(field.reads == LearningReadSchedule.offsets.count + 1)
    }

    @Test("only the first Return takes a read")
    func firstReturnOnly() async throws {
        let store = try Store()
        let id = try saved(store)
        let field = Field(original)
        var extra = 0
        await watch(field, store: store, id: id) { n in
            if n == 2 {
                for _ in 0..<3 {
                    let before = field.reads
                    EditWatcher.returnPressed(frontmostBundleID: app)
                    extra += field.reads - before
                }
            }
        }
        #expect(extra == 1)
    }

    @Test("no read when no watch is live")
    func noWatch() async throws {
        let store = try Store()
        let id = try saved(store)
        let field = Field(original)
        await watch(field, store: store, id: id) { _ in }
        let before = field.reads
        EditWatcher.returnPressed(frontmostBundleID: app)
        EditWatcher.returnPressed(frontmostBundleID: nil)
        #expect(field.reads == before, "the schedule is over, so the watch is gone")
    }

    @Test("no read when the frontmost app is not the watched one")
    func otherApp() async throws {
        let store = try Store()
        let id = try saved(store)
        let field = Field(original)
        var extra = -1
        await watch(field, store: store, id: id) { n in
            if n == 2 {
                let before = field.reads
                EditWatcher.returnPressed(frontmostBundleID: "com.example.other")
                EditWatcher.returnPressed(frontmostBundleID: nil)
                extra = field.reads - before
            }
        }
        #expect(extra == 0)
    }

    @Test("no read when learning was never asked for, or is switched off")
    func learningOff() async throws {
        let store = try Store()
        let id = try saved(store)
        let neverAsked = Field(original)
        var extra = -1
        await watch(neverAsked, store: store, id: id, learning: false) { n in
            if n == 1 {
                let before = neverAsked.reads
                EditWatcher.returnPressed(frontmostBundleID: app)
                extra = neverAsked.reads - before
            }
        }
        #expect(extra == 0)

        var allowed = true
        let switchedOff = Field(original)
        extra = -1
        await watch(switchedOff, store: store, id: id, allowed: { allowed }) { n in
            if n == 1 {
                allowed = false   // learning switched off in settings
                let before = switchedOff.reads
                EditWatcher.returnPressed(frontmostBundleID: app)
                extra = switchedOff.reads - before
            }
        }
        #expect(extra == 0)
    }

    @Test("no read, and nothing learned, from a secure field")
    func secureField() async throws {
        let store = try Store()
        let id = try saved(store)
        let field = Field(fixed)
        var extra = -1
        let first = await watch(field, store: store, id: id) { n in
            if n == 1 {   // the first scheduled look finds the field secure
                field.coverage = .secure
                field.value = nil
            }
            if n == 2 {   // so a later Return must not read it again
                let before = field.reads
                EditWatcher.returnPressed(frontmostBundleID: app)
                extra = field.reads - before
            }
        }
        #expect(extra == 0)
        #expect(!taught(first))

        // A field that is secure at the Return look itself: its text is never used.
        let id2 = try saved(store)
        let secureAtReturn = Field(fixed)
        secureAtReturn.coverage = .secure
        let second = await watch(secureAtReturn, store: store, id: id2) { n in
            if n == 1 { EditWatcher.returnPressed(frontmostBundleID: app) }
        }
        #expect(!taught(second))
    }

    @Test("a superseded watch takes no Return read")
    func superseded() async throws {
        let store = try Store()
        let id = try saved(store)
        let field = Field(original)
        var extra = -1
        await watch(field, store: store, id: id) { n in
            if n == 2 {
                try store.updateTranscription(id: id, rawText: original, text: original, status: .inserted)
                let before = field.reads
                EditWatcher.returnPressed(frontmostBundleID: app)
                extra = field.reads - before
            }
        }
        #expect(extra == 0)
    }
}

@Suite("Return key signal from the event tap")
@MainActor
struct ReturnKeySignalTests {
    private func key(_ code: Int, _ flags: CGEventFlags = []) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
        event.flags = flags
        return event
    }

    @Test("only a plain or command Return or Enter that is not auto-repeating counts")
    func whichKeys() {
        #expect(HotkeyMonitor.sendsMessage(keyCode: kVK_Return, flags: [], isRepeat: false))
        #expect(HotkeyMonitor.sendsMessage(keyCode: kVK_Return, flags: .maskCommand, isRepeat: false))
        #expect(HotkeyMonitor.sendsMessage(keyCode: kVK_ANSI_KeypadEnter, flags: [], isRepeat: false))
        #expect(!HotkeyMonitor.sendsMessage(keyCode: kVK_Return, flags: .maskShift, isRepeat: false))
        #expect(!HotkeyMonitor.sendsMessage(keyCode: kVK_Return, flags: [], isRepeat: true))
        #expect(!HotkeyMonitor.sendsMessage(keyCode: kVK_ANSI_A, flags: [], isRepeat: false))
    }

    @Test("the tap signals after it returns, never consumes the key, and ignores other keys")
    func tapSignal() async {
        let monitor = HotkeyMonitor()
        var signals = 0
        monitor.onReturnKey = { signals += 1 }
        let consumed = monitor.handleRecorded(type: .keyDown, event: key(kVK_Return), at: Date())
        #expect(!consumed)
        #expect(signals == 0, "the signal is posted for after the callback, not run inside it")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(signals == 1)
        _ = monitor.handleRecorded(type: .keyDown, event: key(kVK_ANSI_A), at: Date())
        try? await Task.sleep(for: .milliseconds(50))
        #expect(signals == 1)
    }

    @Test("a Return that Hushy takes (finishing a hands-free dictation) is not signalled")
    func consumedReturn() async {
        let monitor = HotkeyMonitor()
        monitor.isDictationActive = true
        monitor.isLatched = true
        var signals = 0
        monitor.onReturnKey = { signals += 1 }
        let consumed = monitor.handleRecorded(type: .keyDown, event: key(kVK_Return), at: Date())
        #expect(consumed)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(signals == 0)
    }
}
