"""Turns per-call judgements into pair outcomes, per-arm evidence, and a short Markdown table.

A "task" is one blind call: item, arms (a, b), and `order` ("ab": a shown as Version 1; "ba": b shown
as Version 1). Its `verdict` speaks of version_1 and version_2; everything here maps those back to
arm names only after the calls are done.
"""

from collections import Counter, defaultdict

from api_judge_verdict import FAULT_KINDS, VERSIONS, normal_text

DONE = ("ok", "cached")


def arm_shown_as(task, version):
    first, second = (task["a"], task["b"]) if task["order"] == "ab" else (task["b"], task["a"])
    return first if version == "version_1" else second


def winner_arm(task):
    """The arm the verdict prefers, 'tie', or None when the call produced no verdict."""
    if task["status"] not in DONE:
        return None
    choice = task["verdict"]["more_typed"]
    return "tie" if choice == "tie" else arm_shown_as(task, choice)


def pair_outcomes(tasks):
    """One row per (item, a, b): win for an arm, tie, inconsistent (the two orders disagree), or incomplete."""
    grouped = defaultdict(dict)
    for task in tasks:
        grouped[(task["item"], task["a"], task["b"])][task["order"]] = task
    rows = []
    for (item, a, b), orders in grouped.items():
        picks = {order: winner_arm(orders[order]) for order in orders}
        row = {"item": item, "a": a, "b": b, "ab": picks.get("ab"), "ba": picks.get("ba")}
        if None in (row["ab"], row["ba"]):
            row.update(status="incomplete", winner=None)
        elif row["ab"] != row["ba"]:
            row.update(status="inconsistent", winner=None)
        elif row["ab"] == "tie":
            row.update(status="tie", winner=None)
        else:
            row.update(status="win", winner=row["ab"])
        rows.append(row)
    return rows


def pair_summary(rows):
    summary = {}
    for row in rows:
        entry = summary.setdefault(f"{row['a']} vs {row['b']}", {
            "pairs": 0, "wins": {row["a"]: 0, row["b"]: 0}, "ties": 0, "inconsistent": 0, "incomplete": 0})
        entry["pairs"] += 1
        if row["status"] == "win":
            entry["wins"][row["winner"]] += 1
        elif row["status"] == "tie":
            entry["ties"] += 1
        else:
            entry[row["status"]] += 1
    return summary


def _views(tasks):
    """{(item, arm): [(task, version side dict, version name)]} for every finished call."""
    views = defaultdict(list)
    for task in tasks:
        if task["status"] in DONE:
            for version in VERSIONS:
                views[(task["item"], arm_shown_as(task, version))].append((task, version))
    return views


def _meaning_evidence(entries):
    merged = {}
    for task, version, entry in entries:
        key = (entry["kind"], normal_text(entry["quote"]), normal_text(entry["said"]))
        row = merged.setdefault(key, {"kind": entry["kind"], "quote": entry["quote"], "said": entry["said"],
                                      "grounded": entry["grounded"], "orders": []})
        row["orders"].append(task["order"])
    return list(merged.values())


def arm_evidence(tasks):
    """Meaning changes (with quotes) and fault counts per arm, merged across the arm's views.

    An item counts as 'any' when at least one view of that arm's text flagged it, and as 'confirmed'
    when every view did (the arm is shown at least twice per item: once in each order).
    """
    arms = defaultdict(lambda: {"items": 0, "views": 0, "meaning_changes": [], "meaning_items_any": 0,
                                "meaning_items_confirmed": 0, "by_kind": Counter(),
                                "faults_any": Counter(), "faults_confirmed": Counter(),
                                "fault_entries": 0, "ungrounded_quotes": 0})
    for (item, arm), views in sorted(_views(tasks).items()):
        row = arms[arm]
        row["items"] += 1
        row["views"] += len(views)
        sides = [(task, task["verdict"][version]) for task, version in views]
        flagged = [bool(side["meaning_changes"]) for _, side in sides]
        row["meaning_items_any"] += any(flagged)
        row["meaning_items_confirmed"] += all(flagged)
        entries = [(task, version, e) for (task, version) in views
                   for e in task["verdict"][version]["meaning_changes"]]
        for evidence in _meaning_evidence(entries):
            row["meaning_changes"].append({"item": item, **evidence})
            row["by_kind"][evidence["kind"]] += 1
        for kind in FAULT_KINDS:
            present = [any(f["kind"] == kind for f in side["faults"]) for _, side in sides]
            row["faults_any"][kind] += any(present)
            row["faults_confirmed"][kind] += all(present)
        row["fault_entries"] += sum(len(side["faults"]) for _, side in sides)
        row["ungrounded_quotes"] += sum(1 for _, side in sides for e in side["meaning_changes"] + side["faults"]
                                        if not e["grounded"])
    return {arm: _finish_arm(row) for arm, row in arms.items()}


def _finish_arm(row):
    out = dict(row)
    out["fault_entries_per_view"] = round(row["fault_entries"] / row["views"], 3) if row["views"] else 0
    for key in ("by_kind", "faults_any", "faults_confirmed"):
        out[key] = dict(row[key])
    return out


def position_bias(tasks):
    counts = Counter(t["verdict"]["more_typed"] for t in tasks if t["status"] in DONE)
    total = sum(counts.values())
    return {"version_1": counts["version_1"], "version_2": counts["version_2"], "tie": counts["tie"],
            "version_1_share": round(counts["version_1"] / total, 3) if total else None}


def build_report(meta, tasks):
    rows = pair_outcomes(tasks)
    return {"meta": meta, "pair_summary": pair_summary(rows), "arms": arm_evidence(tasks),
            "position_bias": position_bias(tasks), "pairs": rows, "calls": tasks}


def _cell(value):
    return str(value).replace("|", "\\|").replace("\n", " ")


def markdown(report):
    meta = report["meta"]
    lines = ["# API judge report", "",
             f"Model `{meta['model']}`, rubric `{meta['rubric_version']}`, seed {meta['seed']}. "
             f"Calls {meta['calls']} (cached {meta['cached']}, failed {meta['failed']}, "
             f"skipped {meta['skipped']}); tokens in {meta['input_tokens']}, out {meta['output_tokens']}; "
             f"cost ${meta['dollars']:.4f}.", "",
             "## Which reads more as typed", "",
             "| Pair | Pairs | Wins | Ties | Inconsistent | Incomplete |", "|---|---|---|---|---|---|"]
    for name, row in report["pair_summary"].items():
        wins = ", ".join(f"{arm} {count}" for arm, count in row["wins"].items())
        lines.append(f"| {_cell(name)} | {row['pairs']} | {_cell(wins)} | {row['ties']} | "
                     f"{row['inconsistent']} | {row['incomplete']} |")
    lines += ["", "Inconsistent means the two orders disagreed; those pairs are not counted as wins.", "",
              "## Meaning changes and faults per arm", "",
              "| Arm | Items | Meaning-change items (any / both orders) | Fault entries per view | "
              + " | ".join(FAULT_KINDS) + " |",
              "|---|---|---|---|" + "---|" * len(FAULT_KINDS)]
    for arm, row in report["arms"].items():
        faults = " | ".join(f"{row['faults_any'].get(k, 0)}/{row['faults_confirmed'].get(k, 0)}"
                            for k in FAULT_KINDS)
        lines.append(f"| {_cell(arm)} | {row['items']} | {row['meaning_items_any']} / "
                     f"{row['meaning_items_confirmed']} | {row['fault_entries_per_view']} | {faults} |")
    lines += ["", "Fault cells read: items flagged in any order / in every order.", ""]
    for arm, row in report["arms"].items():
        if row["meaning_changes"]:
            lines += [f"### Meaning changes: {arm}", "", "| Item | Kind | Version says | Speaker said | Orders |",
                      "|---|---|---|---|---|"]
            lines += [f"| {_cell(e['item'])} | {e['kind']} | {_cell(e['quote'])} | {_cell(e['said'])} | "
                      f"{_cell('+'.join(e['orders']))}{'' if e['grounded'] else ' (quote not found)'} |"
                      for e in row["meaning_changes"]]
            lines.append("")
    bias = report["position_bias"]
    lines.append(f"Position check: Version 1 chosen {bias['version_1']}, Version 2 chosen "
                 f"{bias['version_2']}, ties {bias['tie']}.")
    return "\n".join(lines) + "\n"

