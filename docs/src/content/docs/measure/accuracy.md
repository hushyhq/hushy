---
title: Measure accuracy
description: The evaluation tools in the repository, the public benchmarks they download, and how to compare two models.
---

The evaluation harness is `murmur-eval`. It lives in `Sources/murmur-eval` and drives the same
capture and cleanup code as the app. Run it with no arguments to see its commands.

```bash
swift run murmur-eval
```

## What is in the repository

| Path | What it is |
|---|---|
| `Evals/demo/dictation-demo.json` | 12 invented dictation cases. They show the file format. They are too few to compare models. |
| `Evals/finetune-prompts/` | System prompts from earlier training rounds. The app's current cleanup prompt is in `Sources/MurmurCore/Cleanup/IntentCleanupPrompt.swift`. |
| `Evals/judge/` | Rubrics and instructions for model judges. |
| `Evals/tools-v1.schema.json` | The voice-action tool schema. |
| `Evals/meeting-extract/LICENSES.md` | The licence of each corpus the meeting recipe uses. |

The maintainers' development, held-out and sealed sets are not published. Some come from real
dictations, and a sealed set only stays useful if nobody trains on it. Commands that default to one
of those files need an explicit path in this repository.

## Run the demo set

This runs the rule-based cleaner on the demo cases, with no model and no network.

```bash
swift run murmur-eval cleanup --golden Evals/demo/dictation-demo.json --backend none
```

On 14 November 2026 it printed a pass or fail line for each of the 12 cases and then the text of
each failure. With `--backend none` three cases failed. They were a spoken correction ("the design
team, no actually the product team"), a time written as "3:30pm" where the expected text has
"3:30 PM", and a leading "you know" that the rules kept. That is the baseline a model has to beat.

`--backend apple` uses Apple's on-device model on macOS 26 with Apple Intelligence.
`--backend mlx --mlx-model <dir>` uses a local MLX model, after you build the kernels. To run a model you
trained from the cleanup prompt, use `intent-run`, described in
[Convert and run](/train/convert-and-run/).

## Public speech-recognition benchmarks

Invented sets share their authors' blind spots, so score on public sets too. Name the set you want.
A bare `download` with no name fetches several default sets, which is a large download.

```bash
swift run murmur-eval download librispeech-clean --limit 50
swift run murmur-eval asr librispeech-clean --limit 50
```

`download` fetches the set from its own host into `Evals/data/`, which git ignores. We ran the
download. `asr` loads the speech model and prints the word error rate, the speed relative to real
time and the latency per clip. We did not run `asr`, because it loads the 610 MB speech model.

The available names are in `Sources/murmur-eval/Datasets.swift`. They include `librispeech-clean`,
`librispeech-other`, `ami-headset`, `ami-farfield`, `earnings22`, `peoples-speech`, the EdAcc accent
sets, FLEURS and MLS in four languages, and four Open ASR Leaderboard sets with the `oasr-`
prefix. Each set keeps its own licence, and the repository does not mirror any of them.

## Compare two cleanup models

Score cleanup output against independent references.

```bash
python3 scripts/retrain_public_eval.py score --outputs out.jsonl --references refs.jsonl --verdicts verdicts.jsonl
```

Outputs are JSON lines of `{id, text}`. References are `{id, reference, spoken?}`. The scorer
normalises both sides, so number words and digits meet, and writes a verdict per row. Its help
text describes each column.

For judged comparisons, `scripts/api_judge.py` uses the rubrics in `Evals/judge/`. It calls a
provider's API with your own key and keeps a spend ledger with a cap. We did not run it.

## Avoid fooling yourself

- Test on text your model never trained on. A model trained on AMI cannot be judged on AMI.
- Compare two models on the same cases and read the cases where they differ, not only the total.
- Check that a better score did not come from changing numbers or dropping a "not". The guards in
  [Cleanup and guards](/how-it-works/cleanup-and-guards/) exist for this.
- Keep the sets you tune on apart from the set you report.
