# MurmurCore

The platform-independent engine. No SwiftUI, no AppKit, no event taps: everything here can be
unit-tested (`swift test`) and reused by the app, the MCP server, the eval harness, and future
iOS / other-platform ports.

| Folder | Contents |
|---|---|
| `Cleanup/` | `TextCleaner` (rule pipeline), `VoiceCommands` (scratch that, new line, press enter, fillers), `SelfCorrection` (typed "10, no, 9" corrections), `FrameCorrection` (retarget, head-noun and keep-the-old-value corrections that keep the name or noun), `ListFormatter` (spoken lists → bullets), `SmartCleaner` (rules + Apple Foundation Models with `ModelHints` and `OutputGuard`; note summaries), `ModelHealth` (skip a model that can't answer in time: breaker + key-down probe) and `ModelOutcome` (the log's `why=`), `StyleFormatter` (per-app writing styles), `ExtractiveSummarizer` (fallback summaries), `CleanupOptions` |
| `Personalization/` | `DictionaryEntry`, `Snippet`, `Personalizer` (spellings + expansions); `DictionaryMatcher` + `PhraseAutomaton` (Aho–Corasick, one-pass Dictionary replacement; the regex loop stays as `Personalizer.applyDictionarySequential`) |
| `Learning/` | On-device learn-from-corrections: `CorrectionAlignment` (locate + word-align the dictation in the edited field), `CorrectionClassifier` (ASR term / cleanup over- or under-edit / formatting / rewrite), `CorrectionCapture` + `LearningGate` (privacy and conservatism gates), `Learner` (thresholds, confirm, forget), `LearnedItem` + store API (migration `v14-learned-items`), `LearnedPersonalization` + `PreferenceHints` (feeds Dictionary boosting/replacements/`ProtectedTermGuard`) |
| `Lexicon/` | `WordFrequency` (is this ordinary English); the personal lexicon: `PersonalTerm` + `PersonalLexicon` (one ranked view over History, learned items, kept-as-heard and meeting attendees, 30-day decay) → `LexiconSnapshot.boostTerms` (recogniser vocabulary + protected terms), `LexiconTermShape` (names and identifiers only); domain packs `DomainPack` (bundled JSON in `Packs/`, embedded as `DomainPackData`), `PackMatcher` (Aho–Corasick), `PackActivation` (3 names, 2 days), `PackStateFile`/`PackStateKeeper` (`lexicon-packs.json`), `PackNameGuard`. See `docs/engineering/personal-lexicon.md` |
| `Storage/` | `Models` (`Dictation`, `Note`, `TextStats`), `Store` (GRDB/SQLite, migrations, FTS5 search, retention) |
| `Insights/` | `Insights` (totals, speed, streaks, apps, `AppCategory` incl. browser web-app detection), `EditVerdict` (edit-free rate) |
| `MCP/` | `MCPServer` — JSON-RPC handling for the read-only MCP tools |
| `Export/` | `MarkdownExporter` |
| `Downloads/` | `OnboardingPacing` + `OnboardingFlow` (download-paced onboarding), `ThroughputMeter`/`ETASmoother`/`SpeedBucket`, `DownloadableAsset` + `AssetQueue`, `AssetDownloader` (range resume, SHA-256, backoff), `ChecksumManifest`, `NetworkConditions`/`DownloadGate`/`RetryBackoff`, `ManagedAssetInstaller` (`.files` assets: install/verify/remove), `URLSessionDownloadTransport`, `AuthorizedDownloadTransport` (account token for `models.tryhushy.com` only; `AccountDownloadAuthorizer`) |
| `LanguageModel/` | The `LanguageModel` seam, `FallbackLanguageModel` (MLX → Apple FM → rules), `SwitchableLanguageModel` (backend swapped in place) + `ModelCallLog`/`RecordingLanguageModel` (latency, never text), `ModelRegistry` (pinned, hashed, licensed local models), `ModelTierPolicy` + `MachineProfile` (RAM/chip tier rule), `LocalModelResidency` + `ManagedLocalModel` + `MemoryPressureMonitor` (idle/pressure unload), `CleanupBackendChoice`/`EffectiveCleanupBackend` |
| `Support/` | `AppPaths`, `ChunkSplitter`, `StreamingResampler` + `LoudnessNormalizer`, `EvalMetrics` (WER etc.) |
| `Uninstall/` | "Uninstall Hushy…": `UninstallPlanner` (pure: roots in, exact list of steps out; the export folder is never in it, compared with links followed and letter case folded; a test run gets only its own folder's named files), `UninstallPathPolicy` (plain path, inside an allowed folder, never a link or through one), `UninstallExecutor` (runs exactly the plan over injected file, Keychain, settings, login-item and Trash operations; abandons before any removal if the app will not stop; keeps the encryption key when recordings stay; a failed step is reported and the rest still run), `UninstallStopper` (each stop step has a time limit), `UninstallConfirmation` (Return cancels; needs a measured plan, and a second tick when an export left notes unsaved) |

| `Actions/` | Voice actions: `ActionExtractor` (the model decides intent; no rule vetoes) + `ActionValidator` + `ActionSafetyScreen` (edits refused, installed-Shortcuts-only, destructive/injection screen) + `ActionRecovery` (a named list or calendar that isn't there is refused, and the refusal offers the default on the person's tick) + `DateAnchor` over `RelativeDateParser` with an injected `DateContext` (shipping Apple FM path), connected `propose_*` tools, `SensitiveContentScreen`, and **tool schema v1** (`VoiceToolCatalog`, `ToolCall`) shared by the MLX adapter and `murmur-eval tools` |
| `Support/` | `SealedEvalGuard` (sealed held-out sets: refused by name or hash), `AppPaths`, `ChunkSplitter`, `StreamingResampler` + `LoudnessNormalizer`, `EvalMetrics` (WER etc.) |

Rules of the road:
- Cleanup must never invent words. Prefer "unresolved" over a risky guess; the model pass and
  its guard handle hard cases.
- Styles change formatting only (a test asserts identical words for every style).
- Every behaviour change to cleanup should come with golden cases in `Evals/dictation-golden.json`.
