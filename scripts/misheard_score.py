#!/usr/bin/env python3
"""Score an `murmur-eval intent-app` output against Evals/misheard-probe.jsonl.

usage: python3 -I scripts/misheard_score.py <cases.jsonl> <out.jsonl> [--rows]
Classes for a case: repaired / kept / deleted / other. Controls: control-real is "unchanged"
or "changed"; control-unclear is kept / deleted / other. Refused = the app rejected the model
answer (usedModel false; absent in the training PC's intent_box.py output, which counts as used); the app's final text is still scored, and the rejected model answer
is scored as well ("model said").
"""
import json, re, sys

def toks(s):
    s = s.lower().replace("'", "").replace("’", "").replace(".", "")
    return re.sub(r"[^a-z0-9]+", " ", s).split()

def find(hay, needle):
    n = len(needle)
    return [i for i in range(len(hay) - n + 1) if hay[i:i + n] == needle] if n else []

def classify(case, text):
    out, heard = toks(text), toks(case["heard"])
    if case["role"] == "control-real":
        return "unchanged" if find(out, heard) else "changed"
    has_heard = bool(find(out, heard))
    if case["role"] == "case":
        for variant in case["intended"]:
            if find(out, toks(variant)) and not has_heard:
                return "repaired"
    if has_heard:
        return "kept"
    spoken = toks(case["spoken"])
    at = find(spoken, heard)[0]
    left = spoken[at - 1] if at > 0 else None
    right = spoken[at + len(heard)] if at + len(heard) < len(spoken) else None
    if left and right:
        for i in find(out, [left]):
            if out[i + 1:i + 2] == [right]:
                return "deleted"
    elif left and out and out[-1] == left:
        return "deleted"
    # Nothing new was written and some words are gone: a deletion even when the neighbours moved too
    # (an article went with it, or a filler). A new word means it was replaced or rewritten.
    spoken_set = set(spoken)
    if len(out) < len(spoken) and all(t in spoken_set or t.isdigit() for t in out):
        return "deleted"
    return "other"

def raw_text(answer):
    try:
        return json.loads(answer)["text"]
    except (ValueError, KeyError, TypeError):
        return answer

def rows(path):
    return [json.loads(l) for l in open(path) if l.strip()]

def main():
    cases = {c["id"]: c for c in rows(sys.argv[1])}
    results = rows(sys.argv[2])
    show = "--rows" in sys.argv
    tally, model_tally, refused_n = {}, {}, 0
    detail = []
    for r in results:
        case = cases[r["id"]]
        role = case["role"]
        cls = classify(case, r["text"])
        refused = not r.get("usedModel", True)
        refused_n += refused
        rejected = [s.get("rejectedAnswer") for s in r.get("stages", []) if s.get("rejectedAnswer")]
        # `modelAnswers` (raw model replies, newer runner) beats `rejectedAnswer`, which the intent path leaves empty.
        raw = [raw_text(a) for a in r.get("modelAnswers", [])] or rejected
        said = classify(case, raw[-1]) if raw else None
        rejected = raw if refused else []
        if said:
            model_tally.setdefault(role, {}).setdefault(said, 0)
            model_tally[role][said] += 1
        tally.setdefault(role, {}).setdefault(cls, 0)
        tally[role][cls] += 1
        if refused:
            tally[role].setdefault("(refused)", 0)
            tally[role]["(refused)"] += 1
        detail.append((case, r, cls, refused, said, rejected))
    print("rows", len(results), "refused", refused_n)
    for role, counts in tally.items():
        print(f"{role:16s}", ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    if model_tally:
        print("what the model itself answered (before the app's guards):")
        for role, counts in model_tally.items():
            print(f"  {role:16s}", ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    kinds = {}
    for case, r, cls, refused, said, rej in detail:
        if case["role"] == "case":
            kinds.setdefault(case["kind"], {}).setdefault(cls, 0)
            kinds[case["kind"]][cls] += 1
    for k, c in kinds.items():
        print(f"  {k:10s}", ", ".join(f"{a}={b}" for a, b in sorted(c.items())))
    if show:
        for case, r, cls, refused, said, rej in detail:
            if cls in ("repaired", "unchanged"):
                continue
            print(f"[{case['id']}] {cls}{' REFUSED(' + str(r.get('rejection')) + ')' if refused else ''}"
                  f"{' model-said=' + said if said else ''}")
            print("   in :", case["spoken"])
            print("   out:", r["text"])
            for s in rej:
                print("   rej:", s)

if __name__ == "__main__":
    main()
