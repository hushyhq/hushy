#!/usr/bin/env python3
"""Loss curve (PNG + CSV) from a CUDA run's `train_summary.json` (Hugging Face log_history).

    python3 scripts/finetune/plot_loss.py <train_summary.json> <out-prefix> "<title>"

Writes <out-prefix>.csv (step, epoch, split, loss, learning_rate, peak_mem_gb) and <out-prefix>.png.
Needs matplotlib (the fine-tune venv: scripts/finetune/venv.sh, then `uv pip install matplotlib`).
"""

from __future__ import annotations

import csv
import json
import sys
from pathlib import Path


def rows(summary: dict) -> list[dict]:
    out = []
    for entry in summary.get("log_history", []):
        step = entry.get("step")
        if "loss" in entry:
            out.append({"step": step, "epoch": entry.get("epoch"), "split": "train", "loss": float(entry["loss"]),
                        "learning_rate": entry.get("learning_rate"), "peak_mem_gb": entry.get("peak_mem_gb")})
        if "eval_loss" in entry:
            out.append({"step": step, "epoch": entry.get("epoch"), "split": "valid", "loss": float(entry["eval_loss"]),
                        "learning_rate": None, "peak_mem_gb": entry.get("peak_mem_gb")})
    return out


def main() -> None:
    summary_path, prefix, title = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
    summary = json.loads(summary_path.read_text())
    data = rows(summary)
    prefix.parent.mkdir(parents=True, exist_ok=True)
    with open(Path(f"{prefix}.csv"), "w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=["step", "epoch", "split", "loss", "learning_rate", "peak_mem_gb"])
        writer.writeheader()
        writer.writerows(data)

    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, ax = plt.subplots(figsize=(6.4, 3.6), dpi=120)
    train = [r for r in data if r["split"] == "train"]
    valid = [r for r in data if r["split"] == "valid"]
    ax.plot([r["step"] for r in train], [r["loss"] for r in train], "-", color="#3b6fb6", label="train loss (answer tokens)")
    ax.plot([r["step"] for r in valid], [r["loss"] for r in valid], "s--", color="#d9822b", label="validation loss")
    best = min(valid, key=lambda r: r["loss"]) if valid else None
    if best:
        ax.annotate(f"best {best['loss']:.3f}", (best["step"], best["loss"]), textcoords="offset points", xytext=(0, 10),
                    ha="center", fontsize=8, color="#d9822b")
    ax.set_yscale("log")
    ax.set_xlabel("optimizer step (effective batch 16)")
    ax.set_ylabel("cross-entropy (log scale)")
    ax.set_title(title, fontsize=10)
    ax.grid(alpha=0.3, which="both")
    ax.legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(Path(f"{prefix}.png"))
    print(f"{prefix}.png / .csv: {len(train)} train points, {len(valid)} validation points")


if __name__ == "__main__":
    main()
