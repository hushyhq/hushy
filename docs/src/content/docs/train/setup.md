---
title: Set up
description: The Mac and the CUDA machine you need before you build data and train.
---

## On the Mac

Clone the repository and check that it builds. See [Build from source](/build/from-source/).

The data and conversion scripts run in a Python 3.12 environment that `scripts/finetune/venv.sh`
makes with [uv](https://docs.astral.sh/uv/). It prints the path of that environment's Python, and
creates the environment on first use under `.build/finetune-venv`.

```bash
PY="$(scripts/finetune/venv.sh)"
```

The packages it installs are pinned in `scripts/finetune/requirements-mlx.txt`.

Some steps measure row length with a tokenizer. Download the tokenizer files of
`Qwen/Qwen3.5-4B` from Hugging Face into a folder and point `HUSHY_TOKENIZER_DIR` at it.

```bash
export HUSHY_TOKENIZER_DIR=/path/to/qwen3.5-tokenizer-folder
```

## On the CUDA machine

You need Linux, an NVIDIA GPU and CUDA 12. Install PyTorch to match your CUDA version first,
then the other packages.

```bash
pip install torch --index-url https://download.pytorch.org/whl/cu124
pip install -r scripts/finetune/cuda/requirements.txt
```

`scripts/finetune/cuda/requirements.txt` has these notes in its header and lists two optional
packages that speed up Qwen3.5's attention layers. Copy the repository, or at least `scripts/`,
`training/` and your data folders, to this machine.

The trainer is `scripts/finetune/cuda/train_cuda.py`. It takes one config file and reads
`train.jsonl` and `valid.jsonl` from the config's `data_dir`.

## Folders the scripts write

All outputs go under `.build/`, which git ignores.

| Folder | What goes there |
|---|---|
| `.build/public-data/meeting-extract/` | Corpora, staged rows and the training files for the meeting recipe |
| `.build/public-data/cleanup-public/` | The training files for the cleanup recipe |
| `.build/runs/` | Trainer output, one folder per config |

The data and training commands on these pages never touch your Hushy data folder.
