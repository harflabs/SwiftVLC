#!/usr/bin/env bash
#
# check-engine-coverage.sh — report which engine patches CI is not testing.
#
# CI does not build libVLC. `ci-use-released-xcframework.sh` rewrites
# Package.swift to the exact release declared by the checkout (or by
# SWIFTVLC_RELEASE_TAG), so every test job links a known engine candidate.
#
# The consequence is easy to miss. A patch added to scripts/patches/ after that
# release is present in the source tree and absent from the binary under test,
# so it can change libVLC behaviour while every gate stays green.
#
# That already happened. Patch 0007 changed `libvlc_media_player_get_media()`
# to report the media the player core is using rather than the one last set.
# Three tests depended on the old semantics and passed CI for as long as the
# gap existed, failing the moment the suite ran against the patched engine.
#
# Non-blocking by design. Patches legitimately land before the release that
# carries them, so failing here would wedge every PR. This emits warning
# annotations instead, so the divergence is visible on the PR rather than
# silent.
#
# Usage:
#   ./scripts/check-engine-coverage.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

PATCHES_DIR="scripts/patches"

annotate() {
  # GitHub renders `::warning::` on the PR; elsewhere it is just a line.
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::warning title=Engine patch not covered by CI::$1"
  else
    echo "WARNING: $1"
  fi
}

artifact_info=$("$SCRIPT_DIR/resolve-release-artifact.sh" 2>/dev/null || true)
if [ -z "$artifact_info" ]; then
  echo "Could not resolve the checkout's engine release; skipping coverage check." >&2
  exit 0
fi
tag=$(printf '%s' "$artifact_info" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag"])')

if ! git rev-parse -q --verify "$tag^{commit}" >/dev/null; then
  echo "Tag $tag is not available locally; skipping coverage check." >&2
  exit 0
fi

# Basenames stripped in the pipeline rather than through `xargs basename`,
# which needs a guard for empty input and is the only `xargs` in scripts/.
released=$(git ls-tree --name-only "$tag" "$PATCHES_DIR/" 2>/dev/null \
  | grep '\.patch$' | sed 's#.*/##' | sort || true)
current=$(find "$PATCHES_DIR" -maxdepth 1 -type f -name '*.patch' | sed 's#.*/##' | sort)

uncovered=$(comm -13 <(printf '%s\n' "$released") <(printf '%s\n' "$current"))

echo "Engine under test: $tag"
echo "Patches in tree:   $(printf '%s\n' "$current" | grep -c . || true)"
echo "Patches at $tag:   $(printf '%s\n' "$released" | grep -c . || true)"

if [ -z "$uncovered" ]; then
  echo "Every engine patch is covered by the release CI links."
  exit 0
fi

count=$(printf '%s\n' "$uncovered" | grep -c .)
echo
echo "$count patch(es) are in the tree but not in the engine CI links:"

# Read loop rather than an unquoted expansion: word splitting and globbing
# would mangle any patch name containing whitespace or a glob character.
names=""
while IFS= read -r patch; do
  [ -n "$patch" ] || continue
  echo "  $patch"
  names="${names:+$names }$patch"
done <<EOF
$uncovered
EOF

annotate "$count engine patch(es) are not in the binary CI tests against ($tag). Behaviour they change is untested until a release carries them: $names"

# Always succeeds. See the header for why.
exit 0
