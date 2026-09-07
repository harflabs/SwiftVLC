#!/usr/bin/env bash
#
# setup-dev.sh — Install the libvlc xcframework locally and point
# Package.swift plus the Showcase app at repo-local sources, so `swift build`
# / `swift test` and local Showcase development work on a fresh clone.
#
# Usage:
#   ./scripts/setup-dev.sh                  # install release declared by Package.swift
#   ./scripts/setup-dev.sh v0.3.0           # pin to a specific release tag
#   ./scripts/setup-dev.sh --force          # always re-download, even if Vendor/ exists
#   ./scripts/setup-dev.sh --artifact-only  # install/verify Vendor without editing sources
#   ./scripts/setup-dev.sh --manifest-only  # use this checkout's pinned URL/checksum
#   ./scripts/setup-dev.sh --skip-download  # only flip local references
#                                             (useful after ./scripts/build-libvlc.sh)
#
set -euo pipefail

REPO="harflabs/SwiftVLC"
XCFW_DIR="Vendor/libvlc.xcframework"
INSTALL_RECORD="Vendor/.swiftvlc-release.json"
SHOWCASE_PROJECT="Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj"
ZIP_NAME="libvlc.xcframework.zip"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# ── Args ──────────────────────────────────────────────────────────────────────

VERSION=""
FORCE=false
SKIP_DOWNLOAD=false
ARTIFACT_ONLY=false
MANIFEST_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --force)         FORCE=true ;;
    --artifact-only) ARTIFACT_ONLY=true ;;
    --manifest-only) MANIFEST_ONLY=true ;;
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
        os.fchmod(f.fileno(), os.stat(path).st_mode & 0o7777)
        f.write(result)
    os.replace(tmp, path)
except Exception:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise
PYEOF
}

switch_showcase_to_local_package() {
  SHOWCASE_PROJECT="$SHOWCASE_PROJECT" python3 - <<'PYEOF'
import os
import re
import sys
import tempfile

path = os.environ["SHOWCASE_PROJECT"]

with open(path, "r") as f:
    text = f.read()

local_block = """/* Begin XCLocalSwiftPackageReference section */
\t\tBA000001 /* XCLocalSwiftPackageReference \"..\" */ = {
\t\t\tisa = XCLocalSwiftPackageReference;
\t\t\trelativePath = \"..\";
\t\t};
/* End XCLocalSwiftPackageReference section */"""

remote_pattern = re.compile(
    r'/\* Begin XCRemoteSwiftPackageReference section \*/\n'
    r'\t\tBA000001 /\* XCRemoteSwiftPackageReference "SwiftVLC" \*/ = \{\n'
    r'\t\t\tisa = XCRemoteSwiftPackageReference;\n'
    r'\t\t\trepositoryURL = "https://github.com/harflabs/SwiftVLC";\n'
    r'\t\t\trequirement = \{\n'
    r'\t\t\t\tkind = (?:upToNextMajorVersion|exactVersion);\n'
    # Pre-release identifiers carry letters and hyphens: 1.1.0-beta.1.
    r'\t\t\t\t(?:minimumVersion|version) = [0-9][0-9A-Za-z.\-]*;\n'
    r'\t\t\t\};\n'
    r'\t\t\};\n'
    r'/\* End XCRemoteSwiftPackageReference section \*/'
)

local_pattern = re.compile(
    r'/\* Begin XCLocalSwiftPackageReference section \*/\n'
    r'\t\tBA000001 /\* XCLocalSwiftPackageReference "\.\." \*/ = \{\n'
    r'\t\t\tisa = XCLocalSwiftPackageReference;\n'
    r'\t\t\trelativePath = "?\.\."?;\n'
    r'\t\t\};\n'
    r'/\* End XCLocalSwiftPackageReference section \*/'
)

if local_block in text or local_pattern.search(text):
    result = text
else:
    result, n = remote_pattern.subn(local_block, text, count=1)
    if n == 0:
        print("ERROR: Showcase package reference block not found", file=sys.stderr)
        sys.exit(1)

result = result.replace(
    'BA000001 /* XCRemoteSwiftPackageReference "SwiftVLC" */',
    'BA000001 /* XCLocalSwiftPackageReference ".." */',
)

if result == text:
    sys.exit(0)

fd, tmp = tempfile.mkstemp(dir=".", prefix=".SwiftVLCShowcase.", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        os.fchmod(f.fileno(), os.stat(path).st_mode & 0o7777)
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
  if [[ "$MANIFEST_ONLY" == true ]]; then
    if [[ -n "$VERSION" ]]; then
      echo "Error: --manifest-only cannot be combined with an explicit version." >&2
      exit 2
    fi
    artifact_info=$(python3 "$SCRIPT_DIR/release-artifact-info.py" Package.swift)
  elif [[ -n "$VERSION" ]]; then
    artifact_info=$("$SCRIPT_DIR/resolve-release-artifact.sh" --tag "$VERSION")
  else
    artifact_info=$("$SCRIPT_DIR/resolve-release-artifact.sh")
  fi
  RESOLVED_TAG=$(printf '%s' "$artifact_info" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag"])')
  RESOLVED_DOWNLOAD_TAG=$(printf '%s' "$artifact_info" \
    | python3 -c 'import json,sys; value=json.load(sys.stdin); print(value.get("downloadTag", value["tag"]))')
  RESOLVED_URL=$(printf '%s' "$artifact_info" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["url"])')
  RESOLVED_CHECKSUM=$(printf '%s' "$artifact_info" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["checksum"])')
  RESOLVED_IS_DRAFT=$(printf '%s' "$artifact_info" \
    | python3 -c 'import json,sys; print("true" if json.load(sys.stdin).get("isDraft") else "false")')

  NEED_DOWNLOAD=false
  if [[ ! -d "$XCFW_DIR" ]]; then
    NEED_DOWNLOAD=true
  elif [[ "$RESOLVED_IS_DRAFT" == true ]]; then
    # Candidate CI is release authorization. Vendor/ and its install record are
    # restored from the same unsigned Actions cache, so the record's treeDigest
    # cannot authenticate the adjacent tree: a poisoned cache can forge both.
    # The release commit cryptographically binds only the ZIP checksum. Always
    # redownload and re-extract that exact ZIP for a mutable draft candidate.
    echo "Discarding cached Vendor bytes for draft candidate $RESOLVED_DOWNLOAD_TAG..."
    rm -rf "$XCFW_DIR"
    rm -f "$INSTALL_RECORD"
    NEED_DOWNLOAD=true
  elif [[ "$FORCE" == true ]]; then
    echo "Removing existing $XCFW_DIR (--force)..."
    rm -rf "$XCFW_DIR"
    rm -f "$INSTALL_RECORD"
    NEED_DOWNLOAD=true
  else
    installed_values=$(python3 - "$INSTALL_RECORD" <<'PYEOF' || true
import json
import sys

try:
    record = json.load(open(sys.argv[1]))
    print(record["tag"])
    print(record["checksum"])
    print(record["treeDigest"])
except (OSError, ValueError, KeyError):
    pass
PYEOF
)
    installed_tag=$(printf '%s\n' "$installed_values" | sed -n '1p')
    installed_checksum=$(printf '%s\n' "$installed_values" | sed -n '2p')
    installed_tree_digest=$(printf '%s\n' "$installed_values" | sed -n '3p')
    actual_tree_digest=$("$SCRIPT_DIR/artifact-tree-digest.py" \
      "$XCFW_DIR" 2>/dev/null || true)
    if [[ "$installed_tag" == "$RESOLVED_TAG" \
      && "$installed_checksum" == "$RESOLVED_CHECKSUM" \
      && "$installed_tree_digest" == "$actual_tree_digest" ]]; then
      echo "Keeping verified $RESOLVED_TAG xcframework at $XCFW_DIR."
    else
      echo "Replacing unverified or stale xcframework at $XCFW_DIR..."
      rm -rf "$XCFW_DIR"
      rm -f "$INSTALL_RECORD"
      NEED_DOWNLOAD=true
    fi
  fi

  if [[ "$NEED_DOWNLOAD" == true ]]; then
    mkdir -p Vendor

    echo "Downloading $ZIP_NAME from $RESOLVED_DOWNLOAD_TAG..."
    rm -f "Vendor/$ZIP_NAME"
    if [[ "$RESOLVED_IS_DRAFT" == true || -n "${GH_TOKEN:-}" ]]; then
      # Authenticated gh downloads avoid the shared anonymous runner quota and
      # refresh GitHub's short-lived signed asset URL. The checksum below still
      # authenticates the exact bytes declared by Package.swift.
      require_gh
      gh release download "$RESOLVED_DOWNLOAD_TAG" \
        --repo "$REPO" --pattern "$ZIP_NAME" --dir Vendor/
    else
      # Local public installs remain usable without GitHub authentication.
      curl --disable --fail --location --retry 3 --retry-all-errors \
        --output "Vendor/$ZIP_NAME" "$RESOLVED_URL"
    fi

    downloaded_checksum=$(swift package compute-checksum "Vendor/$ZIP_NAME")
    if [[ "$downloaded_checksum" != "$RESOLVED_CHECKSUM" ]]; then
      rm -f "Vendor/$ZIP_NAME"
      echo "Error: downloaded asset checksum does not match $RESOLVED_TAG." >&2
      echo "  expected: $RESOLVED_CHECKSUM" >&2
      echo "  actual:   $downloaded_checksum" >&2
      exit 1
    fi

    echo "Extracting..."
    (cd Vendor && ditto -x -k "$ZIP_NAME" . && rm "$ZIP_NAME")
    echo "  Installed to $XCFW_DIR"

    # A release asset is immutable input. It was fixed before packaging; doing
    # another mutation here would make CI test bytes consumers never receive.
    echo "Verifying duplicate symbols in released libraries..."
    "$SCRIPT_DIR/fix-duplicate-symbols.sh" --verify "$XCFW_DIR"

    RESOLVED_TREE_DIGEST=$("$SCRIPT_DIR/artifact-tree-digest.py" "$XCFW_DIR")

    RESOLVED_TAG="$RESOLVED_TAG" \
      RESOLVED_URL="$RESOLVED_URL" \
      RESOLVED_CHECKSUM="$RESOLVED_CHECKSUM" \
      RESOLVED_TREE_DIGEST="$RESOLVED_TREE_DIGEST" \
      INSTALL_RECORD="$INSTALL_RECORD" \
      python3 - <<'PYEOF'
import json
import os

record = {
    "tag": os.environ["RESOLVED_TAG"],
    "url": os.environ["RESOLVED_URL"],
    "checksum": os.environ["RESOLVED_CHECKSUM"],
    "treeDigest": os.environ["RESOLVED_TREE_DIGEST"],
}
with open(os.environ["INSTALL_RECORD"], "w") as output:
    json.dump(record, output, indent=2, sort_keys=True)
    output.write("\n")
PYEOF
  fi
fi

# ── Flip Package.swift to local path ──────────────────────────────────────────

if [[ "$ARTIFACT_ONLY" == true ]]; then
  echo "Artifact is ready at $XCFW_DIR."
  exit 0
fi

echo "Pointing Package.swift at $XCFW_DIR..."
switch_package_to_local_path
echo "  Package.swift now uses local path."

echo "Pointing Showcase app at the local Swift package checkout..."
switch_showcase_to_local_package
echo "  Showcase now uses the repo-local package."

echo ""
echo "Done. Try:"
echo "  swift build"
echo "  swift test"
