#!/usr/bin/env bash
set -euo pipefail

build_root="${SWIFT_BUILD_ROOT:-.build}"
output="${SWIFT_LCOV_OUTPUT:-.build/local-quality/coverage/lcov.info}"

profdata="${SWIFT_COVERAGE_PROFDATA:-}"
if [[ -z "$profdata" ]]; then
  profdata="$(find "$build_root" -path '*/debug/codecov/default.profdata' -type f -print | head -n 1)"
fi

if [[ -z "$profdata" || ! -f "$profdata" ]]; then
  echo "::error::Could not find SwiftPM coverage profile data under $build_root." >&2
  exit 1
fi

bin_dir="$(dirname "$(dirname "$profdata")")"
test_bundle="${SWIFT_TEST_BUNDLE:-}"
if [[ -z "$test_bundle" ]]; then
  if [[ -d "$bin_dir/SwiftVLCPackageTests.xctest" ]]; then
    test_bundle="$bin_dir/SwiftVLCPackageTests.xctest"
  else
    test_bundle="$(find "$bin_dir" -maxdepth 1 -name '*PackageTests.xctest' -type d -print | head -n 1)"
  fi
fi

if [[ -z "$test_bundle" || ! -d "$test_bundle" ]]; then
  echo "::error::Could not find SwiftPM test bundle next to $profdata." >&2
  exit 1
fi

bundle_name="$(basename "$test_bundle" .xctest)"
test_binary="$test_bundle/Contents/MacOS/$bundle_name"
if [[ ! -x "$test_binary" ]]; then
  test_binary="$(find "$test_bundle" -path '*/Contents/MacOS/*' -type f -perm -111 -print | head -n 1)"
fi

if [[ -z "$test_binary" || ! -x "$test_binary" ]]; then
  echo "::error::Could not find executable inside $test_bundle." >&2
  exit 1
fi

mkdir -p "$(dirname "$output")"

llvm_cov=(xcrun llvm-cov)
if [[ -n "${TOOLCHAINS:-}" ]]; then
  llvm_cov=(xcrun --toolchain "$TOOLCHAINS" llvm-cov)
fi

"${llvm_cov[@]}" export \
  -format=lcov \
  "$test_binary" \
  -instr-profile "$profdata" \
  --ignore-filename-regex='(/\.build/|/Tests/)' \
  > "$output"

if [[ ! -s "$output" ]] || ! grep -q '^SF:' "$output"; then
  echo "::error::Generated LCOV report is empty or invalid: $output." >&2
  exit 1
fi

echo "Wrote $output"
