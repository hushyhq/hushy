#!/usr/bin/env python3
"""Builds the public meeting scorecard set from the AMI corpus manual annotations (CC BY 4.0).

Each meeting becomes a `murmur-eval meeting --golden` file entry: the transcript as speaker turns
labelled by role ("Project Manager: ..."), and the human gold from AMI's abstractive summaries
(decisions and actions as separate lists). Long meetings (60+ minutes) are two consecutive
meetings of one team joined end to end, with the union of their gold.

The split is by team (series), so no team's voice is in both dev and test. Meetings whose words
appear in a training file (`--train`, any JSONL) are left out, so a fine-tuned model is not
scored on a transcript it was trained on.

    scripts/meeting-eval/build_public_ami.py [--ami Evals/runs/public/ami/extracted]
        [--train .build/modal-staging/data-r10d/train.jsonl] [--out .build/meetings-hillclimb/sets]

Writes ami-dev.json, ami-test.json, ami-long.json and contamination.tsv. Never tune on ami-test.
"""
import argparse
import hashlib
import html
import json
import re
from pathlib import Path

ROLES = {"PM": "Project Manager", "ME": "Marketing Expert", "UI": "User Interface Designer", "ID": "Industrial Designer"}
OWNER_PATTERNS = [
    ("Project Manager", r"project manager|\bpm\b"),
    ("Marketing Expert", r"marketing"),
    ("User Interface Designer", r"user interface|\bui\b|interface designer"),
    ("Industrial Designer", r"industrial designer|\bid\b"),
    ("group", r"\b(group|team|everyone|all)\b"),
]
TURN_GAP_SECONDS = 1.5
WORD = re.compile(r'<w ([^>]*)>([^<]*)</w>')
START = re.compile(r'starttime="([\d.]+)"')
SENTENCE = re.compile(r"<sentence[^>]*>(.*?)</sentence>", re.S)


def roles_by_meeting(root: Path) -> dict:
    text = (root / "corpusResources/meetings.xml").read_text(encoding="latin-1")
    meetings = {}
    for block in re.finditer(r'<meeting [^>]*observation="(\w+)"[^>]*duration="(\d+)"[^>]*>(.*?)</meeting>', text, re.S):
        speakers = dict(re.findall(r'nxt_agent="(\w)"[^>]*role="(\w+)"', block.group(3)))
        meetings[block.group(1)] = {"duration": int(block.group(2)), "roles": speakers}
    return meetings


def words(root: Path, meeting: str, agent: str) -> list:
    path = root / f"words/{meeting}.{agent}.words.xml"
    if not path.exists():
        return []
    out = []
    for attributes, token in WORD.findall(path.read_text(encoding="latin-1")):
        token, start = html.unescape(token).strip(), START.search(attributes)
        if token and start:
            out.append((float(start.group(1)), agent, token, 'punc="true"' in attributes))
    return out


def transcript(root: Path, meeting: str, roles: dict) -> tuple:
    stream = sorted((w for agent in roles for w in words(root, meeting, agent)), key=lambda w: w[0])
    turns = []
    last_time = -1e9
    for start, agent, token, punc in stream:
        label = ROLES.get(roles[agent], roles[agent])
        if punc:
            if turns and turns[-1][0] == label:
                turns[-1][1].append((token, punc))
            continue
        if turns and turns[-1][0] == label and start - last_time < TURN_GAP_SECONDS:
            turns[-1][1].append((token, punc))
        else:
            turns.append([label, [(token, punc)]])
        last_time = start
    lines = []
    for label, tokens in turns:
        text = ""
        for token, punc in tokens:
            text += token if punc or not text else " " + token
        lines.append(f"{label}: {text}")
    merged = []
    for line in lines:
        label, text = line.split(": ", 1)
        if merged and merged[-1][0] == label:
            merged[-1][1] += " " + text
        else:
            merged.append([label, text])
    return "\n".join(f"{label}: {text}" for label, text in merged), sum(1 for w in stream if not w[3])


def gold(root: Path, meeting: str) -> dict:
    text = (root / f"abstractive/{meeting}.abssumm.xml").read_text(encoding="latin-1")

    def section(tag):
        match = re.search(rf"<{tag}[^>]*>(.*?)</{tag}>", text, re.S)
        if not match:
            return []
        return [html.unescape(s).strip() for s in SENTENCE.findall(match.group(1)) if s.strip() and s.strip() != "*NA*"]

    return {"abstract": section("abstract"), "actions": section("actions"), "decisions": section("decisions")}


def owner_of(action: str) -> str:
    head = action.lower()[:60]
    for owner, pattern in OWNER_PATTERNS:
        if re.search(pattern, head):
            return owner
    return ""


def item(prefix: str, index: int, **fields) -> dict:
    base = {"id": f"{prefix}{index + 1}", "terms": [], "position": 0.5, "quartile": 2, "lastTenMinutes": False}
    base.update(fields)
    return base


def entry(meeting_id: str, title: str, minutes: int, roles: list, text: str, word_count: int, g: dict) -> dict:
    return {
        "id": meeting_id, "title": title, "minutes": minutes, "style": "names",
        "people": [{"name": r, "label": r} for r in roles], "words": word_count, "transcript": text,
        "actionItems": [item("a", i, owner=owner_of(a), task=a) for i, a in enumerate(g["actions"])],
        "superseded": [], "distractors": [],
        "decisions": [item("d", i, text=d) for i, d in enumerate(g["decisions"])],
        "abstract": g["abstract"],
    }


def normalized(text: str) -> str:
    return " ".join(re.findall(r"[a-z0-9']+", text.lower()))


def contaminated(train_text: str, text: str, probes: int = 6, length: int = 10) -> int:
    tokens = normalized(text).split()
    if len(tokens) < length * probes:
        return 0
    step = len(tokens) // (probes + 1)
    hits = 0
    for k in range(1, probes + 1):
        probe = " ".join(tokens[k * step:k * step + length])
        hits += probe in train_text
    return hits


def split_of(series: str) -> str:
    return "test" if int(hashlib.sha256(series.encode()).hexdigest(), 16) % 2 else "dev"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ami", default="Evals/runs/public/ami/extracted")
    parser.add_argument("--train", default="")
    parser.add_argument("--out", default=".build/meetings-hillclimb/sets")
    parser.add_argument("--per-split", type=int, default=14)
    parser.add_argument("--long", type=int, default=4)
    args = parser.parse_args()
    root, out = Path(args.ami), Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    meta = roles_by_meeting(root)
    train_text = ""
    if args.train:
        train_text = " ".join(normalized(line) for line in open(args.train, encoding="utf-8", errors="ignore"))

    built, contamination = {}, []
    for path in sorted((root / "abstractive").glob("*.abssumm.xml")):
        meeting = path.name.split(".")[0]
        if meeting not in meta or len(meta[meeting]["roles"]) < 3:
            continue
        g = gold(root, meeting)
        text, count = transcript(root, meeting, meta[meeting]["roles"])
        hits = contaminated(train_text, text) if train_text else 0
        contamination.append((meeting, hits, count))
        if hits:
            continue
        roles = sorted({ROLES.get(r, r) for r in meta[meeting]["roles"].values()})
        built[meeting] = entry(meeting, f"AMI {meeting}", round(meta[meeting]["duration"] / 60), roles, text, count, g)

    def usable(m):
        return len(m["decisions"]) + len(m["actionItems"]) >= 4 and m["words"] >= 2_000

    sets = {"dev": [], "test": []}
    for meeting_id in sorted(built):
        m = built[meeting_id]
        if usable(m):
            sets[split_of(meeting_id[:-1])].append(m)
    for name, meetings in sets.items():
        meetings.sort(key=lambda m: hashlib.sha256(m["id"].encode()).hexdigest())
        chosen = sorted(meetings[: args.per_split], key=lambda m: m["id"])
        (out / f"ami-{name}.json").write_text(json.dumps({"note": NOTE, "meetings": chosen}, indent=1))
        print(f"ami-{name}: {len(chosen)} meetings, {sum(len(m['decisions']) for m in chosen)} decisions, "
              f"{sum(len(m['actionItems']) for m in chosen)} actions, {sum(m['words'] for m in chosen)} words")

    long_meetings = []
    for meeting_id in sorted(built):
        if not meeting_id.endswith("c"):
            continue
        partner = meeting_id[:-1] + "d"
        if partner not in built or split_of(meeting_id[:-1]) != "dev":
            continue
        a, b = built[meeting_id], built[partner]
        joined = {"abstract": a["abstract"] + b["abstract"],
                  "actions": [x["task"] for x in a["actionItems"] + b["actionItems"]],
                  "decisions": [x["text"] for x in a["decisions"] + b["decisions"]]}
        m = entry(meeting_id[:-1] + "cd", f"AMI {meeting_id[:-1]} c+d", a["minutes"] + b["minutes"],
                  sorted({p["name"] for p in a["people"] + b["people"]}), a["transcript"] + "\n" + b["transcript"],
                  a["words"] + b["words"], joined)
        if m["minutes"] >= 60:
            long_meetings.append(m)
    long_meetings.sort(key=lambda m: hashlib.sha256(m["id"].encode()).hexdigest())
    chosen = sorted(long_meetings[: args.long], key=lambda m: m["id"])
    (out / "ami-long.json").write_text(json.dumps({"note": NOTE, "meetings": chosen}, indent=1))
    print(f"ami-long: {len(chosen)} meetings, minutes {[m['minutes'] for m in chosen]}, words {[m['words'] for m in chosen]}")
    with open(out / "contamination.tsv", "w") as f:
        f.write("meeting\tprobe_hits_of_6\twords\n")
        for row in contamination:
            f.write("\t".join(map(str, row)) + "\n")
    print(f"contaminated (left out): {sum(1 for r in contamination if r[1])} of {len(contamination)}")


NOTE = ("Built by scripts/meeting-eval/build_public_ami.py from the AMI corpus manual annotations (CC BY 4.0). "
        "Gold is AMI's human abstractive summary (decisions, actions). Score with scripts/meeting-eval/score_public.py.")

if __name__ == "__main__":
    main()
