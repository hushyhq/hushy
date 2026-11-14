#!/bin/zsh
# Standalone Apple Foundation Models probe (no Hushy code): error kinds and latency per call.
# Builds ./fm-probe from main.swift plus Hushy's exact Clean/Polished prompts, extracted from
# SmartCleaner.swift at build time. See DECISIONS 2026-09-27 "Apple FM errors are memory pressure".
#   scripts/fm-probe/build.sh [outdir]
#   <outdir>/fm-probe --instr clean|polished|short|none --prompt short|medium|long|xlong|"<text>" \
#       --session fresh|reused --mode schema|string --guard default|permissive --n 10 --gap-ms 250
# Watch the system side while it runs (read only):
#   /usr/bin/log stream --style compact --predicate 'eventMessage CONTAINS "current system state" \
#       OR (subsystem == "com.apple.SensitiveContentAnalysisML" AND messageType == error)'
set -euo pipefail
here=${0:a:h}
out=${1:-$here/.build}
src=$here/../../Sources/MurmurCore/Cleanup/SmartCleaner.swift
mkdir -p $out
extract() { awk -v start="    static let $1 = \"\"\"" 'index($0, start) == 1 {on=1; next} on && /^        """$/ {print; exit} on {print}' $src; }
{
  echo 'let hushyCleanInstructions = """'; extract instructions; echo
  echo 'let hushyPolishedInstructions = """'; extract polishedInstructions
} > $out/Prompts.swift
swiftc -O -parse-as-library $out/Prompts.swift $here/main.swift -o $out/fm-probe
echo "built $out/fm-probe"
