---
title: Overview
description: What you can train from this repository, what it needs, and what is not released.
---

This repository holds the recipe for Hushy's two on-device language models and the tools that
measure them. This section walks through the recipe with public data only.

## What is and is not released

The weights of the models Hushy ships are not open yet, and the dataset those models were trained
on is not published. Some of that data came from sources we cannot redistribute in a model, and
the training labels were written by large language models whose terms we have not finished
reviewing. The top-level README explains the reasons.

What you can do is train equivalent models yourself. The two public recipes below use only sources
whose licences allow commercial training. A model you train this way is not one of the models we
ship, and it is probably weaker, because it has less data.

The public configs were written for this release. We ran every data step on a Mac, but we have not
run the training step end to end from a fresh checkout. Training needs a CUDA machine that we did
not use for these two configs. If a step fails, open an issue.

## The two recipes

| Recipe | What the model does | Targets come from |
|---|---|---|
| [Meeting extract](/train/meeting-extract/) | Reads a chunk of a meeting transcript and lists decisions, actions, open questions and changes | The human annotators' own linked records in AMI and ICSI |
| [Dictation cleanup](/train/cleanup/) | Turns the recogniser's text into the text a person would have typed | A teacher model that you choose and pay for |

Both start from `Qwen/Qwen3.5-4B` and train a LoRA adapter with 4-bit quantisation (QLoRA).

## What you need

- A Mac with Apple silicon for building data, converting the model and measuring it.
  [Build from source](/build/from-source/) lists the requirements.
- A Linux machine with an NVIDIA GPU for training. The config comments say the cleanup recipe fits
  a 12 GB GPU, and the meeting-extract recipe needs about 24 GB.
- Disk for the corpora. The meeting-extract data folder was about 520 MB in our run.
- For the cleanup recipe only, an API key for the teacher model and money to spend. The tool
  prints an estimate first, and you set a spend cap.

We did not time training for these configs. The trainer writes `train_summary.json` to the output
folder, which records the minutes, the peak GPU memory and the final validation loss, so you will
have your own numbers after one run.

## Licence tags on every row

Every training row says where it came from, so you can check a model's licence row by row.

- The meeting builders write `source`, `licence` and `commercial_safe` on each row. The values come
  from `Evals/meeting-extract/LICENSES.md`.
- `scripts/finetune/licence_filter.py` keeps a cleanup row only when its source is in the source
  table with `commercial_safe` set to true. It drops every other row, including rows with no
  source. The licence comes from the table and never from the row. The report it writes lists the
  attributions your model card owes.

The table is the maintainers' reading of each source's published terms. It is not legal advice.
Read the terms again before you train or publish a model.

## The steps

1. [Set up](/train/setup/) the Mac and the training machine.
2. Build the data and train, following [Meeting extract](/train/meeting-extract/) or
   [Dictation cleanup](/train/cleanup/).
3. [Convert and run](/train/convert-and-run/) the model on the Mac.
4. [Measure accuracy](/measure/accuracy/).
