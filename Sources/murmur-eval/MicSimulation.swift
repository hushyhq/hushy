import Foundation
import MurmurCore

/// Simulated microphone conditions for `murmur-eval mics`: what a headset, a noisy room or a
/// too-hot input does to speech before Hushy sees it. Every function is a plain transform of 16 kHz
/// mono samples, so a condition can be read, tested and rerun exactly.
///
/// These are simulations, and each says what it stands for. None is a recording through a real
/// device: a real headset adds its own microphone, beam-forming and firmware processing on top of
/// the codec, and only a device check can measure those.
enum MicSimulation {
    static let sampleRate = 16_000

    /// The same speech at another level: -20 dB is a quiet voice or a far microphone, -30 dB is
    /// about whisper level (RMS near 0.002 for speech recorded near 0.06). A scaled voice is not a
    /// whisper: a real whisper also loses its voicing.
    static func gain(_ samples: [Float], dB: Double) -> [Float] {
        let factor = Float(pow(10, dB / 20))
        return samples.map { $0 * factor }
    }

    /// The first `seconds` replaced by exact zeros: the person was already speaking while a
    /// Bluetooth headset's call link came up, and the microphone delivered nothing.
    static func loseStart(_ samples: [Float], seconds: Double) -> [Float] {
        let count = min(samples.count, max(0, Int(seconds * Double(sampleRate))))
        return [Float](repeating: 0, count: count) + samples[count...]
    }

    /// `seconds` of exact zeros before the speech: the person waited for the link, so nothing is
    /// lost, and the recording only starts with silence.
    static func leadIn(_ samples: [Float], seconds: Double) -> [Float] {
        [Float](repeating: 0, count: max(0, Int(seconds * Double(sampleRate)))) + samples
    }

    /// A headset-style noise gate: 10 ms frames under `thresholdDBFS` are muted to exact zeros,
    /// except for `holdSeconds` after the last frame that was over it. No look-ahead, so an onset
    /// quieter than the threshold is cut. The threshold is an illustration, not a figure measured
    /// from any headset.
    static func noiseGate(_ samples: [Float], thresholdDBFS: Double, holdSeconds: Double = 0.15) -> [Float] {
        let frame = sampleRate / 100
        let threshold = Float(pow(10, thresholdDBFS / 20))
        let holdFrames = Int((holdSeconds * 100).rounded())
        var output = samples
        var framesSinceOpen = Int.max
        var start = 0
        while start < samples.count {
            let end = min(start + frame, samples.count)
            var sumSquares: Float = 0
            for index in start..<end { sumSquares += samples[index] * samples[index] }
            let rms = (sumSquares / Float(end - start)).squareRoot()
            if rms >= threshold {
                framesSinceOpen = 0
            } else if framesSinceOpen != Int.max {
                framesSinceOpen += 1
            }
            if framesSinceOpen > holdFrames {
                for index in start..<end { output[index] = 0 }
            }
            start = end
        }
        return output
    }

    /// A too-hot input: the signal is raised until its peak is `dBOverFullScale` above full scale,
    /// then cut flat at full scale, as a converter does.
    static func overdrive(_ samples: [Float], dBOverFullScale: Double) -> [Float] {
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0 else { return samples }
        let factor = Float(pow(10, dBOverFullScale / 20)) / peak
        return samples.map { min(1, max(-1, $0 * factor)) }
    }

    /// Pink noise from white: Paul Kellett's economy filter (three one-pole sections), which
    /// falls about 3 dB an octave. Room noise leans this way; white noise is harsher than rooms are.
    static func pink(_ white: [Float]) -> [Float] {
        var b0: Float = 0, b1: Float = 0, b2: Float = 0
        return white.map { sample in
            b0 = 0.997_65 * b0 + sample * 0.099_046_0
            b1 = 0.963_00 * b1 + sample * 0.296_516_4
            b2 = 0.570_00 * b2 + sample * 1.052_691_3
            return b0 + b1 + b2 + sample * 0.184_8
        }
    }

    /// Babble: several other speakers at equal level, each looped to `count` from a different
    /// starting point. The mix is scaled against the speech afterwards (`Runners.mix`).
    static func babble(_ voices: [[Float]], count: Int) -> [Float] {
        var sum = [Float](repeating: 0, count: count)
        for (number, voice) in voices.enumerated() where !voice.isEmpty {
            let level = StreamingResampler.rms(voice)
            guard level > 0 else { continue }
            let offset = (number * 7_919) % voice.count
            for index in 0..<count { sum[index] += voice[(index + offset) % voice.count] / level }
        }
        return sum
    }
}

/// One simulated condition: its name, the group it is reported under, and the transform.
struct MicCondition {
    /// What the transform is given for one clip.
    struct Input {
        let index: Int
        let samples: [Float]
        /// Other clips of the same run, for babble: never the clip itself.
        let otherVoices: [[Float]]
        /// Seeded per condition and clip, so every rerun adds the same noise.
        var noise: SeededNoise
    }

    let name: String
    let group: String
    let apply: (inout Input) throws -> [Float]
}

/// Passes audio through an `ffmpeg` encoder and back, for the codec conditions. Nothing is
/// installed or downloaded: a condition whose codec this `ffmpeg` lacks is reported as skipped.
struct FFmpegRoundTrip {
    let ffmpeg: URL
    let scratch: URL

    enum Failure: Error, CustomStringConvertible {
        case exited(String, Int32)
        var description: String {
            switch self {
            case .exited(let step, let status): "ffmpeg \(step) exited with \(status)"
            }
        }
    }

    /// The encoders this `ffmpeg` has, by name.
    func encoders() -> Set<String> {
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        return Set(lines.compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            return fields.count >= 2 && fields[0].count == 6 ? String(fields[1]) : nil
        })
    }

    /// 16 kHz mono in, `encode` arguments applied (filters, rate, codec), written as `container`,
    /// decoded again (`decode` arguments go before the input) and returned at 16 kHz mono.
    func run(_ samples: [Float], encode: [String], container: String, decode: [String] = []) throws -> [Float] {
        let id = UUID().uuidString
        let input = scratch.appendingPathComponent("\(id)-in.f32")
        let coded = scratch.appendingPathComponent("\(id)-coded.\(container)")
        let output = scratch.appendingPathComponent("\(id)-out.f32")
        defer { for url in [input, coded, output] { try? FileManager.default.removeItem(at: url) } }
        try samples.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: input)
        let raw = ["-f", "f32le", "-ar", "16000", "-ac", "1"]
        try invoke("encode", raw + ["-i", input.path] + encode + [coded.path])
        try invoke("decode", decode + ["-i", coded.path] + raw + [output.path])
        let data = try Data(contentsOf: output)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private func invoke(_ step: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.exited(step, process.terminationStatus) }
    }
}

extension MicCondition {
    static let cleanName = "clean, as recorded"

    /// Every condition of the run, in report order. `codec` is nil when no `ffmpeg` was found;
    /// `encoders` is what it can encode. Codec conditions that cannot run are left out and named
    /// in `skipped`.
    static func all(codec: FFmpegRoundTrip?, encoders: Set<String>) -> (conditions: [MicCondition], skipped: [String]) {
        var conditions: [MicCondition] = []
        var skipped: [String] = []
        func add(_ group: String, _ name: String, _ apply: @escaping (inout Input) throws -> [Float]) {
            conditions.append(MicCondition(name: name, group: group, apply: apply))
        }

        // Level.
        add("level", cleanName) { $0.samples }
        add("level", "quiet, -20 dB") { MicSimulation.gain($0.samples, dB: -20) }
        add("level", "whisper-quiet, -30 dB") { MicSimulation.gain($0.samples, dB: -30) }
        add("level", "under a whisper, -40 dB") { MicSimulation.gain($0.samples, dB: -40) }

        // Bluetooth call mode. The band limits and codecs need ffmpeg.
        let narrowBand = ["-af", "highpass=f=300,lowpass=f=3400", "-ar", "8000"]
        let wideBand = ["-ar", "16000", "-c:a", "sbc", "-msbc", "1", "-f", "sbc"]
        func msbc(_ samples: [Float], _ codec: FFmpegRoundTrip) throws -> [Float] {
            try codec.run(samples, encode: wideBand, container: "sbc", decode: ["-f", "sbc"])
        }
        if let codec {
            add("bluetooth", "8 kHz, 300 to 3,400 Hz, no codec") {
                try codec.run($0.samples, encode: narrowBand + ["-c:a", "pcm_s16le"], container: "wav")
            }
            if encoders.contains("pcm_mulaw") {
                add("bluetooth", "8 kHz with G.711 mu-law (stands in for CVSD)") {
                    try codec.run($0.samples, encode: narrowBand + ["-c:a", "pcm_mulaw"], container: "wav")
                }
            } else { skipped.append("8 kHz with G.711 mu-law: this ffmpeg has no pcm_mulaw encoder") }
            if encoders.contains("sbc") {
                add("bluetooth", "16 kHz mSBC") { try msbc($0.samples, codec) }
                add("bluetooth", "16 kHz mSBC, quiet, -20 dB") { try msbc(MicSimulation.gain($0.samples, dB: -20), codec) }
                add("bluetooth", "16 kHz mSBC, whisper-quiet, -30 dB") { try msbc(MicSimulation.gain($0.samples, dB: -30), codec) }
                add("bluetooth", "16 kHz mSBC, first 0.5 s lost") {
                    MicSimulation.loseStart(try msbc($0.samples, codec), seconds: 0.5)
                }
                add("bluetooth", "16 kHz mSBC, first 1.0 s lost") {
                    MicSimulation.loseStart(try msbc($0.samples, codec), seconds: 1.0)
                }
            } else { skipped.append("16 kHz mSBC: this ffmpeg has no sbc encoder") }
            if encoders.contains("aac_at") {
                add("bluetooth", "24 kHz AAC-ELD, 32 kbit/s") {
                    try codec.run($0.samples, encode: ["-ar", "24000", "-c:a", "aac_at", "-profile:a", "38", "-b:a", "32k"],
                                  container: "m4a")
                }
            } else { skipped.append("24 kHz AAC-ELD: this ffmpeg has no aac_at encoder") }
        } else {
            skipped.append("every band-limit and codec condition: no ffmpeg found")
        }
        skipped.append("CVSD itself: ffmpeg has no CVSD codec, so G.711 mu-law at the same 8 kHz stands in")
        skipped.append("LC3 and LC3-SWB: this ffmpeg has no LC3 codec")
        add("bluetooth", "first 0.5 s lost (zeros)") { MicSimulation.loseStart($0.samples, seconds: 0.5) }
        add("bluetooth", "first 1.0 s lost (zeros)") { MicSimulation.loseStart($0.samples, seconds: 1.0) }
        add("bluetooth", "1.0 s of zeros before the speech") { MicSimulation.leadIn($0.samples, seconds: 1.0) }

        // A headset's own noise gate.
        add("noise gate", "gate at -45 dBFS, normal level") { MicSimulation.noiseGate($0.samples, thresholdDBFS: -45) }
        add("noise gate", "gate at -45 dBFS, quiet, -20 dB") {
            MicSimulation.noiseGate(MicSimulation.gain($0.samples, dB: -20), thresholdDBFS: -45)
        }
        add("noise gate", "gate at -45 dBFS, whisper-quiet, -30 dB") {
            MicSimulation.noiseGate(MicSimulation.gain($0.samples, dB: -30), thresholdDBFS: -45)
        }
        add("noise gate", "gate at -55 dBFS, quiet, -20 dB") {
            MicSimulation.noiseGate(MicSimulation.gain($0.samples, dB: -20), thresholdDBFS: -55)
        }
        add("noise gate", "gate at -55 dBFS, whisper-quiet, -30 dB") {
            MicSimulation.noiseGate(MicSimulation.gain($0.samples, dB: -30), thresholdDBFS: -55)
        }

        // Added noise.
        for snr in [20.0, 10, 0] {
            add("noise", "white noise, \(Int(snr)) dB SNR") { input in
                Runners.mix(input.samples, input.noise.noise(count: input.samples.count), snrDB: snr)
            }
        }
        for snr in [20.0, 10, 0] {
            add("noise", "pink noise, \(Int(snr)) dB SNR") { input in
                Runners.mix(input.samples, MicSimulation.pink(input.noise.noise(count: input.samples.count)), snrDB: snr)
            }
        }
        for snr in [20.0, 10, 0] {
            add("noise", "babble of four other speakers, \(Int(snr)) dB SNR") { input in
                Runners.mix(input.samples, MicSimulation.babble(input.otherVoices, count: input.samples.count), snrDB: snr)
            }
        }

        // Clipping.
        for over in [6.0, 12, 20] {
            add("clipping", "clipped, peaks \(Int(over)) dB over full scale") {
                MicSimulation.overdrive($0.samples, dBOverFullScale: over)
            }
        }
        return (conditions, skipped)
    }
}
