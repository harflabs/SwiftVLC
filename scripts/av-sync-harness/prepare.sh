#!/bin/bash
# prepare.sh WORKDIR [ENGINE.xcframework]
#
# Builds the harness against this checkout's SwiftVLC sources and an engine
# (default: Vendor/libvlc.xcframework). WORKDIR receives a SwiftVLC copy whose
# manifest exports CLibVLC and links the given engine, plus the harness itself.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="$1"
ENGINE="$(cd "$(dirname "${2:-$REPO/Vendor/libvlc.xcframework}")" && pwd)/$(basename "${2:-libvlc.xcframework}")"
mkdir -p "$WORK/swiftvlc/Vendor"
rsync -a --delete "$REPO/Sources/" "$WORK/swiftvlc/Sources/"
ln -sfn "$ENGINE" "$WORK/swiftvlc/Vendor/libvlc.xcframework"
python3 - "$REPO/Package.swift" "$WORK/swiftvlc/Package.swift" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
text, n = re.subn(r'\.binaryTarget\(\s*name:\s*"libvlc"[^)]*\)',
                  '.binaryTarget(name: "libvlc", path: "Vendor/libvlc.xcframework")', text)
assert n == 1
text = text.replace('.library(name: "SwiftVLC", targets: ["SwiftVLC"])',
                    '.library(name: "SwiftVLC", targets: ["SwiftVLC"]),\n    .library(name: "CLibVLC", targets: ["CLibVLC"])')
text = re.sub(r'dependencies: \[\n(?:\s*//.*\n|\s*\.package\(url:[^\n]*\n)*\s*\],', 'dependencies: [],', text, count=1)
text = re.sub(r',\s*\.testTarget\(.*?\n    \)\n', '\n', text, flags=re.S)
open(sys.argv[2], "w").write(text)
PY
rsync -a --delete --exclude .build "$HERE/harness/" "$WORK/harness/"
# Build output goes to stderr: stdout is only the executable path, for AVH=$(...).
(cd "$WORK/harness" && swift build) >&2
echo "$WORK/harness/.build/debug/avh"
