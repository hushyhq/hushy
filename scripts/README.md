# scripts

| Script | Purpose |
|---|---|
| `build-app.sh [--debug] [--open]` | Builds `build/Hushy.app` (app + `hushy-mcp` helper + resource bundles + icon), signs it (prefers a "Hushy Dev" identity if present, else falls back to "Murmur Dev"), optionally launches it |
| `create-dev-cert.sh [--name "Hushy Dev"]` | Creates a local signing identity ("Murmur Dev" by default; run automatically by `build-app.sh` if neither identity exists) so macOS permissions persist across rebuilds |
| `make-icon.swift` | Renders the app icon into an `.iconset` |
| `sealed_guard.py [--self-test] <path>…` | Refuses sealed held-out eval sets (by name or SHA-256, from `Evals/sealed-sets.json`); every Python data generator / tuning script must call `assert_tuning_safe` on its inputs |
| `gate.sh [--quick\|--full\|--only NAME\|--list]` | The committed project gate (agent-kit): steps `build`, `unit` (a full `swift test` with a temp home, via `gate-swift-test.sh`) and, in the full run, `cleanup` (`gate-cleanup.sh --fail-on-regression`). Prints a pass/fail table, exits non-zero if any step failed; logs in `.gate-logs/` |
| `gate-cleanup.sh [--base REF] [--models intent,v54] [--sets pub,golden,never,probe,misheard,long] [--out DIR] [--fail-on-regression]` | Cleanup gate: builds `murmur-eval` for the base (temporary worktree) and the working tree, runs `intent-app` (intent 2B: public 300, golden, never-answer, misheard, number probe) and `early-clean` (long+live, both models) one at a time through `mac-heavy.sh` under `caffeinate`, scores public 300 with `retrain_public_eval.py`, prints one base-versus-candidate table and writes `changed.md` (every changed text) and `summary.json` in the report folder. Exit 0, or 1 with `--fail-on-regression` if public exact drops, used-model drops or a long dictation goes from cleaned to raw. Uses a temp `HUSHY_HOME`, never sealed sets. Report logic in `gate_cleanup_report.py` |
| `gate-swift-test.sh` | The gate's unit step: full `swift test -j 4` with a throwaway `HUSHY_HOME`, queued behind other heavy Mac jobs |
| `seal-model.sh <plain folder> <new id>` | Seals a model folder's weights into AES-256-GCM part files for upload (`hushy-model-seal`); writes the upload folder, a listing of sizes and SHA-256, and the key to `.secrets/model-keys/<id>.key` (git-ignored, never printed). `--key-file` rebuilds the same files. `docs/engineering/SEALED-MODELS.md` |
| `check-hardening.sh [--app <bundle>] [--entitlements <plist>]` | Fails if the entitlements set `get-task-allow`, `disable-library-validation` or `allow-dyld-environment-variables`, or (with `--app`) the signature lacks the hardened runtime flag; `HardeningTests` runs it |
| `sealed-load-probe.sh [--runs N] [--cold-runs N] [--work DIR]` | Plain 4B against a sealed copy (throwaway key): load time, load peak and the first cleanup call, warm and cold (cold reads copies written with `F_NOCACHE` by `coldcopy.swift`); run it inside one `mac-heavy.sh` slot. `docs/research/model-encryption-2026-11-04.md` |
| `run-evals.sh [--quick]` | Runs the evaluation suite; results appended to `Evals/results.md` |
| `finetune/finetune.sh data / smoke / convert / eval` | Cleanup-model fine-tune (M7): synthetic data + manifest, Mac smoke LoRA, CUDA training (`finetune/cuda/`), 4-bit MLX conversion, dev evals. See `finetune/README.md` and `docs/product/FINETUNE.md` |
| `mock-mic.sh [--report <dir>] [--clips <dir>] [--keep]` | Headless mock-microphone test (debug build only): plays synthetic `say` clips (or your own `clips.json` folder) into BlackHole 2ch and drives Hushy's own `AudioCapture`, dictation path, `NoteRecorder` and remembered-voice code; prints pass/fail/skipped per scenario, writes `mock-mic.json`, exits non-zero on failure (77 = skipped, 4 = mic permission block). Real time, about 5-6 minutes; standalone, not in `run-evals.sh`. See `docs/guide/MOCK-MIC.md` |

Signing: `build-app.sh` uses `MURMUR_SIGN_IDENTITY` if set; otherwise the "Developer ID Application"
identity of team `RY2CM3XV32` from the login keychain (hardened runtime, release entitlements, not
notarized), so Microphone and Accessibility permissions carry over between dev and release builds;
otherwise a local dev certificate, and it prints that permissions will not carry over.
`scripts/test-developer-id.sh` checks the identity choice against invented `security` output.
Release signing: set `MURMUR_SIGN_IDENTITY="Developer ID Application: …"` before `build-app.sh`
to sign with hardened runtime; `HUSHY_APPCAST_URL` / `HUSHY_SPARKLE_PUBLIC_KEY` fill the Sparkle
placeholders in `Info.plist` (empty = updates not configured). The maintainers' signed release and notarization tooling is
not part of this repository.
