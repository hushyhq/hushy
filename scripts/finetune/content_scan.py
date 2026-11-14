#!/usr/bin/env python3
"""Content-loss scans over dev-eval reports — the check the v5.2 2B needed (FINETUNE.md §3.27).

    python3 scripts/finetune/content_scan.py --runs v5.3-2b=<dir> apple=<dir> --out <dir> --max-calls 300
        [--ledger <file>] [--no-jev]

Two scans per run, over every set in the run's directory:
1. `lost_span_before_hedge` (the data builder's check): outputs missing a 3+ word run that the
   speaker said before "I think" / "I feel" / … — free, deterministic.
2. Jev pointwise on every output that differs from both its reference and its spoken input
   (an output equal to either can't have dropped content relative to the correct answer); hits are
   outputs with the `dropped_content` fault ≥ 0.6. Identical (level, spoken, output, reference)
   rows are judged once and the Jev cache makes reruns free.

Writes content-scan.md (hits by case id) and the judged rows. Dev sets only: the path guard
refuses held-out paths.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_data import lost_span_before_hedge  # noqa: E402
from jev_ab import LEVEL, NO_REFERENCE, ROOT, load_cases  # noqa: E402
from pathguard import Manifest, check  # noqa: E402

DROPPED_CONTENT_HIT = 0.6
# v5.4: a garbled correction ("Assign Jordan to Mia, no, Jordan.") keeps every word but changes
# the fact; report those too.
MEANING_FAULTS = ("changed_fact", "meaning_broken")
MEANING_HIT = 0.5


def collect(runs: dict[str, str], manifest: Manifest) -> list[dict[str, Any]]:
    rows = []
    for label, directory in runs.items():
        for path in sorted(Path(check(Path(directory).resolve())).glob("*.json")):
            name = path.stem
            if name not in LEVEL:
                continue
            for case_id, case in load_cases(path, manifest).items():
                reference = "" if name in NO_REFERENCE else case["reference"]
                rows.append({"id": f"{name}/{case_id}/{label}", "run": label, "set": name, "case": case_id,
                             "level": LEVEL[name], "spoken": case["spoken"], "output": case["output"], "reference": reference})
    return rows


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", nargs="+", required=True, help="label=dir")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--max-calls", type=int, default=300)
    parser.add_argument("--ledger", type=Path)
    parser.add_argument("--no-jev", action="store_true")
    parser.add_argument("--eval-bin", type=Path, default=ROOT / ".build/release/murmur-eval")
    args = parser.parse_args()
    out = check(args.out.resolve())
    out.mkdir(parents=True, exist_ok=True)
    manifest = Manifest(ROOT)
    runs = dict(item.split("=", 1) for item in args.runs)
    rows = collect(runs, manifest)

    lines = ["# Content-loss scans", "", "## Lost span before a hedge (builder check on outputs)", ""]
    span_hits = [(r, lost_span_before_hedge(r["spoken"], r["output"])) for r in rows]
    span_hits = [(r, hit) for r, hit in span_hits if hit]
    for label in runs:
        mine = [(r, hit) for r, hit in span_hits if r["run"] == label]
        lines.append(f"- **{label}**: {len(mine)}" + ("" if not mine else " — " + "; ".join(
            f"`{r['set']}/{r['case']}` (lost \"{hit}\")" for r, hit in mine)))

    if not args.no_jev:
        judge, seen = [], set()
        for r in rows:
            signature = (r["level"], r["spoken"], r["output"], r["reference"])
            if r["output"] in (r["reference"], r["spoken"]) or signature in seen:
                continue
            seen.add(signature)
            judge.append(r)
        manifest.write_jsonl(out / "scan-rows.jsonl", judge)
        command = [str(args.eval_bin), "finetune", "jev", "--in", str(out / "scan-rows.jsonl"), "--out", str(out / "scan-judged.jsonl"),
                   "--max-calls", str(args.max_calls), "--spoken-key", "spoken", "--output-key", "output",
                   "--reference-key", "reference", "--label", f"content-scan:{','.join(runs)}"]
        if args.ledger:
            command += ["--ledger", str(check(args.ledger))]
        subprocess.run(command, cwd=ROOT, check=True)
        judged = {(r["level"], r["spoken"], r["output"], r["reference"]): r for r in manifest.read_jsonl(out / "scan-judged.jsonl")}
        lines += ["", f"## Jev dropped_content ≥ {DROPPED_CONTENT_HIT} ({len(judge)} distinct outputs judged: every output that "
                  "differs from its reference and its input)", ""]
        meaning_lines: list[str] = []
        for label in runs:
            hits, meaning, unjudged = [], [], 0
            for r in rows:
                if r["run"] != label or r["output"] in (r["reference"], r["spoken"]):
                    continue
                verdict = judged.get((r["level"], r["spoken"], r["output"], r["reference"]))
                if not verdict or verdict.get("pBad") is None:
                    unjudged += 1
                    continue
                faults = verdict.get("jevFaults") or {}
                score = faults.get("dropped_content", 0)
                if score >= DROPPED_CONTENT_HIT:
                    hits.append(f"`{r['set']}/{r['case']}` ({score:.2f})")
                worst = max((faults.get(f, 0), f) for f in MEANING_FAULTS)
                if worst[0] >= MEANING_HIT:
                    meaning.append(f"`{r['set']}/{r['case']}` ({worst[1]} {worst[0]:.2f})")
            lines.append(f"- **{label}**: {len(hits)}" + (f" — {'; '.join(hits)}" if hits else "")
                         + (f" ({unjudged} over the call budget, not judged)" if unjudged else ""))
            meaning_lines.append(f"- **{label}**: {len(meaning)}" + (f" — {'; '.join(meaning)}" if meaning else ""))
        lines += ["", f"## Jev changed_fact / meaning_broken ≥ {MEANING_HIT} (same outputs)", ""] + meaning_lines
    report = "\n".join(lines) + "\n"
    (out / "content-scan.md").write_text(report)
    manifest.record_write(out / "content-scan.md")
    manifest.sections["runs"] = runs
    manifest.save(out / "content-scan-manifest.json")
    print(report)


if __name__ == "__main__":
    main()
