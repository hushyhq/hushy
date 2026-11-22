# Hushy architecture

This document explains how Hushy is put together and why. Murmur was the project's codename, and
the Swift module and target names below keep it (`Murmur`, `MurmurCore`) so a rename doesn't break
history. It is written so a new contributor can change the code confidently. The user-facing
explanation is at [docs.tryhushy.com](https://docs.tryhushy.com).

## 1. Principles

1. **Local only.** No backend, no account, no telemetry. The network is used once, to download the
   speech model. Anything cloud-based must be opt-in and visibly labelled.
2. **Never lose or garble what the user said.** Rules are conservative; the language model is
   guarded; styles never change words; every utterance lands in History even if pasting fails.
3. **Fast hot path.** Key release → text in the app in ~50–150 ms without the model pass,
   ~500–900 ms with it. Anything not needed to paste happens after the paste.
4. **Measured, not guessed.** Behaviour changes go through `murmur-eval` and the golden sets.

## 2. Targets and processes

| Target | Kind | Depends on | Responsibility |
|---|---|---|---|
| `MurmurCore` | library | GRDB | Everything testable without macOS UI: cleanup, styles, storage, insights, MCP logic, export, metrics |
| `Murmur` | executable (app, ships as Hushy.app) | MurmurCore, FluidAudio | macOS integration and UI |
| `murmur-mcp` | executable | MurmurCore | Read-only MCP stdio server bundled in `Hushy.app/Contents/MacOS`, listed in client configs as "hushy" |
| `murmur-eval` | executable | MurmurCore, FluidAudio, Speech | Evaluation harness |
| `murmur-bench` | executable | FluidAudio | Quick ASR latency benchmark |

At runtime there are only two processes: `Murmur` (always) and `murmur-mcp` (spawned by an AI
client when the user connects one). They share the SQLite database; the app writes, the MCP
server opens it read-only (WAL mode makes that safe).

## 3. The dictation hot path

```
key down ─▶ HotkeyMonitor (CGEventTap, main run loop)
            └─▶ DictationController.begin
                 ├─ TextInserter.exposeAccessibilityOfFrontmostApp()   (Electron apps build their AX tree)
                 ├─ FocusTarget.current()                               (app, AX focus, browser window title)
                 ├─ AudioCapture.start  (AVAudioEngine + Apple voice processing, 16 kHz mono via StreamingResampler)
                 ├─ SmartCleaner.prewarm()  (load Apple's model while the user talks; probe it if ModelHealth is in doubt)
                 └─ pill → .listening (live levels)
key up ───▶ DictationController.finish
            ├─ discard if held < 250 ms or no audio above threshold (pill says so)
            └─ process():
                 1. LoudnessNormalizer.normalize(samples)        (whispers → speaking level)
                 2. SpeechEngine.transcribe                       (Parakeet Ultra on ANE, ~45 ms / 4 s)
                 3. SmartCleaner.clean                            (TextCleaner rules; model only if ModelHints say so)
                 4. applyStyle                                    (StyleFormatter by StyleContext of the target app)
                 5. TextInserter.insert                           (pasteboard + ⌘V; returns immediately)
                 6. pill → .done / .noField card
                 7. persist (off the hot path): WAV + Dictation row
                 8. EditWatcher: 8 s later, kept/edited verdict
```

`LatencyBreakdown` logs speech / cleanup / insert timings for every dictation (Console, subsystem
`app.murmur`).

### Cleanup pipeline (MurmurCore/Cleanup)

1. **TextCleaner** (rules, <1 ms): voice commands (`VoiceCommands`), fillers and stutters,
   typed self-corrections (`SelfCorrection` — numbers, times, days, months, names, repeated
   function-word anchors), lists (`ListFormatter`), punctuation tidy.
   Generic "X, no, Y" is *not* guessed by rules — it is reported as an unresolved cue.
2. **SmartCleaner** decides whether to ask Apple's on-device model (`ModelHints`: unresolved cues,
   correction words, enumerations; always for Polished). The model gets a few-shot prompt, a
   deadline (1.2 s), and its answer goes through `OutputGuard` (no invented words, no growth,
   no mass deletion). Rejected or late → rule output is used. `ModelHealth` skips the call
   outright when recent timeouts or a probe show it can't answer in time (another process using
   the on-device model makes every call take 5–7 s), so the rules text pastes at once instead of
   after the whole budget; the log's `why=` says which (`ModelOutcome`).
3. **Personalizer** applies dictionary spellings and snippet expansions.
4. **StyleFormatter** (app side, after cleanup) applies the per-context style.

### Styles and app detection

`AppCategory.classify(bundleID:windowTitle:)` maps the frontmost app to a category; for browsers
the focused window title identifies web apps (Gmail → email, Slack → work, …).
`StyleContext.from(category)` maps categories to the four style contexts; code editors return
`nil` and are never styled. `StyleContext.representativeApps` (shown on the Style page) is
checked by tests to classify into its own context.

## 4. Notes pipeline

`NoteRecorder` drains both sides every 1 s into the capture journal (`CaptureJournalWriter`: one synced
`hseg1` frame per side per tick, ~30 s segments sealed at a pause, `capture_segment` rows), recognises sealed
segments in order, and watches each side with `CaptureHealth` (stall or exact zeros: rebuild, gap, warning). On stop,
quit or a relaunch after a crash, `FinalizeRunner` takes the note from `note_finalize.step` through sealing,
transcribing, assembling, writing and exporting (handbook: speakers-and-call-audio, "The capture journal").
An imported file goes the same way (`FileTranscriber`: `file` segments, then the runner). Finalize yields to a
dictation (recognition per segment, diarization per 10 s window, summaries cancelled and fed in 128-token chunks on
the shared 4B) and never holds a whole side in memory (`StreamedDiarization` over `CaptureSegmentAudio.windows`). Then `SmartCleaner.summarize` → `NoteSummarizer` (one call when the
transcript fits the model's window, else map-reduce over overlapping pieces with a merge that
applies later corrections; extractive fallback) produces title, summary (key points + "Decided:"
lines) and "Owner: Task — due" action items. Export: Markdown (`MarkdownExporter`) and optionally Apple Notes (`AppleNotesExporter`,
AppleScript).

## 5. Data

SQLite via GRDB (`Store`), WAL, at `~/Library/Application Support/Hushy/murmur.sqlite`
(override with `MURMUR_HOME`). Tables: `dictation` (+ FTS5 `dictation_fts`), `note`
(+ FTS5 `note_fts`), `dictionaryEntry`, `snippet`. Migrations: `v1`, `v2-edit-state`.
Audio: `Audio/<uuid>.wav` (retention setting), `Notes/<id>/seg-NNNNNN-<mic|system|file>.hseg` (legacy notes and imports: `chunk-NNNN.wav`).

The UI never caches copies of data: `Library` holds live arrays fed by GRDB `ValueObservation`,
and user actions go through `Library` methods that log failures.

## 6. App composition (Sources/Murmur/App)

- `AppModel` — composition root and navigation state only.
- `Library` — live data + data actions.
- `SettingsSync` — the single path from `AppSettings` to running services (hotkey, sounds,
  pill, appearance with crossfade, audio retention). Screens only mutate `AppSettings`.
- `PillCoordinator` — the floating `PillPanel` window: size and click-through by state.
- `Snapshots` — `Murmur --snapshots <dir>` renders every page to PNG (scroll views are laid out
  flat via the `isSnapshot` environment value).

## 7. MCP server (the only API)

`murmur-mcp` speaks MCP (protocol 2025-06-18) over newline-delimited JSON-RPC on stdio. Tools:
`search_notes`, `list_notes`, `get_note`, `search_history`, `recent_dictations`, `get_insights`,
plus the propose-only tools `propose_action`, `propose_calendar_invite`, `propose_email_draft`,
`propose_message`, `propose_issue` (`MurmurCore/Actions`; they validate and acknowledge, never
execute — see `docs/product/ASSISTANT-ACTIONS.md`).
All read-only; results frame transcripts as quoted data (prompt-injection defence).
`MCPInstaller` writes client configs (Claude Desktop, Cursor JSON; Codex TOML) after confirmation
and keeps the user's original config as `*.murmur-backup`. Claude Code is configured with a
copyable `claude mcp add` command.

## 8. Concurrency

Swift 6 strict concurrency. UI, controllers and coordinators are `@MainActor`. `SpeechEngine`
and `SmartCleaner` are actors. `AudioCapture` is `@unchecked Sendable` with an
`OSAllocatedUnfairLock` around capture state (audio thread ↔ main). The event tap callback runs
on the main run loop and uses `MainActor.assumeIsolated`.

## 9. Design system

"Graphite & Phosphor" (see `docs/research/competitor-ux.md` §4): tokens in `UI/Theme.swift`
(light/dark dynamic colors, 4 pt spacing, non-uniform radii, spring motion). The pill is always
dark. Page banners use static mesh gradients with grain (`PageBanner`, `BannerBackground`).

## 10. Extending

- **New cleanup rule:** add to `MurmurCore/Cleanup`, add golden cases to
  `Evals/dictation-golden.json`, run `scripts/run-evals.sh --quick`; never regress `plain`/`safety`.
- **New setting:** add to `AppSettings`; if a running service needs it, apply it in
  `SettingsSync.apply()` and include it in `track()`; UI only writes the setting.
- **New screen:** add a case to `AppModel.Section`, a view in `UI/Screens`, the sidebar group in
  `RootView`, and check it with `--snapshots` in light and dark.
- **New platform (iOS/Windows/Android):** MurmurCore is the portable part; see DECISIONS.md.

## Experimental cleanup supervision workflow — October 3, 2026

On `codex/local-asr-evals`, `BroadCleanTraining` shares deterministic preparation and the complete
MLX request renderer with `BroadCleanReviewPacket`. Packets expose exactly what the model sees;
author context/rationale remains separate annotation metadata. `BroadCleanSupervisionValidation`
checks prospective independent input/target attestations and reviewed family/situation components
for diagnostic split isolation. Rejected examples may supply trusted relationship evidence without
becoming eligible training rows.

This is an eval/training-data workflow, not a new dictation runtime/backend. It writes no training
examples, invokes no model, changes no app defaults, and leaves legacy export reproducible.
See `docs/engineering/GRAMMAR-EDIT-PROPOSALS.md` and the fine-tuning handbook for schema, commands
and experimental qualification status. The revised grammar goal remains unmet; the current
whole-text adaptation has no measured useful-repair gain or release approval.
