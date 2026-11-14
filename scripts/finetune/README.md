# scripts/finetune — cleanup-model fine-tune (M7)

Recipe, data card and results: [`docs/product/FINETUNE.md`](../../docs/product/FINETUNE.md).
This file is the operator's guide: what runs where, what to copy between machines.
Score public dictation outputs against references with `python3 -I scripts/retrain_public_eval.py score --outputs PATH --references PATH --verdicts PATH`.

## The pieces

| File | Runs on | What it does |
|---|---|---|
| `finetune.sh data` | Mac | Builds the synthetic dataset: dev-set shapes → CLI-LLM content → templates → rules drafts + production guards → Jev filter → balance/split → `train.jsonl`/`valid.jsonl` + `manifest.json` |
| `content_scan.py` | Mac | Content-loss scans over dev reports: lost words before a hedge, Jev `dropped_content` ≥ 0.6 by case id (run after every eval) |
| `build_data.py`, `templates.py`, `llm_prompts.py`, `shapes.py`, `pathguard.py` | Mac | The data builder (Python 3.12, stdlib only) |
| `murmur-eval finetune prompt/prepare/jev/llm/export` | Mac | The Swift half: compact prompt, rules drafts, guards, Jev, CLI LLM, export (same code the app runs) |
| `run_dev_evals.sh`, `jev_ab.py` | Mac | Dev-set evals through the Swift runtime; pointwise Jev A/B over their outputs |
| `train_mlx.py`, `configs/mlx-*.yaml`, `finetune.sh smoke` | Mac | `mlx_lm.lora` with the exact non-thinking template; smoke run only while the Mac serves live dictation |
| `cuda/train.sh`, `cuda/train_cuda.py`, `cuda/merge.py`, `cuda/configs/*.yaml` | Linux + NVIDIA | PEFT LoRA/QLoRA on the original bf16 Hugging Face weights, then merge |
| `convert_mlx.sh` (`finetune.sh convert`) | Mac | Merged HF checkpoint → 4-bit MLX (group 64) for the Swift runtime |
| `finetune.sh eval <mlx-dir> <label>` | Mac | All cleanup dev sets with `--mlx-prompt compact`, plus the warm-latency probe |
| `tools/build_tools_data.py` (+ `banks`, `positives`, `refusals`, `asr`, `tool_llm`, `mix_cleanup`) | Mac | The voice-actions (tools-v1) dataset: slot-grammar labels, LLM content + paraphrases, verified not-a-command dictation, `murmur-eval finetune tools-check/tools-export`, cleanup replay mix |
| `cuda/configs/*-tools.yaml` | Linux + NVIDIA | Voice-actions presets: long rows, `answer_only_logits`, base = the cleanup run's merged checkpoint |
| `tests/` | Mac | `python3 -m unittest discover -s scripts/finetune/tests -p "test_*.py"` (from the repo root, includes eval-stats) — path guard, manifest proof, contamination filter, templates, tools labels |

Data rule (enforced in code, both languages): nothing is read from `Evals/heldout-v2*`, the
sealed actions held-out set, Voice Lab or `~/Library/Application Support/Hushy`; any path
containing `heldout`/`voicelab` is refused, `Evals/` reads are limited to an allow-list of dev
sets, and `manifest.json` lists every file read or written with its SHA-256 plus a
`heldoutProof` section. Training rows sharing an 8-gram with any dev text are dropped.

## Mac: build the data (and optionally a smoke run)

```sh
scripts/finetune/finetune.sh data     # → .build/finetune/data/{mlx/train.jsonl,mlx/valid.jsonl,manifest.json,pairs.jsonl}
scripts/finetune/finetune.sh smoke    # 150-iteration LoRA on Qwen3.5-0.8B-4bit + fuse (pipeline check, ~10 min)
```

Needs: Xcode toolchain (`swift build`), the Metal toolchain for `scripts/build-mlx-metallib.sh`,
`uv`, the `claude` CLI logged in (content generation, ~130 calls, cached under
`.build/finetune-cache/llm/`), and a TypeSafe key for Jev (`~/.config/hushy/typesafe_api_key`;
calls are cached under `.build/judge-cache/jev/` and capped by `jev-ledger.json`).

## CUDA box: train

**Copy over** (`gpu-box` is an SSH alias for a Linux machine with an NVIDIA GPU, 12 GB or more, for example an
RTX 4070 SUPER under WSL2 Ubuntu; work only under `~/hushy-train/`, no sudo):

```sh
rsync -a --exclude runs scripts/finetune/cuda/ gpu-box:hushy-train/cuda/
rsync -a .build/finetune/data/mlx/{train,valid}.jsonl .build/finetune/data/mlx/export.json \
      .build/finetune/data/manifest.json gpu-box:hushy-train/data/
```

Nothing else: no repo, no Evals, no user data. The dataset is synthetic.

```sh
cd ~/hushy-train
python3 -m venv .venv && . .venv/bin/activate
pip install torch --index-url https://download.pytorch.org/whl/cu128   # match the driver's CUDA
pip install -r cuda/requirements.txt       # + flash-linear-attention causal-conv1d for fast Qwen3.5
export PATH=/usr/lib/wsl/lib:$PATH         # nvidia-smi under WSL2
cd cuda
./train.sh configs/smoke-qwen3.5-0.8b.yaml # < 5 min: validates CUDA, bf16, train + merge
./train.sh configs/qwen3.5-0.8b.yaml       # then qwen3-1.7b, qwen3.5-2b (qwen3.5-4b-qlora if we step up)
```

Presets are sized for 12 GB with ~1.6 GB taken by the Windows desktop (estimates, replaced by the
measured `peak_mem_gb` after the first run): smoke ~5 GB · 0.8B bf16 LoRA b4×4 ~6.5 GB · 1.7B bf16
b4×4 ~7.5 GB · 2B bf16 b2×8 ~8.5 GB · 4B QLoRA b2×8 ~8 GB. Unsloth also supports Ada and could
cut memory further; the PEFT path is kept because it needs no custom kernels.

Each run writes `runs/<model>/adapter/`, `runs/<model>/merged/` (bf16 safetensors, original
structure and config, tokenizer + chat template) and `runs/<model>/train_summary.json` (loss curve,
minutes, **measured peak VRAM**). Early stopping on the validation loss; ≤ 2 epochs.

**Copy back**: `runs/<model>/merged/` and `runs/<model>/train_summary.json`, then delete the
run's `checkpoints/` on the box to keep its disk tidy.

## Voice actions (tools-v1): build the data, train on top of the cleanup model

Data card and decisions: `docs/product/FINETUNE.md` "Voice actions data v1".

```sh
swift build --product murmur-eval                    # needs the finetune tools-* subcommands
python3 scripts/finetune/tools/build_tools_data.py --out <dir> \
    --cleanup-pairs <cleanup build>/pairs.jsonl       # the winning cleanup round; replay share defaults to 40% (v2)
# → <dir>/mlx/{train,valid}.jsonl (tools + cleanup replay), <dir>/mlx-tools/export.json
#   (prompt version, system SHA-256, grammar), <dir>/manifest.json (held-out proof)
```

The model is married to the tools prompt (`VoiceToolCatalog.promptVersion`, `tools-v1-prompt-1`)
and to the **`tool-first`** envelope order: evaluate and run it with `--mlx-tool-grammar tool-first`
(`HUSHY_MLX_TOOL_GRAMMAR=tool-first`), never the default `strict` order.

Copy to the box (the cleanup model's `runs/<model>/merged` must still be there — it is the base):

```sh
rsync -a --exclude runs scripts/finetune/cuda/ gpu-box:hushy-train/cuda/
rsync -a <dir>/mlx/{train,valid}.jsonl <dir>/mlx-tools/export.json <dir>/manifest.json gpu-box:hushy-train/data-tools/
# on the box
cd ~/hushy-train/cuda
./train.sh configs/smoke-qwen3.5-0.8b-tools.yaml   # ~5 min: long rows + answer-only logits work
./train.sh configs/qwen3.5-2b-tools.yaml           # then qwen3.5-0.8b-tools (and 4b-qlora-tools for the ceiling)
```

Then on the Mac: `finetune.sh convert` as below, and evaluate **both** skills — `murmur-eval tools
--backend mlx --mlx-model <out> --mlx-tool-grammar tool-first` on `Evals/actions-tools-dev.json`,
and `finetune.sh eval <out> <label>` for cleanup (must stay within 1 point of the base checkpoint).

## Mac: convert and evaluate

```sh
scripts/finetune/finetune.sh convert ~/Downloads/qwen3.5-2b/merged .build/finetune/models/qwen3.5-2b-ft-4bit
scripts/finetune/finetune.sh eval .build/finetune/models/qwen3.5-2b-ft-4bit qwen3.5-2b-ft
python3 scripts/finetune/jev_ab.py --runs apple=<apple run dir> ft=.build/finetune/eval/qwen3.5-2b-ft \
    --out .build/finetune/eval/ab-ft --max-calls 80 --ledger .build/finetune/jev-ledger.json
```

Always evaluate the **4-bit MLX artifact through the Swift runtime** (`--backend mlx --mlx-prompt
compact`), never the adapter in Python: re-quantisation and template drift are both real.

### Quantisation recipe (measured 2026-09-27, `docs/product/INFERENCE-OPTIMIZATION.md` §5)

Quantise the merged bf16 model with plain affine RTN, group 64, text-only (`convert_mlx.sh`):

| Artifact | Command | Size | Why |
|---|---|---|---|
| 0.8B, 8 GB tier | `finetune.sh convert <merged> <out> 4` | ~0.40 GB | 4/5/6/8-bit scored the same on the zero-shot 0.8B |
| 2B, base chips | `finetune.sh convert <merged> <out> 4` | ~1.01 GB | the latency-safe point |
| 2B, Pro/Max 16 GB+ | `finetune.sh convert <merged> <out> 6` | ~1.46 GB | zero-shot: +3/+5/+6 points (cleanup-hybrid / Clean / Polished) over 4-bit; with speculation as fast as 4-bit without |

Evaluate the 2B at **both** 4 and 6 bits through Swift and keep 6-bit only if it still wins by
≥ 2 points after the fine-tune (the fine-tune may absorb part of the gap). Don't use: 3-bit or
`mixed_3_6` (0.8B runs away on 14–24 of 30 long drafts; 2B −6…−11 points), `q4g32` /
`mixed_4_6` / an 8-bit embedding (no gain for +4–25% size), DWQ (`mlx_lm.dwq` runs out of GPU memory
on a 24 GB Mac through the gated-delta layers, even for the 0.8B at 2×256 tokens), GPTQ
(`mlx_lm.quant.gptq`, in-domain calibration: the 2B ran away on long drafts) or KV-cache
quantization (Qwen3.5 has 6 attention layers with 2 KV heads — nothing to save).

## VRAM estimate (short prompt; not yet measured on the GPU)

Sequences are short: compact system prompt ≈ 250 tokens + draft + answer, p50 ≈ 320 and
max ≈ 700 tokens (`max_seq_length: 768`). Gradient checkpointing on. The biggest single term is
the logits: Qwen3.5's 248k-token vocabulary makes `batch × seq × vocab` ≈ 3 GB at batch 4 and
≈ 6 GB at batch 8 (fp32 loss upcast included); Qwen3's 152k vocabulary is ~60% of that.
Weights: bf16 = 2 bytes/param; NF4 ≈ 0.56 bytes/param with the (tied) embedding kept in bf16.

| Model (params incl. embeddings) | bf16 LoRA, batch 8 | bf16 LoRA, batch 4 | QLoRA (NF4), batch 4 | Fits |
|---|---|---|---|---|
| Qwen3.5-0.8B (0.87B) | ~10 GB | ~6.5 GB | ~5.5 GB | any 8 GB card (QLoRA or bf16 b4) |
| Qwen3-1.7B (1.7B) | ~10 GB | ~8 GB | ~5.5 GB | 8 GB with QLoRA, 12 GB bf16 |
| Qwen3.5-2B (2.3B) | ~13.5 GB | ~10 GB | ~7.5 GB | 12 GB bf16 b4, 16 GB bf16 b8 |
| Qwen3.5-4B (4.7B) | ~19 GB | ~16 GB | ~9.5 GB | 12 GB with QLoRA, 24 GB bf16 |

Includes ~1 GB CUDA context, LoRA rank 32 (16 for 0.8B) with fp32 Adam states (0.1–1 GB), and
checkpointed activations (0.4–1.2 GB). Keep the effective batch at 16 with
`grad_accumulation_steps`. Prefer bf16 LoRA over QLoRA when it fits — we quantise to 4-bit after
merging anyway, and QLoRA adds a second quantisation error. The first real run's
`train_summary.json` `peak_mem_gb` replaces these estimates.

Time, ~4k rows × 2 epochs ≈ 2.6M tokens: minutes per run on a 24 GB RTX-class card for 0.8B–2B,
~15–30 min for 4B. Qwen3.5's Gated DeltaNet layers need `flash-linear-attention` +
`causal-conv1d` for speed; without them transformers uses a slow PyTorch path (several × slower).

## Reviewed broad Clean pilot (October 3 branch experiment)

A separate `murmur-eval finetune broad-export` path requires independently annotated plus explicit root-adjudicated, hash-pinned source records and named development contamination indexes. It uses the runtime whole-text request renderer and actual rules/context preparation. See `docs/engineering/GRAMMAR-EDIT-PROPOSALS.md`; v4 legacy prepare/export stays blocked. Never substitute evaluation cases for synthetic training records. The initial118-row export is historical; corrected complete-system merged exports contain282 train/56 validation conversations. They remain a narrow, correlated synthetic pilot, not a production training corpus.

### Merge reviewed exports without duplicate weighting

`python3 scripts/finetune/combine_reviewed_exports.py --source .build/finetune/<reviewed-export-a> --source .build/finetune/<reviewed-export-b> --out .build/finetune/<new-directory>` verifies split hashes against each runtime export manifest, preserves split membership, rejects conflicting targets, removes exact conversations, and writes an immutable derivation ledger. Source exports retain annotation provenance and contamination checks. Do not substitute evaluation fixtures or private dictations as source data.

### Runtime-visible review and prospective v2 validation

Before reviewing new synthetic targets, render the exact prepared model input rather than relying
on author-only scenario notes:

```sh
.build/debug/murmur-eval finetune broad-review-packet --in <synthetic-candidates.jsonl> --out .build/finetune/<new-packet.json>
.build/debug/murmur-eval finetune broad-validate-v2 --in <synthetic-candidates.jsonl> --review-v2 <independent-review-v2.json> --out .build/finetune/<new-validation.json>
```

Outputs must be new files beneath `.build/finetune`; path/sealed-data guards apply. Packet hashes
identify exact source/row/prepared-target/request bytes. External narrative and rationale remain
annotations, not runtime context. A null hard veto is not semantic approval. The v2 ledger requires
actual independent runtime-only review and reviewed relationship metadata; documentation examples
and an empty ledger are not approvals. Components keep related variants together and reject
contradictory targets. Reports include rejection reasons and nonempty-split feasibility.

These commands write no training examples. Legacy export behavior is unchanged. The schema and
relationship rules are documented in `handbook/src/content/docs/models/fine-tuning-pipeline.mdx`.
The new120-row draft failed review105/120 and68families; do not train it or silently upgrade its
old ledger. Completion-loss audit found no mask defect; mostly copied output makes scalar loss
insufficient to assess repair learning. See the October 3 qualification, diversity, semantic review
and objective audit reports under `docs/research/`. Consumed qualification and competitors' outputs
remain permanently excluded from training.
