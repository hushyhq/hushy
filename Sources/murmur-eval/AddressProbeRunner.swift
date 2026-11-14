import FluidAudio
import Foundation
import MurmurCore

/// Local prepared speech only; prints the app's short-dictation stages for each clip.
enum AddressProbeRunner {
    struct Clip: Decodable {
        let file: String
        let said: String
        let voice: String
        let tailSeconds: Int
        let noise: Double
    }

    static func loadClips(folder: URL) throws -> [Clip] {
        try JSONDecoder().decode([Clip].self, from: Data(contentsOf: folder.appendingPathComponent("clips.json")))
    }

    /// The ending comes from the manifest, not an address or ending list.
    static func hasRepeatedEnding(_ text: String, said: String) -> Bool {
        guard said.range(of: "\\bdot\\b", options: .regularExpression) != nil else { return false }
        func units(_ value: String) -> [String] {
            value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init).filter { $0 != "dot" }
        }
        guard let ending = units(said).last else { return false }
        let heard = units(text)
        return heard.count >= 2 && heard.suffix(2).allSatisfy { $0 == ending }
    }

    /// A term that contains its heard phrase, made from the spoken address itself (no list): the name is the one or two words
    /// before "dot", the term is the name joined with its ending ("jimmy lord dot com" -> "jimmylord.com"), and the alias is the
    /// glued name, or the name as two words.
    static func inventedVocabularies(said: String) -> [(String, VocabularyContext)] {
        let words = said.lowercased().split(separator: " ").map(String.init)
        guard let dot = words.firstIndex(of: "dot"), dot >= 1, dot + 1 < words.count else { return [] }
        let name = Array(words[max(0, dot - 2)..<dot])
        let term = name.joined() + "." + words[dot + 1]
        var result = [("term+glued-alias", VocabularyContext(terms: [VocabularyTerm(text: term, aliases: [name.joined()])]))]
        if name.count > 1 {
            result.append(("term+two-word-alias", VocabularyContext(terms: [VocabularyTerm(text: term, aliases: [name.joined(separator: " ")])])))
        }
        return result
    }

    /// The last word of a spoken address ("jimmy lord dot com" -> "com"), nil when nothing was said with "dot".
    static func hasDot(_ said: String) -> String? {
        let words = said.lowercased().split(separator: " ").map(String.init)
        return words.contains("dot") ? words.last : nil
    }

    static func run(_ args: Arguments) async throws {
        guard let path = args.string("clips") else { throw EvalError.missing("address-probe requires --clips <folder>") }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let clips = try loadClips(folder: folder)
        guard AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: args.model), version: args.model),
              AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v2), version: .v2),
              CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory(for: .ctc110m)) else {
            throw EvalError.missing("address-probe requires cached ASR, v2 drift fallback, and vocabulary models; no downloads attempted")
        }
        let engine = try await Engine.load(args.model, driftGuard: args.modelName == "ultra")
        let cleaner = TextCleaner()
        var counts: [String: Int] = [:]
        for clip in clips {
            let samples = try AudioConverter(sampleRate: 16_000).resampleAudioFile(folder.appendingPathComponent(clip.file))
            let normalized = LoudnessNormalizer.normalize(samples)
            print("clip=\"\(clip.file)\" said=\"\(clip.said)\" voice=\(clip.voice) tail=\(clip.tailSeconds) noise=\(clip.noise) samples=\(samples.count)")
            var vocabularies: [(String, VocabularyContext)] = args.flag("invented-only") ? [] : [
                ("empty", VocabularyContext.empty),
                ("built-in", VocabularyContext(terms: VocabularyContext.builtInTerms)),
            ]
            if args.flag("invented-only") || args.flag("invented") {
                vocabularies += inventedVocabularies(said: clip.said)
            }
            for (name, vocabulary) in vocabularies {
                let trace = try await engine.vocabularyTrace(normalized, vocabulary: vocabulary)
                // DictationController stores guarded ASR text verbatim as raw. TextCleaner runs
                // after that boundary and includes SpokenAddressNormalizer for English cleanup.
                let raw = trace.guarded
                let rules = cleaner.clean(raw).text
                let stages = [
                    ("base", trace.base), ("drifted", trace.drifted),
                    ("rescored", trace.rescored), ("guarded", trace.guarded),
                    ("raw", raw), ("rules", rules),
                ]
                // The boosting stage alone: did the rescoring (and the guard after it) repeat a word the recogniser's text did not?
                let drifted = RepeatTrace(trace.drifted)
                for (stage, text) in [("rescored", trace.rescored), ("guarded", trace.guarded)]
                where RepeatTrace.added(from: drifted, to: RepeatTrace(text)) {
                    counts["\(name).boost-added.\(stage)", default: 0] += 1
                }
                // The ending written more times than the recogniser's text had it, adjacent or not ("jimmylord.com dot com").
                if let ending = hasDot(clip.said) {
                    func times(_ text: String) -> Int { text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0 == ending }.count }
                    for (stage, text) in [("rescored", trace.rescored), ("guarded", trace.guarded)] where times(text) > times(trace.drifted) {
                        counts["\(name).ending-added.\(stage)", default: 0] += 1
                    }
                }
                if trace.rescored != trace.drifted { counts["\(name).boost-changed-text", default: 0] += 1 }
                for (stage, text) in stages where hasRepeatedEnding(text, said: clip.said) {
                    counts["\(name).\(stage)", default: 0] += 1
                    counts["\(name).\(stage).\(clip.voice).t\(clip.tailSeconds).n\(clip.noise)", default: 0] += 1
                }
                print("  \(name) base=\"\(trace.base)\" drifted=\"\(trace.drifted)\" rescored=\"\(trace.rescored)\" guarded=\"\(trace.guarded)\" confidenceWords=\(trace.confidenceWords) raw=\"\(raw)\" rules=\"\(rules)\"")
            }
        }
        print("summary clips=\(clips.count) vocabularyRuns=\(clips.count * 2)")
        for key in counts.keys.sorted() { print("  repeats \(key)=\(counts[key]!)") }
    }
}
