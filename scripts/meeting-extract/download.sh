#!/bin/sh
# Fetches the text-only raw files for the meeting-extract data (about 0.8 GB with unpacking).
# AMI is read from Evals/runs/public/ami/extracted; it is fetched there when missing.
# HUSHY_MEETING_PUBLIC=1 fetches only the CC BY 4.0 corpora of the public recipe (AMI and ICSI) and stops.
set -eu
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ROOT=${1:-${HUSHY_MEETING_DATA:-$REPO/.build/public-data/meeting-extract}}/raw
mkdir -p "$ROOT/icsi-plus"

AMI="$REPO/Evals/runs/public/ami"
if [ ! -d "$AMI/extracted" ]; then
  mkdir -p "$AMI"
  curl -fL -o "$AMI/ami_public_manual_1.6.2.zip" https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip
  unzip -q -o "$AMI/ami_public_manual_1.6.2.zip" -d "$AMI/extracted"
fi

curl -fL -o "$ROOT/icsi-plus/ICSI_plus_NXT.zip" https://groups.inf.ed.ac.uk/ami/ICSICorpusAnnotations/ICSI_plus_NXT.zip
unzip -q -o "$ROOT/icsi-plus/ICSI_plus_NXT.zip" -d "$ROOT/icsi-plus/x"
[ "${HUSHY_MEETING_PUBLIC:-0}" = 1 ] && exit 0
mkdir -p "$ROOT/qmsum" "$ROOT/meetingbank" "$ROOT/elitr" "$ROOT/notsofar"

curl -fL -o "$ROOT/qmsum/QMSum.zip" https://github.com/Yale-LILY/QMSum/archive/refs/heads/main.zip
unzip -q -o "$ROOT/qmsum/QMSum.zip" -d "$ROOT/qmsum/x"

for f in train validation test; do
  curl -fL -o "$ROOT/meetingbank/$f.json" "https://huggingface.co/datasets/huuuyeah/meetingbank/resolve/main/$f.json"
done

LINDAT=https://lindat.mff.cuni.cz/repository/server/api/core/bitstreams
curl -fL -o "$ROOT/elitr/ELITR-minuting-corpus.zip" "$LINDAT/76466f35-1bac-47bf-958b-c235b1fb4966/content"
curl -fL -o "$ROOT/elitr/license.txt" "$LINDAT/5eb5f4c1-9f3d-4aa1-bbc5-4a3deb6433fa/content"
unzip -q -o "$ROOT/elitr/ELITR-minuting-corpus.zip" -d "$ROOT/elitr/x"

# NOTSOFAR-1: the transcript JSON of each train-set meeting, no audio. Train split only.
HF=https://huggingface.co/datasets/microsoft/NOTSOFAR/resolve/main/benchmark-datasets/train_set/240825.1_train/MTG
curl -fsL "https://huggingface.co/api/datasets/microsoft/NOTSOFAR/tree/main/benchmark-datasets/train_set/240825.1_train/MTG?limit=1000" |
  python3 -c "import sys,json;print('\n'.join(x['path'].split('/')[-1] for x in json.load(sys.stdin) if x['type']=='directory'))" > "$ROOT/notsofar/ids.txt"
while read -r id; do
  mkdir -p "$ROOT/notsofar/mtg/$id"
  for f in gt_transcription.json gt_meeting_metadata.json; do
    curl -fsL -o "$ROOT/notsofar/mtg/$id/$f" "$HF/$id/$f"
  done
done < "$ROOT/notsofar/ids.txt"
