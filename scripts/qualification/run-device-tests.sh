#!/usr/bin/env bash
set -euo pipefail

# Imported qualification modules are source inputs, not build artifacts.
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

VERSION=""
DEVICE_SELECTOR=""
DEVELOPMENT_TEAM="${SWIFTVLC_DEVELOPMENT_TEAM:-}"
CANDIDATE_APP=""
CANDIDATE_METADATA=""
XCTESTRUN_OVERRIDE=""
DERIVED_DATA="${SWIFTVLC_DEVICE_DERIVED_DATA:-$ROOT_DIR/.device-test-build}"
FIXTURES="${SWIFTVLC_DEVICE_FIXTURES:-$ROOT_DIR/.qualification-fixtures}"
OUTPUT_ROOT="${SWIFTVLC_DEVICE_RESULTS:-$ROOT_DIR/.qualification-results}"
WORK_ROOT="${SWIFTVLC_DEVICE_WORK_ROOT:-$ROOT_DIR/.qualification-work}"
REQUIRE_STABLE=false
EXPLORATORY_CURRENT_ONLY=false
EXPLORATORY_HARDWARE_ID=""
SKIP_BUILD=false
FULL_SUITE_SELECTION=false
ORCHESTRATOR_SESSION_BINDING=""
ORCHESTRATOR_STARTED_AT_UTC=""
ONLY_SCENARIOS=()
ADAPTIVE_SOAK_SECONDS="${SWIFTVLC_ADAPTIVE_SOAK_SECONDS:-7200}"
PIP_PERFORMANCE_SECONDS="${SWIFTVLC_PIP_PERFORMANCE_SECONDS:-900}"
CADENCE_SECONDS="${SWIFTVLC_CADENCE_SECONDS:-600}"
NATIVE_SUBTITLE_SECONDS="${SWIFTVLC_NATIVE_SUBTITLE_SECONDS:-900}"
TIMEBASE_SOAK_SECONDS="${SWIFTVLC_TIMEBASE_SOAK_SECONDS:-7200}"
CADENCE_SEMANTICS_PROBE_XCTEST_ALLOWANCE_SECONDS=420
CADENCE_SEMANTICS_PROBE_IDLE_WATCHDOG_SECONDS=480
CADENCE_SEMANTICS_PROBE_WALL_WATCHDOG_SECONDS=780

usage() {
  cat <<'EOF'
Usage: scripts/qualification/run-device-tests.sh [options]

Runs automated candidate-bound physical iOS smoke tests and captures xcresult,
app-log, fixture-server, device, source, and binary identity evidence.

Options:
  --version VERSION       Exact candidate version (required)
  --device IDENTIFIER     CoreDevice id, UDID, ECID, or exact device name
  --development-team ID  Required for a new build: signs the disposable export
                          with team-scoped bundle IDs (or set the matching env)
  --candidate-app PATH    Prebuilt signed iOS.app to install and test
  --candidate-metadata PATH
                          Source/app identity JSON for a prebuilt candidate
  --xctestrun PATH        Explicit base xctestrun (required when build output
                          contains more than one candidate)
  --derived-data PATH     Signed UI-test runner build directory
  --fixtures PATH         Generated fixture directory
  --output PATH           Evidence output root
  --work-root PATH        Temporary source/work root (default: beside the repo)
  --orchestrator-session-binding SHA256
                          Exact 64-hex handoff binding from qualify.py
  --orchestrator-started-at-utc TIMESTAMP
                          Canonical UTC start of the qualifying orchestrator
  --only SCENARIO         Repeat to select: analyzer, ui-suite, native-live,
                          direct-live, live-media, background-audio,
                          continuity, capability-convergence,
                          vod-controls, long-stall, failed-start, dismissal,
                          interruptions,
                          audio-session-ownership,
                          audio-media-services-reset,
                          native-lifecycle,
                          playback-foreground-displaylayer-recovery,
                          terminal-outcomes,
                          adaptive-hls-soak,
                          pip-render-performance-1080p60,
                          pip-render-performance-4k60,
                          cadence-matrix,
                          cadence-semantics-probe (report-only; never release credit),
                          native-subtitle-matrix,
                          timebase-vod-soak, timebase-live-soak,
                          deferred-pause-rejection,
                          hls-seek, seek-frame-oracles,
                          progressive-http-range-seek, local-file-matrix,
                          audio-only-playback,
                          harness-regressions, ui-failures, thumbnail-preview
  --full-suite-selection  Mark repeated --only arguments as full only when they
                          exactly equal the canonical applicable release suite
  --require-stable        Refuse beta/unknown OS or a non-matching matrix row
  --exploratory-current-only
                          Allow iphone-current-only lanes on a newer iPhone OS;
                          evidence remains exploratory and cannot qualify rows
  --skip-build            Reuse an existing signed runner in derived data
  -h, --help              Show this help

Connecting, unlocking, trusting, and enabling Developer Mode are the ordinary
operator steps. The audio-media-services-reset scenario also pauses for a real
Settings > Developer > Reset Media Services action on the connected iPhone.
A beta OS can run exploratory tests, but never qualifies a release row.
EOF
}

case "$ADAPTIVE_SOAK_SECONDS" in
  ''|*[!0-9]*)
    echo "Error: SWIFTVLC_ADAPTIVE_SOAK_SECONDS must be a positive integer." >&2
    exit 2
    ;;
esac
if [[ "$ADAPTIVE_SOAK_SECONDS" -le 0 ]]; then
  echo "Error: SWIFTVLC_ADAPTIVE_SOAK_SECONDS must be positive." >&2
  exit 2
fi
case "$PIP_PERFORMANCE_SECONDS" in
  ''|*[!0-9]*)
    echo "Error: SWIFTVLC_PIP_PERFORMANCE_SECONDS must be a positive integer." >&2
    exit 2
    ;;
esac
if [[ "$PIP_PERFORMANCE_SECONDS" -le 0 ]]; then
  echo "Error: SWIFTVLC_PIP_PERFORMANCE_SECONDS must be positive." >&2
  exit 2
fi
case "$CADENCE_SECONDS" in
  ''|*[!0-9]*)
    echo "Error: SWIFTVLC_CADENCE_SECONDS must be a positive integer." >&2
    exit 2
    ;;
esac
if [[ "$CADENCE_SECONDS" -le 0 ]]; then
  echo "Error: SWIFTVLC_CADENCE_SECONDS must be positive." >&2
  exit 2
fi
case "$NATIVE_SUBTITLE_SECONDS" in
  ''|*[!0-9]*)
    echo "Error: SWIFTVLC_NATIVE_SUBTITLE_SECONDS must be a positive integer." >&2
    exit 2
    ;;
esac
if [[ "$NATIVE_SUBTITLE_SECONDS" -le 0 ]]; then
  echo "Error: SWIFTVLC_NATIVE_SUBTITLE_SECONDS must be positive." >&2
  exit 2
fi
case "$TIMEBASE_SOAK_SECONDS" in
  ''|*[!0-9]*)
    echo "Error: SWIFTVLC_TIMEBASE_SOAK_SECONDS must be a positive integer." >&2
    exit 2
    ;;
esac
if [[ "$TIMEBASE_SOAK_SECONDS" -le 0 ]]; then
  echo "Error: SWIFTVLC_TIMEBASE_SOAK_SECONDS must be positive." >&2
  exit 2
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --device) DEVICE_SELECTOR="$2"; shift 2 ;;
    --development-team) DEVELOPMENT_TEAM="$2"; shift 2 ;;
    --candidate-app) CANDIDATE_APP="$2"; shift 2 ;;
    --candidate-metadata) CANDIDATE_METADATA="$2"; shift 2 ;;
    --xctestrun) XCTESTRUN_OVERRIDE="$2"; shift 2 ;;
    --derived-data) DERIVED_DATA="$2"; shift 2 ;;
    --fixtures) FIXTURES="$2"; shift 2 ;;
    --output) OUTPUT_ROOT="$2"; shift 2 ;;
    --work-root) WORK_ROOT="$2"; shift 2 ;;
    --orchestrator-session-binding) ORCHESTRATOR_SESSION_BINDING="$2"; shift 2 ;;
    --orchestrator-started-at-utc) ORCHESTRATOR_STARTED_AT_UTC="$2"; shift 2 ;;
    --only) ONLY_SCENARIOS+=("$2"); shift 2 ;;
    --full-suite-selection) FULL_SUITE_SELECTION=true; shift ;;
    --require-stable) REQUIRE_STABLE=true; shift ;;
    --exploratory-current-only) EXPLORATORY_CURRENT_ONLY=true; shift ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "Error: --version is required; qualification must name the exact candidate." >&2
  exit 2
fi
if ! RELEASE_VERSION_PREFIX=$(python3 - "$SCRIPT_DIR/feature-manifest-v1.json" \
    "$SCRIPT_DIR" <<'PY'
import sys
from pathlib import Path

manifest_path, qualification_path = sys.argv[1:]
sys.path.insert(0, qualification_path)
import qualification_policy as policy

manifest = policy.load_json(Path(manifest_path), "feature manifest")
prefix = manifest.get("releaseVersionPrefix")
if not isinstance(prefix, str) or not prefix:
    raise SystemExit("feature manifest has no releaseVersionPrefix")
print(prefix)
PY
); then
  echo "Error: cannot resolve the feature manifest release series." >&2
  exit 2
fi
if ! python3 "$ROOT_DIR/scripts/release-version-policy.py" "$VERSION" \
    --series-prefix "$RELEASE_VERSION_PREFIX" > /dev/null; then
  echo "Error: --version must be strict SemVer in release series $RELEASE_VERSION_PREFIX." >&2
  exit 2
fi
if [[ -n "$DEVELOPMENT_TEAM" && ! "$DEVELOPMENT_TEAM" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Error: --development-team must be a 10-character Apple team identifier." >&2
  exit 2
fi
if [[ "$SKIP_BUILD" == false && -z "$DEVELOPMENT_TEAM" ]]; then
  echo "Error: --development-team is required when building the signed candidate." >&2
  echo "  Use --skip-build only with an already signed, metadata-bound runner." >&2
  exit 2
fi
if [[ "$SKIP_BUILD" == true && -n "$DEVELOPMENT_TEAM" ]]; then
  echo "Error: --development-team cannot affect an existing --skip-build runner." >&2
  echo "  Omit the team; signed bundle identities are read from the retained apps." >&2
  exit 2
fi

# Report-only probe authority is resolved before device discovery or a build.
# It cannot be mixed with candidate lanes or promoted by --require-stable.
REPORT_ONLY_RUN=false
for requested_scenario in ${ONLY_SCENARIOS[@]+"${ONLY_SCENARIOS[@]}"}; do
  if [[ "$requested_scenario" == "cadence-semantics-probe" ]]; then
    if [[ ${#ONLY_SCENARIOS[@]} -ne 1 ]]; then
      echo "Error: cadence-semantics-probe must run alone (report-only)." >&2
      exit 2
    fi
    if [[ "$REQUIRE_STABLE" == true ]]; then
      echo "Error: cadence-semantics-probe cannot be used with --require-stable." >&2
      exit 2
    fi
    REPORT_ONLY_RUN=true
  fi
done

if [[ "$REQUIRE_STABLE" == true ]]; then
  for duration_spec in \
    "SWIFTVLC_ADAPTIVE_SOAK_SECONDS|$ADAPTIVE_SOAK_SECONDS|7200" \
    "SWIFTVLC_PIP_PERFORMANCE_SECONDS|$PIP_PERFORMANCE_SECONDS|900" \
    "SWIFTVLC_CADENCE_SECONDS|$CADENCE_SECONDS|600" \
    "SWIFTVLC_NATIVE_SUBTITLE_SECONDS|$NATIVE_SUBTITLE_SECONDS|900" \
    "SWIFTVLC_TIMEBASE_SOAK_SECONDS|$TIMEBASE_SOAK_SECONDS|7200"; do
    IFS='|' read -r duration_name duration_value duration_minimum <<< "$duration_spec"
    if [[ "$duration_value" -lt "$duration_minimum" ]]; then
      echo "Error: $duration_name=$duration_value cannot qualify a stable run;" >&2
      echo "  the immutable minimum is ${duration_minimum}s." >&2
      exit 2
    fi
  done
fi

for command in chflags curl ffmpeg ffprobe git jq plutil python3 shasum tar xcodebuild xcrun; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Error: required command is unavailable: $command" >&2
    exit 1
  fi
done

# Do not let an inherited shell build-setting override select different
# compiler inputs, conditions, link flags, metadata, or tools than the settings
# captured in the candidate build attestation.
for override in \
  CC CXX LD LDPLUSPLUS LIBTOOL SWIFT_EXEC XCODE_XCCONFIG_FILE \
  OTHER_CFLAGS OTHER_CPLUSPLUSFLAGS OTHER_LDFLAGS OTHER_SWIFT_FLAGS \
  GCC_PREPROCESSOR_DEFINITIONS SWIFT_ACTIVE_COMPILATION_CONDITIONS \
  EXCLUDED_SOURCE_FILE_NAMES INCLUDED_SOURCE_FILE_NAMES \
  INFOPLIST_FILE CODE_SIGN_ENTITLEMENTS; do
  if [[ ${!override+x} == x ]]; then
    echo "Error: inherited Xcode build override is forbidden: $override" >&2
    exit 2
  fi
done

# xcodebuild can outlive XCTest's per-test timeout while resolving packages,
# communicating with the device, or collecting a result bundle. Bound both the
# complete subprocess lifetime and periods with no observable command output;
# the watchdog owns a process group so cleanup cannot strand Xcode helpers.
run_with_watchdog() {
  local wall_seconds="$1"
  local idle_seconds="$2"
  local output_path="$3"
  shift 3
  python3 "$SCRIPT_DIR/run-with-watchdog.py" \
    --wall-seconds "$wall_seconds" \
    --idle-seconds "$idle_seconds" \
    --output "$output_path" \
    -- "$@"
}

RUN_STARTED_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ -z "$ORCHESTRATOR_SESSION_BINDING" \
  && -z "$ORCHESTRATOR_STARTED_AT_UTC" ]]; then
  ORCHESTRATOR_SESSION_BINDING=$(python3 -c \
    'import secrets; print(secrets.token_hex(32))')
  ORCHESTRATOR_STARTED_AT_UTC="$RUN_STARTED_AT_UTC"
elif [[ -z "$ORCHESTRATOR_SESSION_BINDING" \
  || -z "$ORCHESTRATOR_STARTED_AT_UTC" ]]; then
  echo "Error: orchestrator binding and start timestamp must be supplied together." >&2
  exit 2
fi
python3 - \
  "$ORCHESTRATOR_SESSION_BINDING" \
  "$ORCHESTRATOR_STARTED_AT_UTC" \
  "$RUN_STARTED_AT_UTC" <<'PY'
import re
import sys
from datetime import datetime, timezone

binding, orchestrator_raw, runner_raw = sys.argv[1:]
if re.fullmatch(r"[0-9a-f]{64}", binding) is None:
    raise SystemExit("orchestrator session binding must be 64 lowercase hex characters")

def timestamp(value: str) -> datetime:
    try:
        parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError as error:
        raise SystemExit("orchestrator timestamps must be canonical UTC") from error
    if parsed.strftime("%Y-%m-%dT%H:%M:%SZ") != value:
        raise SystemExit("orchestrator timestamps must be canonical UTC")
    return parsed

orchestrator = timestamp(orchestrator_raw)
runner = timestamp(runner_raw)
age = (runner - orchestrator).total_seconds()
if age < 0 or age > 300:
    raise SystemExit(
        "orchestrator start must be no later than runner start and at most 5 minutes old"
    )
PY
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
OUTPUT_DIR="$OUTPUT_ROOT/$run_id"
mkdir -p "$OUTPUT_DIR" "$WORK_ROOT"
WORK_DIR=$(mktemp -d "$WORK_ROOT/swiftvlc-device-tests.XXXXXX")
export TMPDIR="$WORK_DIR"
SERVER_PID=""
DEVICE_LOCK_PID=""
ACTIVE_XCODEBUILD_PID=""
ACTIVE_XCTRACE_PID=""

stop_fixture_server() {
  if [[ -z "$SERVER_PID" ]] || ! kill -0 "$SERVER_PID" 2>/dev/null; then
    SERVER_PID=""
    return
  fi
  kill -TERM "$SERVER_PID" 2>/dev/null || true
  for _ in {1..50}; do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  if kill -0 "$SERVER_PID" 2>/dev/null; then
    kill -KILL "$SERVER_PID" 2>/dev/null || true
  fi
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
}

cleanup() {
  if [[ -n "$ACTIVE_XCTRACE_PID" ]] && kill -0 "$ACTIVE_XCTRACE_PID" 2>/dev/null; then
    kill -INT "$ACTIVE_XCTRACE_PID" 2>/dev/null || true
    for _ in {1..20}; do
      if ! kill -0 "$ACTIVE_XCTRACE_PID" 2>/dev/null; then
        break
      fi
      sleep 0.1
    done
    if kill -0 "$ACTIVE_XCTRACE_PID" 2>/dev/null; then
      kill -KILL "$ACTIVE_XCTRACE_PID" 2>/dev/null || true
    fi
    wait "$ACTIVE_XCTRACE_PID" 2>/dev/null || true
  fi
  if [[ -n "$ACTIVE_XCODEBUILD_PID" ]] && kill -0 "$ACTIVE_XCODEBUILD_PID" 2>/dev/null; then
    kill -TERM "$ACTIVE_XCODEBUILD_PID" 2>/dev/null || true
    wait "$ACTIVE_XCODEBUILD_PID" 2>/dev/null || true
  fi
  if [[ -n "$DEVICE_LOCK_PID" ]] && kill -0 "$DEVICE_LOCK_PID" 2>/dev/null; then
    kill -TERM "$DEVICE_LOCK_PID" 2>/dev/null || true
    wait "$DEVICE_LOCK_PID" 2>/dev/null || true
  fi
  stop_fixture_server
  if [[ -n "${BUILD_SOURCE_ROOT:-}" && -e "$BUILD_SOURCE_ROOT" ]]; then
    chflags -R nouchg "$BUILD_SOURCE_ROOT" 2>/dev/null || true
  fi
  if [[ -n "${SOURCE_AUTHORITY_ROOT:-}" && -e "$SOURCE_AUTHORITY_ROOT" ]]; then
    chflags -R nouchg "$SOURCE_AUTHORITY_ROOT" 2>/dev/null || true
  fi
  if [[ -n "${STAGED_VENDOR_ROOT:-}" && -e "$STAGED_VENDOR_ROOT" ]]; then
    chflags -R nouchg "$STAGED_VENDOR_ROOT" 2>/dev/null || true
  fi
  if [[ -n "${STAGED_PRODUCTS:-}" && -e "$STAGED_PRODUCTS" ]]; then
    chflags -R nouchg "$STAGED_PRODUCTS" 2>/dev/null || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

stage_tree() {
  local source="$1"
  local destination="$2"
  if ! /bin/cp -cR "$source" "$destination" 2>/dev/null; then
    /bin/cp -R "$source" "$destination"
  fi
}

# Pin every subsequently invoked qualification helper and policy input to the
# committed source snapshot. The running shell remains part of the trusted host
# boundary, while mutable checkout helpers cannot be swapped during a long run.
AUTHORITY_SCRIPT_DIR="$SCRIPT_DIR"
SOURCE_AUTHORITY_IDENTITY_START=$(python3 \
  "$AUTHORITY_SCRIPT_DIR/candidate-metadata.py" source \
  --source-root "$ROOT_DIR" \
  --version "$VERSION")
SOURCE_AUTHORITY_COMMIT_START=$(jq -er '.sourceCommit' \
  <<< "$SOURCE_AUTHORITY_IDENTITY_START")
SOURCE_AUTHORITY_DIGEST_START=$(jq -er '.releaseSourceDigest' \
  <<< "$SOURCE_AUTHORITY_IDENTITY_START")

# Create a private Git checkout of the exact observed commit. Merely archiving
# HEAD again would reopen a race where a same-host ref move could select a
# different tree between identity capture and staging. The private checkout is
# also the Git-backed source authority used by candidate-build-binding.
SOURCE_AUTHORITY_ROOT="$WORK_DIR/source-authority"
git clone --quiet --no-checkout --no-local "$ROOT_DIR" "$SOURCE_AUTHORITY_ROOT"
git -C "$SOURCE_AUTHORITY_ROOT" checkout --quiet --detach \
  "$SOURCE_AUTHORITY_COMMIT_START"
PINNED_SOURCE_AUTHORITY_IDENTITY=$(python3 \
  "$SOURCE_AUTHORITY_ROOT/scripts/qualification/candidate-metadata.py" source \
  --source-root "$SOURCE_AUTHORITY_ROOT" \
  --version "$VERSION")
if [[ $(jq -er '.sourceCommit' <<< "$PINNED_SOURCE_AUTHORITY_IDENTITY") \
    != "$SOURCE_AUTHORITY_COMMIT_START" \
  || $(jq -er '.releaseSourceDigest' <<< "$PINNED_SOURCE_AUTHORITY_IDENTITY") \
    != "$SOURCE_AUTHORITY_DIGEST_START" ]]; then
  echo "Error: exact-commit source authority differs from captured identity." >&2
  exit 1
fi
chflags -R uchg "$SOURCE_AUTHORITY_ROOT"
TOOL_SOURCE_ROOT="$SOURCE_AUTHORITY_ROOT"
SCRIPT_DIR="$SOURCE_AUTHORITY_ROOT/scripts/qualification"

assert_source_authority_unchanged() {
  local current_identity current_commit current_digest pinned_identity
  current_identity=$(python3 "$SCRIPT_DIR/candidate-metadata.py" source \
    --source-root "$ROOT_DIR" \
    --version "$VERSION")
  current_commit=$(jq -er '.sourceCommit' <<< "$current_identity")
  current_digest=$(jq -er '.releaseSourceDigest' <<< "$current_identity")
  if [[ "$current_commit" != "$SOURCE_AUTHORITY_COMMIT_START" \
    || "$current_digest" != "$SOURCE_AUTHORITY_DIGEST_START" ]]; then
    echo "Error: source authority identity changed during qualification." >&2
    exit 1
  fi
  pinned_identity=$(python3 "$SCRIPT_DIR/candidate-metadata.py" source \
    --source-root "$SOURCE_AUTHORITY_ROOT" \
    --version "$VERSION")
  if [[ $(jq -er '.sourceCommit' <<< "$pinned_identity") \
      != "$SOURCE_AUTHORITY_COMMIT_START" \
    || $(jq -er '.releaseSourceDigest' <<< "$pinned_identity") \
      != "$SOURCE_AUTHORITY_DIGEST_START" ]]; then
    echo "Error: private exact-commit source authority changed during qualification." >&2
    exit 1
  fi
}

device_args=(--matrix "$SCRIPT_DIR/matrix.json")
if [[ -n "$DEVICE_SELECTOR" ]]; then
  device_args+=(--device "$DEVICE_SELECTOR")
fi
if [[ "$REQUIRE_STABLE" == true ]]; then
  device_args+=(--require-stable)
fi
device_args+=(--output "$OUTPUT_DIR/device.json")

set +e
python3 "$SCRIPT_DIR/device-info.py" "${device_args[@]}"
device_status=$?
set -e
if [[ "$device_status" -ne 0 ]]; then
  echo "Error: no eligible connected physical iOS device (status $device_status)." >&2
  jq '.connected' "$OUTPUT_DIR/device.json" >&2 || true
  exit "$device_status"
fi

DEVICE_UDID=$(jq -r '.selected.udid' "$OUTPUT_DIR/device.json")
DEVICE_ECID=$(jq -r '.selected.ecidHex' "$OUTPUT_DIR/device.json")
DEVICE_TUNNEL_IP=$(jq -r '.selected.tunnelIPAddress // empty' "$OUTPUT_DIR/device.json")
RUN_MODE=$(jq -r '.mode' "$OUTPUT_DIR/device.json")
DEVICE_LOCK_READY="$WORK_DIR/device-lock.json"
python3 "$SCRIPT_DIR/device-run-lock.py" \
  --device-identifier "$DEVICE_UDID" \
  --parent-pid "$$" \
  --ready-file "$DEVICE_LOCK_READY" \
  > "$OUTPUT_DIR/device-lock.log" 2>&1 &
DEVICE_LOCK_PID=$!
for _ in {1..100}; do
  [[ -s "$DEVICE_LOCK_READY" ]] && break
  if ! kill -0 "$DEVICE_LOCK_PID" 2>/dev/null; then
    wait "$DEVICE_LOCK_PID" || lock_status=$?
    echo "Error: could not reserve the selected physical device (status ${lock_status:-1})." >&2
    exit "${lock_status:-1}"
  fi
  sleep 0.1
done
if [[ ! -s "$DEVICE_LOCK_READY" ]] || ! kill -0 "$DEVICE_LOCK_PID" 2>/dev/null; then
  echo "Error: device reservation helper did not establish a live lock." >&2
  exit 1
fi
cp "$DEVICE_LOCK_READY" "$OUTPUT_DIR/device-lock.json"

assert_device_lock_held() {
  if [[ -z "$DEVICE_LOCK_PID" ]]; then
    echo "Error: selected physical device has no reservation helper." >&2
    exit 1
  fi
  python3 "$SCRIPT_DIR/device-run-lock.py" \
    --assert-held \
    --device-identifier "$DEVICE_UDID" \
    --parent-pid "$$" \
    --owner-pid "$DEVICE_LOCK_PID"
}

assert_device_lock_held
echo "Selected $(jq -r '.selected.marketingName' "$OUTPUT_DIR/device.json") on $(jq -r '.selected.osVersion' "$OUTPUT_DIR/device.json") ($RUN_MODE)."

DEFAULT_SCENARIOS=(analyzer ui-suite harness-regressions live-media background-audio continuity capability-convergence vod-controls long-stall failed-start dismissal interruptions audio-session-ownership native-lifecycle playback-foreground-displaylayer-recovery terminal-outcomes adaptive-hls-soak deferred-pause-rejection hls-seek)
DEFAULT_SCENARIOS+=(seek-frame-oracles)
DEFAULT_SCENARIOS+=(progressive-http-range-seek)
DEFAULT_SCENARIOS+=(local-file-matrix audio-only-playback)
DEFAULT_SCENARIOS+=(pip-render-performance-1080p60 pip-render-performance-4k60)
DEFAULT_SCENARIOS+=(cadence-matrix)
DEFAULT_SCENARIOS+=(native-subtitle-matrix)
DEFAULT_SCENARIOS+=(timebase-vod-soak timebase-live-soak)
DEFAULT_SCENARIOS+=(audio-media-services-reset)
IPHONE_CURRENT_ONLY_SCENARIOS=(
  capability-convergence
  native-lifecycle
  playback-foreground-displaylayer-recovery
  terminal-outcomes
  adaptive-hls-soak
  pip-render-performance-1080p60
  pip-render-performance-4k60
  cadence-matrix
  native-subtitle-matrix
  timebase-vod-soak
  timebase-live-soak
  deferred-pause-rejection
  seek-frame-oracles
)

scenario_requires_iphone_current() {
  local candidate="$1"
  local required
  for required in "${IPHONE_CURRENT_ONLY_SCENARIOS[@]}"; do
    if [[ "$candidate" == "$required" ]]; then
      return 0
    fi
  done
  return 1
}

SCENARIOS_WERE_EXPLICIT=false
if [[ ${#ONLY_SCENARIOS[@]} -eq 0 ]]; then
  ONLY_SCENARIOS=("${DEFAULT_SCENARIOS[@]}")
  VALIDATION_SELECTION_SCOPE=full
else
  SCENARIOS_WERE_EXPLICIT=true
  VALIDATION_SELECTION_SCOPE=partial
fi
for scenario in "${ONLY_SCENARIOS[@]}"; do
  case "$scenario" in
    analyzer|ui-suite|native-live|direct-live|live-media|background-audio|continuity|capability-convergence|vod-controls|long-stall|failed-start|dismissal|interruptions|audio-session-ownership|audio-media-services-reset|native-lifecycle|playback-foreground-displaylayer-recovery|terminal-outcomes|adaptive-hls-soak|pip-render-performance-1080p60|pip-render-performance-4k60|cadence-matrix|cadence-semantics-probe|native-subtitle-matrix|timebase-vod-soak|timebase-live-soak|deferred-pause-rejection|hls-seek|seek-frame-oracles|progressive-http-range-seek|local-file-matrix|audio-only-playback|harness-regressions|ui-failures|thumbnail-preview) ;;
    *) echo "Error: unknown scenario: $scenario" >&2; exit 2 ;;
  esac
done
REQUESTED_SCENARIOS=("${ONLY_SCENARIOS[@]}")

# The semantics probe intentionally has no matrix-owned runner contract. Keep
# it isolated so the ordinary candidate report can never authorize, materialize,
# or accidentally inherit release qualification rows from another scenario.
device_matches_hardware_row() {
  local hardware_row="$1"
  jq -e --arg hardware_row "$hardware_row" \
    '.selected.matchingHardwareRows | index($hardware_row) != null' \
    "$OUTPUT_DIR/device.json" > /dev/null
}

can_run_iphone_current_lanes() {
  device_matches_hardware_row "iphone-current" \
    || [[ -n "$EXPLORATORY_HARDWARE_ID" ]]
}

if [[ "$EXPLORATORY_CURRENT_ONLY" == true ]]; then
  if ! EXPLORATORY_HARDWARE_ID=$(python3 \
    "$SCRIPT_DIR/exploratory-device-policy.py" \
    --device-info "$OUTPUT_DIR/device.json" \
    --matrix "$SCRIPT_DIR/matrix.json"); then
    echo "Error: --exploratory-current-only requires an exploratory iPhone" >&2
    echo "  on an OS newer than the matrix's iphone-current row." >&2
    exit 2
  fi
fi

if ! device_matches_hardware_row "iphone-current"; then
  if [[ -n "$EXPLORATORY_HARDWARE_ID" ]]; then
    echo "Including iphone-current-only scenarios as exploratory evidence."
    echo "These results cannot qualify or close any stable matrix row."
  elif [[ "$SCENARIOS_WERE_EXPLICIT" == true ]]; then
    for scenario in "${ONLY_SCENARIOS[@]}"; do
      if scenario_requires_iphone_current "$scenario"; then
        echo "Error: $scenario requires the iphone-current hardware row." >&2
        exit 2
      fi
    done
  else
    FILTERED_SCENARIOS=()
    for scenario in "${ONLY_SCENARIOS[@]}"; do
      if ! scenario_requires_iphone_current "$scenario"; then
        FILTERED_SCENARIOS+=("$scenario")
      fi
    done
    ONLY_SCENARIOS=("${FILTERED_SCENARIOS[@]}")
    echo "Skipping iphone-current-only qualification scenarios: selected device does not match iphone-current."
  fi
fi

# The profile wrapper must pass repeated --only values so it can select the
# device-applicable subset. Accept a full-scope claim only when that subset is
# exactly the runner's canonical suite for this device. This keeps arbitrary
# targeted invocations partial while allowing the canonical release profile to
# produce an honest full-device validation plan.
if [[ "$FULL_SUITE_SELECTION" == true ]]; then
  if [[ "$REPORT_ONLY_RUN" == true ]]; then
    echo "Error: a report-only probe cannot claim full-suite selection." >&2
    exit 2
  fi
  if [[ "${DEFAULT_SCENARIOS[${#DEFAULT_SCENARIOS[@]}-1]}" != "audio-media-services-reset" ]]; then
    echo "Error: canonical suite must keep audio-media-services-reset last." >&2
    exit 2
  fi
  EXPECTED_FULL_SCENARIOS=()
  for scenario in "${DEFAULT_SCENARIOS[@]}"; do
    if device_matches_hardware_row "iphone-current" \
      || [[ -n "$EXPLORATORY_HARDWARE_ID" ]] \
      || ! scenario_requires_iphone_current "$scenario"; then
      EXPECTED_FULL_SCENARIOS+=("$scenario")
    fi
  done
  if ! diff -u \
      <(printf '%s\n' "${EXPECTED_FULL_SCENARIOS[@]}") \
      <(printf '%s\n' "${ONLY_SCENARIOS[@]}") >/dev/null; then
    echo "Error: --full-suite-selection does not match the canonical applicable suite in canonical order." >&2
    exit 2
  fi
  REQUESTED_SCENARIOS=("${DEFAULT_SCENARIOS[@]}")
  VALIDATION_SELECTION_SCOPE=full
fi

requested_scenarios_file="$WORK_DIR/requested-scenarios.txt"
selected_scenarios_file="$WORK_DIR/selected-scenarios.txt"
printf '%s\n' "${REQUESTED_SCENARIOS[@]}" > "$requested_scenarios_file"
printf '%s\n' "${ONLY_SCENARIOS[@]}" > "$selected_scenarios_file"
validation_plan_args=(
  --device-info "$OUTPUT_DIR/device.json"
  --matrix "$SCRIPT_DIR/matrix.json"
  --requested "$requested_scenarios_file"
  --selected "$selected_scenarios_file"
  --selection-scope "$VALIDATION_SELECTION_SCOPE"
  --started-at-utc "$RUN_STARTED_AT_UTC"
  --orchestrator-session-binding "$ORCHESTRATOR_SESSION_BINDING"
  --orchestrator-started-at-utc "$ORCHESTRATOR_STARTED_AT_UTC"
  --output "$OUTPUT_DIR/validation-plan.json"
)
if [[ -n "$EXPLORATORY_HARDWARE_ID" ]]; then
  validation_plan_args+=(--projected-hardware-row iphone-current)
fi
if [[ "$REPORT_ONLY_RUN" == true ]]; then
  validation_plan_args+=(--report-only)
fi
python3 "$SCRIPT_DIR/validation-plan.py" "${validation_plan_args[@]}"

# Retain an empty plan-bound ledger before fixture generation, build, install,
# or runner priming. Any later interruption can still produce a useful and
# truthfully incomplete checklist.
RESULTS_TSV="$OUTPUT_DIR/scenario-results.tsv"
: > "$RESULTS_TSV"
QUALIFICATION_ROWS="$OUTPUT_DIR/qualification-rows.jsonl"
: > "$QUALIFICATION_ROWS"

if [[ ! -f "$FIXTURES/manifest.json" \
  || ! -f "$FIXTURES/unsupported-codec.mp4" \
  || ! -f "$FIXTURES/oracles/seek-sparse-gop.mp4" \
  || ! -f "$FIXTURES/oracles/frame-all-intra.mp4" \
  || ! -f "$FIXTURES/oracles/progressive-range.mp4" \
  || ! -f "$FIXTURES/local-playback/video/h264-aac-fragmented.mp4" \
  || ! -f "$FIXTURES/local-playback/audio/pcm-s16le.wav" \
  || ! -f "$FIXTURES/hls/soak/ts/low/segment-000.ts" \
  || ! -f "$FIXTURES/hls/soak/fmp4/high/init.mp4" \
  || ! -f "$FIXTURES/performance/1080p60.mp4" \
  || ! -f "$FIXTURES/performance/4k60.mp4" \
  || ! -f "$FIXTURES/cadence/23_976.mp4" \
  || ! -f "$FIXTURES/cadence/vfr.mp4" \
  || ! -f "$FIXTURES/subtitles/bitmap.mkv" \
  || ! -f "$FIXTURES/subtitles/hdr-text.mkv" ]]; then
  "$SCRIPT_DIR/generate-fixtures.sh" "$FIXTURES"
fi
python3 "$SCRIPT_DIR/verify-fixtures.py" "$FIXTURES" > /dev/null
python3 "$SCRIPT_DIR/fixture-tree-binding.py" create \
  --root "$FIXTURES" \
  --output "$WORK_DIR/external-fixture-tree-binding.json" \
  > /dev/null

# The external fixture authority may be regenerated by another process during
# a long qualification. Freeze a verified copy in this run's private work
# directory and serve only that snapshot. APFS clone copies keep the large
# media set cheap while still providing independent directory entries.
EXTERNAL_FIXTURES="$FIXTURES"
STAGED_FIXTURES="$WORK_DIR/qualification-fixtures"
stage_tree "$EXTERNAL_FIXTURES" "$STAGED_FIXTURES"
python3 "$SCRIPT_DIR/fixture-tree-binding.py" verify \
  --root "$STAGED_FIXTURES" \
  --receipt "$WORK_DIR/external-fixture-tree-binding.json" \
  > /dev/null
python3 "$SCRIPT_DIR/verify-fixtures.py" "$STAGED_FIXTURES" > /dev/null
cp "$WORK_DIR/external-fixture-tree-binding.json" \
  "$OUTPUT_DIR/fixture-tree-binding.json"
FIXTURES="$STAGED_FIXTURES"
cp "$FIXTURES/manifest.json" "$OUTPUT_DIR/fixture-manifest.json"
FIXTURE_MANIFEST_CHECKSUM=$(shasum -a 256 \
  "$OUTPUT_DIR/fixture-manifest.json" | cut -d' ' -f1)
if [[ "$FIXTURE_MANIFEST_CHECKSUM" != \
    "$(jq -er '.manifestDigest' "$OUTPUT_DIR/fixture-tree-binding.json")" ]]; then
  echo "Error: fixture manifest changed while establishing its preflight binding." >&2
  exit 1
fi

READY_FILE="$WORK_DIR/server-ready.json"
fixture_server_args=(
  --root "$FIXTURES"
  --ready-file "$READY_FILE"
  --request-log "$OUTPUT_DIR/fixture-requests.jsonl"
)
if [[ -n "$DEVICE_TUNNEL_IP" ]]; then
  set +e
  TUNNEL_HOST=$(python3 "$SCRIPT_DIR/tunnel-host.py" \
    --device-address "$DEVICE_TUNNEL_IP" 2> "$OUTPUT_DIR/tunnel-host.log")
  tunnel_status=$?
  set -e
  if [[ "$tunnel_status" -eq 0 ]]; then
    fixture_server_args+=(--host :: --advertise-host "$TUNNEL_HOST")
    echo "Using the wired CoreDevice tunnel for fixture delivery ($TUNNEL_HOST)."
  else
    echo "CoreDevice tunnel discovery failed; falling back to the LAN fixture address."
  fi
fi
python3 "$SCRIPT_DIR/fixture-server.py" "${fixture_server_args[@]}" \
  > "$OUTPUT_DIR/fixture-server.log" 2>&1 &
SERVER_PID=$!
for _ in {1..100}; do
  [[ -s "$READY_FILE" ]] && break
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "Error: fixture server exited before becoming ready." >&2
    exit 1
  fi
  sleep 0.1
done
if [[ ! -s "$READY_FILE" ]]; then
  echo "Error: fixture server did not become ready." >&2
  exit 1
fi
cp "$READY_FILE" "$OUTPUT_DIR/fixture-server.json"
BASE_URL=$(jq -r '.baseURL' "$READY_FILE")
PIP_LIVE_URL_BASE64=$(printf '%s' "$BASE_URL/live/live.ts" | base64 | tr -d '\r\n')
PIP_LONG_STALL_URL_BASE64=$(printf '%s' \
  "$BASE_URL/fault/gated-stall/long-stall/12/live.ts" | base64 | tr -d '\r\n')
VOD_URL_BASE64=$(printf '%s' "$BASE_URL/files/vod.mp4" | base64 | tr -d '\r\n')
LOCAL_PLAYBACK_BASE_URL_BASE64=$(printf '%s/' "$BASE_URL" | base64 | tr -d '\r\n')
PROGRESSIVE_HTTP_RANGE_BASE_URL_BASE64=$(printf '%s/' "$BASE_URL" | base64 | tr -d '\r\n')
PROGRESSIVE_HTTP_RANGE_FIXTURE_SHA256=$(jq -er \
  '.files["oracles/progressive-range.mp4"].sha256' "$OUTPUT_DIR/fixture-manifest.json")
PROGRESSIVE_HTTP_RANGE_FIXTURE_BYTES=$(jq -er \
  '.files["oracles/progressive-range.mp4"].bytes' "$OUTPUT_DIR/fixture-manifest.json")

# Freeze the large binary artifact into the run-owned work directory before
# package resolution/build. On APFS this is a copy-on-write clone; the fallback
# is an ordinary (and intentionally more expensive) independent copy.
EXTERNAL_ARTIFACT="$ROOT_DIR/Vendor/libvlc.xcframework"
if [[ ! -d "$EXTERNAL_ARTIFACT" ]]; then
  echo "Error: local Vendor/libvlc.xcframework is required for candidate verification." >&2
  exit 1
fi
EXTERNAL_ARTIFACT_DIGEST_BEFORE=$(python3 \
  "$TOOL_SOURCE_ROOT/scripts/artifact-tree-digest.py" "$EXTERNAL_ARTIFACT")
STAGED_VENDOR_ROOT="$WORK_DIR/vendor-authority"
mkdir -p "$STAGED_VENDOR_ROOT"
ARTIFACT_AUTHORITY="$STAGED_VENDOR_ROOT/libvlc.xcframework"
stage_tree "$EXTERNAL_ARTIFACT" "$ARTIFACT_AUTHORITY"
STAGED_ARTIFACT_DIGEST=$(python3 \
  "$TOOL_SOURCE_ROOT/scripts/artifact-tree-digest.py" "$ARTIFACT_AUTHORITY")
EXTERNAL_ARTIFACT_DIGEST_AFTER=$(python3 \
  "$TOOL_SOURCE_ROOT/scripts/artifact-tree-digest.py" "$EXTERNAL_ARTIFACT")
if [[ "$EXTERNAL_ARTIFACT_DIGEST_BEFORE" != "$STAGED_ARTIFACT_DIGEST" \
  || "$EXTERNAL_ARTIFACT_DIGEST_AFTER" != "$STAGED_ARTIFACT_DIGEST" ]]; then
  echo "Error: Vendor artifact changed while creating its run-owned snapshot." >&2
  exit 1
fi
chflags -R uchg "$STAGED_VENDOR_ROOT"

if [[ "$SKIP_BUILD" == false ]]; then
  CANDIDATE_RUNTIME_BINDING=$(python3 -c \
    'import secrets; print(secrets.token_hex(32))')
  BUILD_SOURCE_COMMIT="$SOURCE_AUTHORITY_COMMIT_START"
  BUILD_SOURCE_DIGEST="$SOURCE_AUTHORITY_DIGEST_START"
  BUILD_ARTIFACT_DIGEST=$(python3 "$TOOL_SOURCE_ROOT/scripts/artifact-tree-digest.py" \
    "$ARTIFACT_AUTHORITY")
  BUILD_SOURCE_ROOT="$WORK_DIR/source"
  mkdir -p "$BUILD_SOURCE_ROOT"
  git -C "$SOURCE_AUTHORITY_ROOT" archive "$SOURCE_AUTHORITY_COMMIT_START" \
    | tar -x -C "$BUILD_SOURCE_ROOT"
  ln -s "$STAGED_VENDOR_ROOT" "$BUILD_SOURCE_ROOT/Vendor"
  "$BUILD_SOURCE_ROOT/scripts/setup-dev.sh" --skip-download \
    > "$OUTPUT_DIR/setup-local-source.log"
  team_suffix=$(printf '%s' "$DEVELOPMENT_TEAM" | tr '[:upper:]' '[:lower:]')
  python3 "$SCRIPT_DIR/configure-signing.py" \
    "$BUILD_SOURCE_ROOT/Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj" \
    --team "$DEVELOPMENT_TEAM" \
    --bundle-prefix "com.swiftvlc.validation.$team_suffix" \
    > "$OUTPUT_DIR/configure-signing.log"
  rm -f "$BUILD_SOURCE_ROOT/Showcase/SwiftVLCShowcase.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
  if ! run_with_watchdog 1800 600 \
      "$OUTPUT_DIR/resolve-package-dependencies.log" \
      xcodebuild -resolvePackageDependencies \
      -project "$BUILD_SOURCE_ROOT/Showcase/SwiftVLCShowcase.xcodeproj" \
      -scheme iOS \
      -derivedDataPath "$DERIVED_DATA"; then
    echo "Error: explicit local package resolution failed." >&2
    exit 1
  fi
  build_args=(
    build-for-testing
    -project "$BUILD_SOURCE_ROOT/Showcase/SwiftVLCShowcase.xcodeproj"
    -scheme iOS
    -configuration Release
    -destination "platform=iOS,id=$DEVICE_UDID"
    -derivedDataPath "$DERIVED_DATA"
    -allowProvisioningUpdates
    -allowProvisioningDeviceRegistration
    SWIFTVLC_SOURCE_COMMIT="$BUILD_SOURCE_COMMIT"
    SWIFTVLC_RELEASE_SOURCE_DIGEST="$BUILD_SOURCE_DIGEST"
    SWIFTVLC_ARTIFACT_DIGEST="$BUILD_ARTIFACT_DIGEST"
    SWIFTVLC_CANDIDATE_VERSION="$VERSION"
    SWIFTVLC_CANDIDATE_RUNTIME_BINDING="$CANDIDATE_RUNTIME_BINDING"
    CODE_SIGNING_ALLOWED=YES
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
  )
  EFFECTIVE_BUILD_SETTINGS="$WORK_DIR/effective-build-settings.json"
  if ! run_with_watchdog 900 300 "$EFFECTIVE_BUILD_SETTINGS" \
      python3 "$SCRIPT_DIR/capture-build-settings.py" \
      --stderr "$OUTPUT_DIR/effective-build-settings-prebuild.log" -- \
      xcodebuild "${build_args[@]}" -showBuildSettings -json; then
    echo "Error: cannot capture authoritative effective build settings." >&2
    exit 1
  fi
  BUILD_BINDING_RECEIPT="$WORK_DIR/candidate-build-resolution.json"
  BUILD_ATTESTATION="$OUTPUT_DIR/candidate-build-attestation.json"
  python3 "$SCRIPT_DIR/candidate-build-binding.py" prebuild \
    --source-root "$BUILD_SOURCE_ROOT" \
    --source-authority "$SOURCE_AUTHORITY_ROOT" \
    --artifact-authority "$ARTIFACT_AUTHORITY" \
    --derived-data "$DERIVED_DATA" \
    --build-settings "$EFFECTIVE_BUILD_SETTINGS" \
    --development-team "$DEVELOPMENT_TEAM" \
    --bundle-prefix "com.swiftvlc.validation.$team_suffix" \
    --version "$VERSION" \
    --candidate-runtime-binding "$CANDIDATE_RUNTIME_BINDING" \
    --source-commit "$BUILD_SOURCE_COMMIT" \
    --release-source-digest "$BUILD_SOURCE_DIGEST" \
    --configuration Release \
    --platform iphoneos \
    --output "$BUILD_BINDING_RECEIPT" \
    > /dev/null
  chflags -R uchg "$BUILD_SOURCE_ROOT"
  run_with_watchdog 7200 900 "$OUTPUT_DIR/build.log" \
    xcodebuild "${build_args[@]}"
  if ! run_with_watchdog 900 300 "$EFFECTIVE_BUILD_SETTINGS" \
      python3 "$SCRIPT_DIR/capture-build-settings.py" \
      --stderr "$OUTPUT_DIR/effective-build-settings-postbuild.log" -- \
      xcodebuild "${build_args[@]}" -showBuildSettings -json; then
    echo "Error: cannot recheck effective build settings after build." >&2
    exit 1
  fi
fi

RUNNER_APP="$DERIVED_DATA/Build/Products/Release-iphoneos/iOSUITests-Runner.app"
PREBUILT_CANDIDATE=false
if [[ -n "$CANDIDATE_APP" ]] || [[ "$SKIP_BUILD" == true ]]; then
  PREBUILT_CANDIDATE=true
fi
if [[ -z "$CANDIDATE_APP" ]]; then
  CANDIDATE_APP="$DERIVED_DATA/Build/Products/Release-iphoneos/iOS.app"
fi
for app in "$CANDIDATE_APP" "$RUNNER_APP"; do
  if [[ ! -d "$app" ]]; then
    echo "Error: signed application not found: $app" >&2
    exit 1
  fi
  codesign --verify --deep --strict "$app"
done

read_app_bundle_identifier() {
  local app="$1"
  local description="$2"
  local identifier
  if ! identifier=$(plutil -extract CFBundleIdentifier raw -- "$app/Info.plist") \
      || [[ ! "$identifier" =~ ^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$ ]]; then
    echo "Error: $description has no valid CFBundleIdentifier: $app" >&2
    exit 1
  fi
  printf '%s\n' "$identifier"
}

CANDIDATE_BUNDLE_IDENTIFIER=$(read_app_bundle_identifier \
  "$CANDIDATE_APP" "candidate application")
TEST_RUNNER_BUNDLE_IDENTIFIER=$(read_app_bundle_identifier \
  "$RUNNER_APP" "UI-test runner")

prepare_xctestrun() {
  python3 "$SCRIPT_DIR/prepare-xctestrun.py" "$@" \
    --environment SWIFTVLC_QUALIFICATION_SESSION_BINDING="$ORCHESTRATOR_SESSION_BINDING" \
    --environment SWIFTVLC_CANDIDATE_RUNTIME_BINDING="$CANDIDATE_RUNTIME_BINDING" \
    --test-host-bundle-identifier "$TEST_RUNNER_BUNDLE_IDENTIFIER" \
    --ui-target-app-bundle-identifier "$CANDIDATE_BUNDLE_IDENTIFIER"
}

TEST_BUNDLES=()
while IFS= read -r test_bundle; do
  TEST_BUNDLES+=("$test_bundle")
done < <(find "$RUNNER_APP/PlugIns" -maxdepth 1 -name '*.xctest' -type d -print | sort)
if [[ ${#TEST_BUNDLES[@]} -ne 1 ]]; then
  echo "Error: expected exactly one embedded .xctest bundle in $RUNNER_APP;" >&2
  echo "  found ${#TEST_BUNDLES[@]}." >&2
  exit 1
fi
TEST_BUNDLE="${TEST_BUNDLES[0]}"

if [[ -n "$XCTESTRUN_OVERRIDE" ]]; then
  if [[ ! -f "$XCTESTRUN_OVERRIDE" || "$XCTESTRUN_OVERRIDE" != *.xctestrun ]]; then
    echo "Error: explicit xctestrun must be an existing .xctestrun file: $XCTESTRUN_OVERRIDE" >&2
    exit 1
  fi
  XCTESTRUN="$(cd "$(dirname "$XCTESTRUN_OVERRIDE")" && pwd)/$(basename "$XCTESTRUN_OVERRIDE")"
else
  XCTESTRUN_CANDIDATES=()
  while IFS= read -r xctestrun_candidate; do
    XCTESTRUN_CANDIDATES+=("$xctestrun_candidate")
  done < <(find "$DERIVED_DATA/Build/Products" -maxdepth 1 -name '*.xctestrun' -type f -print | sort)
  if [[ ${#XCTESTRUN_CANDIDATES[@]} -ne 1 ]]; then
    echo "Error: expected exactly one base xctestrun in $DERIVED_DATA/Build/Products;" >&2
    echo "  found ${#XCTESTRUN_CANDIDATES[@]}. Pass --xctestrun PATH to select explicitly." >&2
    printf '  %s\n' "${XCTESTRUN_CANDIDATES[@]}" >&2
    exit 1
  fi
  XCTESTRUN="${XCTESTRUN_CANDIDATES[0]}"
fi

# Freeze the exact signed products in the run-owned work directory before any
# catalog enumeration, hashing, installation, or evidence collection. APFS
# clone copies avoid duplicating the large linked application when available;
# the ordinary recursive-copy fallback preserves portability.
SOURCE_CANDIDATE_APP="$CANDIDATE_APP"
SOURCE_RUNNER_APP="$RUNNER_APP"
SOURCE_XCTESTRUN="$XCTESTRUN"
STAGED_PRODUCTS="$WORK_DIR/candidate-products"
STAGED_CONFIGURATION="$STAGED_PRODUCTS/Release-iphoneos"
mkdir -p "$STAGED_CONFIGURATION"
stage_tree "$SOURCE_CANDIDATE_APP" "$STAGED_CONFIGURATION/iOS.app"
stage_tree "$SOURCE_RUNNER_APP" \
  "$STAGED_CONFIGURATION/iOSUITests-Runner.app"
/bin/cp "$SOURCE_XCTESTRUN" "$STAGED_PRODUCTS/$(basename "$SOURCE_XCTESTRUN")"
CANDIDATE_APP="$STAGED_CONFIGURATION/iOS.app"
RUNNER_APP="$STAGED_CONFIGURATION/iOSUITests-Runner.app"
TEST_BUNDLE="$RUNNER_APP/PlugIns/iOSUITests.xctest"
XCTESTRUN="$STAGED_PRODUCTS/$(basename "$SOURCE_XCTESTRUN")"
for app in "$CANDIDATE_APP" "$RUNNER_APP"; do
  codesign --verify --deep --strict "$app"
done

if [[ "$PREBUILT_CANDIDATE" == false ]]; then
  python3 "$SCRIPT_DIR/candidate-build-binding.py" postbuild \
    --receipt "$BUILD_BINDING_RECEIPT" \
    --candidate-app "$CANDIDATE_APP" \
    --test-runner "$RUNNER_APP" \
    --test-bundle "$TEST_BUNDLE" \
    --xctestrun "$XCTESTRUN" \
    --output "$BUILD_ATTESTATION" \
    > /dev/null
fi

FULL_CATALOG_RAW="$WORK_DIR/full-test-catalog-raw.json"
FULL_TEST_CATALOG="$OUTPUT_DIR/full-test-catalog.json"
if ! run_with_watchdog 600 180 "$OUTPUT_DIR/enumerate-full-test-catalog.log" \
    xcodebuild test-without-building \
    -parallel-testing-enabled NO \
    -xctestrun "$XCTESTRUN" \
    -derivedDataPath "$DERIVED_DATA" \
    -destination "platform=iOS,id=$DEVICE_UDID" \
    -enumerate-tests \
    -test-enumeration-style flat \
    -test-enumeration-format json \
    -test-enumeration-output-path "$FULL_CATALOG_RAW"; then
  echo "Error: XCTest preflight enumeration failed." >&2
  exit 1
fi
python3 "$SCRIPT_DIR/qualification_policy.py" normalize-catalog \
  --input "$FULL_CATALOG_RAW" \
  --output "$FULL_TEST_CATALOG"
TEST_CATALOG_AUTHORITY="$SCRIPT_DIR/ios-test-catalog-authority-v1.json"
if [[ ! -f "$TEST_CATALOG_AUTHORITY" ]]; then
  echo "Error: reviewed exact iOS XCTest catalog authority is missing." >&2
  echo "  After a clean reviewed build, create it with:" >&2
  echo "  python3 scripts/qualification/test-catalog-authority.py create --catalog '$FULL_TEST_CATALOG' --output scripts/qualification/ios-test-catalog-authority-v1.json" >&2
  exit 1
fi
python3 "$SCRIPT_DIR/test-catalog-authority.py" verify \
  --catalog "$FULL_TEST_CATALOG" \
  --authority "$TEST_CATALOG_AUTHORITY" \
  > /dev/null

if [[ "$PREBUILT_CANDIDATE" == false ]]; then
  python3 "$SCRIPT_DIR/candidate-build-binding.py" bind-catalog \
    --attestation "$BUILD_ATTESTATION" \
    --test-catalog "$FULL_TEST_CATALOG" \
    --output "$BUILD_ATTESTATION" \
    > /dev/null
fi

CANDIDATE_IDENTITY="$OUTPUT_DIR/candidate-metadata.json"
if [[ "$PREBUILT_CANDIDATE" == true ]]; then
  if [[ -z "$CANDIDATE_METADATA" || ! -f "$CANDIDATE_METADATA" ]]; then
    echo "Error: --candidate-metadata is required for a prebuilt candidate." >&2
    exit 1
  fi
  python3 "$SCRIPT_DIR/candidate-metadata.py" verify \
    --candidate-app "$CANDIDATE_APP" \
    --xcframework "$ARTIFACT_AUTHORITY" \
    --metadata "$CANDIDATE_METADATA" \
    --version "$VERSION" \
    --digest-script "$TOOL_SOURCE_ROOT/scripts/artifact-tree-digest.py" \
    --test-runner "$RUNNER_APP" \
    --test-bundle "$TEST_BUNDLE" \
    --xctestrun "$XCTESTRUN" \
    --test-catalog "$FULL_TEST_CATALOG" \
    --test-catalog-authority "$TEST_CATALOG_AUTHORITY" \
    --matrix "$SCRIPT_DIR/matrix.json" \
    --feature-manifest "$SCRIPT_DIR/feature-manifest-v1.json" \
    --profiles "$SCRIPT_DIR/profiles-v1.json" \
    --fixture-manifest "$OUTPUT_DIR/fixture-manifest.json" \
    > "$CANDIDATE_IDENTITY"
else
  python3 "$SCRIPT_DIR/candidate-metadata.py" create \
    --candidate-app "$CANDIDATE_APP" \
    --xcframework "$ARTIFACT_AUTHORITY" \
    --version "$VERSION" \
    --digest-script "$TOOL_SOURCE_ROOT/scripts/artifact-tree-digest.py" \
    --build-attestation "$BUILD_ATTESTATION" \
    --test-runner "$RUNNER_APP" \
    --test-bundle "$TEST_BUNDLE" \
    --xctestrun "$XCTESTRUN" \
    --test-catalog "$FULL_TEST_CATALOG" \
    --test-catalog-authority "$TEST_CATALOG_AUTHORITY" \
    --matrix "$SCRIPT_DIR/matrix.json" \
    --feature-manifest "$SCRIPT_DIR/feature-manifest-v1.json" \
    --profiles "$SCRIPT_DIR/profiles-v1.json" \
    --fixture-manifest "$OUTPUT_DIR/fixture-manifest.json" \
    --output "$CANDIDATE_IDENTITY" \
    > /dev/null
fi
CANDIDATE_APP_DIGEST=$(jq -r '.candidateAppDigest' "$CANDIDATE_IDENTITY")
ARTIFACT_DIGEST=$(jq -r '.artifactDigest' "$CANDIDATE_IDENTITY")
SOURCE_COMMIT=$(jq -r '.sourceCommit' "$CANDIDATE_IDENTITY")
SOURCE_DIGEST=$(jq -r '.releaseSourceDigest' "$CANDIDATE_IDENTITY")
CANDIDATE_VERSION=$(jq -r '.version' "$CANDIDATE_IDENTITY")
CANDIDATE_RUNTIME_BINDING=$(jq -r '.candidateRuntimeBinding' "$CANDIDATE_IDENTITY")

assert_candidate_matches_source_authority() {
  if [[ "$CANDIDATE_VERSION" != "$VERSION" \
    || ! "$CANDIDATE_RUNTIME_BINDING" =~ ^[0-9a-f]{64}$ \
    || "$SOURCE_COMMIT" != "$SOURCE_AUTHORITY_COMMIT_START" \
    || "$SOURCE_DIGEST" != "$SOURCE_AUTHORITY_DIGEST_START" ]]; then
    echo "Error: candidate identity does not match the current source authority/version." >&2
    exit 1
  fi
}

assert_candidate_matches_source_authority

verify_staged_candidate_identity() {
  codesign --verify --deep --strict "$CANDIDATE_APP"
  codesign --verify --deep --strict "$RUNNER_APP"
  python3 "$SCRIPT_DIR/candidate-metadata.py" verify \
    --candidate-app "$CANDIDATE_APP" \
    --xcframework "$ARTIFACT_AUTHORITY" \
    --metadata "$CANDIDATE_IDENTITY" \
    --version "$VERSION" \
    --digest-script "$TOOL_SOURCE_ROOT/scripts/artifact-tree-digest.py" \
    --test-runner "$RUNNER_APP" \
    --test-bundle "$TEST_BUNDLE" \
    --xctestrun "$XCTESTRUN" \
    --test-catalog "$FULL_TEST_CATALOG" \
    --test-catalog-authority "$TEST_CATALOG_AUTHORITY" \
    --matrix "$SCRIPT_DIR/matrix.json" \
    --feature-manifest "$SCRIPT_DIR/feature-manifest-v1.json" \
    --profiles "$SCRIPT_DIR/profiles-v1.json" \
    --fixture-manifest "$OUTPUT_DIR/fixture-manifest.json" \
    > /dev/null
  assert_source_authority_unchanged
  assert_candidate_matches_source_authority
}

verify_staged_candidate_identity
chflags -R uchg "$STAGED_PRODUCTS"

DESTINATION_XCTESTRUN="$WORK_DIR/destination.xctestrun"
prepare_xctestrun "$XCTESTRUN" "$DESTINATION_XCTESTRUN" \
  --environment SWIFTVLC_PIP_LIVE_URL_BASE64="$PIP_LIVE_URL_BASE64" \
  --environment SWIFTVLC_PIP_CONTINUITY_DEVICE=YES \
  --environment SWIFTVLC_PIP_CAPABILITY_DEVICE=YES \
  --environment SWIFTVLC_PIP_VOD_CONTROLS_DEVICE=YES \
  --environment SWIFTVLC_PIP_LONG_STALL_DEVICE=YES \
  --environment SWIFTVLC_PIP_LONG_STALL_URL_BASE64="$PIP_LONG_STALL_URL_BASE64" \
  --environment SWIFTVLC_PIP_DISMISSAL_DEVICE=YES \
  --environment SWIFTVLC_PIP_INTERRUPTION_DEVICE=YES \
  --environment SWIFTVLC_PIP_NATIVE_LIFECYCLE_DEVICE=YES \
  --environment SWIFTVLC_TERMINAL_OUTCOMES_DEVICE=YES \
  --environment SWIFTVLC_ADAPTIVE_HLS_SOAK_DEVICE=YES \
  --environment SWIFTVLC_ADAPTIVE_SOAK_SECONDS="$ADAPTIVE_SOAK_SECONDS" \
  --environment SWIFTVLC_PIP_DEFERRED_PAUSE_DEVICE=YES \
  --environment SWIFTVLC_PIP_DELAYED_START_FAILURE_DEVICE=YES \
  --environment SWIFTVLC_PIP_OVERLAY_DEVICE=YES \
  --environment SWIFTVLC_PIP_SEEK_DEVICE=YES \
  --environment SWIFTVLC_PROGRESSIVE_HTTP_RANGE_DEVICE=YES \
  --environment SWIFTVLC_PROGRESSIVE_HTTP_RANGE_BASE_URL_BASE64="$PROGRESSIVE_HTTP_RANGE_BASE_URL_BASE64" \
  --environment SWIFTVLC_PROGRESSIVE_HTTP_RANGE_FIXTURE_SHA256="$PROGRESSIVE_HTTP_RANGE_FIXTURE_SHA256" \
  --environment SWIFTVLC_PROGRESSIVE_HTTP_RANGE_FIXTURE_BYTES="$PROGRESSIVE_HTTP_RANGE_FIXTURE_BYTES" \
  --environment SWIFTVLC_LOCAL_PLAYBACK_DEVICE=YES \
  --environment SWIFTVLC_LOCAL_PLAYBACK_BASE_URL_BASE64="$LOCAL_PLAYBACK_BASE_URL_BASE64"
cp "$DESTINATION_XCTESTRUN" "$OUTPUT_DIR/destination.xctestrun"

LAUNCH_XCTESTRUN="$WORK_DIR/destination-launch.xctestrun"
prepare_xctestrun "$XCTESTRUN" "$LAUNCH_XCTESTRUN" \
  --environment SWIFTVLC_DEVICE_FIXTURE_URL_BASE64="$VOD_URL_BASE64" \
  --environment SWIFTVLC_DEVICE_LOG_PREFIX="$run_id"
cp "$LAUNCH_XCTESTRUN" "$OUTPUT_DIR/destination-launch.xctestrun"

install_app() {
  local app="$1"
  local configurator="/Applications/Apple Configurator.app/Contents/MacOS/cfgutil"
  assert_device_lock_held
  if [[ -x "$configurator" ]]; then
    if "$configurator" --ecid "$DEVICE_ECID" install-app "$app"; then
      return 0
    fi
    echo "Warning: Apple Configurator installation failed; retrying the same app with devicectl." >&2
  fi
  assert_device_lock_held
  xcrun devicectl device install app --device "$DEVICE_UDID" "$app"
}

install_candidate_with_fresh_permission_state() {
  if [[ "$CANDIDATE_BUNDLE_IDENTIFIER" == com.swiftvlc.validation.* ]]; then
    # Installing first makes the exact verified candidate the known uninstall
    # target even when no older copy exists. Removing and reinstalling this
    # disposable namespace clears a previously denied Local Network decision.
    install_app "$CANDIDATE_APP" > "$OUTPUT_DIR/install-candidate-bootstrap.log"
    echo "Resetting Local Network permission state for disposable candidate $CANDIDATE_BUNDLE_IDENTIFIER." >&2
    assert_device_lock_held
    if ! xcrun devicectl device uninstall app \
        --device "$DEVICE_UDID" "$CANDIDATE_BUNDLE_IDENTIFIER" \
        > "$OUTPUT_DIR/reset-candidate-permissions.log" 2>&1; then
      echo "Error: could not fresh-install the disposable candidate; permission state may be stale." >&2
      echo "  See $OUTPUT_DIR/reset-candidate-permissions.log" >&2
      exit 1
    fi
  else
    {
      echo "Warning: candidate $CANDIDATE_BUNDLE_IDENTIFIER is outside the disposable com.swiftvlc.validation.* namespace."
      echo "It will not be uninstalled, so iOS Local Network permission state is preserved."
      echo "Before qualifying it, enable Local Network access in Settings > Privacy & Security > Local Network."
    } | tee "$OUTPUT_DIR/candidate-permission-state-warning.log" >&2
  fi

  install_app "$CANDIDATE_APP" > "$OUTPUT_DIR/install-candidate.log"
}

install_candidate_with_fresh_permission_state
install_app "$RUNNER_APP" > "$OUTPUT_DIR/install-runner.log"

# A freshly installed xctrunner has no data container until its first launch.
# Xcode can try to place runtime profiles in that container before launching
# the process, which otherwise fails with ContainerLookupErrorDomain or times
# out enabling automation. Prime the exact signed runner without presenting UI,
# then terminate the suspended process before XCTest owns it.
"$SCRIPT_DIR/prime-xctrunner.sh" \
  --device "$DEVICE_UDID" \
  --bundle-identifier "$TEST_RUNNER_BUNDLE_IDENTIFIER" \
  --work-root "$WORK_DIR" \
  > "$OUTPUT_DIR/prime-runner.log" 2>&1

STREAMS_FILE="$WORK_DIR/streams.local.json"
python3 - "$BASE_URL" "$STREAMS_FILE" <<'PY'
import json
import sys

base, output = sys.argv[1:]
value = {
    "liveTS": f"{base}/live/live.ts",
    "hlsLive": f"{base}/files/hls/vod.m3u8",
    "vod": f"{base}/files/vod.mp4",
    "catchup": f"{base}/fault/stall/2/vod.mp4",
    "subtitled": f"{base}/files/hls/vod.m3u8",
    "adaptive": f"{base}/files/hls/vod.m3u8",
    "audioOnly": f"{base}/files/audio.m4a",
}
with open(output, "w") as destination:
    json.dump(value, destination, indent=2, sort_keys=True)
    destination.write("\n")
PY
cp "$STREAMS_FILE" "$OUTPUT_DIR/streams.local.json"
xcrun devicectl device copy to \
  --device "$DEVICE_UDID" \
  --domain-type appDataContainer \
  --domain-identifier "$CANDIDATE_BUNDLE_IDENTIFIER" \
  --source "$STREAMS_FILE" \
  --destination Documents/streams.local.json \
  > "$OUTPUT_DIR/stage-streams.log"

export_trace_toc() {
  local trace="$1"
  local toc="$2"
  python3 - "$trace" "$toc" <<'PY'
import subprocess
import sys

try:
    result = subprocess.run(
        [
            "xcrun", "xctrace", "export", "--quiet",
            "--input", sys.argv[1], "--toc", "--output", sys.argv[2],
        ],
        timeout=120,
    )
except subprocess.TimeoutExpired:
    raise SystemExit(124)
raise SystemExit(result.returncode)
PY
}

record_performance_trace() {
  local template="$1"
  local trace="$2"
  local toc="$3"
  local duration="$4"
  local xcodebuild_pid="$5"
  local trace_log="$6"
  xcrun xctrace record --quiet \
    --template "$template" \
    --device "$DEVICE_UDID" \
    --attach iOS \
    --time-limit "${duration}s" \
    --output "$trace" \
    --no-prompt \
    > "$trace_log" 2>&1 &
  local trace_pid=$!
  ACTIVE_XCTRACE_PID="$trace_pid"
  while kill -0 "$trace_pid" 2>/dev/null; do
    if ! kill -0 "$xcodebuild_pid" 2>/dev/null; then
      kill -INT "$trace_pid" 2>/dev/null || true
      wait "$trace_pid" 2>/dev/null || true
      ACTIVE_XCTRACE_PID=""
      return 1
    fi
    sleep 1
  done
  wait "$trace_pid"
  local trace_status=$?
  ACTIVE_XCTRACE_PID=""
  if [[ "$trace_status" -ne 0 || ! -d "$trace" ]]; then
    return 1
  fi
  export_trace_toc "$trace" "$toc" >> "$trace_log" 2>&1
  [[ -s "$toc" ]]
}

capture_apple_audio_source_metrics() {
  local token="$1"
  local minimum_successful_segments="$2"
  local destination="$3"
  local metrics_directory="${destination%/*}"
  local first_snapshot=""
  local second_snapshot=""
  if ! mkdir -p "$metrics_directory"; then
    return 1
  fi
  if [[ -e "$destination" ]]; then
    echo "Error: refusing to replace retained Apple audio source metrics: $destination" >&2
    return 1
  fi
  if ! first_snapshot=$(mktemp "$metrics_directory/.metrics-first.XXXXXX"); then
    return 1
  fi
  if ! second_snapshot=$(mktemp "$metrics_directory/.metrics-second.XXXXXX"); then
    rm -f -- "$first_snapshot"
    return 1
  fi
  local validate_filter='def integer:
      type == "number" and floor == . and . >= 0;
    type == "object"
    and (keys == [
      "clientCompleted", "containers", "discontinuityManifests",
      "expiredWindows", "formatVersion", "masterRequests",
      "maxMediaSequenceByMode", "mediaPlaylistRequests", "modes",
      "playlistTypes", "retryFailures", "retryRecoveries",
      "segmentRequests", "successfulSegments",
      "successfulSegmentsByVariant", "token", "variantTransitions",
      "variants"
    ])
    and .formatVersion == 1
    and .token == $token
    and ([
      .masterRequests, .mediaPlaylistRequests, .segmentRequests,
      .successfulSegments, .retryFailures, .retryRecoveries,
      .expiredWindows, .discontinuityManifests, .variantTransitions
    ] | all(.[]; integer))
    and .masterRequests > 0
    and .mediaPlaylistRequests > 0
    and .segmentRequests >= $minimum
    and .successfulSegments == .segmentRequests
    and (.successfulSegments as $successful
      | .successfulSegmentsByVariant == {"high": $successful, "low": 0})
    and .retryFailures == 0
    and .retryRecoveries == 0
    and .expiredWindows == 0
    and .discontinuityManifests == .mediaPlaylistRequests
    and .variantTransitions == 0
    and .clientCompleted == false
    and .playlistTypes == ["vod"]
    and .containers == ["ts"]
    and .variants == ["high"]
    and .modes == ["timebase-vod-ts"]
    and .maxMediaSequenceByMode == {"timebase-vod-ts": 0}'
  local captured=false
  # The deterministic HLS segments are two seconds long. Requiring unchanged
  # snapshots across three seconds proves the candidate has actually quiesced
  # after XCTest teardown instead of catching an ordinary inter-segment gap.
  for _ in {1..5}; do
    if curl -fsS "$BASE_URL/adaptive/$token/metrics" > "$first_snapshot" \
        2>/dev/null \
      && jq -e --arg token "$token" \
        --argjson minimum "$minimum_successful_segments" \
        "$validate_filter" "$first_snapshot" >/dev/null \
      && sleep 3 \
      && curl -fsS "$BASE_URL/adaptive/$token/metrics" > "$second_snapshot" \
        2>/dev/null \
      && jq -e --arg token "$token" \
        --argjson minimum "$minimum_successful_segments" \
        "$validate_filter" "$second_snapshot" >/dev/null \
      && cmp -s "$first_snapshot" "$second_snapshot"; then
      if mv "$second_snapshot" "$destination"; then
        captured=true
        break
      fi
    fi
    sleep 0.25
  done
  rm -f -- "$first_snapshot" "$second_snapshot"
  [[ "$captured" == true ]]
}

run_scenario() {
  local scenario="$1"
  assert_device_lock_held
  local route log_name selected_xctestrun
  local test_identifiers=()
  local skip_device_tests=false
  local pip_url=""
  local rendering_path=""
  local performance_profile=""
  local performance_url=""
  local timebase_mode=""
  case "$scenario" in
    analyzer)
      test_identifiers=(
        "iOSUITests/DeferredPauseSettlementObservationTests"
        "iOSUITests/HLSSeekLandingFrameGateTests"
        "iOSUITests/NativeRendererRecoveryEvidenceTests"
        "iOSUITests/NativeRendererRecoveryVisualEvidenceTests"
        "iOSUITests/PiPMotionRegionAnalyzerTests"
        "iOSUITests/VideoSurfaceMotionEvidenceTests"
        "iOSUITests/VideoOracleAnalyzerTests"
      )
      route=""
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    ui-suite)
      test_identifiers=("iOSUITests")
      route=""
      selected_xctestrun="$LAUNCH_XCTESTRUN"
      skip_device_tests=true
      ;;
    native-live)
      test_identifiers=("iOSUITests/PiPLiveDeviceUITests/test_nativeLiveMPEGTSRendersMovingFramesInSystemPiP")
      route="PiPLiveValidation"
      pip_url="$BASE_URL/live/live.ts"
      rendering_path="native"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    direct-live)
      test_identifiers=("iOSUITests/PiPLiveDeviceUITests/test_directLiveMPEGTSRendersMovingFramesInSystemPiP")
      route="PiPLiveValidation"
      pip_url="$BASE_URL/live/live.ts"
      rendering_path="direct"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    live-media)
      test_identifiers=("iOSUITests/PiPLiveDeviceUITests/test_liveMediaQualificationAcrossNativeAndDirectBackends")
      route="PiPLiveValidation"
      pip_url="$BASE_URL/live/live.ts"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    background-audio)
      test_identifiers=("iOSUITests/PiPLiveDeviceUITests/test_backgroundAudioQualificationWhileAppIsBackgrounded")
      route="PiPLiveValidation"
      pip_url="$BASE_URL/live/live.ts"
      rendering_path="native"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    continuity)
      test_identifiers=("iOSUITests/PiPContinuityDeviceUITests/test_nativePiPSurvivesSamePlayerReplacement")
      if can_run_iphone_current_lanes; then
        test_identifiers+=("iOSUITests/PiPContinuityDeviceUITests/test_nativePiPReplacementContinuityAcrossVODAndLive")
      fi
      route="HarnessHome"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    capability-convergence)
      test_identifiers=(
        "iOSUITests/PiPCapabilityDeviceUITests/test_capabilityConvergenceAcrossNativeAndDirectBackends"
      )
      route="PiPCapabilityValidation"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    vod-controls)
      test_identifiers=(
        "iOSUITests/PiPVODControlsDeviceUITests/test_vodControlsAcrossNativeAndDirectBackends"
      )
      route="PiPVODControlsValidation"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    long-stall)
      test_identifiers=(
        "iOSUITests/PiPLongStallDeviceUITests/test_longStallRecoversAcrossNativeAndDirectBackends"
      )
      route="PiPLongStallValidation"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    failed-start)
      test_identifiers=(
        "iOSUITests/PiPDelayedStartFailureDeviceUITests/test_acceptedStartRetainsAttributionThroughDelayedFailure"
      )
      route="PiPDelayedStartFailureValidation"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    dismissal)
      test_identifiers=(
        "iOSUITests/PiPDismissalDeviceUITests/test_systemRestoreAndCloseAcrossNativeAndDirectBackends"
      )
      route="PiPDismissalValidation"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    interruptions)
      test_identifiers=(
        "iOSUITests/PiPInterruptionDeviceUITests/test_audioInterruptionAndRouteLossAcrossNativeAndDirectBackends"
      )
      route="PiPInterruptionValidation"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    audio-session-ownership)
      test_identifiers=(
        "iOSUITests/AudioSessionOwnershipDeviceUITests/test_libraryAndApplicationManagedOwnershipIsExact"
      )
      route="AudioSessionOwnershipValidation"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    audio-media-services-reset)
      test_identifiers=(
        "iOSUITests/MediaServicesResetDeviceUITests/test_realMediaServicesResetQuarantinesAndRebuildsBothAppleOutputs"
      )
      route="MediaServicesResetValidation"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    native-lifecycle)
      test_identifiers=(
        "iOSUITests/PiPNativeLifecycleDeviceUITests/test_nativeLifecyclePublishesAuthoritativeOrderedEvents"
      )
      route="PiPNativeLifecycleValidation"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    playback-foreground-displaylayer-recovery)
      test_identifiers=(
        "iOSUITests/NativeRendererRecoveryDeviceUITests/test_pausedNativeRendererRecoversAfterRealOSRevocation"
      )
      route="NativeRendererRecoveryValidation"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    terminal-outcomes)
      test_identifiers=(
        "iOSUITests/TerminalOutcomesDeviceUITests/test_terminalOutcomeMatrixIsGenerationScopedAndPreReset"
      )
      route="TerminalOutcomesValidation"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    adaptive-hls-soak)
      test_identifiers=(
        "iOSUITests/AdaptiveHLSSoakDeviceUITests/test_adaptiveHLSMatrixSoakRemainsBounded"
      )
      route="AdaptiveHLSSoakValidation"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    pip-render-performance-1080p60)
      test_identifiers=(
        "iOSUITests/PiPRenderPerformanceDeviceUITests/test_directPiPPerformanceRow"
      )
      route="PiPRenderPerformanceValidation"
      performance_profile="1080p60"
      performance_url="$BASE_URL/files/performance/1080p60.mp4"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    pip-render-performance-4k60)
      test_identifiers=(
        "iOSUITests/PiPRenderPerformanceDeviceUITests/test_directPiPPerformanceRow"
      )
      route="PiPRenderPerformanceValidation"
      performance_profile="4k60"
      performance_url="$BASE_URL/files/performance/4k60.mp4"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    cadence-matrix)
      test_identifiers=(
        "iOSUITests/PiPCadenceDeviceUITests/test_directPiPCadenceMatrix"
      )
      route="PiPCadenceValidation"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    cadence-semantics-probe)
      test_identifiers=(
        "iOSUITests/PiPCadenceSemanticsProbeDeviceUITests/test_reportOnlyVmemCadenceSemanticsProbe"
      )
      route="PiPCadenceSemanticsProbe"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    native-subtitle-matrix)
      test_identifiers=(
        "iOSUITests/NativeSubtitleMatrixDeviceUITests/test_nativeSubtitleMatrixIsVisibleAndBounded"
      )
      route="NativeSubtitleMatrixValidation"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    timebase-vod-soak|timebase-live-soak)
      test_identifiers=(
        "iOSUITests/TimebaseSoakDeviceUITests/test_directPiPTimebaseSoak"
      )
      route="TimebaseSoakValidation"
      timebase_mode="${scenario#timebase-}"
      timebase_mode="${timebase_mode%-soak}"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    deferred-pause-rejection)
      test_identifiers=(
        "iOSUITests/PiPDeferredPauseDeviceUITests/test_deferredPauseRejectionAndCancellationStayTruthful"
      )
      route="PiPDeferredPauseValidation"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    hls-seek)
      test_identifiers=(
        "iOSUITests/PiPOverlayDeviceUITests/test_nativePiPOverlayTransitionsRemainOperational"
        "iOSUITests/PiPOverlayDeviceUITests/test_nativePiPHLSSeeksRemainActive"
      )
      route="HarnessHome"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    seek-frame-oracles)
      test_identifiers=(
        "iOSUITests/SeekFrameOracleDeviceUITests/test_seekAndFrameRequestsMatchDecodedContent"
      )
      route="SeekFrameOracleValidation"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    progressive-http-range-seek)
      test_identifiers=(
        "iOSUITests/ProgressiveHTTPRangeSeekDeviceUITests/test_progressiveRangeSeekUsesFresh206AndNoRangeRejectsStrictly"
      )
      route="ProgressiveHTTPRangeSeekValidation"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    local-file-matrix)
      test_identifiers=(
        "iOSUITests/LocalPlaybackMatrixDeviceUITests/test_localFileContainerCodecMatrixProducesMovingVideo"
      )
      route="LocalFileMatrixValidation"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    audio-only-playback)
      test_identifiers=(
        "iOSUITests/AudioOnlyPlaybackDeviceUITests/test_audioOnlyCodecMatrixAdvancesNativeOutput"
      )
      route="AudioOnlyPlaybackValidation"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    harness-regressions)
      test_identifiers=(
        "iOSUITests/MusicPlayerUITests/test_switchingTracksKeepsTransportStateAndDoesNotCrash"
        "iOSUITests/PiPUITests/test_deep_toggleButtonAvailabilityMatchesPiPPossibility"
      )
      route=""
      selected_xctestrun="$LAUNCH_XCTESTRUN"
      ;;
    ui-failures)
      test_identifiers=(
        "iOSUITests/ThumbnailScrubUITests"
        "iOSUITests/RelativeSeekUITests"
        "iOSUITests/VolumeUITests"
      )
      route=""
      selected_xctestrun="$LAUNCH_XCTESTRUN"
      ;;
    thumbnail-preview)
      test_identifiers=(
        "iOSUITests/ThumbnailScrubUITests/test_deep_scrubbingKeepsPreviewStableAcrossPositions"
        "iOSUITests/ThumbnailScrubUITests/test_deep_scrubbingShowsPreviewTileOnceLoaded"
        "iOSUITests/ThumbnailScrubUITests/test_perf_firstScrubPreviewAppearsWithinBudget"
      )
      route=""
      selected_xctestrun="$LAUNCH_XCTESTRUN"
      ;;
  esac

  log_name="$scenario.jsonl"
  if [[ -n "$route" ]]; then
    selected_xctestrun="$WORK_DIR/destination-$scenario.xctestrun"
    prepare_xctestrun "$XCTESTRUN" "$selected_xctestrun" \
      --environment SWIFTVLC_PIP_LIVE_URL_BASE64="$PIP_LIVE_URL_BASE64" \
      --environment SWIFTVLC_PIP_CONTINUITY_DEVICE=YES \
      --environment SWIFTVLC_PIP_CAPABILITY_DEVICE=YES \
      --environment SWIFTVLC_PIP_VOD_CONTROLS_DEVICE=YES \
      --environment SWIFTVLC_PIP_LONG_STALL_DEVICE=YES \
      --environment SWIFTVLC_PIP_LONG_STALL_URL_BASE64="$PIP_LONG_STALL_URL_BASE64" \
      --environment SWIFTVLC_PIP_DISMISSAL_DEVICE=YES \
      --environment SWIFTVLC_PIP_INTERRUPTION_DEVICE=YES \
      --environment SWIFTVLC_AUDIO_SESSION_OWNERSHIP_DEVICE=YES \
      --environment SWIFTVLC_AUDIO_MEDIA_SERVICES_RESET_DEVICE=YES \
      --environment SWIFTVLC_PIP_NATIVE_LIFECYCLE_DEVICE=YES \
      --environment SWIFTVLC_NATIVE_RENDERER_RECOVERY_DEVICE=YES \
      --environment SWIFTVLC_NATIVE_RENDERER_RECOVERY_URL_BASE64="$VOD_URL_BASE64" \
      --environment SWIFTVLC_TERMINAL_OUTCOMES_DEVICE=YES \
      --environment SWIFTVLC_ADAPTIVE_HLS_SOAK_DEVICE=YES \
      --environment SWIFTVLC_ADAPTIVE_SOAK_SECONDS="$ADAPTIVE_SOAK_SECONDS" \
      --environment SWIFTVLC_PIP_PERFORMANCE_DEVICE=YES \
      --environment SWIFTVLC_PIP_PERFORMANCE_PROFILE="$performance_profile" \
      --environment SWIFTVLC_PIP_PERFORMANCE_URL_BASE64="$(printf '%s' "$performance_url" | base64 | tr -d '\r\n')" \
      --environment SWIFTVLC_PIP_PERFORMANCE_SECONDS="$PIP_PERFORMANCE_SECONDS" \
      --environment SWIFTVLC_PIP_CADENCE_DEVICE=YES \
      --environment SWIFTVLC_PIP_CADENCE_SEMANTICS_PROBE=YES \
      --environment SWIFTVLC_PIP_CADENCE_BASE_URL_BASE64="$(printf '%s/' "$BASE_URL" | base64 | tr -d '\r\n')" \
      --environment SWIFTVLC_CADENCE_SECONDS="$CADENCE_SECONDS" \
      --environment SWIFTVLC_NATIVE_SUBTITLE_DEVICE=YES \
      --environment SWIFTVLC_NATIVE_SUBTITLE_BASE_URL_BASE64="$(printf '%s/' "$BASE_URL" | base64 | tr -d '\r\n')" \
      --environment SWIFTVLC_NATIVE_SUBTITLE_SECONDS="$NATIVE_SUBTITLE_SECONDS" \
      --environment SWIFTVLC_TIMEBASE_SOAK_DEVICE=YES \
      --environment SWIFTVLC_TIMEBASE_SOAK_BASE_URL_BASE64="$(printf '%s/' "$BASE_URL" | base64 | tr -d '\r\n')" \
      --environment SWIFTVLC_TIMEBASE_SOAK_SECONDS="$TIMEBASE_SOAK_SECONDS" \
      --environment SWIFTVLC_PIP_DEFERRED_PAUSE_DEVICE=YES \
      --environment SWIFTVLC_PIP_DELAYED_START_FAILURE_DEVICE=YES \
      --environment SWIFTVLC_PIP_OVERLAY_DEVICE=YES \
      --environment SWIFTVLC_PIP_SEEK_DEVICE=YES \
      --environment SWIFTVLC_SEEK_FRAME_ORACLE_DEVICE=YES \
      --environment SWIFTVLC_SEEK_FRAME_ORACLE_BASE_URL_BASE64="$(printf '%s/' "$BASE_URL" | base64 | tr -d '\r\n')" \
      --environment SWIFTVLC_PROGRESSIVE_HTTP_RANGE_DEVICE=YES \
      --environment SWIFTVLC_PROGRESSIVE_HTTP_RANGE_BASE_URL_BASE64="$PROGRESSIVE_HTTP_RANGE_BASE_URL_BASE64" \
      --environment SWIFTVLC_PROGRESSIVE_HTTP_RANGE_FIXTURE_SHA256="$PROGRESSIVE_HTTP_RANGE_FIXTURE_SHA256" \
      --environment SWIFTVLC_PROGRESSIVE_HTTP_RANGE_FIXTURE_BYTES="$PROGRESSIVE_HTTP_RANGE_FIXTURE_BYTES" \
      --environment SWIFTVLC_LOCAL_PLAYBACK_DEVICE=YES \
      --environment SWIFTVLC_LOCAL_PLAYBACK_BASE_URL_BASE64="$LOCAL_PLAYBACK_BASE_URL_BASE64" \
      --environment SWIFTVLC_DEVICE_LOG_PREFIX="$run_id-$scenario"
    cp "$selected_xctestrun" "$OUTPUT_DIR/destination-$scenario.xctestrun"
  elif [[ "$scenario" != "analyzer" ]]; then
    selected_xctestrun="$WORK_DIR/destination-$scenario.xctestrun"
    prepare_xctestrun "$XCTESTRUN" "$selected_xctestrun" \
      --environment SWIFTVLC_DEVICE_FIXTURE_URL_BASE64="$VOD_URL_BASE64" \
      --environment SWIFTVLC_DEVICE_LOG_PREFIX="$run_id-$scenario"
    cp "$selected_xctestrun" "$OUTPUT_DIR/destination-$scenario.xctestrun"
  fi

  local started ended test_status result error_count log_status evidence_status
  local allocation_trace_status="not-applicable"
  local allocation_trace=""
  local allocation_trace_toc=""
  local performance_trace_status="not-applicable"
  local perf_game_trace=""
  local perf_game_toc=""
  local perf_power_trace=""
  local perf_power_toc=""
  local perf_time_trace=""
  local perf_time_toc=""
  local subtitle_trace_status="not-applicable"
  local subtitle_game_trace=""
  local subtitle_game_toc=""
  local subtitle_time_trace=""
  local subtitle_time_toc=""
  local subtitle_metal_trace=""
  local subtitle_metal_toc=""
  local timebase_trace_status="not-applicable"
  local timebase_audio_trace=""
  local timebase_audio_toc=""
  local xcodebuild_log="$OUTPUT_DIR/$scenario-xcodebuild.log"
  local result_bundle="$OUTPUT_DIR/$scenario.xcresult"
  local test_selection_args=()
  local test_identifier
  for test_identifier in "${test_identifiers[@]}"; do
    test_selection_args+=("-only-testing:$test_identifier")
  done
  if [[ "$skip_device_tests" == true ]]; then
    local excluded_prefix exclusion_count=0
    while IFS= read -r excluded_prefix; do
      if [[ "$excluded_prefix" != iOSUITests/*/ ]]; then
        echo "Error: unsafe $scenario matrix exclusion prefix: $excluded_prefix" >&2
        return 1
      fi
      test_selection_args+=("-skip-testing:${excluded_prefix%/}")
      exclusion_count=$((exclusion_count + 1))
    done < <(
      jq -r --arg runner "$scenario" '
        .runnerContracts[]
        | select(.id == $runner)
        | .selection
        | select(.kind == "candidateExcludingPrefixes")
        | .prefixes[]
      ' "$SCRIPT_DIR/matrix.json"
    )
    if [[ "$exclusion_count" -eq 0 ]]; then
      echo "Error: $scenario has no matrix-owned XCTest exclusions." >&2
      return 1
    fi
  fi

  local scenario_catalog_raw="$WORK_DIR/$scenario-selected-catalog-raw.json"
  local scenario_expected_catalog="$OUTPUT_DIR/$scenario-expected-test-catalog.json"
  if ! run_with_watchdog 600 180 \
      "$OUTPUT_DIR/$scenario-enumerate-tests.log" \
      xcodebuild test-without-building \
      -parallel-testing-enabled NO \
      -xctestrun "$selected_xctestrun" \
      -derivedDataPath "$DERIVED_DATA" \
      -destination "platform=iOS,id=$DEVICE_UDID" \
      "${test_selection_args[@]}" \
      -enumerate-tests \
      -test-enumeration-style flat \
      -test-enumeration-format json \
      -test-enumeration-output-path "$scenario_catalog_raw"; then
    echo "Error: $scenario XCTest preflight enumeration failed." >&2
    return 1
  fi
  if ! python3 "$SCRIPT_DIR/qualification_policy.py" normalize-catalog \
      --input "$scenario_catalog_raw" \
      --full-catalog "$FULL_TEST_CATALOG" \
      --output "$scenario_expected_catalog"; then
    echo "Error: $scenario selected no concrete XCTest leaves." >&2
    return 1
  fi

  started=$(date +%s)
  local attempt attempt_log attempt_bundle attempt_xctestrun final_log_prefix
  local attempt_execution retry_classification final_test_execution
  local attempts_jsonl="$WORK_DIR/$scenario-attempts.jsonl"
  local attempts_json="$OUTPUT_DIR/$scenario-attempts.json"
  local attempt_artifact_root="$OUTPUT_DIR/$scenario-attempt-artifacts"
  local progressive_transcript_root=""
  local apple_audio_metrics_root=""
  local final_apple_audio_source_metrics=""
  mkdir -p "$attempt_artifact_root"
  if [[ "$scenario" == "progressive-http-range-seek" ]]; then
    progressive_transcript_root="$OUTPUT_DIR/progressive-http-range-seek-server-transcripts/$run_id-$scenario"
    mkdir -p "$progressive_transcript_root"
  elif [[ "$scenario" == "audio-media-services-reset" || "$scenario" == "audio-session-ownership" ]]; then
    apple_audio_metrics_root="$OUTPUT_DIR/apple-audio-source-metrics/$run_id-$scenario"
    mkdir -p "$apple_audio_metrics_root"
  fi
  : > "$attempts_jsonl"
  final_log_prefix="$run_id-$scenario"
  final_test_execution=""
  for attempt in 1 2 3; do
    attempt_log="$attempt_artifact_root/attempt-$attempt.log"
    attempt_bundle="$attempt_artifact_root/attempt-$attempt.xcresult"
    local attempt_log_relative="${attempt_log#"$OUTPUT_DIR/"}"
    local attempt_bundle_relative="${attempt_bundle#"$OUTPUT_DIR/"}"
    attempt_xctestrun="$selected_xctestrun"
    local attempt_token=""
    if [[ "$scenario" != "analyzer" ]]; then
      final_log_prefix="$run_id-$scenario-attempt$attempt"
      attempt_xctestrun="$WORK_DIR/destination-$scenario-attempt$attempt.xctestrun"
      if [[ "$scenario" == "adaptive-hls-soak" ]]; then
        attempt_token="$run_id-adaptive-$attempt"
        prepare_xctestrun \
          "$selected_xctestrun" "$attempt_xctestrun" \
          --environment SWIFTVLC_DEVICE_LOG_PREFIX="$final_log_prefix" \
          --environment SWIFTVLC_ADAPTIVE_SOAK_TOKEN="$attempt_token"
      elif [[ "$scenario" == "progressive-http-range-seek" ]]; then
        attempt_token="$final_log_prefix"
        prepare_xctestrun \
          "$selected_xctestrun" "$attempt_xctestrun" \
          --environment SWIFTVLC_DEVICE_LOG_PREFIX="$final_log_prefix" \
          --environment SWIFTVLC_PROGRESSIVE_HTTP_RANGE_ATTEMPT_TOKEN="$attempt_token"
      elif [[ "$scenario" == "audio-media-services-reset" ]]; then
        attempt_token="$run_id-audio-reset-$attempt"
        local reset_url="$BASE_URL/adaptive/$attempt_token/timebase-vod-ts/master.m3u8"
        local reset_url_base64
        reset_url_base64=$(printf '%s' "$reset_url" | base64 | tr -d '\r\n')
        prepare_xctestrun \
          "$selected_xctestrun" "$attempt_xctestrun" \
          --environment SWIFTVLC_DEVICE_LOG_PREFIX="$final_log_prefix" \
          --environment SWIFTVLC_AUDIO_MEDIA_SERVICES_RESET_URL_BASE64="$reset_url_base64"
      elif [[ "$scenario" == "audio-session-ownership" ]]; then
        attempt_token="$run_id-audio-ownership-$attempt"
        local ownership_url="$BASE_URL/adaptive/$attempt_token/timebase-vod-ts/master.m3u8"
        local ownership_url_base64
        ownership_url_base64=$(printf '%s' "$ownership_url" | base64 | tr -d '\r\n')
        prepare_xctestrun \
          "$selected_xctestrun" "$attempt_xctestrun" \
          --environment SWIFTVLC_DEVICE_LOG_PREFIX="$final_log_prefix" \
          --environment SWIFTVLC_AUDIO_SESSION_OWNERSHIP_URL_BASE64="$ownership_url_base64"
      else
        prepare_xctestrun \
          "$selected_xctestrun" "$attempt_xctestrun" \
          --environment SWIFTVLC_DEVICE_LOG_PREFIX="$final_log_prefix"
      fi
      cp "$attempt_xctestrun" \
        "$OUTPUT_DIR/destination-$scenario-attempt$attempt.xctestrun"
    fi
    if [[ "$scenario" == "adaptive-hls-soak" ]]; then
      allocation_trace_status="missing"
      allocation_trace="$OUTPUT_DIR/$scenario-allocations-attempt$attempt.trace"
      allocation_trace_toc="$OUTPUT_DIR/$scenario-allocations-attempt$attempt-toc.xml"
    elif [[ "$scenario" == pip-render-performance-* ]]; then
      attempt_token="$run_id-$performance_profile-$attempt"
      attempt_xctestrun="$WORK_DIR/destination-$scenario-attempt$attempt.xctestrun"
      local attempt_performance_url="$performance_url?swiftvlcQualification=$attempt_token"
      local attempt_performance_url_base64
      attempt_performance_url_base64=$(printf '%s' "$attempt_performance_url" | base64 | tr -d '\r\n')
      prepare_xctestrun \
        "$selected_xctestrun" "$attempt_xctestrun" \
        --environment SWIFTVLC_DEVICE_LOG_PREFIX="$final_log_prefix" \
        --environment SWIFTVLC_PIP_PERFORMANCE_URL_BASE64="$attempt_performance_url_base64"
      cp "$attempt_xctestrun" "$OUTPUT_DIR/destination-$scenario-attempt$attempt.xctestrun"
      performance_trace_status="missing"
      perf_game_trace="$OUTPUT_DIR/$scenario-game-attempt$attempt.trace"
      perf_game_toc="$OUTPUT_DIR/$scenario-game-attempt$attempt-toc.xml"
      perf_power_trace="$OUTPUT_DIR/$scenario-power-attempt$attempt.trace"
      perf_power_toc="$OUTPUT_DIR/$scenario-power-attempt$attempt-toc.xml"
      perf_time_trace="$OUTPUT_DIR/$scenario-time-attempt$attempt.trace"
      perf_time_toc="$OUTPUT_DIR/$scenario-time-attempt$attempt-toc.xml"
    elif [[ "$scenario" == "native-subtitle-matrix" ]]; then
      attempt_token="$run_id-subtitle-$attempt"
      attempt_xctestrun="$WORK_DIR/destination-$scenario-attempt$attempt.xctestrun"
      prepare_xctestrun \
        "$selected_xctestrun" "$attempt_xctestrun" \
        --environment SWIFTVLC_DEVICE_LOG_PREFIX="$final_log_prefix" \
        --environment SWIFTVLC_NATIVE_SUBTITLE_TOKEN="$attempt_token"
      cp "$attempt_xctestrun" "$OUTPUT_DIR/destination-$scenario-attempt$attempt.xctestrun"
      subtitle_trace_status="missing"
      subtitle_game_trace="$OUTPUT_DIR/$scenario-game-attempt$attempt.trace"
      subtitle_game_toc="$OUTPUT_DIR/$scenario-game-attempt$attempt-toc.xml"
      subtitle_time_trace="$OUTPUT_DIR/$scenario-time-attempt$attempt.trace"
      subtitle_time_toc="$OUTPUT_DIR/$scenario-time-attempt$attempt-toc.xml"
      subtitle_metal_trace="$OUTPUT_DIR/$scenario-metal-attempt$attempt.trace"
      subtitle_metal_toc="$OUTPUT_DIR/$scenario-metal-attempt$attempt-toc.xml"
    elif [[ "$scenario" == timebase-*-soak ]]; then
      attempt_token="$run_id-$timebase_mode-$attempt"
      attempt_xctestrun="$WORK_DIR/destination-$scenario-attempt$attempt.xctestrun"
      prepare_xctestrun \
        "$selected_xctestrun" "$attempt_xctestrun" \
        --environment SWIFTVLC_DEVICE_LOG_PREFIX="$final_log_prefix" \
        --environment SWIFTVLC_TIMEBASE_SOAK_MODE="$timebase_mode" \
        --environment SWIFTVLC_TIMEBASE_SOAK_TOKEN="$attempt_token"
      cp "$attempt_xctestrun" "$OUTPUT_DIR/destination-$scenario-attempt$attempt.xctestrun"
      timebase_trace_status="missing"
      timebase_audio_trace="$OUTPUT_DIR/$scenario-audio-attempt$attempt.trace"
      timebase_audio_toc="$OUTPUT_DIR/$scenario-audio-attempt$attempt-toc.xml"
    fi
    set +e
    if [[ "$scenario" == "adaptive-hls-soak" ]]; then
      run_with_watchdog "$((ADAPTIVE_SOAK_SECONDS + 900))" \
        "$((ADAPTIVE_SOAK_SECONDS + 600))" "$attempt_log" \
        xcodebuild test-without-building \
        -parallel-testing-enabled NO \
        -xctestrun "$attempt_xctestrun" \
        -derivedDataPath "$DERIVED_DATA" \
        -destination "platform=iOS,id=$DEVICE_UDID" \
        -collect-test-diagnostics never \
        -test-timeouts-enabled YES \
        -default-test-execution-time-allowance "$((ADAPTIVE_SOAK_SECONDS + 300))" \
        -maximum-test-execution-time-allowance "$((ADAPTIVE_SOAK_SECONDS + 300))" \
        "${test_selection_args[@]}" \
        -resultBundlePath "$attempt_bundle" &
      local xcodebuild_pid=$!
      ACTIVE_XCODEBUILD_PID="$xcodebuild_pid"
      local xctrace_pid=""
      local trace_exited_early=false
      for _ in {1..300}; do
        if ! kill -0 "$xcodebuild_pid" 2>/dev/null; then
          break
        fi
        if curl -fsS "$BASE_URL/adaptive/$attempt_token/metrics" 2>/dev/null \
            | jq -e '.masterRequests > 0' >/dev/null 2>&1; then
          xcrun xctrace record --quiet \
            --template Allocations \
            --device "$DEVICE_UDID" \
            --attach iOS \
            --time-limit "$((ADAPTIVE_SOAK_SECONDS + 300))s" \
            --window 15m \
            --output "$allocation_trace" \
            --no-prompt \
            > "$OUTPUT_DIR/$scenario-xctrace-attempt$attempt.log" 2>&1 &
          xctrace_pid=$!
          ACTIVE_XCTRACE_PID="$xctrace_pid"
          break
        fi
        sleep 0.2
      done
      if [[ -n "$xctrace_pid" ]]; then
        while kill -0 "$xcodebuild_pid" 2>/dev/null; do
          if ! kill -0 "$xctrace_pid" 2>/dev/null; then
            if curl -fsS "$BASE_URL/adaptive/$attempt_token/metrics" 2>/dev/null \
                | jq -e '.clientCompleted == true' >/dev/null 2>&1; then
              break
            fi
            trace_exited_early=true
            echo "Error: allocation trace exited before the soak completed." >> "$attempt_log"
            kill -TERM "$xcodebuild_pid" 2>/dev/null
            break
          fi
          sleep 1
        done
      fi
      wait "$xcodebuild_pid"
      test_status=$?
      ACTIVE_XCODEBUILD_PID=""
      if [[ -n "$xctrace_pid" ]]; then
        if kill -0 "$xctrace_pid" 2>/dev/null; then
          kill -INT "$xctrace_pid" 2>/dev/null
        fi
        for _ in {1..100}; do
          if ! kill -0 "$xctrace_pid" 2>/dev/null; then
            break
          fi
          sleep 0.1
        done
        if kill -0 "$xctrace_pid" 2>/dev/null; then
          kill -TERM "$xctrace_pid" 2>/dev/null
        fi
        for _ in {1..50}; do
          if ! kill -0 "$xctrace_pid" 2>/dev/null; then
            break
          fi
          sleep 0.1
        done
        if kill -0 "$xctrace_pid" 2>/dev/null; then
          kill -KILL "$xctrace_pid" 2>/dev/null
        fi
        wait "$xctrace_pid" 2>/dev/null
        ACTIVE_XCTRACE_PID=""
      fi
      if [[ "$trace_exited_early" == false ]] && [[ -d "$allocation_trace" ]]; then
        python3 - "$allocation_trace" "$allocation_trace_toc" \
            > "$OUTPUT_DIR/$scenario-xctrace-export-attempt$attempt.log" 2>&1 <<'PY'
import subprocess
import sys

try:
    result = subprocess.run(
        [
            "xcrun", "xctrace", "export", "--quiet",
            "--input", sys.argv[1], "--toc", "--output", sys.argv[2],
        ],
        timeout=120,
    )
except subprocess.TimeoutExpired:
    raise SystemExit(124)
raise SystemExit(result.returncode)
PY
        local trace_export_status=$?
        if [[ "$trace_export_status" -eq 0 ]] \
          && [[ -s "$allocation_trace_toc" ]] \
          && grep -qiE 'allocation|vm-tracker' "$allocation_trace_toc"; then
          allocation_trace_status="captured"
        fi
      fi
    elif [[ "$scenario" == pip-render-performance-* ]]; then
      run_with_watchdog "$((PIP_PERFORMANCE_SECONDS + 900))" \
        "$((PIP_PERFORMANCE_SECONDS + 600))" "$attempt_log" \
        xcodebuild test-without-building \
        -parallel-testing-enabled NO \
        -xctestrun "$attempt_xctestrun" \
        -derivedDataPath "$DERIVED_DATA" \
        -destination "platform=iOS,id=$DEVICE_UDID" \
        -collect-test-diagnostics never \
        -test-timeouts-enabled YES \
        -default-test-execution-time-allowance "$((PIP_PERFORMANCE_SECONDS + 300))" \
        -maximum-test-execution-time-allowance "$((PIP_PERFORMANCE_SECONDS + 300))" \
        "${test_selection_args[@]}" \
        -resultBundlePath "$attempt_bundle" &
      local performance_xcodebuild_pid=$!
      ACTIVE_XCODEBUILD_PID="$performance_xcodebuild_pid"
      local performance_started=false
      for _ in {1..600}; do
        if ! kill -0 "$performance_xcodebuild_pid" 2>/dev/null; then
          break
        fi
        if grep -q "$attempt_token" "$OUTPUT_DIR/fixture-requests.jsonl" 2>/dev/null; then
          performance_started=true
          break
        fi
        sleep 0.1
      done
      local performance_trace_failed=false
      local performance_phase_seconds=$(((PIP_PERFORMANCE_SECONDS - 120) / 3))
      if [[ "$performance_phase_seconds" -lt 60 ]]; then
        performance_phase_seconds=60
      fi
      if [[ "$performance_started" == false ]]; then
        performance_trace_failed=true
        echo "Error: performance fixture did not start before trace capture." >> "$attempt_log"
      else
        local performance_spec performance_key performance_template performance_trace performance_toc
        for performance_spec in \
          "game|Game Performance|$perf_game_trace|$perf_game_toc" \
          "power|Power Profiler|$perf_power_trace|$perf_power_toc" \
          "time|Time Profiler|$perf_time_trace|$perf_time_toc"; do
          IFS='|' read -r performance_key performance_template performance_trace performance_toc \
            <<< "$performance_spec"
          if ! record_performance_trace \
              "$performance_template" "$performance_trace" "$performance_toc" \
              "$performance_phase_seconds" "$performance_xcodebuild_pid" \
              "$OUTPUT_DIR/$scenario-$performance_key-xctrace-attempt$attempt.log"; then
            performance_trace_failed=true
            echo "Error: $performance_template trace capture failed." >> "$attempt_log"
            break
          fi
        done
      fi
      if [[ "$performance_trace_failed" == true ]]; then
        kill -TERM "$performance_xcodebuild_pid" 2>/dev/null
      fi
      wait "$performance_xcodebuild_pid"
      test_status=$?
      ACTIVE_XCODEBUILD_PID=""
      if [[ "$performance_trace_failed" == true ]]; then
        test_status=1
      elif [[ "$test_status" -eq 0 ]]; then
        performance_trace_status="captured"
      fi
    elif [[ "$scenario" == "cadence-matrix" ]]; then
      run_with_watchdog "$((CADENCE_SECONDS + 600))" \
        "$((CADENCE_SECONDS + 300))" "$attempt_log" \
        xcodebuild test-without-building \
        -parallel-testing-enabled NO \
        -xctestrun "$attempt_xctestrun" \
        -derivedDataPath "$DERIVED_DATA" \
        -destination "platform=iOS,id=$DEVICE_UDID" \
        -collect-test-diagnostics never \
        -test-timeouts-enabled YES \
        -default-test-execution-time-allowance "$((CADENCE_SECONDS + 300))" \
        -maximum-test-execution-time-allowance "$((CADENCE_SECONDS + 300))" \
        "${test_selection_args[@]}" \
        -resultBundlePath "$attempt_bundle"
      test_status=$?
    elif [[ "$scenario" == "cadence-semantics-probe" ]]; then
      run_with_watchdog \
        "$CADENCE_SEMANTICS_PROBE_WALL_WATCHDOG_SECONDS" \
        "$CADENCE_SEMANTICS_PROBE_IDLE_WATCHDOG_SECONDS" "$attempt_log" \
        xcodebuild test-without-building \
        -parallel-testing-enabled NO \
        -xctestrun "$attempt_xctestrun" \
        -derivedDataPath "$DERIVED_DATA" \
        -destination "platform=iOS,id=$DEVICE_UDID" \
        -collect-test-diagnostics never \
        -test-timeouts-enabled YES \
        -default-test-execution-time-allowance \
        "$CADENCE_SEMANTICS_PROBE_XCTEST_ALLOWANCE_SECONDS" \
        -maximum-test-execution-time-allowance \
        "$CADENCE_SEMANTICS_PROBE_XCTEST_ALLOWANCE_SECONDS" \
        "${test_selection_args[@]}" \
        -resultBundlePath "$attempt_bundle"
      test_status=$?
    elif [[ "$scenario" == "native-subtitle-matrix" ]]; then
      run_with_watchdog "$((NATIVE_SUBTITLE_SECONDS + 900))" \
        "$((NATIVE_SUBTITLE_SECONDS + 600))" "$attempt_log" \
        xcodebuild test-without-building \
        -parallel-testing-enabled NO \
        -xctestrun "$attempt_xctestrun" \
        -derivedDataPath "$DERIVED_DATA" \
        -destination "platform=iOS,id=$DEVICE_UDID" \
        -collect-test-diagnostics never \
        -test-timeouts-enabled YES \
        -default-test-execution-time-allowance "$((NATIVE_SUBTITLE_SECONDS + 300))" \
        -maximum-test-execution-time-allowance "$((NATIVE_SUBTITLE_SECONDS + 300))" \
        "${test_selection_args[@]}" \
        -resultBundlePath "$attempt_bundle" &
      local subtitle_xcodebuild_pid=$!
      ACTIVE_XCODEBUILD_PID="$subtitle_xcodebuild_pid"
      local subtitle_started=false
      for _ in {1..600}; do
        if ! kill -0 "$subtitle_xcodebuild_pid" 2>/dev/null; then
          break
        fi
        if grep -q "$attempt_token" "$OUTPUT_DIR/fixture-requests.jsonl" 2>/dev/null; then
          subtitle_started=true
          break
        fi
        sleep 0.1
      done
      local subtitle_trace_failed=false
      local subtitle_phase_seconds=$(((NATIVE_SUBTITLE_SECONDS - 120) / 3))
      if [[ "$subtitle_phase_seconds" -lt 60 ]]; then
        subtitle_phase_seconds=60
      fi
      if [[ "$subtitle_started" == false ]]; then
        subtitle_trace_failed=true
        echo "Error: subtitle fixture did not start before trace capture." >> "$attempt_log"
      else
        local subtitle_spec subtitle_key subtitle_template subtitle_trace subtitle_toc
        for subtitle_spec in \
          "time|Time Profiler|$subtitle_time_trace|$subtitle_time_toc" \
          "game|Game Performance|$subtitle_game_trace|$subtitle_game_toc" \
          "metal|Metal System Trace|$subtitle_metal_trace|$subtitle_metal_toc"; do
          IFS='|' read -r subtitle_key subtitle_template subtitle_trace subtitle_toc \
            <<< "$subtitle_spec"
          if ! record_performance_trace \
              "$subtitle_template" "$subtitle_trace" "$subtitle_toc" \
              "$subtitle_phase_seconds" "$subtitle_xcodebuild_pid" \
              "$OUTPUT_DIR/$scenario-$subtitle_key-xctrace-attempt$attempt.log"; then
            subtitle_trace_failed=true
            echo "Error: $subtitle_template trace capture failed." >> "$attempt_log"
            break
          fi
        done
      fi
      if [[ "$subtitle_trace_failed" == true ]]; then
        kill -TERM "$subtitle_xcodebuild_pid" 2>/dev/null
      fi
      wait "$subtitle_xcodebuild_pid"
      test_status=$?
      ACTIVE_XCODEBUILD_PID=""
      if [[ "$subtitle_trace_failed" == true ]]; then
        test_status=1
      elif [[ "$test_status" -eq 0 ]]; then
        subtitle_trace_status="captured"
      fi
    elif [[ "$scenario" == timebase-*-soak ]]; then
      run_with_watchdog "$((TIMEBASE_SOAK_SECONDS + 1200))" \
        "$((TIMEBASE_SOAK_SECONDS + 900))" "$attempt_log" \
        xcodebuild test-without-building \
        -parallel-testing-enabled NO \
        -xctestrun "$attempt_xctestrun" \
        -derivedDataPath "$DERIVED_DATA" \
        -destination "platform=iOS,id=$DEVICE_UDID" \
        -collect-test-diagnostics never \
        -test-timeouts-enabled YES \
        -default-test-execution-time-allowance "$((TIMEBASE_SOAK_SECONDS + 600))" \
        -maximum-test-execution-time-allowance "$((TIMEBASE_SOAK_SECONDS + 600))" \
        "${test_selection_args[@]}" \
        -resultBundlePath "$attempt_bundle" &
      local timebase_xcodebuild_pid=$!
      ACTIVE_XCODEBUILD_PID="$timebase_xcodebuild_pid"
      local timebase_started=false
      for _ in {1..600}; do
        if ! kill -0 "$timebase_xcodebuild_pid" 2>/dev/null; then
          break
        fi
        if grep -q "swiftvlcTimebaseReady=$attempt_token" "$OUTPUT_DIR/fixture-requests.jsonl" 2>/dev/null; then
          timebase_started=true
          break
        fi
        sleep 0.1
      done
      local timebase_trace_failed=false
      if [[ "$timebase_started" == false ]]; then
        timebase_trace_failed=true
        echo "Error: timebase fixture did not start before Audio System Trace capture." >> "$attempt_log"
      elif ! record_performance_trace \
          "Audio System Trace" "$timebase_audio_trace" "$timebase_audio_toc" \
          "$TIMEBASE_SOAK_SECONDS" "$timebase_xcodebuild_pid" \
          "$OUTPUT_DIR/$scenario-audio-xctrace-attempt$attempt.log"; then
        timebase_trace_failed=true
        echo "Error: Audio System Trace capture failed." >> "$attempt_log"
      fi
      if [[ "$timebase_trace_failed" == true ]]; then
        kill -TERM "$timebase_xcodebuild_pid" 2>/dev/null
      fi
      wait "$timebase_xcodebuild_pid"
      test_status=$?
      ACTIVE_XCODEBUILD_PID=""
      if [[ "$timebase_trace_failed" == true ]]; then
        test_status=1
      elif [[ "$test_status" -eq 0 ]]; then
        timebase_trace_status="captured"
      fi
    elif [[ "$scenario" == "audio-session-ownership" ]]; then
      run_with_watchdog 900 660 "$attempt_log" \
        xcodebuild test-without-building \
        -parallel-testing-enabled NO \
        -xctestrun "$attempt_xctestrun" \
        -derivedDataPath "$DERIVED_DATA" \
        -destination "platform=iOS,id=$DEVICE_UDID" \
        -collect-test-diagnostics never \
        -test-timeouts-enabled YES \
        -default-test-execution-time-allowance 600 \
        -maximum-test-execution-time-allowance 600 \
        "${test_selection_args[@]}" \
        -resultBundlePath "$attempt_bundle"
      test_status=$?
    elif [[ "$scenario" == "audio-media-services-reset" ]]; then
      local reset_readiness_marker="SWIFTVLC_AUDIO_RESET_READY_FOR_OPERATOR:$attempt_token"
      local reset_ready=false
      run_with_watchdog 1200 660 "$attempt_log" \
        xcodebuild test-without-building \
        -parallel-testing-enabled NO \
        -xctestrun "$attempt_xctestrun" \
        -derivedDataPath "$DERIVED_DATA" \
        -destination "platform=iOS,id=$DEVICE_UDID" \
        -collect-test-diagnostics never \
        -test-timeouts-enabled YES \
        -default-test-execution-time-allowance 900 \
        -maximum-test-execution-time-allowance 900 \
        "${test_selection_args[@]}" \
        -resultBundlePath "$attempt_bundle" &
      local reset_xcodebuild_pid=$!
      ACTIVE_XCODEBUILD_PID="$reset_xcodebuild_pid"
      for _ in {1..600}; do
        if grep -Fq -- "$reset_readiness_marker" "$attempt_log"; then
          reset_ready=true
          break
        fi
        if ! kill -0 "$reset_xcodebuild_pid" 2>/dev/null; then
          break
        fi
        sleep 0.5
      done
      if [[ "$reset_ready" == true ]]; then
        cat >&2 <<EOF

========================================================================
ACTION REQUIRED — REAL MEDIA SERVICES RESET (attempt $attempt)

SwiftVLC has proven moving system Picture in Picture, returned to the Home
Screen, and armed attempt token $attempt_token. On the connected iPhone:
  1. Open Settings > Developer.
  2. Run Reset Media Services and confirm if iOS asks.
  3. Return to the SwiftVLC showcase app if iOS does not do so automatically.

The XCTest waits up to 10 minutes for the real reset. Do not simulate or post
notifications. Product failures are final; only classified infrastructure
failures can cause another attempt and another prompt.
========================================================================

EOF
      elif kill -0 "$reset_xcodebuild_pid" 2>/dev/null; then
        echo "Error: reset test did not publish its operator-readiness marker." \
          >> "$attempt_log"
        kill -TERM "$reset_xcodebuild_pid" 2>/dev/null
      fi
      wait "$reset_xcodebuild_pid"
      test_status=$?
      ACTIVE_XCODEBUILD_PID=""
      if [[ "$reset_ready" != true ]]; then
        test_status=1
      fi
    else
      run_with_watchdog 1800 900 "$attempt_log" \
        xcodebuild test-without-building \
        -parallel-testing-enabled NO \
        -xctestrun "$attempt_xctestrun" \
        -derivedDataPath "$DERIVED_DATA" \
        -destination "platform=iOS,id=$DEVICE_UDID" \
        -collect-test-diagnostics never \
        "${test_selection_args[@]}" \
        -resultBundlePath "$attempt_bundle"
      test_status=$?
    fi
    set -e
    if [[ "$test_status" -eq 0 ]] \
      && [[ "$scenario" == "audio-media-services-reset" || "$scenario" == "audio-session-ownership" ]]; then
      local apple_audio_source_metrics="$apple_audio_metrics_root/attempt-$attempt.json"
      local minimum_audio_segments=2
      if [[ "$scenario" == "audio-session-ownership" ]]; then
        minimum_audio_segments=6
      fi
      if capture_apple_audio_source_metrics \
          "$attempt_token" "$minimum_audio_segments" \
          "$apple_audio_source_metrics"; then
        final_apple_audio_source_metrics="$apple_audio_source_metrics"
      else
        echo "Error: host could not retain exact quiescent source metrics for $attempt_token." \
          >> "$attempt_log"
        test_status=1
      fi
    fi
    if [[ "$scenario" == "progressive-http-range-seek" ]]; then
      local transcript_path="$progressive_transcript_root/attempt-$attempt.json"
      local transcript_temp="$transcript_path.tmp"
      local transcript_captured=false
      for _ in {1..100}; do
        if curl -fsS "$BASE_URL/progressive/$attempt_token/transcript" \
            > "$transcript_temp" 2>/dev/null \
          && jq -e --arg token "$attempt_token" '
            .formatVersion == 1
            and .token == $token
            and (.events | type == "array")
            and all(.events[];
              .kind != "media-request"
              or (.responseStatus | type == "number")
                and (.responseContentLength | type == "number")
                and (.completedAtUTC | type == "string"))
          ' "$transcript_temp" > /dev/null; then
          mv "$transcript_temp" "$transcript_path"
          transcript_captured=true
          break
        fi
        sleep 0.1
      done
      rm -f "$transcript_temp"
      if [[ "$transcript_captured" != true ]]; then
        echo "Error: progressive server transcript was not quiescent/capturable." \
          >> "$attempt_log"
        test_status=1
      fi
    fi
    if [[ "$test_status" -eq 0 ]]; then
      attempt_execution="$OUTPUT_DIR/$scenario-test-execution-attempt$attempt.json"
      if [[ -d "$attempt_bundle" ]] \
        && python3 "$SCRIPT_DIR/qualification_policy.py" verify-xcresult \
          --xcresult "$attempt_bundle" \
          --expected-catalog "$scenario_expected_catalog" \
          --output "$attempt_execution" \
          > "$OUTPUT_DIR/$scenario-verify-xcresult-attempt$attempt.log" 2>&1; then
        jq -nc \
          --argjson attempt "$attempt" \
          --arg log "$attempt_log_relative" \
          --arg xcresult "$attempt_bundle_relative" \
          --slurpfile execution "$attempt_execution" \
          '{attempt: $attempt, classification: "passed", retryable: false,
            intendedTestBegan: true, xcodebuildExitCode: 0,
            logArtifact: $log, xcresultArtifact: $xcresult,
            testExecution: $execution[0]}' \
          >> "$attempts_jsonl"
        final_test_execution="$attempt_execution"
        break
      fi
      echo "Error: XCTest execution identity/count did not match preflight." >> "$attempt_log"
      test_status=1
      # A zero-exit run that executed the wrong catalog is deterministic test
      # selection/provenance failure, never infrastructure-only retry state.
      retry_classification="$OUTPUT_DIR/$scenario-retry-classification-attempt$attempt.json"
      set +e
      retry_args=(
        classify-retry
        --log "$attempt_log"
        --expected-catalog "$scenario_expected_catalog"
        --output "$retry_classification"
      )
      if [[ -d "$attempt_bundle" ]]; then
        retry_args+=(--xcresult "$attempt_bundle")
      fi
      python3 "$SCRIPT_DIR/qualification_policy.py" "${retry_args[@]}"
      set -e
      jq -c \
        --argjson attempt "$attempt" \
        --arg log "$attempt_log_relative" \
        --arg xcresult "$attempt_bundle_relative" \
        '. + {attempt: $attempt, xcodebuildExitCode: 0,
          terminalReason: "XCTest execution identity/count mismatch",
          logArtifact: $log, xcresultArtifact: $xcresult}' \
        "$retry_classification" >> "$attempts_jsonl"
      break
    fi
    retry_classification="$OUTPUT_DIR/$scenario-retry-classification-attempt$attempt.json"
    set +e
    retry_args=(
      classify-retry
      --log "$attempt_log"
      --expected-catalog "$scenario_expected_catalog"
      --output "$retry_classification"
    )
    if [[ -d "$attempt_bundle" ]]; then
      retry_args+=(--xcresult "$attempt_bundle")
    fi
    python3 "$SCRIPT_DIR/qualification_policy.py" "${retry_args[@]}"
    local retry_status=$?
    set -e
    jq -c \
      --argjson attempt "$attempt" \
      --argjson exitCode "$test_status" \
      --arg log "$attempt_log_relative" \
      --arg xcresult "$attempt_bundle_relative" \
      '. + {attempt: $attempt, xcodebuildExitCode: $exitCode,
        logArtifact: $log, xcresultArtifact: $xcresult}' \
      "$retry_classification" >> "$attempts_jsonl"
    if [[ "$retry_status" -ne 0 ]] \
      || [[ "$attempt" -eq 3 ]] \
      || { [[ "$scenario" == "adaptive-hls-soak" ]] && [[ "$trace_exited_early" == true ]]; }; then
      break
    fi
    sleep 3
  done
  jq -s '.' "$attempts_jsonl" > "$attempts_json"
  python3 "$SCRIPT_DIR/qualification_policy.py" bind-attempt-artifacts \
    --input "$attempts_json" \
    --artifact-root "$OUTPUT_DIR" \
    --output "$attempts_json"
  cp "$attempt_log" "$xcodebuild_log"
  if [[ -d "$attempt_bundle" ]]; then
    cp -R "$attempt_bundle" "$result_bundle"
  fi
  local test_execution=""
  if [[ -n "$final_test_execution" && -f "$final_test_execution" ]]; then
    test_execution="$OUTPUT_DIR/$scenario-test-execution.json"
    cp "$final_test_execution" "$test_execution"
  fi
  ended=$(date +%s)

  error_count=0
  local error_inventory=""
  log_status="none"
  evidence_status="not-applicable"
  if [[ "$scenario" == "ui-suite" || "$scenario" == "harness-regressions" || "$scenario" == "ui-failures" || "$scenario" == "thumbnail-preview" || -n "$route" ]]; then
    local document_capture="$OUTPUT_DIR/$scenario-documents"
    set +e
    xcrun devicectl device copy from \
      --device "$DEVICE_UDID" \
      --domain-type appDataContainer \
      --domain-identifier "$CANDIDATE_BUNDLE_IDENTIFIER" \
      --source Documents \
      --destination "$document_capture" \
      > "$OUTPUT_DIR/$scenario-pull-log.log" 2>&1
    local pull_status=$?
    set -e
    if [[ "$pull_status" -eq 0 ]]; then
      error_inventory="$OUTPUT_DIR/$scenario-error-inventory.json"
      set +e
      python3 "$SCRIPT_DIR/qualification_policy.py" build-error-inventory \
        --log-root "$document_capture" \
        --log-prefix "$final_log_prefix" \
        --source-prefix "$run_id-$scenario" \
        --scenario "$scenario" \
        --retained-root "$scenario-raw-jsonl" \
        --retained-base "$OUTPUT_DIR" \
        --expected-catalog "$scenario_expected_catalog" \
        --output "$error_inventory" \
        > "$OUTPUT_DIR/$scenario-error-inventory.log" 2>&1
      local aggregate_status=$?
      set -e
      if [[ "$aggregate_status" -eq 0 ]]; then
        error_count=$(jq -r '.errorCount' "$error_inventory")
        log_status="captured"
      else
        error_inventory=""
        error_count=0
        log_status="missing"
      fi
    else
      log_status="missing"
    fi
  fi

  # Terminal outcomes deliberately drives engine failures, while the adaptive
  # soak deliberately injects recoverable HTTP failures. Preserve their raw
  # logs, but let their typed assertions reject sanitizer signatures,
  # unbounded recovery, or incorrect attribution. Other scenarios retain the
  # strict zero-error gate.
  local log_errors_acceptable=false
  if [[ "$error_count" -eq 0 || "$scenario" == "terminal-outcomes" || "$scenario" == "adaptive-hls-soak" ]]; then
    log_errors_acceptable=true
  fi

  if [[ "$scenario" == "cadence-semantics-probe" ]]; then
    # Preserve the ordinary XCTest JSON attachment for human/engineering
    # inspection. Mark it report-only only after the retained passing xcresult,
    # exact XCTest owner/catalog, export, and raw cadence/motion semantics all
    # reconcile. It never enters materialize-evidence.py, qualification rows,
    # or the release policy.
    evidence_status="missing"
    local probe_proof="$OUTPUT_DIR/$scenario-report-only-evidence.json"
    rm -f "$probe_proof"
    if [[ "$test_status" -eq 0 ]] \
      && [[ "$log_status" == "captured" ]] \
      && [[ "$error_count" -eq 0 ]] \
      && [[ -d "$result_bundle" ]]; then
      local probe_attachments="$OUTPUT_DIR/$scenario-attachments"
      if xcrun xcresulttool export attachments \
          --path "$result_bundle" \
          --output-path "$probe_attachments" \
          > "$OUTPUT_DIR/$scenario-export-attachments.log" 2>&1 \
        && python3 "$SCRIPT_DIR/qualification_policy.py" \
          validate-cadence-semantics-probe \
          --artifact-root "$OUTPUT_DIR" \
          --expected-catalog "$scenario_expected_catalog" \
          --test-execution "$test_execution" \
          --attempts "$attempts_json" \
          --version "$VERSION" \
          --output "$probe_proof" \
          > "$OUTPUT_DIR/$scenario-validate-report-only.log" 2>&1; then
        evidence_status="report-only"
      fi
    fi
  fi

  local qualification_scenarios=()
  local qualification_attachments=()
  case "$scenario" in
    hls-seek)
      qualification_scenarios=("native-hls-seek-continuity")
      qualification_attachments=("qualification-native-hls-seek-continuity.json")
      ;;
    live-media)
      qualification_scenarios=("live-media")
      qualification_attachments=("qualification-live-media.json")
      ;;
    background-audio)
      qualification_scenarios=("background-audio")
      qualification_attachments=("qualification-background-audio.json")
      ;;
    continuity)
      qualification_scenarios=("replacement")
      qualification_attachments=("qualification-replacement.json")
      if can_run_iphone_current_lanes; then
        qualification_scenarios+=("replacement-continuity")
        qualification_attachments+=("qualification-replacement-continuity.json")
      fi
      ;;
    capability-convergence)
      qualification_scenarios=("capability-convergence")
      qualification_attachments=("qualification-capability-convergence.json")
      ;;
    vod-controls)
      qualification_scenarios=("vod-controls")
      qualification_attachments=("qualification-vod-controls.json")
      ;;
    long-stall)
      qualification_scenarios=("long-stall")
      qualification_attachments=("qualification-long-stall.json")
      ;;
    failed-start)
      qualification_scenarios=("failed-start")
      qualification_attachments=("qualification-failed-start.json")
      if can_run_iphone_current_lanes; then
        qualification_scenarios+=("accepted-start-delayed-failure")
        qualification_attachments+=("qualification-accepted-start-delayed-failure.json")
      fi
      ;;
    dismissal)
      qualification_scenarios=("restore" "close")
      qualification_attachments=("qualification-restore.json" "qualification-close.json")
      ;;
    interruptions)
      qualification_scenarios=("interruptions")
      qualification_attachments=("qualification-interruptions.json")
      ;;
    audio-session-ownership)
      qualification_scenarios=("audio-session-ownership")
      qualification_attachments=("qualification-audio-session-ownership.json")
      ;;
    audio-media-services-reset)
      qualification_scenarios=("audio-media-services-reset")
      qualification_attachments=("qualification-audio-media-services-reset.json")
      ;;
    native-lifecycle)
      qualification_scenarios=("native-lifecycle")
      qualification_attachments=("qualification-native-lifecycle.json")
      ;;
    playback-foreground-displaylayer-recovery)
      qualification_scenarios=("playback-foreground-displaylayer-recovery")
      qualification_attachments=("qualification-playback-foreground-displaylayer-recovery.json")
      ;;
    terminal-outcomes)
      qualification_scenarios=("terminal-outcomes")
      qualification_attachments=("qualification-terminal-outcomes.json")
      ;;
    adaptive-hls-soak)
      qualification_scenarios=("adaptive-hls-soak")
      qualification_attachments=("qualification-adaptive-hls-soak.json")
      ;;
    pip-render-performance-1080p60|pip-render-performance-4k60)
      qualification_scenarios=("$scenario")
      qualification_attachments=("qualification-$scenario.json")
      ;;
    cadence-matrix)
      qualification_scenarios=("cadence-matrix")
      qualification_attachments=("qualification-cadence-matrix.json")
      ;;
    native-subtitle-matrix)
      qualification_scenarios=("native-subtitle-matrix")
      qualification_attachments=("qualification-native-subtitle-matrix.json")
      ;;
    timebase-vod-soak|timebase-live-soak)
      qualification_scenarios=("$scenario")
      qualification_attachments=("qualification-$scenario.json")
      ;;
    deferred-pause-rejection)
      qualification_scenarios=("deferred-pause-rejection")
      qualification_attachments=("qualification-deferred-pause-rejection.json")
      ;;
    seek-frame-oracles)
      qualification_scenarios=("seek-frame-oracles")
      qualification_attachments=("qualification-seek-frame-oracles.json")
      ;;
    progressive-http-range-seek)
      qualification_scenarios=("progressive-http-range-seek")
      qualification_attachments=("qualification-progressive-http-range-seek.json")
      ;;
    local-file-matrix)
      qualification_scenarios=("local-file-matrix")
      qualification_attachments=("qualification-local-file-matrix.json")
      ;;
    audio-only-playback)
      qualification_scenarios=("audio-only-playback")
      qualification_attachments=("qualification-audio-only-playback.json")
      ;;
  esac
  if [[ ${#qualification_scenarios[@]} -gt 0 ]]; then
    evidence_status="missing"
    if [[ "$test_status" -eq 0 ]] && [[ "$log_errors_acceptable" == true ]] \
      && [[ "$allocation_trace_status" != "missing" ]] \
      && [[ "$performance_trace_status" != "missing" ]] \
      && [[ "$subtitle_trace_status" != "missing" ]] \
      && [[ "$timebase_trace_status" != "missing" ]] \
      && [[ "$log_status" == "captured" ]] && [[ -d "$result_bundle" ]]; then
      local attachments="$OUTPUT_DIR/$scenario-attachments"
      local hardware_id evidence_file evidence_relative export_status materialize_status
      local evidence_index qualification_scenario qualification_attachment
      local materialized_scenarios=()
      local materialized_evidence=()
      local materialized_count=0
      set +e
      xcrun xcresulttool export attachments \
        --path "$result_bundle" \
        --output-path "$attachments" \
        > "$OUTPUT_DIR/$scenario-export-attachments.log" 2>&1
      export_status=$?
      set -e
      hardware_id=$(jq -r '.selected.matchingHardwareRows | if length == 1 then .[0] else "" end' \
        "$OUTPUT_DIR/device.json")
      if [[ -z "$hardware_id" ]] && [[ -n "$EXPLORATORY_HARDWARE_ID" ]]; then
        hardware_id="$EXPLORATORY_HARDWARE_ID"
      fi
      if [[ "$export_status" -eq 0 ]] && [[ -n "$hardware_id" ]]; then
        for evidence_index in "${!qualification_scenarios[@]}"; do
          qualification_scenario="${qualification_scenarios[$evidence_index]}"
          qualification_attachment="${qualification_attachments[$evidence_index]}"
          evidence_relative="evidence/$qualification_scenario-$hardware_id.json"
          evidence_file="$OUTPUT_DIR/$evidence_relative"
          local materialize_extra_args=()
          if [[ "$scenario" == "progressive-http-range-seek" ]]; then
            materialize_extra_args=(
              --progressive-transcripts "$progressive_transcript_root"
            )
          elif [[ "$scenario" == "audio-media-services-reset" || "$scenario" == "audio-session-ownership" ]]; then
            materialize_extra_args=(
              --adaptive-source-metrics "$final_apple_audio_source_metrics"
            )
          fi
          set +e
          python3 "$SCRIPT_DIR/materialize-evidence.py" \
            --attachments "$attachments" \
            --attachment-name "$qualification_attachment" \
            --scenario "$qualification_scenario" \
            --hardware "$hardware_id" \
            --device-identifier "$DEVICE_UDID" \
            --qualification-session-binding "$ORCHESTRATOR_SESSION_BINDING" \
            --candidate-runtime-binding "$CANDIDATE_RUNTIME_BINDING" \
            --artifact-digest "$ARTIFACT_DIGEST" \
            --source-digest "$SOURCE_DIGEST" \
            --candidate-metadata "$CANDIDATE_IDENTITY" \
            --test-execution "$test_execution" \
            --error-inventory "$error_inventory" \
            --retained-root-base "$OUTPUT_DIR" \
            --matrix "$SCRIPT_DIR/matrix.json" \
            --duration-seconds "$((ended - started))" \
            --runner-scenario "$scenario" \
            --attempts "$attempts_json" \
            "${materialize_extra_args[@]}" \
            --output "$evidence_file" \
            > "$OUTPUT_DIR/$scenario-$qualification_scenario-materialize-evidence.log" 2>&1
          materialize_status=$?
          set -e
          if [[ "$materialize_status" -ne 0 ]]; then
            continue
          fi
          if [[ "$scenario" == "adaptive-hls-soak" ]]; then
            set +e
            python3 "$SCRIPT_DIR/augment-allocation-trace.py" \
              --evidence "$evidence_file" \
              --trace "$allocation_trace" \
              --toc "$allocation_trace_toc" \
              --digest-script "$ROOT_DIR/scripts/artifact-tree-digest.py"
            local augment_trace_status=$?
            set -e
            if [[ "$augment_trace_status" -ne 0 ]]; then
              continue
            fi
            if ! jq -e '
                .durationSeconds
                | type == "number" and . > 0 and floor == .
              ' "$evidence_file" >/dev/null; then
              continue
            fi
          elif [[ "$scenario" == pip-render-performance-* ]]; then
            set +e
            python3 "$SCRIPT_DIR/augment-performance-traces.py" \
              --evidence "$evidence_file" \
              --game-trace "$perf_game_trace" \
              --game-toc "$perf_game_toc" \
              --power-trace "$perf_power_trace" \
              --power-toc "$perf_power_toc" \
              --time-trace "$perf_time_trace" \
              --time-toc "$perf_time_toc" \
              --digest-script "$ROOT_DIR/scripts/artifact-tree-digest.py"
            local augment_performance_status=$?
            set -e
            if [[ "$augment_performance_status" -ne 0 ]]; then
              continue
            fi
          elif [[ "$scenario" == "native-subtitle-matrix" ]]; then
            set +e
            python3 "$SCRIPT_DIR/augment-native-subtitle-traces.py" \
              --evidence "$evidence_file" \
              --time-trace "$subtitle_time_trace" \
              --time-toc "$subtitle_time_toc" \
              --game-trace "$subtitle_game_trace" \
              --game-toc "$subtitle_game_toc" \
              --metal-trace "$subtitle_metal_trace" \
              --metal-toc "$subtitle_metal_toc" \
              --digest-script "$ROOT_DIR/scripts/artifact-tree-digest.py"
            local augment_subtitle_status=$?
            set -e
            if [[ "$augment_subtitle_status" -ne 0 ]]; then
              continue
            fi
          elif [[ "$scenario" == timebase-*-soak ]]; then
            set +e
            python3 "$SCRIPT_DIR/augment-timebase-evidence.py" \
              --evidence "$evidence_file" \
              --raw-root "$OUTPUT_DIR/$scenario-documents" \
              --audio-trace "$timebase_audio_trace" \
              --audio-toc "$timebase_audio_toc" \
              --digest-script "$ROOT_DIR/scripts/artifact-tree-digest.py"
            local augment_timebase_status=$?
            set -e
            if [[ "$augment_timebase_status" -ne 0 ]]; then
              continue
            fi
          fi
          policy_evidence_args=(
            validate-evidence
            --evidence "$evidence_file"
            --matrix "$SCRIPT_DIR/matrix.json"
            --identity "$CANDIDATE_IDENTITY"
            --scenario "$qualification_scenario"
            --hardware "$hardware_id"
            --retained-root-base "$OUTPUT_DIR"
            --require-retained-artifacts
          )
          if [[ "$RUN_MODE" == "qualification" ]]; then
            policy_evidence_args+=(--stable)
          fi
          if ! python3 "$SCRIPT_DIR/qualification_policy.py" \
              "${policy_evidence_args[@]}" \
              > "$OUTPUT_DIR/$scenario-$qualification_scenario-validate-evidence.log" 2>&1; then
            continue
          fi
          materialized_count=$((materialized_count + 1))
          materialized_scenarios+=("$qualification_scenario")
          materialized_evidence+=("$evidence_relative")
        done
        if [[ "$materialized_count" -eq "${#qualification_scenarios[@]}" ]]; then
          evidence_status="captured"
          # Exploratory devices may execute the exact same XCTest leaves, but
          # they never materialize release-credit rows—even when a beta build
          # happens to share the current stable OS major.
          if [[ "$RUN_MODE" == "qualification" ]]; then
            for evidence_index in "${!materialized_scenarios[@]}"; do
              local qualification_duration
              qualification_duration=$(jq -r '.durationSeconds' \
                "$OUTPUT_DIR/${materialized_evidence[$evidence_index]}")
              python3 - \
                  "$OUTPUT_DIR/device.json" "$QUALIFICATION_ROWS" \
                  "${materialized_evidence[$evidence_index]}" \
                  "$FIXTURE_MANIFEST_CHECKSUM" "$qualification_duration" \
                  "${materialized_scenarios[$evidence_index]}" "$scenario" <<'PY'
import json
import sys

(
    device_path,
    rows_path,
    evidence,
    fixture_checksum,
    duration,
    scenario,
    runner_scenario,
) = sys.argv[1:]
device = json.load(open(device_path))["selected"]
row = {
    "scenario": scenario,
    "runnerScenario": runner_scenario,
    "hardware": device["matchingHardwareRows"][0],
    "device": device["marketingName"],
    "deviceFamily": device["deviceFamily"],
    "productType": device["productType"],
    "osVersion": device["osVersion"],
    "osBuild": device["osBuild"],
    "osReleaseType": device["osReleaseType"],
    "fixture": f"qualification-fixtures:{fixture_checksum}",
    "duration": f"{duration}s",
    "durationSeconds": int(duration),
    "evidence": evidence,
    "result": "pass",
}
with open(rows_path, "a") as output:
    output.write(json.dumps(row, sort_keys=True) + "\n")
PY
            done
          fi
        fi
      fi
    fi
  fi

  result="pass"
  if [[ "$test_status" -ne 0 ]] || [[ "$log_errors_acceptable" != true ]] || [[ "$log_status" == "missing" ]] \
    || [[ "$allocation_trace_status" == "missing" ]] \
    || [[ "$performance_trace_status" == "missing" ]] \
    || [[ "$subtitle_trace_status" == "missing" ]] \
    || [[ "$timebase_trace_status" == "missing" ]] \
    || [[ "$evidence_status" == "missing" ]]; then
    result="fail"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$scenario" "$result" "$test_status" "$error_count" "$log_status" "$evidence_status" "$((ended - started))" \
    "$scenario_expected_catalog" "$test_execution" "$attempts_json" "$error_inventory" \
    >> "$RESULTS_TSV"
  assert_device_lock_held
  echo "$scenario: $result"
}

for scenario in "${ONLY_SCENARIOS[@]}"; do
  run_scenario "$scenario"
done

# Freeze the request transcript and server log before the evidence manifest is
# calculated. No retained artifact producer may remain alive past this point.
stop_fixture_server
python3 "$SCRIPT_DIR/fixture-tree-binding.py" verify \
  --root "$FIXTURES" \
  --receipt "$OUTPUT_DIR/fixture-tree-binding.json" \
  > /dev/null
verify_staged_candidate_identity
assert_source_authority_unchanged

MATRIX_CHECKSUM=$(shasum -a 256 "$SCRIPT_DIR/matrix.json" | cut -d' ' -f1)

assert_device_lock_held
python3 - \
  "$RESULTS_TSV" "$OUTPUT_DIR/report.json" "$OUTPUT_DIR/device.json" \
  "$VERSION" "$SOURCE_COMMIT" "$SOURCE_DIGEST" "$MATRIX_CHECKSUM" \
  "$CANDIDATE_APP_DIGEST" "$ARTIFACT_DIGEST" "$RUN_MODE" "$QUALIFICATION_ROWS" \
  "$CANDIDATE_IDENTITY" "$REPORT_ONLY_RUN" "$RUN_STARTED_AT_UTC" "$SCRIPT_DIR" \
  "$ORCHESTRATOR_SESSION_BINDING" "$ORCHESTRATOR_STARTED_AT_UTC" <<'PY'
import json
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

(
    results_path,
    output_path,
    device_path,
    version,
    source_commit,
    source_digest,
    matrix_checksum,
    app_digest,
    artifact_digest,
    mode,
    qualification_rows_path,
    candidate_path,
    report_only_raw,
    started_at_utc,
    script_dir,
    orchestrator_session_binding,
    orchestrator_started_at_utc,
) = sys.argv[1:]
report_only = report_only_raw == "true"
sys.path.insert(0, script_dir)
import qualification_policy as policy

scenarios = []
with open(results_path) as source:
    for line in source:
        (
            scenario,
            result,
            exit_code,
            errors,
            log_status,
            evidence_status,
            duration,
            expected_catalog_path,
            test_execution_path,
            attempts_path,
            error_inventory_path,
        ) = line.rstrip("\n").split("\t")
        with open(expected_catalog_path) as catalog_source:
            expected_catalog = json.load(catalog_source)
        test_execution = None
        if test_execution_path:
            with open(test_execution_path) as execution_source:
                test_execution = json.load(execution_source)
        with open(attempts_path) as attempts_source:
            attempts = json.load(attempts_source)
        error_inventory = None
        if error_inventory_path:
            with open(error_inventory_path) as inventory_source:
                error_inventory = json.load(inventory_source)
        row = {
            "scenario": scenario,
            "result": result,
            "xcodebuildExitCode": int(exit_code),
            "libraryErrorCount": int(errors),
            "appLog": log_status,
            "qualificationEvidence": evidence_status,
            "durationSeconds": int(duration),
            "expectedTestCatalog": expected_catalog,
            "testExecution": test_execution,
            "attempts": attempts,
            "attemptArtifactRoot": f"{scenario}-attempt-artifacts",
            "hostErrorInventory": error_inventory,
        }
        if scenario == policy.CADENCE_SEMANTICS_PROBE_SCENARIO:
            if evidence_status == "report-only":
                proof_path = (
                    Path(output_path).parent
                    / f"{scenario}-report-only-evidence.json"
                )
                with proof_path.open(encoding="utf-8") as proof_source:
                    row["reportOnlyEvidence"] = json.load(proof_source)
        scenarios.append(row)

device = json.load(open(device_path))["selected"]
device_snapshot = policy.device_snapshot_binding(Path(output_path).parent)
with open(qualification_rows_path) as source:
    qualification_rows = [json.loads(line) for line in source if line.strip()]
with open(candidate_path) as source:
    candidate = json.load(source)
started_at = datetime.strptime(started_at_utc, "%Y-%m-%dT%H:%M:%SZ").replace(
    tzinfo=timezone.utc
)
completed_at = datetime.now(timezone.utc).replace(microsecond=0)
report = {
    **candidate,
    "formatVersion": 2,
    "startedAtUTC": started_at_utc,
    "orchestratorSessionBinding": orchestrator_session_binding,
    "orchestratorStartedAtUTC": orchestrator_started_at_utc,
    "completedAtUTC": completed_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "wallDurationSeconds": int((completed_at - started_at).total_seconds()),
    "mode": mode,
    "qualificationEligibleEnvironment": device["qualificationEligible"],
    "releaseGateSatisfied": False,
    "releaseGateReason": (
        "exploratory cadence semantics probe cannot produce release credit"
        if report_only
        else "automated smoke coverage is not yet the complete required matrix"
    ),
    "reportOnly": report_only,
    "device": device,
    "deviceSnapshot": device_snapshot,
    "scenarios": scenarios,
    "qualificationRows": qualification_rows,
    "result": "pass" if scenarios and all(row["result"] == "pass" for row in scenarios) else "fail",
}
output_directory = os.path.dirname(output_path)
descriptor, staged_path = tempfile.mkstemp(
    prefix=".report.json.", suffix=".tmp", dir=output_directory
)
try:
    with os.fdopen(descriptor, "w") as output:
        json.dump(report, output, indent=2, sort_keys=True)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    os.chmod(staged_path, 0o644)
    os.replace(staged_path, output_path)
finally:
    if os.path.exists(staged_path):
        os.unlink(staged_path)
PY

report_validation_args=(
  validate-and-mark
  --run-dir "$OUTPUT_DIR"
  --candidate "$CANDIDATE_IDENTITY"
)
if [[ "$REPORT_ONLY_RUN" == true ]]; then
  report_validation_args+=(--report-only)
else
  report_validation_args+=(
    --matrix "$SCRIPT_DIR/matrix.json"
  )
  if [[ "$REQUIRE_STABLE" == true ]]; then
    report_validation_args+=(--stable-required)
  fi
fi

# Validate one immutable snapshot and bind its exact report and selected plan.
# A validated FAIL remains complete; a killed, changed, or mismatched run has
# no matching marker and the volunteer package labels it incomplete.
assert_source_authority_unchanged
assert_device_lock_held
python3 "$SCRIPT_DIR/report_validation.py" "${report_validation_args[@]}" > /dev/null

jq '{result, mode, qualificationEligibleEnvironment, releaseGateSatisfied, scenarios}' "$OUTPUT_DIR/report.json"
echo "Evidence: $OUTPUT_DIR"

if [[ $(jq -r '.result' "$OUTPUT_DIR/report.json") != "pass" ]]; then
  exit 1
fi
