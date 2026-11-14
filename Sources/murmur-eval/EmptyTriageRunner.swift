import AVFoundation
import Foundation
import MurmurCore

/// `murmur-eval empty-triage --dirs <folder,…>`: the numbers behind `EmptyDictationTriage`'s two
/// thresholds. Reads WAV files only (no recogniser, no microphone) and prints, per clip, its length,
/// the speech gate's speech seconds and sound seconds, and the outcome the triage would give if the
/// recogniser returned nothing. Each clip is also cut to its first 0.5 s and 0.8 s, the shortest press
/// a person could still speak a word into. Synthetic presses (exact silence, room noise, key clicks,
/// a desk bump, a breath) are generated here and run through the same measures.
///
/// The wanted result: every speech clip and cut is `brief` or longer-lived (never `dismiss`), and
/// every synthetic press under a second is `dismiss`.
enum EmptyTriageRunner {
    static func run(_ args: Arguments) async throws {
        let dirs = (args.string("dirs") ?? "").split(separator: ",").map { URL(fileURLWithPath: String($0)) }
        print("| clip | seconds | speech s | sound s | gate | outcome |")
        print("|---|---|---|---|---|---|")
        var speechMin = Double.infinity
        var speechDismissed = 0
        var speechRows = 0
        var speechNoEvidence = 0
        var evidenceMin = Double.infinity
        var voicedMin = Double.infinity
        var voicedZero: [String] = []
        var shortClips: [[Float]] = []
        for dir in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files.filter({ $0.pathExtension.lowercased() == "wav" }).sorted(by: { $0.path < $1.path }) {
                guard let samples = load(file) else { continue }
                for cut in [nil, 0.5, 0.8] as [Double?] {
                    let clip = cut.map { Array(samples.prefix(Int($0 * 16_000))) } ?? samples
                    let row = measure(clip)
                    speechRows += 1
                    speechMin = min(speechMin, row.speech)
                    if row.outcome == .dismiss { speechDismissed += 1 }
                    if !row.evidence.accepts(gatePassed: row.gate) { speechNoEvidence += 1; print("  NO EVIDENCE: \(file.lastPathComponent) cut \(cut.map { String($0) } ?? "full") seconds \(String(format: "%.2f", row.seconds)) gate \(row.gate ? "pass" : "fail") run s \(String(format: "%.2f", row.evidence.speechSeconds)) voiced s \(String(format: "%.2f", row.evidence.voicedSeconds)) share \(String(format: "%.0f%%", row.evidence.share * 100))") }
                    evidenceMin = min(evidenceMin, row.evidence.speechSeconds)
                    let gateNow = SpeechGate.evaluate(clip)
                    let voiced = VoicingFrames.measure(clip, active: gateNow.activeFrames).filter { $0 }.count
                    voicedMin = min(voicedMin, Double(voiced) * 0.02)
                    if voiced < 3 { voicedZero.append("\(dir.lastPathComponent)/\(file.deletingPathExtension().lastPathComponent.prefix(14)) cut \(cut.map { String($0) } ?? "full") voiced \(voiced) frames") }
                    if cut == nil { shortClips.append(clip) }
                    let name = "\(dir.lastPathComponent)/\(file.deletingPathExtension().lastPathComponent.prefix(12))" + (cut.map { " ≤\($0)s" } ?? "")
                    print(line(name, row))
                }
            }
        }
        var pressMax = 0.0
        var pressKept = 0
        let presses = syntheticPresses()
        for (name, clip) in presses {
            let row = measure(clip)
            if Double(clip.count) / 16_000 < EmptyDictationTriage.accidentalPressSeconds {
                pressMax = max(pressMax, row.speech)
                if row.outcome != .dismiss { pressKept += 1 }
            }
            print(line("synthetic/\(name)", row))
        }
        print("")
        print("speech clips and cuts: \(speechRows), dismissed: \(speechDismissed), least speech seconds: \(String(format: "%.3f", speechMin))")
        print("synthetic presses under \(EmptyDictationTriage.accidentalPressSeconds) s: \(presses.filter { Double($0.1.count) / 16_000 < EmptyDictationTriage.accidentalPressSeconds }.count), not dismissed: \(pressKept), most speech seconds: \(String(format: "%.3f", pressMax))")
        print("speech clips and cuts the recogniser would not get: \(speechNoEvidence) of \(speechRows); least run seconds: \(String(format: "%.3f", evidenceMin))")
        print("speech clips and cuts with under 3 voiced frames: \(voicedZero.count); least voiced seconds: \(String(format: "%.2f", voicedMin))")
        voicedZero.prefix(40).forEach { print("  \($0)") }
        print("")
        print("long recordings (20 s): share = run seconds / length; old = the gate's scattered-frame rule")
        print("| case | gate | active frames | run s | voiced s | runs | share | real speech |")
        print("|---|---|---|---|---|---|---|---|")
        var wrong = 0
        for item in EmptyTriageLongCases.make(speech: shortClips) {
            let gate = SpeechGate.evaluate(item.samples)
            let evidence = SpeechEvidence(gate: gate, samples: item.samples, duration: Double(item.samples.count) / 16_000)
            let isWrong = evidence.accepts(gatePassed: gate.hasSpeech) != item.hasSpeech && !item.name.hasPrefix("video")
            if isWrong { wrong += 1 }
            let voicedFrames = VoicingFrames.measure(item.samples, active: gate.activeFrames).filter { $0 }.count
            print("  voiced frames in \(item.name): \(voicedFrames) of \(gate.activeFrames.filter { $0 }.count) active")
            print(String(format: "| %@ | %@ | %.1f%% | %.2f | %.2f | %d | %.2f%% | %@ |", item.name, gate.hasSpeech ? "pass" : "fail",
                         gate.activeFrameFraction * 100, evidence.speechSeconds, evidence.voicedSeconds, evidence.runs.count, evidence.share * 100,
                         (evidence.accepts(gatePassed: gate.hasSpeech) ? "yes" : "no") + (isWrong ? "  <-- WRONG" : "")))
        }
        print("long recordings judged wrongly (video cases excluded, they are speech): \(wrong)")
        print("thresholds: accidental press < \(EmptyDictationTriage.accidentalPressSeconds) s, speech energy ≥ \(EmptyDictationTriage.speechEnergySeconds) s")
    }

    struct Row {
        let seconds: Double
        let speech: Double
        let sound: Double
        let gate: Bool
        let outcome: EmptyDictationTriage.Outcome
        let evidence: SpeechEvidence
    }

    static func measure(_ samples: [Float]) -> Row {
        let seconds = Double(samples.count) / 16_000
        let gate = SpeechGate.evaluate(samples)
        let hearing = InputHearing.measure(samples)
        let speech = EmptyDictationTriage.speechSeconds(gate, duration: seconds)
        let outcome = EmptyDictationTriage.outcome(duration: seconds, speechSeconds: speech, hearing: hearing)
        return Row(seconds: seconds, speech: speech, sound: hearing.soundSeconds, gate: gate.hasSpeech, outcome: outcome,
                   evidence: SpeechEvidence(gate: gate, samples: samples, duration: seconds))
    }

    private static func line(_ name: String, _ row: Row) -> String {
        String(format: "| %@ | %.2f | %.3f | %.2f | %@ | %@ |", name, row.seconds, row.speech, row.sound,
               row.gate ? "pass" : "fail", row.outcome.rawValue)
    }

    private static func load(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let resampler = StreamingResampler(from: file.processingFormat) else { return nil }
        return resampler.convert(buffer)
    }

    /// Presses with no speech in them, at the lengths a stray tap or a short hold takes.
    static func syntheticPresses() -> [(String, [Float])] {
        var generator = SeededNoise(seed: 7)
        var cases: [(String, [Float])] = []
        for seconds in [0.3, 0.5, 0.8, 1.2, 2.0] {
            let count = Int(seconds * 16_000)
            let tag = String(format: "%.1fs", seconds)
            cases.append(("silence-\(tag)", [Float](repeating: 0, count: count)))
            for (level, label) in [(Float(0.0003), "quiet room"), (Float(0.002), "office")] {
                let room = (0..<count).map { _ in generator.next() * level }
                cases.append(("\(label)-\(tag)", room))
                cases.append(("\(label)+clicks-\(tag)", withClicks(room)))
                cases.append(("\(label)+bump-\(tag)", withBump(withClicks(room))))
                cases.append(("\(label)+breath-\(tag)", withBreath(withClicks(room), generator: &generator)))
            }
        }
        return cases
    }

    /// A key's press and release: a 6 ms decaying burst at the start and at the end.
    private static func withClicks(_ room: [Float]) -> [Float] {
        var out = room
        for start in [Int(0.03 * 16_000), max(0, room.count - Int(0.05 * 16_000))] {
            for i in 0..<96 where start + i < out.count {
                let decay = Float(exp(-Double(i) / 18))
                out[start + i] += 0.08 * decay * (i % 2 == 0 ? 1 : -1)
            }
        }
        return out
    }

    /// The desk bumped: a 40 ms low thump (mostly under the gate's 180 Hz high-pass) with some click.
    private static func withBump(_ input: [Float]) -> [Float] {
        var out = input
        let start = out.count / 3
        for i in 0..<640 where start + i < out.count {
            let t = Double(i) / 16_000
            out[start + i] += Float(0.12 * exp(-t * 60) * sin(2 * .pi * 70 * t))
        }
        return out
    }

    /// A short breath out: 150 ms of soft broadband noise.
    private static func withBreath(_ input: [Float], generator: inout SeededNoise) -> [Float] {
        var out = input
        let start = out.count / 2 - 1_200
        for i in 0..<2_400 where start + i >= 0 && start + i < out.count {
            let envelope = Float(sin(Double(i) / 2_400 * .pi))
            out[start + i] += generator.next() * 0.006 * envelope
        }
        return out
    }

    /// A fixed noise source, so the table is the same on every run.
    struct SeededNoise {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int64(bitPattern: state >> 1) % 2_000_001) / 1_000_000 - 1
        }
    }
}
