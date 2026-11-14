"""The independent meaning check: two typed texts of one passage (the original and the one the example writer
produced from the spoken text alone) must agree on numbers, names, dates and negations.

Built on the writer's own checks run both ways, so a value in one that is not in the other is caught whichever
side added it.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import retrain_checks as checks  # noqa: E402


def compare_typed(original, second):
    """{"problems": [...], "detail": {...}}; no problems means the two agree on every tracked fact."""
    problems, detail = [], {}
    for name, check in (("numbers", checks.check_numbers), ("dates", checks.check_dates),
                        ("names", checks.check_names)):
        forward = check(original, second, [], [])
        backward = check(second, original, [], [])
        if not forward["ok"] or not backward["ok"]:
            problems.append(name)
            detail[name] = {"second_has_extra": forward.get("added"), "second_lacks": forward.get("missing")}
    first_negations, second_negations = checks.negation_count(original), checks.negation_count(second)
    if first_negations != second_negations:
        problems.append("negation")
        detail["negation"] = {"original": first_negations, "second": second_negations}
    return {"problems": problems, "detail": detail}
