@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os
import Testing
@testable import Murmur

/// What a device's IO proc hands over, and how it leaves the audio thread. A fake proc feeds
/// hand-built buffer lists (short, uneven, several streams); no device is opened.
@Suite("Device IO hand-off: the audio thread only copies, and every sample arrives once, in order")
struct DeviceIOHandoffTests {
    /// An `AudioBufferList` of interleaved float buffers, one per entry of `streams`.
    static func withList<T>(_ streams: [(channels: Int, samples: [Float32])], _ body: (UnsafePointer<AudioBufferList>) -> T) -> T {
        let list = AudioBufferList.allocate(maximumBuffers: max(streams.count, 1))
        list.count = streams.count
        defer {
            list.forEach { $0.mData?.deallocate() }
            free(list.unsafeMutablePointer)
        }
        for (index, stream) in streams.enumerated() {
            let bytes = stream.samples.count * MemoryLayout<Float32>.size
            let data = UnsafeMutableRawPointer.allocate(byteCount: max(bytes, 1), alignment: MemoryLayout<Float32>.alignment)
            stream.samples.withUnsafeBytes { if bytes > 0 { data.copyMemory(from: $0.baseAddress!, byteCount: bytes) } }
            list[index] = AudioBuffer(mNumberChannels: UInt32(stream.channels), mDataByteSize: UInt32(bytes), mData: data)
        }
        return body(UnsafePointer(list.unsafeMutablePointer))
    }

    static func samples(_ buffer: AVAudioPCMBuffer, channel: Int = 0) -> [Float] {
        Array(UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength)))
    }

    /// A ramp: sample n is n. Any sample lost, repeated, moved or misread shows as a break in it.
    static func ramp(from start: Int, count: Int) -> [Float32] { (start..<(start + count)).map(Float32.init) }

    // MARK: The ring

    static func ring(rate: Double = 48_000, seconds: Double = 2) -> DeviceIORing { DeviceIORing(sampleRate: rate, seconds: seconds)! }

    @Test("callbacks of uneven sizes, as a real device gives: every sample once, in order", arguments: [
        [512, 512, 512], [512, 480, 1, 1024, 37], [1, 1, 1, 1], [3, 700, 2],
    ])
    func unevenCallbacks(_ sizes: [Int]) throws {
        let ring = Self.ring()
        var next = 0
        var read: [Float] = []
        for (index, size) in sizes.enumerated() {
            #expect(Self.withList([(1, Self.ramp(from: next, count: size))]) { ring.write($0, sampleTime: Double(next)) })
            next += size
            // Read after some callbacks and not others, as a reader that runs when it can.
            if index % 2 == 1, let buffer = ring.read() { read += Self.samples(buffer) }
        }
        while let buffer = ring.read() { read += Self.samples(buffer) }
        #expect(read == Self.ramp(from: 0, count: next), "the ramp is whole")
        #expect(ring.counters.callbacks == sizes.count)
        #expect(ring.counters.frames == next)
        #expect(ring.counters.smallestCallback == sizes.min())
        #expect(ring.counters.largestCallback == sizes.max())
        #expect(ring.counters.dropped == 0)
        #expect(ring.counters.gaps == 0, "each callback followed the one before on the device's clock")
        #expect(ring.read() == nil, "nothing is handed out twice")
        #expect(ring.format.channelCount == 1)
    }

    @Test("the ring wraps around its end without tearing a callback")
    func wrapsAround() {
        let ring = Self.ring(rate: 100, seconds: 1)   // 100 frames
        var next = 0
        var read: [Float] = []
        for _ in 0..<25 {
            #expect(Self.withList([(1, Self.ramp(from: next, count: 37))]) { ring.write($0) })
            next += 37
            if let buffer = ring.read() { read += Self.samples(buffer) }
        }
        #expect(read == Self.ramp(from: 0, count: next))
        #expect(ring.counters.dropped == 0)
    }

    @Test("channel 0 of the first stream is what is kept, however the device lays its channels out")
    func channelZeroOfTheFirstStream() throws {
        let ring = Self.ring()
        // One channel; then the Mac's microphone in its three-capsule mode as three buffers;
        // then the same as one interleaved buffer; then back. The ramp runs through all of it.
        #expect(Self.withList([(1, [0, 1])]) { ring.write($0) })
        #expect(Self.withList([(1, [2, 3]), (1, [90, 91]), (1, [80, 81])]) { ring.write($0) })
        #expect(Self.withList([(3, [4, 90, 80, 5, 91, 81])]) { ring.write($0) })
        #expect(Self.withList([(2, [6, -6, 7, -7])]) { ring.write($0) })
        #expect(Self.samples(try #require(ring.read())) == Self.ramp(from: 0, count: 8))
        #expect(ring.counters.frames == 8, "frames come from each buffer's own bytes and channels: 2 each, never 6 or 1")
        #expect(ring.counters.fewestBuffers == 1)
        #expect(ring.counters.mostBuffers == 3)
        #expect(ring.counters.widestFirstBuffer == 3)
        #expect(ring.counters.misfits == 0)
    }

    @Test("a first buffer that cannot be read is refused whole and counted")
    func misfitsAreRefused() {
        let ring = Self.ring()
        #expect(!Self.withList([(1, [])]) { ring.write($0) }, "no frames")
        #expect(!Self.withList([]) { ring.write($0) }, "no buffers")
        #expect(!Self.withList([(2, [1, -1, 2])]) { ring.write($0) }, "bytes that are not whole frames: never read past the end")
        #expect(!Self.withList([(0, [1, 2])]) { ring.write($0) }, "no channels")
        #expect(ring.read() == nil)
        #expect(ring.counters.misfits == 4)
        #expect(ring.counters.frames == 0)
    }

    @Test("a reader a whole ring behind: the newest callbacks are dropped and counted, and what was kept is intact")
    func overflowDropsWholeCallbacks() throws {
        let ring = Self.ring(rate: 100, seconds: 1)   // 100 frames
        for start in stride(from: 0, to: 160, by: 40) {
            Self.withList([(1, Self.ramp(from: start, count: 40))]) { _ = ring.write($0) }
        }
        #expect(ring.counters.dropped == 80, "the third and fourth callbacks did not fit")
        #expect(Self.samples(try #require(ring.read())) == Self.ramp(from: 0, count: 80), "no torn or mixed callback")
        #expect(Self.withList([(1, Self.ramp(from: 500, count: 40))]) { ring.write($0) }, "and the ring takes audio again")
        #expect(Self.samples(try #require(ring.read())) == Self.ramp(from: 500, count: 40))
    }

    @Test("once the device's format has changed nothing more is taken: audio at the old rate is never decoded")
    func gateShutsOnAFormatChange() throws {
        let ring = Self.ring()
        #expect(Self.withList([(1, Self.ramp(from: 0, count: 512))]) { ring.write($0) })
        ring.closeGate()
        #expect(!Self.withList([(1, Self.ramp(from: 512, count: 512))]) { ring.write($0) })
        #expect(!Self.withList([(1, Self.ramp(from: 1_024, count: 512))]) { ring.write($0) })
        #expect(Self.samples(try #require(ring.read())) == Self.ramp(from: 0, count: 512), "what came before the change is kept")
        #expect(ring.read() == nil)
        #expect(ring.counters.gated == 1_024)
    }

    // MARK: The record that names a fault

    @Test("a callback that does not follow the one before on the device's clock is a gap, with its size")
    func clockGapsAreCounted() {
        let ring = Self.ring()
        Self.withList([(1, Self.ramp(from: 0, count: 512))]) { _ = ring.write($0, sampleTime: 10_000) }
        Self.withList([(1, Self.ramp(from: 512, count: 512))]) { _ = ring.write($0, sampleTime: 10_512) }
        Self.withList([(1, Self.ramp(from: 1_024, count: 512))]) { _ = ring.write($0, sampleTime: 12_048) }   // two cycles missed
        Self.withList([(1, Self.ramp(from: 1_536, count: 512))]) { _ = ring.write($0, sampleTime: 12_560) }
        #expect(ring.counters.gaps == 1)
        #expect(ring.counters.largestGap == 1_024)
    }

    @Test("a sample beyond full scale: the callback's layout, its place and its gap on the clock are kept")
    func faultRecordsWhatSeparatesTheCauses() throws {
        let ring = Self.ring()
        let quiet = [Float32](repeating: 0.04, count: 512)
        var burst = quiet
        burst[200] = -11.7033
        Self.withList([(1, quiet)]) { _ = ring.write($0, sampleTime: 0) }
        Self.withList([(1, quiet)]) { _ = ring.write($0, sampleTime: 512) }
        // The burst arrives in a callback of three buffers, one cycle late.
        Self.withList([(1, burst), (1, quiet), (1, quiet)]) { _ = ring.write($0, sampleTime: 1_536) }
        Self.withList([(1, quiet)]) { _ = ring.write($0, sampleTime: 2_048) }
        #expect(ring.counters.faulty == 1)
        let fault = try #require(ring.faults.first)
        #expect(fault.callback == 3)
        #expect(fault.frames == 512)
        #expect(fault.peak == 11.7033)
        #expect(fault.buffers == 3)
        #expect(fault.layout.map(\.channels) == [1, 1, 1])
        #expect(fault.layout.map(\.bytes) == [2_048, 2_048, 2_048])
        #expect(fault.gap == 512, "one cycle was missed before it")
        #expect(fault.logWords == "callback 3 · 512 frames · peak 11.7033 · buffers 3 [1 ch 2048 bytes, 1 ch 2048 bytes, 1 ch 2048 bytes] · gap 512 frames")
    }

    @Test("a value that is not a number is a fault too, and only the first few faults are kept")
    func notANumberAndTheLimit() throws {
        let ring = Self.ring()
        var samples = [Float32](repeating: 0.01, count: 64)
        samples[5] = .nan
        for index in 0..<7 { Self.withList([(1, samples)]) { _ = ring.write($0, sampleTime: Double(index * 64)) } }
        #expect(ring.counters.faulty == 7)
        #expect(ring.faults.count == DeviceIORing.faultsKept)
        #expect(ring.faults[0].logWords.contains("peak not a number"))
        #expect(ring.faults[0].gap == nil, "the first callback has none before it")
        #expect(ring.faults[1].gap == 0)
    }

    @Test("sound at full scale and below is no fault")
    func fullScaleIsNotAFault() {
        let ring = Self.ring()
        Self.withList([(1, [0.3, -1, 1, 0.9])]) { _ = ring.write($0) }
        #expect(ring.counters.faulty == 0)
        #expect(ring.faults.isEmpty)
    }

    @Test("only a stream of 32-bit floats in the Mac's byte order is read")
    func readableFormats() {
        var float = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        #expect(DeviceIOMicrophoneEngine.isReadable(float), "the Mac's own microphone and a Bluetooth headset, as read on this Mac")
        float.mFormatFlags |= kAudioFormatFlagIsBigEndian
        #expect(!DeviceIOMicrophoneEngine.isReadable(float))
        var integer = float
        integer.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        integer.mBitsPerChannel = 16
        #expect(!DeviceIOMicrophoneEngine.isReadable(integer))
        var unpacked = float
        unpacked.mFormatFlags = kAudioFormatFlagIsFloat
        #expect(!DeviceIOMicrophoneEngine.isReadable(unpacked))
    }

    // MARK: Off the audio thread

    /// What a reader received. `holdsFirst` keeps it stuck inside its first buffer until `gate` is signalled.
    private final class Sink: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: [Float]())
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        var holdsFirst = false
        func receive(_ buffer: AVAudioPCMBuffer) {
            if holdsFirst {
                holdsFirst = false
                entered.signal()
                gate.wait()
            }
            let samples = DeviceIOHandoffTests.samples(buffer)
            lock.withLock { $0 += samples }
        }
        var samples: [Float] { lock.withLock { $0 } }
    }

    @Test("what the audio thread hands over reaches the capture whole, through the reader's queue")
    func everythingArrives() {
        let sink = Sink()
        let queue = DispatchQueue(label: "test.device-io")
        let handoff = DeviceIOHandoff(sampleRate: 48_000, queue: queue, receive: { sink.receive($0) })!
        var next = 0
        for size in [512, 480, 512, 33] {
            Self.withList([(1, Self.ramp(from: next, count: size))]) { handoff.take($0) }
            next += size
        }
        handoff.flush()
        #expect(sink.samples == Self.ramp(from: 0, count: next))
        #expect(handoff.ring.counters.callbacks == 4)
    }

    @Test("a slow reader never holds the audio thread: callbacks keep being taken while it is stuck")
    func slowReaderDoesNotBlockTheAudioThread() {
        let sink = Sink()
        sink.holdsFirst = true
        let queue = DispatchQueue(label: "test.device-io.slow")
        let handoff = DeviceIOHandoff(sampleRate: 48_000, queue: queue, receive: { sink.receive($0) })!
        Self.withList([(1, Self.ramp(from: 0, count: 512))]) { handoff.take($0) }
        sink.entered.wait()   // the reader is now stuck inside the capture's work
        var next = 512
        // The "audio thread" delivers twenty more callbacks; each must return at once.
        for _ in 0..<20 {
            Self.withList([(1, Self.ramp(from: next, count: 512))]) { handoff.take($0) }
            next += 512
        }
        #expect(handoff.ring.counters.callbacks == 21, "every callback returned while the reader was stuck")
        #expect(sink.samples.isEmpty, "and the reader had delivered nothing yet")
        sink.gate.signal()
        handoff.flush()
        #expect(sink.samples == Self.ramp(from: 0, count: next), "nothing was lost or reordered meanwhile")
        #expect(handoff.ring.counters.dropped == 0)
    }

    @Test("flush hands over the end of a recording before it returns")
    func flushDeliversTheTail() {
        let sink = Sink()
        let handoff = DeviceIOHandoff(sampleRate: 48_000, queue: DispatchQueue(label: "test.device-io.flush"),
                                      receive: { sink.receive($0) })!
        Self.withList([(1, Self.ramp(from: 0, count: 100))]) { handoff.take($0) }
        handoff.flush()
        #expect(sink.samples.count == 100)
    }
}
