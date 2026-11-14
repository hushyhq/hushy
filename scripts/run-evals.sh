#!/usr/bin/env bash
# Run cached evaluations, preserve full evidence, and fail on golden quality regressions.
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in ""|--quick) ;; *) echo 'Usage: scripts/run-evals.sh [--quick]' >&2; exit 2;; esac
swift build -j 4 -c release --product murmur-eval >/dev/null
EVAL=.build/release/murmur-eval
RUN_DIR="${MURMUR_EVAL_RUN_DIR:-Evals/runs/$(date -u +%Y%m%dT%H%M%SZ)-$$}"
mkdir -p "$RUN_DIR"
git rev-parse HEAD > "$RUN_DIR/revision.txt"
git diff --binary > "$RUN_DIR/working-tree.patch"
sw_vers > "$RUN_DIR/environment.txt"
system_profiler SPHardwareDataType | sed '/Serial Number/d; /Hardware UUID/d; /Provisioning UDID/d' >> "$RUN_DIR/environment.txt"
swift --version >> "$RUN_DIR/environment.txt"
cp Package.resolved "$RUN_DIR/Package.resolved"
tar -czf "$RUN_DIR/source.tar.gz" Sources Tests scripts Package.swift Package.resolved Evals/*golden.json
failed=0
run() {
  local label="$1"; shift
  printf '\n==> %s\n' "$label"
  if "$EVAL" "$@" 2>&1 | tee "$RUN_DIR/$label.log"; then
    printf '%s\tPASS\n' "$label" >> "$RUN_DIR/status.tsv"
  else
    printf '%s\tFAIL\n' "$label" >> "$RUN_DIR/status.tsv"
    failed=1
  fi
}
skip() { printf '%s\tSKIP (missing cached dataset)\n' "$1" | tee -a "$RUN_DIR/status.tsv"; }
has() { [ -f "Evals/data/$1/manifest.json" ]; }
has_voicelab() { find "${HUSHY_HOME:-${MURMUR_HOME:-$HOME/Library/Application Support/Hushy}}/VoiceLab" -name '*.wav' -print -quit 2>/dev/null | grep -q .; }
has_typesafe_key() {
  [ -n "${TYPESAFE_API_KEY:-}" ] || [ -f "$HOME/.config/hushy/typesafe_api_key" ]
}
# Which judge backend `run_judge` below drives: `typesafe` (TypeSafe/Jev, needs an API key),
# `claude`/`codex` (the developer's own locally installed, already-logged-in CLI, no key needed —
# see Sources/murmur-eval/CLIJudge/), or `both` (claude + codex agreement report). Defaults to
# `codex`: it needs no separately-provisioned API key, only the developer's own `codex` CLI
# login, so it's the lowest-friction judge for a normal dev machine.
JUDGE_BACKEND="${JUDGE_BACKEND:-codex}"
# Optional judge stage. `judge` exits 0 and prints its own `· skipped` message when its selected
# backend's credential/login is missing (TypeSafe key, or `claude`/`codex` not logged in — see
# Sources/murmur-eval/JudgeRunner.swift and CLIJudge/), so gate it here only for the one case we
# can check cheaply from the shell (the TypeSafe key) and otherwise let `judge` itself report
# SKIP — this stage never fails the suite when a credential/login is absent.
run_judge() {
  local label="$1"; shift
  if [ "${HUSHY_EVAL_SKIP_JUDGE:-0}" = 1 ]; then
    printf '%s\tSKIP (explicit HUSHY_EVAL_SKIP_JUDGE=1)\n' "$label" | tee -a "$RUN_DIR/status.tsv"
    return
  fi
  if [ "$JUDGE_BACKEND" = typesafe ] && ! has_typesafe_key; then
    skip "$label (no TYPESAFE_API_KEY / ~/.config/hushy/typesafe_api_key)"
    return
  fi
  run "$label" judge --backend "$JUDGE_BACKEND" "$@"
}
# Runs a stage that reports a number (DER, etc.) without gating the suite: PASS/FAIL is still
# recorded to status.tsv for visibility, but it never sets the outer `failed` flag, since no
# --min-pass/quality floor exists for this stage yet (see the diarize call sites below).
run_informational() {
  local label="$1"; shift
  printf '\n==> %s (informational, not gating)\n' "$label"
  if "$EVAL" "$@" 2>&1 | tee "$RUN_DIR/$label.log"; then
    printf '%s\tPASS\n' "$label" >> "$RUN_DIR/status.tsv"
  else
    printf '%s\tFAIL (informational — does not fail the suite)\n' "$label" >> "$RUN_DIR/status.tsv"
  fi
}
run cleanup-rules cleanup --strategy rules --min-pass 0.80 --require-tags plain,safety --report "$RUN_DIR/cleanup-rules.json"
run cleanup-hybrid cleanup --strategy hybrid --min-pass 0.88 --require-tags plain,safety --report "$RUN_DIR/cleanup-hybrid.json"
run e2e-hybrid e2e --model ultra --strategy hybrid --min-pass 0.80 --require-tags plain,safety --report "$RUN_DIR/e2e-hybrid.json"
# Style formatting (formatting-only rules): word-preservation must be 100%, and the
# non-aspirational pass rate floor matches what this golden set currently achieves (100%).
run style style --min-pass 1.00 --report "$RUN_DIR/style.json"
# Code style (CleanupOptions.isCodeContext): casing commands, symbol words and file tags,
# scored deterministically (rules only, no model) — see Sources/murmur-eval/CodeRunner.swift.
run code code --min-pass 1.00 --report "$RUN_DIR/code.json"
# Learn-from-corrections simulation (text-only, deterministic, in-memory store): terms learned
# within 2 edits, zero false learns on adversarial edits, no change to sentences without learned
# terms — see Sources/murmur-eval/LearnRunner.swift.
run learn learn --max-false-learn 0 --max-mean-edits 2 --report "$RUN_DIR/learn.json"
# Adversarial diagnostics and over-deletion regression set — both previously existed as golden
# files without a wired gate; scored here at their measured floors (50/50, 30/30) so a real
# regression fails the suite instead of silently going unmeasured.
run adversarial cleanup --strategy rules --golden Evals/adversarial-golden.json --min-pass 1.00 --report "$RUN_DIR/adversarial.json"
run overdeletion cleanup --strategy hybrid --golden Evals/overdeletion-golden.json --min-pass 1.00 --report "$RUN_DIR/overdeletion.json"
# Grammar repair (task: grammar-polish — disfluency removal at .clean, full grammar-and-flow
# repair at .polished; see .claude/DECISIONS.md for the design). Text-only, so it always runs
# even in --quick. Gated at 80% combined (measured 87.2% on an idle machine; the floor leaves
# headroom for on-device model non-determinism/load — see this eval's own report for the
# tune/holdout split, the real-user group and the legit-repeat negatives, which are the more
# informative numbers than the single combined gate).
run grammar-repair grammar --golden Evals/grammar-golden.json --min-pass 0.80 --report "$RUN_DIR/grammar-repair.json"
# Long dictation golden (task: incremental cleanup) — rules alone must fully resolve this set
# deterministically (no model variance); the hybrid/incremental comparison is measured and
# reported separately (see docs/guide/HUSHY_GUIDE.md and DECISIONS.md), not gated here, since the
# on-device model's timing is inherently noisier run to run than this suite's other rules-driven
# gates and gating on it would make --quick flaky for reasons unrelated to code correctness.
run long-golden-rules cleanup --strategy rules --golden Evals/long-golden.json --min-pass 1.00 --report "$RUN_DIR/long-golden-rules.json"
# Multi-language cleanup: non-English text must keep >=99% of its spoken content words through
# cleanup (English-only stages skip for it — see TextCleaner.clean). No audio/network needed,
# so this always runs, even in --quick.
run multilang-cleanup multilang cleanup --min-preserved 0.99
# Custom modes (Email/Message/Note/Bullet points + user-created): property checks (greeting/
# sign-off, list format, fact preservation, no injection compliance) against the real pipeline,
# including a live on-device model call on this Mac when Apple Intelligence is available. No
# audio/network needed, so this always runs, even in --quick. Gated at 90% rather than 100%: the
# on-device model's phrasing has some run-to-run variance (unlike the deterministic rules gates
# above), and this floor still catches a real regression while tolerating that noise.
run modes modes --min-pass 0.90 --report "$RUN_DIR/modes.json"
# Context awareness (ContextExtractor/ContextSpellingFixer, MurmurCore): text-only, like the
# multilang-cleanup gate above, so it always runs even in --quick. Gated at 100% of the
# non-aspirational cases (currently 36/36) — a handful of deliberately hard cases (an inserted
# vowel next to a consonant cluster, cross-script phonetic matches) are marked aspirational in
# the golden set rather than gated, since loosening the phonetic check to catch them would also
# let a numerically-close-but-different-sounding word (e.g. "chat"/"chart") slip through.
run context-awareness context --golden Evals/context-golden.json --min-pass 1.00 --report "$RUN_DIR/context-awareness.json"
# HELD-OUT reformat eval (Evals/reformat-golden.json; see .claude/DECISIONS.md "Reformat eval is
# held out"): rambling dictation -> clean typed text, clean and polished levels through the real
# pipeline. Text-only, ~70-90 s for both levels. In --quick it gates at a 40% floor per level —
# below the measured 2026-09-26 baseline (clean ~42%, polished 46-55%), and also what a fully
# timed-out polished run falls back to (rules output), so host load alone can't trip it. In the
# full run it is informational. Never tune cleanup against these cases.
if [ "${1:-}" = --quick ]; then
  run reformat reformat --level both --min-pass 0.40 --report "$RUN_DIR/reformat.json"
else
  run_informational reformat reformat --level both --report "$RUN_DIR/reformat.json"
fi
# Fast streaming sanity check (task: "make streaming the default"; see .claude/DECISIONS.md,
# 2026-09-26): a small, quick version of the full `streaming` stage below (30/60s lengths,
# 40 clips instead of the full run's larger lengths/limit) — measured at ~4 s once
# librispeech-clean is cached, comfortably inside --quick's budget. Informational, like
# `long-golden-rules`'s note above: the on-device model's per-run timing is noisier than this
# suite's other rules-driven gates, and streaming WER vs whole-utterance is tracked/trended in
# DECISIONS.md rather than gated on a hard threshold here.
if has librispeech-clean; then
  run_informational streaming-quick streaming --dataset librispeech-clean --lengths 30,60 --model ultra --limit 40
else
  skip streaming-quick
fi
# Optional LLM-judge cross-check of cleanup quality on the synthetic golden set; never gates the
# suite (no --min-pass), report-only. Voice Lab is never sent here. Backend is $JUDGE_BACKEND
# (default codex; set JUDGE_BACKEND=typesafe|claude|both to use a different one).
run_judge judge-rules --golden Evals/dictation-golden.json --strategy rules --report "$RUN_DIR/judge-rules.json"
# Ground-truth eval: real dictation through the production mic path (see Evals/README.md).
# Held out — never tune prompts/rules against individual Voice Lab cases, report aggregate only.
if has_voicelab; then
  run voicelab-hybrid voicelab --model ultra --strategy hybrid --report "$RUN_DIR/voicelab-hybrid.json"
else
  skip voicelab
fi
if [ "${1:-}" != --quick ]; then
  run apple-golden e2e --engine apple-dictation --raw 1 --report "$RUN_DIR/apple-golden.json"
  for dataset in librispeech-clean librispeech-other accents ami-headset ami-farfield earnings22 peoples-speech commonvoice-spontaneous commonvoice-scripted; do
    if has "$dataset"; then
      run "$dataset-ultra" asr "$dataset" --model ultra
      run "$dataset-apple" asr "$dataset" --engine apple-dictation
    else
      skip "$dataset"
    fi
  done
  if has librispeech-clean; then
    run challenge challenge --model ultra --limit 60
    run notes notes --model ultra --limit 40
    run streaming streaming --dataset librispeech-clean --model ultra --limit 40
  else
    skip challenge
    skip notes
    skip streaming
  fi
  run whisper whisper
  if has disfluency; then run disfluency disfluency --model ultra --limit 120; else skip disfluency; fi
  # Multi-language WER: v2/v3/Ultra on ~25 Multilingual LibriSpeech clips each for es/fr/de/it
  # (originally FLEURS, swapped because every FLEURS config's datasets-server /rows endpoint
  # 500s with a Parquet scan-size-limit error — see Dataset.multilangDatasets). Downloads are
  # resumable and cached under Evals/data (see Downloader.download), so a later run only
  # re-downloads what a previous run didn't finish. Never tunes against Voice Lab.
  run multilang-wer multilang wer --languages es,fr,de,it --models v2,v3,ultra --limit 25
  # Indian-accented English WER vs a US-English control (docs/research/accent-robustness.md):
  # EdAcc's own Indian English subset (Svarah is gated, no HF_TOKEN in CI — see
  # AccentRunner.swift), v2/v3, 300 clips per set. Downloads are resumable/cached the same way.
  run accent accent --models v2,v3 --limit 300
fi
# Speaker diarization DER (docs/research/speaker-labeling.md): a small, fast subset against
# official ground-truth RTTM (AMI's community "mini" 3-meeting subset + 2 VoxConverse dev
# files), run in both --quick and full mode since it's small and network-bounded rather than
# CPU-bound. Informational only — never gates the suite, until
# docs/research/speaker-labeling.md's "Ship as Beta until DER <= 25%" bar has enough real runs
# behind it to gate on.
run_informational diarize-ami-mini diarize --dataset ami --config sdm --meetings 3 --collar 0.25
run_informational diarize-voxconverse diarize --dataset voxconverse --meetings 2 --collar 0.25
printf '\nEvidence: %s\n' "$RUN_DIR"
exit "$failed"
