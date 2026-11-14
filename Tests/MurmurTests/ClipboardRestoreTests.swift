import AppKit
import Carbon.HIToolbox
import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The product rule: after a dictation is pasted with "keep on clipboard" off, the clipboard holds
/// exactly what it held before (every item, every type, in order), or whatever the person copied in
/// between. Never a dictation, never an older saved copy. Every test drives a private, uniquely named
/// pasteboard and a fake ⌘V; nothing here reads or writes the person's clipboard.
@Suite("Clipboard restore — screenshot-shaped clipboards", .serialized)
@MainActor
final class ClipboardRestoreTests {
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("app.hushy.tests.restore.\(UUID().uuidString)"))
    private var paster: ClipboardPaster!
    private var logs: [String] = []
    /// Runs inside the fake ⌘V, i.e. while the dictation is staged and before the restore.
    private var duringPaste: () -> Void = {}

    init(restoreDelay: Duration = .milliseconds(20)) {
        paster = ClipboardPaster(pasteboard: pasteboard, postKey: { [unowned self] key, _ in
            if key == CGKeyCode(kVK_ANSI_V) { duringPaste() }
            return true
        }, restoreDelay: restoreDelay, returnDelay: .milliseconds(1))
        paster.onLog = { [unowned self] line in logs.append(line) }
    }

    isolated deinit { pasteboard.releaseGlobally() }

    // MARK: fixtures

    /// Deterministic noise, so a byte-for-byte comparison means something.
    private static func blob(_ megabytes: Int, seed: UInt8) -> Data {
        var generator = SeededGenerator(state: UInt64(seed) &+ 0x9E37_79B9_7F4A_7C15)
        return Data((0..<(megabytes * 1_048_576)).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    private static let png = blob(3, seed: 1)
    private static let tiff = blob(4, seed: 2)

    /// What the system screenshot-to-clipboard shortcut leaves: one item, PNG first, then TIFF.
    private func copyScreenshot() {
        let item = NSPasteboardItem()
        item.setData(Self.png, forType: .png)
        item.setData(Self.tiff, forType: .tiff)
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([item]))
    }

    private func copyText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func expectScreenshot(sourceLocation: SourceLocation = #_sourceLocation) {
        let items = ClipboardSnapshot.capture(pasteboard).items
        #expect(items.count == 1, sourceLocation: sourceLocation)
        #expect(items.first?.map(\.type) == [.png, .tiff], sourceLocation: sourceLocation)
        #expect(items.first?.first(where: { $0.type == .png })?.data == Self.png, sourceLocation: sourceLocation)
        #expect(items.first?.first(where: { $0.type == .tiff })?.data == Self.tiff, sourceLocation: sourceLocation)
        #expect(!isOurDictation, sourceLocation: sourceLocation)
    }

    private var isOurDictation: Bool {
        pasteboard.data(forType: ClipboardPaster.transientType) != nil
    }

    @discardableResult
    private func dictate(_ text: String, waitForRestore: Bool = true) async -> String {
        _ = await paster.paste(text, pressReturn: false, awaitLanding: nil, hasFocus: { true })
        if waitForRestore { await paster.waitForPendingRestore() }
        return text
    }

    // MARK: sequences

    @Test("copy X, dictate, copy screenshot, dictate, dictate again quickly: the screenshot comes back intact")
    func screenshotSurvivesDictations() async {
        copyText("a link the person copied")
        await dictate("first words")
        #expect(pasteboard.string(forType: .string) == "a link the person copied")

        copyScreenshot()
        await dictate("second words")
        expectScreenshot()

        // A quick second dictation reuses the saved original; both restores must end on the screenshot.
        await dictate("third words", waitForRestore: false)
        await dictate("fourth words")
        expectScreenshot()

        await dictate("fifth words")
        await dictate("sixth words")
        expectScreenshot()
    }

    @Test("a lazily provided screenshot (data promised, not present) round-trips")
    func lazyProviderRoundTrips() async {
        final class Provider: NSObject, NSPasteboardItemDataProvider {
            let png: Data, tiff: Data
            init(png: Data, tiff: Data) { self.png = png; self.tiff = tiff }
            func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
                item.setData(type == .png ? png : tiff, forType: type)
            }
        }
        let provider = Provider(png: Self.png, tiff: Self.tiff)
        let item = NSPasteboardItem()
        #expect(item.setDataProvider(provider, forTypes: [.png, .tiff]))
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([item]))

        await dictate("words over a promised screenshot")
        await dictate("more words", waitForRestore: false)
        await dictate("and more")
        withExtendedLifetime(provider) { expectScreenshot() }
    }

    @Test("a file-URL item and a multi-item clipboard come back with every item and type, in order")
    func fileURLAndMultipleItems() async {
        let first = NSPasteboardItem()
        first.setString("file:///tmp/hushy-restore-test/a.png", forType: .fileURL)
        first.setString("a.png", forType: .string)
        let second = NSPasteboardItem()
        second.setString("file:///tmp/hushy-restore-test/b.png", forType: .fileURL)
        second.setData(Self.png, forType: .png)
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([first, second]))
        let before = ClipboardSnapshot.capture(pasteboard)
        #expect(before.itemCount == 2)

        await dictate("words over files")
        await dictate("again", waitForRestore: false)
        await dictate("and again")

        let after = ClipboardSnapshot.capture(pasteboard)
        #expect(after.items.map { $0.map(\.type) } == before.items.map { $0.map(\.type) })
        #expect(after.items.map { $0.map(\.data) } == before.items.map { $0.map(\.data) })
    }

    @Test("something re-writes our staged item mid-paste (count moves, content is ours): still restored")
    func rewrittenTransientItemIsStillRestored() async {
        copyScreenshot()
        duringPaste = { [unowned self] in
            // A clipboard manager / Universal Clipboard / the target app touching the pasteboard.
            let items = (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
                let copy = NSPasteboardItem()
                for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
                return copy
            }
            pasteboard.clearContents()
            pasteboard.writeObjects(items)
        }
        await dictate("words")
        expectScreenshot()
        #expect(logs.last?.hasSuffix("restore=restored") == true)
    }

    @Test("a second dictation after a re-write saves the person's clipboard, never the first dictation")
    func secondDictationAfterRewriteDoesNotSaveOurText() async {
        let slow = ClipboardRestoreTests(restoreDelay: .milliseconds(300))
        slow.copyScreenshot()
        slow.duringPaste = { [unowned slow] in
            let items = (slow.pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
                let copy = NSPasteboardItem()
                for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
                return copy
            }
            slow.pasteboard.clearContents()
            slow.pasteboard.writeObjects(items)
        }
        await slow.dictate("first dictation", waitForRestore: false)
        slow.duringPaste = {}
        await slow.dictate("second dictation")
        slow.expectScreenshot()
        #expect(slow.logs.contains { $0.contains("original=reused") })
        #expect(slow.logs.allSatisfy { !$0.contains("dictation") })
    }

    @Test("the person copies something new during the paste window: that new thing stays, and is what the next paste restores")
    func newCopyWins() async {
        copyText("old clipboard")
        duringPaste = { [unowned self] in copyScreenshot() }
        await dictate("words")
        expectScreenshot()
        #expect(logs.last?.hasSuffix("restore=skipped-clipboard-changed") == true)

        duringPaste = {}
        await dictate("more words")
        expectScreenshot()
    }

    @Test("something re-publishes our text as a plain string, marker dropped: still ours, restored")
    func rewriteWithoutMarkerIsRestored() async {
        copyScreenshot()
        duringPaste = { [unowned self] in copyText("words") }
        await dictate("words")
        expectScreenshot()
        #expect(logs.last?.hasSuffix("restore=restored") == true)
    }

    @Test("marker-less re-write, then a quick second dictation: it saves the person's clipboard, not the dictation")
    func secondDictationAfterMarkerlessRewrite() async {
        let slow = ClipboardRestoreTests(restoreDelay: .milliseconds(300))
        slow.copyScreenshot()
        slow.duringPaste = { [unowned slow] in slow.copyText("first dictation") }
        await slow.dictate("first dictation", waitForRestore: false)
        slow.duringPaste = {}
        await slow.dictate("second dictation")
        slow.expectScreenshot()
        #expect(slow.logs.contains { $0.contains("original=reused") })
    }

    @Test("different text, or more than one item, is a real new copy and is left alone")
    func differentContentIsNotOurs() async {
        copyScreenshot()
        duringPaste = { [unowned self] in copyText("words, and then some") }
        await dictate("words")
        #expect(pasteboard.string(forType: .string) == "words, and then some")
        #expect(logs.last?.hasSuffix("restore=skipped-clipboard-changed") == true)

        copyScreenshot()
        duringPaste = { [unowned self] in
            let a = NSPasteboardItem(), b = NSPasteboardItem()
            a.setString("words", forType: .string)
            b.setString("another", forType: .string)
            pasteboard.clearContents()
            pasteboard.writeObjects([a, b])
        }
        await dictate("words")
        #expect(pasteboard.pasteboardItems?.count == 2)
        #expect(logs.last?.hasSuffix("restore=skipped-clipboard-changed") == true)
    }

    @Test("keep ON: the dictation stays and the log says so")
    func keepOnLogsKept() async {
        copyScreenshot()
        paster.keepsPastedText = true
        await dictate("words")
        #expect(pasteboard.string(forType: .string) == "words")
        #expect(logs.last?.hasSuffix("restore=kept-by-setting") == true)
    }

    // MARK: the log line

    @Test("one line per paste: fixed words and numbers, counts and bytes saved, never any text")
    func logLineFormat() async {
        copyScreenshot()
        await dictate("secret dictation words")
        await dictate("another secret dictation", waitForRestore: false)
        await dictate("third secret dictation")

        #expect(logs.count == 3)
        let saved = "items=1 types=2 bytes=\(Self.png.count + Self.tiff.count) dropped=0"
        #expect(logs[0] == "paste original=snapshotted \(saved) restore=restored")
        #expect(logs[1] == "paste original=snapshotted \(saved) restore=handed-to-next-paste")
        #expect(logs[2] == "paste original=reused \(saved) restore=restored")
        #expect(logs.allSatisfy { !$0.contains("secret") })
    }

    // MARK: the two outcomes of a dictation, through the real delivery decision

    @Test("confirmed uncertain paste restores the earlier clipboard after the landing probe")
    func confirmedUnknownRestores() async {
        copyScreenshot()
        var count = 2
        duringPaste = { count = 5 }
        let result = await TargetedDelivery.deliver(
            text: "Vela raises the amber sail.", pressReturn: false, answer: .unknown,
            check: { .unchanged }, landing: { LandingProbe(characterCount: count, selectedLength: 0) }, paster: paster)
        await paster.waitForPendingRestore()
        #expect(result == .unknownConfirmed)
        expectScreenshot()
        #expect(logs.last?.hasSuffix("restore=restored") == true)
    }

    @Test("unconfirmed paste keeps the staged dictation with no second clipboard write")
    func unconfirmedUnknownKeepsStagedText() async {
        copyScreenshot()
        var stagedChange = -1
        duringPaste = { [unowned self] in stagedChange = pasteboard.changeCount }
        let result = await TargetedDelivery.deliver(
            text: Self.words, pressReturn: false, answer: .unknown,
            check: { .unchanged }, landing: { LandingProbe(characterCount: 2, selectedLength: 0) }, paster: paster)
        await paster.waitForPendingRestore()
        try? await Task.sleep(for: .milliseconds(120)) // well past any restore
        #expect(result == .unknownNotLanded)
        #expect(pasteboard.string(forType: .string) == Self.words)
        #expect(isOurDictation)
        #expect(pasteboard.changeCount == stagedChange, "the clipboard was written once, when the paste was staged")
        #expect(logs.last?.hasSuffix("restore=kept reason=unconfirmed") == true)
    }

    @Test("unreadable landing: the same staged item stays, written once")
    func unreadableUnknownKeepsStagedTextWrittenOnce() async {
        copyScreenshot()
        var stagedChange = -1
        duringPaste = { [unowned self] in stagedChange = pasteboard.changeCount }
        let result = await uncertain(landing: { nil })
        try? await Task.sleep(for: .milliseconds(120))
        #expect(result == .unknownUnreadable)
        #expect(pasteboard.string(forType: .string) == Self.words)
        #expect(pasteboard.changeCount == stagedChange)
    }

    @Test("confirmed paste with keep on: the dictation stays, written once, and the log says kept by the setting")
    func confirmedUnknownWithKeepOn() async {
        copyScreenshot()
        paster.keepsPastedText = true
        var count = 2
        var stagedChange = -1
        duringPaste = { [unowned self] in
            count = 5
            stagedChange = pasteboard.changeCount
        }
        let result = await uncertain(landing: { LandingProbe(characterCount: count, selectedLength: 0) })
        try? await Task.sleep(for: .milliseconds(120))
        #expect(result == .unknownConfirmed)
        #expect(pasteboard.string(forType: .string) == Self.words)
        #expect(isOurDictation)
        #expect(pasteboard.changeCount == stagedChange)
        #expect(logs.last?.hasSuffix("restore=kept-by-setting") == true)
    }

    // MARK: one paste never settles another

    @Test("a late unconfirmed settle from an earlier paste does not settle the next paste: its confirmed landing still restores")
    func lateSettleFromEarlierPasteIsIgnored() async {
        copyText("earlier clipboard")
        let first = PasteLanding(), second = PasteLanding()
        #expect(await paster.paste("first words", pressReturn: false, awaitLanding: first, hasFocus: { true }) == .pasted)
        #expect(await paster.paste("second words", pressReturn: false, awaitLanding: second, hasFocus: { true }) == .pasted)
        // The first dictation was cancelled; its landing check reports only now.
        paster.finishLanding(first, as: .unconfirmed)
        paster.finishLanding(second, as: .confirmed)
        await paster.waitForPendingRestore()
        #expect(pasteboard.string(forType: .string) == "earlier clipboard")
        #expect(!isOurDictation)
        #expect(logs.count == 2)
        #expect(logs.first?.hasSuffix("restore=handed-to-next-paste") == true)
        #expect(logs.last?.hasPrefix("paste original=reused ") == true, "the second paste carried the person's clipboard")
        #expect(logs.last?.hasSuffix("restore=restored") == true)
    }

    @Test("a late confirmed or withdrawn settle from an earlier paste does not restore over the next paste's held dictation",
          arguments: [LandingSettlement.confirmed, .withdrawn])
    func lateRestoreFromEarlierPasteIsIgnored(late: LandingSettlement) async {
        copyText("earlier clipboard")
        let first = PasteLanding(), second = PasteLanding()
        _ = await paster.paste("first words", pressReturn: false, awaitLanding: first, hasFocus: { true })
        _ = await paster.paste("second words", pressReturn: false, awaitLanding: second, hasFocus: { true })
        let stagedChange = pasteboard.changeCount
        paster.finishLanding(first, as: late)
        await paster.waitForPendingRestore()
        try? await Task.sleep(for: .milliseconds(120))
        #expect(pasteboard.string(forType: .string) == "second words", "still held for its own landing check")
        paster.finishLanding(second, as: .unconfirmed)
        #expect(pasteboard.string(forType: .string) == "second words")
        #expect(pasteboard.changeCount == stagedChange)
        #expect(logs.last?.hasSuffix("restore=kept reason=unconfirmed") == true)
    }

    @Test("settling the same paste twice does nothing the second time")
    func settlingTwiceIsANoOp() async {
        copyText("earlier clipboard")
        let landing = PasteLanding()
        _ = await paster.paste(Self.words, pressReturn: false, awaitLanding: landing, hasFocus: { true })
        paster.finishLanding(landing, as: .unconfirmed)
        paster.finishLanding(landing, as: .confirmed)
        await paster.waitForPendingRestore()
        try? await Task.sleep(for: .milliseconds(120))
        #expect(pasteboard.string(forType: .string) == Self.words)
        #expect(logs.count == 1)
    }

    // MARK: cancelled after ⌘V

    @Test("cancelled during the landing check: the earlier clipboard comes back, whatever the keep setting",
          arguments: [false, true])
    func cancelledDuringLandingRestores(keep: Bool) async {
        copyScreenshot()
        paster.keepsPastedText = keep
        let delivery = Task { @MainActor [paster] in
            var reads = 0
            return await TargetedDelivery.deliver(
                text: Self.words, pressReturn: false, answer: .unknown, check: { .unchanged },
                landing: {
                    reads += 1
                    if reads == 2 { withUnsafeCurrentTask { $0?.cancel() } } // Esc, mid-check
                    return LandingProbe(characterCount: 2, selectedLength: 0)
                }, paster: paster!)
        }
        let result = await delivery.value
        await paster.waitForPendingRestore()
        #expect(result == .unknownCancelled)
        expectScreenshot()
        #expect(logs.last?.hasSuffix("restore=restored") == true)
    }

    @Test("a password field focused when the landing fails: the dictation does not stay, even with keep on")
    func secureFieldAfterFailedLandingRestores() async {
        copyScreenshot()
        paster.keepsPastedText = true
        var pasted = false
        duringPaste = { pasted = true }
        let result = await TargetedDelivery.deliver(
            text: Self.words, pressReturn: false, answer: .unknown,
            check: { pasted ? .secureField(change: .field) : .unchanged },
            landing: { LandingProbe(characterCount: 2, selectedLength: 0) }, paster: paster)
        await paster.waitForPendingRestore()
        #expect(result == .heldForSecureField(.field))
        expectScreenshot()
    }

    // MARK: what interrupts an uncertain paste

    @Test("⌘V refused while a landing was awaited: not pasted, the dictation is copied for ⌘V and no hold is left behind")
    func pasteKeyRefusedWhileAwaitingLanding() async {
        var refusedLogs: [String] = []
        let refusing = ClipboardPaster(pasteboard: pasteboard, postKey: { _, _ in false },
                                       restoreDelay: .milliseconds(20), returnDelay: .milliseconds(1))
        refusing.onLog = { refusedLogs.append($0) }
        copyScreenshot()
        var landingReads = 0
        let result = await TargetedDelivery.deliver(
            text: Self.words, pressReturn: false, answer: .unknown, check: { .unchanged },
            landing: { landingReads += 1; return LandingProbe(characterCount: 2, selectedLength: 0) }, paster: refusing)
        await refusing.waitForPendingRestore()
        try? await Task.sleep(for: .milliseconds(120))
        #expect(result == .dispatchFailed(copied: true))
        #expect(landingReads == 1, "nothing was sent, so nothing is checked")
        #expect(pasteboard.string(forType: .string) == Self.words)
        #expect(isOurDictation, "Hushy's own copy is marked for clipboard managers to skip")
        #expect(refusedLogs.last?.hasSuffix("restore=replaced-by-copy") == true)
    }

    @Test("⌘V refused at the paster: the hold ends at once, the earlier clipboard comes back, and a late settle does nothing")
    func refusedPasteReleasesItsHold() async {
        var refusedLogs: [String] = []
        let refusing = ClipboardPaster(pasteboard: pasteboard, postKey: { _, _ in false },
                                       restoreDelay: .milliseconds(20), returnDelay: .milliseconds(1))
        refusing.onLog = { refusedLogs.append($0) }
        copyScreenshot()
        let landing = PasteLanding()
        let outcome = await refusing.paste(Self.words, pressReturn: false, awaitLanding: landing, hasFocus: { true })
        await refusing.waitForPendingRestore()
        #expect(outcome == .dispatchFailed)
        expectScreenshot()
        let restoredChange = pasteboard.changeCount
        refusing.finishLanding(landing, as: .unconfirmed)
        refusing.finishLanding(landing, as: .confirmed)
        await refusing.waitForPendingRestore()
        expectScreenshot()
        #expect(pasteboard.changeCount == restoredChange)
        #expect(refusedLogs.count == 1)
        #expect(refusedLogs.last?.hasSuffix("restore=restored") == true)
    }

    @Test("focus moves after the dictation is staged: ⌘V is never sent and the dictation is copied for ⌘V")
    func focusChangesAfterStaging() async {
        copyScreenshot()
        var pasteKeySent = false
        duringPaste = { pasteKeySent = true }
        let result = await TargetedDelivery.deliver(
            text: Self.words, pressReturn: false, answer: .unknown,
            // Focus is on the key-down field until the dictation is on the clipboard, then elsewhere.
            check: { [unowned self] in pasteboard.string(forType: .string) == Self.words ? .changed(.app) : .unchanged },
            landing: { LandingProbe(characterCount: 2, selectedLength: 0) }, paster: paster)
        await paster.waitForPendingRestore()
        try? await Task.sleep(for: .milliseconds(120))
        #expect(result == .copied(.app))
        #expect(!pasteKeySent)
        #expect(pasteboard.string(forType: .string) == Self.words)
        #expect(isOurDictation)
        #expect(logs.last?.hasSuffix("restore=replaced-by-copy") == true)
    }

    @Test("the person copies something else during the landing check: their copy stays, unconfirmed or confirmed",
          arguments: [false, true])
    func personsCopyDuringLandingWins(confirmed: Bool) async {
        copyText("earlier clipboard")
        var reads = 0
        let result = await uncertain(landing: { [unowned self] in
            reads += 1
            guard reads >= 2 else { return LandingProbe(characterCount: 2, selectedLength: 0) }
            if reads == 2 { copyText("the person's own copy") }
            return LandingProbe(characterCount: confirmed && reads >= 3 ? 9 : 2, selectedLength: 0)
        })
        try? await Task.sleep(for: .milliseconds(120))
        #expect(result == (confirmed ? .unknownConfirmed : .unknownNotLanded))
        #expect(pasteboard.string(forType: .string) == "the person's own copy")
        #expect(!isOurDictation)
        #expect(logs.last?.hasSuffix("restore=skipped-clipboard-changed") == true)

        // And it is what the next paste saves and restores, not the older clipboard or a dictation.
        await dictate("more words")
        #expect(pasteboard.string(forType: .string) == "the person's own copy")
    }

    private static let words = "Vela raises the amber sail."

    private func uncertain(landing: @escaping () -> LandingProbe?) async -> DeliveryResult {
        let result = await TargetedDelivery.deliver(
            text: Self.words, pressReturn: false, answer: .unknown, check: { .unchanged }, landing: landing, paster: paster)
        await paster.waitForPendingRestore()
        return result
    }

    @Test("unknown answer beside a password field stages nothing")
    func unknownSecureFieldDoesNotStage() async {
        copyScreenshot()
        let result = await TargetedDelivery.deliver(
            text: "Vela raises the amber sail.", pressReturn: false, answer: .unknown,
            check: { .secureField(change: .field) }, landing: { nil }, paster: paster)
        #expect(result == .heldForSecureField(.field))
        expectScreenshot()
        #expect(logs.isEmpty)
    }

    private func deliver(_ text: String, check: @escaping () -> TargetVerdict = { .unchanged },
                         hasTextInput: Bool = true,
                         noFieldClipboard: NoFieldClipboardPolicy = .current) async -> DeliveryResult {
        let result = await TargetedDelivery.deliver(
            text: text, pressReturn: false, hasTextInput: hasTextInput, check: check,
            noFieldClipboard: noFieldClipboard, paster: paster)
        await paster.waitForPendingRestore()
        return result
    }

    @Test("pasted into a text box: the screenshot is back, no dictation anywhere on the clipboard")
    func pastedLeavesTheScreenshot() async {
        copyScreenshot()
        #expect(await deliver("pasted words") == .pasted)
        expectScreenshot()
        #expect(!(pasteboard.pasteboardItems ?? []).contains { $0.string(forType: .string) == "pasted words" })
    }

    @Test("⌘V could not be posted: not pasted, so the dictation is on the clipboard and stays there")
    func failedPasteLeavesDictation() async {
        let failing = ClipboardPaster(pasteboard: pasteboard, postKey: { _, _ in false },
                                      restoreDelay: .milliseconds(20), returnDelay: .milliseconds(1))
        copyScreenshot()
        let result = await TargetedDelivery.deliver(
            text: "unpasted words", pressReturn: false, hasTextInput: true, check: { .unchanged }, paster: failing)
        await failing.waitForPendingRestore()
        try? await Task.sleep(for: .milliseconds(120)) // well past any restore
        #expect(result == .dispatchFailed(copied: true))
        #expect(pasteboard.string(forType: .string) == "unpasted words")
    }

    @Test("focus moved before ⌘V: not pasted, the dictation is on the clipboard and stays there")
    func movedFocusLeavesDictation() async {
        copyScreenshot()
        let result = await deliver("unpasted words", check: { .changed(.field) })
        try? await Task.sleep(for: .milliseconds(120))
        #expect(result == .copied(.field))
        #expect(pasteboard.string(forType: .string) == "unpasted words")
    }

    @Test("an earlier paste's pending restore never removes a later not-pasted dictation")
    func pendingRestoreDoesNotEraseUnpastedDictation() async {
        copyScreenshot()
        await dictate("pasted words", waitForRestore: false)
        let result = await deliver("unpasted words", check: { .changed(.app) })
        try? await Task.sleep(for: .milliseconds(120))
        #expect(result == .copied(.app))
        #expect(pasteboard.string(forType: .string) == "unpasted words")
    }

    @Test("no text box (the shipped policy): the dictation is on the clipboard and stays")
    func noFieldCopyAutomaticallyKeepsDictation() async {
        copyScreenshot()
        let result = await deliver("unpasted words", hasTextInput: false)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(result == .noField(copied: true))
        #expect(pasteboard.string(forType: .string) == "unpasted words")
    }
}
