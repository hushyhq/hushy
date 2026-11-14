# Cleanup gate (`scripts/gate-cleanup.sh`)

The cleanup gate compares a base git ref (default `origin/main`) with your working tree on the same eval sets and
models the orchestrator uses before merging cleanup-path changes.

## What it runs

- **Intent 2B** on public 300, golden, never-answer, misheard, and the number probe (`murmur-eval intent-app`).
- **Intent 2B and v5.4** on the long and live invented dictations (`murmur-eval early-clean`).
- **Vocab boost on speech** (set `vocab`, record only): see the next section.

Heavy work goes through `scripts/mac-heavy.sh`. Use a temp `HUSHY_HOME`; the gate never reads the founder's app data
folder or sealed sets.

## Made-worse per step

Founder rule (2026-10-24): every step after the speech recogniser must add to what it heard and never make it worse.

For each case, `intent-app --trace-steps` records text after:

1. the recogniser's base output (on text-only sets, the case `spoken` stands in for recogniser and boosted),
2. vocabulary boosting,
3. the name and Dictionary fixers,
4. the cleanup model's first pass,
5. rules, guards, and the delivered text.

The gate aligns each step to the set's reference (public `reference`, golden `expected`, other invented sets use
`spoken`) with the same word normalisation as `scripts/retrain_public_eval.py`. For each step transition it counts
**made worse** (reference words that matched before the step but not after) and **made better** (the reverse).
Speech-only filler removal does not count as worse when the normalised word stream is unchanged.

The report prints per-set, per-step made-worse totals for base versus candidate. With `--fail-on-regression`, the
gate exits 1 if any step's made-worse total rises on the candidate once the base build also recorded step traces
(if the base predates `--trace-steps`, the report still prints candidate totals but skips the made-worse regression
check). Up to five worst examples from the public or golden sets are written to `<out>/made-worse-worst.md`.

## Vocabulary boost on speech (record only)

The text sets treat the boosted text as equal to the recogniser text, so they never exercise the CTC vocabulary boost.
The `vocab` set does (`murmur-eval vocab-real-boost`, no cleanup model needed):

- `Evals/vocab-harm.jsonl` (about 200 rows): ordinary sentences full of collision words (text, next, data, edit, voice,
  privacy, cloud, mail, notes, music, photos, messages, pages, numbers, preview, home, linear, notion, slack, and joins
  such as "text data"). They must come out unchanged. Each row names the vocabulary in force: `full` (all sources) or
  one source alone (`dictionary`, `screen`, `apps`) to isolate where a bad swap comes from.
- `Evals/vocab-win.jsonl` (about 80 rows): names and terms the boost should get right, each with the expected spelling.
- `Evals/vocab-real-boost-fixture.json`: one invented vocabulary for both: 154 installed app names, a screen with UI
  labels, and a 40-entry Dictionary. It is built through the app's own `PipelineSettings.vocabulary`.
- Speech is made by `scripts/vocab-eval-audio.sh` with the built-in `say` command (Samantha, Daniel, Karen, Moira at
  their default rate, 16 kHz mono WAV) into the git-ignored `Evals/runs/vocab-real-boost/audio`.

Each row goes through the real Parakeet recogniser, the real boost (FluidAudio rescorer, spotter rescue off, as in
`SpeechEngine`), then `BoostGuard` via `VocabularyContext.guarded`. Scored: **words made worse** (a word that matched
what was said before the step and not after) at the boost step and after the guard, the source of each harmful term
(Dictionary, screen, installed app, built-in), and for the win rows the **recall of the expected spelling** (exact
capitals) in the recogniser text, after the boost and after the guard. The report prints base versus candidate and
never fails the gate yet (the baseline is still being recorded); a base that predates the command shows candidate
numbers only. Run alone:

```bash
scripts/vocab-eval-audio.sh
scripts/mac-heavy.sh vocab-boost .build/release/murmur-eval vocab-real-boost --backend none \
  --report /tmp/vocab-summary.json --rows-out /tmp/vocab-rows.jsonl
```

## Commands

```bash
# Full gate (queue through mac-heavy)
scripts/mac-heavy.sh gate-cleanup scripts/gate-cleanup.sh --fail-on-regression

# Faster smoke on golden + probe only
scripts/mac-heavy.sh gate-cleanup-smoke scripts/gate-cleanup.sh --sets golden,probe --models intent --fail-on-regression
```

See `scripts/gate-cleanup.sh --help` for flags (`--base`, `--models`, `--sets`, `--out`).
