#!/usr/bin/env bash
#
# release.sh — Strip, zip, checksum, and publish the libVLC xcframework.
#
# Prerequisites:
#   - ./scripts/build-libvlc.sh --all  (produces Vendor/libvlc.xcframework)
#   - gh authed (gh auth login)
#   - Clean working tree on main (unless --allow-dirty-branch)
#
# Usage:
#   ./scripts/release.sh 0.1.0
#   ./scripts/release.sh 0.1.0 --dry-run            # strip/zip/checksum only, no push
#   ./scripts/release.sh 0.1.0 --allow-dirty-branch # skip the "on main" check
#
set -euo pipefail

REPO="harflabs/SwiftVLC"
XCFW_PATH="Vendor/libvlc.xcframework"
ZIP_NAME="libvlc.xcframework.zip"
MAX_SIZE=$((2 * 1024 * 1024 * 1024))  # 2 GB (GitHub release asset limit)

# All 5 slices the xcframework must contain. If a slice is missing, the
# release would ship a partial artifact that fails on one of iOS/tvOS/macOS/Catalyst.
EXPECTED_SLICES=(
  "ios-arm64"
  "ios-arm64_x86_64-simulator"
  "tvos-arm64"
  "tvos-arm64_x86_64-simulator"
  "macos-arm64_x86_64"
  "ios-arm64_x86_64-maccatalyst"
)

# ── Args ──────────────────────────────────────────────────────────────────────

VERSION=""
DRY_RUN=false
ALLOW_DIRTY_BRANCH=false

for arg in "$@"; do
  case "$arg" in
    --dry-run)            DRY_RUN=true ;;
    --allow-dirty-branch) ALLOW_DIRTY_BRANCH=true ;;
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

if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version> [--dry-run] [--allow-dirty-branch]" >&2
  echo "  e.g. $0 0.1.0" >&2
  exit 1
fi

TAG="v${VERSION}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# ── Preflight ─────────────────────────────────────────────────────────────────

if [[ ! -d "$XCFW_PATH" ]]; then
  echo "Error: $XCFW_PATH not found. Build it first: ./scripts/build-libvlc.sh --all" >&2
  exit 1
fi

# Verify every expected platform slice is present. Missing slices would produce
# a release that breaks at SPM-resolution time for affected platforms.
missing_slices=()
for slice in "${EXPECTED_SLICES[@]}"; do
  if [[ ! -d "$XCFW_PATH/$slice" ]]; then
    missing_slices+=("$slice")
  fi
done
if [[ ${#missing_slices[@]} -gt 0 ]]; then
  echo "Error: xcframework is missing slices: ${missing_slices[*]}" >&2
  echo "  Re-run ./scripts/build-libvlc.sh --all to build all platforms." >&2
  exit 1
fi

if ! command -v gh &>/dev/null; then
  echo "Error: GitHub CLI (gh) is required. Install with: brew install gh" >&2
  exit 1
fi

if [[ "$DRY_RUN" == false ]]; then
  if ! gh auth status &>/dev/null; then
    echo "Error: Not authenticated with gh. Run: gh auth login" >&2
    exit 1
  fi

  if [[ -n "$(git status --porcelain Package.swift)" ]]; then
    echo "Error: Package.swift has uncommitted changes. Commit or stash first." >&2
    exit 1
  fi

  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  if [[ "$CURRENT_BRANCH" != "main" && "$ALLOW_DIRTY_BRANCH" == false ]]; then
    echo "Error: on branch '$CURRENT_BRANCH', not 'main'." >&2
    echo "  Releases should usually be cut from main." >&2
    echo "  Pass --allow-dirty-branch to override." >&2
    exit 1
  fi

  if git rev-parse "$TAG" &>/dev/null; then
    echo "Error: tag '$TAG' already exists locally." >&2
    echo "  If the previous release attempt was partial, clean up:" >&2
    echo "    git tag -d $TAG && git push origin :refs/tags/$TAG" >&2
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
  echo "Error: Zip is ${ZIP_SIZE_MB} MB — exceeds GitHub's 2 GB limit." >&2
  echo "  The xcframework may need further size reduction." >&2
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

# Atomic write: tempfile + os.replace, so an interrupted rewrite can't corrupt
# the manifest.
RELEASE_URL="$RELEASE_URL" CHECKSUM="$CHECKSUM" python3 - <<'PYEOF'
import os
import re
import sys
import tempfile

url = os.environ["RELEASE_URL"]
checksum = os.environ["CHECKSUM"]
path = "Package.swift"

with open(path, "r") as f:
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

echo "  Package.swift updated to remote URL."

# ── Validate Package.swift ───────────────────────────────────────────────

if ! grep -q 'name: "CLibVLC"' Package.swift; then
  echo "Error: Package.swift corrupted — CLibVLC target missing." >&2
  echo "  Restoring with: git checkout Package.swift" >&2
  git checkout Package.swift
  exit 1
fi

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
