"""The cleanup replay slice mixed into the voice-actions training set.

The tools run continues from the cleanup fine-tune (same base, one LoRA per stage, merged), so a
slice of the cleanup data (40% since tools data v2) is replayed to keep that skill (docs/product/FINETUNE.md "Voice actions
data v1", DECISIONS "Voice-actions data v1"). The slice comes from a cleanup build's
`pairs.jsonl` (v3.1 today, v4 when it exists) and is re-derived under *today's* rules and guards
(`murmur-eval finetune prepare`): drafts are recomputed, pairs the current guards reject are
dropped (this is what removes v3.1's unsignalled-list → bullets targets under the list style
contract), and ungrounded targets are dropped. It is then exported with today's compact prompt.

Stratified by (leave-unchanged, level, kind) so the slice keeps the source's mix, and each pair
keeps its original split (a pair the cleanup run validated on is never trained on here).
"""

from __future__ import annotations

import collections
import hashlib
import json
import random
import sys
from pathlib import Path
from typing import Any, Callable

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from build_data import ungrounded_words  # noqa: E402

SEED = 23


def build(args: Any, manifest: Any, tools_rows: int, run_eval: Callable[..., None],
          guarded_jsonl: Callable[[Any, Path], list[dict[str, Any]]]) -> dict[str, Any]:
    out = args.out
    tools_dir, cleanup_dir, mixed = out / "mlx-tools", out / "mlx-cleanup", out / "mlx"
    summary: dict[str, Any] = {"cleanupShare": 0.0, "cleanupRows": 0}
    cleanup_lines: dict[str, list[str]] = {"train": [], "valid": []}
    if args.cleanup_pairs:
        source = guarded_jsonl(manifest, args.cleanup_pairs)
        prepared = prepare(args, manifest, source, run_eval, guarded_jsonl)
        want = round(tools_rows * args.cleanup_share / (1 - args.cleanup_share))
        chosen = stratified(prepared, want)
        manifest.write_jsonl(out / "cleanup-rows.jsonl", chosen)
        run_eval(args.eval_bin, "export", "--in", str(out / "cleanup-rows.jsonl"), "--out-dir", str(cleanup_dir))
        for name in ("train.jsonl", "valid.jsonl", "export.json"):
            manifest.record_write(cleanup_dir / name)
        cleanup_lines = {split: read_lines(cleanup_dir / f"{split}.jsonl") for split in ("train", "valid")}
        export = json.loads((cleanup_dir / "export.json").read_text())
        summary.update({
            "cleanupSource": str(args.cleanup_pairs), "cleanupSourceRows": len(source),
            "cleanupAfterPrepare": len(prepared), "cleanupRows": len(chosen),
            "cleanupUnchangedShare": round(sum(r["unchanged"] for r in chosen) / max(1, len(chosen)), 3),
            "cleanupByLevel": dict(collections.Counter(r["level"] for r in chosen)),
            "cleanupByKind": dict(collections.Counter(r["kind"].split(":")[0] for r in chosen).most_common()),
            "cleanupPromptVersion": export.get("promptVersion"),
        })
    tools_lines = {split: read_lines(tools_dir / f"{split}.jsonl") for split in ("train", "valid")}
    for split in ("train", "valid"):
        lines = tools_lines[split] + cleanup_lines[split]
        lines.sort(key=lambda line: hashlib.sha256(f"{SEED}|{line}".encode()).hexdigest())
        path = mixed / f"{split}.jsonl"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(line + "\n" for line in lines), encoding="utf-8")
        manifest.record_write(path)
        summary[split] = {"rows": len(lines), "tools": len(tools_lines[split]), "cleanup": len(cleanup_lines[split]),
                          "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    total = summary["train"]["rows"] + summary["valid"]["rows"]
    summary["cleanupShare"] = round((summary["train"]["cleanup"] + summary["valid"]["cleanup"]) / max(1, total), 3)
    return summary


def read_lines(path: Path) -> list[str]:
    return [line for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def prepare(args: Any, manifest: Any, source: list[dict[str, Any]], run_eval: Callable[..., None],
            guarded_jsonl: Callable[[Any, Path], list[dict[str, Any]]]) -> list[dict[str, Any]]:
    """Today's rules draft + guards for every source pair; keeps the ones that still pass."""
    rows = [{"id": r["id"], "level": r["level"], "raw": r["raw"], "target": r["target"], "kind": r["kind"],
             "source": r.get("source", ""), "seedId": r.get("seedId") or r["id"], "split": r.get("split", "train"),
             "negative": r.get("negative", False), **({"protected": r["protected"]} if r.get("protected") else {})}
            for r in source]
    path_in, path_out = args.out / "work/cleanup-prepare-in.jsonl", args.out / "work/cleanup-prepare-out.jsonl"
    manifest.write_jsonl(path_in, rows)
    run_eval(args.eval_bin, "prepare", "--in", str(path_in), "--out", str(path_out))
    prepared = guarded_jsonl(manifest, path_out)
    kept = []
    for r in prepared:
        if r["negative"]:
            # A leave-unchanged pair stays one under today's rules: the target is the new draft.
            r["target"], r["unchanged"], r["rejection"] = r["draft"], True, None
        if not r.get("rejection") and not ungrounded_words(r):
            kept.append(r)
    return kept


def stratified(rows: list[dict[str, Any]], want: int) -> list[dict[str, Any]]:
    """`want` rows drawn proportionally from each (unchanged, level, kind) stratum."""
    rng = random.Random(SEED)
    strata: dict[tuple[bool, str, str], list[dict[str, Any]]] = collections.defaultdict(list)
    for r in rows:
        strata[(bool(r["unchanged"]), r["level"], r["kind"].split(":")[0])].append(r)
    total = len(rows)
    chosen: list[dict[str, Any]] = []
    for key in sorted(strata):
        group = strata[key]
        rng.shuffle(group)
        chosen += group[: round(len(group) * want / max(1, total))]
    rng.shuffle(chosen)
    return chosen[:want]
