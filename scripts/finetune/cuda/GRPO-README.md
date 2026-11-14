# Arm D GRPO trial (Job 52)

Run on the Linux training PC, from the repo root, in its existing Python 3.12 CUDA venv. The orchestrator copies `.build/grpo-data/train.jsonl` there; no validation or test set enters training. The config points to the local arm D merged bf16 checkpoint, and uses only local model files. No vLLM, network, or package install is part of this recipe.

```bash
mkdir -p ~/hushy-train/grpo-data
cp .build/grpo-data/train.jsonl ~/hushy-train/grpo-data/train.jsonl
python scripts/finetune/cuda/grpo_cuda.py --config scripts/finetune/cuda/configs/grpo-qwen3.5-4b-qlora.yaml --select
python scripts/finetune/cuda/grpo_cuda.py --config scripts/finetune/cuda/configs/grpo-qwen3.5-4b-qlora.yaml --max-steps 100
python scripts/finetune/cuda/merge.py --config scripts/finetune/cuda/configs/grpo-qwen3.5-4b-qlora.yaml
```

The first command runs one greedy arm D answer for each of the 7,009 training rows, saves IDs of answers scoring below 3.0 plus the same number of seeded random rows from the remainder in `~/hushy-train/cuda/runs/r5grpo-qwen3.5-4b-qlora/selection.json`. If fewer ordinary rows remain, it takes all of them. This score selection catches short corrections and questions that arm D mishandles without hand-picked phrase rules. Selection may take hours; it is a one-time scan. The second command trains a rank-16 LoRA on 4-bit NF4 arm D with group size 4, learning rate 5e-6, beta 0.02, and gradient checkpointing. It writes checkpoints, `adapter/`, and numeric per-call reward component means (tagged with step) to `reward-components.jsonl`. The third command writes `merged/`; it loads the bf16 base, so it may need system RAM, not just the 12 GB GPU. Resume happens from the latest checkpoint.

TRL 1.15's GRPO uses one `max_completion_length` for the whole batch. The runner sets it to 1.5 times the longest selected reference (up to 160 tokens); the length reward penalizes excess relative to each row. This is less strict for a very short row than a per-row generation cap. The reference policy for the positive KL term is the starting model with the new LoRA disabled, as TRL does for PEFT training. The output must be exactly a JSON object with a single string `text` member. The rewrite check gates all rewards to zero for replies; it follows the Swift account's letters and alignment rule. Component weights are format +0.5, word similarity +4.0, lost facts -0.4, retained retractions -0.3, length excess -0.3. Similarity dominates so copying the input when the reference corrected it loses to the reference. Facts, retractions, and length are smaller nudges.

**Memory estimate:** NF4 double-quantized 4B base is roughly 2.1–2.6 GiB; unquantized vision modules and embeddings, LoRA/optimizer state, four sampled completions, reference-policy/KL logits, and CUDA workspace add about 5–7 GiB. Expect roughly **8–10.5 GiB peak**, with a real risk of crossing the 10.7 GiB available limit on long prompts. The CUDA allocation printed at exit and `nvidia-smi` give the actual figure. Estimate **20–45 minutes per 100 optimizer steps** (400 sampled completions plus gradients and KL), depending strongly on prompt lengths and checkpoint overhead. Neither estimate is measured. If it runs out of memory, shorten `max_prompt_length` and `max_completion_length` in the config before changing group size or removing KL.

A CPU plumbing check, after providing an already-local tiny causal model directory and a small training-only JSONL under the configured `data_dir`, is:

```bash
python scripts/finetune/cuda/grpo_cuda.py --config scripts/finetune/cuda/configs/grpo-qwen3.5-4b-qlora.yaml --cpu-dry-run --tiny-model /path/to/local/tiny-model --select
python scripts/finetune/cuda/grpo_cuda.py --config scripts/finetune/cuda/configs/grpo-qwen3.5-4b-qlora.yaml --cpu-dry-run --tiny-model /path/to/local/tiny-model --max-steps 1
```

Fake quant is omitted: `mlx_fake_quant.py` is absent in this worktree, and TRL's generation plus KL path has no supported drop-in fake-quant hook. CPU dry run is not an accuracy or memory estimate for Qwen3.5. The GPU run, Qwen3.5 multimodal loading under TRL 1.15, and reward improvements remain unproven until the PC run.
