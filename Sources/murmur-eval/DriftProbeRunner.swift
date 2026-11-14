import FluidAudio
import Foundation
import MurmurCore

/// Short-clip language-drift probe: 1–3 word utterances synthesized with `/usr/bin/say` across
/// several voices, transcribed by each model configuration. Reports how many outputs came out
/// in another language (`Runners.isNonEnglish`: non-Latin script or a confident non-English
/// language ID) and, for guarded configurations, how often the guard fell back to v2.
///
/// Why short clips: language ID inside the multilingual model has the least evidence on a
/// one-word utterance, which is where the whisper-into-Polish class of drift is most likely —
/// and where `AsrDriftGuard`'s own `NLLanguageRecognizer` check is least reliable, so this is the
/// set that exercises its word-list rule. Acceptance (docs/product/DIRECTION.md, decision 1):
/// 0 non-English outputs after the guard.
///
///   murmur-eval drift-probe [--models v2,ultra,ultra+guard] [--limit 50] [--outputs path]
///
/// `--outputs` writes every clip's text, one line per model and clip, so two runs can be
/// compared exactly (the phrases are this file's own, synthesized: nothing a person said).
enum DriftProbeRunner {
    /// 50 distinct 1–3 word dictations of the kind people actually send: replies, commands,
    /// names, numbers. Kept disjoint from `Runners.shortPhrases` (the challenge set) so the two
    /// numbers stay independent.
    static let phrases = [
        "Okay.", "Sure.", "Nope.", "Absolutely.", "Cancel that.", "Send it.", "Book it.", "Skip this.",
        "Next slide.", "New paragraph.", "Delete that.", "Undo.", "Save draft.", "Reply all.", "Mute.",
        "Sounds fine.", "Almost there.", "Be right back.", "Coffee first.", "Lunch at noon.", "Ten minutes.",
        "Two hundred.", "Half past five.", "Tuesday morning.", "Next week.", "Talk soon.", "Thanks again.",
        "You too.", "Well done.", "Nice work.", "Fair enough.", "No worries.", "Good point.", "Makes sense.",
        "Hold on.", "One second.", "Almost done.", "Push it.", "Merge it.", "Fix the tests.", "Ping Priya.",
        "Email Siobhan.", "Call Marcus.", "Ask Wei.", "Invoice sent.", "Meeting moved.", "Flight booked.",
        "Battery low.", "Door's open.", "Lights off.",
    ]

    static let voices = ["Samantha", "Daniel", "Karen", "Moira", "Aman", "Whisper"]

    static func run(_ args: Arguments) async throws {
        let limit = args.int("limit") ?? phrases.count
        let models = (args.string("models") ?? "v2,ultra,ultra+guard").split(separator: ",").map(String.init)
        let folder = Paths.data.appendingPathComponent("tts-drift-probe", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var clips: [(phrase: String, voice: String, samples: [Float])] = []
        for (index, phrase) in phrases.prefix(limit).enumerated() {
            let voice = voices[index % voices.count]
            let url = folder.appendingPathComponent("probe-\(index)-\(voice).wav")
            if !FileManager.default.fileExists(atPath: url.path) { try Runners.synthesize(phrase, voice: voice, to: url) }
            var samples = try AudioConverter().resampleAudioFile(url)
            // The "Whisper" voice is played back at whisper level, as in `Runners.whisper`.
            if voice == "Whisper" { samples = samples.map { $0 * 0.06 } }
            clips.append((phrase, voice, samples))
        }

        var lines: [String] = []
        var details: [String] = []
        var outputs: [String] = []
        for name in models {
            guard let engine = try await Engine.load(named: name) else {
                print("  skipping unknown model \(name)")
                continue
            }
            let pipeline = DictationPipeline(transcriber: engine)
            var pairs: [(reference: String, hypothesis: String)] = []
            var nonEnglish = 0
            var exact = 0
            for (index, clip) in clips.enumerated() {
                let text = try await pipeline.transcribeRaw(clip.samples)
                outputs.append("\(name)\t\(index)\t\(clip.voice)\t\(text)")
                pairs.append((clip.phrase, text))
                if EvalMetrics.wordsMatch(clip.phrase, text) { exact += 1 }
                if Runners.isNonEnglish(text) {
                    nonEnglish += 1
                    details.append("  ! \(name) · \(clip.voice) · \"\(clip.phrase)\" → \"\(text)\"")
                }
            }
            lines.append(
                "  - \(name): \(nonEnglish)/\(clips.count) came out in another language, "
                    + "\(Runners.percent(EvalMetrics.corpusWER(pairs))) WER, \(exact)/\(clips.count) exactly right"
                    + (await engine.driftSummary))
        }
        Runners.emit(
            "### Drift probe · \(clips.count) short (1–3 word) utterances · \(voices.joined(separator: "/")) · \(models.joined(separator: ","))\n"
                + lines.joined(separator: "\n"),
            details: details)
        if let path = args.string("outputs") {
            try (outputs.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
