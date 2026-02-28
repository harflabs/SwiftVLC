#!/usr/bin/env bash
#
# setup-dev.sh — Download xcframework and switch Package.swift to local path
#
# Usage:
#   ./scripts/setup-dev.sh          # Download from latest release
#   ./scripts/setup-dev.sh v0.1.0   # Download a specific version
#
set -euo pipefail

REPO="harflabs/SwiftVLC"
XCFW_DIR="Vendor/libvlc.xcframework"
ZIP_NAME="libvlc.xcframework.zip"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# ── Preflight ─────────────────────────────────────────────────────────────────

if ! command -v gh &>/dev/null; then
  echo "Error: GitHub CLI (gh) is required. Install with: brew install gh"
  exit 1
fi

if ! gh auth status &>/dev/null; then
  echo "Error: Not authenticated with gh. Run: gh auth login"
  exit 1
fi

# ── Download ──────────────────────────────────────────────────────────────────

VERSION="${1:-}"

if [[ -d "$XCFW_DIR" ]]; then
  echo "xcframework already exists at $XCFW_DIR"
  read -rp "Re-download and replace? [y/N] " answer
  if [[ "$answer" != [yY] ]]; then
    echo "Keeping existing xcframework."
  else
    rm -rf "$XCFW_DIR"
  fi
fi

if [[ ! -d "$XCFW_DIR" ]]; then
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
fi

# ── Switch Package.swift to local path ────────────────────────────────────────

echo "Switching Package.swift to local path..."

sed -i '' -E \
  '/\.binaryTarget\($/,/\)/c\
    .binaryTarget(name: "libvlc", path: "Vendor/libvlc.xcframework")' \
  Package.swift

# Also handle single-line form
sed -i '' -E \
  's|\.binaryTarget\(name: "libvlc", url: "[^"]*", checksum: "[^"]*"\)|.binaryTarget(name: "libvlc", path: "Vendor/libvlc.xcframework")|' \
  Package.swift

echo "  Package.swift now uses local path."
echo ""
echo "Done! You can now build and test locally:"
echo "  swift build"
echo "  swift test"
