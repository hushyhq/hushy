#!/usr/bin/env python3
"""Loss curves as themed SVG for the handbook, plus a summary table, from each run's `train_summary.json`.

    python3 -I scripts/finetune/plot_loss_svg.py <summaries-dir> <out-dir> [run ...]

<summaries-dir>/<run>/train_summary.json is the Hugging Face log_history our trainer writes (cuda/train_cuda.py).
Each chart draws the training loss (a 9-point moving average over the logged points, raw points faint) and the
evaluation loss (markers), on one loss axis against the optimizer step, with the best evaluation marked. Colours are
the validated categorical slots 1 and 2 (blue, orange); the SVG follows the reader's light or dark setting. Writes
<out-dir>/<run>.svg and prints one JSON line per run (steps, rows, minutes, best eval, peak memory, GPU).
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

W, H = 720, 320
LEFT, RIGHT, TOP, BOTTOM = 64, 150, 34, 46
STYLE = """
<style>
  .surface { fill: #fcfcfb } .ink { fill: #0b0b0b } .ink2 { fill: #52514e } .grid { stroke: #e4e3df }
  .train { stroke: #2a78d6 } .trainfill { fill: #2a78d6 } .eval { stroke: #eb6834 } .evalfill { fill: #eb6834 }
  @media (prefers-color-scheme: dark) {
    .surface { fill: #1a1a19 } .ink { fill: #f0efec } .ink2 { fill: #c3c2b7 } .grid { stroke: #383835 }
    .train { stroke: #3987e5 } .trainfill { fill: #3987e5 } .eval { stroke: #d95926 } .evalfill { fill: #d95926 }
  }
  text { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; font-variant-numeric: tabular-nums }
</style>"""


def nice_ticks(lo: float, hi: float, count: int = 5) -> list[float]:
    span = hi - lo or 1.0
    raw = span / count
    mag = 10 ** __import__("math").floor(__import__("math").log10(raw))
    step = min((m * mag for m in (1, 2, 2.5, 5, 10) if m * mag >= raw), default=mag * 10)
    first = __import__("math").ceil(lo / step) * step
    ticks, value = [], first
    while value <= hi + 1e-12:
        ticks.append(round(value, 10))
        value += step
    return ticks


def smooth(points: list[tuple[float, float]], k: int = 9) -> list[tuple[float, float]]:
    out = []
    for i in range(len(points)):
        window = points[max(0, i - k // 2): i + k // 2 + 1]
        out.append((points[i][0], sum(v for _, v in window) / len(window)))
    return out


def chart(run: str, summary: dict) -> tuple[str, dict]:
    history = summary.get("log_history", [])
    train = [(h["step"], float(h["loss"])) for h in history if "loss" in h and "eval_loss" not in h and "train_runtime" not in h]
    evals = [(h["step"], float(h["eval_loss"])) for h in history if "eval_loss" in h]
    seen: set[int] = set()
    evals = [e for e in evals if not (e[0] in seen or seen.add(e[0]))]   # the final re-evaluation repeats a step
    steps = max([s for s, _ in train + evals] or [1])
    values = [v for _, v in train + evals]
    lo, hi = (min(values), max(values)) if values else (0.0, 1.0)
    pad = (hi - lo) * 0.08 or 0.05
    lo, hi = max(0.0, lo - pad), hi + pad
    px = lambda s: LEFT + (W - LEFT - RIGHT) * s / steps                         # noqa: E731
    py = lambda v: TOP + (H - TOP - BOTTOM) * (1 - (v - lo) / (hi - lo))      # noqa: E731
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" role="img" aria-labelledby="t-{run} d-{run}">',
             f'<title id="t-{run}">{run}: training and evaluation loss by step</title>',
             f'<desc id="d-{run}">{len(train)} logged training losses and {len(evals)} evaluations over {steps} steps.</desc>', STYLE,
             f'<rect class="surface" width="{W}" height="{H}" rx="8"/>']
    for tick in nice_ticks(lo, hi):
        y = py(tick)
        parts.append(f'<line class="grid" x1="{LEFT}" x2="{W - RIGHT}" y1="{y:.1f}" y2="{y:.1f}" stroke-width="1"/>')
        parts.append(f'<text class="ink2" x="{LEFT - 8}" y="{y + 4:.1f}" font-size="11" text-anchor="end">{tick:g}</text>')
    for tick in nice_ticks(0, steps, 6):
        x = px(tick)
        parts.append(f'<text class="ink2" x="{x:.1f}" y="{H - BOTTOM + 18}" font-size="11" text-anchor="middle">{int(tick)}</text>')
    parts.append(f'<text class="ink2" x="{(LEFT + W - RIGHT) / 2:.0f}" y="{H - 10}" font-size="11" text-anchor="middle">optimizer step</text>')
    parts.append(f'<text class="ink2" x="14" y="{TOP - 14}" font-size="11">loss</text>')
    if train:
        raw = " ".join(f"{px(s):.1f},{py(v):.1f}" for s, v in train)
        parts.append(f'<polyline class="train" points="{raw}" fill="none" stroke-width="1" opacity="0.25"/>')
        line = smooth(train)
        pts = " ".join(f"{px(s):.1f},{py(v):.1f}" for s, v in line)
        parts.append(f'<polyline class="train" points="{pts}" fill="none" stroke-width="2" stroke-linejoin="round"/>')
        s, v = line[-1]
        parts.append(f'<text class="ink" x="{W - RIGHT + 10}" y="{py(v) + 4:.1f}" font-size="12">training {v:.3f}</text>')
    best = min(evals, key=lambda e: e[1]) if evals else None
    if evals:
        pts = " ".join(f"{px(s):.1f},{py(v):.1f}" for s, v in evals)
        parts.append(f'<polyline class="eval" points="{pts}" fill="none" stroke-width="2" stroke-linejoin="round"/>')
        for s, v in evals:
            parts.append(f'<circle class="evalfill" cx="{px(s):.1f}" cy="{py(v):.1f}" r="4" stroke="none"><title>step {s}: evaluation loss {v:.4f}</title></circle>')
        s, v = evals[-1]
        label_y = py(v) + 4
        if train and abs(label_y - (py(smooth(train)[-1][1]) + 4)) < 14:
            label_y += 16
        parts.append(f'<text class="ink" x="{W - RIGHT + 10}" y="{label_y:.1f}" font-size="12">evaluation {v:.3f}</text>')
        bs, bv = best
        parts.append(f'<circle class="surface" cx="{px(bs):.1f}" cy="{py(bv):.1f}" r="7" opacity="0"/>')
        parts.append(f'<circle cx="{px(bs):.1f}" cy="{py(bv):.1f}" r="7" fill="none" class="eval" stroke-width="2"/>')
        parts.append(f'<text class="ink2" x="{px(bs):.1f}" y="{py(bv) - 12:.1f}" font-size="11" text-anchor="middle">best {bv:.3f} (step {bs})</text>')
    parts.append("</svg>")
    meta = {"run": run, "base": summary.get("base_model"), "gpu": summary.get("gpu"), "rows": summary.get("train_rows"),
            "steps": steps, "minutes": summary.get("minutes"), "best_eval": round(best[1], 4) if best else None,
            "best_step": best[0] if best else None, "final_eval": summary.get("final_eval_loss"), "peak_gb": summary.get("peak_mem_gb"),
            "quantization": summary.get("quantization"), "rank": summary.get("rank")}
    return "\n".join(parts) + "\n", meta


def main() -> None:
    src, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    runs = sys.argv[3:] or sorted(p.parent.name for p in src.glob("*/train_summary.json"))
    for run in runs:
        summary = json.loads((src / run / "train_summary.json").read_text())
        svg, meta = chart(run, summary)
        (out / f"{run}.svg").write_text(svg, encoding="utf-8")
        print(json.dumps(meta))


if __name__ == "__main__":
    main()
