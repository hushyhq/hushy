#!/usr/bin/env bash
# Gate 6 (docs/product/DIRECTION.md §2): the safety gate.
#
# Runs the adversarial set (rules and hybrid) and the over-deletion set (hybrid) through the
# release build of murmur-eval and holds ONE subset to a 100% floor: the literal/negated-command
# cases, marked `"gate": "literal-command"` in Evals/adversarial-golden.json (literal "press
# enter", "new line", "scratch that", "new paragraph", "hit return" used as content, and "no"/
# "not"/"don't" that must not be read as a correction cue). For those cases a violation is any
# of: an unintended Return (pressEnter when none was expected), a fired line break (more lines
# in the output than expected), or a dropped word (any expected word missing from the output).
# Everything else — the rest of the adversarial set and all of over-deletion — is report-only.
#
# Exit status: 0 = floor intact; 1 = floor violated; 2 = the harness could not produce a report.
# Report-only stages never change the exit status. Results are appended to Evals/results.md
# (append-only) with the machine load (`uptime`) noted, because the hybrid strategy calls the
# on-device model with a time budget and a busy machine can turn model calls into timeouts.
#
# Usage: scripts/safety-gate.sh [--skip-build] [--run-dir DIR]
set -uo pipefail
cd "$(dirname "$0")/.."

SKIP_BUILD=0
RUN_DIR=""
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    --run-dir) : ;;
    *) if [ -z "$RUN_DIR" ] && [ "${prev:-}" = --run-dir ]; then RUN_DIR="$arg"; else echo "Usage: scripts/safety-gate.sh [--skip-build] [--run-dir DIR]" >&2; exit 2; fi ;;
  esac
  prev="$arg"
done

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${RUN_DIR:-Evals/runs/safety-gate-$STAMP}"
mkdir -p "$RUN_DIR"
EVAL=.build/release/murmur-eval

if [ "$SKIP_BUILD" = 0 ]; then
  echo "==> swift build -c release --product murmur-eval"
  swift build -c release --product murmur-eval >"$RUN_DIR/build.log" 2>&1 || { echo "release build failed, see $RUN_DIR/build.log" >&2; exit 2; }
fi
[ -x "$EVAL" ] || { echo "missing $EVAL (run without --skip-build)" >&2; exit 2; }

LOAD="$(uptime)"
REV="$(git rev-parse --short HEAD)"
{
  echo "revision: $(git rev-parse HEAD)"
  echo "dirty: $(git status --short | wc -l | tr -d ' ') path(s)"
  echo "uptime: $LOAD"
  sw_vers
} > "$RUN_DIR/environment.txt"
echo "==> $LOAD"

stage() {
  local label="$1"; shift
  printf '\n==> %s\n' "$label"
  if "$EVAL" "$@" --report "$RUN_DIR/$label.json" 2>&1 | tee "$RUN_DIR/$label.log"; then
    printf '%s\tran\n' "$label" >> "$RUN_DIR/status.tsv"
  else
    printf '%s\tharness error\n' "$label" >> "$RUN_DIR/status.tsv"
  fi
}

# All three stages are report-only at the murmur-eval level (no --min-pass); the floor is
# evaluated below from the JSON reports so the gate's definition lives in one place.
stage adversarial-rules  cleanup --strategy rules  --golden Evals/adversarial-golden.json
stage adversarial-hybrid cleanup --strategy hybrid --golden Evals/adversarial-golden.json
stage overdeletion-hybrid cleanup --strategy hybrid --golden Evals/overdeletion-golden.json

printf '\n==> floor check (literal/negated-command subset, 100%%)\n'
python3 - "$RUN_DIR" "$STAMP" "$REV" "$LOAD" <<'PY' | tee "$RUN_DIR/floor.md"
import json, re, sys, collections
run_dir, stamp, rev, load = sys.argv[1:5]

def words(text):
    # Mirrors EvalMetrics.normalizedWords closely enough for a "was a word dropped" check:
    # lowercase, apostrophes kept, punctuation removed, small number words -> digits.
    numbers = {"zero":"0","one":"1","two":"2","three":"3","four":"4","five":"5","six":"6","seven":"7",
               "eight":"8","nine":"9","ten":"10","eleven":"11","twelve":"12","fifteen":"15","twenty":"20",
               "thirty":"30","sixty":"60","hundred":"100","okay":"ok","o.k":"ok"}
    out = []
    for token in re.split(r"[^0-9A-Za-z']+", text.lower().replace("’", "'")):
        token = token.strip("'")
        if token:
            out.append(numbers.get(token, token))
    return out

def violations(case):
    problems = []
    if case["pressEnter"] and not case["expectedPressEnter"]:
        problems.append("unintended Return")
    if case["actual"].count("\n") > case["expected"].count("\n"):
        problems.append("fired a line break")
    missing = collections.Counter(words(case["expected"])) - collections.Counter(words(case["actual"]))
    if missing:
        problems.append("dropped: " + " ".join(sorted(missing.elements())))
    return problems

reports = {}
for label in ("adversarial-rules", "adversarial-hybrid", "overdeletion-hybrid"):
    try:
        with open(f"{run_dir}/{label}.json") as f:
            reports[label] = json.load(f)
    except FileNotFoundError:
        reports[label] = None

total_violations = 0
lines = [f"### Safety gate (gate 6) · {stamp} · {rev}", f"- Load at run time: `{load.strip()}`"]
for label in ("adversarial-rules", "adversarial-hybrid"):
    report = reports[label]
    if report is None:
        lines.append(f"- {label}: **no report produced (harness error)**")
        total_violations += 1_000_000
        continue
    subset = [c for c in report["cases"] if c.get("gate") == "literal-command"]
    bad = [(c["id"], violations(c)) for c in subset]
    bad = [(cid, v) for cid, v in bad if v]
    total_violations += len(bad)
    rest = [c for c in report["cases"] if c.get("gate") != "literal-command"]
    rest_pass = sum(1 for c in rest if c["passed"])
    subset_pass = sum(1 for c in subset if c["passed"])
    timeouts = sum(1 for c in report["cases"] if c.get("rejection"))
    lines.append(f"- {label}: floor subset {len(subset) - len(bad)}/{len(subset)} intact "
                 f"({'**FLOOR VIOLATED**' if bad else 'PASS'}; exact-pass {subset_pass}/{len(subset)}) · "
                 f"rest report-only {rest_pass}/{len(rest)} pass · model rejected/timed out {timeouts}")
    for cid, v in bad:
        lines.append(f"  - ✘ {cid}: {'; '.join(v)}")
    for c in subset:
        print(f"  {'✘' if violations(c) else '✔'} {label:19s} {c['id']:20s} {'; '.join(violations(c)) or 'ok'}", file=sys.stderr)

report = reports["overdeletion-hybrid"]
if report is None:
    lines.append("- overdeletion-hybrid: **no report produced (harness error)**")
    total_violations += 1_000_000
else:
    passed = sum(1 for c in report["cases"] if c["passed"])
    timeouts = sum(1 for c in report["cases"] if c.get("rejection"))
    lines.append(f"- overdeletion-hybrid (report-only): {passed}/{len(report['cases'])} pass · model rejected/timed out {timeouts}")

if total_violations >= 1_000_000:
    lines.append("- Result: **HARNESS ERROR** — a stage produced no report; nothing measured")
    code = 2
elif total_violations:
    lines.append(f"- Result: **FAIL** — {total_violations} floor violation(s) on the literal/negated-command subset")
    code = 1
else:
    lines.append("- Result: **PASS** — zero unintended Return/deletion on the literal/negated-command subset")
    code = 0
print("\n".join(lines))
sys.exit(code)
PY
CODE=${PIPESTATUS[0]}

{ printf '\n<!-- %s safety-gate -->\n' "$STAMP"; cat "$RUN_DIR/floor.md"; } >> Evals/results.md
printf '\nEvidence: %s (exit %s)\n' "$RUN_DIR" "$CODE"
exit "$CODE"
