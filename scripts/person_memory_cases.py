#!/usr/bin/env python3
"""Generate the wholly invented, deterministic person-memory dev set."""
import json
from pathlib import Path

THEMES = [
    ("Veloria", "Valoria", "Nerula", "new ruler", "Meral", "mural"),
    ("Avenlo", "avenue", "Teralis", "terrorless", "Parel", "parallel"),
    ("Solmera", "summer", "Kivora", "key for a", "Cadel", "cattle"),
    ("Rovika", "Rebecca", "Dunaro", "do narrow", "Ferin", "ferrying"),
    ("Brelan", "Braylon", "Ostera", "oyster", "Selin", "ceiling"),
    ("Nivaro", "Navarro", "Calune", "calloon", "Pavin", "paving"),
    ("Tavelle", "travel", "Orendi", "already", "Maden", "maiden"),
    ("Lunara", "Luna", "Vesaro", "the sorrow", "Dorin", "door in"),
    ("Korelia", "corollary", "Mavento", "momentum", "Barel", "barrel"),
    ("Denora", "the Nora", "Silvani", "Sylvaney", "Ralen", "railing"),
    ("Peravo", "bravo", "Zeluna", "the lunar", "Norel", "normal"),
    ("Camira", "camera", "Fovela", "for Vella", "Ravin", "raving"),
]

EXTRA = ["Juniper desk", "winter ledger", "copper sketch", "north alcove", "quiet harbor",
         "silver folder", "maple board", "open ticket", "paper index", "evening plan",
         "garden shelf", "cobalt chart"]
HEARD_EXTRA = ["juniper disk", "winter ledge", "copper scratch", "north alcohol", "quiet harbour",
               "silver holder", "maple border", "open tick it", "paper in decks", "even plan",
               "garden self", "cobalt shard"]
EDIT_TARGET = ["Jorella", "Pamera", "Vandri", "Calora", "Benvia", "Torami",
               "Sorella", "Damera", "Kelora", "Rovena", "Pelari", "Navora"]
EDIT_HEARD = ["your Ella", "Pam era", "van dry", "call Laura", "Ben via", "tore me",
              "so Rella", "dam era", "call Laura", "row vena", "pill airy", "nav aura"]


def make_rows():
    rows = []
    for i, (name, heard_name, term, heard_term, other, common) in enumerate(THEMES):
        words = [name, term, "Arden", "Bexley", "Cintara", "Dovet", "Elara", "Fennick",
                 "Gavrel", "Halden", "Isola", "Jorren"]
        style = "brief friendly notes; sign off Cheers, Rowan" if i % 2 == 0 else "short formal notes; sign off Best, Rowan"
        prior = [
            f"The amber lantern stays beside the west gate. Ask {name} about the draft.",
            f"We agreed to call the new route {EXTRA[i]}. Keep the map for Friday.",
            f"Please check {term} before noon. The violet paper crane belongs in storage.",
        ]
        before, after = f"Use the {EDIT_HEARD[i]} label", f"Use the {EDIT_TARGET[i]} label"
        history = {"style": style, "terms": words, "earlier": prior,
                   "edits": [{"before": before, "after": after},
                             {"before": "send the note next week", "after": "send the note on Monday"}]}
        prefix = f"pm-{i + 1:02d}"
        def add(kind, spoken, expected, keys, control=False):
            rows.append({"id": f"{prefix}-{kind}", "kind": kind, "control": control,
                         "spoken": spoken, "expected": expected, "keyItems": keys,
                         "history": history})
        add("name", f"please send the short draft to {heard_name} by friday",
            f"Please send the short draft to {name} by Friday.", [name])
        add("term", f"the {heard_term} review is ready for tomorrow",
            f"The {term} review is ready for tomorrow.", [term])
        if i % 2 == 0:
            add("earlier", f"please update the {HEARD_EXTRA[i]} route after lunch",
                f"Please update the {EXTRA[i]} route after lunch.", [EXTRA[i]])
        else:
            add("edit", f"use the {EDIT_HEARD[i]} label on the new page",
                f"Use the {EDIT_TARGET[i]} label on the new page.", [EDIT_TARGET[i]])
        if i < 9:
            signoff = "Cheers, Rowan" if i % 2 == 0 else "Best, Rowan"
            add("style", "please say the meeting is moved to tuesday and use my usual sign off",
                f"The meeting is moved to Tuesday.\n\n{signoff}", [signoff])
        else:
            add("control-style", "please say the meeting is moved to tuesday and sign off sincerely",
                "The meeting is moved to Tuesday.\n\nSincerely,", ["Sincerely"], True)
        add("control-near", f"we need a {common} on the diagram today",
            f"We need a {common} on the diagram today.", [common], True)
    return rows


def write(path):
    rows = make_rows()
    kinds = {kind: sum(row["kind"] == kind for row in rows) for kind in sorted({r["kind"] for r in rows})}
    header = {"_header": "Invented person-memory dev set; 12 invented people, 60 cases, 45 positive, 15 controls; no real history.",
              "kinds": kinds}
    path.write_text("\n".join(json.dumps(x, ensure_ascii=False) for x in [header, *rows]) + "\n")


if __name__ == "__main__":
    write(Path(__file__).resolve().parents[1] / "Evals/person-memory.jsonl")
