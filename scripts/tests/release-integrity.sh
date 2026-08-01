#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/swiftvlc-release-tests.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

checksum="03a57454a6159c455406889c7867e0b284db028d2734a10bdf85a6a7285c862f"
cat > "$temp_dir/Package.swift" <<EOF
let package = Package(targets: [
  .binaryTarget(
    name: "libvlc",
    url: "https://github.com/harflabs/SwiftVLC/releases/download/v1.1.0-beta.1/libvlc.xcframework.zip",
    checksum: "$checksum"
  )
])
EOF

resolved_tag=$(python3 "$SCRIPT_DIR/release-artifact-info.py" \
  "$temp_dir/Package.swift" --field tag)
[[ "$resolved_tag" == "v1.1.0-beta.1" ]] || fail "pre-release tag was not parsed"

python3 "$SCRIPT_DIR/release-artifact-info.py" \
  "$temp_dir/Package.swift" --expect-tag v1.1.0-beta.1 >/dev/null
if python3 "$SCRIPT_DIR/release-artifact-info.py" \
  "$temp_dir/Package.swift" --expect-tag v1.1.0 >/dev/null 2>&1; then
  fail "mismatched expected tag was accepted"
fi

sed 's#url: "https://[^\"]*"#path: "Vendor/libvlc.xcframework"#' \
  "$temp_dir/Package.swift" > "$temp_dir/LocalPackage.swift"
if python3 "$SCRIPT_DIR/release-artifact-info.py" \
  "$temp_dir/LocalPackage.swift" >/dev/null 2>&1; then
  fail "local binary target was treated as a released artifact"
fi

mkdir -p "$temp_dir/tree-a/Headers" "$temp_dir/tree-b/Headers"
printf 'binary' > "$temp_dir/tree-a/libvlc.a"
printf 'header' > "$temp_dir/tree-a/Headers/libvlc.h"
cp -R "$temp_dir/tree-a/." "$temp_dir/tree-b/"

digest_a=$("$SCRIPT_DIR/artifact-tree-digest.py" "$temp_dir/tree-a")
digest_b=$("$SCRIPT_DIR/artifact-tree-digest.py" "$temp_dir/tree-b")
[[ "$digest_a" == "$digest_b" ]] || fail "digest depends on the artifact root path"

touch -t 202001010000 "$temp_dir/tree-b/Headers/libvlc.h"
digest_b=$("$SCRIPT_DIR/artifact-tree-digest.py" "$temp_dir/tree-b")
[[ "$digest_a" == "$digest_b" ]] || fail "digest depends on file timestamps"

printf 'changed header' > "$temp_dir/tree-b/Headers/libvlc.h"
digest_b=$("$SCRIPT_DIR/artifact-tree-digest.py" "$temp_dir/tree-b")
[[ "$digest_a" != "$digest_b" ]] || fail "header changes do not affect the digest"

python3 - "$temp_dir/matrix.json" "$temp_dir/record.json" "$digest_a" <<'PY'
import json
import sys

matrix_path, record_path, digest = sys.argv[1:4]
open(str(record_path).rsplit("/", 1)[0] + "/evidence.json", "w").write("{}\n")
matrix = {
    "scenarios": [{"id": "vod"}],
    "hardware": [
        {"id": "iphone-current", "deviceFamily": "iPhone", "osMajor": 26}
    ],
}
record = {
    "version": "1.1.0",
    "artifactDigestAlgorithm": "swiftvlc-tree-v1",
    "artifactDigest": digest,
    "rows": [
        {
            "scenario": "vod",
            "hardware": "iphone-current",
            "device": "Test phone",
            "deviceFamily": "iPhone",
            "productType": "iPhone16,1",
            "osVersion": "26.6",
            "osBuild": "23G80",
            "osReleaseType": "stable",
            "fixture": "fixture.mp4",
            "duration": "2m",
            "evidence": "evidence.json",
            "result": "pass",
        }
    ],
}
json.dump(matrix, open(matrix_path, "w"))
json.dump(record, open(record_path, "w"))
PY

SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null

if SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-b" >/dev/null 2>&1; then
  fail "qualification survived a header change"
fi

python3 - "$temp_dir/record.json" <<'PY'
import json
import sys

path = sys.argv[1]
record = json.load(open(path))
record["rows"][0]["osReleaseType"] = "beta"
json.dump(record, open(path, "w"))
PY
if SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification accepted a beta OS row"
fi

cd "$ROOT_DIR"
bash -n \
  scripts/check-engine-coverage.sh \
  scripts/check-qualification.sh \
  scripts/ci-use-released-xcframework.sh \
  scripts/release.sh \
  scripts/resolve-release-artifact.sh \
  scripts/setup-dev.sh

# GitHub's macOS runners still execute these scripts with Bash 3.2. An empty
# array expansion under nounset fails there even though newer Bash accepts it.
if grep -En '\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]\}' scripts/setup-dev.sh >/dev/null; then
  fail "setup-dev.sh contains an array expansion that is unsafe under Bash 3.2 nounset"
fi

artifact_info=$(./scripts/resolve-release-artifact.sh)
actual_tag=$(printf '%s' "$artifact_info" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag"])')
[[ "$actual_tag" == "v1.1.0-beta.1" ]] \
  || fail "checkout resolved $actual_tag instead of v1.1.0-beta.1"

stable_info=$(SWIFTVLC_RELEASE_TAG=v1.0.0 ./scripts/resolve-release-artifact.sh)
stable_tag=$(printf '%s' "$stable_info" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag"])')
[[ "$stable_tag" == "v1.0.0" ]] \
  || fail "explicit release override resolved $stable_tag instead of v1.0.0"

if ./scripts/release.sh 1.1.0 >/dev/null 2>&1; then
  fail "stable release was accepted without a prepared candidate"
fi

echo "Release-integrity tests passed."
