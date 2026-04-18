#!/usr/bin/env bash
#
# setup-dev.sh — Install the libvlc xcframework locally and point
# Package.swift at it, so `swift build` / `swift test` work on a fresh clone.
#
# Usage:
#   ./scripts/setup-dev.sh                  # install latest release (or keep existing)
#   ./scripts/setup-dev.sh v0.3.0           # pin to a specific release tag
#   ./scripts/setup-dev.sh --force          # always re-download, even if Vendor/ exists
#   ./scripts/setup-dev.sh --skip-download  # only flip Package.swift to local path
#                                             (useful after ./scripts/build-libvlc.sh)
#
set -euo pipefail

REPO="harflabs/SwiftVLC"
XCFW_DIR="Vendor/libvlc.xcframework"
ZIP_NAME="libvlc.xcframework.zip"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# ── Args ──────────────────────────────────────────────────────────────────────

VERSION=""
FORCE=false
SKIP_DOWNLOAD=false

for arg in "$@"; do
  case "$arg" in
    --force)         FORCE=true ;;
    --skip-download) SKIP_DOWNLOAD=true ;;
    --help|-h)
      sed -n 's/^# \{0,1\}//p' "$0" | sed -n '/^Usage:/,/^$/p'
      exit 0 ;;
    -*)
      echo "Error: unknown flag '$arg'" >&2
      exit 1 ;;
    *)
      if [[ -n "$VERSION" ]]; then
        echo "Error: version already specified ('$VERSION'), got extra arg '$arg'" >&2
        exit 1
      fi
      VERSION="$arg" ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────

# Rewrite Package.swift's libvlc binaryTarget to local path form. Writes to a
# temp file and renames atomically so an interrupted write can't leave the
# manifest corrupted.
switch_package_to_local_path() {
  python3 - <<'PYEOF'
import os
import re
import sys
import tempfile

path = "Package.swift"
with open(path, "r") as f:
    text = f.read()

pattern = r'\.binaryTarget\(\s*name:\s*"libvlc"[^)]*\)'
replacement = '.binaryTarget(name: "libvlc", path: "Vendor/libvlc.xcframework")'
result, n = re.subn(pattern, replacement, text, count=1, flags=re.DOTALL)

if n == 0:
    print("ERROR: could not find libvlc binaryTarget in Package.swift", file=sys.stderr)
    sys.exit(1)
if result == text:
    # Already local path — nothing to do.
    sys.exit(0)

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
}

require_gh() {
  if ! command -v gh &>/dev/null; then
    echo "Error: GitHub CLI (gh) is required. Install with: brew install gh" >&2
    exit 1
  fi
  if ! gh auth status &>/dev/null; then
    echo "Error: not authenticated with gh. Run: gh auth login" >&2
    exit 1
  fi
}

# ── Decide whether to download ────────────────────────────────────────────────

if [[ "$SKIP_DOWNLOAD" == true ]]; then
  if [[ ! -d "$XCFW_DIR" ]]; then
    echo "Error: --skip-download passed but $XCFW_DIR does not exist." >&2
    echo "  Run ./scripts/build-libvlc.sh first, or omit --skip-download." >&2
    exit 1
  fi
  echo "Keeping existing xcframework at $XCFW_DIR (--skip-download)."
else
  NEED_DOWNLOAD=false
  if [[ ! -d "$XCFW_DIR" ]]; then
    NEED_DOWNLOAD=true
  elif [[ "$FORCE" == true ]]; then
    echo "Removing existing $XCFW_DIR (--force)..."
    rm -rf "$XCFW_DIR"
    NEED_DOWNLOAD=true
  else
    echo "Keeping existing xcframework at $XCFW_DIR (pass --force to re-download)."
  fi

  if [[ "$NEED_DOWNLOAD" == true ]]; then
    require_gh
    mkdir -p Vendor

    echo "Downloading $ZIP_NAME..."
    if [[ -n "$VERSION" ]]; then
      gh release download "$VERSION" --repo "$REPO" --pattern "$ZIP_NAME" --dir Vendor/
    else
      gh release download --repo "$REPO" --pattern "$ZIP_NAME" --dir Vendor/
    fi

    echo "Extracting..."
    (cd Vendor && ditto -x -k "$ZIP_NAME" . && rm "$ZIP_NAME")
    echo "  Installed to $XCFW_DIR"

    # Fix duplicate symbols (json_parse_error/json_read) in the static library.
    # Two VLC plugins (ytdl, chromecast) each compile their own copy; the
    # Apple linker in Xcode 16+ treats duplicates as errors on Mac Catalyst.
    echo "Fixing duplicate symbols in static libraries..."
    "$SCRIPT_DIR/fix-duplicate-symbols.sh" "$XCFW_DIR"
  fi
fi

# ── Flip Package.swift to local path ──────────────────────────────────────────

echo "Pointing Package.swift at $XCFW_DIR..."
switch_package_to_local_path
echo "  Package.swift now uses local path."

echo ""
echo "Done. Try:"
echo "  swift build"
echo "  swift test"
