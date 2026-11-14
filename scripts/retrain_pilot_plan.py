#!/usr/bin/env python3
"""The plan for the 60-passage pilot: what each passage is, before any text exists.

One slot per passage, drawn from a seed so the plan is repeatable and the mix is on record: the
family of message, a length band (in spoken words), which kinds of facts it must carry, a speaking
profile with the ingredients to plant, the surface style a recogniser would hand over, and the
variety seeds (domain, role, register, names) that keep sixty calls from writing sixty versions of
the same message. Pure functions, no network.
"""

import argparse
import json
from pathlib import Path
import random
import sys

FAMILIES = (  # family, share of rows, sub-kinds
    ("chat", 8, ("a chat message to a colleague",)),
    ("email", 8, ("an email",)),
    ("note", 7, ("a note to self",)),
    ("status", 8, ("a status update", "a meeting follow-up")),
    ("personal", 8, ("a personal message to a friend or family member",)),
    ("agent", 21, ("a bug report to an AI coding agent that names a file or a flag in a sentence",
                   "a feature request to an AI agent",
                   "several questions put to an AI agent",
                   "multi-step instructions to an AI agent",
                   "feedback on an AI agent's last piece of work")),
)
AGENT_WEIGHTS = (5, 5, 4, 4, 3)  # how the 21 agent rows split over the five sub-kinds
BANDS = ((40, 100, 20), (100, 180, 25), (180, 280, 15))  # spoken words low, high, rows
PROFILES = (("clean", 5), ("moderate", 30), ("heavy", 25))
FACT_RATES = {"names": 0.70, "numbers": 0.55, "dates": 0.35, "times": 0.30, "amounts": 0.25}
INGREDIENTS = {
    "moderate": ("fillers", "repeated_words", "false_starts"),
    "heavy": ("fillers", "repeated_words", "false_starts", "restarts_apart", "run_on_chain"),
}
PLANT_RATES = {"value_cue": 0.35, "value_restart": 0.28, "opening_adds": 0.28, "negation_corrected": 0.25}
VALUE_PLANTS = ("value_cue", "value_restart")
SURFACES = ("punctuated", "plain")
TYPED_PER_SPOKEN = {"clean": 1.0, "moderate": 0.86, "heavy": 0.74}  # asked-for typed length per spoken word

DOMAINS = """a bakery's online orders|a hospital's appointment system|a high school's timetable|a small trucking firm
|a community garden|a mobile game studio|a dental clinic|a city bike-share scheme|a wedding planner|a university library
|a regional airline's baggage desk|a plumbing business|a podcast network|an online furniture shop|a physiotherapy practice
|a food bank|a language-learning app|a theatre box office|a solar installer|a landlord and tenants|a football club's
fixtures|a farm shop|a freelance photographer|a county council's road repairs|a charity fun run|a recruitment agency
|a cinema chain|a data team at a bank|a hardware startup|a school parents' group|a family holiday|a house move|a
neighbourhood watch|a bookkeeping firm|a veterinary clinic|a small brewery""".replace("\n", " ").split("|")
ROLES = """a shift manager|a product manager|a nurse|a teacher|a backend developer|a freelance designer|a retired
engineer|a student|an office manager|a team lead|a founder|a parent|a researcher|a support agent|a volunteer
coordinator|a project coordinator|a mobile developer|a data analyst|a shop owner|a site supervisor|an accountant|a
sales rep|a night-shift worker|a writer|a new hire""".replace("\n", " ").split("|")
REGISTERS = ("plain and direct", "casual and quick", "slightly rushed", "polite and careful", "dry and understated",
             "warm but plain")
NAMES = """Aisha|Bram|Chidi|Dara|Emeka|Farah|Gustav|Hana|Ines|Jorge|Kofi|Lena|Mateo|Noor|Oskar|Paloma|Quinn|Rafa|Saoirse
|Tariq|Una|Viktor|Wen|Xiomara|Yusuf|Zainab|Anders|Beatriz|Callum|Dev|Elif|Fergus|Greta|Hugo|Imani|Joaquin|Kiran|Lucia
|Mehmet|Nia|Olu|Petra|Ravi|Sunita|Thabo|Ulla|Vera|Wanjiru|Yara""".replace("\n", " ").split("|")
DOMAINS, ROLES, NAMES = ([" ".join(x.split()) for x in group] for group in (DOMAINS, ROLES, NAMES))
FILE_HINTS = ("a config file", "a setting or flag", "a function name", "a test file", "an environment variable")


class PlanError(Exception):
    pass


def _split_counts(total, weights, rng):
    """`total` rows over `weights` (which sum to `total`), as a shuffled list of indices."""
    items = [i for i, w in enumerate(weights) for _ in range(w)]
    if len(items) != total:
        raise PlanError("the weights do not add up to the number of rows")
    rng.shuffle(items)
    return items


def _spread(pairs, total, rng):
    items = [value for value, count in pairs for _ in range(count)]
    if len(items) != total:
        raise PlanError("the shares do not add up to the number of rows")
    rng.shuffle(items)
    return items


def plan(seed=7, rows=60):
    if rows != 60:
        raise PlanError("the shares are written for sixty rows")
    rng = random.Random(seed)
    families = []
    for name, count, kinds in FAMILIES:
        picks = _split_counts(count, AGENT_WEIGHTS, rng) if name == "agent" else [0] * count
        families += [(name, kinds[p]) for p in picks]
    rng.shuffle(families)
    bands = _spread([((lo, hi), n) for lo, hi, n in BANDS], rows, rng)
    profiles = _spread(PROFILES, rows, rng)
    surfaces = _spread([("punctuated", rows // 2), ("plain", rows - rows // 2)], rows, rng)
    slots = []
    for index in range(rows):
        family, kind = families[index]
        profile = profiles[index]
        facts = {name: rng.random() < rate for name, rate in FACT_RATES.items()}
        has_value = any(facts[k] for k in ("numbers", "dates", "times", "amounts"))
        plants = [] if profile == "clean" else [
            plant for plant, rate in PLANT_RATES.items()
            if rng.random() < rate and (has_value or plant not in VALUE_PLANTS)]
        if len([p for p in plants if p in VALUE_PLANTS]) == 2:
            plants.remove(rng.choice(VALUE_PLANTS))  # one value correction of each sort at most is plenty
        lo, hi = bands[index]
        target = rng.randint(lo + (hi - lo) // 8, hi - (hi - lo) // 8)
        slots.append({
            "id": f"p{index + 1:02d}", "family": family, "kind": kind, "band": [lo, hi],
            "spoken_words_target": target,
            "typed_words_target": round(target * TYPED_PER_SPOKEN[profile]),
            "profile": profile, "ingredients": list(INGREDIENTS.get(profile, ())), "plants": plants,
            "surface": surfaces[index], "stray_full_stop": surfaces[index] == "punctuated" and rng.random() < 0.4,
            "facts": facts, "domain": rng.choice(DOMAINS), "role": rng.choice(ROLES),
            "register": rng.choice(REGISTERS), "names": rng.sample(NAMES, 3),
            "file_hint": rng.choice(FILE_HINTS) if family == "agent" else "", "seed": rng.randrange(10**6)})
    return slots


def summary(slots):
    def count(key, fn=lambda s, k: s[k]):
        out = {}
        for slot in slots:
            value = fn(slot, key)
            for item in (value if isinstance(value, list) else [value]):
                out[str(item)] = out.get(str(item), 0) + 1
        return dict(sorted(out.items()))
    return {"rows": len(slots), "family": count("family"), "kind": count("kind"), "profile": count("profile"),
            "surface": count("surface"), "band": count("band", lambda s, k: f"{s[k][0]}-{s[k][1]}"),
            "plants": count("plants"), "ingredients": count("ingredients"),
            "facts": {k: sum(1 for s in slots if s["facts"][k]) for k in FACT_RATES},
            "agent_share": round(sum(1 for s in slots if s["family"] == "agent") / len(slots), 3),
            "stray_full_stop": sum(1 for s in slots if s["stray_full_stop"])}


def main(argv=None):
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--out", required=True)
    cli.add_argument("--seed", type=int, default=7)
    args = cli.parse_args(argv)
    slots = plan(args.seed)
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text("".join(json.dumps(s) + "\n" for s in slots), encoding="utf-8")
    print(json.dumps(summary(slots), indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
