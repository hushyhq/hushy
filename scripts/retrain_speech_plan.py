"""The plan for the speech-first pilot: 45 slots, each describing a person and a situation, never a text.

Same idea as retrain_pilot_plan (a seeded slot per passage, mix on record) with the changes the speech-first route
needs: four length bands (a short one of 12 to 40 spoken words is added), the agent-prompt family at 35 percent
with its own shapes, every family spread over the bands, plan reversals as a planted correction, and file, tool or
product names for the agent family.
"""

import json
from pathlib import Path
import random
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

import retrain_pilot_plan as base  # noqa: E402
import retrain_scale_pools as scale_pools  # noqa: E402

BANDS = ((12, 40), (40, 100), (100, 180), (180, 280))
FAMILY_ROWS = (("agent", 16), ("chat", 6), ("email", 5), ("note", 6), ("status", 6), ("personal", 6))
AGENT_BAND_COUNTS = (6, 4, 4, 2)  # the agent family leans short, as real prompts do
AGENT_KINDS = (
    "a bug report to an AI coding agent that names a file or a flag in a sentence",
    "a feature request to an AI agent partway through a task",
    "several questions put to an AI agent about the work in front of it",
    "multi-step instructions to an AI agent",
    "feedback on an AI agent's last piece of work")
OTHER_KINDS = {"chat": ("a chat message to a colleague",), "email": ("an email",), "note": ("a note to self",),
               "status": ("a status update", "a meeting follow-up"),
               "personal": ("a personal message to a friend or family member",)}
PLANT_RATES = {"value_cue": 0.30, "value_restart": 0.22, "opening_adds": 0.40, "negation_corrected": 0.20,
               "plan_reversal": 0.40}
AGENT_ONLY_PLANTS = ("plan_reversal",)
VALUE_PLANTS = ("value_cue", "value_restart")
PROFILES = (("clean", 4), ("moderate", 20), ("heavy", 21))
FACT_RATES = {"names": 0.6, "numbers": 0.5, "dates": 0.3, "times": 0.25, "amounts": 0.2}
WORDS_PER_NOTE_POINT = 28  # points in the notes per spoken words, roughly


def scale_plan(count, seed=11):
    """Seeded mix for a full retraining batch; long means a target over 120 words."""
    if count < 1:
        raise ValueError("count must be positive")
    rng = random.Random(seed)
    families = ["agent", "chat", "email", "note", "status"]
    weights = [35, 20, 20, 15, 10]
    quotas = [count * weight // 100 for weight in weights]
    for i in range(count - sum(quotas)):
        quotas[i % len(quotas)] += 1
    family_slots = [family for family, quota in zip(families, quotas) for _ in range(quota)]
    rng.shuffle(family_slots)
    long_count = (count * 3 + 4) // 5
    bands = [[121, 180] if i % 2 == 0 else [180, 280] for i in range(long_count)]
    bands += [[12, 40] if i % 2 == 0 else [40, 120] for i in range(count - long_count)]
    rng.shuffle(bands)
    profiles = ["clean"] * round(count * 4 / 45) + ["moderate"] * round(count * 20 / 45)
    profiles += ["heavy"] * (count - len(profiles))
    rng.shuffle(profiles)
    surfaces = ["punctuated"] * round(count * 23 / 45)
    surfaces += ["plain"] * (count - len(surfaces))
    rng.shuffle(surfaces)
    kinds_by_family = {}
    for family, quota in zip(families, quotas):
        kinds = AGENT_KINDS if family == "agent" else OTHER_KINDS[family]
        cycle = [kinds[i % len(kinds)] for i in range(quota)]
        rng.shuffle(cycle)
        kinds_by_family[family] = iter(cycle)
    name_deck = [f"{given} {surname}" for given in scale_pools.GIVEN_NAMES
                 for surname in scale_pools.FAMILY_NAMES]
    rng.shuffle(name_deck)
    name_index = 0
    out = []
    for i, (family, band) in enumerate(zip(family_slots, bands), 1):
        lo, hi = band
        profile = profiles[i - 1]
        if hi <= 40 and profile == "heavy":
            profile = "moderate"
        facts = {key: rng.random() < rate for key, rate in FACT_RATES.items()}
        if family == "agent":
            facts["files"] = rng.random() < 0.7
        has_value = any(facts[key] for key in ("numbers", "dates", "times", "amounts"))
        plants = [] if profile == "clean" else [
            plant for plant, rate in PLANT_RATES.items() if rng.random() < rate
            and (has_value or plant not in VALUE_PLANTS)
            and (family == "agent" or plant not in AGENT_ONLY_PLANTS)]
        plants = [plant for plant in plants if plant != "opening_adds" or hi > 40]
        if hi <= 40:
            plants = plants[:1]
        if all(plant in plants for plant in VALUE_PLANTS):
            plants.remove(rng.choice(VALUE_PLANTS))
        if name_index + 3 > len(name_deck):
            rng.shuffle(name_deck)
            name_index = 0
        names = name_deck[name_index:name_index + 3]
        name_index += 3
        target = rng.randint(lo + (hi - lo) // 8, hi - (hi - lo) // 8)
        out.append({"id": f"s{i:05d}", "route": "speech_first", "family": family,
                    "kind": next(kinds_by_family[family]), "band": band,
                    "spoken_words_target": target, "points": max(1, round(target / WORDS_PER_NOTE_POINT)),
                    "profile": profile, "plants": plants, "surface": surfaces[i - 1],
                    "stray_full_stop": surfaces[i - 1] == "punctuated" and rng.random() < 0.4,
                    "facts": facts, "domain": rng.choice(scale_pools.DOMAINS),
                    "role": rng.choice(scale_pools.ROLES), "register": rng.choice(base.REGISTERS),
                    "names": names, "seed": rng.randrange(10**9)})
    return out


def _bands_for(family, count, rng):
    if family == "agent":
        items = [band for band, n in zip(BANDS, AGENT_BAND_COUNTS) for _ in range(n)]
    else:
        order = list(BANDS)
        rng.shuffle(order)
        items = [order[i % 4] for i in range(count)]
    rng.shuffle(items)
    return items


def plan(seed=11):
    rng = random.Random(seed)
    slots = []
    for family, count in FAMILY_ROWS:
        bands = _bands_for(family, count, rng)
        kinds = AGENT_KINDS if family == "agent" else OTHER_KINDS[family]
        kind_cycle = [kinds[i % len(kinds)] for i in range(count)]
        rng.shuffle(kind_cycle)
        for band, kind in zip(bands, kind_cycle):
            slots.append({"family": family, "kind": kind, "band": list(band)})
    rng.shuffle(slots)
    profiles = [p for p, n in PROFILES for _ in range(n)]
    rng.shuffle(profiles)
    surfaces = ["punctuated"] * 23 + ["plain"] * 22
    rng.shuffle(surfaces)
    out = []
    for index, slot in enumerate(slots):
        family, (lo, hi) = slot["family"], slot["band"]
        profile = profiles[index]
        if hi <= 40 and profile == "heavy":
            profile = "moderate"
        facts = {k: rng.random() < rate for k, rate in FACT_RATES.items()}
        if family == "agent":
            facts["files"] = rng.random() < 0.7
        has_value = any(facts[k] for k in ("numbers", "dates", "times", "amounts"))
        plants = [] if profile == "clean" else [
            p for p, rate in PLANT_RATES.items() if rng.random() < rate
            and (has_value or p not in VALUE_PLANTS) and (family == "agent" or p not in AGENT_ONLY_PLANTS)]
        plants = [p for p in plants if p != "opening_adds" or hi > 40]
        if hi <= 40:
            plants = plants[:1]
        if len([p for p in plants if p in VALUE_PLANTS]) == 2:
            plants.remove(rng.choice(VALUE_PLANTS))
        target = rng.randint(lo + (hi - lo) // 8, hi - (hi - lo) // 8)
        out.append({
            "id": f"s{index + 1:02d}", "route": "speech_first", "family": family, "kind": slot["kind"],
            "band": [lo, hi], "spoken_words_target": target, "points": max(1, round(target / WORDS_PER_NOTE_POINT)),
            "profile": profile, "plants": plants, "surface": surfaces[index],
            "stray_full_stop": surfaces[index] == "punctuated" and rng.random() < 0.4, "facts": facts,
            "domain": rng.choice(base.DOMAINS), "role": rng.choice(base.ROLES), "register": rng.choice(base.REGISTERS),
            "names": rng.sample(base.NAMES, 3), "seed": rng.randrange(10**6)})
    return out


def summary(slots):
    def count(fn):
        out = {}
        for slot in slots:
            value = fn(slot)
            for item in (value if isinstance(value, list) else [value]):
                out[str(item)] = out.get(str(item), 0) + 1
        return dict(sorted(out.items()))
    return {"rows": len(slots), "family": count(lambda s: s["family"]), "profile": count(lambda s: s["profile"]),
            "surface": count(lambda s: s["surface"]), "band": count(lambda s: f"{s['band'][0]}-{s['band'][1]}"),
            "family_by_band": count(lambda s: f"{s['family']}:{s['band'][0]}-{s['band'][1]}"),
            "plants": count(lambda s: s["plants"]),
            "agent_share": round(sum(1 for s in slots if s["family"] == "agent") / len(slots), 3),
            "files": sum(1 for s in slots if s["facts"].get("files"))}


def main(argv=None):
    import argparse
    cli = argparse.ArgumentParser()
    cli.add_argument("--out", required=True)
    cli.add_argument("--seed", type=int, default=11)
    args = cli.parse_args(argv)
    slots = plan(args.seed)
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text("".join(json.dumps(s) + "\n" for s in slots), encoding="utf-8")
    print(json.dumps(summary(slots), indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
