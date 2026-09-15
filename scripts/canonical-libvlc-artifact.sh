#!/usr/bin/env bash
# Copy and archive a proven libVLC XCFramework without host filesystem metadata.
#
# Provenance intentionally identifies the logical artifact tree: relative paths,
# entry kinds, POSIX modes, file bytes, and symlink targets. Resource forks,
# extended attributes, ACLs, ownership, and mtimes are outside that identity.
# This helper prevents those excluded fields from making the release ZIP depend
# on which Mac or volume staged it, while preserving and re-verifying everything
# that provenance does cover.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<'EOF'
Usage:
  canonical-libvlc-artifact.sh stage SOURCE_XCFRAMEWORK DESTINATION PROVENANCE
  canonical-libvlc-artifact.sh archive STAGED_XCFRAMEWORK OUTPUT_ZIP PROVENANCE
EOF
}

fail() {
  echo "Error: $1" >&2
  exit 1
}

if [[ $# -ne 4 ]]; then
  usage >&2
  exit 2
fi

command_name=$1
source_path=$2
output_path=$3
provenance_path=$4

if [[ ! -d "$source_path" ]]; then
  fail "XCFramework source not found: $source_path"
fi
if [[ ! -f "$provenance_path" ]]; then
  fail "libVLC provenance not found: $provenance_path"
fi

provenance_identity=$(python3 - "$provenance_path" <<'PY'
import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])


def unique_object(pairs):
    output = {}
    for key, value in pairs:
        if key in output:
            raise ValueError(f"duplicate JSON key: {key!r}")
        output[key] = value
    return output


def reject_constant(value):
    raise ValueError(f"non-finite JSON number: {value}")


try:
    value = json.loads(
        path.read_text(),
        object_pairs_hook=unique_object,
        parse_constant=reject_constant,
    )
except (OSError, ValueError) as error:
    raise SystemExit(f"Error: cannot read provenance {path}: {error}")

if not isinstance(value, dict):
    raise SystemExit(f"Error: {path} is not a libVLC provenance object")
if type(value.get("schemaVersion")) is not int or value["schemaVersion"] != 4:
    raise SystemExit(f"Error: {path} is not libVLC provenance schema 4")
revision = value.get("swiftVLCRevision")
if not isinstance(revision, str) or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
    raise SystemExit(f"Error: {path} has an invalid SwiftVLC revision")
build = value.get("build")
if not isinstance(build, dict):
    raise SystemExit(f"Error: {path} has an invalid build record")
epoch = build.get("sourceDateEpoch")
digest = value.get("xcframeworkTreeDigest")
if isinstance(epoch, bool) or not isinstance(epoch, int) or epoch < 0:
    raise SystemExit(f"Error: {path} has an invalid sourceDateEpoch")
if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
    raise SystemExit(f"Error: {path} has an invalid XCFramework tree digest")
print(epoch, digest)
PY
)
read -r source_date_epoch expected_tree_digest <<< "$provenance_identity"

verify_logical_tree() {
  local tree=$1
  local actual
  actual=$("$SCRIPT_DIR/artifact-tree-digest.py" "$tree")
  if [[ "$actual" != "$expected_tree_digest" ]]; then
    fail "XCFramework logical tree does not match provenance: $tree"
  fi
}

normalize_archive_metadata() {
  local tree=$1
  # The root mode is not part of the path-relative tree digest, but it is a ZIP
  # entry. Give it one deterministic value before archiving.
  chmod 0755 "$tree"
  python3 - "$tree" "$source_date_epoch" <<'PY'
import os
import sys
from pathlib import Path

root = Path(sys.argv[1])
epoch = int(sys.argv[2])

# Touch children before parents because changing a child can update its parent
# directory mtime. Do not follow symlinks: their targets are artifact content.
paths = sorted(
    root.rglob("*"),
    key=lambda path: len(path.relative_to(root).parts),
    reverse=True,
)
for path in [*paths, root]:
    os.utime(path, (epoch, epoch), follow_symlinks=False)
PY
}

case "$command_name" in
  stage)
    if [[ -e "$output_path" || -L "$output_path" ]]; then
      fail "stage destination already exists: $output_path"
    fi
    output_parent=$(dirname "$output_path")
    mkdir -p "$output_parent"
    output_parent=$(cd "$output_parent" && pwd)
    output_name=$(basename "$output_path")
    temporary=$(mktemp -d "$output_parent/.swiftvlc-libvlc-stage.XXXXXX")
    staged="$temporary/$output_name"
    cleanup() {
      rm -rf -- "$temporary"
    }
    trap cleanup EXIT

    verify_logical_tree "$source_path"
    ditto --norsrc --noextattr --noqtn --noacl --nopersistRootless \
      "$source_path" "$staged"
    # macOS 27 ditto can clone APFS extended attributes despite --noextattr.
    # Scrub the new staging tree explicitly; -s treats symlinks themselves.
    xattr -crs "$staged"
    chmod -RN "$staged"
    verify_logical_tree "$staged"
    # Verification reads every file and may advance atime. Normalize only after
    # that final logical-tree read so staging has deterministic metadata.
    normalize_archive_metadata "$staged"
    mv "$staged" "$output_parent/$output_name"
    rmdir "$temporary"
    trap - EXIT
    ;;

  archive)
    if [[ -e "$output_path" || -L "$output_path" ]]; then
      fail "archive destination already exists: $output_path"
    fi
    output_parent=$(dirname "$output_path")
    mkdir -p "$output_parent"
    output_parent=$(cd "$output_parent" && pwd)
    output_name=$(basename "$output_path")
    temporary=$(mktemp -d "$output_parent/.swiftvlc-libvlc-archive.XXXXXX")
    temporary_zip="$temporary/$output_name"
    cleanup() {
      rm -rf -- "$temporary"
    }
    trap cleanup EXIT

    source_parent=$(cd "$(dirname "$source_path")" && pwd)
    source_name=$(basename "$source_path")
    verify_logical_tree "$source_path"
    # Nothing may read the source tree between this final normalization and
    # zip. -X omits UID/GID and timestamp extra fields; TZ makes its portable
    # DOS timestamp independent of the release Mac's local time zone.
    normalize_archive_metadata "$source_path"
    (
      cd "$source_parent"
      COPYFILE_DISABLE=1 LC_ALL=C TZ=UTC \
        /usr/bin/zip -q -r -X -y "$temporary_zip" "$source_name"
    )
    mv "$temporary_zip" "$output_parent/$output_name"
    rmdir "$temporary"
    trap - EXIT
    ;;

  *)
    usage >&2
    exit 2
    ;;
esac
