import Foundation
import Testing
@testable import MurmurCore

@Suite("Capture timing: the lost start of a recording, split into its parts")
struct CaptureTimingTests {
    @Test("each step is kept the first time it happens")
    func stepsAreKeptOnce() {
        var timing = CaptureTiming()
        timing.mark(.engineStarted, at: .milliseconds(96))
        timing.mark(.engineStarted, at: .milliseconds(900))
        #expect(timing.engineStarted == .milliseconds(96), "a restart later in the capture does not move it")
    }

    @Test("the line says every part in milliseconds, and a dash for a step that never happened")
    func lineSaysEveryPart() {
        var timing = CaptureTiming()
        timing.mark(.graphReady, at: .milliseconds(31))
        timing.mark(.engineStarted, at: .microseconds(96_400))
        timing.mark(.firstBuffer, at: .milliseconds(214))
        #expect(timing.logLine == "capture timing: graph ready 31 ms · engine started 96 ms · first buffer 214 ms · first sound -")
        timing.mark(.firstSound, at: .milliseconds(1_312))
        #expect(timing.logLine.hasSuffix("first sound 1312 ms"))
        #expect(timing.silenceDelivered == .milliseconds(1_098))
    }

    @Test("the silence a device delivered is unknown until it has delivered a sound")
    func silenceUnknownWithoutSound() {
        #expect(CaptureTiming(firstBuffer: .milliseconds(200)).silenceDelivered == nil)
    }
}
