# Dictation cleanup judge

The model judge checks whether synthetic developer dictations keep the speaker's meaning, use careful writing mechanics, and are ready to send. It sits beside the fixed rule checks. It is not a gate.

Only synthetic, non-sealed dev eval cases may be sent to a judge model. Never send real dictations. `build` and `run` accept source files only from this repository's `Evals/` directory. They refuse paths containing `heldout` or `sealed`, and `build` accepts only reports whose `caseFile` is on the script's allowlist. The script also checks source files with `sealed_guard.assert_tuning_safe`.

```sh
python3 scripts/llm-judge.py build --report Evals/developer-messages-dev-baseline-local-2026-10-04.json --out Evals/judge/new-input.json
python3 scripts/llm-judge.py run --input Evals/judge/new-input.json --out Evals/judge/new-verdicts.json
python3 scripts/llm-judge.py summarise --input Evals/judge/new-input.json --verdicts Evals/judge/new-verdicts.json --report Evals/developer-messages-dev-baseline-local-2026-10-04.json
```

The pilot Codex judge marked 29/60 Clean and 29/60 Polished outputs good at baseline. The Sonnet judge marked 32/60 Clean and 31/60 Polished good. After the first fixes, Codex marked 34/60 Clean and 35/60 Polished good. The fixed rules passed 39/60 Clean and 36/60 Polished at baseline, then 39/60 Clean and 39/60 Polished after the fixes.

These are a model's opinions, and they move between runs. On outputs that were byte-for-byte the same, the Codex judge changed its `good` verdict on 1 of 100 items between the baseline and the first fixes, and on 6 of 118 items (3 at each level, all towards `good`) between the first fixes and the third pass (`after-fixes-3-2026-10-04/`). In that second pair only one case's output had changed, yet `good` rose from 34 to 38 at Clean and from 35 to 39 at Polished. A difference of fewer than about four cases per level is inside the judge's noise. The two judges agreed on `good` for 111 of 120 items. Verdicts need a human-labelled sample before anyone trusts the absolute numbers.

Run the offline tests with `python3 scripts/test-llm-judge.py`.

## API judge: blind pairwise readability (`scripts/api_judge.py`)

Judges which of two outputs for the same dictation reads more like typed text, and whether either changed the meaning, by calling the Anthropic Messages API directly (Python standard library only). The rubric is `Evals/judge/TYPED-READ-RUBRIC.md`; its `Rubric version:` line is part of the cache key. The judge never sees the arm names; every pair is asked in both orders, and a pair whose two orders disagree is reported as inconsistent, not as a win.

Only invented or public-benchmark text may be sent. Inputs and outputs must sit in `Evals/` or a `--scratch-dir`, must pass `scripts/finetune/pathguard.py` and `scripts/sealed_guard.py` (heldout, sealed, Voice Lab, the app's data directory), and the run needs `--invented-or-public`. The key is read from `~/.config/hushy/anthropic_api_key` (mode 600) at the first live call and never written to any output, log, cache or error. Verdicts are cached under `--state-dir` (default `Evals/runs/api-judge/`, git-ignored) by a hash of model, rubric version and exact request; `ledger.jsonl` there records tokens, dollars, and a bounded request-ID fingerprint per call.

```sh
python3 scripts/api_judge.py convert --scratch-dir DIR --invented-or-public --case-file CASES.jsonl \
    --report baseline=R0.json --report candidate=R3.json --out DIR/items.jsonl
python3 scripts/api_judge.py judge --scratch-dir DIR --invented-or-public --items DIR/items.jsonl \
    --out DIR/judge-run --dry-run                       # call count and estimated cost, nothing sent
python3 scripts/api_judge.py judge --scratch-dir DIR --invented-or-public --items DIR/items.jsonl \
    --out DIR/judge-run --max-dollars 8                 # writes judge-run.json and judge-run.md
```

Tests: `python3 scripts/tests/test_api_judge.py` (no network beyond a loopback fake server, no real key).

## Typed-version training data: mining and writing (`scripts/retrain_*.py`)

Builds spoken/typed pairs for long dictations (100 to 280 words of one person speaking). The spoken side is real spontaneous speech from the AMI and ICSI meeting corpora (CC BY 4.0; attribution owed: AMI Meeting Corpus, ICSI Meeting Corpus); a large model writes the typed side; automatic checks quarantine rows that change meaning. Standard library only. Unpack each corpus archive into its own empty folder, keep these scripts outside it, and run with `python3 -I`.

```sh
python3 -I scripts/retrain_mine.py mine --ami-dir AMI/extracted --icsi-dir ICSI/original_extracted/transcripts --out-dir Evals/runs/retrain
python3 -I scripts/retrain_mine.py select --passages Evals/runs/retrain/passages.jsonl --out Evals/runs/retrain/first-batch-20.jsonl \
    --monologue --exclude-pii person_name phone email address health money_personal --mask-names --sample 20   # caps: 3 per meeting, 5 per speaker
python3 -I scripts/retrain_writer.py write --passages Evals/runs/retrain/first-batch-20.jsonl --out Evals/runs/retrain/batch1 \
    --scratch-dir Evals/runs/retrain --state-dir Evals/runs/retrain/writer-state --invented-or-public --dry-run --assume 20 500 3000
```

Drop `--dry-run` and add `--max-dollars 3` for the real batch. The writer reuses the judge's client, key handling, ledger, cap, cache and path guards; its instructions are `TYPED-WRITER-INSTRUCTIONS.md` (the `Writer version:` line is part of the cache key). Each written row gets eleven separate checks (numbers, dates, names, negation, content words added, function words added, length, clause order, fillers left, corrections grounded, taken-back residue of the writer's own reported corrections); a row that fails any, or has an `unsure` item of kind `meaning`, goes to `PREFIX.quarantine.jsonl` with the reasons, unchanged. A faithful row with two or more `garbled` items goes to `PREFIX.not_typed.jsonl` (`reads_as_typed: false`). Two findings are report only and never quarantine: AMI-layer taken-back words that survive, and mixed number style in a sentence. `retrain_writer.py check` re-runs the checks on written rows with other thresholds and no API call. Tests: `python3 -I scripts/tests/test_retrain_mine.py` and `python3 -I scripts/tests/test_retrain_writer.py`.

### Typed-first pilot (`scripts/retrain_pilot*.py`)

Sixty invented passages written typed first, then spoken, then checked by writing the typed text again from the spoken text alone (`PILOT-TYPED-INSTRUCTIONS.md`, `PILOT-SPOKEN-INSTRUCTIONS.md`; the draft model prompts for the per-group and whole-dictation arms are in `Evals/finetune-prompts/`). Steps: `retrain_pilot.py plan`, `typed`, `spoken`, then `retrain_writer.py write` on `PREFIX.for_writer.jsonl`, then `retrain_pilot.py meaning` and `retrain_pilot_report.py`. Every call step takes `--dry-run`; live calls require an explicit cumulative `--max-dollars`, and the pilot ledger also enforces a $15 ceiling. Test: `python3 scripts/tests/test_retrain_pilot.py`.

Groups and rules drafts come from `murmur-eval finetune groups --in rows.jsonl --out groups.jsonl` (rows `{id, text}`; per row the groups the app cuts with `TextSegmentation.groups`, each group's `TextCleaner` draft, and the whole text's draft; no model call; test `Tests/MurmurEvalTests/FinetuneGroupsTests.swift`). Left context (the previous draft's last sentence, 15 to 25 words) is cut in Python, because `Sentences` is internal to MurmurCore.

### Speech-first route (`scripts/retrain_speech*.py`, `retrain_groups*.py`, `retrain_assemble.py`)

Notes first (who speaks, to whom, the points, the fixed facts and negations: `SPEECH-NOTES-INSTRUCTIONS.md`), then the speech written from the notes alone with two windows of real meeting speech as manner examples only (`SPEECH-SPOKEN-INSTRUCTIONS.md`), then typed-writer-v2 on the speech alone, then an independent check of the typed text against the notes (`check_against_notes`: facts, files, points by anchor words, negations, planted corrections), then the groups, one call per passage that splits the typed text over the groups (`GROUP-TARGETS-INSTRUCTIONS.md`), the group-level checks, and the production guard's verdict on each (draft, piece) pair through `finetune prepare`. Tests: `python3 scripts/tests/test_retrain_speech.py`.

### Release-route pair check and policy relabel (`scripts/retrain_release*.py`)

The first pilot judged pairs on the Clean level with the legacy grammar contract, which is stricter than the route the app ships (Polished unless As Spoken, and the destination app's own options). `murmur-eval finetune groups` now takes `--bundle <bundle id>` (or a `bundle` per row, or `--as-spoken`) and builds the rules drafts with `PipelineSettings.forDictation` for that destination (`Sources/murmur-eval/Finetune/ReleaseRoute.swift`); `murmur-eval finetune verdicts --in rows.jsonl --out verdicts.jsonl` (rows `{id, raw, target[, bundle]}`) reports the first rejection of TrainingPairCheck on that route's draft, with the release draft, the check's own draft, whether they match, and an approximate re-run where they do not. It is not the app's full acceptance path, which may prepare, repair, or retry an answer. No model call; tests in `Tests/MurmurEvalTests/FinetuneVerdictsTests.swift`.

Not reachable from `murmur-eval` without changing MurmurCore: `OutputGuard.check`, `SpokenLayoutGuard`, `ListStructureGuard`, `TrailOffGuard`, `DroppedClauseGuard`, `LanguageMatchGuard`, the answer preparation (`restoringFlattenedBreaks`, `droppingBareRetraction`, `Punctuation.tidy`), and the runtime order (layout and list checks before `OutputGuard`). The public door, `TrainingPairCheck.check`, runs `OutputGuard` first, the layout and list checks only when it accepts, and returns the first reason only, so a pair's later reasons are not visible; it also builds its own draft from the level alone.

Targets are relabelled under the written policy (`GROUP-TARGETS-INSTRUCTIONS.md`, `group-targets-v3`; v1 kept as `GROUP-TARGETS-INSTRUCTIONS-V1.md`): the writer sees each group's speech and release-route draft and the previous draft's last sentence, not the typed text; the joined pieces are the passage's typed text. Commands: `retrain_release_cli.py groups-in | relabel | verdicts-in | report`. The report (`Evals/runs/retrain/pilot60.md`) gives accepted and rejected counts per arm and route, every rejection reason with counts and three example ids, the draft match basis of each pair-check result (exact, same words, approximate), and how the relabelled text differs from the earlier typed text by class. Tests: `python3 scripts/tests/test_retrain_release.py`.

Current label brief: `GROUP-TARGETS-INSTRUCTIONS.md` is `group-targets-v4.1`; the former v4 is preserved as `GROUP-TARGETS-INSTRUCTIONS-V4.md`. The mechanical per-group audit is `scripts/retrain_provenance.py`; it reports label provenance findings without rewriting labels. `RETRAIN-V41-SCALE.md` has the resumable speech-first scale command, manifest contract, pilot-ledger cost estimates, and the local training-data inventory.

Label versions: v1 is the first pilot's split of a composed typed text, v2 (`GROUP-TARGETS-INSTRUCTIONS-V2.md`) is the minimal policy label, and v3 (`GROUP-TARGETS-INSTRUCTIONS.md`, `group-targets-v3`) writes the best typed version of the whole message first and cuts it into pieces (the call returns `typed` and `pieces`). `retrain_release_cli.py compare` puts the versions side by side (pieces that differ from the draft in punctuation and case only, a run-on measure, pair-check results where a verdict file exists); `judge-summary` clusters the blind judge's stated reasons; `report` flags any group or whole draft that lost a content word (`draft_lost_content_word`) so a target built on it is never accepted.
