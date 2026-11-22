import FluidAudio
import Foundation
import HushyModelsApple
import HushyModelsMLX
import HushyModelsRemote
import MurmurCore

/// Murmur evaluation harness.
///
///   Every command takes `--backend apple|apple-guided|none|mlx|mlx+apple|local` (default apple): the `LanguageModel`
///   behind cleanup, modes, actions and summaries. `none` = no model (rules paths only); `mlx` =
///   a local MLX model from `--mlx-model <dir>` or $HUSHY_MLX_MODEL_DIR (needs
///   scripts/build-mlx-metallib.sh once per build dir); `mlx+apple` = MLX, falling back to Apple FM;
///   `local` = the app's own wiring of a `ModelRegistry` entry (`LocalCleanupBackend`: speculation
///   on, the entry's prompt profile, → Apple FM) — `--local-model <id>` (default: this Mac's
///   recommendation), files from `--mlx-model <dir>` or <HUSHY_HOME>/Models/<id>.
///   `remote` (EVAL-ONLY) = the same model served by vLLM on the CUDA box over Tailscale
///   (`--remote-url http://<box>:8008` or $HUSHY_REMOTE_URL, API key from scripts/gpu/fetch-api-key.sh,
///   `--remote-model <served name>` or
///   $HUSHY_REMOTE_MODEL; `--mlx-prompt` and `--mlx-tool-grammar` apply as for `mlx`). Same
///   prompts, grammar and guards; the model runs on the GPU (.claude/GPU-TRAINING.md
///   "Remote GPU inference for evals"). Apple FM evals and the final 4-bit MLX sign-off stay local.
///   murmur-eval local-model list|fetch|verify [--local-model <id>] [--dir <dir>]
///     (registry entries; fetch = the app's resumable, SHA-256-checked download; verify = full hash)
///   murmur-eval download [dataset|all] [--limit N]
///   murmur-eval vocab-real-boost [--harm Evals/vocab-harm.jsonl] [--win Evals/vocab-win.jsonl] [--fixture Evals/vocab-real-boost-fixture.json]
///       [--audio <dir from scripts/vocab-eval-audio.sh>] [--model ultra+guard] [--rows-out rows.jsonl] [--report summary.json] [--limit N]
///     (real Parakeet -> real CTC boost -> BoostGuard on invented `say` speech with the fixture vocabulary; words made worse, name recall)
///   murmur-eval asr <dataset> [--model v3|ultra] [--limit N]
///   murmur-eval cleanup [--strategy rules|hybrid|model] [--clean-gate heuristic|always]
///     (--clean-gate applies to every command that cleans at Clean: always = the model is asked for
///      every English dictation instead of only when ModelHints.worthAsking fires)
///   murmur-eval cleanup-trace --cases <dev.json> --backend none|apple|mlx [--mlx-model dir]
///       [--mlx-prompt production|compact|compact-v3|compact-v4|compact-v4-polished-bridge] --report <json>
///     (one fixed-text cleanup trace per invocation; see handbook quality/cleanup-trace)
///   murmur-eval grammar-verify --cases <dev.json> --backend none|apple|mlx --report <json>
///     (independent synthetic source/candidate stress pairs for the local grammar verifier)
///   murmur-eval dev-messages [--cases Evals/developer-messages-dev.json] [--level clean|polished|both] [--report path.json]
///     (developer Slack/PR/ticket/email messages through the real classifier, cleanup and styling;
///      a development set — see Evals/README.md. Use --backend local --mlx-model <dir> for the app's model)
///   murmur-eval tones [--set Evals/tones-dev.json] [--path rules|hybrid|wired] [--report path.json]
///       [--jev | --jev-calibrate] [--jev-calls 450] [--jev-report path.json]
///     (the Refined/Casual/Professional tone layer on the developer messages: exact, checks and faithfulness per tone;
///      use --backend none for the rules path; hybrid and wired only run if a model is already available;
///      wired = the dictation pipeline with the tone setting, as the app runs it. --jev adds Jev as a second
///      opinion on each output, --jev-calibrate scores that rubric against the expected outputs; both off by default)
///   murmur-eval e2e [--model v3|ultra] [--strategy hybrid] [--voices Samantha,Daniel,…]
///   murmur-eval disfluency [--model ultra] [--strategy hybrid] [--limit N]
///   murmur-eval notes [--model ultra] [--limit N]
///   murmur-eval voicelab [--dir path] [--model v2|ultra] [--strategy rules|hybrid] [--dictionary terms.json] [--gate3]
///   murmur-eval vocab --dir <voicelab session dir> [--terms "Priya,Siobhan,…"] [--distractors N]
///   murmur-eval confidence-calibrate [--datasets librispeech-other,commonvoice-spontaneous] [--model v2|ultra] [--limit N]
///   murmur-eval streaming --dataset <name|dir> [--lengths 30,60,120,300] [--model v2|ultra] [--seed 42] [--limit N]
///   murmur-eval judge --golden <file[,file]> [--strategy rules|hybrid] [--include-voicelab] [--limit N] [--report path]
///       [--backend jev|claude|codex|both] [--level clean|polished] [--sample all|fails+N] [--lm-backend apple|none]
///   murmur-eval judge calibrate [--build-set [--seed 7]] [--jev-calls 300] [--codex-calls 60] [--skip-codex]
///     (judge calibration on the dev sets — see Evals/JUDGES.md)
///   murmur-eval diarize [--dataset ami|voxconverse] [--config sdm|ihm] [--meetings N] [--collar 0.25]
///   murmur-eval diarize --dataset ami --two-channel [--meetings N] [--collar 0.25]
///     (simulates mic+system-audio using AMI per-speaker headset audio; informational only)
///   murmur-eval diarize-bakeoff --diarizer legacy|community1|nemotron-offline|nemotron-fast128|nemotron-fast32
///     --dataset ami-sdm|ami-sdm-dev|voxconverse-test|notsofar-sc [--files N] [--data-dir DIR] [--threshold F]
///     (one diarizer on one public set; scripts/diarizer-bakeoff.sh runs them all)
///   murmur-eval timing [--minutes 10] [--chunk-seconds 30] [--model v2|ultra]
///   murmur-eval accent [--models v2,v3,ultra,ultra+guard] [--limit 300] [--top-errors 30]
///     (Indian-accented English WER vs a US-English control, on EdAcc — see AccentRunner.swift;
///      `ultra+guard` is the app's English-only default: Ultra with the v2 drift fallback)
///   murmur-eval us-english bench|parity|dictation|normalize …
///     (US English WER on the Open ASR Leaderboard sets with the Whisper normaliser, EdAcc accent
///      parity, and the 120-paragraph US dictation proxy — see USEnglishRunner.swift and
///      docs/product/US-ENGLISH-ACCURACY.md)
///   murmur-eval challenge [--model ultra] [--guard] [--limit 60]
///   murmur-eval mics [--datasets librispeech-clean,commonvoice-spontaneous] [--limit 100] [--model ultra+guard]
///       [--max-seconds 40] [--data <folder>] [--ffmpeg <path>] [--only <group or text>] [--out report.json]
///     (public speech through simulated microphones: levels, Bluetooth call mode and codecs, a headset
///      noise gate, added noise, clipping; WER, gate rejections and empty results per condition.
///      Measurement only; see MicConditionsRunner.swift)
///   murmur-eval drift-probe [--models v2,ultra,ultra+guard] [--limit 50] [--outputs path]
///     (1–3 word utterances across `say` voices: non-English outputs and the guard's fallback rate)
///   murmur-eval fallback-contention [--dataset librispeech-clean] [--limit 30] [--data <folder>]
///     (does loading the fallback recogniser in the background slow a recognition? Measurement only;
///      see FallbackContentionRunner.swift)
///   murmur-eval voice-trace [--local-dir path] [--dataset a,b] [--no-web] [--direct]
///       [--model ultra+guard] [--limit 10] [--report path]
///   murmur-eval voice-trace score-lines --lines results.txt [--local-dir path | --dataset a,b]
///       [--limit N] [--report path]
///     (voice trace: (a) --direct parakeet-direct scale path, (b) default mock-mic seam,
///      (c) founder-run acoustic loopback via scripts/acoustic-loopback.sh + score-lines —
///      per-clip traces + per-corpus aggregates; local founder pairs are the PRIMARY
///      corpus, web clips breadth only — see Evals/README.md; standalone, never in run-evals.sh)
///   murmur-eval asr-paired prepare --cases <dev.json> --out-dir <scratch>
///   murmur-eval asr-paired compare --manifest <file> --candidate-results <JSONL>
///       [--model ultra+guard] --backend <explicit local cleanup backend> --report <json>
///     (paired candidate / Parakeet ASR comparison on identical prepared WAVs)
///   murmur-eval multilang wer [--languages es,fr,de,it] [--models v2,v3,ultra] [--limit 25]
///   murmur-eval multilang cleanup [--golden path] [--min-preserved 0.99]
///   murmur-eval modes [--golden Evals/modes-golden.json] [--min-pass 0.NN] [--report path]
///   murmur-eval voice-edit [--cases Evals/voice-edit-dev.jsonl] --out <file.jsonl> (voice edit of a selection)
///   murmur-eval context [--golden Evals/context-golden.json] [--min-pass 0.NN] [--report path]
///   murmur-eval code [--golden Evals/code-golden.json] [--min-pass 0.NN] [--report path.json]
///   murmur-eval code-context [--cases Evals/code-context-dev.jsonl] [--level default|clean|polished] [--bundle <id>] [--text] [--report path.json]
///     (Task 143: prose and dictated code spoken into a code app, through the app's own settings; invented text only)
///   murmur-eval actions [--dataset Evals/actions-golden.json] [--limit N] [--report path]
///   murmur-eval tools [--dataset Evals/actions-tools-dev.json] [--backend apple|mlx|none] [--mode extractor|catalog]
///                     [--limit N] [--category name] [--judge jev] [--show N] [--report path.json] [--print-catalog]
///   murmur-eval tools --heldout <path>   (orchestrator only: the sealed actions held-out set; aggregates only)
///     (voice-actions / tool-calling eval, tools-v1 — see Sources/murmur-eval/ToolEval/ToolsRunner.swift)
///
/// Sealed held-out sets (`actions-heldout*`, `heldout-v2*`, or any file with a sealed set's
/// SHA-256) are refused as an argument to every command except `tools --heldout`
/// (`SealedEvalGuard`; see .claude/AGENTS.md).
///   murmur-eval discard-audit --golden <dev.json> [--level clean|polished] [--strategy hybrid|model] [--report path]
///     (Task 110: Jev v2 grades each answer a guard threw away; eval-only, dev text only)
///   murmur-eval ceiling-probe
///   murmur-eval live-shape --cases <file.jsonl> [--arm single|chain] [--path release|prewarmed|rules|both] [--tone refined] [--text]
///   murmur-eval long-dictation --cases Evals/long-dictation-dev.jsonl [--path release|prewarmed] [--tone refined] [--second-opinion]
///       [--neighbour-context] [--whole-dictation-words N] [--paragraph-breaks] [--group-contract] [--double] [--report path.json] [--text]
///     (Task 142: whole-dictation faults by kind and meaning faults, per 100 spoken words; see LongDictationScorer.swift)
///   murmur-eval second-pass --mlx-model <dir> --out <dir> [--plan live:on,replay:on,replay:off,replay:1000,live:off,…]
///       [--sets long,live,long2] [--setting refined|casual|professional|as-spoken|clean] [--path release|prewarmed]
///     (how often the second cleanup pass runs, what it does to the text, what it costs; see SecondPass/SecondPassRunner.swift)
///   murmur-eval early-text --out <dir> [--sets long,live,long2] [--voice Samantha] [--rate 150]
///     (speaks the dev dictations and records what the recogniser has while they are spoken; writes events.json)
///   murmur-eval early-clean --out <dir> (--events <events.json> | --sets long,live) --mlx-model <dir>
///     [--arms ref,legacy,early:prefix:1] [--first 10] [--stretch 0] [--dry]
///     (wait after the key release with and without cleaning groups while speaking; text compared with ref)
///   murmur-eval live-shape [--tone professional] [--bundle <id>] [--text]
///   murmur-eval rewrite-check --cases <file.jsonl> --out <file.jsonl> [--tone refined] [--bundle <id>] [--no-rewrite-check]
///       (invented cases through the app's cleanup path: is what is delivered a rewrite of what was said?)
///   murmur-eval rewrite-check --pairs <file>[,<file>…] --out <file.jsonl>   (how many wanted rewrites in the dev sets the check refuses)
///   murmur-eval answer-check --cases <file.jsonl> --runs <intent-app output> --out <file.jsonl> [--register professional|casual|prompt]
///       (replays the whole-transcript checks on the model answers a run saved: guard verdict, lost content words, added negations)
///     (Task 110: the worst wait after key release when the model never answers; scripted model, invented text)
///     `--show-rejected` prints the model's answers that a check threw away, as text. Use it on invented cases only and
///     never on real dictations: it puts the dictated words on the screen and in any log of the run.
///   murmur-eval grammar [--golden Evals/grammar-golden.json] [--strategy hybrid] [--split tune|holdout|all] [--min-pass 0.NN] [--report path]
///   murmur-eval reformat [--level clean|polished|both] [--min-pass 0.NN] [--report path] [--judge]
///                        [--prewarm] [--via-asr [--model ultra] [--voices Samantha,Daniel,…]]
///     (reformat eval, Evals/reformat-golden.json — the dictation-robustness dev set since
///     2026-09-26; --via-asr speaks each case with `say` and runs Parakeet + cleanup)
///   murmur-eval release-latency [--level clean|polished|both] [--wps 2.5] [--lag 2] [--repeats N]
///     (real-time streaming-prewarm simulation of 60 s / 100 s dictations; after-release cleanup time)
///   murmur-eval finetune prompt|prepare|jev|llm|export …  (M7 fine-tune data pipeline — see
///     scripts/finetune and docs/product/FINETUNE.md; `--mlx-prompt compact` runs a fine-tuned
///     model with its short prompt)
///   murmur-eval meeting [--digest legacy|auto|map-reduce|single-pass] [--chunk-words N] [--plain] [--only m01,m09] [--out path.json]
///     (long-meeting digest eval, Evals/meeting-eval — action items, decisions, corrections, position
///      bias and latency over 12 synthetic 20–70 min meetings; eval-only data, never train on it)
///   murmur-eval meeting --heldout <path> [--app-path|--plain] (orchestrator only: the sealed meeting set, aggregates only)
///   murmur-eval meeting-jev label=run.json[,…]   (Jev second opinion on those digests: unsupported content, coverage)
///   murmur-eval external list|import <name>|<name> [--split test] [--sample N] [--oracle gold|identity] [--report path]
///     (public disfluency-removal sets — disfluencyspeech, disflqa — scored with the DRES metric,
///      arXiv 2509.20321, plus Hushy's guards; see docs/product/EXTERNAL-BENCHMARKS.md)
///   murmur-eval try "<text>" [--level clean|polished] [--raw-model]
///     (debug: rules draft, final output, model use/rejection for one string)
///   murmur-eval head-to-head template --out <dir> [--count 100] [--other-name "Wispr Flow"]
///   murmur-eval head-to-head record --out <dir> [--count 100]   (founder's own 100-paragraph recording)
///   murmur-eval head-to-head play --audio-dir <dir> --device "BlackHole" --out <filled.md>
///     (plays the same recording into a virtual mic; see docs/guide/HEAD-TO-HEAD-VIRTUAL-MIC.md)
///   murmur-eval head-to-head build --hushy <filled.md> --other <filled.md> --out pairs.json [--audio-dir dir]
///   murmur-eval head-to-head --pairs pairs.json [--seed 42] [--form review.html] [--votes a.json,b.json]
///       [--report path] [--no-judge] [--judge-calls 60] [--judge-model gpt-6-luna]
///     (gate 12 blind harness — see docs/guide/RECORDING-SESSION.md; report-only)
///
/// Data lives in Evals/data (gitignored). Reports print to stdout and are appended to
/// Evals/results.md so runs can be compared over time.
@main
struct Eval {
    static let usage = "usage: murmur-eval download|import-commonvoice|asr|asr-paired|accent|us-english|analyze|cleanup|cleanup-trace|grammar-verify|grammar-proposal|e2e|disfluency|notes|voicelab|style|dev-messages|tones|confidence-calibrate|streaming|judge|timing|diarize|diarize-bakeoff|voice-match|multilang|modes|context|code|learn|learn-timelines|lexicon|actions|tools|grammar|reformat|release-latency|try|head-to-head|external|voice-trace|intent-run|intent-app|agent-prompts|model-diag|memory-probe|vocab-real-boost …  (see Eval.swift)"

    static func main() async {
        let args = Arguments(CommandLine.arguments.dropFirst())
        // A help request never starts a run: subcommands ignore flags they do not know, so
        // `voice-trace --help` used to begin a default run and fetch a dataset.
        if args.wantsHelp {
            print(usage)
            return
        }
        do {
            try args.refuseSealedPaths()
            if args.command == "cleanup-trace", !["none", "apple", "mlx"].contains(args.string("backend") ?? "") {
                throw NSError(domain: "cleanup-trace", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "cleanup-trace requires an explicit --backend none|apple|mlx; fallback and remote backends are not allowed",
                ])
            }
            LanguageModels.current = try args.languageModel()
            if let remote = LanguageModels.current as? RemoteLanguageModel {
                let served = try await remote.connect()
                FileHandle.standardError.write(Data("backend remote: \(served) at \(remote.configuration.baseURL.absoluteString) (prompt \(remote.configuration.promptProfile.rawValue))\n".utf8))
            }
            defer { Self.reportRemoteStats() }
            switch args.command {
            case "download": try await download(args)
            case "import-commonvoice": try await CommonVoiceImport.run(args)
            case "asr": try await Runners.asr(args)
            case "analyze": try await Analyze.run(args)
            case "cleanup": try await Runners.cleanup(args)
            case "cleanup-trace": try await CleanupTraceRunner.run(args)
            case "grammar-verify": try await GrammarVerifierStressRunner.run(args)
            case "grammar-proposal": try await GrammarProposalRunner.run(args)
            case "e2e": try await Runners.endToEnd(args)
            case "disfluency": try await Runners.disfluency(args)
            case "notes": try await Runners.notes(args)
            case "challenge": try await Runners.challenge(args)
            case "mics": try await MicConditionsRunner.run(args)
            case "whisper": try await Runners.whisper(args)
            case "voicelab": try await Runners.voicelab(args)
            case "style": try await StyleRunner.run(args)
            case "vocab": try await Runners.vocab(args)
            case "address-probe": try await AddressProbeRunner.run(args)
            case "address-stages": try await AddressStagesRunner.run(args)
            case "appnames": try await AppNamesRunner.run(args)
            case "lexicon-pack": try await LexiconPackRunner.run(args)
            case "confidence-calibrate": try await ConfidenceCalibration.run(args)
            case "streaming": try await StreamingRunner.run(args)
            case "judge": try await JudgeRunner.run(args)
            case "timing": try await TimingRunner.run(args)
            case "diarize": try await DiarizeRunner.run(args)
            case "diarize-bakeoff": try await DiarizeBakeoffRunner.run(args)
            case "voice-match": try await VoiceMatchRunner.run(args)
            case "accent": try await AccentRunner.run(args)
            case "us-english": try await USEnglishRunner.run(args)
            case "drift-probe": try await DriftProbeRunner.run(args)
            case "fallback-contention": try await FallbackContentionRunner.run(args)
            case "voice-trace": try await VoiceTraceRunner.run(args)
            case "empty-triage": try await EmptyTriageRunner.run(args)
            case "asr-paired": try await ASRPairedRunner.run(args)
            case "multilang": try await MultilangRunner.run(args)
            case "modes": try await ModesRunner.run(args)
            case "voice-edit": try await VoiceEditRunner.run(args)
            case "context": try await ContextRunner.run(args)
            case "context-loss": try await ContextLossRunner.run(args)
            case "common-words": try await CommonWordsRunner.run(args)
            case "vocab-real-boost": try await VocabRealBoostRunner.run(args)
            case "dev-messages": try await DevMessagesRunner.run(args)
            case "tones": try await TonesRunner.run(args)
            case "code": try await CodeRunner.run(args)
            case "code-context": try await CodeContextRunner.run(args)
            case "learn": try await LearnRunner.run(args)
            case "learn-timelines": try await LearnTimelines.run(args)
            case "lexicon": try await LexiconRunner.run(args)
            case "actions": try await ActionsRunner.run(args)
            case "tools": try await ToolsRunner.run(args)
            case "ask": try await AskRunner.run(args)
            case "memory": try await MemoryRunner.run(args)
            case "grammar": try await GrammarRunner.run(args)
            case "discard-audit": try await DiscardAuditRunner.run(args)
            case "ceiling-probe": try await CeilingProbe.run(args)
            case "live-shape": try await LiveShapeRunner.run(args)
            case "rewrite-check": try await RewriteCheckRunner.run(args)
            case "answer-check": try await AnswerCheckRunner.run(args)
            case "long-dictation": try await LongDictationRunner.run(args)
            case "second-pass": try await SecondPassRunner.run(args)
            case "early-text": try await EarlyTextRunner.run(args)
            case "early-clean": try await EarlyCleanRunner.run(args)
            case "model-diag": try await ModelDiagnostic.run(args)
            case "reformat": try await ReformatRunner.run(args)
            case "try": try await ModelDiagnostic.tryText(args)
            case "release-latency": try await ReleaseLatencyRunner.run(args)
            case "release-paste": try await ReleasePasteRunner.run(args)
            case "wait-latency": try await WaitLatencyRunner.run(args)
            case "head-to-head": try await HeadToHeadRunner.run(args)
            case "finetune": try await FinetuneRunner.run(args)
            case "local-model": try await LocalModelRunner.run(args)
            case "intent-run": try await IntentRunner.run(args)
            case "intent-app": try await IntentAppRunner.run(args)
            case "draft-accept": try await DraftAcceptRunner.run(args)
            case "agent-prompts": try await AgentPromptsRunner.run(args)
            case "memory-probe": try await MemoryProbe.run(args)
            case "sealed-parity": try await SealedParity.run(args)
            case "residency-probe": try await ResidencyProbe.run(args)
            case "meeting": try await MeetingRunner.run(args)
            case "prefill-yield": try await PrefillYieldProbe.run(args)
            case "meeting-jev": try await MeetingJevJudge.run(args)
            case "external": try await ExternalRunner.run(args)
            default:
                print(usage)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    /// One stderr line with the remote backend's totals (calls, failures, mean wall time, tokens).
    static func reportRemoteStats() {
        guard let remote = LanguageModels.current as? RemoteLanguageModel else { return }
        let stats = remote.stats
        let mean = stats.successes > 0 ? Int(stats.milliseconds / Double(stats.successes)) : 0
        FileHandle.standardError.write(Data(("remote stats: \(stats.calls) calls, \(stats.successes) ok, \(stats.failures) failed, "
            + "\(stats.cancellations) cancelled, mean \(mean) ms, tokens \(stats.promptTokens) in / \(stats.completionTokens) out\n").utf8))
    }

    static func download(_ args: Arguments) async throws {
        let targets: [Dataset] = args.positional.first.flatMap(Dataset.init(rawValue:)).map { [$0] }
            ?? Dataset.allCases.filter { !$0.isOptIn }
        for dataset in targets {
            print("Downloading \(dataset.summary)")
            do {
                let result = try await Downloader.download(
                    dataset, limit: args.int("limit") ?? 200, perGroup: args.int("per-group"),
                    seed: UInt64(args.int("seed") ?? 42), root: Paths.data)
                print("  \(result.statusLine)")
            } catch {
                print("  skipped: \(error.localizedDescription)")
            }
        }
    }
}

struct Arguments {
    let command: String
    let positional: [String]
    private let options: [String: String]
    private let flags: Set<String>

    init(_ raw: ArraySlice<String>) {
        var positional: [String] = []
        var options: [String: String] = [:]
        var flags: Set<String> = []
        let items = Array(raw)
        var index = items.startIndex
        var command = ""
        while index < items.endIndex {
            let item = items[index]
            if item.hasPrefix("--") {
                let key = String(item.dropFirst(2))
                let next = index + 1 < items.endIndex ? items[index + 1] : nil
                // A `--key` immediately followed by another `--flag` or nothing is a bare
                // boolean flag (e.g. `--two-channel`), not a `--key value` pair — this keeps
                // existing `--key value` parsing unchanged while letting a flag with no value
                // sit anywhere in the argument list, including before other `--key value` pairs.
                if let next, !next.hasPrefix("--") {
                    options[key] = next
                    index += 2
                } else {
                    flags.insert(key)
                    index += 1
                }
            } else if command.isEmpty {
                command = item
                index += 1
            } else {
                positional.append(item)
                index += 1
            }
        }
        self.command = command
        self.positional = positional
        self.options = options
        self.flags = flags
    }

    func string(_ key: String) -> String? { options[key] }

    /// Throws if any argument names a sealed held-out set (by name or by content), except the
    /// orchestrator's `tools --heldout <path>` and `meeting --heldout <path>`. Comma-separated values are checked item by item.
    func refuseSealedPaths() throws {
        let allowed: Set<String> = ["tools", "meeting"].contains(command) ? ["heldout"] : []
        let values = options.filter { !allowed.contains($0.key) }.map(\.value) + positional
        for value in values.flatMap({ $0.split(separator: ",").map(String.init) }) {
            try SealedEvalGuard.assertTuningSafe(URL(fileURLWithPath: value), purpose: "murmur-eval \(command)")
        }
    }
    func int(_ key: String) -> Int? { options[key].flatMap(Int.init) }
    /// Whether `--key` was passed as a bare boolean flag (no following value), e.g.
    /// `--two-channel`.
    func flag(_ key: String) -> Bool { flags.contains(key) }

    /// True for `--help` anywhere, or a bare `-h` that is not the value of another option.
    var wantsHelp: Bool {
        flags.contains("help") || options["help"] != nil || command == "-h" || positional.contains("-h")
    }

    var model: AsrModelVersion {
        switch options["model"] ?? "ultra" {
        case "v3": .v3
        case "v2": .v2
        case "redux": .redux
        default: .ultra
        }
    }

    var modelName: String { options["model"] ?? "ultra" }

    var strategy: SmartCleaner.Strategy {
        SmartCleaner.Strategy(rawValue: options["strategy"] ?? "hybrid") ?? .hybrid
    }

    /// `--clean-gate heuristic|always`: whether Clean (`.hybrid`) asks the model only when
    /// `ModelHints.worthAsking` fires (the shipping default) or on every English dictation. An
    /// experiment flag for the dev sets — see `SmartCleaner.CleanGate`.
    var cleanGate: SmartCleaner.CleanGate {
        SmartCleaner.CleanGate(rawValue: options["clean-gate"] ?? "heuristic") ?? .heuristic
    }

    /// `--backend apple|none|mlx|mlx+apple`: the process-wide `LanguageModel` (set once in `main`,
    /// before any runner builds a cleaner). Default `apple`, the shipping backend.
    ///
    /// `judge` already uses `--backend` for the judge (jev|claude|codex|both), so for that
    /// command the cleanup model comes from `--lm-backend` instead (same rule as on main).
    func languageModel() throws -> any LanguageModel {
        let key = command == "judge" ? "lm-backend" : "backend"
        switch options[key] ?? "apple" {
        case "apple": return AppleFoundationModel()
        // Before 2026-09-27: guided generation, default guardrails, for every call (A/B only).
        case "apple-guided": return AppleFoundationModel(permissiveTextTransforms: false)
        case "none": return NullLanguageModel()
        case "mlx": return try mlxModel()
        case "mlx+apple": return FallbackLanguageModel(primary: try mlxModel(), secondary: AppleFoundationModel())
        case "local": return try localModel()
        case "remote": return try remoteModel()
        case let other:
            throw NSError(domain: "murmur-eval", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "unknown --backend \(other) (expected apple|apple-guided|none|mlx|mlx+apple|local|remote)",
            ])
        }
    }

    /// The registry entry `--local-model` names, or this Mac's RAM-tier recommendation.
    /// `--speculate on|off`: prompt-lookup speculation for the local model, overriding its registry entry
    /// (measurement only). nil keeps the entry's own flag, which is what the app runs.
    func speculationOverride() throws -> Bool? {
        guard let value = options["speculate"] else { return nil }
        switch value {
        case "on": return true
        case "off": return false
        default: throw EvalError.missing("--speculate must be on or off")
        }
    }

    /// `--speculate-draft N [--speculate-ngram K]`: the most draft tokens per pass (measurement only); nil keeps the default.
    func speculationTuning() -> SpeculationSettings? {
        guard let draft = int("speculate-draft") else { return nil }
        return SpeculationSettings(maxDraftTokens: draft, maxNgram: int("speculate-ngram") ?? 3)
    }

    func localModelEntry() throws -> LocalModelEntry {
        guard let id = options["local-model"] else { return ModelTierPolicy.recommended(for: .current()) }
        guard let entry = ModelRegistry.entry(id: id) else {
            throw NSError(domain: "murmur-eval", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "unknown --local-model \(id) (expected \(ModelRegistry.entries.map(\.id).joined(separator: "|")))",
            ])
        }
        return entry
    }

    /// `--backend local`: exactly what the app runs for "Hushy local model" — `LocalCleanupBackend`
    /// (speculation on, the entry's prompt profile, residency policy) in front of Apple FM.
    func localModel() throws -> any LanguageModel {
        let entry = try localModelEntry()
        let directory = options["mlx-model"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? ModelRegistry.directory(for: entry)
        if options["mlx-model"] == nil, !ManagedAssetInstaller.isInstalled(entry.files, in: directory) {
            throw NSError(domain: "murmur-eval", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(entry.id) is not installed at \(directory.path) (murmur-eval local-model fetch)",
            ])
        }
        let machine = MachineProfile.current()
        let chain = LocalCleanupBackend.chain(
            entry: entry, directory: directory, fallback: AppleFoundationModel(),
            idleSeconds: ModelTierPolicy.idleUnloadSeconds(for: machine), callLog: ModelCallLog())
        if case .unavailable(let reason) = chain.mlx.availability {
            throw NSError(domain: "murmur-eval", code: 2, userInfo: [NSLocalizedDescriptionKey: "local backend unavailable: \(reason)"])
        }
        FileHandle.standardError.write(Data("backend local: \(entry.id) (\(entry.displayName)) from \(directory.path), speculation on, → apple-fm\n".utf8))
        return chain.model
    }

    /// The MLX backend: `--mlx-model <dir>` or $HUSHY_MLX_MODEL_DIR; `--mlx-kv-bits 4|8` quantizes
    /// cached prefixes; `--mlx-no-prefix-cache` measures without the prefix cache;
    /// `--mlx-prompt production|compact|compact-v3|compact-context|compact-paragraphs` picks the system prompt (`PromptProfile`).
    func mlxModel() throws -> MLXLanguageModel {
        var environment = ProcessInfo.processInfo.environment
        if let directory = options["mlx-model"] { environment["HUSHY_MLX_MODEL_DIR"] = directory }
        if let bits = options["mlx-kv-bits"] { environment["HUSHY_MLX_KV_BITS"] = bits }
        // `--mlx-speculate on|off|<max draft>`: prompt-lookup speculative decoding (same output).
        if let speculate = options["mlx-speculate"] { environment["HUSHY_MLX_SPECULATE"] = speculate }
        // `--mlx-tool-grammar strict|aware|flat|tool-first`: tools-v1 envelope grammar (`ToolEnvelopeGrammar`).
        if let grammar = options["mlx-tool-grammar"] { environment["HUSHY_MLX_TOOL_GRAMMAR"] = grammar }
        // `--mlx-adapter <peft dir>` (SPIKE, FINETUNE.md §3.32): a LoRA adapter applied unfused on the 4-bit model.
        if let adapter = options["mlx-adapter"] { environment["HUSHY_MLX_ADAPTER_DIR"] = adapter }
        if let scope = options["mlx-adapter-scope"] { environment["HUSHY_MLX_ADAPTER_SCOPE"] = scope }
        guard var configuration = MLXLanguageModel.Configuration.fromEnvironment(environment) else {
            throw NSError(domain: "murmur-eval", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "--backend mlx needs --mlx-model <dir> or HUSHY_MLX_MODEL_DIR",
            ])
        }
        configuration.usePrefixCache = !flag("mlx-no-prefix-cache")
        // `--mlx-prompt compact` = a model fine-tuned on `CompactCleanupPrompt` (scripts/finetune).
        if let raw = options["mlx-prompt"] ?? (command == "cleanup-trace" ? "production" : nil) {
            guard let profile = MLXLanguageModel.PromptProfile(rawValue: raw) else {
                throw NSError(domain: "murmur-eval", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "unknown --mlx-prompt \(raw) (expected production|compact|compact-v3|compact-v4|compact-v4-polished-bridge)",
                ])
            }
            configuration.promptProfile = profile
        }
        let model = MLXLanguageModel(configuration: configuration)
        if case .unavailable(let reason) = model.availability {
            throw NSError(domain: "murmur-eval", code: 2, userInfo: [NSLocalizedDescriptionKey: "MLX backend unavailable: \(reason)"])
        }
        return model
    }

    /// `--backend remote` (eval-only): `--remote-url` or $HUSHY_REMOTE_URL (loopback, a Tailscale IP,
    /// or `<machine>.<tailnet>` with `--remote-tailnet`/$HUSHY_REMOTE_TAILNET — `RemoteAddressPolicy`),
    /// `--remote-model` or $HUSHY_REMOTE_MODEL (default: the server's only model), the API key from
    /// $HUSHY_REMOTE_API_KEY or the mode-600 file `--remote-api-key-file` (default
    /// ~/.config/hushy/gpu-serve-api-key, from scripts/gpu/fetch-api-key.sh); the prompt
    /// profile and tool grammar come from `--mlx-prompt` / `--mlx-tool-grammar`, as for `mlx`.
    func remoteModel() throws -> RemoteLanguageModel {
        var environment = ProcessInfo.processInfo.environment
        if let url = options["remote-url"] { environment["HUSHY_REMOTE_URL"] = url }
        if let model = options["remote-model"] { environment["HUSHY_REMOTE_MODEL"] = model }
        if let tailnet = options["remote-tailnet"] { environment["HUSHY_REMOTE_TAILNET"] = tailnet }
        if let keyFile = options["remote-api-key-file"] { environment["HUSHY_REMOTE_API_KEY_FILE"] = keyFile }
        if let grammar = options["mlx-tool-grammar"] { environment["HUSHY_MLX_TOOL_GRAMMAR"] = grammar }
        if let raw = options["mlx-prompt"] {
            guard MLXLanguageModel.PromptProfile(rawValue: raw) != nil else {
                throw NSError(domain: "murmur-eval", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "unknown --mlx-prompt \(raw) (expected production|compact|compact-v3|compact-v4|compact-v4-polished-bridge)",
                ])
            }
            environment["HUSHY_MLX_PROMPT_PROFILE"] = raw
        }
        guard var configuration = try RemoteLanguageModel.Configuration.fromEnvironment(environment) else {
            throw NSError(domain: "murmur-eval", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "--backend remote needs --remote-url http://<box>:8008 or HUSHY_REMOTE_URL",
            ])
        }
        // `--remote-debug`: server error bodies (which can quote dev-set text) go to mode-600 files
        // in the eval run directory instead of nowhere; error messages never carry them.
        if flag("remote-debug") {
            let home = ProcessInfo.processInfo.environment["MURMUR_EVAL_HOME"] ?? FileManager.default.currentDirectoryPath + "/.build"
            configuration.debugDirectory = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("remote-debug")
        }
        return RemoteLanguageModel(configuration: configuration)
    }

    /// The cleaner every runner should use, so `--clean-gate` reaches each of them the same way.
    ///
    /// `--budget-ms N` (eval-only) gives every model call the same N ms budget instead of the
    /// shipping 2.4/3.0/3.5/4.0 s tiers — for *quality* A/Bs on a loaded machine, where Apple FM
    /// calls otherwise time out and the rules fallback gets scored as the model's answer. Never
    /// use it for latency numbers.
    func makeCleaner(retainsRejectedCandidates: Bool = false) -> SmartCleaner {
        if string("instruction-suffix") == "keep-list" { SmartCleaner.instructionSuffix.withLock { $0 = SmartCleaner.keepListSuffix } }
        let repairs = !flag("no-span-repair")
        let asksAgain = !flag("no-guided-retry")
        // `--retry-model second` sends the guided second ask to the second-opinion model instead of the first.
        let retriesOnSecond = string("retry-model") == "second"
        // `--second-pass-trigger widened` also runs the second pass for the filler markers; the default is the narrower trigger.
        let triggers = Set((string("second-pass-trigger") ?? "").split(separator: ",").map(String.init))
        let widenedSecondPass = triggers.contains("widened")
        // `repeat` also runs it for an opening said twice and asks for the join; combine as `widened,repeat`.
        let repeatSecondPass = triggers.contains("repeat")

        // `--second-opinion` asks Apple's model about leftover filler after the first model (Task 130).
        let second: (any LanguageModel)? = flag("second-opinion") ? AppleFoundationModel() : nil
        // Task 142 experiments, all off unless named: `--neighbour-context` (each group's call also gets the words on each
        // side as read-only context), `--whole-dictation-words N` (a dictation of at most N words is one model call),
        // `--paragraph-breaks` (blank lines between paragraphs are not rejected as added structure).
        let neighbours = flag("neighbour-context")
        let wholeLimit = int("whole-dictation-words").flatMap { $0 > 0 ? $0 : nil }
        let paragraphs = flag("paragraph-breaks")
        let groupContract = flag("group-contract")
        guard let ms = int("budget-ms"), ms > 0 else {
            return SmartCleaner(
                cleanGate: cleanGate, retainsRejectedCandidates: retainsRejectedCandidates, repairsSpans: repairs,
                asksAgain: asksAgain, retriesOnSecondOpinion: retriesOnSecond, widenedSecondPass: widenedSecondPass, repeatSecondPass: repeatSecondPass,
                neighbourContext: neighbours, wholeDictationLimit: wholeLimit, allowsParagraphBreaks: paragraphs, groupContract: groupContract, secondOpinion: second)
        }
        let budget = Duration.milliseconds(ms)
        return SmartCleaner(
            budget: budget, correctionBudget: budget, polishedBudget: budget, segmentBudget: budget, cleanGate: cleanGate,
            retainsRejectedCandidates: retainsRejectedCandidates, repairsSpans: repairs, asksAgain: asksAgain,
            retriesOnSecondOpinion: retriesOnSecond, widenedSecondPass: widenedSecondPass, repeatSecondPass: repeatSecondPass,
            neighbourContext: neighbours, wholeDictationLimit: wholeLimit, allowsParagraphBreaks: paragraphs, groupContract: groupContract, secondOpinion: second)
    }

    /// The cleanup level to test against (`.clean` by default, matching `CleanupOptions`'s own
    /// default) — lets `cleanup`/`grammar` exercise `.polished`'s grammar-repair instructions and
    /// permissive guard profile specifically, since `SmartCleaner.cleanOne` derives its
    /// instruction set and `OutputGuard.Profile` from `options.level`, not from `--strategy`
    /// alone (task: grammar-polish, "each cleanup level must do what the UI promises").
    var cleanupLevel: CleanupLevel {
        CleanupLevel(rawValue: options["level"] ?? "clean") ?? .clean
    }

    static let cleanupPromptProfiles = [
        "production", "compact", "compact-v3", "compact-v4", "compact-v4-polished-bridge", "compact-context", "compact-paragraphs", "group-contract",
    ]

    /// Resolve only profiles consumed by the actual backend. A registry-backed local model has
    /// its own pinned profile and cannot currently opt into experimental grammar contracts.
    func cleanGrammarContract() throws -> CleanupOptions.GrammarContract {
        guard !flag("clean-grammar-contract"), !flag("mlx-prompt") else {
            throw EvalError.missing("cleanup contract and prompt flags require explicit values")
        }
        let backend = string(command == "judge" ? "lm-backend" : "backend") ?? "apple"
        let consumesMLXProfile = ["mlx", "mlx+apple", "remote"].contains(backend)
        if string("mlx-prompt") != nil, !consumesMLXProfile {
            throw EvalError.missing("--mlx-prompt applies only to mlx, mlx+apple, or remote backends")
        }
        let selectedPrompt = string("mlx-prompt")
            ?? (consumesMLXProfile && command != "cleanup-trace"
                ? ProcessInfo.processInfo.environment["HUSHY_MLX_PROMPT_PROFILE"] : nil)
            ?? "production"
        guard Self.cleanupPromptProfiles.contains(selectedPrompt) else {
            throw EvalError.missing("unknown --mlx-prompt \(selectedPrompt)")
        }
        let inferred: CleanupOptions.GrammarContract = switch selectedPrompt {
        case "compact-v3": .minimal
        case "compact-v4", "compact-v4-polished-bridge": .generalMinimal
        default: .legacy
        }
        let contract: CleanupOptions.GrammarContract
        if let raw = string("clean-grammar-contract") {
            guard let parsed = CleanupOptions.GrammarContract(rawValue: raw) else {
                throw EvalError.missing("--clean-grammar-contract must be legacy, minimal, or general-minimal")
            }
            contract = parsed
        } else { contract = inferred }
        if selectedPrompt != "production", contract != inferred {
            throw EvalError.missing("--mlx-prompt \(selectedPrompt) requires the \(inferred.rawValue) Clean grammar contract")
        }
        if backend == "local", contract != .legacy {
            throw EvalError.missing("registry-backed local models do not support experimental grammar contracts")
        }
        return contract
    }

    /// Builds the options shared by cleanup, grammar, trace, and one-off text diagnostics.
    /// Per-case context overrides command-wide context flags when supplied.
    func cleanupOptions(
        level: CleanupLevel,
        isCodeContext: Bool? = nil,
        isCasualContext: Bool? = nil,
        detectedLanguage: String? = nil
    ) throws -> CleanupOptions {
        var result = CleanupOptions(
            level: level,
            detectedLanguage: detectedLanguage ?? string("language"),
            isCodeContext: isCodeContext ?? flag("code-context"),
            grammarContract: try cleanGrammarContract())
        result.isCasualContext = isCasualContext ?? flag("casual-context")
        return result
    }
}

/// Used where a `DictationPipeline` is needed only for its `clean`/`transcribeRaw` helpers on
/// already-transcribed text (the `cleanup` command has no audio) and ASR is never actually invoked.
struct NullTranscriber: Transcriber {
    func transcribe(_ samples: [Float]) async throws -> String {
        throw EvalError.missing("NullTranscriber has no audio to transcribe")
    }
}

enum Paths {
    static var root: URL {
        // Evals/ next to Package.swift, found from the current directory.
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MURMUR_EVAL_HOME"]
            ?? FileManager.default.currentDirectoryPath + "/Evals", isDirectory: true)
    }
    static var data: URL { root.appendingPathComponent("data", isDirectory: true) }
    static var golden: URL { root.appendingPathComponent("dictation-golden.json") }
    static var results: URL { root.appendingPathComponent("results.md") }
}
