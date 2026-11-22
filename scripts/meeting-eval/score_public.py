#!/usr/bin/env python3
"""Scores `murmur-eval meeting --out` digests against a public gold set (build_public_ami.py).

Deterministic and model-free, so any run can be rescored and two runs compared exactly. Matching
is lexical (stemmed content words), so read the numbers as comparisons between systems on the
same set, not as absolute quality.

Headline (lower is better): invented owners, unsupported items, wrong-owner rate.
  - invented owner: an action item's owner who is not a speaker label, "You", a group word,
    or a name said in the transcript.
  - unsupported item: an action item or decision whose content words are mostly absent from
    every 80-word stretch of the transcript (support < SUPPORT_MIN). Words are compared as said:
    digits read as number words ("12.50" as "twelve fifty", as AMI writes it) and an acronym AMI
    spells letter by letter ("L_C_D_") as one word ("lcd").
  - wrong owner: a gold action matched by task whose owner is not the gold owner.
Also: decision and action recall against the human gold, gold precision, invented numbers and
dates (in the output, not in the transcript), key-point support, latency, calls, failures.

    scripts/meeting-eval/score_public.py --gold ami-dev.json --run 4b=out-4b.json --run apple=out-apple.json
        [--control]   (also scores each run against the wrong meeting's gold: the floor)
        [--self]      (scores the gold as if it were a run: the ceiling)
        [--json results.json]
"""
import argparse
import json
import re
import statistics

STOP = set("""a an the and or but of to in on at for with by from as is are was were be been being it its this that these
those there their they them we our us you your i me my he she his her him not no do does did done will would shall should
can could may might must have has had also so such than then very just about into over up out off more most some any each
all both other only own same too which who whom what when where why how decided decide decision agreed agree group team
meeting going go get got make made use used need needs one remote control product thing things""".split())
GROUP = {"group", "team", "everyone", "all", "everybody", "we", "us", "the group", "the team", "all participants"}
ROLE_ALIASES = {
    "Project Manager": r"project manager|\bpm\b",
    "Marketing Expert": r"marketing",
    "User Interface Designer": r"user interface|\bui\b|interface designer",
    "Industrial Designer": r"industrial designer|\bid\b",
}
NUMBER_WORDS = {w: i for i, w in enumerate(
    "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen "
    "eighteen nineteen".split())}
NUMBER_WORDS.update({"twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80,
                     "ninety": 90, "hundred": 100, "thousand": 1000, "half": 0.5})
CALENDAR = set("monday tuesday wednesday thursday friday saturday sunday january february march april may june july "
               "august september october november december tomorrow tonight weekend".split())
WINDOW, STRIDE, SUPPORT_MIN, MATCH_MIN, COVERAGE_WEIGHT = 80, 40, 0.4, 0.34, 0.75


def stem(word: str) -> str:
    for suffix in ("ing", "ed", "es", "s", "ly"):
        if word.endswith(suffix) and len(word) - len(suffix) >= 4:
            return word[: -len(suffix)]
    return word


SPELLED = re.compile(r"\b(?:[a-z]_){2,}")


UNITS = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen \
eighteen nineteen".split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()


def said(number: int) -> str:
    """0 to 999 in words, as a speaker says it ("one hundred twenty five"); larger numbers stay digits."""
    if number >= 1000:
        return str(number)
    hundreds, rest = divmod(number, 100)
    words = [UNITS[hundreds], "hundred"] if hundreds else []
    if rest or not words:
        words += [UNITS[rest]] if rest < 20 else [TENS[rest // 10]] + ([UNITS[rest % 10]] if rest % 10 else [])
    return " ".join(words)


def tokens(text: str) -> list:
    low = SPELLED.sub(lambda m: m.group(0).replace("_", ""), text.lower())
    low = re.sub(r"\d+(?:,\d{3})*", lambda m: f" {said(int(m.group(0).replace(',', '')))} ", low)
    return re.findall(r"[a-z0-9]+", low)


def content(text: str) -> set:
    return {stem(w) for w in tokens(text) if w not in STOP and len(w) > 1}


def similarity(gold: str, pred: str) -> float:
    """Dice overlap, or most of the gold's words inside a longer written line, whichever is higher."""
    g, p = content(gold), content(pred)
    if not g or not p:
        return 0.0
    shared = len(g & p)
    return max(2 * shared / (len(g) + len(p)), COVERAGE_WEIGHT * shared / len(g))


def windows(transcript: str) -> list:
    words = tokens(transcript)
    return [{stem(w) for w in words[i:i + WINDOW]} for i in range(0, max(1, len(words) - STRIDE), STRIDE)]


def support(text: str, spans: list) -> float:
    words = content(text)
    return max((len(words & span) / len(words) for span in spans), default=0.0) if words else 1.0


def numbers(text: str, spoken: bool = False) -> set:
    """Numbers in `text`. `spoken` (the transcript side) also reads "twelve and a half", "twelve
    point five" and "twelve fifty" (12.5), so a written-out spoken number is not called invented."""
    found = {float(n.replace(",", "")) for n in re.findall(r"\d[\d,]*\.?\d*", text) if n.replace(",", "").replace(".", "")}
    tokens = re.findall(r"[a-z]+", text.lower())
    values = []
    i = 0
    while i < len(tokens):
        if tokens[i] in NUMBER_WORDS:
            value = NUMBER_WORDS[tokens[i]]
            if i + 1 < len(tokens) and tokens[i + 1] in NUMBER_WORDS and 0 < NUMBER_WORDS[tokens[i + 1]] < 10 <= value:
                value += NUMBER_WORDS[tokens[i + 1]]
                i += 1
            values.append((i, value))
            found.add(float(value))
        i += 1
    if spoken:
        for (i, a), (j, b) in zip(values, values[1:]):
            if j - i <= 2:
                found.update({a + b / 100, a + b / 10, a * b})
        for k, (i, a) in enumerate(values):
            if tokens[i + 1:i + 4] == ["and", "a", "half"]:
                found.add(a + 0.5)
            found.update({a * 1000, a * 1_000_000})
    return found


def calendar(text: str) -> set:
    return {w for w in re.findall(r"[a-z]+", text.lower()) if w in CALENDAR}


def role_of(owner: str) -> str:
    low = owner.lower().strip()
    if low in GROUP or re.fullmatch(r"(the )?(whole )?(group|team)", low):
        return "group"
    for role, pattern in ROLE_ALIASES.items():
        if re.search(pattern, low):
            return role
    return low


def gold_owners(action: dict) -> set:
    """Every role the gold sentence names before "will" ("The ID and the UI will build..."), or its owner."""
    head = action["task"].lower().split(" will ")[0][:80]
    owners = {role for role, pattern in ROLE_ALIASES.items() if re.search(pattern, head)}
    if re.search(r"\b(group|team|everyone|all)\b", head):
        owners.add("group")
    return owners or ({action["owner"]} if action.get("owner") else set())


def parse_item(line: str, detail: dict | None) -> dict:
    if detail:
        return {"owner": detail.get("owner", ""), "task": detail.get("task", ""), "due": detail.get("due", "")}
    owner, task, due = "", line, ""
    head, sep, rest = line.partition(": ")
    if sep and len(head) <= 30:
        owner, task = head, rest
    task, _, due = task.partition(" — ")
    return {"owner": owner, "task": task, "due": due}


def digest(row: dict) -> dict:
    lines = [l[2:].strip() for l in row.get("summary", "").split("\n") if l.startswith("- ")]
    decisions = [l[len("Decided: "):] for l in lines if l.startswith("Decided: ")]
    points = [l for l in lines if not l.startswith("Decided: ")]
    details = row.get("actionDetails") or [None] * len(row.get("actionItems", []))
    items = [parse_item(line, d) for line, d in zip(row.get("actionItems", []), details)]
    return {"decisions": decisions, "points": points, "items": items}


def assign(gold: list, pred: list) -> list:
    pairs = sorted(((similarity(g, p), gi, pi) for gi, g in enumerate(gold) for pi, p in enumerate(pred)), reverse=True)
    used_g, used_p, matches = set(), set(), []
    for score, gi, pi in pairs:
        if score < MATCH_MIN:
            break
        if gi in used_g or pi in used_p:
            continue
        used_g.add(gi), used_p.add(pi)
        matches.append((gi, pi, score))
    return matches


def score_meeting(meeting: dict, row: dict) -> dict:
    d = digest(row)
    transcript = meeting["transcript"]
    spans = windows(transcript)
    labels = {p["label"].lower() for p in meeting["people"]} | {p["name"].lower() for p in meeting["people"]}
    transcript_low = transcript.lower()
    transcript_numbers, transcript_calendar = numbers(transcript, spoken=True), calendar(transcript)

    gold_decisions = [g["text"] for g in meeting["decisions"]]
    gold_actions = meeting["actionItems"]
    tasks = [i["task"] for i in d["items"]]
    decision_matches = assign(gold_decisions, d["decisions"] + tasks)
    action_matches = assign([g["task"] for g in gold_actions], tasks + d["decisions"])

    owner_checked = owner_wrong = 0
    for gi, pi, _ in action_matches:
        owners = gold_owners(gold_actions[gi])
        if not owners or pi >= len(tasks):
            continue
        owner_checked += 1
        owner_wrong += role_of(d["items"][pi]["owner"]) not in owners

    invented_owners = []
    for item in d["items"]:
        owner = item["owner"].strip()
        low = owner.lower()
        if not owner or low in labels or low == "you" or role_of(owner) in ROLE_ALIASES or role_of(owner) == "group":
            continue
        if all(part in transcript_low for part in re.findall(r"[a-z]+", low)):
            continue
        invented_owners.append(owner)

    produced = d["decisions"] + [f'{i["task"]} {i["due"]}' for i in d["items"]]
    unsupported = [t for t in produced if support(t, spans) < SUPPORT_MIN]
    out_text = " ".join(produced + d["points"])
    invented_numbers = sorted(n for n in numbers(out_text) if n not in transcript_numbers)
    invented_dates = sorted(calendar(out_text) - transcript_calendar)
    point_support = [support(p, spans) for p in d["points"]]
    return {
        "id": meeting["id"], "minutes": meeting["minutes"], "words": meeting["words"],
        "gold_decisions": len(gold_decisions), "gold_actions": len(gold_actions),
        "decisions_found": len(decision_matches), "actions_found": len(action_matches),
        "pred_decisions": len(d["decisions"]), "pred_items": len(d["items"]),
        "owner_checked": owner_checked, "owner_wrong": owner_wrong,
        "unassigned_items": sum(1 for i in d["items"] if not i["owner"].strip()),
        "invented_owners": invented_owners, "unsupported": unsupported,
        "produced": len(produced), "invented_numbers": invented_numbers, "invented_dates": invented_dates,
        "points": len(point_support), "points_supported": sum(1 for s in point_support if s >= SUPPORT_MIN),
        "ms": row.get("milliseconds", 0), "calls": row.get("calls", 0), "note": row.get("note", ""),
    }


def pct(a, b):
    return f"{100 * a / b:.0f}%" if b else "n/a"


def aggregate(rows: list) -> dict:
    s = lambda k: sum(r[k] for r in rows)
    ms = [r["ms"] for r in rows]
    degraded = sum(1 for r in rows if re.search(r"extractive|deterministic|failed|fell back", r["note"]))
    return {
        "meetings": len(rows),
        "invented owners": s_len(rows, "invented_owners"),
        "unsupported items": f'{s_len(rows, "unsupported")}/{s("produced")} ({pct(s_len(rows, "unsupported"), s("produced"))})',
        "wrong-owner rate": f'{pct(s("owner_wrong"), s("owner_checked"))} ({s("owner_wrong")}/{s("owner_checked")})',
        "decision recall": f'{pct(s("decisions_found"), s("gold_decisions"))} ({s("decisions_found")}/{s("gold_decisions")})',
        "action recall": f'{pct(s("actions_found"), s("gold_actions"))} ({s("actions_found")}/{s("gold_actions")})',
        "gold precision (items+decisions hitting gold)": pct(s("decisions_found") + s("actions_found"), s("pred_items") + s("pred_decisions")),
        "items / decisions written": f'{s("pred_items")} / {s("pred_decisions")}',
        "unassigned items": s("unassigned_items"),
        "invented numbers / dates": f'{s_len(rows, "invented_numbers")} / {s_len(rows, "invented_dates")}',
        "key points supported": pct(s("points_supported"), s("points")),
        "p50 latency s": f"{statistics.median(ms) / 1000:.1f}" if ms else "n/a",
        "max latency s": f"{max(ms) / 1000:.1f}" if ms else "n/a",
        "calls": s("calls"),
        "degraded meetings": degraded,
    }


def s_len(rows, key):
    return sum(len(r[key]) for r in rows)


def load_run(path: str) -> dict:
    return {row["id"]: row for row in json.load(open(path))}


def gold_as_run(meeting: dict) -> dict:
    return {"id": meeting["id"], "summary": "\n".join(f"- Decided: {d['text']}" for d in meeting["decisions"]),
            "actionItems": [a["task"] for a in meeting["actionItems"]],
            "actionDetails": [{"owner": a.get("owner", ""), "task": a["task"], "due": ""} for a in meeting["actionItems"]]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--gold", required=True)
    parser.add_argument("--run", action="append", default=[], help="name=path to murmur-eval meeting --out JSON")
    parser.add_argument("--control", action="store_true")
    parser.add_argument("--self", action="store_true")
    parser.add_argument("--json")
    parser.add_argument("--per-meeting", action="store_true")
    args = parser.parse_args()
    meetings = json.load(open(args.gold))["meetings"]
    runs = {}
    if args.self:
        runs["gold (ceiling)"] = {m["id"]: gold_as_run(m) for m in meetings}
    for spec in args.run:
        name, _, path = spec.partition("=")
        runs[name] = load_run(path)
    table, detail = {}, {}
    for name, run in runs.items():
        rows = [score_meeting(m, run[m["id"]]) for m in meetings if m["id"] in run]
        missing = [m["id"] for m in meetings if m["id"] not in run]
        table[name] = aggregate(rows)
        if missing:
            table[name]["missing meetings"] = ",".join(missing)
        detail[name] = rows
        if args.control:
            shifted = [score_meeting(meetings[(i + 1) % len(meetings)], run[m["id"]])
                       for i, m in enumerate(meetings) if m["id"] in run]
            table[f"{name} vs wrong meeting (floor)"] = aggregate(shifted)
    metrics = list(dict.fromkeys(k for t in table.values() for k in t))
    names = list(table)
    print("| metric | " + " | ".join(names) + " |")
    print("|---|" + "---|" * len(names))
    for metric in metrics:
        print(f"| {metric} | " + " | ".join(str(table[n].get(metric, "")) for n in names) + " |")
    if args.per_meeting:
        for name, rows in detail.items():
            print(f"\n{name}")
            for r in rows:
                print(f'  {r["id"]} dec {r["decisions_found"]}/{r["gold_decisions"]} act {r["actions_found"]}/{r["gold_actions"]} '
                      f'owner-wrong {r["owner_wrong"]}/{r["owner_checked"]} inv-owner {r["invented_owners"]} '
                      f'unsupported {len(r["unsupported"])}/{r["produced"]} inv-num {r["invented_numbers"]} {r["ms"] / 1000:.0f}s {r["note"]}')
    if args.json:
        json.dump({"table": table, "meetings": detail}, open(args.json, "w"), indent=1)


if __name__ == "__main__":
    main()
