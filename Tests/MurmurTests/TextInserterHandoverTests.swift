import AppKit
import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// What `TextInserter.deliver` hands back for a paste into a field Hushy is sure of: the second look, built from the
/// read made at key-down. The paster is a real `ClipboardPaster` on a private pasteboard with a fake ⌘V, and the
/// field is scripted, so nothing here pastes into an app, reads one, or touches the person's clipboard.
@Suite("TextInserter hands over the second look", .serialized)
@MainActor
final class TextInserterHandoverTests {
    private let text = "Ship it on Thursday."
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("app.hushy.tests.handover.\(UUID().uuidString)"))
    private var paster: ClipboardPaster!
    private var readsAfterPaste: [Bool] = []
    private var queue: [LandingProbe?] = []

    init() {
        paster = ClipboardPaster(pasteboard: pasteboard, postKey: { _, _ in true },
                                 restoreDelay: .milliseconds(5), returnDelay: .milliseconds(1))
    }

    isolated deinit { pasteboard.releaseGlobally() }

    private func probe(count: Int) -> LandingProbe { LandingProbe(characterCount: count, selectedLength: 0, caretLocation: count) }

    /// The field as it reads after ⌘V: the next entry of `queue`, then the last one again.
    private var access: TextInserter.FieldAccess {
        TextInserter.FieldAccess(
            verdict: { .unchanged },
            read: { [unowned self] _, afterPaste in
                readsAfterPaste.append(afterPaste)
                let next = queue.count > 1 ? queue.removeFirst() : queue.first ?? nil
                return (next, next == nil ? .noElement : .ok)
            })
    }

    private func deliver(baseline: LandingProbe?, pressReturn: Bool = false) async -> TextInserter.Delivered {
        let delivered = await TextInserter.deliver(
            text, to: .scriptedField(baseline: baseline), pressReturn: pressReturn, paster: paster, access: { _ in access })
        await paster.waitForPendingRestore()
        return delivered
    }

    @Test("a known field read at key-down is pasted with no read of it on the way, and a look comes back")
    func lookComesBackWithoutAPrePasteRead() async throws {
        queue = [probe(count: 3)]
        let delivered = await deliver(baseline: probe(count: 3))
        #expect(delivered.result == .pasted)
        #expect(readsAfterPaste.isEmpty, "nothing is read between key-down and ⌘V, or by the paste itself")
        let look = try #require(delivered.lateLanding)
        #expect(await look() == .notLanded, "the field never changed from the key-down read")
    }

    @Test("the look reads the field with every read bounded, at most five times, and one read confirms a changed count")
    func lookReadsAreBounded() async throws {
        queue = [probe(count: 3)]
        let look = try #require(await deliver(baseline: probe(count: 3)).lateLanding)
        _ = await look()
        #expect(!readsAfterPaste.isEmpty && readsAfterPaste.count <= 5, "five at most; fewer when a busy Mac runs the look out of time")
        #expect(readsAfterPaste.allSatisfy { $0 }, "every read of the look bounds the guard check as well")

        readsAfterPaste = []
        queue = [probe(count: 3 + text.utf16.count)]
        let second = try #require(await deliver(baseline: probe(count: 3)).lateLanding)
        #expect(await second() == .confirmed)
        #expect(readsAfterPaste.count == 1)
    }

    @Test("a paste sent with Return gets no look")
    func noLookAfterReturn() async {
        queue = [probe(count: 0)]
        let delivered = await deliver(baseline: probe(count: 0), pressReturn: true)
        #expect(delivered.result == .pasted)
        #expect(delivered.lateLanding == nil, "the composer clears itself on send, so 0 to 0 would read as a lost paste")
    }

    @Test("a field that was not read at key-down gets no look")
    func noLookWithoutABaseline() async {
        queue = [probe(count: 3)]
        let delivered = await deliver(baseline: nil)
        #expect(delivered.result == .pasted)
        #expect(delivered.lateLanding == nil)
        #expect(readsAfterPaste.isEmpty)
    }
}
