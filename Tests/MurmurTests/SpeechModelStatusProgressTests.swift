import FluidAudio
import Foundation
import MurmurCore
import Testing
@testable import Murmur

@Suite("Speech model status: honest progress")
@MainActor
struct SpeechModelStatusProgressTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// FluidAudio's download phase runs 0 → 0.5 of `fractionCompleted`.
    private func tick(_ status: SpeechModelStatus, bytesFraction: Double, at second: Double) {
        status.report(DownloadProgress(fractionCompleted: bytesFraction * 0.5, phase: .downloading(completedFiles: 1, totalFiles: 20)),
                      now: t0.addingTimeInterval(second))
    }

    @Test("bytes never go backwards, and the ETA appears only after warm-up, then counts down smoothly")
    func monotonicAndSmooth() {
        let status = SpeechModelStatus()
        status.beginLoad(cached: false, expectedBytes: 632_000_000, now: t0)
        var shown: [Int64] = []
        for second in 0...20 {
            // A steady 6.32 MB/s, with one out-of-order (lower) report mid-way.
            let fraction = second == 10 ? 0.05 : Double(second) * 0.01
            tick(status, bytesFraction: fraction, at: Double(second))
            shown.append(status.download?.estimatedBytes ?? -1)
        }
        #expect(zip(shown, shown.dropFirst()).allSatisfy { $0 <= $1 })
        let eta = status.download?.estimatedSecondsRemaining ?? 0
        #expect(abs(eta - 80) < 8)  // 80% left at 1%/s
        tick(status, bytesFraction: 0.21, at: 21)
        #expect((status.download?.estimatedSecondsRemaining ?? 0) < eta)
    }

    @Test("a stall lengthens the ETA gradually instead of freezing or jumping")
    func stall() {
        let status = SpeechModelStatus()
        status.beginLoad(cached: false, expectedBytes: 632_000_000, now: t0)
        for second in 0...10 { tick(status, bytesFraction: Double(second) * 0.01, at: Double(second)) }
        let before = status.download?.estimatedSecondsRemaining ?? 0
        status.tick(now: t0.addingTimeInterval(11))
        let oneSecondLater = status.download?.estimatedSecondsRemaining ?? 0
        #expect(oneSecondLater < before * 1.3)
        for second in 12...40 { status.tick(now: t0.addingTimeInterval(Double(second))) }
        #expect((status.download?.estimatedSecondsRemaining ?? 0) > before)
    }

    @Test("pausing keeps the bytes and drops the ETA")
    func pause() {
        let status = SpeechModelStatus()
        status.beginLoad(cached: false, expectedBytes: 632_000_000, now: t0)
        for second in 0...5 { tick(status, bytesFraction: Double(second) * 0.02, at: Double(second)) }
        status.markPaused()
        #expect(status.state == .paused)
        #expect(status.download?.estimatedBytes == 63_200_000)
        #expect(status.download?.estimatedSecondsRemaining == nil)
        #expect(status.downloadStartedAt == t0)
    }
}
