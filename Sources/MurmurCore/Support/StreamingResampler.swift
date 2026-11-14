@preconcurrency import AVFoundation

/// Converts microphone buffers (any rate / channel count) to 16 kHz mono Float, one buffer
/// at a time, keeping converter state between buffers so there are no gaps or clicks.
///
/// Shared by live capture and the eval harness, so the exact conversion path is tested.
public final class StreamingResampler: @unchecked Sendable {
    public static let targetRate: Double = 16_000

    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    /// Mono format at the input rate. Multichannel mic input (the built-in array reports
    /// 3 discrete channels, 9 with voice processing) is reduced to its first channel here:
    /// AVAudioConverter's own discrete-layout downmix outputs silence on current macOS.
    private let mono: AVAudioFormat?

    public init?(from input: AVAudioFormat) {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Self.targetRate, channels: 1, interleaved: false)
        else { return nil }
        let mono = input.channelCount > 1
            ? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: input.sampleRate, channels: 1, interleaved: false)
            : nil
        guard let converter = AVAudioConverter(from: mono ?? input, to: target) else { return nil }
        self.target = target
        self.converter = converter
        self.mono = mono
    }

    /// Converts one input buffer; returns the 16 kHz mono samples produced so far.
    ///
    /// `AVAudioConverter.convert(to:error:withInputFrom:)` only pulls a bounded amount of input
    /// per call — observed ~4096 frames for this format pairing, regardless of how large a
    /// buffer the input block hands back or how much capacity `output` has — and does *not*
    /// track "the rest of that same buffer" across separate `convert()` calls: offering the
    /// identical buffer again on a second call is treated as *new* input, not a continuation,
    /// which either drops the remainder (if the second call is told "no more data") or
    /// re-processes/duplicates it (if offered again in full). Live capture's buffers (1024
    /// frames per tap callback) never approach that ceiling, so this went unnoticed there, but a
    /// large decoded chunk (file import reads whole `CMSampleBuffer`s, often tens of thousands of
    /// frames) silently lost every frame past the first internal chunk before this fix — see
    /// `MediaDecoderTests` for the regression this addresses.
    ///
    /// The fix is to track how much of `buffer` has actually been consumed (inferred from how
    /// many output frames each call produced, scaled by the sample-rate ratio) and, on each
    /// subsequent call, hand the converter a fresh sub-buffer wrapping only the unconsumed
    /// remainder — never the same buffer twice. The persistent `converter` instance itself is
    /// still reused across separate calls to `convert(_:)` (not recreated here), preserving the
    /// resampling filter's continuity between tap callbacks that the type's doc comment promises.
    public func convert(_ input: AVAudioPCMBuffer) -> [Float] {
        guard let buffer = firstChannel(of: input) else { return [] }
        let ratio = target.sampleRate / buffer.format.sampleRate
        var result: [Float] = []
        result.reserveCapacity(Int(Double(buffer.frameLength) * ratio) + 64)

        var consumedFrames = 0
        // Bounded by how many internal chunks the converter could possibly need for this
        // buffer, plus headroom — guards against ever spinning forever if a future AVFoundation
        // behavior change stops shrinking the remainder as expected.
        let maxIterations = max(4, Int(buffer.frameLength) / 256 + 4)
        var iterations = 0
        while consumedFrames < Int(buffer.frameLength), iterations < maxIterations {
            iterations += 1
            let remainingFrames = Int(buffer.frameLength) - consumedFrames
            guard let remainder = Self.subBuffer(of: buffer, startingAtFrame: consumedFrames, frameCount: remainingFrames)
            else { break }
            let outputCapacity = AVAudioFrameCount(Double(remainingFrames) * ratio) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputCapacity) else { break }

            nonisolated(unsafe) var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return remainder
            }
            guard status != .error, error == nil else { break }
            let produced = Int(output.frameLength)
            if produced > 0, let channel = output.floatChannelData?[0] {
                result.append(contentsOf: UnsafeBufferPointer(start: channel, count: produced))
            }
            guard produced > 0 else { break }
            // The converter doesn't report how many *input* frames it consumed directly, but
            // for a fixed sample-rate ratio, produced-output-frames / ratio is exact (matches
            // AVFoundation's own resampling arithmetic) and always at least 1 when `produced` is
            // positive, so this can never fail to make forward progress.
            consumedFrames += max(1, Int(Double(produced) / ratio))
        }
        return result
    }

    /// Wraps `frameCount` frames of `buffer` starting at `startFrame` as a new (copied)
    /// `AVAudioPCMBuffer` in the same format, for `convert(_:)`'s remainder-tracking loop above.
    private static func subBuffer(of buffer: AVAudioPCMBuffer, startingAtFrame startFrame: Int, frameCount: Int) -> AVAudioPCMBuffer? {
        guard frameCount > 0, let source = buffer.floatChannelData?[0],
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(frameCount))
        else { return nil }
        copy.frameLength = AVAudioFrameCount(frameCount)
        copy.floatChannelData?[0].update(from: source + startFrame, count: frameCount)
        return copy
    }

    private func firstChannel(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let mono else { return buffer }
        guard let source = buffer.floatChannelData?[0],
              let copy = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
              let destination = copy.floatChannelData?[0] else { return nil }
        copy.frameLength = buffer.frameLength
        destination.update(from: source, count: Int(buffer.frameLength))
        return copy
    }

    /// Root-mean-square level of samples, for meters and silence detection.
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}

/// Peak/RMS/noise-floor of one audio buffer, computed the same way at every pipeline stage
/// (raw capture, post-resample, post-normalize) so logs are directly comparable across stages.
/// A pure value type: no I/O, no dependency on AVFoundation, so it is cheap to compute on the
/// hot path and trivial to unit test.
public struct AudioStageMetrics: Sendable, Equatable {
    /// Largest absolute sample value.
    public let peak: Float
    /// Root-mean-square level over the whole buffer.
    public let rms: Float
    /// RMS of the 10th-percentile-quietest 20 ms frame: an estimate of the room/mic noise
    /// floor that ignores the louder voiced frames, so it doesn't rise just because someone
    /// is speaking loudly.
    public let noiseFloor: Float
    /// Number of complete 20 ms frames the buffer contained (0 for very short buffers).
    public let frameCount: Int
    /// Fraction of total energy sitting in the 2-8 kHz band. Whispers lose voicing (low-frequency
    /// harmonic energy from vocal fold vibration) and carry their intelligible content mostly as
    /// high-frequency turbulent noise (Chang et al. 2020, wTIMIT), so this ratio is expected to
    /// run high for whispers and low for normally-voiced speech or low-frequency room/fan hum.
    /// Logged for now so voice-processing on/off can be compared later; nothing acts on it yet.
    public let highBandRatio: Float

    public init(peak: Float, rms: Float, noiseFloor: Float, frameCount: Int, highBandRatio: Float = 0) {
        self.peak = peak
        self.rms = rms
        self.noiseFloor = noiseFloor
        self.frameCount = frameCount
        self.highBandRatio = highBandRatio
    }

    /// A short line for `os.Logger`, e.g. "peak 0.081 rms 0.014 floor 0.0009 hi 0.42 (312 frames)".
    public var logSummary: String {
        String(format: "peak %.4f rms %.4f floor %.5f hi %.2f (%d frames)", peak, rms, noiseFloor, highBandRatio, frameCount)
    }
}

/// A minimal second-order (biquad) Butterworth-style high-pass filter, used only to measure
/// levels without letting sub-150 Hz hum/fan noise dominate the RMS — not applied to audio that
/// gets transcribed. Coefficients follow the standard RBJ cookbook formula.
struct BiquadHighPass {
    private let b0: Float
    private let b1: Float
    private let b2: Float
    private let a1: Float
    private let a2: Float
    private var x1: Float = 0
    private var x2: Float = 0
    private var y1: Float = 0
    private var y2: Float = 0

    init(cutoffHz: Float, sampleRate: Float, q: Float = 0.7071) {
        let omega = 2 * Float.pi * cutoffHz / sampleRate
        let alpha = sin(omega) / (2 * q)
        let cosOmega = cos(omega)
        let a0 = 1 + alpha
        b0 = ((1 + cosOmega) / 2) / a0
        b1 = -(1 + cosOmega) / a0
        b2 = ((1 + cosOmega) / 2) / a0
        a1 = (-2 * cosOmega) / a0
        a2 = (1 - alpha) / a0
    }

    mutating func process(_ samples: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: samples.count)
        for (index, x0) in samples.enumerated() {
            let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1
            x1 = x0
            y2 = y1
            y1 = y0
            output[index] = y0
        }
        return output
    }
}

public enum AudioMetering {
    /// Samples per 20 ms frame at 16 kHz, the pipeline's working rate. Callers measuring
    /// audio at a different rate should resample first, or pass the equivalent frame size.
    public static let frameSamples16k = 320
    /// Below this, hum/fan/HVAC noise lives; used only to keep it out of level *measurement*
    /// (see `measure`), never applied to audio that gets transcribed — whispers still need
    /// their (much weaker) low-frequency content intact for the ASR model.
    private static let measurementHighPassHz: Float = 180
    /// Lower edge of the band whispers rely on for intelligibility (Chang et al. 2020: whispers
    /// lose low-frequency voicing, so ASR-relevant energy sits higher). Never filtered out of
    /// the actual signal — only used to compute `highBandRatio` for diagnostics.
    private static let highBandLowHz: Float = 2_000
    private static let highBandHighHz: Float = 8_000

    /// Computes peak, whole-buffer RMS, noise floor (10th-percentile 20 ms frame RMS measured
    /// after a measurement-only high-pass, so sub-180 Hz hum doesn't mask a quiet voice), and
    /// the 2-8 kHz energy ratio. Cheap: a couple of linear passes plus one sort.
    public static func measure(_ samples: [Float], frameSize: Int = frameSamples16k, sampleRate: Float = 16_000) -> AudioStageMetrics {
        guard !samples.isEmpty else { return AudioStageMetrics(peak: 0, rms: 0, noiseFloor: 0, frameCount: 0) }
        var peak: Float = 0
        var sumSquares: Float = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
            sumSquares += sample * sample
        }
        let rms = (sumSquares / Float(samples.count)).squareRoot()
        let highBandRatio = highBandEnergyRatio(samples, sampleRate: sampleRate)

        guard frameSize > 0, samples.count >= frameSize else {
            return AudioStageMetrics(peak: peak, rms: rms, noiseFloor: rms, frameCount: 0, highBandRatio: highBandRatio)
        }
        // Noise floor is measured on high-passed samples: a floor dominated by low-frequency
        // hum would otherwise report as "loud" even when there is no whisper-relevant energy
        // in it, pushing the gate's threshold up and making quiet speech harder to pass.
        var highPass = BiquadHighPass(cutoffHz: measurementHighPassHz, sampleRate: sampleRate)
        let measurementSignal = highPass.process(samples)
        var frameRMS: [Float] = []
        frameRMS.reserveCapacity(samples.count / frameSize)
        var start = 0
        while start + frameSize <= measurementSignal.count {
            var sum: Float = 0
            for index in start..<(start + frameSize) { sum += measurementSignal[index] * measurementSignal[index] }
            frameRMS.append((sum / Float(frameSize)).squareRoot())
            start += frameSize
        }
        frameRMS.sort()
        let percentileIndex = max(0, min(frameRMS.count - 1, frameRMS.count / 10))
        let noiseFloor = frameRMS[percentileIndex]
        return AudioStageMetrics(peak: peak, rms: rms, noiseFloor: noiseFloor, frameCount: frameRMS.count, highBandRatio: highBandRatio)
    }

    /// Fraction of total energy in the 2-8 kHz band: band-pass via two cascaded high-passes
    /// (2 kHz, then subtract a 8 kHz-high-passed copy) rather than a full FFT, since this is a
    /// diagnostic ratio, not something gating or normalization decisions depend on.
    private static func highBandEnergyRatio(_ samples: [Float], sampleRate: Float) -> Float {
        guard samples.count > 8, sampleRate >= highBandHighHz * 2 else { return 0 }
        var totalEnergy: Float = 0
        for sample in samples { totalEnergy += sample * sample }
        guard totalEnergy > 0 else { return 0 }
        var lowCut = BiquadHighPass(cutoffHz: highBandLowHz, sampleRate: sampleRate)
        let above2k = lowCut.process(samples)
        var highCut = BiquadHighPass(cutoffHz: highBandHighHz, sampleRate: sampleRate)
        let above8k = highCut.process(samples)
        var bandEnergy: Float = 0
        for index in 0..<samples.count {
            let value = above2k[index] - above8k[index]
            bandEnergy += value * value
        }
        return min(1, max(0, bandEnergy / totalEnergy))
    }
}

/// Decides whether a recording contains speech, using a noise-floor-relative threshold
/// instead of a single fixed peak level. A fixed threshold (the app's old 0.0015 constant)
/// either clips real whispers in a quiet room (their peak sits barely above true silence) or
/// passes room hum recorded on a hot/noisy mic — because it never looks at what "quiet" means
/// for *this* recording. Comparing against the recording's own noise floor fixes both.
public enum SpeechGate {
    /// A frame at or below this RMS is inaudible even relative to the noise floor — keeps a
    /// completely dead channel (digital silence) or an extremely clean recording from letting
    /// `noiseFloor * k` collapse to ~0 and accepting every frame as "speech".
    public static let absoluteFloor: Float = 0.000_25
    /// How many times louder than the noise floor a frame must be to count as speech.
    /// Tuned so whisper-level bursts (recorded ~25-30 dB down, per the whisper eval) clear the
    /// bar while steady room noise — whose frames barely vary from the floor — does not.
    public static let floorMultiplier: Float = 3.0
    /// Fraction of 20 ms frames that must clear the threshold for the recording to count as
    /// speech. A handful of stray loud frames (a click, a cough) should not pass a silent take.
    public static let minimumActiveFraction: Double = 0.05
    /// Overall RMS above this level counts as speech outright, regardless of the floor-relative
    /// frame count. Needed because a signal with little quiet-to-loud contrast — continuous
    /// speech filling the whole clip, or a synthetic steady tone — has a noise floor close to
    /// its own RMS, so `noiseFloor * floorMultiplier` would sit close to the signal itself and
    /// reject audio that is obviously well above any plausible room-noise level.
    public static let unambiguousSpeechRMS: Float = 0.01

    /// One gate decision plus the numbers behind it, so callers can log why a recording passed
    /// or failed instead of only a boolean.
    public struct Decision: Sendable, Equatable {
        public let hasSpeech: Bool
        public let metrics: AudioStageMetrics
        public let threshold: Float
        public let activeFrameFraction: Double
        /// Which 20 ms frames cleared the bar, in time order (empty when the gate never looked at frames).
        /// `SpeechEvidence` reads it to tell speech, which comes in runs, from scattered clicks.
        public let activeFrames: [Bool]

        public init(hasSpeech: Bool, metrics: AudioStageMetrics, threshold: Float, activeFrameFraction: Double,
                    activeFrames: [Bool] = []) {
            self.hasSpeech = hasSpeech
            self.metrics = metrics
            self.threshold = threshold
            self.activeFrameFraction = activeFrameFraction
            self.activeFrames = activeFrames
        }
    }

    /// Evaluates whether `samples` contains speech. Exact digital silence (every sample `== 0`,
    /// the capture-path failure the app already detects separately) always fails here too.
    ///
    /// Per-frame levels are measured on the same sub-180 Hz-removed signal `AudioMetering`
    /// derives its noise floor from (never on the raw samples passed to ASR) — low-frequency
    /// fan/HVAC hum would otherwise inflate frame RMS without being the kind of energy that
    /// makes a whisper intelligible, pushing frames above threshold for the wrong reason.
    public static func evaluate(_ samples: [Float], sampleRate: Float = 16_000) -> Decision {
        let metrics = AudioMetering.measure(samples, sampleRate: sampleRate)
        return evaluate(samples, metrics: metrics, sampleRate: sampleRate)
    }

    public static func evaluate(_ samples: [Float], metrics: AudioStageMetrics,
                                sampleRate: Float = 16_000) -> Decision {
        guard metrics.frameCount > 0 else {
            return Decision(hasSpeech: false, metrics: metrics, threshold: absoluteFloor, activeFrameFraction: 0)
        }
        // Digital silence (exact zeros) must never pass, even though RMS 0 also technically
        // clears "below unambiguousSpeechRMS" below — this guard is what actually blocks it.
        guard metrics.rms > 0 else {
            return Decision(hasSpeech: false, metrics: metrics, threshold: absoluteFloor, activeFrameFraction: 0)
        }
        var highPass = BiquadHighPass(cutoffHz: 180, sampleRate: sampleRate)
        let measurementSignal = highPass.process(samples)
        let threshold = max(absoluteFloor, metrics.noiseFloor * floorMultiplier)
        var activeFrames = 0
        var activity: [Bool] = []
        let frame = AudioMetering.frameSamples16k
        var start = 0
        while start + frame <= measurementSignal.count {
            var sum: Float = 0
            for index in start..<(start + frame) { sum += measurementSignal[index] * measurementSignal[index] }
            // A frame clears the bar either by beating the floor-relative threshold (the usual
            // case) or, when the floor itself is close to the frame level (a steady loud
            // signal with little quiet-to-loud contrast), by clearly exceeding the ambient
            // room-noise range outright.
            let frameRMS = (sum / Float(frame)).squareRoot()
            let isActive = frameRMS >= threshold || frameRMS >= unambiguousSpeechRMS
            if isActive { activeFrames += 1 }
            activity.append(isActive)
            start += frame
        }
        let fraction = Double(activeFrames) / Double(metrics.frameCount)
        let hasSpeech = fraction >= minimumActiveFraction
        return Decision(hasSpeech: hasSpeech, metrics: metrics, threshold: threshold, activeFrameFraction: fraction,
                        activeFrames: activity)
    }
}

/// Brings quiet speech (whispers, far-away mics) up to a level the recognizer is trained on,
/// without also amplifying the room's noise floor into audibility.
public enum LoudnessNormalizer {
    /// Target RMS for speech, about −23 dBFS.
    public static let targetRMS: Float = 0.07
    /// Never amplify more than this. Raised from 30x (≈30 dB) to 100x (≈40 dB) so whispers
    /// (~20 dB quieter than normal speech, per the whisper research) reach the target level
    /// instead of landing well short of it; the noise-floor cap below is what actually keeps
    /// this safe.
    public static let maxGain: Float = 100
    /// However much gain the signal level suggests, never lift the noise floor above this RMS.
    /// This is what makes a higher `maxGain` safe: a whisper (low signal, low floor) gets
    /// amplified a lot, but a noisy recording (floor already high) is held back even if its
    /// speech is also quiet.
    public static let maxNoiseFloorAfterGain: Float = 0.02

    public static func normalize(_ samples: [Float]) -> [Float] {
        let frame = AudioMetering.frameSamples16k
        guard samples.count >= frame else { return samples }
        let metrics = AudioMetering.measure(samples, frameSize: frame)
        return normalize(samples, metrics: metrics)
    }

    public static func normalize(_ samples: [Float], metrics: AudioStageMetrics) -> [Float] {
        let frame = AudioMetering.frameSamples16k
        guard samples.count >= frame else { return samples }

        // Measure speech loudness over the voiced part only: the loudest 30% of 20 ms frames.
        // This stays a separate pass from `AudioMetering.measure` (which reports the noise
        // floor from the quietest frames) since the two need different frame subsets.
        var energies: [Float] = []
        energies.reserveCapacity(samples.count / frame)
        var start = 0
        while start + frame <= samples.count {
            var sum: Float = 0
            for index in start..<(start + frame) { sum += samples[index] * samples[index] }
            energies.append((sum / Float(frame)).squareRoot())
            start += frame
        }
        let voiced = energies.sorted(by: >).prefix(max(1, energies.count * 3 / 10))
        let level = voiced.reduce(0, +) / Float(voiced.count)
        guard level > 0.000_5 else { return samples }

        var gain = min(targetRMS / level, maxGain)
        // Cap gain so the noise floor doesn't get lifted past the limit: if the floor is
        // already non-trivial (a noisy room), amplifying it as much as a clean whisper would
        // turn hiss into a wall of noise loud enough to compete with the (now-boosted) speech.
        if metrics.noiseFloor > 0 {
            let floorLimitedGain = maxNoiseFloorAfterGain / metrics.noiseFloor
            gain = min(gain, floorLimitedGain)
        }
        guard gain > 1.2 else { return samples }

        let peak = samples.reduce(0) { max($0, abs($1)) }
        // Leave headroom: scale so the loudest sample stays below full scale.
        let linearGain = min(gain, peak > 0 ? 0.95 / peak : gain)
        return samples.map { softLimit($0 * linearGain) }
    }

    /// A gentle tanh-based soft limiter: samples already inside ±1 pass through almost
    /// unchanged (tanh(x) ≈ x near 0), while anything the linear gain pushes past that range
    /// is compressed toward ±1 instead of hard-clipping. Applied after the headroom-based
    /// linear gain above, which already keeps most material well inside range — this only
    /// catches the occasional sample the frame-level gain calculation didn't anticipate.
    private static func softLimit(_ sample: Float) -> Float {
        guard abs(sample) > 0.98 else { return sample }
        return tanh(sample)
    }
}
