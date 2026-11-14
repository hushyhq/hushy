"""Calibrate the Codex labeller against the AMI and ICSI annotator records.

    calibrate.py split                       # writes dev.ids and test.ids (split by team, never by chunk)
    calibrate.py score labels/cal-test.jsonl # recall, precision bounds, extras

Gold is the human-linked tier (gold-human.jsonl plus the AMI and ICSI rows of held-r10d-overlap.jsonl). Gold
is incomplete: annotators wrote 3 to 8 decisions per meeting. So recall is a fair number but precision is only
a lower bound; `extras` lists the Codex records with no annotator match for hand reading.
"""
import json
import random
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from common import DATA_ROOT, content_words, stable_hash  # noqa: E402
from label_codex import labeller_stats, turn_texts  # noqa: E402

FINAL = DATA_ROOT / "final"
DEV_SHARE = 4  # about a quarter of each source goes to dev
STRICT_WINDOW, LOOSE_WINDOW = 3, 8


def gold_rows() -> dict:
    rows = {}
    for name in ("gold-human.jsonl", "held-r10d-overlap.jsonl"):
        for line in open(FINAL / name, encoding="utf-8"):
            row = json.loads(line)
            if row["gold"] == "human-linked":
                rows[row["id"]] = row
    return rows


def dev_series(rows: dict) -> set:
    """Whole teams go to dev, taken in hash order per source until a quarter of that source's chunks are in."""
    dev = set()
    for source in sorted({r["source"] for r in rows.values()}):
        by_series = defaultdict(int)
        for r in rows.values():
            if r["source"] == source:
                by_series[r["series"]] += 1
        total, taken = sum(by_series.values()), 0
        for series in sorted(by_series, key=lambda s: stable_hash("cal:" + s)):
            if taken >= total / DEV_SHARE:
                break
            dev.add(series)
            taken += by_series[series]
    return dev


def split() -> None:
    rows = gold_rows()
    series = dev_series(rows)
    dev = sorted(i for i, r in rows.items() if r["series"] in series)
    test = sorted(i for i in rows if i not in set(dev))
    for name, ids in (("dev", dev), ("test", test)):
        (DATA_ROOT / "labels").mkdir(exist_ok=True)
        (DATA_ROOT / "labels" / f"cal-{name}.ids").write_text("\n".join(ids) + "\n")
        by = Counter(rows[i]["source"] for i in ids)
        gold = Counter(rows[i]["source"] for i in ids if rows[i]["output"])
        print(name, len(ids), dict(by), "with gold:", dict(gold))


def quote_turn(turns: list, quote: str) -> int | None:
    for i, t in enumerate(turns):
        if quote in t:
            return i
    return None


def evidence_turns(gold: dict, i: int) -> set:
    align = gold["notes"]["alignments"][i]
    return {align["turn"]} | {alt["turn"] for alt in align["alt_quotes"]}


def hash_seed(chunk_id: str, j: int) -> int:
    return stable_hash(f"{chunk_id}:{j}") % 2**32


def shares(a: str, b: str) -> tuple:
    wa, wb = content_words(a), content_words(b)
    return len(wa & wb), len(wa & wb) / max(1, min(len(wa), len(wb)))


def near(turn: int, evidence: set, window: int) -> bool:
    return any(abs(turn - e) <= window for e in evidence)


def match_level(g_rec: dict, ev: set, c_rec: dict, c_turn: int) -> str | None:
    n, frac = shares(g_rec["text"], c_rec["text"])
    if c_rec["kind"] == g_rec["kind"] and near(c_turn, ev, STRICT_WINDOW) and (n >= 2 or frac >= 0.5):
        return "strict"
    if near(c_turn, ev, LOOSE_WINDOW):
        return "loose"
    return None


def score(path: Path, sample_extras: int, seed: int) -> None:
    gold = gold_rows()
    labelled = [json.loads(line) for line in open(path, encoding="utf-8")]
    recall, kind_counts, owner_ok, extras, per_codex = Counter(), Counter(), Counter(), [], Counter()
    new_in_gold_empty = Counter()
    for row in labelled:
        g = gold[row["id"]]
        turns = turn_texts(row)
        codex = [(c, quote_turn(turns, c["quote"])) for c in row["output"]]
        used = set()
        shuffled = [random.Random(hash_seed(row["id"], j)).randrange(len(turns)) for j in range(len(codex))]
        for i, g_rec in enumerate(g["output"] or []):
            ev = evidence_turns(g, i)
            best, best_idx = None, None
            for j, (c, t) in enumerate(codex):
                level = match_level(g_rec, ev, c, t)
                if level and (best is None or (level == "strict" and best == "loose")):
                    best, best_idx = level, j
            key = (row["source"], g_rec["kind"])
            kind_counts[key] += 1
            if any(near(t, ev, LOOSE_WINDOW) for t in shuffled):
                recall[key, "chance"] += 1
            if best:
                recall[key, best] += 1
                used.add(best_idx)
                if best == "strict":
                    recall[key, "loose"] += 1
                    if g_rec["kind"] == "action":
                        owner_ok[row["source"], g_rec["owner"] == codex[best_idx][0]["owner"]] += 1
        for j, (c, t) in enumerate(codex):
            per_codex[row["source"], c["kind"], "matched" if j in used else "extra"] += 1
            if j not in used:
                extras.append({"id": row["id"], "kind": c["kind"], "text": c["text"], "owner": c["owner"],
                               "due": c["due"], "quote": c["quote"], "gold_chunk": bool(g["output"])})
            if not g["output"]:
                new_in_gold_empty[row["source"]] += 1
    raw = sum(labeller_stats(r)["raw_records"] for r in labelled)
    drops = Counter()
    for r in labelled:
        drops.update(labeller_stats(r)["dropped"])
    print(f"chunks {len(labelled)}  records kept {sum(len(r['output']) for r in labelled)} of {raw} raw; drops {dict(drops)}")
    print("\nRecall against annotator records (strict = same kind, evidence within "
          f"{STRICT_WINDOW} lines, text overlap; loose = any codex record within {LOOSE_WINDOW} lines of the evidence; chance = the same with each codex record moved to a random line)")
    for key in sorted(kind_counts):
        n = kind_counts[key]
        print(f"  {key[0]:5} {key[1]:9} n={n:3}  strict {recall[key, 'strict'] / n:5.1%}  loose {recall[key, 'loose'] / n:5.1%}  chance {recall[key, 'chance'] / n:5.1%}")
    tot = sum(kind_counts.values())
    print(f"  all n={tot}  strict {sum(v for k, v in recall.items() if k[1] == 'strict') / tot:.1%}"
          f"  loose {sum(v for k, v in recall.items() if k[1] == 'loose') / tot:.1%}"
          f"  chance {sum(v for k, v in recall.items() if k[1] == 'chance') / tot:.1%}")
    print("  AMI action owner agreement on strict matches:", dict(owner_ok))
    print("\nCodex records by source, kind and match (matched = used by a strict or loose gold match)")
    for key in sorted(per_codex):
        print(f"  {key[0]:5} {key[1]:13} {key[2]:8} {per_codex[key]}")
    print(f"codex records in chunks where the annotators wrote nothing: {dict(new_in_gold_empty)}")
    random.Random(seed).shuffle(extras)
    out = path.with_suffix(".extras-sample.json")
    out.write_text(json.dumps(extras[:sample_extras], indent=1, ensure_ascii=False))
    print(f"\n{len(extras)} extras; {min(sample_extras, len(extras))} sampled to {out}")


if __name__ == "__main__":
    if sys.argv[1] == "split":
        split()
    else:
        score(Path(sys.argv[2]), int(sys.argv[3]) if len(sys.argv) > 3 else 20, 20261106)
