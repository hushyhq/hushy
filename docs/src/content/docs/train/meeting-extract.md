---
title: Meeting extract
description: Train a model that lists decisions and actions from a meeting transcript, using AMI and ICSI only.
---

This recipe trains a model that reads a chunk of a meeting transcript and returns its decisions,
actions, open questions and changes. The targets are the records that human annotators linked to
the transcript in the AMI and ICSI corpora, both CC BY 4.0. No model writes any label, so you need
no API key.

## 1. Download the corpora

```bash
export HUSHY_MEETING_PUBLIC=1
scripts/meeting-extract/download.sh
```

Setting `HUSHY_MEETING_PUBLIC=1` makes the script fetch only the AMI and ICSI annotations and stop.
It needs `curl` and `unzip`. AMI lands in `Evals/runs/public/ami/extracted`, which git ignores, and
ICSI in `.build/public-data/meeting-extract/raw`. In our run the raw folder was about 490 MB.

The scripts print a note when a maintainers' evaluation file is absent. With
`HUSHY_MEETING_PUBLIC=1` they carry on and hold nothing out for that file.

## 2. Build the rows

Keep `HUSHY_MEETING_PUBLIC=1` set for every command below.

```bash
PY="$(scripts/finetune/venv.sh)"
export HUSHY_TOKENIZER_DIR=/path/to/qwen3.5-tokenizer-folder
"$PY" scripts/meeting-extract/build_nxt.py ami
"$PY" scripts/meeting-extract/build_nxt.py icsi
"$PY" scripts/meeting-extract/assemble.py
"$PY" scripts/meeting-extract/build_sft.py --public
```

`assemble.py` takes no arguments and has no help flag, so running it always rebuilds. It also
writes `manifest.json` and `STATS.md` into `Evals/meeting-extract/`. Do not commit those two files.

The four steps ran in about six seconds on a Mac once the corpora were on disk. On 14 November
2026 the steps printed these counts.

| Step | Output |
|---|---|
| `build_nxt.py ami` | 143 chunks from 48 meetings, 335 records |
| `build_nxt.py icsi` | 339 chunks from 59 meetings, 263 records |
| `assemble.py` | 482 rows in `gold-human.jsonl` |
| `build_sft.py --public` | 404 training rows, 56 validation rows, 22 rows skipped as too long |

Your counts can differ if the corpora or the scripts change.

`build_sft.py --public` keeps only commercial-safe rows that have human targets. It splits by whole
meeting team, using a hash of the team name, so no team is in both the training and the validation
file. It writes to `.build/public-data/meeting-extract/sft-public/`:

| File | Contents |
|---|---|
| `train.jsonl`, `valid.jsonl` | Chat rows for the trainer |
| `train-commercial.jsonl`, `valid-commercial.jsonl` | Byte-for-byte copies of the two files above, because every row in this recipe is commercial-safe |
| `meta.jsonl` | The source, licence and `commercial_safe` flag of every row |
| `manifest.json` | Row, token and record counts |

## 3. Train

Copy `.build/public-data/meeting-extract/sft-public/` to the CUDA machine at the same relative path,
then run the trainer from the repository root.

```bash
python scripts/finetune/cuda/train_cuda.py --config training/configs/meeting-extract-public.yaml
```

The config trains a rank-32 LoRA adapter on `Qwen/Qwen3.5-4B` in 4-bit for two epochs, with
sequences up to 6144 tokens, and stops early when validation loss stops improving. It needs a GPU
with about 24 GB of memory.

The run writes to `.build/runs/meeting-extract-public-qwen3.5-4b/`.

- `adapter/` holds the trained LoRA adapter.
- `train_summary.json` records the minutes, peak memory, final validation loss and the loss history.
- `checkpoints/` lets an interrupted run resume. Run the same command again and it continues from
  the newest checkpoint. Add `--fresh` to start over.

Next, [convert and run the model](/train/convert-and-run/).

## What this model is not

It is not the model the maintainers ship. That model starts from the maintainers' own cleanup model
and adds rows labelled by large language models. This recipe starts from the base model and uses
only the human annotations.
