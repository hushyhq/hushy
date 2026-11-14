#!/usr/bin/env python3
"""Re-template a group-contract trainset into the shipped compact format (Task 142). No model call.

The shipped app asks for one group with the compact Polished system text, the group's draft and nothing else, and
reads back {"text"}. A group row becomes that: the left context and the paragraph flag are dropped, and because the
model then cannot know whether it continues a sentence, every piece starts with a capital and ends closed, which is
what the shipped stitcher expects. Replay rows return to their original form; rows of other tasks pass through.

    python3 -I scripts/retrain_compact.py --trainset Evals/runs/retrain/h1-trainset \
        --replay Evals/runs/retrain/replay-v5.4/train.jsonl --out Evals/runs/retrain/c1-trainset
"""

import argparse
import hashlib
import json
from pathlib import Path
import random
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "scripts/finetune"))
from pathguard import violation  # noqa: E402
import retrain_seamview as seamview  # noqa: E402

USER = re.compile(r"Left context: [^\n]*\nTranscript: ([^\n]+)\nOutput:")


def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def polished_system(replay_path):
    with open(replay_path, encoding="utf-8") as handle:
        for line in handle:
            system = json.loads(line)["messages"][0]["content"]
            if "Level: Polished." in system and "⟦" not in system.split("Reply with JSON", 1)[0][-400:]:
                return system
    raise ValueError("no Polished row in the replay file")


def convert(row, system):
    if row.get("source") and row["source"] != "legacy_replay":
        return row
    match = USER.fullmatch(row["messages"][1]["content"])
    answer = json.loads(row["messages"][2]["content"])
    text = answer["text"].strip()
    if not row.get("source"):
        text = seamview.capitalised(text if seamview.is_closed(text) else seamview.close_piece(text, "."))
    return {**{k: v for k, v in row.items() if k != "left_context"},
            "messages": [{"role": "system", "content": system},
                         {"role": "user", "content": f"Transcript: {match[1]}\nOutput:"},
                         {"role": "assistant", "content": compact({"text": text})}]}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--trainset", required=True)
    parser.add_argument("--replay", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--clean-rows", type=int, default=0,
                        help="also add this many of the replay file's Clean-level rows, unchanged, so the level the app "
                             "uses outside the default tone is still trained")
    parser.add_argument("--seed", type=int, default=11)
    args = parser.parse_args(argv)
    source, out = Path(args.trainset), Path(args.out)
    if any(violation(Path(p)) for p in (source, out, Path(args.replay))) or out.exists():
        raise SystemExit("refused: a forbidden path, or the output folder exists")
    system = polished_system(args.replay)
    (out / "mlx").mkdir(parents=True)
    counts = {}
    for part in ("train", "valid"):
        rows = [convert(json.loads(line), system) for line in (source / "mlx" / f"{part}.jsonl").open(encoding="utf-8")]
        if part == "train" and args.clean_rows:
            clean = [json.loads(line) for line in open(args.replay, encoding="utf-8")]
            clean = [{"id": r["id"], "passage": f"replay:{r['id']}", "source": "legacy_replay_clean", "messages": r["messages"]}
                     for r in clean if "Level: Clean." in r["messages"][0]["content"]]
            rng = random.Random(args.seed)
            rng.shuffle(clean)
            rows += clean[:args.clean_rows]
            rng.shuffle(rows)
        (out / "mlx" / f"{part}.jsonl").write_text("".join(compact(r) + "\n" for r in rows), encoding="utf-8")
        counts[part] = len(rows)
    manifest = json.loads((source / "manifest.json").read_text(encoding="utf-8"))
    manifest["format"] = {"name": "compact-v2 Polished, one group per call", "derived_from": str(source),
                          "systemSHA256": hashlib.sha256(system.encode()).hexdigest(), "rows": counts}
    manifest["files"] = {f"mlx/{p}.jsonl": hashlib.sha256((out / "mlx" / f"{p}.jsonl").read_bytes()).hexdigest()
                         for p in ("train", "valid")}
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    (out / "export.json").write_text(json.dumps({"promptVersion": "compact-v2", "level": "polished",
                                                 "systemSHA256": manifest["format"]["systemSHA256"]}, indent=2) + "\n")
    print(json.dumps(counts))


if __name__ == "__main__":
    main()
