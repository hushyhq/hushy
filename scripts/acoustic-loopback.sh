#!/usr/bin/env bash
# Acoustic loopback kit, path (c) of `murmur-eval voice-trace` — FOUNDER-RUN ONLY.
#
# Plays clips with transcripts through the Mac speakers while the founder dictates through
# the LIVE Hushy app's real mic path into a scratch doc. Agents must NEVER run this (the
# one-Hushy rule: only the founder's live app may capture audio).
#
# Usage:
#   scripts/acoustic-loopback.sh [--local-dir path | --dataset edacc-indian] [--limit 10] [--gap 10]
#
#   --local-dir  founder pairs folder (transcripts.json + audio; see Evals/README.md)
#   --dataset    web corpus already cached under Evals/data (default: edacc-indian)
#   --limit      clips to play (default 10)
#   --gap        seconds of silence after each clip for the fn-hold + paste (default 10)
#
# Procedure for the founder:
#   1. Open a scratch doc (TextEdit, plain text). The live Hushy app must be running.
#   2. Run this script. For each clip it prints the clip id, plays it through the speakers,
#      then waits --gap seconds.
#   3. Hold fn DURING each playback (release when the clip ends), so Hushy hears room audio
#      exactly as a conversation partner would sound. One pasted line per clip, IN ORDER.
#      If a clip is missed, leave a BLANK line — never delete a line (alignment is positional).
#   4. Save the scratch doc as loopback-results.txt and score it:
#        .build/release/murmur-eval voice-trace score-lines --lines loopback-results.txt \
#            [--local-dir path | --dataset <same selection>] [--limit <same N>]
#      Send the printed summary (or the --report JSON) back. Nothing leaves the Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

LOCAL_DIR=""; DATASET="edacc-indian"; LIMIT=10; GAP=10
while [ $# -gt 0 ]; do
  case "$1" in
    --local-dir) LOCAL_DIR="$2"; shift 2;;
    --dataset) DATASET="$2"; shift 2;;
    --limit) LIMIT="$2"; shift 2;;
    --gap) GAP="$2"; shift 2;;
    *) echo "usage: $0 [--local-dir path | --dataset name] [--limit N] [--gap SECONDS]" >&2; exit 2;;
  esac
done

CLIPS_TSV="$(mktemp -t hushy-loopback)"
trap 'rm -f "$CLIPS_TSV"' EXIT

if [ -n "$LOCAL_DIR" ]; then
  python3 - "$LOCAL_DIR" "$LIMIT" "$CLIPS_TSV" <<'EOF'
import json, os, sys
local_dir, limit, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
sidecar = json.load(open(os.path.join(local_dir, "transcripts.json")))
exts = ["wav", "mp3", "m4a", "aiff", "aif", "flac", "caf"]
n = 0
with open(out, "w") as f:
    for key in sorted(sidecar):
        if key.startswith("_") or n >= limit:
            continue
        path = None
        for ext in exts:
            candidate = os.path.join(local_dir, f"{key}.{ext}")
            if os.path.exists(candidate):
                path = candidate
                break
        if path is None:
            continue
        f.write(f"local-{key}\t{path}\n")
        n += 1
EOF
else
  MANIFEST="Evals/data/$DATASET/manifest.json"
  [ -f "$MANIFEST" ] || { echo "no manifest at $MANIFEST — run: murmur-eval download $DATASET --limit $LIMIT" >&2; exit 1; }
  python3 - "$MANIFEST" "$LIMIT" "$CLIPS_TSV" <<'EOF'
import json, sys
manifest, limit, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
clips = json.load(open(manifest))
n = 0
with open(out, "w") as f:
    for clip in clips:
        if n >= limit:
            break
        ref = clip.get("reference", "")
        if "IGNORE_TIME_SEGMENT" in ref or not ref.strip():
            continue
        f.write(f"{clip['id']}\t{clip['audioPath']}\n")
        n += 1
EOF
fi

TOTAL="$(wc -l < "$CLIPS_TSV" | tr -d ' ')"
[ "$TOTAL" -gt 0 ] || { echo "no clips resolved (empty selection)" >&2; exit 1; }

cat <<EOF
=== Acoustic loopback: $TOTAL clips ===
Founder only. Live Hushy running, room quiet, scratch doc open.
For EACH clip: hold fn DURING playback, release at the end.
One pasted line per clip, IN ORDER — blank line for a miss, never delete.
Starting in 5 seconds…
EOF
sleep 5

i=0
while IFS="$(printf '\t')" read -r id path; do
  i=$((i + 1))
  printf '\n--- CLIP %s/%s: %s — hold fn NOW ---\n' "$i" "$TOTAL" "$id"
  afplay "$path"
  printf '(paste lands now — %s s)\n' "$GAP"
  sleep "$GAP"
done < "$CLIPS_TSV"

cat <<EOF

=== Done: $TOTAL clips played ===
Save the scratch doc as loopback-results.txt (one line per clip, in order),
then score it with:
  .build/release/murmur-eval voice-trace score-lines --lines loopback-results.txt \\
      $([ -n "$LOCAL_DIR" ] && echo "--local-dir $LOCAL_DIR" || echo "--dataset $DATASET") --limit $TOTAL
EOF
