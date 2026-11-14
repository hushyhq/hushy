#!/usr/bin/env python3
"""LoRA / QLoRA fine-tune of a Qwen cleanup model on a Linux CUDA box (Hugging Face PEFT).

    python train_cuda.py --config configs/qwen3.5-2b.yaml

Same data files as the Mac path (`train.jsonl` / `valid.jsonl` from
`murmur-eval finetune export`: chat rows of compact system prompt, "Transcript: …\\nOutput:"
user turn, and the exact `{"text":"…"}` answer), rendered with the model's own chat template in
non-thinking mode, loss on the answer tokens only. Trains on the original bf16 Hugging Face
weights; `merge.py` folds the adapter back in, and the Mac converts the merged model to 4-bit
MLX (`../convert_mlx.sh`) for evaluation through the Swift runtime.

The voice-actions data (`scripts/finetune/tools`, `configs/*-tools.yaml`) uses the same format:
tools-v1 system prompt, "Now: …\nUtterance: …" user turn, the exact tool envelope as the
answer, mixed with a replayed cleanup slice. Its rows are ~4× longer, so those presets set
`answer_only_logits: true` (`AnswerOnlyTrainer`: logits for the answer positions only) and
usually start from the cleanup fine-tune's merged checkpoint instead of the Hugging Face base.

Qwen3.5 checkpoints are multimodal (`Qwen3_5ForConditionalGeneration`); they are loaded with
their own class and trained text-only, and LoRA only touches the language model's layers, so the
merged checkpoint has exactly the original structure (what `mlx_lm.convert` expects).
"""

from __future__ import annotations

import argparse
import json
import math
import os
import random
import time
from pathlib import Path
from typing import Any

import torch
import yaml
from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training
from torch.utils.data import Dataset
from transformers import (
    AutoConfig,
    AutoModelForCausalLM,
    AutoTokenizer,
    EarlyStoppingCallback,
    Trainer,
    TrainerCallback,
    TrainingArguments,
)

# Language-model projections only (attention, Gated DeltaNet linear attention, MLP); the vision
# tower's modules (`blocks.N.attn.qkv`, `…proj`, `linear_fc*`) never match.
DEFAULT_TARGETS = (
    r".*layers\.\d+\.(self_attn\.(q_proj|k_proj|v_proj|o_proj)"
    r"|linear_attn\.(in_proj_qkv|in_proj_z|out_proj)"
    r"|mlp\.(gate_proj|up_proj|down_proj))$"
)


def load_config(path: str) -> dict[str, Any]:
    with open(path, encoding="utf-8") as handle:
        config = yaml.safe_load(handle)
    for key in ("base_model", "data_dir", "output_dir"):
        if not config.get(key):
            raise SystemExit(f"config: '{key}' is required")
    for key in ("data_dir", "output_dir"):
        if "heldout" in str(config[key]).lower() or "voicelab" in str(config[key]).lower():
            raise SystemExit(f"config: refusing {key}={config[key]!r} (held-out / Voice Lab paths are never used)")
    return config


def model_class(base: str):
    config = AutoConfig.from_pretrained(base, trust_remote_code=False)
    if getattr(config, "vision_config", None) is not None:
        from transformers import AutoModelForImageTextToText

        return AutoModelForImageTextToText
    return AutoModelForCausalLM


class ChatRows(Dataset):
    """Tokenised chat rows: labels are -100 on the prompt, the answer is trained."""

    def __init__(self, path: Path, tokenizer, max_len: int) -> None:  # noqa: ANN001
        self.items: list[dict[str, list[int]]] = []
        skipped = 0
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                if not line.strip():
                    continue
                messages = json.loads(line)["messages"]
                full = tokenizer.apply_chat_template(messages, tokenize=False, enable_thinking=False)
                prompt = tokenizer.apply_chat_template(
                    messages[:-1], tokenize=False, add_generation_prompt=True, enable_thinking=False
                )
                if not full.startswith(prompt):
                    raise ValueError("chat template: prompt is not a prefix of the conversation")
                prompt_ids = tokenizer(prompt, add_special_tokens=False)["input_ids"]
                answer_ids = tokenizer(full[len(prompt) :], add_special_tokens=False)["input_ids"]
                ids = prompt_ids + answer_ids
                if len(ids) > max_len:
                    skipped += 1
                    continue
                self.items.append({"input_ids": ids, "labels": [-100] * len(prompt_ids) + answer_ids})
        print(f"{path.name}: {len(self.items)} rows ({skipped} over {max_len} tokens skipped)")

    def __len__(self) -> int:
        return len(self.items)

    def __getitem__(self, index: int) -> dict[str, list[int]]:
        return self.items[index]


def collate(pad_id: int, answer_only: bool = False):
    """Pads a batch. With `answer_only`, pads on the left (every answer ends the row) and adds
    `keep`: how many trailing positions need logits (longest answer + 1)."""

    def _collate(batch: list[dict[str, list[int]]]) -> dict[str, torch.Tensor]:
        width = max(len(row["input_ids"]) for row in batch)
        ids = torch.full((len(batch), width), pad_id, dtype=torch.long)
        labels = torch.full((len(batch), width), -100, dtype=torch.long)
        mask = torch.zeros((len(batch), width), dtype=torch.long)
        for i, row in enumerate(batch):
            n = len(row["input_ids"])
            span = slice(width - n, width) if answer_only else slice(0, n)
            ids[i, span] = torch.tensor(row["input_ids"])
            labels[i, span] = torch.tensor(row["labels"])
            mask[i, span] = 1
        out = {"input_ids": ids, "labels": labels, "attention_mask": mask}
        if answer_only:
            answer = max(sum(1 for label in row["labels"] if label != -100) for row in batch)
            out["keep"] = torch.tensor(min(width, answer + 1))
        return out

    return _collate


class AnswerOnlyTrainer(Trainer):
    """Computes logits only for the answer positions (`logits_to_keep`), not the whole prompt.

    The tools rows carry a ~1,350-token system prompt and a ~100-token answer; with a 248k
    vocabulary the full-sequence logits (batch × seq × vocab, upcast to fp32 for the loss) are the
    largest memory term and a large share of the compute, yet only the answer is trained. Rows are
    left-padded, so the last `keep` positions cover every answer: position p predicts token p+1,
    so logits[:, :-1] line up with labels[:, -(keep-1):]. Same loss as the default, summed over
    answer tokens and divided by the batch's token count (so gradient accumulation stays exact).
    """

    def compute_loss(self, model, inputs, return_outputs=False, num_items_in_batch=None):  # noqa: ANN001
        labels = inputs.pop("labels")
        keep = int(inputs.pop("keep"))
        outputs = model(**inputs, logits_to_keep=keep)
        logits = outputs.logits[:, :-1, :].float()
        targets = labels[:, -(keep - 1):].to(logits.device)
        loss = torch.nn.functional.cross_entropy(
            logits.reshape(-1, logits.size(-1)), targets.reshape(-1), ignore_index=-100, reduction="sum")
        count = num_items_in_batch if num_items_in_batch is not None else (targets != -100).sum()
        loss = loss / count
        return (loss, outputs) if return_outputs else loss


class PeakMemory(TrainerCallback):
    def on_log(self, args, state, control, logs=None, **kwargs):  # noqa: ANN001, ANN003
        if torch.cuda.is_available() and logs is not None:
            logs["peak_mem_gb"] = round(torch.cuda.max_memory_allocated() / 2**30, 2)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--fresh", action="store_true", help="ignore existing checkpoints and start over")
    parser.add_argument("--cpu-dry-run", action="store_true",
                        help="fp32 on CPU, no workers — only to check the code path on a machine without CUDA")
    args = parser.parse_args()
    config = load_config(args.config)
    dtype = torch.float32 if args.cpu_dry_run else torch.bfloat16
    train_cfg, lora_cfg = config.get("train", {}), config.get("lora", {})
    seed = int(train_cfg.get("seed", 7))
    random.seed(seed)
    torch.manual_seed(seed)

    out = Path(config["output_dir"])
    out.mkdir(parents=True, exist_ok=True)
    tokenizer = AutoTokenizer.from_pretrained(config["base_model"])
    pad_id = tokenizer.pad_token_id if tokenizer.pad_token_id is not None else tokenizer.eos_token_id

    quant = str(config.get("quantization", "none")).lower()
    load_kwargs: dict[str, Any] = {"dtype": dtype}
    if quant in {"4bit", "nf4", "qlora"}:
        from transformers import BitsAndBytesConfig

        load_kwargs["quantization_config"] = BitsAndBytesConfig(
            load_in_4bit=True, bnb_4bit_quant_type="nf4", bnb_4bit_use_double_quant=True,
            bnb_4bit_compute_dtype=torch.bfloat16,
        )
    if config.get("attn_implementation"):
        load_kwargs["attn_implementation"] = config["attn_implementation"]
    cls = model_class(config["base_model"])
    model = cls.from_pretrained(config["base_model"], **load_kwargs)
    model.config.use_cache = False
    if "quantization_config" in load_kwargs and config.get("kbit_fp32_cast", True):
        model = prepare_model_for_kbit_training(model, use_gradient_checkpointing=True)
    elif "quantization_config" in load_kwargs:
        # Gemma 4's edge models carry very large embedding tables that stay unquantised; casting them
        # to float32 (what prepare_model_for_kbit_training does) does not fit a 12 GB card. Freeze the
        # base as loaded, keep its dtype, and turn on checkpointing by hand.
        for param in model.parameters():
            param.requires_grad = False
        model.gradient_checkpointing_enable()
        model.enable_input_require_grads()
    if torch.cuda.is_available():
        print(f"loaded: {torch.cuda.memory_allocated() / 2**30:.2f} GiB allocated on the card", flush=True)

    rank = int(lora_cfg.get("rank", 32))
    model = get_peft_model(model, LoraConfig(
        r=rank, lora_alpha=int(lora_cfg.get("alpha", 2 * rank)), lora_dropout=float(lora_cfg.get("dropout", 0.05)),
        target_modules=lora_cfg.get("target_modules", DEFAULT_TARGETS), bias="none", task_type="CAUSAL_LM",
    ))
    model.print_trainable_parameters()

    data = Path(config["data_dir"])
    max_len = int(train_cfg.get("max_seq_length", 768))
    train_set = ChatRows(data / "train.jsonl", tokenizer, max_len)
    valid_set = ChatRows(data / "valid.jsonl", tokenizer, max_len)
    if train_cfg.get("max_train_rows"):  # smoke preset: a small, fixed slice
        train_set.items = train_set.items[: int(train_cfg["max_train_rows"])]
        valid_set.items = valid_set.items[: max(16, int(train_cfg["max_train_rows"]) // 10)]
    if train_cfg.get("max_valid_rows"):  # long rows: evaluate on a fixed slice (the file is shuffled)
        valid_set.items = valid_set.items[: int(train_cfg["max_valid_rows"])]
    answer_only = bool(train_cfg.get("answer_only_logits", False))

    batch = int(train_cfg.get("batch_size", 8))
    accumulation = int(train_cfg.get("grad_accumulation_steps", 2))
    epochs = float(train_cfg.get("epochs", 2))
    steps_per_epoch = math.ceil(len(train_set) / (batch * accumulation))
    eval_steps = int(train_cfg.get("eval_steps", max(20, steps_per_epoch // 4)))
    training_args = TrainingArguments(
        output_dir=str(out / "checkpoints"), per_device_train_batch_size=batch, per_device_eval_batch_size=batch,
        gradient_accumulation_steps=accumulation, num_train_epochs=epochs, max_steps=int(train_cfg.get("max_steps", -1)),
        learning_rate=float(train_cfg.get("learning_rate", 1e-4)), lr_scheduler_type="cosine",
        warmup_steps=max(1, int(0.05 * (int(train_cfg.get("max_steps", 0)) or steps_per_epoch * epochs))),
        weight_decay=0.0, bf16=not args.cpu_dry_run, use_cpu=args.cpu_dry_run, logging_steps=10, eval_strategy="steps", eval_steps=eval_steps,
        save_strategy="steps", save_steps=eval_steps, save_total_limit=2, load_best_model_at_end=True,
        metric_for_best_model="eval_loss", greater_is_better=False, gradient_checkpointing=True,
        gradient_checkpointing_kwargs={"use_reentrant": False}, report_to="none", seed=seed,
        dataloader_num_workers=0 if args.cpu_dry_run else 2, remove_unused_columns=False,
        prediction_loss_only=answer_only,
    )
    trainer = (AnswerOnlyTrainer if answer_only else Trainer)(
        model=model, args=training_args, train_dataset=train_set, eval_dataset=valid_set,
        data_collator=collate(pad_id, answer_only),
        callbacks=[EarlyStoppingCallback(early_stopping_patience=int(train_cfg.get("patience", 3))), PeakMemory()],
    )
    started = time.time()
    # Resume after an interruption (the box sleeping mid-run): the newest checkpoint under
    # <output_dir>/checkpoints carries model, optimizer, scheduler and data-order state.
    checkpoints = sorted((out / "checkpoints").glob("checkpoint-*"), key=lambda p: int(p.name.split("-")[-1]))
    resume = str(checkpoints[-1]) if checkpoints and not args.fresh else None
    if resume:
        print(f"resuming from {resume}")
    trainer.train(resume_from_checkpoint=resume)
    minutes = (time.time() - started) / 60
    metrics = trainer.evaluate()
    trainer.model.save_pretrained(str(out / "adapter"))
    tokenizer.save_pretrained(str(out / "adapter"))
    summary = {
        "base_model": config["base_model"], "quantization": quant, "rank": rank, "answer_only_logits": answer_only,
        "train_rows": len(train_set),
        "valid_rows": len(valid_set), "minutes": round(minutes, 1), "final_eval_loss": metrics.get("eval_loss"),
        "peak_mem_gb": round(torch.cuda.max_memory_allocated() / 2**30, 2) if torch.cuda.is_available() else None,
        "gpu": torch.cuda.get_device_name(0) if torch.cuda.is_available() else None,
        "log_history": trainer.state.log_history,
    }
    with open(out / "train_summary.json", "w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2)
    print(json.dumps({k: v for k, v in summary.items() if k != "log_history"}, indent=2))


if __name__ == "__main__":
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
    main()
