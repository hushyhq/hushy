import Foundation
import MurmurCore
import SwiftUI
import Testing
@testable import Murmur

@Suite("Pill live words")
@MainActor
struct PillLiveWordsTests {
    private let long = "Please send the revised lighthouse proposal to Mara before the ferry leaves tomorrow"

    private func listening(_ variant: PillLiveVariant = .waveAndWords) -> PillModel {
        let pill = PillModel()
        pill.liveVariant = variant
        pill.liveWordsAllowed = true
        pill.state = .listening
        return pill
    }

    @Test func visibleKeepsTheNewestWordsWhole() {
        #expect(PillLiveWords.visible("Please send this", width: 300) == "Please send this")
        let fitted = PillLiveWords.visible(long, width: PillLiveWords.textWidth(.waveAndWords))
        #expect(fitted.hasPrefix("…"))
        #expect(fitted.hasSuffix("leaves tomorrow"))
        let words = fitted.dropFirst().split(separator: " ")
        #expect((4...7).contains(words.count))
        #expect(long.hasSuffix(String(fitted.dropFirst())))
        #expect(PillLiveWords.visible("Supercalifragilistic", width: 10) == "Supercalifragilistic")
    }

    @Test func textRoomIsFixedPerVariant() {
        #expect(PillLiveWords.textWidth(.wordsOnly) > PillLiveWords.textWidth(.waveAndWords))
        #expect(PillLiveWords.capsule.width > PillMetrics.listening.width)
        #expect(PillLiveWords.capsule.height == PillMetrics.listening.height)
    }

    @Test func noWordsWithoutADraftOrOnTheSidePill() {
        let pill = PillModel()
        pill.state = .listening
        pill.noteHeard("words without a live draft")
        #expect(pill.liveWords(vertical: false) == nil)
        let allowed = listening()
        #expect(allowed.liveWords(vertical: false) == nil)
        allowed.noteHeard("Please send")
        #expect(allowed.liveWords(vertical: false) == "Please send")
        #expect(allowed.liveWords(vertical: true) == nil)
    }

    @Test func draftsReplaceAndTheWidthStays() {
        let pill = listening()
        pill.noteHeard("Send it to Mara")
        pill.noteHeard("   ")
        #expect(pill.live.heard == "Send it to Mara")
        pill.noteHeard("Send it tomorrow")
        #expect(pill.live.heard == "Send it tomorrow")
        #expect(pill.live.isWide)
        pill.noteHeard(long + " " + long)
        #expect(pill.live.heard?.split(separator: " ").count == PillLiveState.keptWords)
    }

    @Test func writingCarriesTheWordsThenPrefersWhatWasWritten() {
        let pill = listening()
        pill.noteHeard("Please send the proposal")
        pill.state = .processing()
        #expect(pill.liveWords(vertical: false) == "Please send the proposal")
        pill.advance(to: .polishing, ink: "Please send the revised proposal to Mara")
        #expect(pill.liveWords(vertical: false) == "Please send the revised proposal to Mara")
        pill.noteCleanupProgress(.init(groupsDone: 1, groupCount: 2, wordsDone: 4, wordCount: 8,
                                       latestText: "Send Mara the proposal."), revision: pill.stateRevision)
        #expect(pill.liveWords(vertical: false) == "Send Mara the proposal.")
        pill.advance(to: .typing, ink: "Send Mara the revised proposal.")
        #expect(pill.liveWords(vertical: false) == "Send Mara the revised proposal.")
    }

    @Test func aShortDictationKeepsTheUsualWait() {
        let pill = listening()
        pill.state = .processing()
        pill.advance(to: .polishing, ink: "Hi there")
        #expect(pill.liveWords(vertical: false) == nil)
    }

    @Test func cancelErrorAndPasteDropEveryWord() {
        for end in [PillState.idle, .error("oops"), .done(words: 3), .listening] {
            let pill = listening()
            pill.noteHeard("private spoken words")
            pill.state = .processing()
            let revision = pill.stateRevision
            pill.noteCleanupProgress(.init(groupsDone: 1, groupCount: 2, wordsDone: 2,
                                           wordCount: 4, latestText: "written words"), revision: revision)
            pill.state = end
            #expect(pill.live == PillLiveState())
            #expect(pill.live.settled == nil)
            pill.noteCleanupProgress(.init(groupsDone: 2, groupCount: 2, wordsDone: 4,
                                           wordCount: 4, latestText: "late answer"), revision: revision)
            #expect(pill.live.settled == nil)
            pill.state = .idle
            pill.noteHeard("late words")
            #expect(pill.liveWords(vertical: false) == nil)
            #expect(pill.live == PillLiveState())
        }
    }

    @Test func aNewDictationStartsBare() {
        let pill = listening()
        pill.noteHeard("first dictation")
        pill.state = .processing()
        pill.state = .done(words: 2)
        pill.liveWordsAllowed = true
        pill.state = .listening
        #expect(pill.liveWords(vertical: false) == nil)
        #expect(!pill.live.isWide)
    }

    @Test func mainActorUpdateCost() {
        let pill = listening()
        let clock = ContinuousClock()
        let took = clock.measure {
            for index in 0..<1_000 {
                pill.noteHeard("The ferry leaves tomorrow morning \(index)")
                _ = PillLiveWords.visible(pill.liveWords(vertical: false) ?? "", width: 167)
            }
        }
        print("pill live words: 1000 updates with fitting took \(took)")
        #expect(took < .seconds(1))
    }

    @Test func renderComparisonFrames() async {
        guard let root = ProcessInfo.processInfo.environment["PILL_LIVE_RENDER_DIR"] else { return }
        let directory = URL(fileURLWithPath: root, isDirectory: true)
        await Snapshots.renderPillLive(scheme: .light, directory: directory)
        await Snapshots.renderPillLive(scheme: .dark, directory: directory)
        let expected = Snapshots.pillLiveStates.count * PillLiveVariant.allCases.count * 2
        #expect((try? FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("pill-live"), includingPropertiesForKeys: nil).count) == expected)
    }
}
