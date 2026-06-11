#!/usr/bin/env bash
# Drives Showcase AspectRatioCase through every aspect option on a booted iOS
# simulator and prints one JSON measurement line per option. Prerequisites:
#   - Showcase iOS installed on the target sim (bundle com.swiftvlc.showcase.ios)
#   - idb_companion running for the UDID; fb-idb + Pillow venvs (see README)
#   - the fixture from make-fixture.sh
# The PopUpButton menu coordinates are layout-stable for this screen; re-derive
# with `idb ui describe-all` if the Showcase layout changes.
set -euo pipefail
UDID="${1:?usage: sweep.sh <udid> [fixture] [outdir]}"
FIXTURE="${2:-/tmp/aspect-240.mp4}"
OUT="${3:-/tmp/aspect-sweep}"
IDB="${IDB:-/tmp/idbvenv/bin/idb}"
PY="${PY:-/tmp/axvenv/bin/python}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BUNDLE=com.swiftvlc.showcase.ios
PICKER_X=201; PICKER_Y=587
mkdir -p "$OUT"
optY() { case "$1" in
  default) echo 366;; fill) echo 408;; r169) echo 450;;
  r43) echo 492;; r11) echo 534;; r219) echo 576;; esac; }
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl launch "$UDID" "$BUNDLE" \
  -UITestMode 1 -UITestRoute AspectRatio -UITestFixtureURL "$FIXTURE" >/dev/null
sleep 5
for opt in default fill r169 r43 r11 r219; do
  "$IDB" ui tap --udid "$UDID" $PICKER_X $PICKER_Y >/dev/null 2>&1; sleep 1
  "$IDB" ui tap --udid "$UDID" 245 "$(optY "$opt")" >/dev/null 2>&1; sleep 2
  xcrun simctl io "$UDID" screenshot "$OUT/$opt.png" >/dev/null 2>&1
  printf '%s ' "$opt"
  "$PY" "$HERE/measure.py" "$OUT/$opt.png" 666 1396
done
