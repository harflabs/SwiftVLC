#!/usr/bin/env bash
#
# check-qualification.sh — refuse to release an xcframework whose physical-device
# qualification is missing, stale, or incomplete.
#
# Issue 88: simulator and wrapper-only coverage cannot validate system PiP,
# native video output, audio teardown, or real libVLC playback. CI compiles the
# iOS tests but never executes system PiP on hardware, and the sanitizer job
# links a released xcframework rather than the engine under test. So the device
# matrix is the acceptance gate, and nothing enforced it.
#
# This does not run the tests — a person does, on hardware. What it enforces is
# that the results exist, that every required row was executed and passed, and
# that they describe *this* artifact rather than an earlier one.
#
# The artifact is identified by a digest over the complete XCFramework tree,
# including libraries, headers, metadata, paths, and modes. Header/ABI drift is
# release-significant even when the static archive bytes are unchanged.
#
# Usage:
#   ./scripts/check-qualification.sh <version> [xcframework-path]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${1:-}"
XCFW="${2:-Vendor/libvlc.xcframework}"
MATRIX="${SWIFTVLC_QUALIFICATION_MATRIX:-$SCRIPT_DIR/qualification/matrix.json}"
RECORD="${SWIFTVLC_QUALIFICATION_RECORD:-$SCRIPT_DIR/qualification/${VERSION}.json}"

if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version> [xcframework-path]" >&2
  exit 2
fi

if [[ ! -d "$XCFW" ]]; then
  echo "Error: $XCFW not found." >&2
  exit 1
fi

if [[ ! -f "$MATRIX" ]]; then
  echo "Error: $MATRIX not found; the required rows are undefined." >&2
  exit 1
fi

artifact_digest() {
  python3 "$SCRIPT_DIR/artifact-tree-digest.py" "$XCFW"
}

# An xcframework with no static libraries would still produce a stable digest —
# shasum of empty input — so a record could be written that "qualifies" an
# artifact containing nothing. Refuse before computing anything.
SLICE_COUNT=$(find "$XCFW" -name '*.a' -type f | grep -c . || true)
if [[ "$SLICE_COUNT" -eq 0 ]]; then
  echo "Error: $XCFW contains no static libraries." >&2
  echo "  Nothing to qualify. Rebuild with ./scripts/build-libvlc.sh --all." >&2
  exit 1
fi

DIGEST="$(artifact_digest)"

if [[ ! -f "$RECORD" ]]; then
  echo "Error: no device qualification record for $VERSION." >&2
  echo "  Expected: $RECORD" >&2
  echo "  Artifact digest: $DIGEST" >&2
  echo "" >&2
  echo "  The device matrix is the acceptance gate for system PiP; CI cannot" >&2
  echo "  stand in for it. Run the matrix on hardware and record the results," >&2
  echo "  then release. See scripts/qualification/README.md." >&2
  exit 1
fi

python3 - "$MATRIX" "$RECORD" "$DIGEST" "$VERSION" <<'PY'
import json
import sys
from pathlib import Path

matrix_path, record_path, digest, version = sys.argv[1:5]

try:
    matrix = json.load(open(matrix_path))
    record = json.load(open(record_path))
except (OSError, ValueError) as error:
    sys.exit(f"Error: cannot read qualification input: {error}")

problems = []

recorded = record.get("artifactDigest")
if recorded != digest:
    problems.append(
        "the record describes a different artifact\n"
        f"    recorded:   {recorded}\n"
        f"    on disk:    {digest}\n"
        "    A device run only qualifies the binary it was run against. Rebuild\n"
        "    or re-run the matrix, whichever is actually stale."
    )

if record.get("version") != version:
    problems.append(
        f"the record is for version {record.get('version')!r}, not {version!r}"
    )

if record.get("artifactDigestAlgorithm") != "swiftvlc-tree-v1":
    problems.append(
        "the record does not declare artifactDigestAlgorithm "
        "'swiftvlc-tree-v1'"
    )

required = {
    (s["id"], h["id"])
    for s in matrix["scenarios"]
    for h in matrix["hardware"]
}

rows = record.get("rows")
if not isinstance(rows, list):
    sys.exit(f"Error: {record_path} has no 'rows' array.")

executed = {}
duplicates = []
for index, row in enumerate(rows):
    if not isinstance(row, dict):
        problems.append(f"row {index} is not an object")
        continue
    key = (row.get("scenario"), row.get("hardware"))
    if key in executed:
        # Last-wins would let a failing row be masked by appending a passing
        # duplicate, which defeats the point of the gate.
        duplicates.append(key)
    executed[key] = row

if duplicates:
    listed = "\n".join(f"      {s} on {h}" for s, h in sorted(set(duplicates)))
    problems.append(
        f"{len(set(duplicates))} row(s) appear more than once:\n{listed}\n"
        "    A duplicate can hide an earlier failure behind a later pass."
    )

missing = sorted(required - set(executed))
if missing:
    listed = "\n".join(f"      {s} on {h}" for s, h in missing)
    problems.append(f"{len(missing)} required row(s) were never executed:\n{listed}")

failed = sorted(
    key for key, row in executed.items()
    if key in required and row.get("result") != "pass"
)
if failed:
    listed = "\n".join(
        f"      {s} on {h}: {executed[(s, h)].get('result')!r}" for s, h in failed
    )
    problems.append(f"{len(failed)} required row(s) did not pass:\n{listed}")

# Fields the criteria call for on every row. A row missing them is not a record
# of anything reproducible.
hardware_by_id = {hardware["id"]: hardware for hardware in matrix["hardware"]}
for key in sorted(executed):
    if key not in required:
        continue
    row = executed[key]
    for field in (
        "device",
        "deviceFamily",
        "productType",
        "osVersion",
        "osBuild",
        "osReleaseType",
        "fixture",
        "duration",
        "evidence",
        "result",
    ):
        if not row.get(field):
            problems.append(f"row {key[0]} on {key[1]} is missing {field!r}")

    hardware = hardware_by_id[key[1]]
    if row.get("deviceFamily") != hardware["deviceFamily"]:
        problems.append(
            f"row {key[0]} on {key[1]} records deviceFamily "
            f"{row.get('deviceFamily')!r}, expected {hardware['deviceFamily']!r}"
        )
    try:
        os_major = int(str(row.get("osVersion", "")).split(".", 1)[0])
    except ValueError:
        os_major = None
    if os_major != hardware["osMajor"]:
        problems.append(
            f"row {key[0]} on {key[1]} records OS {row.get('osVersion')!r}, "
            f"expected major version {hardware['osMajor']}"
        )
    if row.get("osReleaseType") != "stable":
        problems.append(
            f"row {key[0]} on {key[1]} uses {row.get('osReleaseType')!r} OS "
            "software; release qualification requires a stable OS build"
        )
    evidence = row.get("evidence")
    if evidence:
        evidence_path = Path(evidence)
        if evidence_path.is_absolute() or ".." in evidence_path.parts:
            problems.append(
                f"row {key[0]} on {key[1]} evidence must be a safe path "
                "relative to the qualification record"
            )
        elif not (Path(record_path).parent / evidence_path).is_file():
            problems.append(
                f"row {key[0]} on {key[1]} evidence file does not exist: "
                f"{evidence}"
            )

if problems:
    print(f"Error: {version} is not qualified for release.", file=sys.stderr)
    for problem in problems:
        print(f"  - {problem}", file=sys.stderr)
    sys.exit(1)

print(
    f"Device qualification verified: {len(required)} rows executed and passing "
    f"for artifact {digest[:12]}…"
)
PY
