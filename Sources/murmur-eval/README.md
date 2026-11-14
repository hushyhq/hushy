# murmur-eval

The evaluation harness. See [Evals/README.md](../../Evals/README.md) for datasets, commands and
current results.

| File | Contents |
|---|---|
| `Eval.swift` | Entry point, argument parsing, paths |
| (target `HushyModelsRemote`) | `--backend remote`: eval-only `RemoteLanguageModel` over vLLM on the CUDA box (Tailscale); same prompts/grammar as MLX; never linked by the app (`.claude/GPU-TRAINING.md` §8) |
| `Datasets.swift` | Dataset catalogue and downloader (Hugging Face datasets-server), with checkpoint/resume and backoff |
| `CommonVoiceImport.swift` | `import-commonvoice`: local import of manually-downloaded Common Voice releases (TSV/CSV parsing, MP3→16kHz WAV, balanced sampling) |
| `Recognizers.swift` | Pluggable engines: Parakeet (FluidAudio) and Apple Dictation / SpeechTranscriber |
| `AskRunner.swift` | `ask routing` (deterministic `AskRouter` over `Evals/ask-routing-dev.json`: ask_ai / ask_own / summarize / do / negatives) and `ask grounding` (`OwnStuffAnswerer` over `Evals/ask-grounding-dev.json` fixture sources: cited source, invented items, required items; `--backend apple|none`); both write `--report` JSON for `compare_runs.py` |
| `ToolEval/` | `tools`: the voice-actions / tool-calling eval (tools-v1) — case format + loader (`ToolEvalSet`), tolerance rules (`ToolArgumentMatcher`, `SpokenDuration`), scoring + summary, backends (`extractor` = shipping `ActionExtractor`, `catalog` = `VoiceToolCatalog` envelope + `VoiceToolGuard`; both score Shortcuts against `EvalShortcutLibrary`, a simulated library of the case's expected names + 5 unrelated), Jev second opinion, `--heldout` orchestrator mode |

| `USEnglishRunner.swift`, `USDictationRunner.swift`, `AccentParity.swift` | `us-english bench/dictation/parity/breakdown/spelling/normalize` — US English WER on the Open ASR Leaderboard sets, the TTS dictation proxy, EdAcc accent parity (see docs/product/US-ENGLISH-ACCURACY.md) |
| `WhisperEnglishNormalizer.swift`, `WhisperNumberNormalizer.swift`, `WhisperNumberState.swift` | Port of Whisper's `EnglishTextNormalizer`, verified clip-for-clip against the Python original |
| `WERStats.swift`, `ErrorBreakdown.swift`, `EdAccAccents.swift` | Bootstrap intervals + permutation test; written-form error categories; EdAcc all-accent sampling |
| `Runners.swift` | `asr`, `cleanup`, `e2e`, `disfluency`, `notes`, `challenge`, `whisper` runners and reporting |
| `SecondPass/` | `second-pass`: how often the second cleanup pass runs, what it does and what it costs (live arms, and the same answers replayed with the pass off or under a time budget); tables by `scripts/second-pass-report.py`. Measurement only |
| `EarlyCleanup/` | `early-text` (what the recogniser has while a spoken dev dictation is still going) and `early-clean` (the wait after the key release with and without cleaning groups while speaking, text compared with no early cleaning); tables by `scripts/early-cleanup-report.py` |
| `DiarizerBakeoff/` | `diarize-bakeoff`: one FluidAudio diarizer (legacy, community-1, Nemotron 3 presets) on one public set (AMI-SDM test and dev, NOTSOFAR-1 eval single channel, VoxConverse test); DER at two collars, speaker counts, speed, peak memory, every hypothesis turn in JSON. `scripts/diarizer-bakeoff.sh` runs them all; `scripts/diarizer_bakeoff_table.py` and `scripts/diarizer_attribution.py` make the tables (docs/research/diarizer-bakeoff-2026-11-06.md) |
| `MicConditionsRunner.swift`, `MicSimulation.swift` | `mics`: public speech through simulated microphones (levels, Bluetooth call mode with real mSBC and AAC-ELD passes through `ffmpeg`, a headset noise gate, white, pink and babble noise, clipping), each scored through the speech gate, loudness normalisation and the recogniser. Measurement only; simulations, not device recordings |

## Synthetic supervision diagnostics

| Module | Responsibility |
|---|---|
| `IntentRunner.swift` | `intent-run --model <mlx dir> --cases <jsonl> --system <prompt file> --out <jsonl> [--reference <jsonl>] [--constrained] [--speculate]`: the rewrite-to-intent call through the app's MLX engine in the Python reference runner's layout (greedy, no grammar unless `--constrained`); load time, seconds, tokens per second, peak memory and the count of answers identical to the reference |
| `Finetune/BroadCleanTraining.swift` | Legacy reviewed export plus shared exact preparation/request renderer; historical export behavior unchanged |
| `Finetune/BroadCleanReviewPacket.swift` | `finetune broad-review-packet`: exact model-visible input and prepared targets, separate author annotations, hashes and veto diagnostics |
| `Finetune/BroadCleanSupervisionValidation.swift` | `finetune broad-validate-v2`: digest-bound independent attestations, rejection reasons, reviewed relationship components and diagnostic split manifest |

The new diagnostics are opt-in and write new files under `.build/finetune`. They do not invoke
models, export training examples or approve semantics. See the fine-tuning handbook and
`scripts/finetune/README.md` for the prospective schema; sealed/private/evaluation material is
not synthetic supervision.

## Audio cleanup option parity

`e2e` and `voice-trace` carry validated `--level`, grammar contract, code/casual context,
and language options into `PipelineSettings`, including level/contract-specific prewarming.
Voice-trace uses the same settings for both cleanup arms. Reports include effective
`cleanupSettings`; raw e2e records `applied: false` and constructs no cleanup model.
`score-lines` cannot observe the live app's settings and leaves that metadata unknown.
Voice-trace scores exact spoken-transcript fidelity, not fluent grammar or intent quality.

Synthetic mocked pipeline coverage: `swift test -j 4 --filter AudioCleanupOptionParityTests`.
These tests use no corpus files, recognizer weights, or real language model inference.

When `--strategy` is omitted, audio cleanup uses the production level's strategy:
Verbatim uses rules, Clean uses hybrid, and Polished uses the model. An explicit
`--strategy` overrides that default and is retained in reporting.

Voice-trace's `transcribeTrace` exposes ASR/guard text but does not return word confidences.
Its cleanup pass therefore uses the text-only path without confidence guidance; option parity
does not establish full parity with the app's ASR confidence routing.
