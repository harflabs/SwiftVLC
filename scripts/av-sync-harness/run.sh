#!/bin/bash
# run.sh AVH OUTDIR NAME URL SCENARIO [avh options...]
# Runs one scenario (quiet audio) and writes NAME.jsonl, NAME.vlc.log and the
# analysis NAME.summary.txt / NAME.report.json into OUTDIR.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
AVH="$1"; OUT="$2"; NAME="$3"; URL="$4"; SCENARIO="$5"; shift 5
mkdir -p "$OUT"
"$AVH" --mode swiftvlc --url "$URL" --scenario "$SCENARIO" --out "$OUT/$NAME.jsonl" \
  --log "$OUT/$NAME.vlc.log" --arg --gain=0.05 "$@" 2> "$OUT/$NAME.stderr"
python3 "$HERE/analyze.py" "$OUT/$NAME.jsonl" --json "$OUT/$NAME.report.json" > "$OUT/$NAME.summary.txt"
cat "$OUT/$NAME.summary.txt"
