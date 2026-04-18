#!/usr/bin/env bash
#
# ci-use-released-xcframework.sh — Swap Package.swift's libvlc binaryTarget
# from the local-path form to the url+checksum form from the latest release,
# so CI can resolve the xcframework via SPM just like a downstream consumer
# pinning that tag would.
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

tag=$(gh release view --json tagName -q .tagName)
if [ -z "$tag" ]; then
  echo "Error: could not resolve latest release tag via gh." >&2
  exit 1
fi

# Make sure the tag blob is locally available (shallow CI checkouts don't
# fetch tags by default).
git fetch origin "refs/tags/$tag:refs/tags/$tag" >/dev/null 2>&1 || true

tag_manifest=$(git show "$tag:Package.swift")

url=$(printf '%s\n' "$tag_manifest" | grep -oE 'https://[^"]*libvlc\.xcframework\.zip' | head -1)
checksum=$(printf '%s\n' "$tag_manifest" | grep -oE '[a-f0-9]{64}' | head -1)

if [ -z "$url" ] || [ -z "$checksum" ]; then
  echo "Error: could not extract url/checksum from $tag's Package.swift." >&2
  echo "  Did release.sh successfully pin the manifest for $tag?" >&2
  exit 1
fi

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
