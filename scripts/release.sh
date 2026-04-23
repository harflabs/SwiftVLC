#!/usr/bin/env bash
#
# release.sh — Strip, zip, checksum, and publish the libVLC xcframework.
#
# Prerequisites:
#   - ./scripts/build-libvlc.sh --all  (produces Vendor/libvlc.xcframework)
#   - gh authed (gh auth login)
#   - Clean Package.swift + Showcase project on main
#
# Usage:
#   ./scripts/release.sh 0.1.0
#   ./scripts/release.sh 0.1.0 --dry-run            # strip/zip/checksum only, no push
#
set -euo pipefail

REPO="harflabs/SwiftVLC"
XCFW_PATH="Vendor/libvlc.xcframework"
SHOWCASE_PROJECT="Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj"
ZIP_NAME="libvlc.xcframework.zip"
MAX_SIZE=$((2 * 1024 * 1024 * 1024))  # 2 GB (GitHub release asset limit)

# All 6 slices the xcframework must contain. If a slice is missing, the
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

for arg in "$@"; do
  case "$arg" in
    --dry-run)            DRY_RUN=true ;;
    --allow-dirty-branch)
      echo "Error: --allow-dirty-branch is no longer supported." >&2
      echo "  Releases advance origin/main and must be run from main." >&2
      exit 1 ;;
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
  echo "Usage: $0 <version> [--dry-run]" >&2
  echo "  e.g. $0 0.1.0" >&2
  exit 1
fi

TAG="v${VERSION}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# ── Helpers ───────────────────────────────────────────────────────────────────

WORK_DIR=""
RELEASE_RESTORE_DIR=""
RELEASE_RESTORE_FILES=false

cleanup() {
  local status=$?

  if [[ "$RELEASE_RESTORE_FILES" == true ]]; then
    if [[ -n "$RELEASE_RESTORE_DIR" && -f "$RELEASE_RESTORE_DIR/Package.swift" ]]; then
      cp "$RELEASE_RESTORE_DIR/Package.swift" Package.swift
    fi
    if [[ -n "$RELEASE_RESTORE_DIR" && -f "$RELEASE_RESTORE_DIR/project.pbxproj" ]]; then
      cp "$RELEASE_RESTORE_DIR/project.pbxproj" "$SHOWCASE_PROJECT"
    fi
    git reset -q -- Package.swift "$SHOWCASE_PROJECT" 2>/dev/null || true
    if [[ "$status" -ne 0 ]]; then
      echo "Restored Package.swift and $SHOWCASE_PROJECT after failed release rewrite." >&2
    fi
  fi

  if [[ -n "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
  if [[ -n "$RELEASE_RESTORE_DIR" ]]; then
    rm -rf "$RELEASE_RESTORE_DIR"
  fi
}
trap cleanup EXIT

begin_release_file_restore() {
  RELEASE_RESTORE_DIR=$(mktemp -d)
  cp Package.swift "$RELEASE_RESTORE_DIR/Package.swift"
  cp "$SHOWCASE_PROJECT" "$RELEASE_RESTORE_DIR/project.pbxproj"
  RELEASE_RESTORE_FILES=true
}

switch_package_to_release_url() {
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
}

switch_showcase_to_release_version() {
  RELEASE_VERSION="$VERSION" SHOWCASE_PROJECT="$SHOWCASE_PROJECT" python3 - <<'PYEOF'
import os
import re
import sys
import tempfile

version = os.environ["RELEASE_VERSION"]
path = os.environ["SHOWCASE_PROJECT"]

with open(path, "r") as f:
    text = f.read()

local_block = """/* Begin XCLocalSwiftPackageReference section */
\t\tBA000001 /* XCLocalSwiftPackageReference \"..\" */ = {
\t\t\tisa = XCLocalSwiftPackageReference;
\t\t\trelativePath = ..;
\t\t};
/* End XCLocalSwiftPackageReference section */"""

remote_block = f"""/* Begin XCRemoteSwiftPackageReference section */
\t\tBA000001 /* XCRemoteSwiftPackageReference \"SwiftVLC\" */ = {{
\t\t\tisa = XCRemoteSwiftPackageReference;
\t\t\trepositoryURL = \"https://github.com/harflabs/SwiftVLC\";
\t\t\trequirement = {{
\t\t\t\tkind = exactVersion;
\t\t\t\tversion = {version};
\t\t\t}};
\t\t}};
/* End XCRemoteSwiftPackageReference section */"""

remote_pattern = re.compile(
    r'/\* Begin XCRemoteSwiftPackageReference section \*/\n'
    r'\t\tBA000001 /\* XCRemoteSwiftPackageReference "SwiftVLC" \*/ = \{\n'
    r'\t\t\tisa = XCRemoteSwiftPackageReference;\n'
    r'\t\t\trepositoryURL = "https://github.com/harflabs/SwiftVLC";\n'
    r'\t\t\trequirement = \{\n'
    r'\t\t\t\tkind = (?:upToNextMajorVersion|exactVersion);\n'
    r'\t\t\t\t(?:minimumVersion|version) = [0-9.]+;\n'
    r'\t\t\t\};\n'
    r'\t\t\};\n'
    r'/\* End XCRemoteSwiftPackageReference section \*/'
)

if local_block in text:
    result = text.replace(local_block, remote_block, 1)
else:
    result, n = remote_pattern.subn(remote_block, text, count=1)
    if n == 0:
        print("ERROR: Showcase package reference block not found", file=sys.stderr)
        sys.exit(1)

result = result.replace(
    'BA000001 /* XCLocalSwiftPackageReference ".." */',
    'BA000001 /* XCRemoteSwiftPackageReference "SwiftVLC" */',
)

fd, tmp = tempfile.mkstemp(dir=".", prefix=".SwiftVLCShowcase.", suffix=".tmp")
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

  if [[ -n "$(git status --porcelain -- Package.swift "$SHOWCASE_PROJECT")" ]]; then
    echo "Error: Package.swift or $SHOWCASE_PROJECT has uncommitted changes." >&2
    echo "  Commit or stash them first." >&2
    exit 1
  fi

  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  if [[ "$CURRENT_BRANCH" != "main" ]]; then
    echo "Error: refusing to release from branch '$CURRENT_BRANCH'." >&2
    echo "  Release commits advance origin/main, so rerun from main." >&2
    exit 1
  fi

  if git rev-parse "$TAG" &>/dev/null; then
    echo "Error: tag '$TAG' already exists locally." >&2
    echo "  If the previous release attempt was partial, clean up:" >&2
    echo "    git tag -d $TAG && git push origin :refs/tags/$TAG" >&2
    exit 1
  fi

  if git ls-remote --exit-code --tags origin "refs/tags/$TAG" &>/dev/null; then
    echo "Error: tag '$TAG' already exists on origin." >&2
    echo "  Finish that release or delete the remote tag before retrying:" >&2
    echo "    git push origin :refs/tags/$TAG" >&2
    exit 1
  fi

  if gh release view "$TAG" --repo "$REPO" &>/dev/null; then
    echo "Error: GitHub Release '$TAG' already exists." >&2
    echo "  Delete it first or pick a new version." >&2
    exit 1
  fi
fi

# ── Strip ─────────────────────────────────────────────────────────────────────

WORK_DIR=$(mktemp -d)

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
  echo ""
  echo "Showcase package requirement:"
  echo "  kind = exactVersion"
  echo "  version = $VERSION"
  exit 0
fi

# ── Release commit on main ───────────────────────────────────────────────────
#
# main should always resolve the most recently published xcframework, and the
# Showcase app should always resolve the matching Swift package release. Local
# development can flip both back to repo-local sources via `setup-dev.sh`.
#
# Mechanics:
#   1. Rewrite Package.swift and the Showcase app, commit, and tag.
#   2. Push the tag first so GitHub can attach the release asset to the exact
#      commit without advancing origin/main yet.
#   3. Create the GitHub Release and upload the zip.
#   4. Fast-forward origin/main to the same commit, so main always points at
#      the latest published binary and Showcase package version.
#
# If the tag push succeeds but later steps fail, origin/main is still untouched.
# Finish the GitHub Release (or delete the tag) and then retry the main push.

echo ""
echo "Creating release commit on $CURRENT_BRANCH..."

begin_release_file_restore

echo "Pointing Package.swift at $RELEASE_URL..."
switch_package_to_release_url

echo "Pointing Showcase app at SwiftVLC $TAG..."
switch_showcase_to_release_version

# Sanity-check: a corrupted regex result would wipe the rest of Package.swift.
if ! grep -q 'name: "CLibVLC"' Package.swift; then
  echo "Error: Package.swift corrupted — CLibVLC target missing." >&2
  exit 1
fi

if ! grep -q 'kind = exactVersion;' "$SHOWCASE_PROJECT"; then
  echo "Error: Showcase project was not pinned to an exact SwiftVLC version." >&2
  exit 1
fi

git add Package.swift "$SHOWCASE_PROJECT"
git commit --quiet -m "Release $TAG"
RELEASE_RESTORE_FILES=false
TAG_COMMIT=$(git rev-parse HEAD)
git tag "$TAG" "$TAG_COMMIT"

echo "  Tag $TAG → $TAG_COMMIT (Package.swift pinned to $RELEASE_URL)"
echo "  Showcase app → exactVersion $VERSION"

echo "Pushing tag..."
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

echo "Pushing $CURRENT_BRANCH to origin/main..."
git push origin HEAD:main

echo "  origin/main → $TAG_COMMIT"

echo ""
echo "Release $TAG published: https://github.com/$REPO/releases/tag/$TAG"
