"""Score list layout on Evals/list-layout-dev.jsonl: shape by code, no judge. Invented dev text; never trained on.

    python3 scripts/list_layout_score.py <cases.jsonl> name=<outputs.jsonl>...

A case passes when the output has the expected shape (bullets, numbered, paragraphs or none), the expected
number of items, none of the `absent` phrases (a spoken layout direction left in the text) and all of the
`present` ones (content that must survive)."""
import json, re, sys

def shape(text):
    bullets = len(re.findall(r"(?m)^\s*[-•*]\s+\S", text)); numbered = len(re.findall(r"(?m)^\s*\d+[.)]\s+\S", text))
    if bullets and not numbered: return "bullets", bullets
    if numbered and not bullets: return "numbered", numbered
    if bullets or numbered: return "mixed", bullets + numbered
    return ("paragraphs" if "\n\n" in text.strip() else "none"), 0

def verdict(case, text):
    got, n = shape(text); want = case["expect"]; low = text.lower(); why = []
    if want == "none" and got not in ("none", "paragraphs"): why.append(f"listed ({got})")
    if want == "paragraphs" and got != "paragraphs": why.append(f"shape {got}")
    if want in ("bullets", "numbered"):
        if got != want: why.append(f"shape {got}")
        elif n != case["items"]: why.append(f"{n} items, want {case['items']}")
    why += [f"kept '{p}'" for p in case["absent"] if p.lower() in low]
    why += [f"lost '{p}'" for p in case["present"] if p.lower() not in low]
    return why

cases = [json.loads(line) for line in open(sys.argv[1])]
for spec in sys.argv[2:]:
    name, path = spec.split("=", 1); out = {r["id"]: r["text"] for r in map(json.loads, open(path))}
    fails = {c["id"]: verdict(c, out.get(c["id"], "")) for c in cases}
    lists = [c for c in cases if c["expect"] in ("bullets", "numbered", "paragraphs")]; plain = [c for c in cases if c["expect"] == "none"]
    ok = lambda group: sum(not fails[c["id"]] for c in group)
    print(f"{name}: layout wanted {ok(lists)} of {len(lists)} | must stay prose {ok(plain)} of {len(plain)}")
    for cid, why in fails.items():
        if why: print(f"  {cid}: {'; '.join(why)}")
