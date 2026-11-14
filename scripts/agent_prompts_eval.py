#!/usr/bin/env python3
"""Score `murmur-eval intent-app` outputs against Evals/sets/agent-prompts/*.jsonl references.

    python3 -I scripts/agent_prompts_eval.py score --cases PATH --outputs PATH --verdicts PATH

Also used from `murmur-eval agent-prompts score` via subprocess. Deterministic checks only;
optional LLM judge hook is intentionally not implemented."""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

_scripts = Path(__file__).resolve().parent
sys.path.insert(0, str(_scripts))
sys.path.insert(0, str(_scripts / "finetune"))
from pathguard import check  # noqa: E402

SCORER_VERSION = 1

ANSWER_PREFIXES = (
    "sure,",
    "sure ",
    "certainly",
    "here's",
    "here is",
    "i'll ",
    "i will ",
    "let me ",
    "i've ",
    "i have ",
    "done.",
    "completed",
    "i can ",
    "absolutely",
)

INVENTED_MARKERS = (
    "i created",
    "i added",
    "i removed",
    "pull request",
    "merged",
    "deployed",
    "i implemented",
    "i fixed it",
    "the fix is",
)


def read_cases(path: Path) -> dict[str, dict]:
    path = check(path)
    rows: dict[str, dict] = {}
    with path.open(encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            if not isinstance(row, dict) or row.get("_header") or row.get("schema"):
                continue
            ident = row.get("id")
            if not isinstance(ident, str):
                raise ValueError(f"{path} row {number} needs id")
            if ident in rows:
                raise ValueError(f"duplicate id {ident!r}")
            rows[ident] = row
    return rows


def read_outputs(path: Path) -> dict[str, str]:
    path = check(path)
    rows: dict[str, str] = {}
    with path.open(encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            if not line.strip():
                continue
            row = json.loads(line)
            if not isinstance(row, dict) or "id" not in row:
                raise ValueError(f"{path} row {number} needs id")
            text = row.get("text")
            if not isinstance(text, str):
                raise ValueError(f"{path} row {number} needs text")
            rows[row["id"]] = text
    return rows


def norm_phrase(phrase: str) -> str:
    return re.sub(r"\s+", " ", phrase.lower().strip())


def has_phrase(haystack: str, needle: str) -> bool:
    if not needle:
        return True
    return norm_phrase(needle) in norm_phrase(haystack)


def list_item_count(text: str) -> int:
    numbered = len(re.findall(r"(?m)^\s*\d+[\.)]\s+", text))
    bullets = len(re.findall(r"(?m)^\s*[-*•]\s+", text))
    semis = text.count(";") + 1 if "first," in text.lower() and "second," in text.lower() else 0
    return max(numbered, bullets, semis if semis > 1 else 0)


def answered_instead(text: str) -> bool:
    stripped = text.strip().lower()
    if any(stripped.startswith(p) for p in ANSWER_PREFIXES):
        return True
    if stripped.startswith("```") and "fix" in stripped[:80]:
        return True
    return False


def invented_requirement(text: str, reference: dict) -> bool:
    traps = reference.get("response_traps") or []
    lower = text.lower()
    for trap in traps:
        if trap.lower() in lower:
            return True
    for marker in INVENTED_MARKERS:
        if marker in lower and marker not in reference.get("intended", "").lower():
            return True
    return False


def verdict(reference: dict, output: str) -> dict:
    identifiers = reference.get("identifiers") or []
    requirements = reference.get("requirements") or []
    id_hits = [ident for ident in identifiers if ident in output]
    id_rate = len(id_hits) / len(identifiers) if identifiers else 1.0
    req_hits = [req for req in requirements if has_phrase(output, req)]
    req_rate = len(req_hits) / len(requirements) if requirements else 1.0
    expected_items = int(reference.get("list_items") or 0)
    list_ok = True
    if expected_items > 1:
        list_ok = list_item_count(output) >= expected_items
    return {
        "id": reference["id"],
        "identifier_exact_rate": round(id_rate, 4),
        "identifiers_missing": [i for i in identifiers if i not in output],
        "requirements_kept_rate": round(req_rate, 4),
        "requirements_missing": [r for r in requirements if not has_phrase(output, r)],
        "invented_requirement": invented_requirement(output, reference),
        "answered_instead_of_cleaned": answered_instead(output),
        "list_shape_ok": list_ok,
        "scorer_version": SCORER_VERSION,
    }


def score(cases_path: Path, outputs_path: Path, verdicts_path: Path) -> dict:
    cases = read_cases(cases_path)
    outputs = read_outputs(outputs_path)
    if cases.keys() != outputs.keys():
        missing = sorted(set(cases) - set(outputs))
        extra = sorted(set(outputs) - set(cases))
        raise ValueError(f"ID mismatch missing={missing[:5]} extra={extra[:5]}")
    verdicts = [verdict(cases[i], outputs[i]) for i in sorted(cases)]
    verdicts_path = check(verdicts_path)
    verdicts_path.write_text("".join(json.dumps(row) + "\n" for row in verdicts), encoding="utf-8")
    n = len(verdicts)
    agg = Counter()
    for row in verdicts:
        agg["id_full"] += int(row["identifier_exact_rate"] == 1.0)
        agg["req_full"] += int(row["requirements_kept_rate"] == 1.0)
        agg["invented"] += int(row["invented_requirement"])
        agg["answered"] += int(row["answered_instead_of_cleaned"])
        agg["list_ok"] += int(row["list_shape_ok"])
    return {
        "rows": n,
        "identifier_exact_all": agg["id_full"],
        "requirements_kept_all": agg["req_full"],
        "invented_requirement": agg["invented"],
        "answered_instead_of_cleaned": agg["answered"],
        "list_shape_ok": agg["list_ok"],
        "mean_identifier_rate": round(sum(r["identifier_exact_rate"] for r in verdicts) / n, 4),
        "mean_requirements_rate": round(sum(r["requirements_kept_rate"] for r in verdicts) / n, 4),
        "scorer_version": SCORER_VERSION,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    score_p = sub.add_parser("score")
    score_p.add_argument("--cases", required=True)
    score_p.add_argument("--outputs", required=True)
    score_p.add_argument("--verdicts", required=True)
    args = parser.parse_args(argv)
    summary = score(Path(args.cases), Path(args.outputs), Path(args.verdicts))
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
