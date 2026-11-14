---
title: Dictation cleanup
description: Train a model that turns recogniser text into the text a person would have typed, from public corpora and a teacher you choose.
---

This recipe trains the model that turns the recogniser's words into the text you would have typed.
Its inputs are real spoken text from corpora with open licences. Its targets are written by a
teacher model that you choose and pay for. Unlike the meeting recipe, it has no human-written
targets, so the quality of your model depends on the teacher and on the checks below.

Run the commands in the order shown, from the repository root.

## 1. Get a corpus

`scripts/meeting-extract/download.sh` fetches the AMI annotations to `Evals/runs/public/ami/extracted`
as its first step. If you already ran it for the meeting recipe, skip this step.

```bash
HUSHY_MEETING_PUBLIC=1 scripts/meeting-extract/download.sh
```

The ICSI reader needs a different download, the original ICSI transcripts as a folder of `.mrt`
files. No script in this repository fetches them, so the walkthrough uses AMI only.

## 2. Cut passages

`scripts/retrain_longform.py stretches` cuts each speaker's unbroken speech into passages of 100 to
300 words, shaped like recogniser output. It rejects a passage when words are missing, when it is
mostly very short clauses, or when it repeats text found in another file.

```bash
mkdir -p .build/public-data/cleanup-work
python3 scripts/retrain_longform.py stretches --source ami \
  --input Evals/runs/public/ami/extracted --out .build/public-data/cleanup-work/passages.jsonl
```

It took about five seconds and printed a count of passages by length band. On 14 November 2026 it
kept 860 AMI passages and rejected 369 for missing words and 23 for short clauses. Each output
line has an `id`, a `source`, a `licence`, a `meeting`, a `series`, the word count and the `spoken`
text.

The other `--source` values are `icsi`, `earnings21` and `earnings22`. The Earnings sources are not
in the licence table, so step 5 drops them.

## 3. Hold out whole meetings

```bash
python3 scripts/retrain_longform.py split \
  --input .build/public-data/cleanup-work/passages.jsonl \
  --train .build/public-data/cleanup-work/train-passages.jsonl \
  --held-back .build/public-data/cleanup-work/valid-passages.jsonl
```

A stable hash of the meeting decides which meetings are held back, so no meeting is in both
files. The command prints the held meetings. On 14 November 2026 it held back 31 meetings and
split the 860 passages into 691 for training and 169 held back.

This held-back set is your validation set. It is AMI text, so it is not a fair test of a model
trained on AMI. Test on other public sets, as [Measure accuracy](/measure/accuracy/) describes.

## 4. Write the targets

`scripts/retrain_writer.py` asks a teacher model to write the typed version of each passage, then
runs automatic checks on the answers. It reads your own Anthropic API key from
`~/.config/hushy/anthropic_api_key` at the first live call and never earlier. Read your provider's
terms on training a model from its outputs before you spend anything.

The tool reads and writes only inside `Evals/` or a folder you name with `--scratch-dir`. Name your
work folder.

Run a dry run first. It sends nothing and does not open the key file.

```bash
python3 scripts/retrain_writer.py write \
  --passages .build/public-data/cleanup-work/train-passages.jsonl \
  --out .build/public-data/cleanup-work/written \
  --scratch-dir .build/public-data/cleanup-work \
  --invented-or-public --dry-run --assume 20 500 3000
```

It prints the number of calls and a cost estimate. For the 691 training passages above, it
printed a typical cost of $33.80 and a worst case of $123.94 on 14 November 2026, using the price
table dated 8 October 2026. Those prices change, so run the dry run yourself.

When the estimate is acceptable, run a small live batch, then the rest. `--max-dollars` is
required for a live run.

```bash
python3 scripts/retrain_writer.py write \
  --passages .build/public-data/cleanup-work/train-passages.jsonl \
  --out .build/public-data/cleanup-work/written \
  --scratch-dir .build/public-data/cleanup-work \
  --invented-or-public --limit 20 --max-dollars 3
```

The tool writes five files next to the `--out` prefix. `written.accepted.jsonl` holds the rows that
passed. `written.quarantine.jsonl` holds every row that looked wrong, with the reasons. The tool
drops nothing silently and repairs nothing. Read the quarantine file before you train. We ran the
dry run only, so we have not seen the accepted-row counts of a live run.

## 5. Filter by licence

Each accepted row keeps its passage fields under `meta`, including `source`. The filter reads the
source from there.

```bash
python3 scripts/finetune/licence_filter.py \
  --sources training/configs/cleanup-public-sources.json \
  .build/public-data/cleanup-work/written.accepted.jsonl \
  .build/public-data/cleanup-work/kept.jsonl \
  --report .build/public-data/cleanup-work/licence-report.json
```

The filter keeps a row only when its source is in the table with `commercial_safe` true. It prints
a report that counts kept and dropped rows per source and lists the attributions your model card
owes. For the AMI passages it kept all 860 and listed one attribution. The command exits with 1
when no row is kept.

## 6. Make the training files

`training/chat_rows.py` turns the rows into the chat rows the trainer reads and splits them into
`train.jsonl` and `valid.jsonl`. It builds the system message from the app's own prompt in
`Sources/MurmurCore/Cleanup/IntentCleanupPrompt.swift`, so training and the app cannot drift apart.
Rows from one meeting stay on one side of the split.

```bash
python3 training/chat_rows.py .build/public-data/cleanup-work/kept.jsonl \
  .build/public-data/cleanup-public --valid-fraction 0.1
```

Each output line is `{"messages": [system, user, assistant]}`. The user turn is
`Transcript: <spoken>` and `Output:`, and the assistant answer is `{"text": "<typed>"}`. A row
without both text fields stops the run and names the line.

We checked these two steps on 60 AMI passages that we gave placeholder targets. The run produced
54 training rows and 6 validation rows. That checks the plumbing, not the quality of a real model.

## 7. Train

Copy `.build/public-data/cleanup-public/` to the CUDA machine, then run the trainer from the
repository root.

```bash
python scripts/finetune/cuda/train_cuda.py --config training/configs/cleanup-public.yaml
```

The config trains a rank-32 LoRA adapter on `Qwen/Qwen3.5-4B` in 4-bit for two epochs with
sequences up to 1024 tokens. The config comments say it fits a 12 GB GPU. The run writes `adapter/`
and `train_summary.json` to `.build/runs/cleanup-public-qwen3.5-4b/`, as the meeting recipe does.

Next, [convert and run the model](/train/convert-and-run/).

## What this recipe leaves out

`scripts/retrain_public_rows.py assemble` builds training sets from a base set that is not in this
repository, so it is not part of the public recipe. That means there is no automatic check that
removes training rows that overlap a benchmark. Keep your test sets separate from your sources
yourself. `retrain_public_rows.py benchmark-index` builds a hash index of a benchmark's text
and is there if you want to write your own filter.
