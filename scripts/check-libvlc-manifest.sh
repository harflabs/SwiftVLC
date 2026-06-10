#!/usr/bin/env bash
#
# Verifies that the archive members of every libvlc.a slice in
# Vendor/libvlc.xcframework match the manifests checked in under
# scripts/libvlc-manifests/. A rebuilt binary that silently drops or
# gains plugins/objects in one slice (e.g. the tvOS slice losing or
# growing the Chromecast plugin stack) shows up as a manifest diff.
#
# Regenerate a manifest after an intentional rebuild with:
#   ./scripts/check-libvlc-manifest.sh --write
#
# Member lists are computed per architecture (fat archives are thinned
# with lipo first, since `ar t` rejects universal files); each line is
# "<arch> <member>", sorted with LC_ALL=C.

set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
xcframework="$repo_root/Vendor/libvlc.xcframework"
manifests="$repo_root/scripts/libvlc-manifests"

write_mode=false
if [ "${1:-}" = "--write" ]; then
  write_mode=true
fi

if [ ! -d "$xcframework" ]; then
  echo "error: $xcframework not found — run ./scripts/setup-dev.sh first" >&2
  exit 1
fi

# Prints "<arch> <member>" lines for every architecture in the archive,
# sorted bytewise so the output is stable across machines.
list_members() {
  local archive=$1
  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' RETURN

  local archs
  archs=$(lipo -archs "$archive")

  local arch thin
  for arch in $archs; do
    if [ "$(echo "$archs" | wc -w)" -gt 1 ]; then
      thin="$tmpdir/$arch.a"
      lipo -thin "$arch" -output "$thin" "$archive"
    else
      thin="$archive"
    fi
    ar t "$thin" | sed "s/^/$arch /"
  done | LC_ALL=C sort
}

failures=0

for slice_dir in "$xcframework"/*/; do
  slice=$(basename "$slice_dir")
  archive="$slice_dir/libvlc.a"
  [ -f "$archive" ] || continue
  manifest="$manifests/$slice.txt"

  if $write_mode; then
    mkdir -p "$manifests"
    list_members "$archive" > "$manifest"
    echo "WROTE $slice ($(wc -l < "$manifest" | tr -d ' ') members)"
    continue
  fi

  if [ ! -f "$manifest" ]; then
    echo "FAIL  $slice — manifest missing at scripts/libvlc-manifests/$slice.txt"
    failures=$((failures + 1))
    continue
  fi

  if diff -u "$manifest" <(list_members "$archive"); then
    echo "PASS  $slice"
  else
    echo "FAIL  $slice — archive members differ from checked-in manifest"
    failures=$((failures + 1))
  fi
done

# A manifest with no corresponding slice means the xcframework lost a
# whole platform slice (or the manifest is stale) — fail either way.
if ! $write_mode; then
  for manifest in "$manifests"/*.txt; do
    [ -f "$manifest" ] || continue
    slice=$(basename "$manifest" .txt)
    if [ ! -f "$xcframework/$slice/libvlc.a" ]; then
      echo "FAIL  $slice — manifest exists but slice is absent from the xcframework"
      failures=$((failures + 1))
    fi
  done

  if [ "$failures" -gt 0 ]; then
    echo "libvlc manifest check failed ($failures problem(s))"
    exit 1
  fi
  echo "libvlc manifest check passed"
fi
