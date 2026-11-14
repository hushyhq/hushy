#!/usr/bin/env python3
"""Mine long single-speaker stretches from the AMI and ICSI meeting transcripts (CC BY 4.0).

The corpora are untrusted data. Unpack each archive into its own empty folder first, keep this script
outside those folders, and run it with `python3 -I` so nothing is imported from the data folders:

    python3 -I scripts/retrain_mine.py mine --ami-dir .../ami/extracted \\
        --icsi-dir .../icsi/original_extracted/transcripts --out-dir .../Evals/runs/retrain
    python3 -I scripts/retrain_mine.py select --passages .../passages.jsonl --out .../writer-input.jsonl \\
        --monologue --exclude-pii person_name phone email address health money_personal --mask-names
    python3 -I scripts/retrain_mine.py stats --passages .../passages.jsonl

`mine` writes passages.jsonl (every passage, with timing, flags, features and, for AMI, the disfluency
layer's marks), lexicons.json (the corpus-derived proper-noun and first-name lists), stats.json,
sample20.jsonl and sample20.txt into --out-dir. Attribution owed: the AMI Meeting Corpus and the ICSI
Meeting Corpus are CC BY 4.0.
"""

import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

import retrain_corpora as corpora  # noqa: E402
import retrain_features as features  # noqa: E402
import retrain_passages as passage_module  # noqa: E402
import retrain_stats as stats_module  # noqa: E402
from api_judge_guard import GuardError, refuse_forbidden_name  # noqa: E402

DEFAULT_SEED = 20261008
SAMPLE_COUNT = 20


def checked(path, must_exist=True):
    refuse_forbidden_name(path)
    resolved = Path(path).expanduser().resolve()
    if must_exist and not resolved.exists():
        raise GuardError(f"{path} does not exist")
    refuse_forbidden_name(resolved)
    return resolved


def write_lines(path, rows):
    path.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")


def read_lines(path):
    return [json.loads(line) for line in Path(path).read_text(encoding="utf-8").splitlines() if line.strip()]


def mine(args):
    ami_dir = checked(args.ami_dir) if args.ami_dir else None
    icsi_dir = checked(args.icsi_dir) if args.icsi_dir else None
    out_dir = checked(args.out_dir, must_exist=False)
    keep = not args.no_dashes
    corpus_path_stats = {}
    meetings = (corpora.load_ami(ami_dir, keep, stats=corpus_path_stats) if ami_dir else []) + \
               (corpora.load_icsi(icsi_dir, keep, stats=corpus_path_stats) if icsi_dir else [])
    if not meetings:
        raise GuardError("give --ami-dir and/or --icsi-dir")
    token_lists = [[t.text for t in unit.tokens] for m in meetings for units in m.speakers.values() for unit in units]
    proper, names = features.derive_lexicons(token_lists)
    rejected = {}
    rows = [row for meeting in meetings
            for row in passage_module.mine_meeting(meeting, (proper, names), rejected)]
    rows.sort(key=lambda r: (r["corpus"], r["meeting"], r["start"], r["speaker"]))
    out_dir.mkdir(parents=True, exist_ok=True)
    write_lines(out_dir / "passages.jsonl", rows)
    (out_dir / "lexicons.json").write_text(json.dumps(
        {"note": "derived from capitalisation statistics; names is a lower bound",
         "proper_nouns": sorted(proper), "first_names": sorted(names)}, indent=1), encoding="utf-8")
    result = stats_module.build_stats(rows)
    result["unsafe_corpus_paths"] = corpus_path_stats.get("unsafe_corpus_paths", 0)
    result["rejected_as_cross_talk"] = rejected.get("cross_talk", 0)
    result["trimming"] = {"words_trimmed_from_chains_of_100_plus": rejected.get("trimmed_words", 0),
                          "chains_dropped_below_floor_after_trim": rejected.get("below_floor_after_trim", 0)}
    result["meetings_read"] = {c: sum(1 for m in meetings if m.corpus == c) for c in ("AMI", "ICSI")}
    (out_dir / "stats.json").write_text(json.dumps(result, indent=1), encoding="utf-8")
    sample = stats_module.sample_varied(rows, SAMPLE_COUNT, args.seed)
    write_lines(out_dir / "sample20.jsonl", sample)
    (out_dir / "sample20.txt").write_text(stats_module.render_sample(sample), encoding="utf-8")
    print(f"retrain-mine: {len(rows)} passages from {len(meetings)} meetings; wrote {out_dir}")
    print_summary(result)


def print_summary(result):
    for name, group in result["by_corpus_and_length"].items():
        print(f"  {name:14s} passages {group['passages']:5d}  meetings {group['meetings']:3d}  "
              f"speakers {group['speakers']:3d}  fillers/100 {group['filler_per100_pooled']:5.2f}  "
              f"selfcorr {group['pct_with_explicit_self_correction']:5.1f}%  numbers {group['pct_with_number']:5.1f}%  "
              f"dates {group['pct_with_date']:5.1f}%  names {group['pct_with_proper_noun']:5.1f}%")
    print(f"  AMI disfluency layer: {result['ami_layer']}")
    print(f"  monologue proposal passes: {result['monologue_proposal']['passes']}")


def select(args):
    passages_path = checked(args.passages)
    out = checked(args.out, must_exist=False)
    rows = read_lines(passages_path)
    chosen = stats_module.select(rows, corpus=args.corpus, monologue=args.monologue,
                                 exclude_pii=args.exclude_pii, allow_flags=args.allow_flags,
                                 min_score=args.min_score)
    before_caps = chosen
    chosen = stats_module.apply_caps(chosen, args.max_per_meeting, args.max_per_speaker, args.seed)
    summary = stats_module.cap_summary(before_caps, chosen)
    names = set(json.loads((passages_path.parent / "lexicons.json").read_text(encoding="utf-8"))["first_names"]) \
        if args.mask_names else set()
    output = []
    for row in chosen:
        text = features.mask_names(row["text"], names, row["id"]) if names else row["text"]
        item = {"id": row["id"], "spoken": text, "corpus": row["corpus"], "meeting": row["meeting"],
                "speaker": row["speaker"], "words": row["words"], "names_masked": bool(names),
                "attribution": "AMI Meeting Corpus / ICSI Meeting Corpus, CC BY 4.0"}
        if "ami_layer" in row:
            item["ami_layer"] = row["ami_layer"]
        output.append(item)
    if args.sample:
        keep = {r["id"] for r in stats_module.sample_varied(chosen, args.sample, args.seed)}
        output = [item for item in output if item["id"] in keep]
    if args.limit:
        output = output[:args.limit]
    out.parent.mkdir(parents=True, exist_ok=True)
    write_lines(out, output)
    summary["written"] = {"passages": len(output), "caps": {"per_meeting": args.max_per_meeting,
                                                              "per_speaker": args.max_per_speaker}}
    summary_path = checked(f"{out}.summary.json", must_exist=False)
    summary_path.write_text(json.dumps(summary, indent=1), encoding="utf-8")
    print(f"retrain-mine: selected {len(output)} of {len(rows)} passages into {out} "
          f"({summary['before_caps']['passages']} passed the filters, {summary['after_caps']['passages']} "
          f"under the caps of {args.max_per_meeting} per meeting and {args.max_per_speaker} per speaker)")


def show_stats(args):
    rows = read_lines(checked(args.passages))
    result = stats_module.build_stats(rows)
    print(json.dumps(result, indent=1) if args.json else "", end="")
    if not args.json:
        print_summary(result)


def parser():
    cli = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = cli.add_subparsers(dest="command", required=True)
    mine_parser = commands.add_parser("mine", help="read the corpora and write every passage")
    mine_parser.add_argument("--ami-dir", help="unpacked ami_public_manual folder")
    mine_parser.add_argument("--icsi-dir", help="folder holding the ICSI *.mrt transcripts")
    mine_parser.add_argument("--out-dir", required=True)
    mine_parser.add_argument("--seed", type=int, default=DEFAULT_SEED, help="picks the 20-passage sample")
    mine_parser.add_argument("--no-dashes", action="store_true",
                             help="drop the interrupted-utterance dash marks instead of keeping them as '-'")
    select_parser = commands.add_parser("select", help="filter passages into a writer input file")
    select_parser.add_argument("--passages", required=True)
    select_parser.add_argument("--out", required=True)
    select_parser.add_argument("--corpus", choices=("AMI", "ICSI"))
    select_parser.add_argument("--monologue", action="store_true", help="apply the monologue proposal")
    select_parser.add_argument("--min-score", type=float, help="override the proposal's minimum score")
    select_parser.add_argument("--exclude-pii", nargs="*", default=[], choices=stats_module.PII_KINDS)
    select_parser.add_argument("--mask-names", action="store_true",
                               help="replace first-name-like words with invented names")
    select_parser.add_argument("--allow-flags", action="store_true",
                               help="keep passages with gaps, undecipherable or censored stretches")
    select_parser.add_argument("--max-per-meeting", type=int, default=stats_module.DEFAULT_MAX_PER_MEETING,
                               help="cap per meeting after the filters, 0 for none (default %(default)s)")
    select_parser.add_argument("--max-per-speaker", type=int, default=stats_module.DEFAULT_MAX_PER_SPEAKER,
                               help="cap per speaker after the filters, 0 for none (default %(default)s)")
    select_parser.add_argument("--sample", type=int, metavar="N",
                               help="keep N passages spread over corpus and length, picked by --seed")
    select_parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    select_parser.add_argument("--limit", type=int, help="keep only the first N (after --sample)")
    stats_parser = commands.add_parser("stats", help="print the statistics of a passages file")
    stats_parser.add_argument("--passages", required=True)
    stats_parser.add_argument("--json", action="store_true")
    return cli


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        {"mine": mine, "select": select, "stats": show_stats}[args.command](args)
    except (GuardError, OSError, ValueError) as exc:
        print(f"retrain-mine: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
