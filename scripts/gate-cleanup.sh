#!/usr/bin/env bash
# Cleanup gate: compares the cleanup path of a base commit with the working tree, per model and
# per eval set, and lists every text that changed. Replaces hand-written scratch scripts.
#
# Usage: scripts/gate-cleanup.sh [--base <git-ref>] [--models intent,v54]
#          [--sets pub,golden,never,probe,misheard,long,vocab] [--out <dir>] [--fail-on-regression]
#   --base      git ref of the base (default origin/main); the working tree is the candidate
#   --models    intent = hushy-cleanup-2b-r5d2blr2-4bit, v54 = hushy-cleanup-2b-v5.4-4bit (default both)
#   --sets      pub = Evals/runs/retrain/public-inputs/handy-eval300.jsonl (public 300), golden =
#               Evals/dictation-golden.json, never = Evals/never-answer-dev.jsonl, misheard =
#               Evals/misheard-probe.jsonl, probe = Evals/number-guard-probe.jsonl, long = long+live dev
#               dictations, vocab = invented `say` speech through the real recogniser, CTC vocabulary boost and
#               BoostGuard with a fixed fixture vocabulary (Evals/vocab-*.jsonl; record-only, see below)
#               (default all). intent-app sets run for the intent model only; v54 gets
#               long (the intent-app runner accepts intent models only). vocab needs no cleanup model.
#   --out       report folder (default .gate-logs/cleanup-<UTC time> in the working tree)
#   --fail-on-regression  exit 1 if public exact drops, a set's used-model count drops, a long
#               dictation goes from cleaned to raw, a pipeline step's made-worse count rises versus
#               the base, or a run failed. Without it the exit is 0. The vocab numbers never fail the gate yet.
#
# Made-worse: each intent-app row with --trace-steps records recogniser, boosted, fixers, model and
# checks text; scripts/gate_cleanup_made_worse.py scores step transitions against the set reference
# (public scorer normalisation). The gate fails when any step's made-worse total rises on the candidate.
#
# Vocab block (record only): `murmur-eval vocab-real-boost` speaks the vocab-harm rows (ordinary sentences full of
# collision words) and vocab-win rows (names and terms) through Parakeet, then the real boost with the fixture
# vocabulary, then BoostGuard. The report prints words made worse at the boost step and after the guard, and
# expected-spelling recall before and after, base versus candidate. A base that predates the command shows
# candidate numbers only. The audio is made by scripts/vocab-eval-audio.sh (git-ignored Evals/runs/).
#
# Writes <out>/changed.md (every changed text, side by side), summary.json, and the raw outputs.
# Builds murmur-eval (release) for the base in a temporary worktree it removes afterwards, and for
# the working tree. mlx.metallib is copied from the main checkout. Models run one at a time, each
# build and run through scripts/mac-heavy.sh (set HUSHY_GATE_NO_QUEUE=1 if the caller already
# holds the heavy-job lock), under caffeinate -i. Uses a temp HUSHY_HOME; never reads the app's
# data folder, sealed sets, Keychain or key files.

set -euo pipefail

BASE_REF="origin/main"
MODELS="intent,v54"
SETS="pub,golden,never,probe,misheard,long,vocab"
OUT=""
FAIL_ON_REGRESSION=0

usage() { sed -n '2,32p' "$0"; }
die() { echo "gate-cleanup: $*" >&2; exit 2; }

ORIGINAL_ARGS=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE_REF="${2:?--base needs a git ref}"; shift ;;
    --models) MODELS="${2:?--models needs a list}"; shift ;;
    --sets) SETS="${2:?--sets needs a list}"; shift ;;
    --out) OUT="${2:?--out needs a folder}"; shift ;;
    --fail-on-regression) FAIL_ON_REGRESSION=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

# Keep the Mac awake for the whole run (re-executes itself once under caffeinate).
if [ -z "${HUSHY_GATE_AWAKE:-}" ]; then
  export HUSHY_GATE_AWAKE=1
  exec caffeinate -i "$0" "${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"}"
fi

# ---------------------------------------------------------------- inputs and checks
for item in $(echo "$MODELS" | tr ',' ' '); do
  case "$item" in intent|v54) ;; *) die "unknown model: $item (intent|v54)" ;; esac
done
for item in $(echo "$SETS" | tr ',' ' '); do
  case "$item" in pub|golden|never|probe|misheard|long|vocab) ;; *) die "unknown set: $item" ;; esac
done

CAND="$(git rev-parse --show-toplevel)" || die "run inside the repository"
COMMON="$(cd "$CAND" && cd "$(git rev-parse --git-common-dir)" && pwd)"
[ "$(basename "$COMMON")" = ".git" ] || die "cannot find the main checkout from $COMMON"
MAIN="$(dirname "$COMMON")"
BASE_SHA="$(git -C "$CAND" rev-parse --verify "${BASE_REF}^{commit}")" || die "unknown base ref: $BASE_REF"
CAND_SHA="$(git -C "$CAND" rev-parse --short HEAD)"
if [ -n "$(git -C "$CAND" status --porcelain --untracked-files=no)" ]; then CAND_LABEL="$CAND_SHA+working-tree"; else CAND_LABEL="$CAND_SHA"; fi
BASE_LABEL="$BASE_REF@$(echo "$BASE_SHA" | cut -c1-8)"

has_set() { case ",$SETS," in *",$1,"*) return 0 ;; esac; return 1; }
has_model() { case ",$MODELS," in *",$1,"*) return 0 ;; esac; return 1; }

INTENT_ID="hushy-cleanup-2b-r5d2blr2-4bit"
V54_ID="hushy-cleanup-2b-v5.4-4bit"
model_id() { case "$1" in intent) echo "$INTENT_ID" ;; v54) echo "$V54_ID" ;; esac; }
model_dir() { echo "$MAIN/.build/hosted-models/$(model_id "$1")"; }

PUB_IN="$CAND/Evals/runs/retrain/public-inputs/handy-eval300.jsonl"
[ -f "$PUB_IN" ] || PUB_IN="$MAIN/Evals/runs/retrain/public-inputs/handy-eval300.jsonl"
GOLDEN_IN="$CAND/Evals/dictation-golden.json"
NEVER_IN="$CAND/Evals/never-answer-dev.jsonl"
MISHEARD_IN="$CAND/Evals/misheard-probe.jsonl"
PROBE_IN="$CAND/Evals/number-guard-probe.jsonl"
LONG_IN="$CAND/Evals/long-dictation-dev.jsonl"
LIVE_IN="$CAND/Evals/live-dictation-dev.jsonl"
VOCAB_HARM_IN="$CAND/Evals/vocab-harm.jsonl"
VOCAB_WIN_IN="$CAND/Evals/vocab-win.jsonl"
VOCAB_FIXTURE_IN="$CAND/Evals/vocab-real-boost-fixture.json"
VOCAB_AUDIO="$CAND/Evals/runs/vocab-real-boost/audio"

# Sealed sets are never read. The Python guard checks names and hashes; the name check below also
# covers the families the guard does not (see .claude/AGENTS.md, "Sealed by name").
refuse_sealed_name() {
  local lower
  lower="$(basename "$1" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    heldout-v2*|actions-heldout*|meeting-heldout*|voicelab-*|ab-*|eval-long64-b*|longb*)
      die "refusing sealed set by name: $1" ;;
  esac
}
CHECKED_INPUTS=()
check_input() {
  [ -f "$1" ] || die "missing input: $1"
  refuse_sealed_name "$1"
  CHECKED_INPUTS+=("$1")
}
if has_set pub; then check_input "$PUB_IN"; fi
if has_set golden; then check_input "$GOLDEN_IN"; fi
if has_set never; then check_input "$NEVER_IN"; fi
if has_set misheard; then check_input "$MISHEARD_IN"; fi
if has_set probe; then check_input "$PROBE_IN"; fi
if has_set long; then check_input "$LONG_IN"; check_input "$LIVE_IN"; fi
if has_set vocab; then check_input "$VOCAB_HARM_IN"; check_input "$VOCAB_WIN_IN"; check_input "$VOCAB_FIXTURE_IN"; fi
python3 -I "$CAND/scripts/sealed_guard.py" "${CHECKED_INPUTS[@]}" || die "sealed_guard refused an input"

for item in $(echo "$MODELS" | tr ',' ' '); do
  [ -d "$(model_dir "$item")" ] || die "model weights not found: $(model_dir "$item")"
done
[ -f "$MAIN/.build/release/mlx.metallib" ] || die "missing $MAIN/.build/release/mlx.metallib (run scripts/build-mlx-metallib.sh release in the main checkout)"

if [ -z "$OUT" ]; then OUT="$CAND/.gate-logs/cleanup-$(date -u +%Y%m%dT%H%M%SZ)"; fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
# A reused report folder must not keep the outputs of an earlier run.
rm -rf -- "${OUT:?}/base" "${OUT:?}/cand"
mkdir -p "$OUT/base" "$OUT/cand"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/gate-cleanup.XXXXXX")"
BASE_TREE="$TMP/base"
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME"
CLEANED=0
cleanup() {
  [ "$CLEANED" = 1 ] && return 0
  CLEANED=1
  if [ -d "$BASE_TREE" ]; then
    git -C "$CAND" worktree remove --force "$BASE_TREE" >/dev/null 2>&1 || true
    git -C "$CAND" worktree prune >/dev/null 2>&1 || true
  fi
  case "$TMP" in
    */gate-cleanup.*) rm -rf -- "$TMP" ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

: >"$OUT/notes.txt"
note() { echo "$1" >>"$OUT/notes.txt"; echo "gate-cleanup: note: $1" >&2; }
log() { echo "gate-cleanup: $*" >&2; }

# ---------------------------------------------------------------- builds
run_heavy() {
  local label="$1"; shift
  if [ "${HUSHY_GATE_NO_QUEUE:-}" = 1 ] || [ ! -x "$CAND/scripts/mac-heavy.sh" ]; then
    "$@"
  else
    "$CAND/scripts/mac-heavy.sh" "$label" "$@"
  fi
}

seed_build() {
  local tree="$1"
  if [ ! -d "$tree/.build" ] && [ "$tree" != "$MAIN" ] && [ -d "$MAIN/.build" ]; then
    log "seeding $tree/.build from the main checkout (APFS clone, no extra disk until it changes)"
    if ! cp -c -R "$MAIN/.build" "$tree/.build" 2>/dev/null; then
      log "clone failed; building cold"
      rm -rf -- "${tree:?}/.build"
    else
      # Compiled module caches remember the folder they were built in; drop them so they are rebuilt here.
      find "$tree/.build" -maxdepth 3 -name ModuleCache -type d -prune -exec rm -rf -- {} +
    fi
  fi
}

build_tree() {
  local tree="$1" arm="$2"
  seed_build "$tree"
  log "building murmur-eval (release) for $arm"
  run_heavy "gate-build-$arm" bash -c 'cd "$1" && swift build -j 4 -c release --product murmur-eval' _ "$tree" \
    >"$OUT/$arm/build.log" 2>&1 || { tail -n 25 "$OUT/$arm/build.log" >&2; die "build failed for $arm (log: $OUT/$arm/build.log)"; }
  # Run from the main checkout, the candidate tree is the main checkout itself: the library is already there.
  [ "$MAIN/.build/release/mlx.metallib" -ef "$tree/.build/release/mlx.metallib" ] \
    || cp -f "$MAIN/.build/release/mlx.metallib" "$tree/.build/release/mlx.metallib"
  [ -x "$tree/.build/release/murmur-eval" ] || die "no murmur-eval binary for $arm"
}

log "base $BASE_LABEL, candidate $CAND_LABEL, models $MODELS, sets $SETS"
log "output: $OUT"
git -C "$CAND" worktree add --detach "$BASE_TREE" "$BASE_SHA" >"$OUT/base/worktree.log" 2>&1 || die "cannot create the base worktree"
if ! cmp -s "$BASE_TREE/Package.resolved" "$CAND/Package.resolved"; then
  note "Package.resolved differs between base and candidate; the copied mlx.metallib comes from the main checkout"
fi
build_tree "$BASE_TREE" base
build_tree "$CAND" cand

# ---------------------------------------------------------------- runs
run_one() {  # run_one <arm> <tree> <tag> <name> <command...> ; records <arm>/<tag>-<name>.status
  local arm="$1" tree="$2" tag="$3" name="$4"; shift 4
  local status=0
  log "[$arm] $tag $name"
  ( cd "$tree" && run_heavy "gate-$arm-$tag-$name" env HUSHY_HOME="$FAKE_HOME" MURMUR_HOME="$FAKE_HOME" "$@" ) \
    >"$OUT/$arm/$tag-$name.log" 2>&1 || status=$?
  echo "$status" >"$OUT/$arm/$tag-$name.status"
  if [ "$status" != 0 ]; then log "[$arm] $tag $name FAILED (exit $status); see $OUT/$arm/$tag-$name.log"; fi
}

intent_app() {  # intent_app <arm> <tree> <name> <cases file>
  local arm="$1" tree="$2" name="$3" cases="$4"
  run_one "$arm" "$tree" intent "$name" "$tree/.build/release/murmur-eval" intent-app --cases "$cases" \
    --mlx-model "$(model_dir intent)" --local-model "$INTENT_ID" --out "$OUT/$arm/intent-$name.jsonl" \
    --level polished --strategy model --trace-steps
}

early_clean() {  # early_clean <arm> <tree> <model key>
  local arm="$1" tree="$2" key="$3"
  mkdir -p "$OUT/$arm/$key-long"
  run_one "$arm" "$tree" "$key" long "$tree/.build/release/murmur-eval" early-clean --out "$OUT/$arm/$key-long" \
    --sets long,live --long "$LONG_IN" --live "$LIVE_IN" --mlx-model "$(model_dir "$key")" \
    --local-model "$(model_id "$key")" --arms early:prefix:1 --label "$key"
}

vocab_boost() {  # vocab_boost <arm> <tree>: needs no cleanup model; the data and audio are the candidate's for both arms
  local arm="$1" tree="$2"
  run_one "$arm" "$tree" vocab boost "$tree/.build/release/murmur-eval" vocab-real-boost --backend none \
    --harm "$VOCAB_HARM_IN" --win "$VOCAB_WIN_IN" --fixture "$VOCAB_FIXTURE_IN" --audio "$VOCAB_AUDIO" \
    --report "$OUT/$arm/vocab-summary.json" --rows-out "$OUT/$arm/vocab-rows.jsonl"
}

for key in $(echo "$MODELS" | tr ',' ' '); do
  if [ "$key" = intent ]; then
    for name in pub golden never probe misheard; do
      has_set "$name" || continue
      case "$name" in
        pub) file="$PUB_IN" ;; golden) file="$GOLDEN_IN" ;; never) file="$NEVER_IN" ;;
        probe) file="$PROBE_IN" ;; misheard) file="$MISHEARD_IN" ;;
      esac
      intent_app base "$BASE_TREE" "$name" "$file"
      intent_app cand "$CAND" "$name" "$file"
    done
  else
    note "$key: the intent-app sets (pub, golden, never, probe, misheard) are skipped; intent-app accepts intent models only"
  fi
  if has_set long; then
    early_clean base "$BASE_TREE" "$key"
    early_clean cand "$CAND" "$key"
  fi
done

if has_set vocab; then
  log "making the vocab-boost speech (scripts/vocab-eval-audio.sh)"
  "$CAND/scripts/vocab-eval-audio.sh" --out "$VOCAB_AUDIO" >"$OUT/vocab-audio.log" 2>&1 \
    || note "vocab: could not make the speech (see $OUT/vocab-audio.log); the vocab block is skipped"
  if [ -s "$VOCAB_AUDIO/voices.tsv" ]; then
    vocab_boost base "$BASE_TREE"
    vocab_boost cand "$CAND"
  fi
fi

# ---------------------------------------------------------------- report
REPORT_STATUS=0
REPORT_FLAGS=()
if [ "$FAIL_ON_REGRESSION" = 1 ]; then REPORT_FLAGS=(--fail-on-regression); fi
python3 -I "$CAND/scripts/gate_cleanup_report.py" --out "$OUT" --base-label "$BASE_LABEL" --cand-label "$CAND_LABEL" \
  --models "$MODELS" --sets "$SETS" --pub-refs "$PUB_IN" --golden "$GOLDEN_IN" --misheard "$MISHEARD_IN" \
  --never "$NEVER_IN" --probe "$PROBE_IN" --long "$LONG_IN" --live "$LIVE_IN" \
  "${REPORT_FLAGS[@]+"${REPORT_FLAGS[@]}"}" || REPORT_STATUS=$?

cleanup
if [ "$FAIL_ON_REGRESSION" = 1 ] && [ "$REPORT_STATUS" != 0 ]; then exit 1; fi
exit 0
