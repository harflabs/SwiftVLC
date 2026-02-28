#!/usr/bin/env bash
#
# release.sh — Strip, zip, checksum, and publish the libVLC xcframework
#
# Usage:
#   ./scripts/release.sh 0.1.0            # Full release
#   ./scripts/release.sh 0.1.0 --dry-run  # Strip/zip/checksum only
#
set -euo pipefail

REPO="harflabs/SwiftVLC"
XCFW_PATH="Vendor/libvlc.xcframework"
ZIP_NAME="libvlc.xcframework.zip"
MAX_SIZE=$((2 * 1024 * 1024 * 1024))  # 2 GB

# ── Args ──────────────────────────────────────────────────────────────────────

VERSION="${1:-}"
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version> [--dry-run]"
  echo "  e.g. $0 0.1.0"
  exit 1
fi

TAG="v${VERSION}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# ── Preflight ─────────────────────────────────────────────────────────────────

if [[ ! -d "$XCFW_PATH" ]]; then
  echo "Error: $XCFW_PATH not found. Build it first with ./build-libvlc.sh"
  exit 1
fi

if ! command -v gh &>/dev/null; then
  echo "Error: GitHub CLI (gh) is required. Install with: brew install gh"
  exit 1
fi

if [[ "$DRY_RUN" == false ]]; then
  if ! gh auth status &>/dev/null; then
    echo "Error: Not authenticated with gh. Run: gh auth login"
    exit 1
  fi

  if [[ -n "$(git status --porcelain Package.swift)" ]]; then
    echo "Error: Package.swift has uncommitted changes. Commit or stash first."
    exit 1
  fi
fi

# ── Strip ─────────────────────────────────────────────────────────────────────

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Copying xcframework to temp dir..."
cp -R "$XCFW_PATH" "$WORK_DIR/libvlc.xcframework"

echo "Stripping debug symbols from .a files..."
BEFORE_SIZE=$(du -sh "$WORK_DIR/libvlc.xcframework" | cut -f1)
find "$WORK_DIR/libvlc.xcframework" -name '*.a' -exec strip -S {} \;
AFTER_SIZE=$(du -sh "$WORK_DIR/libvlc.xcframework" | cut -f1)
echo "  Before: $BEFORE_SIZE → After: $AFTER_SIZE"

# ── Zip ───────────────────────────────────────────────────────────────────────

echo "Creating zip..."
ZIP_PATH="$WORK_DIR/$ZIP_NAME"
(cd "$WORK_DIR" && ditto -c -k --keepParent libvlc.xcframework "$ZIP_NAME")

ZIP_SIZE=$(stat -f%z "$ZIP_PATH")
ZIP_SIZE_MB=$((ZIP_SIZE / 1024 / 1024))
echo "  Zip size: ${ZIP_SIZE_MB} MB"

if [[ "$ZIP_SIZE" -ge "$MAX_SIZE" ]]; then
  echo "Error: Zip is ${ZIP_SIZE_MB} MB — exceeds GitHub's 2 GB limit."
  echo "  The xcframework may need further size reduction."
  exit 1
fi

# ── Checksum ──────────────────────────────────────────────────────────────────

echo "Computing checksum..."
CHECKSUM=$(swift package compute-checksum "$ZIP_PATH")
echo "  SHA256: $CHECKSUM"

# ── Summary ───────────────────────────────────────────────────────────────────

RELEASE_URL="https://github.com/$REPO/releases/download/$TAG/$ZIP_NAME"

echo ""
echo "=== Release Summary ==="
echo "  Version:  $VERSION ($TAG)"
echo "  Zip:      ${ZIP_SIZE_MB} MB"
echo "  Checksum: $CHECKSUM"
echo "  URL:      $RELEASE_URL"

if [[ "$DRY_RUN" == true ]]; then
  echo ""
  echo "Dry run complete. No changes pushed."
  echo ""
  echo "Package.swift snippet:"
  echo "  .binaryTarget("
  echo "    name: \"libvlc\","
  echo "    url: \"$RELEASE_URL\","
  echo "    checksum: \"$CHECKSUM\""
  echo "  )"
  exit 0
fi

# ── Update Package.swift ─────────────────────────────────────────────────────

echo ""
echo "Updating Package.swift..."

# Replace the binaryTarget line (handles both local-path and url+checksum forms)
sed -i '' -E \
  '/\.binaryTarget\(name: "libvlc"/,/\)/c\
    .binaryTarget(\
      name: "libvlc",\
      url: "'"$RELEASE_URL"'",\
      checksum: "'"$CHECKSUM"'"\
    )' \
  Package.swift

echo "  Package.swift updated to remote URL."

# ── Tag & Push ────────────────────────────────────────────────────────────────

echo "Committing, tagging, and pushing..."
git add Package.swift
git commit -m "Release $TAG — update Package.swift to remote xcframework URL"
git tag "$TAG"
git push origin HEAD
git push origin "$TAG"

# ── GitHub Release ────────────────────────────────────────────────────────────

echo "Creating GitHub Release..."
gh release create "$TAG" "$ZIP_PATH" \
  --repo "$REPO" \
  --title "SwiftVLC $TAG" \
  --notes "$(cat <<EOF
## libVLC xcframework

Pre-built static xcframework for libVLC 4.0.

**Platforms:** iOS 18+, macOS 15+, tvOS 18+, Mac Catalyst
**Size:** ${ZIP_SIZE_MB} MB (stripped)
**Checksum:** \`$CHECKSUM\`

SPM resolves this automatically — just add the package dependency.
EOF
)"

echo ""
echo "Release $TAG published: https://github.com/$REPO/releases/tag/$TAG"
