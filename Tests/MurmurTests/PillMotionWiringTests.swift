import Foundation
import MurmurCore
import SwiftUI
import Testing
@testable import Murmur

/// The pill's motion as it is wired: what the model remembers for the views, what the dictation
/// path tells it, and that no view keeps motion values of its own.
@Suite("Pill — motion as wired")
@MainActor
struct PillMotionWiringTests {
    private func report(_ done: Int, of count: Int) -> CleanupProgress {
        CleanupProgress(groupsDone: done, groupCount: count, wordsDone: done * 10, wordCount: count * 10)
    }

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The code lines (no comments) of every Swift file in the pill's folder, by file name.
    private func pillSources() throws -> [String: [String]] {
        let folder = Self.root.appendingPathComponent("Sources/Murmur/Pill")
        let files = try FileManager.default.subpathsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".swift") }.map { folder.appendingPathComponent($0) }
        #expect(files.count > 20)
        var sources: [String: [String]] = [:]
        for file in files {
            sources[file.lastPathComponent] = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") }
        }
        return sources
    }

    // MARK: One place for values

    @Test("no pill view keeps a duration, curve or spring of its own: they are all in PillMotion")
    func noRawValues() throws {
        let raw = [
            ".spring(", ".easeOut(", ".easeIn(", ".easeInOut(", ".linear(", "timingCurve", ".interactiveSpring(", ".bouncy",
            ".smooth(", "Theme.snappy", "Theme.settle", "Theme.fade", "Theme.spatial(", "Theme.Motion.",
        ]
        for (file, lines) in try pillSources() where file != "PillMotion.swift" {
            for line in lines {
                for value in raw where line.contains(value) {
                    // The confirm rows are shared with the Assistant window, which moves with the windows' values.
                    if file == "ActionConfirmationCard.swift", value == "Theme.Motion." { continue }
                    Issue.record("\(file) has a motion value of its own: \(line)")
                }
            }
        }
    }

    @Test("everything that slides or scales in holds still under Reduce Motion")
    func transitionsRespectReduceMotion() throws {
        var seen = 0
        for (file, lines) in try pillSources() {
            for line in lines where line.contains(".transition(") {
                seen += 1
                let isStill = line.contains(".transition(.opacity)") || line.contains(".transition(opening)")
                #expect(isStill || line.contains("reduceMotion"), "\(file): \(line)")
            }
        }
        #expect(seen >= 10, "the scan is looking at the right files")
    }

    @Test("only the pill's root and its drop targets read the Mac's Reduce Motion setting; the rest follow the pill")
    func oneReduceMotionSwitch() throws {
        let readers = try pillSources().filter { $0.value.contains { $0.contains("accessibilityReduceMotion") } }.keys.sorted()
        #expect(readers == ["PillDropTargets.swift", "PillMotion.swift", "PillView.swift"])
    }

    // MARK: The role of a change

    @Test("the model names each change of state for the views: open, morph, close, rise, fall")
    func changeRoles() {
        let pill = PillModel()
        pill.state = .listening
        #expect(pill.changeRole == .open)
        pill.state = .processing()
        #expect(pill.changeRole == .morph)
        pill.state = .done(words: 6)
        #expect(pill.changeRole == .morph)
        pill.state = .idle
        #expect(pill.changeRole == .close)
        pill.present(.pastedUnchecked, text: "Lunch on Thursday works for me.")
        #expect(pill.changeRole == .open, "the quiet Pasted row arrives like any other end state")
        pill.showUncheckedWords()
        #expect(pill.changeRole == .rise, "its card rises from it")
        pill.state = .idle
        #expect(pill.changeRole == .fall)
    }

    @Test("the quiet Pasted row follows the wait exactly as the confirmed tick does")
    func uncheckedRowMovesLikeDone() {
        #expect(PillMotion.role(from: .processing(), to: .pastedUnchecked) == PillMotion.role(from: .processing(), to: .done(words: 6)))
        #expect(PillMotion.role(from: .pastedUnchecked, to: .idle) == PillMotion.role(from: .done(words: 6), to: .idle))
        #expect(!PillState.pastedUnchecked.opensCard)
    }

    @Test("the missing-list question moves as every other one-row action does, and the preview shows it")
    func missingListQuestionMovesLikeOtherActionRows() throws {
        let question = PillPreviewScript.missingListQuestion
        #expect(question.waitsOnOffer && question.soleProblemRow?.offer != nil, "the preview's card really is the question")
        let asked = PillState.actionConfirm(question)
        let ordinary = PillState.actionConfirm(ActionConfirmationCardState(actions: [question.rows[0].action]))
        #expect(!asked.opensCard, "one row: it is the capsule itself, not a card on it")
        for other in [PillState.actionProcessing, .idle, .actionListening] {
            #expect(PillMotion.role(from: other, to: asked) == PillMotion.role(from: other, to: ordinary))
            #expect(PillMotion.role(from: asked, to: other) == PillMotion.role(from: ordinary, to: other))
        }
        #expect(PillMotion.role(from: .actionProcessing, to: asked) == .morph)
        #expect(PillMotion.role(from: asked, to: .idle) == .close)
        #expect(PillPreviewScript.steps(for: .voiceActionCards).contains { step in
            if case .actionConfirm(let card) = step.state { card.waitsOnOffer } else { false }
        })
        // Its row has no motion of its own: the buttons are the pill's, on the pill's values.
        let row = try #require(try pillSources()["ActionPill.swift"])
        #expect(!row.contains { $0.contains("withAnimation") || $0.contains(".animation(") || $0.contains(".transition(") })
    }

    // MARK: Grey until heard

    @Test("a dictation's bars are grey from the moment the microphone is asked for until its first level")
    func greyUntilHeard() {
        let pill = PillModel()
        #expect(!pill.awaitsFirstAudio, "nothing is waiting at rest")
        pill.resetLevels()
        pill.awaitFirstAudio()
        pill.state = .listening
        #expect(pill.awaitsFirstAudio)
        pill.push(rms: 0.000_1)
        #expect(!pill.awaitsFirstAudio, "any level counts, however quiet: the microphone is open")
        pill.resetLevels()
        #expect(!pill.awaitsFirstAudio, "a reset alone never greys the bars: only a dictation asks")
    }

    @Test("a dictation that never got its microphone leaves nothing grey behind for the next pill")
    func greyDoesNotOutliveItsDictation() {
        let pill = PillModel()
        pill.resetLevels()
        pill.awaitFirstAudio()
        pill.present(failure: .didNotStart(PillModel.microphoneFailedMessage))
        #expect(!pill.awaitsFirstAudio)
        pill.state = .listening // the practice pill, which opens no microphone
        #expect(!pill.awaitsFirstAudio)
    }

    @Test("pills that never ask stay as they were: a note, a voice action, the practice pill, a still image")
    func othersStayLime() {
        let pill = PillModel()
        pill.resetLevels()
        pill.state = .listening
        #expect(!pill.awaitsFirstAudio)
        pill.awaitFirstAudio()
        pill.setLevels([0.3, 0.5, 0.8, 0.4, 1.0, 0.6, 0.9, 0.35, 0.55])
        #expect(!pill.awaitsFirstAudio)
    }

    // MARK: Gliding levels

    @Test("each new set of levels remembers the one before it, so the bars can glide")
    func previousLevels() async throws {
        let pill = PillModel()
        pill.resetLevels()
        #expect(pill.previousLevels.isEmpty && pill.levelsUpdatedAt == nil)
        pill.push(rms: 0.05)
        let first = pill.levels
        #expect(pill.previousLevels == Array(repeating: 0, count: PillModel.barCount))
        try await Task.sleep(for: .milliseconds(40))
        pill.push(rms: 0.05)
        #expect(pill.previousLevels == first)
        #expect(pill.levelsUpdatedAt != nil)
        pill.setLevels(first)
        #expect(pill.previousLevels.isEmpty, "levels set directly are drawn as they are")
    }

    // MARK: The fold and the progress line

    @Test("the dots fold out of a dictation's bars, and are simply there after anything else")
    func foldLevels() {
        let pill = PillModel()
        let bars = [0.3, 0.5, 0.8, 0.4, 1.0, 0.6, 0.9, 0.35, 0.55]
        pill.state = .listening
        pill.setLevels(bars)
        pill.state = .processing()
        #expect(pill.foldLevels == bars)
        pill.state = .idle
        pill.state = .recordingNote(startedAt: Date())
        pill.state = .processing()
        #expect(pill.foldLevels.isEmpty, "a note's small bars are not the ones the fold draws")
        pill.state = .failed(.transcription(recordingKept: true))
        pill.state = .processing()
        #expect(pill.foldLevels.isEmpty, "Try again starts from a row, not from bars")
    }

    @Test("progress belongs to one wait: it starts empty, only grows, and is gone when the wait is")
    func progressBelongsToOneWait() throws {
        let pill = PillModel()
        pill.state = .processing()
        let wait = pill.stateRevision
        #expect(pill.waitProgress == nil)
        pill.noteCleanupProgress(report(0, of: 4), revision: wait)
        #expect(pill.waitProgress?.fill == 0)
        pill.noteCleanupProgress(report(2, of: 4), revision: wait)
        let half = try #require(pill.waitProgress?.fill)
        #expect(abs(half - 0.5 * (1 - PillWaitProgress.deliveryShare)) < 1e-9)
        pill.noteCleanupProgress(report(1, of: 4), revision: wait)
        #expect(pill.waitProgress?.fill == half, "a late report never moves the line back")
        pill.noteCleanupProgress(report(4, of: 4), revision: wait)
        #expect(try #require(pill.waitProgress?.fill) < 1, "full only when the paste has gone out, and then the tick replaces the line")
        pill.state = .done(words: 40)
        #expect(pill.waitProgress == nil)
        pill.noteCleanupProgress(report(4, of: 4), revision: wait)
        #expect(pill.waitProgress == nil, "a report for a wait that is over is dropped")
    }

    @Test("a report for an earlier wait never touches the next one, and one sentence shows no line")
    func progressIsNotCarriedOver() {
        let pill = PillModel()
        pill.state = .processing()
        let earlier = pill.stateRevision
        pill.state = .idle
        pill.state = .processing()
        pill.noteCleanupProgress(report(3, of: 4), revision: earlier)
        #expect(pill.waitProgress == nil)
        pill.noteCleanupProgress(report(1, of: 1), revision: pill.stateRevision)
        #expect(pill.waitProgress == nil, "no groups to count: no honest fraction, no line")
    }

    // MARK: Nothing added between release and paste

    @Test("the cleanup listener returns before the pill hears anything: cleanup never waits on the pill")
    func listenerDoesNotRunInline() async {
        let pill = PillModel()
        pill.state = .processing()
        let listener = DictationController.progressObserver(for: pill)
        listener(report(1, of: 3))
        #expect(pill.waitProgress == nil, "the update is only scheduled; the caller has already moved on")
        for _ in 0..<200 where pill.waitProgress == nil { await Task.yield() }
        #expect(pill.waitProgress != nil)
    }

    @Test("a thousand reports cost the cleaner well under a tenth of a millisecond each; a dictation sends one per sentence group")
    func listenerIsCheap() async {
        let pill = PillModel()
        pill.state = .processing()
        let listener = DictationController.progressObserver(for: pill)
        let reports = (0..<1_000).map { report($0 % 5, of: 5) }
        let spent = await Task.detached { ContinuousClock().measure { for item in reports { listener(item) } } }.value
        #expect(spent < .milliseconds(100), "took \(spent)")
    }

    @Test("a listener made for one wait says nothing to the pill once that wait is over")
    func listenerDropsLateReports() async {
        let pill = PillModel()
        pill.state = .processing()
        let listener = DictationController.progressObserver(for: pill)
        pill.state = .done(words: 12)
        pill.state = .idle
        pill.state = .processing()
        listener(report(2, of: 3))
        for _ in 0..<50 { await Task.yield() }
        #expect(pill.waitProgress == nil)
    }

    @Test("a tick is drawn only by the rows of a finished delivery; the wait's own views cannot draw one")
    func tickOnlyWhenDone() throws {
        let sources = try pillSources()
        for file in ["PillWait.swift", "PillWaitMarks.swift", "PillWriting.swift", "PillWaveform.swift"] {
            let lines = try #require(sources[file])
            #expect(!lines.contains { $0.contains("CheckmarkDraw") || $0.contains("checkmark") }, "\(file) draws a tick")
        }
        let drawers = sources.filter { $0.value.contains { $0.contains("CheckmarkDraw(") } }.keys.sorted()
        // FailureRow's tick marks a fix the person already applied (the Mac's microphone in use), also a finished thing.
        // VoiceEditRow's tick marks an edit already made in the field.
        #expect(drawers == ["AnswerCard.swift", "FailureRow.swift", "PastedUncheckedRow.swift", "PillDoneRow.swift", "VoiceEditRow.swift"])
        // And no pill view can put the pill into a tick state: only what ran the delivery can.
        let makers = sources.filter { file, lines in
            !file.hasPrefix("PillPreview") && lines.contains { $0.contains(".done(words") && !$0.contains("case .done") }
        }.keys.sorted()
        #expect(makers.isEmpty, "\(makers) set a done state from inside the pill")
    }

    @Test("a wait that ends inside the fold goes from bars to the row the delivery chose, whatever it is")
    func shortWaitEndsInWhateverTheDeliveryChose() {
        // The fold is only how the wait is drawn; it never picks the state that follows.
        let pill = PillModel()
        pill.state = .listening
        pill.setLevels(Array(repeating: 0.5, count: PillModel.barCount))
        pill.state = .processing()
        #expect(PillWait.frame(elapsed: 0.1).rhythm == .folding)
        for outcome in [PillState.done(words: 4), .copied(reason: .pasteFailed), .held(copied: false), .failed(.noWords),
                        .pastedUnchecked, .noField(.offerCopy), .idle] {
            pill.state = .processing()
            pill.present(outcome, text: "Lunch on Thursday works for me.")
            #expect(pill.state == outcome)
            #expect(pill.waitProgress == nil && pill.processingStartedAt == nil)
        }
    }

    @Test("the microphone opens off the main thread at once; the listening pill gets a frame before main-thread AX work")
    func listeningPillStartsFirst() throws {
        let source = try String(contentsOf: Self.root.appendingPathComponent("Sources/Murmur/Dictation/DictationController.swift"),
                                encoding: .utf8)
        let begin = try #require(source.range(of: "private func begin(mode: Mode, at eventTime:"))
        let opener = try #require(source.range(of: "private func openMicrophone(sessionID:"))
        let continuation = try #require(source.range(of: "private func continueBegin(mode: Mode,"))
        let open = try #require(source.range(of: "openMicrophone(sessionID: sessionID)", range: begin.upperBound..<opener.lowerBound))
        let show = try #require(source.range(of: "showListening(mode: mode", range: begin.upperBound..<opener.lowerBound))
        let listening = try #require(source.range(of: "private func showListening(mode: Mode,"))
        let awaitAudio = try #require(source.range(of: "pill.awaitFirstAudio()", range: listening.upperBound..<source.endIndex))
        let shown = try #require(source.range(of: "show(mode == .handsFree", range: listening.upperBound..<source.endIndex))
        let yieldFrame = try #require(source.range(of: "Task.sleep(for: .milliseconds(16))", range: begin.upperBound..<opener.lowerBound))
        let capture = try #require(source.range(of: "try audio.start", range: opener.upperBound..<continuation.lowerBound))
        let offMain = try #require(source.range(of: "queue.async", range: opener.upperBound..<capture.lowerBound))
        let accessibility = try #require(source.range(of: "FocusTarget.exposeAccessibility(of:", range: capture.upperBound..<continuation.lowerBound))
        let completion = try #require(source.range(of: "private func completeBegin(mode: Mode,"))
        let focusRead = try #require(source.range(of: "keyDownTarget()", range: completion.upperBound..<source.endIndex))
        #expect(awaitAudio.lowerBound < shown.lowerBound)
        #expect(open.lowerBound < show.lowerBound, "the microphone is asked for before anything else is drawn")
        #expect(show.lowerBound < yieldFrame.lowerBound)
        #expect(offMain.lowerBound < capture.lowerBound, "the capture starts on its own queue")
        #expect(capture.lowerBound < accessibility.lowerBound)
        #expect(yieldFrame.lowerBound < focusRead.lowerBound, "the focus read on the main thread waits for the frame")
    }

}
