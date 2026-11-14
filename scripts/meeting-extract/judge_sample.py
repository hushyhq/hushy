"""Blind Sonnet-judge pass over meeting-extract labels: sample, pack, check, score, filter.

    PY=.build/finetune-venv/bin/python
    Add --set new before the command to judge the QMSum, NOTSOFAR and MeetingBank-sample labels (150 records,
    judge-new/) instead of the calibration and ELITR labels.
    $PY scripts/meeting-extract/judge_sample.py pack              # sample ~400 records, write judge/packs/pack-NN.md + judge/key.json
    $PY scripts/meeting-extract/judge_sample.py check judge/packs/pack-01.answer.json ...
    $PY scripts/meeting-extract/judge_sample.py score             # per-kind table with 95% Wilson intervals
    $PY scripts/meeting-extract/judge_sample.py filter            # writes labels/<stage>-v2.clean.jsonl, never touches the labels

Packs hold the record, the whole chunk and the speaker list. The meeting id, the corpus and the labeller are not shown.
The key (item -> row, record index, source, kind) lives only in judge/key.json.
"""
import argparse
import json
import math
import random
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from common import DATA_ROOT  # noqa: E402

LABELS = DATA_ROOT / "labels"
JUDGE = DATA_ROOT / "judge"
PACKS = JUDGE / "packs"
KEY = JUDGE / "key.json"
STAGE_FILES = {"cal-test": LABELS / "cal-test-v2.jsonl", "elitr": LABELS / "elitr-v2.jsonl"}
KINDS = ["decision", "action", "open_question", "change"]
QUOTA = {"change": None, "open_question": 90, "action": 120, "decision": 160}  # None = every record
NEW_STAGE_FILES = {name: LABELS / f"{name}-v2.jsonl" for name in ("qmsum", "notsofar", "meetingbank-s300")}
NEW_QUOTA = {"change": None, "open_question": 25, "action": 45, "decision": 66}
PACK_SIZE = 25
SEED = 20261107
YES_NO = {"yes", "no"}
SUPPORT = {"yes", "partial", "no"}

RUBRIC = """You judge records written by a note-taking labeller from meeting transcript chunks. Each record has a kind,
a text, an owner and due date (actions only) and a verbatim quote. Judge each record against its chunk only. Do not read
any other file. Judge every record yourself. Do not write a script that decides verdicts.

Kinds:
- decision: a choice the participants settled on, including a first-time choice or a fixed constraint.
- action: a task a person took on or was given, with or without a deadline.
- open_question: something the participants say is unresolved and needs an answer later. A rhetorical question or a
  passing remark is not one.
- change: a reversal, cancellation, reschedule or reassignment of something already settled in the chunk. A first-time
  choice is a decision, not a change.

For each record answer:
- quote_supports: "yes" if the quote on its own backs the record text, "partial" if it backs part of it or needs the
  nearby lines, "no" if it does not back it.
- kind_correct: "yes" or "no". If "no", set corrected_kind to one of decision, action, open_question, change, or
  "none" if it should not be a record at all (a suggestion, rhetorical question, chit-chat).
- owner_correct: only for kind action, else null. "yes" if the owner matches who took the task (null counts as yes when
  no speaker clearly took it and a name in the text is not a listed speaker), "no" otherwise.
- invented: "yes" if the record text states a fact (name, number, date, reason, object) that is not in the chunk, "no"
  otherwise. Paraphrase is not invention.

Answer file: one JSON object keyed by item id, each value
  {"quote_supports": "...", "kind_correct": "...", "corrected_kind": null, "owner_correct": null, "invented": "..."}
Every item id in this file must be a key. When you finish, run
  {check}
and fix the answer file until it reports no problems. Then reply with one line: the answer path, items answered.
"""


def wilson(k, n, z=1.96):
    if n == 0:
        return (float("nan"), float("nan"))
    p = k / n
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    m = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return ((c - m) / d, (c + m) / d)


def load_rows():
    rows = {}
    for stage, path in STAGE_FILES.items():
        for line in path.read_text().splitlines():
            r = json.loads(line)
            rows[r["id"]] = (stage, r)
    return rows


def sample_records(rows, rng):
    by_kind = defaultdict(list)
    for rid, (stage, r) in rows.items():
        for i, rec in enumerate(r["output"]):
            by_kind[rec["kind"]].append((rid, i))
    picked = []
    for kind in KINDS:
        pool = sorted(by_kind[kind])
        quota = QUOTA[kind]
        if quota is None or quota >= len(pool):
            picked += pool
            continue
        by_stage = defaultdict(list)
        for rid, i in pool:
            by_stage[rows[rid][0]].append((rid, i))
        for stage in by_stage:
            rng.shuffle(by_stage[stage])
        take = []
        for stage in sorted(by_stage):
            take += by_stage[stage][:round(quota * len(by_stage[stage]) / len(pool))]
        picked += take[:quota]
    return picked


def render_chunk(row):
    m = row["input"]["meeting"]
    speakers = ", ".join(m["speakers"]) if m["speakers"] else "(no speaker labels)"
    return f"Speakers: {speakers}\nTranscript:\n{row['input']['transcript']}\n"


def make_packs(rows, picked, rng):
    by_chunk = defaultdict(list)
    for rid, i in picked:
        by_chunk[rid].append(i)
    chunks = sorted(by_chunk)
    rng.shuffle(chunks)
    groups, cur, size = [], [], 0
    for rid in chunks:
        cur.append(rid)
        size += len(by_chunk[rid])
        if size >= PACK_SIZE:
            groups.append(cur)
            cur, size = [], 0
    if cur:
        if groups and size < PACK_SIZE // 2:
            groups[-1] += cur
        else:
            groups.append(cur)
    return groups, by_chunk


def cmd_pack(_args):
    rows = load_rows()
    rng = random.Random(SEED)
    picked = sample_records(rows, rng)
    groups, by_chunk = make_packs(rows, picked, rng)
    PACKS.mkdir(parents=True, exist_ok=True)
    key = {}
    for n, group in enumerate(groups, 1):
        pack_id = f"pack-{n:02d}"
        answer = PACKS / f"{pack_id}.answer.json"
        check = f"{sys.executable} {Path(__file__).resolve()} {'--set new ' if STAGE_FILES is NEW_STAGE_FILES else ''}check {answer}"
        parts = [RUBRIC.replace("{check}", check), f"Answer file: {answer}\n"]
        items = 0
        order = list(group)
        rng.shuffle(order)
        for c, rid in enumerate(order, 1):
            stage, row = rows[rid]
            parts.append(f"\n=== CHUNK {n}.{c} ===\n" + render_chunk(row))
            recs = list(by_chunk[rid])
            rng.shuffle(recs)
            for i in recs:
                items += 1
                item_id = f"{pack_id}-i{items:02d}"
                rec = row["output"][i]
                key[item_id] = {"row": rid, "index": i, "stage": stage, "source": row["source"], "kind": rec["kind"],
                                "pack": pack_id, "owner": rec.get("owner")}
                body = {k: rec.get(k) for k in ("kind", "text", "owner", "due", "quote")}
                parts.append(f"--- ITEM {item_id}\n{json.dumps(body, ensure_ascii=False)}\n")
        parts.append("\nEND OF PACK\n")
        (PACKS / f"{pack_id}.md").write_text("\n".join(parts))
    KEY.write_text(json.dumps(key, indent=1))
    kinds = Counter(v["kind"] for v in key.values())
    src = Counter(v["source"] for v in key.values())
    print(f"{len(key)} items in {len(groups)} packs; kinds {dict(kinds)}; sources {dict(src)}")
    for n, group in enumerate(groups, 1):
        print(f"pack-{n:02d}: {sum(1 for v in key.values() if v['pack'] == f'pack-{n:02d}')} items, {PACKS / f'pack-{n:02d}.md'}")


def validate_verdict(item_id, v, key):
    problems = []
    if not isinstance(v, dict):
        return [f"{item_id}: not an object"]
    if v.get("quote_supports") not in SUPPORT:
        problems.append(f"{item_id}: quote_supports must be yes, partial or no")
    if v.get("kind_correct") not in YES_NO:
        problems.append(f"{item_id}: kind_correct must be yes or no")
    if v.get("kind_correct") == "no" and v.get("corrected_kind") not in KINDS + ["none"]:
        problems.append(f"{item_id}: corrected_kind needed when kind_correct is no")
    if v.get("invented") not in YES_NO:
        problems.append(f"{item_id}: invented must be yes or no")
    is_action = key.get(item_id, {}).get("kind") == "action"
    if is_action and v.get("owner_correct") not in YES_NO:
        problems.append(f"{item_id}: owner_correct must be yes or no for an action")
    return problems


def cmd_check(args):
    key = json.loads(KEY.read_text())
    bad = 0
    for path in args.answers:
        pack = Path(path).name.split(".")[0]
        want = [k for k, v in key.items() if v["pack"] == pack]
        try:
            ans = json.loads(Path(path).read_text())
        except (OSError, ValueError) as e:
            print(f"{path}: unreadable ({e})")
            bad += 1
            continue
        missing = [k for k in want if k not in ans]
        extra = [k for k in ans if k not in key]
        problems = [p for k in want if k in ans for p in validate_verdict(k, ans[k], key)]
        print(f"{path}: {len(want) - len(missing)} of {len(want)} items answered, {len(problems)} problems")
        for line in [f"missing {k}" for k in missing] + [f"unknown {k}" for k in extra] + problems:
            print("  " + line)
        bad += bool(missing or extra or problems)
    sys.exit(1 if bad else 0)


def load_verdicts():
    key = json.loads(KEY.read_text())
    out = {}
    for path in sorted(PACKS.glob("pack-*.answer.json")):
        for item_id, v in json.loads(path.read_text()).items():
            if item_id in key and not validate_verdict(item_id, v, key):
                out[item_id] = {**key[item_id], **v}
    return out


def rate(items, pred):
    k = sum(1 for x in items if pred(x))
    lo, hi = wilson(k, len(items))
    return f"{100 * k / len(items):5.1f}% [{100 * lo:4.1f},{100 * hi:4.1f}] n={len(items)}" if items else "n/a"


def cmd_score(_args):
    verdicts = load_verdicts()
    by_kind = defaultdict(list)
    for v in verdicts.values():
        by_kind[v["kind"]].append(v)
    print(f"{len(verdicts)} judged items")
    print("kind           support(yes)                 support(yes+partial)         kind-correct                 invented                     owner-correct")
    for kind in KINDS + ["ALL"]:
        items = verdicts.values() if kind == "ALL" else by_kind[kind]
        items = list(items)
        if not items:
            continue
        actions = [x for x in items if x["kind"] == "action"]
        cols = [rate(items, lambda x: x["quote_supports"] == "yes"),
                rate(items, lambda x: x["quote_supports"] in ("yes", "partial")),
                rate(items, lambda x: x["kind_correct"] == "yes"),
                rate(items, lambda x: x["invented"] == "yes"),
                rate(actions, lambda x: x["owner_correct"] == "yes")]
        print(f"{kind:14s} " + "  ".join(f"{c:28s}" for c in cols))
    print("\ncorrected kinds (judged kind -> judge kind):")
    moves = Counter((v["kind"], v["corrected_kind"]) for v in verdicts.values() if v["kind_correct"] == "no")
    for (a, b), n in sorted(moves.items(), key=lambda t: -t[1]):
        print(f"  {a} -> {b}: {n}")
    print("\nby source:")
    by_source = defaultdict(list)
    for v in verdicts.values():
        by_source[v["source"]].append(v)
    for s, items in sorted(by_source.items()):
        print(f"  {s:8s} n={len(items):3d} support {rate(items, lambda x: x['quote_supports'] == 'yes')} invented {rate(items, lambda x: x['invented'] == 'yes')}")


def keep(v):
    return v["quote_supports"] != "no" and v["invented"] != "yes" and v["corrected_kind"] != "none"


def cmd_filter(_args):
    verdicts = load_verdicts()
    rows = load_rows()
    by_row = defaultdict(dict)
    for v in verdicts.values():
        by_row[v["row"]][v["index"]] = v
    survivors = Counter()
    judged = Counter()
    total = Counter()
    for stage, path in STAGE_FILES.items():
        out_path = path.with_name(path.name.replace("-v2.jsonl", "-v2.clean.jsonl"))
        with out_path.open("w") as fh:
            for line in path.read_text().splitlines():
                row = json.loads(line)
                new = []
                for i, rec in enumerate(row["output"]):
                    total[rec["kind"]] += 1
                    v = by_row.get(row["id"], {}).get(i)
                    if v is None:
                        new.append(rec)
                        survivors[rec["kind"]] += 1
                        continue
                    judged[rec["kind"]] += 1
                    if not keep(v):
                        continue
                    if v["kind_correct"] == "no":
                        rec = {**rec, "kind": v["corrected_kind"]}
                        if rec["kind"] != "action":
                            rec = {**rec, "owner": None, "due": None}
                    new.append(rec)
                    survivors[rec["kind"]] += 1
                notes = {**row.get("notes", {}), "clean_filter": "judge pass: drop unsupported, invented or none; relabel kind"}
                fh.write(json.dumps({**row, "output": new, "notes": notes}, ensure_ascii=False) + "\n")
        print(f"wrote {out_path}")
    print("kind           labelled  judged  survivors(after filter, by final kind)")
    for k in KINDS:
        print(f"{k:14s} {total[k]:8d} {judged[k]:7d} {survivors[k]:8d}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--set", choices=["first", "new"], default="first")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("pack").set_defaults(fn=cmd_pack)
    c = sub.add_parser("check")
    c.add_argument("answers", nargs="+")
    c.set_defaults(fn=cmd_check)
    sub.add_parser("score").set_defaults(fn=cmd_score)
    sub.add_parser("filter").set_defaults(fn=cmd_filter)
    args = ap.parse_args()
    if args.set == "new":
        global STAGE_FILES, QUOTA, JUDGE, PACKS, KEY
        STAGE_FILES, QUOTA = NEW_STAGE_FILES, NEW_QUOTA
        JUDGE = DATA_ROOT / "judge-new"
        PACKS, KEY = JUDGE / "packs", JUDGE / "key.json"
    args.fn(args)


if __name__ == "__main__":
    main()
