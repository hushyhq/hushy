"""Pilot round 4: the side-by-side file (Evals/runs/retrain/pilot60.md) with the release-route columns."""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import retrain_release as release  # noqa: E402


def earlier_text_table(sources, verdicts):
    """The whole arm pair-checked on the release route against earlier typed text."""
    out = {}
    for route in release.ROUTES:
        rows = [release.release_verdict(verdicts.get(f"{s['id']}-whole-old")) for s in sources if s["route"] == route]
        rows = [r for r in rows if r["status"] in ("accepted", "rejected")]
        reasons = {}
        for r in rows:
            if r["status"] == "rejected":
                key = release.reason_key(r["reason"])
                reasons[key] = reasons.get(key, 0) + 1
        out[route] = {"judged": len(rows), "accepted": sum(1 for r in rows if r["status"] == "accepted"),
                      "rejected": sum(1 for r in rows if r["status"] == "rejected"),
                      "reasons": dict(sorted(reasons.items(), key=lambda kv: -kv[1]))}
    return out


def rows_kept(assessments):
    """Training rows that survive the mechanical, representability, joined-text, and release-route pair checks.
    Group rows per route, and whole-dictation rows per route."""
    out = {}
    for route in release.ROUTES:
        rows = [a for a in assessments if a["route"] == route]
        out[route] = {"group_rows": sum(1 for a in rows for g in a["groups"] if g["accepted"]),
                      "group_pairs": sum(len(a["groups"]) for a in rows),
                      "whole_rows": sum(1 for a in rows if not a["whole"]["failed_checks"]
                                        and a["whole"]["guard"]["status"] == "accepted"),
                      "whole_pairs": len(rows)}
    return out


def short_summary(summary):
    lines = []
    for arm in release.ARMS:
        for route in release.ROUTES:
            t = summary["reasons"][arm][route]
            lines.append(f"{arm:5} {route:12} judged {t['judged']:4} accepted {t['accepted']:4} rejected {t['rejected']:4} "
                         f"(basis {t['basis']})  "
                         + ", ".join(f"{k} {v['count']}" for k, v in t["reasons"].items()))
    lines.append("rows kept: " + json.dumps(summary["rows_kept"]))
    d = summary["differences"]
    lines.append(f"relabel differs in words: {d['differ_in_words']} of {d['passages']} {d['by_route']} {d['by_class']}")
    return "\n".join(lines)


def _verdict_line(v):
    if v.get("status") not in ("accepted", "rejected"):
        return v.get("status", "not run")
    tag = "" if v.get("basis") in ("exact", "same_words") else f" ({v.get('basis')}: re-run on the release draft)"
    return f"{v['status']}{(': ' + v['reason']) if v['reason'] else ''}{tag}"


def _earlier_group(earlier, ident, index):
    row = earlier.get(ident)
    if not row:
        return None
    return next((g for g in row["groups"] if g["index"] == index), None)


def _table_md(summary):
    out = ["## Counts from the release-route pair check", "",
           "| arm | route | judged | accepted | rejected | basis: exact / same words / approx / approx unreproduced |", "|---|---|---|---|---|---|"]
    for arm in release.ARMS:
        for route in release.ROUTES:
            t = summary["reasons"][arm][route]
            basis = " / ".join(str(t["basis"][n]) for n in release.BASES)
            out.append(f"| {arm} | {route} | {t['judged']} | {t['accepted']} | {t['rejected']} | {basis} |")
    out += ["", "Training rows that survive every check (mechanical checks, representable span, release-route pair check): "
            + "; ".join(f"{route}: {k['group_rows']} of {k['group_pairs']} group rows, {k['whole_rows']} of "
                        f"{k['whole_pairs']} whole rows" for route, k in summary["rows_kept"].items()),
            "", "## Every rejection reason, with counts and three example ids", ""]
    for arm in release.ARMS:
        for route in release.ROUTES:
            t = summary["reasons"][arm][route]
            out.append(f"**{arm} arm, {route}**: {t['rejected']} rejected of {t['judged']}")
            for key, entry in t["reasons"].items():
                out.append(f"- {key}: {entry['count']} (e.g. {', '.join(entry['examples'])})")
            out.append("")
    out += ["## The whole arm against the earlier typed text, same route", ""]
    for route, t in summary["whole_on_earlier_text"].items():
        out.append(f"- {route}: judged {t['judged']}, accepted {t['accepted']}, rejected {t['rejected']}: "
                   + ", ".join(f"{k} {v}" for k, v in t["reasons"].items()))
    damaged = summary.get("damaged_drafts", {})
    out += ["", "## Rules drafts that lost a content word", "",
            f"{sum(1 for k in damaged if '-g' in k)} of the group drafts and {sum(1 for k in damaged if k.endswith('-whole'))} "
            "of the whole drafts lost a content word that is not a filler, restart or correction (only words gone from "
            "the draft altogether are counted): " + ", ".join(f"{k} ({', '.join(v)})" for k, v in damaged.items()) + ". "
            "Targets built on them are flagged (`draft_lost_content_word`) and never accepted."]
    d = summary["differences"]
    out += ["", "## How the relabelled typed text differs from the earlier typed text (words, not punctuation)", "",
            f"{d['differ_in_words']} of {d['passages']} passages differ in words ({d['by_route']}). "
            "A passage counts once per class it shows:", ""]
    out += ["| class | passages | speech-first | typed-first | separate differences |", "|---|---|---|---|---|"]
    out += [f"| {name} | {count} | {d['by_class_and_route']['speech_first'][name]} | "
            f"{d['by_class_and_route']['typed_first'][name]} | {d['events'][name]} |" for name, count in d["by_class"].items()]
    return out


def render_md(sources, judged, assessments, earlier, summary, cost, judgment):
    by_assessment = {a["id"]: a for a in assessments}
    by_source = {s["id"]: s for s in sources}
    out = ["# Pilot: release route drafts, policy relabel, per-class counts", "",
           "Invented text. Groups and rules drafts come from `murmur-eval finetune groups` and first pair-check rejections from "
           "`finetune verdicts` (no model), both with the options `PipelineSettings.forDictation` gives the row's "
           "destination app: level Polished; the Claude desktop app for the agent family (spoken file names and flags "
           "written as code, protected at runtime); Slack for chat and status, Mail for email, Messages for personal, "
           "Notes for note. Pieces were relabelled under the target policy (`group-targets-v3`) from the drafts alone.",
           "", f"API spend: {cost}", ""]
    out += _table_md(summary)
    if judgment:
        out += ["", judgment.rstrip(), ""]
    out += ["", "## Passages", ""]
    for current in judged:
        source, a = by_source[current["id"]], by_assessment[current["id"]]
        out += [f"### {source['id']} · {source['route']} · {source['family']} · {source['profile']} · "
                f"{len(source['spoken'].split())} spoken words", "", "typed (relabelled):", "",
                "> " + current["typed"].replace("\n\n", "\n>\n> "), ""]
        if current["typed_earlier"] != current["typed"]:
            out += ["typed (earlier):", "", "> " + current["typed_earlier"].replace("\n\n", "\n>\n> "), ""]
        v3 = summary.get("v3_typed", {}).get(source["id"])
        if v3 and v3 != current["typed"]:
            out += ["typed (v3, typed-read labels):", "", "> " + v3.replace("\n\n", "\n>\n> "), ""]
        out += ["spoken:", "", "> " + source["spoken"], ""]
        if source["plants"]:
            out += ["planted: " + "; ".join(f"{p['kind']}: \"{p['said_first']}\" -> \"{p['ended_on']}\""
                                            for p in source["plants"]), ""]
        out += [f"whole: checks failed {a['whole']['failed_checks'] or 'none'}; release-route pair check: "
                f"{_verdict_line(a['whole']['guard'])}", ""]
        for g in a["groups"]:
            old = _earlier_group(earlier, source["id"], g["index"])
            out += [f"- group {g['index']}{' (continues sentence)' if g['continues_sentence'] else ''}"
                    f"{' · NEW PARAGRAPH' if g['new_paragraph'] else ''} · representable: {g['representable']}"
                    f"{' (' + '; '.join(g['not_representable_because']) + ')' if g['not_representable_because'] else ''}"
                    f" · checks failed: {g['failed_checks'] or 'none'}",
                    f"  - release-route pair check: {_verdict_line(g['guard'])}"]
            if old:
                legacy = old["guard"]
                out.append(f"  - earlier (clean level, legacy contract): {legacy['status']}"
                           f"{(': ' + legacy['reason']) if legacy.get('reason') else ''}")
            out += [f"  - draft: {g['draft']}", f"  - piece: {g['piece']}"]
            if old and old["piece"] != g["piece"]:
                out.append(f"  - earlier piece: {old['piece']}")
        out.append("")
    return "\n".join(out) + "\n"


def dump(summary):
    return json.dumps(summary, indent=1)


def compare_md(summary):
    """Markdown table over label versions: punctuation-and-case-only pieces, run-on measure, pair-check results."""
    out = ["| label | route | pairs | pieces that differ from the draft in punctuation and case only | "
           "sentences over 40 words (passages) | longest sentence | release-route pair check accepted / rejected (available verdicts; mixed draft basis) |",
           "|---|---|---|---|---|---|---|"]
    for name, version in summary.items():
        for route in release.ROUTES:
            row = version["shape"][route]
            guard_cell = "not run"
            if "guard" in version:
                g = version["guard"][route]
                guard_cell = f"{g['accepted']} / {g['rejected']}"
            out.append(f"| {name} | {route} | {row['pairs']} | {row['punct_case_only']} | "
                       f"{row['over_limit_sentences']} ({row['passages_with_over_limit']}) | {row['longest_sentence']} | "
                       f"{guard_cell} |")
    return "\n".join(out)


def judge_md(summaries):
    out = ["| comparison | pairs | wins | ties | inconsistent | judge reasons that mention |", "|---|---|---|---|---|---|"]
    for item in summaries:
        wins = ", ".join(f"{k} {v}" for k, v in item["wins"].items())
        themes = "; ".join(f"{k} {v}" for k, v in item["clusters"].items() if v)
        out.append(f"| {item['pair']} | {item['pairs']} | {wins} | {item['ties']} | {item['inconsistent']} | "
                   f"{themes} (of {item['reasons']} reasons) |")
    return "\n".join(out)
