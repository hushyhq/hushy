#!/usr/bin/env bash
# inner.sh <set> <variant>...  (run inside one mac-heavy slot) -> out/<variant>/<set>.jsonl
# Study: docs/research/professional-instructions-2026-10-28.md. PRO_WORK holds cases/<set>.jsonl and receives out/.
set -uo pipefail
H="${PRO_WORK:?set PRO_WORK to the work folder (cases/, variants/, out/)}"
WT="$(cd "$(dirname "$0")/../.." && pwd)"
MAIN="$(dirname "$(cd "$WT" && cd "$(git rev-parse --git-common-dir)" && pwd)")"
ID=hushy-cleanup-4b-r10d-6bit
SET="$1"; shift
mkdir -p "$H/warm"
python3 -I - "$H/cases/$SET.jsonl" "$H/warm/$SET.jsonl" <<'PY'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
seen={};warm=[]
for r in rows:
    k=(r.get('bundle'),r.get('app_tone'))
    if k in seen: continue
    seen[k]=1
    for n in range(2):
        w=dict(r); w['id']=f"warm-{len(warm)}"; warm.append(w)
open(sys.argv[2],'w').write("".join(json.dumps(r)+"\n" for r in warm+rows))
PY
for V in "$@"; do
  [ -s "$H/out/$V/$SET.jsonl" ] && continue
  mkdir -p "$H/out/$V"
  HOME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pro-instr.XXXXXX")"
  OVR=(); [ "$V" = native ] || OVR=(HUSHY_EVAL_REGISTER_LINES="$(cd "$(dirname "$0")" && pwd)/variants/$V.json")
  echo "$(date +%T) start $V $SET"
  env HUSHY_HOME="$HOME_DIR" MURMUR_HOME="$HOME_DIR" "${OVR[@]+"${OVR[@]}"}" "$WT/.build/release/murmur-eval" intent-app \
    --cases "$H/warm/$SET.jsonl" --mlx-model "$MAIN/.build/hosted-models/$ID" --local-model "$ID" \
    --out "$H/out/$V/$SET.jsonl.tmp" --level polished --strategy model --repairs-spans --trace-steps >"$H/out/$V/$SET.log" 2>&1 \
    && mv "$H/out/$V/$SET.jsonl.tmp" "$H/out/$V/$SET.jsonl" && echo "$(date +%T) done $V" || echo "$(date +%T) FAILED $V"
  rm -rf -- "$HOME_DIR"
done
