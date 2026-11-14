import Foundation
import Testing
@testable import MurmurCore

@Suite("Audio read fault: samples no microphone could have heard")
struct AudioReadFaultTests {
    @Test("speech, silence, and a clipped shout are sound")
    func ordinaryRecordings() {
        #expect(AudioReadFault.find(in: []) == nil)
        #expect(AudioReadFault.find(in: [Float](repeating: 0, count: 1_000)) == nil)
        #expect(AudioReadFault.find(in: (0..<16_000).map { 0.2 * sin(Float($0) / 10) }) == nil)
        #expect(AudioReadFault.find(in: [0.3, -1, 1, 0.9]) == nil, "full scale is a clipped shout, not a fault")
        #expect(AudioReadFault.find(in: [0.3, 1.4, -1.9]) == nil, "a float device may pass full scale a little")
    }

    @Test("a burst far above full scale is a faulty read, with its numbers", arguments: [Float(3.8409), 11.7033, -11.7033])
    func burstAboveFullScale(_ burst: Float) throws {
        var samples = [Float](repeating: 0.01, count: 1_000)
        samples[400] = burst
        samples[401] = 1.5
        let fault = try #require(AudioReadFault.find(in: samples))
        #expect(fault.peak == abs(burst))
        #expect(fault.overFullScale == 2)
        #expect(fault.nonFinite == 0)
        #expect(fault.samples == 1_000)
    }

    @Test("a value that is not a number is a faulty read, however small the rest", arguments: [Float.nan, .infinity, -.infinity])
    func notANumber(_ value: Float) throws {
        let fault = try #require(AudioReadFault.find(in: [0.01, value, 0.02]))
        #expect(fault.nonFinite == 1)
        #expect(fault.peak == 0.02, "the peak is of the samples that are numbers")
    }

    @Test("the log line is numbers only")
    func logLine() throws {
        var samples = [Float](repeating: 0, count: 100)
        samples[3] = 11.7033
        #expect(try #require(AudioReadFault.find(in: samples)).logSummary == "peak 11.7033 · over full scale 1 of 100 · not numbers 0")
    }
}
