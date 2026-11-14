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
PY="$(scripts/finetune/venv.sh)"
HUSHY_MEETING_PUBLIC=1 scripts/meeting-extract/download.sh      # AMI and ICSI text only
"$PY" scripts/meeting-extract/build_nxt.py ami
"$PY" scripts/meeting-extract/build_nxt.py icsi
"$PY" scripts/meeting-extract/assemble.py
"$PY" scripts/meeting-extract/build_sft.py --public               # .build/public-data/meeting-extract/sft-public/
python scripts/finetune/cuda/train_cuda.py --config training/configs/meeting-extract-public.yaml   # on a CUDA box
```

`build_sft.py --public` keeps only AMI and ICSI rows that are commercial-safe and have human
targets, and splits by whole meeting team, so no team is in both train and validation.
(`scripts/meeting-extract/leakage_check.py` is the maintainers' check against their private
evaluation sets; it needs those sets and does not apply to the public recipe.) Set
`HUSHY_TOKENIZER_DIR` to any Qwen3.5 tokenizer folder; it is used to measure row length.

## Public recipe 2: dictation cleanup

Turns the recogniser's text into the text a person would have typed, keeping the meaning.

1. **Collect spoken-side text** from commercial-safe sources only. The source table is
   `configs/cleanup-public-sources.json`. Readers for AMI and ICSI are in
   `scripts/retrain_corpora.py`; `scripts/retrain_longform_sources.py` reads other long-form
   corpora. Give every row a `source` field.
2. **Index the benchmarks.** `scripts/retrain_public_rows.py benchmark-index` hashes the text of
   the public benchmarks you evaluate on (hashes, never text), so that `assemble --exclude-index`
   in step 5 drops any training row that repeats one. `assemble` also screens every added source
   (`scripts/retrain_public_screen.py`): malformed, empty, repeated or implausible rows are dropped
   and counted.
3. **Write targets with a teacher you choose.** `scripts/retrain_writer.py` asks a model to write
   the typed version of each passage and runs the automatic checks. It reads your own Anthropic key
   from `~/.config/hushy/anthropic_api_key`, and has a dry run, a spend cap and a quarantine for
   rows that look wrong. Read your provider's terms on using its outputs to train a model first.
4. **Filter by licence.**
   `python3 -I scripts/finetune/licence_filter.py --sources training/configs/cleanup-public-sources.json rows.jsonl kept.jsonl --report licence-report.json`
5. **Assemble** train and validation files with `scripts/retrain_public_rows.py assemble`. It
   writes a manifest with the held-out proof the trainer checks.
6. **Train**: `python scripts/finetune/cuda/train_cuda.py --config training/configs/cleanup-public.yaml`.
7. **Convert and evaluate**: `scripts/finetune/cuda/merge.py`, then `scripts/finetune/convert_mlx.sh`
   for the 4-bit MLX model the app runs, then `murmur-eval` with `--backend mlx --mlx-model <dir>`
   on the public benchmarks (Evals/README.md).

The prompts the models are trained with are in `Evals/finetune-prompts/`.

## What you need

- A Mac for data building, conversion and evaluation (BUILDING.md).
- A Linux machine with an NVIDIA GPU for training: 12 GB for the cleanup config, about 24 GB for the
  meeting-extract config (QLoRA). `scripts/finetune/cuda/requirements.txt` lists the packages.
- Disk for the corpora: about 1 GB of text for the meeting recipe.

## Status

The public configs were written for this release and have not yet been run end to end from a fresh
checkout. The individual scripts are the ones the maintainers use. Report problems in an issue.
