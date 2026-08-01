#!/usr/bin/env bash
#
# ci-use-released-xcframework.sh — Rewrite Package.swift's libvlc
# binaryTarget to the url+checksum form from the exact release declared by the
# checkout (or SWIFTVLC_RELEASE_TAG), so CI cannot silently test a different
# engine because GitHub's "latest" pointer excludes pre-releases.
#
# Only the binaryTarget is rewritten; other Package.swift changes on the
# branch (swiftSettings, new targets, platform bumps) are preserved.
#
# Writes `sha` and `tag` to $GITHUB_OUTPUT if that env var is set, so later
# steps can key their caches on the resolved checksum.
#
# Requires: gh (authed via GH_TOKEN / GITHUB_TOKEN), git, python3.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

artifact_info=$("$SCRIPT_DIR/resolve-release-artifact.sh")
tag=$(printf '%s' "$artifact_info" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag"])')
url=$(printf '%s' "$artifact_info" | python3 -c 'import json,sys; print(json.load(sys.stdin)["url"])')
checksum=$(printf '%s' "$artifact_info" | python3 -c 'import json,sys; print(json.load(sys.stdin)["checksum"])')

# Atomic rewrite of only the binaryTarget line.
URL="$url" CHECKSUM="$checksum" python3 - <<'PYEOF'
import os
import re
import sys
import tempfile

url = os.environ["URL"]
checksum = os.environ["CHECKSUM"]
path = "Package.swift"

with open(path) as f:
    text = f.read()

pattern = r'\.binaryTarget\(\s*name:\s*"libvlc"[^)]*\)'
replacement = (
    '.binaryTarget(\n'
    '      name: "libvlc",\n'
    f'      url: "{url}",\n'
    f'      checksum: "{checksum}"\n'
    '    )'
)
result, n = re.subn(pattern, replacement, text, count=1, flags=re.DOTALL)
if n == 0:
    print("ERROR: binaryTarget pattern not found in Package.swift", file=sys.stderr)
    sys.exit(1)

fd, tmp = tempfile.mkstemp(dir=".", prefix=".Package.swift.", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        f.write(result)
    os.replace(tmp, path)
except Exception:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise
PYEOF

echo "Pinned Package.swift to $tag (checksum=$checksum)" >&2

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "sha=$checksum"
    echo "tag=$tag"
  } >> "$GITHUB_OUTPUT"
fi
