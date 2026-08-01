#!/usr/bin/env bash
# Resolve and verify the exact released libvlc artifact this checkout declares.
set -euo pipefail

REPO="harflabs/SwiftVLC"
ASSET_NAME="libvlc.xcframework.zip"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TAG="${SWIFTVLC_RELEASE_TAG:-}"

usage() {
  echo "Usage: $0 [--tag vX.Y.Z]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      TAG="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown argument '$1'." >&2
      usage
      exit 2
      ;;
  esac
done

cd "$ROOT_DIR"

if [[ -z "$TAG" ]]; then
  if ! TAG=$(python3 "$SCRIPT_DIR/release-artifact-info.py" Package.swift --field tag); then
    echo "  Supply --tag or SWIFTVLC_RELEASE_TAG when Package.swift uses a local artifact." >&2
    exit 1
  fi
fi

if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Error: invalid release tag '$TAG'." >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: GitHub CLI (gh) is required to verify release metadata." >&2
  exit 1
fi

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/swiftvlc-artifact.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT

# Shallow Actions checkouts do not have release tags. Refuse a fetch failure:
# silently falling back to another release is the bug this resolver prevents.
git fetch --quiet origin "refs/tags/$TAG:refs/tags/$TAG"
git show "$TAG:Package.swift" > "$temp_dir/Package.swift"
python3 "$SCRIPT_DIR/release-artifact-info.py" \
  "$temp_dir/Package.swift" --expect-tag "$TAG" > "$temp_dir/manifest.json"

gh release view "$TAG" --repo "$REPO" \
  --json tagName,isDraft,isPrerelease,assets > "$temp_dir/release.json"

python3 - "$temp_dir/manifest.json" "$temp_dir/release.json" "$ASSET_NAME" <<'PY'
import json
import sys

manifest_path, release_path, asset_name = sys.argv[1:4]
manifest = json.load(open(manifest_path))
release = json.load(open(release_path))

if release.get("tagName") != manifest["tag"]:
    sys.exit(
        f"Error: GitHub returned release {release.get('tagName')!r}, "
        f"expected {manifest['tag']!r}."
    )
if release.get("isDraft"):
    sys.exit(f"Error: {manifest['tag']} is still a draft release.")

matches = [asset for asset in release.get("assets", []) if asset.get("name") == asset_name]
if len(matches) != 1:
    sys.exit(
        f"Error: {manifest['tag']} must contain exactly one {asset_name}; "
        f"found {len(matches)}."
    )

asset = matches[0]
expected_digest = f"sha256:{manifest['checksum']}"
if asset.get("digest") != expected_digest:
    sys.exit(
        "Error: release asset digest does not match the tagged Package.swift.\n"
        f"  manifest: {expected_digest}\n"
        f"  asset:    {asset.get('digest')}"
    )
if asset.get("url") != manifest["url"]:
    sys.exit(
        "Error: release asset URL does not match the tagged Package.swift.\n"
        f"  manifest: {manifest['url']}\n"
        f"  asset:    {asset.get('url')}"
    )

manifest["isPrerelease"] = bool(release.get("isPrerelease"))
manifest["size"] = asset.get("size")
print(json.dumps(manifest, sort_keys=True))
PY
