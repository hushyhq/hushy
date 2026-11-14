---
title: Convert and run
description: Merge the adapter, convert the model to MLX on the Mac, and try it on a few cases.
---

The trainer leaves a LoRA adapter. The Mac runs a merged, 4-bit MLX model. Two commands cover the
gap, one on the CUDA machine and one on the Mac.

## 1. Merge the adapter

On the CUDA machine, run `merge.py` with the same config you trained with. It folds the adapter
into the base weights and saves a plain Hugging Face checkpoint.

```bash
python scripts/finetune/cuda/merge.py --config training/configs/cleanup-public.yaml
```

The checkpoint lands in the `merged/` folder next to `adapter/`, for example
`.build/runs/cleanup-public-qwen3.5-4b/merged/`. It holds the safetensors weights, the tokenizer
and the chat template. Copy that folder to the Mac.

## 2. Convert to MLX

On the Mac:

```bash
scripts/finetune/convert_mlx.sh <merged-folder> <mlx-output-folder>
```

This makes a 4-bit model with group size 64 by default. A third argument sets the bits to 4, 5, 6
or 8. The script drops the vision tower, so the output is text only. It needs the Python
environment from [Set up](/train/setup/).

## 3. Try it

Build MLX's GPU kernels once. This needs Apple's Metal Toolchain.

```bash
xcodebuild -downloadComponent MetalToolchain
scripts/build-mlx-metallib.sh
```

Then run the model on your own cases. The prompt must match the one you trained with. This command
writes the app's prompt to a file in the layout the evaluator reads.

```bash
python3 training/chat_rows.py --write-prompt-file .build/cleanup-prompt.txt
```

Write a few cases as JSON lines, each with an `id` and the recogniser's `spoken` text, and run them.

```bash
swift run murmur-eval intent-run --model <mlx-output-folder> --cases cases.jsonl \
  --system .build/cleanup-prompt.txt --out out.jsonl
```

The output file holds the model's text for each case. The command is meant for invented or public
text only.

## 4. Use it in the app

The app loads local models from a registry in `Sources/MurmurCore/LanguageModel/ModelRegistry.swift`.
Each entry pins a source, file sizes and hashes, a licence and a prompt profile, and the file's own
comments say a fine-tuned model is a new entry and not a new code path. Adding your model means
adding an entry and rebuilding the app. We have not tried this with a model trained from the public
configs, so treat that step as unverified.

Before you use a model, measure it. See [Measure accuracy](/measure/accuracy/).
