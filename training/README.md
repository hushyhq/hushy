# Training recipe

This folder and the scripts it points to are the recipe for Hushy's on-device models: the data
builders, the licence tags, the commercial-only filter, the trainer and its configs, and the
conversion to the format the app runs. No data is included. The scripts download public corpora
from their own hosts, and you supply any model-written labels with your own account.

The configs here are **public recipes**, not the recipe of the models the maintainers ship today.
Those models were trained on rows that cannot be redistributed (see the top-level README). A model
trained with these configs is not one of the shipped models.

## Licence tags on every row

Every training row says where it came from, so that a model's licence can be checked row by row.

- The meeting-extract builders write `source`, `licence` and `commercial_safe` on each row, and
  `build_sft.py` writes them to `meta.jsonl` next to the training files. The values come from
  `Evals/meeting-extract/LICENSES.md`, which records each corpus's published terms.
- `scripts/finetune/licence_filter.py` is the commercial-only filter for cleanup rows. It keeps a
  row only when its `source` is listed in a source table with `commercial_safe: true`, and drops
  everything else, including rows with no source. A row cannot vouch for itself: the licence comes
  from the table, not from the row. The report lists the attributions your model card owes.

Licences in the source tables are the maintainers' reading of each source's published terms on the
date given in `LICENSES.md`. They are not legal advice. Read the terms again before you train or
publish a model.

## Public recipe 1: meeting extraction

Extracts decisions, actions, open questions and changes from a chunk of a meeting transcript.
Targets are the human annotators' own linked records in AMI and ICSI (both CC BY 4.0). No
model-written labels are used.

```bash
export HUSHY_MEETING_PUBLIC=1                       # set for every command below
export HUSHY_TOKENIZER_DIR=/path/to/qwen3.5-tokenizer-folder
PY="$(scripts/finetune/venv.sh)"
scripts/meeting-extract/download.sh                 # AMI and ICSI text only
"$PY" scripts/meeting-extract/build_nxt.py ami
"$PY" scripts/meeting-extract/build_nxt.py icsi
"$PY" scripts/meeting-extract/assemble.py           # no arguments; also writes Evals/meeting-extract/{manifest.json,STATS.md}, do not commit them
"$PY" scripts/meeting-extract/build_sft.py --public # .build/public-data/meeting-extract/sft-public/
python scripts/finetune/cuda/train_cuda.py --config training/configs/meeting-extract-public.yaml   # on a CUDA box
```

`build_sft.py --public` keeps only AMI and ICSI rows that are commercial-safe and have human
targets, and splits by whole meeting team, so no team is in both train and validation.
(`scripts/meeting-extract/leakage_check.py` is the maintainers' check against their private
evaluation sets; it needs those sets and does not apply to the public recipe.)

## Public recipe 2: dictation cleanup

Turns the recogniser's text into the text a person would have typed, keeping the meaning. Inputs are
real spoken text from commercial-safe corpora. Targets come from a teacher model you choose.

1. **Get a corpus.** `scripts/meeting-extract/download.sh` fetches AMI to
   `Evals/runs/public/ami/extracted`. No script here fetches the ICSI original transcripts that the
   `icsi` reader needs.
2. **Cut passages.**
   `python3 scripts/retrain_longform.py stretches --source ami --input Evals/runs/public/ami/extracted --out .build/public-data/cleanup-work/passages.jsonl`
3. **Hold out whole meetings.**
   `python3 scripts/retrain_longform.py split --input ...passages.jsonl --train ...train-passages.jsonl --held-back ...valid-passages.jsonl`
4. **Write targets with a teacher.** `scripts/retrain_writer.py write` has a dry run, a spend cap and
   a quarantine for rows that look wrong. It reads your own Anthropic key from
   `~/.config/hushy/anthropic_api_key` and only reads and writes under `Evals/` or `--scratch-dir`.
   Read your provider's terms on using its outputs to train a model first.
5. **Filter by licence.**
   `python3 scripts/finetune/licence_filter.py --sources training/configs/cleanup-public-sources.json written.accepted.jsonl kept.jsonl --report licence-report.json`
6. **Make the training files.**
   `python3 training/chat_rows.py kept.jsonl .build/public-data/cleanup-public --valid-fraction 0.1`
   builds the chat rows from the app's own prompt and splits them by meeting.
7. **Train.** `python scripts/finetune/cuda/train_cuda.py --config training/configs/cleanup-public.yaml`.

`scripts/retrain_public_rows.py assemble` is not part of this recipe: it needs a base set that is not
in this repository, so there is no automatic benchmark-overlap filter. Keep your test sets apart from
your sources yourself.

Step-by-step pages with expected output are at https://docs.tryhushy.com/train/overview/.

## Convert and evaluate

On the CUDA box, `python scripts/finetune/cuda/merge.py --config <the config you trained with>`
writes `merged/` beside `adapter/`. On the Mac, `scripts/finetune/convert_mlx.sh <merged-dir> <out-dir>`
makes the 4-bit MLX model. `python3 training/chat_rows.py --write-prompt-file prompt.txt` writes the
training prompt in the layout `murmur-eval intent-run --system` reads.

## What you need

- A Mac for data building, conversion and evaluation (BUILDING.md).
- A Linux machine with an NVIDIA GPU for training: 12 GB for the cleanup config, about 24 GB for the
  meeting-extract config (QLoRA). `scripts/finetune/cuda/requirements.txt` lists the packages.
- Disk for the corpora: about 1 GB of text for the meeting recipe.

## Status

The public configs were written for this release. The data steps were run on a Mac, and the
cleanup steps through the licence filter and `chat_rows.py` were run with placeholder targets. Neither
config has been trained end to end from a fresh checkout. Report problems in an issue.
