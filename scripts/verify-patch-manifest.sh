#!/usr/bin/env bash
#
# Verifies scripts/patches against its committed manifest and prints the patch
# filenames in manifest order, one per line.
#
# The engine xcframework is the one artifact a consumer cannot inspect the
# inputs of, so "which patches produced this binary?" has to be answerable from
# the repository rather than from whatever happened to be on the builder's disk.
# Applying a glob of `*.patch` could not answer it: an untracked file dropped
# into the directory would be applied and shipped without appearing anywhere in
# history. That is issue #97's first acceptance criterion.
#
# Three ways to fail, all fatal:
#   - a patch file present but not listed  (the untracked-patch case)
#   - a listed patch missing from disk      (an incomplete checkout)
#   - a hash mismatch                       (a patch edited after listing)
#
# The manifest also fixes the *order* explicitly. Glob order happens to match
# the numeric prefixes today, but that is a property of the filenames rather
# than a stated contract, and this series depends on order — 0011 exists only
# to give 0014 the context it needs.
#
# Usage:
#   ./scripts/verify-patch-manifest.sh [patches-dir]
#   ./scripts/verify-patch-manifest.sh --update [patches-dir]   # rewrite hashes
#
# Exit codes:
#   0 — the directory matches the manifest; ordered filenames on stdout
#   1 — a mismatch, described on stderr

set -uo pipefail

MANIFEST_NAME="manifest.sha256"
UPDATE=no

if [ "${1:-}" = "--update" ]; then
  UPDATE=yes
  shift
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHES_DIR="${1:-${SCRIPT_DIR}/patches}"
MANIFEST="${PATCHES_DIR}/${MANIFEST_NAME}"

fail() {
  echo "error: $*" >&2
  exit 1
}

if [ "$UPDATE" = yes ]; then
  # Deliberately separate from verification: regenerating is a decision, not a
  # repair, and a build must never do it implicitly.
  #
  # Built in a temporary file and moved into place only once it is complete and
  # non-empty. Writing directly would truncate a good manifest the moment this
  # is pointed at the wrong directory — turning a typo into a silently
  # unguarded patch set, which is the failure this whole script exists to
  # prevent.
  [ -d "$PATCHES_DIR" ] || fail "patch directory not found: ${PATCHES_DIR}"

  staged=$(mktemp "${TMPDIR:-/tmp}/swiftvlc-manifest.XXXXXX") \
    || fail "could not create a temporary file"
  trap 'rm -f "$staged"' EXIT

  count=0
  for path in "${PATCHES_DIR}"/*.patch; do
    [ -f "$path" ] || continue
    printf '%s  %s\n' "$(shasum -a 256 "$path" | cut -d' ' -f1)" "$(basename "$path")" >> "$staged" \
      || fail "could not write the staged manifest"
    count=$((count + 1))
  done

  [ "$count" -gt 0 ] || fail "no *.patch files in ${PATCHES_DIR}; refusing to write an empty manifest"

  mv "$staged" "$MANIFEST" || fail "could not write ${MANIFEST}"
  trap - EXIT
  echo "Wrote ${MANIFEST} (${count} patches)" >&2
  exit 0
fi

[ -d "$PATCHES_DIR" ] || fail "patch directory not found: ${PATCHES_DIR}"
[ -f "$MANIFEST" ] || fail "patch manifest not found: ${MANIFEST}"

listed=()
while read -r expected name; do
  [ -n "${name:-}" ] || continue
  case "$expected" in \#*) continue ;; esac
  path="${PATCHES_DIR}/${name}"
  [ -f "$path" ] || fail "manifest lists a patch that does not exist: ${name}"
  actual=$(shasum -a 256 "$path" | cut -d' ' -f1)
  if [ "$actual" != "$expected" ]; then
    fail "patch ${name} does not match the manifest.
  expected ${expected}
  actual   ${actual}
If the change is intended, re-run with --update and commit the result."
  fi
  listed+=("$name")
done < "$MANIFEST"

[ "${#listed[@]}" -gt 0 ] || fail "patch manifest is empty: ${MANIFEST}"

# The other direction: nothing on disk may be absent from the manifest.
for path in "${PATCHES_DIR}"/*.patch; do
  [ -f "$path" ] || continue
  present=$(basename "$path")
  found=no
  for name in "${listed[@]}"; do
    [ "$name" = "$present" ] && { found=yes; break; }
  done
  [ "$found" = yes ] || fail "patch ${present} is not listed in ${MANIFEST_NAME}.
An unlisted patch would change the shipped binary without appearing in release
history. Re-run with --update and commit the result if it belongs in the series."
done

printf '%s\n' "${listed[@]}"
