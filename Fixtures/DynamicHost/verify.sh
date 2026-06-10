#!/usr/bin/env bash
#
# verify.sh — Build the DynamicHost fixture apps (iOS + tvOS simulators)
# and assert the supported layered-app topology yields exactly ONE copy
# of the libvlc static archive among the images the app loads: only the
# dynamic MediaCore framework defines the libVLC symbols; the app
# executable and every other image must not.
#
# Note: xcodebuild's `build` action does not copy dynamic package
# frameworks into the .app bundle — the app links them from the build
# products' PackageFrameworks/ directory via an absolute rpath. The
# audit therefore inspects the app executable, anything inside the
# bundle, and the PackageFrameworks images the executable links.
#
# Usage:
#   Fixtures/DynamicHost/verify.sh             # build + single-copy audit
#   Fixtures/DynamicHost/verify.sh --launch    # also boot an iPhone
#                                              # simulator, run the iOS app,
#                                              # and check its runtime output
#                                              # (local only)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DERIVED="$SCRIPT_DIR/.derived"
IOS_BUNDLE_ID="com.swiftvlc.fixtures.dynamichost.ios"
SENTINEL_SYMBOL=" T _libvlc_new"

LAUNCH=false
for arg in "$@"; do
  case "$arg" in
    --launch) LAUNCH=true ;;
    --help|-h)
      sed -n 's/^# \{0,1\}//p' "$0" | sed -n '/^Usage:/,/^$/p'
      exit 0 ;;
    *)
      echo "Error: unknown argument '$arg'" >&2
      exit 1 ;;
  esac
done

FAILURES=0

build() { # $1 = scheme, $2 = destination
  echo "── Building $1 ($2) ──"
  xcodebuild build \
    -project "$ROOT_DIR/Fixtures/DynamicHost/DynamicHost.xcodeproj" \
    -scheme "$1" \
    -destination "$2" \
    -configuration Debug \
    -derivedDataPath "$DERIVED" \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    ENABLE_DEBUG_DYLIB=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO
}

# Count how many times an image *defines* the libVLC sentinel symbol.
# `nm -gU` lists global defined symbols; a fat binary repeats the symbol
# once per slice, so any count > 0 means "this image carries libvlc".
defined_count() { # $1 = Mach-O path
  nm -gU "$1" 2>/dev/null | grep -c "$SENTINEL_SYMBOL" || true
}

audit_app() { # $1 = .app path
  local app="$1"
  echo "── Single-copy audit: $app ──"
  if [[ ! -d "$app" ]]; then
    echo "FAIL: app bundle not found: $app"
    FAILURES=$((FAILURES + 1))
    return
  fi

  local products_dir exe_name
  products_dir="$(dirname "$app")"
  exe_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")"
  local app_exe="$app/$exe_name"

  if ! otool -L "$app_exe" | grep -q "@rpath/MediaCore.framework/MediaCore"; then
    echo "FAIL: app executable does not link MediaCore.framework"
    FAILURES=$((FAILURES + 1))
    return
  fi

  local images=("$app_exe")
  local dylib
  for dylib in "$app"/*.dylib; do
    [[ -f "$dylib" ]] && images+=("$dylib")
  done
  local fw fw_name
  for fw in "$app"/Frameworks/*.framework "$products_dir"/PackageFrameworks/*.framework; do
    [[ -d "$fw" ]] || continue
    fw_name="$(basename "$fw" .framework)"
    [[ -f "$fw/$fw_name" ]] && images+=("$fw/$fw_name")
  done

  local defining=()
  local exe_defines=0
  local img count
  for img in "${images[@]}"; do
    count="$(defined_count "$img")"
    printf '  %-4s %s\n' "$count" "${img#"$products_dir"/}"
    if [[ "$count" -gt 0 ]]; then
      defining+=("$img")
      [[ "$img" == *.framework/* ]] || exe_defines=1
    fi
  done

  if [[ "${#defining[@]}" -eq 1 && "$exe_defines" -eq 0 &&
    "${defining[0]}" == */MediaCore.framework/MediaCore ]]; then
    echo "PASS: exactly one libvlc copy, inside MediaCore.framework"
  else
    echo "FAIL: expected exactly one libvlc copy, inside MediaCore.framework;" \
         "found ${#defining[@]} defining image(s):"
    for img in "${defining[@]+"${defining[@]}"}"; do
      echo "  $img"
    done
    FAILURES=$((FAILURES + 1))
  fi
}

launch_check() { # $1 = .app path
  local app="$1"
  echo "── Launch check (iOS Simulator) ──"

  local udid
  udid="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ {gsub(/^ +| +$/, "", $2); print $2; exit}')"
  if [[ -z "$udid" ]]; then
    echo "FAIL: no available iPhone simulator found"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "Using simulator $udid"

  xcrun simctl bootstatus "$udid" -b
  xcrun simctl install "$udid" "$app"

  local log="$DERIVED/launch.log"
  : > "$log"
  xcrun simctl launch --console-pty "$udid" "$IOS_BUNDLE_ID" > "$log" 2>&1 &
  local launch_pid=$!
  sleep 10
  xcrun simctl terminate "$udid" "$IOS_BUNDLE_ID" >/dev/null 2>&1 || true
  kill "$launch_pid" >/dev/null 2>&1 || true
  wait "$launch_pid" 2>/dev/null || true

  local ok=true
  if grep -q "DYNAMICHOST-SINGLE-INSTANCE: true" "$log"; then
    echo "PASS: app reported a single shared VLCInstance"
  else
    echo "FAIL: 'DYNAMICHOST-SINGLE-INSTANCE: true' not found in launch output"
    ok=false
  fi
  if grep -q "is implemented in both" "$log"; then
    echo "FAIL: duplicate Objective-C class warnings in launch output:"
    grep "is implemented in both" "$log" | sed 's/^/  /'
    ok=false
  else
    echo "PASS: no duplicate Objective-C class warnings"
  fi
  if [[ "$ok" == false ]]; then
    echo "Launch output captured at $log"
    FAILURES=$((FAILURES + 1))
  fi
}

build "DynamicHost-iOS" "generic/platform=iOS Simulator"
build "DynamicHost-tvOS" "generic/platform=tvOS Simulator"

IOS_APP="$DERIVED/Build/Products/Debug-iphonesimulator/DynamicHost-iOS.app"
TVOS_APP="$DERIVED/Build/Products/Debug-appletvsimulator/DynamicHost-tvOS.app"

audit_app "$IOS_APP"
audit_app "$TVOS_APP"

if [[ "$LAUNCH" == true ]]; then
  launch_check "$IOS_APP"
fi

echo
if [[ "$FAILURES" -gt 0 ]]; then
  echo "RESULT: FAIL ($FAILURES check(s) failed)"
  exit 1
fi
echo "RESULT: PASS"
