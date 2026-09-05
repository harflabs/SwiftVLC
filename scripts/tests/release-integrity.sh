#!/usr/bin/env bash
set -euo pipefail

# Keep Python imports from dirtying the release source tree with bytecode caches.
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Keep ambient candidate capability out of the isolated adversarial fixtures;
# each fixture supplies its own complete context when it intends one. The lint
# workflow uses a non-authorizing marker to avoid duplicating authenticated
# artifact resolution already performed by both candidate build jobs.
candidate_lint=${SWIFTVLC_RELEASE_CANDIDATE_LINT:-}
if [[ -n "$candidate_lint" && "$candidate_lint" != "1" ]]; then
  echo "Error: SWIFTVLC_RELEASE_CANDIDATE_LINT must be exactly 1 when enabled." >&2
  exit 1
fi
unset SWIFTVLC_ALLOW_DRAFT_RELEASE
unset SWIFTVLC_RELEASE_CANDIDATE_LINT
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/swiftvlc-release-tests.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

python3 "$SCRIPT_DIR/verify-native-validator-assets.py" >/dev/null || \
  fail "repository native validator asset manifest is not current"

# Native validation is executable release evidence, not an untracked build
# convenience. Exercise the standalone asset-manifest verifier in an isolated
# repository-shaped fixture so drift, omission, and duplicate entries all fail
# before an expensive libVLC build begins.
validator_asset_fixture="$temp_dir/validator-assets"
mkdir -p "$validator_asset_fixture"
validator_asset_listing=$(
  python3 "$SCRIPT_DIR/verify-native-validator-assets.py" --list
)
while IFS= read -r relative; do
  [[ -n "$relative" ]] || continue
  mkdir -p "$validator_asset_fixture/$(dirname "$relative")"
  printf 'fixture for %s\n' "$relative" > "$validator_asset_fixture/$relative"
  chmod 0644 "$validator_asset_fixture/$relative"
  case "$relative" in
    scripts/patches/validation/effective-playback-rate-event-source-check.py|\
    scripts/patches/validation/vmem-picture-pts-source-check.py|\
    scripts/validate-*.sh)
      chmod 0755 "$validator_asset_fixture/$relative"
      ;;
  esac
done <<< "$validator_asset_listing"

python3 "$SCRIPT_DIR/verify-native-validator-assets.py" \
  --root "$validator_asset_fixture" --update >/dev/null
python3 "$SCRIPT_DIR/verify-native-validator-assets.py" \
  --root "$validator_asset_fixture" >/dev/null
validator_manifest_before=$(shasum -a 256 \
  "$validator_asset_fixture/scripts/native-validator-assets.sha256" | cut -d' ' -f1)
python3 "$SCRIPT_DIR/verify-native-validator-assets.py" \
  --root "$validator_asset_fixture" --update >/dev/null
validator_manifest_after=$(shasum -a 256 \
  "$validator_asset_fixture/scripts/native-validator-assets.sha256" | cut -d' ' -f1)
[[ "$validator_manifest_before" == "$validator_manifest_after" ]] || \
  fail "native validator asset manifest update is nondeterministic"

cp -R "$validator_asset_fixture" "$temp_dir/validator-assets-drift"
printf 'drift\n' >> \
  "$temp_dir/validator-assets-drift/scripts/validate-strict-frame-step.sh"
if python3 "$SCRIPT_DIR/verify-native-validator-assets.py" \
  --root "$temp_dir/validator-assets-drift" \
  >"$temp_dir/validator-assets-drift.log" 2>&1; then
  fail "native validator asset drift was accepted"
fi
grep -q 'native validator asset hash mismatch' \
  "$temp_dir/validator-assets-drift.log" || \
  fail "native validator drift did not produce a fail-closed diagnostic"

# The renderer recovery wrapper delegates its release decision to four source
# fixtures. Prove that neither the entry point nor any transitive input can
# drift outside the closed asset inventory.
renderer_validator_assets=(
  scripts/patches/validation/native-sample-buffer-renderer-immediate-sample.m
  scripts/patches/validation/native-sample-buffer-renderer-recovery.c
  scripts/patches/validation/sample-buffer-renderer-snapshot-abi.c
  scripts/patches/validation/sample-buffer-renderer-snapshot-abi.cpp
  scripts/validate-sample-buffer-renderer-recovery.sh
)
renderer_asset_index=0
for renderer_asset in "${renderer_validator_assets[@]}"; do
  renderer_asset_index=$((renderer_asset_index + 1))
  renderer_drift_root="$temp_dir/validator-assets-renderer-drift-$renderer_asset_index"
  cp -R "$validator_asset_fixture" "$renderer_drift_root"
  printf 'renderer recovery drift\n' >> "$renderer_drift_root/$renderer_asset"
  if python3 "$SCRIPT_DIR/verify-native-validator-assets.py" \
    --root "$renderer_drift_root" \
    >"$renderer_drift_root.log" 2>&1; then
    fail "renderer validator asset drift was accepted: $renderer_asset"
  fi
  grep -Fq "native validator asset hash mismatch: $renderer_asset" \
    "$renderer_drift_root.log" || \
    fail "renderer validator drift did not identify its asset: $renderer_asset"
done

cp -R "$validator_asset_fixture" "$temp_dir/validator-assets-mode-drift"
chmod 0755 \
  "$temp_dir/validator-assets-mode-drift/scripts/tests/test_pip_extension_version.py"
if python3 "$SCRIPT_DIR/verify-native-validator-assets.py" \
  --root "$temp_dir/validator-assets-mode-drift" \
  >"$temp_dir/validator-assets-mode-drift.log" 2>&1; then
  fail "native validator asset mode drift was accepted"
fi
grep -q 'native validator asset mode mismatch' \
  "$temp_dir/validator-assets-mode-drift.log" || \
  fail "native validator mode drift did not produce a fail-closed diagnostic"

cp -R "$validator_asset_fixture" \
  "$temp_dir/validator-assets-renderer-wrapper-mode-drift"
chmod 0644 \
  "$temp_dir/validator-assets-renderer-wrapper-mode-drift/scripts/validate-sample-buffer-renderer-recovery.sh"
if python3 "$SCRIPT_DIR/verify-native-validator-assets.py" \
  --root "$temp_dir/validator-assets-renderer-wrapper-mode-drift" \
  >"$temp_dir/validator-assets-renderer-wrapper-mode-drift.log" 2>&1; then
  fail "non-executable renderer recovery validator was accepted"
fi
grep -Fq \
  'native validator asset mode mismatch: scripts/validate-sample-buffer-renderer-recovery.sh' \
  "$temp_dir/validator-assets-renderer-wrapper-mode-drift.log" || \
  fail "renderer recovery wrapper mode drift was not diagnosed"

cp -R "$validator_asset_fixture" "$temp_dir/validator-assets-omission"
sed '1d' \
  "$temp_dir/validator-assets-omission/scripts/native-validator-assets.sha256" \
  > "$temp_dir/validator-assets-omission/scripts/native-validator-assets.sha256.tmp"
mv "$temp_dir/validator-assets-omission/scripts/native-validator-assets.sha256.tmp" \
  "$temp_dir/validator-assets-omission/scripts/native-validator-assets.sha256"
if python3 "$SCRIPT_DIR/verify-native-validator-assets.py" \
  --root "$temp_dir/validator-assets-omission" \
  >"$temp_dir/validator-assets-omission.log" 2>&1; then
  fail "an omitted native validator asset was accepted"
fi
grep -q 'native validator asset inventory mismatch' \
  "$temp_dir/validator-assets-omission.log" || \
  fail "native validator omission did not produce a fail-closed diagnostic"

cp -R "$validator_asset_fixture" "$temp_dir/validator-assets-duplicate"
head -n 1 \
  "$temp_dir/validator-assets-duplicate/scripts/native-validator-assets.sha256" \
  >> "$temp_dir/validator-assets-duplicate/scripts/native-validator-assets.sha256"
if python3 "$SCRIPT_DIR/verify-native-validator-assets.py" \
  --root "$temp_dir/validator-assets-duplicate" \
  >"$temp_dir/validator-assets-duplicate.log" 2>&1; then
  fail "a duplicate native validator asset was accepted"
fi
grep -q 'duplicate native validator asset' \
  "$temp_dir/validator-assets-duplicate.log" || \
  fail "duplicate native validator asset did not produce a fail-closed diagnostic"

python3 -B -m unittest discover \
  -s "$SCRIPT_DIR/tests" -p 'test_release_version_policy.py'
python3 -B "$SCRIPT_DIR/tests/test_pip_extension_version.py"
python3 -B "$SCRIPT_DIR/patches/validation/test_pip_extension_version.py"

# Pull-request CI must compile every Apple UI platform's source and tests
# without paying to boot additional runtimes. Keep this scoped to ios-build so
# a destination elsewhere cannot make the contract green.
python3 - \
  "$ROOT_DIR/.github/workflows/test.yml" \
  "$ROOT_DIR/.github/workflows/fixtures.yml" \
  "$ROOT_DIR/.github/workflows/vendor-manifest.yml" \
  "$ROOT_DIR/.github/workflows/sanitize.yml" \
  "$ROOT_DIR/.github/workflows/native-source-contracts.yml" <<'PY'
import re
import sys
from pathlib import Path

workflow = open(sys.argv[1]).read()
draft_authorization = (
    "          SWIFTVLC_ALLOW_DRAFT_RELEASE: "
    "${{ ((github.event_name == 'push' && "
    "startsWith(github.ref, 'refs/heads/release-candidates/')) || "
    "(github.event_name == 'pull_request' && "
    "github.event.pull_request.head.repo.full_name == github.repository && "
    "startsWith(github.head_ref, 'release-candidates/'))) && '1' || '' }}\n"
)
workflow_token = "          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}\n"
expected_draft_counts = (2, 1, 1, 1, 0)
expected_token_counts = (5, 1, 1, 1, 0)
if len(sys.argv[1:]) != len(expected_draft_counts):
    sys.exit("release workflow integrity invocation is incomplete")
for path, expected_draft_count, expected_token_count in zip(
    sys.argv[1:], expected_draft_counts, expected_token_counts
):
    source = open(path).read()
    count = source.count(draft_authorization)
    if count != expected_draft_count:
        sys.exit(
            f"{path} must scope draft authorization to each of its "
            f"{expected_draft_count} release-asset steps; found {count}"
        )
    token_count = source.count(workflow_token)
    if token_count != expected_token_count:
        sys.exit(
            f"{path} must expose the ephemeral token to exactly "
            f"{expected_token_count} release-asset steps; found {token_count}"
        )
    if source.count(workflow_token + draft_authorization) != expected_draft_count:
        sys.exit(f"{path} candidate token and authorization are not inseparable")
    if "  pull_request:\n    branches: [main]\n" not in source:
        sys.exit(f"{path} does not run protected release-candidate PR CI")
    if "  push:\n    branches: [main]\n" not in source:
        sys.exit(f"{path} does not run exact-main post-merge CI")
    if re.search(
        r"SWIFTVLC_ALLOW_DRAFT_RELEASE:\s*(?:['\"]?1['\"]?)?\s*$",
        source,
        re.MULTILINE,
    ):
        sys.exit(f"{path} grants unconditional draft release access")
    if expected_draft_count and (
        "github.event.pull_request.head.repo.full_name == github.repository"
        not in source
        or "startsWith(github.head_ref, 'release-candidates/')" not in source
    ):
        sys.exit(f"{path} does not authenticate same-repository candidate PRs")
    for action in re.findall(r"(?m)^\s*-?\s*uses:\s*([^\s#]+)", source):
        if not re.fullmatch(r"[^@]+@[0-9a-f]{40}", action):
            sys.exit(f"{path} contains an unpinned authorizing action: {action}")

# Audit consumers, not only the candidate jobs: main-only Showcase/tvOS lanes
# also call GitHub's API and can exhaust the shared anonymous runner quota.
for path in Path(sys.argv[1]).parent.glob("*.yml"):
    source = path.read_text()
    for step in re.split(r"(?m)^      - ", source)[1:]:
        if re.search(
            r"(?m)^\s+run: \./scripts/(?:setup-dev|ci-use-released-xcframework)\.sh\s*$",
            step,
        ) and workflow_token not in step:
            sys.exit(f"{path} has an unauthenticated release-artifact consumer")

candidate_lint_marker = (
    "          SWIFTVLC_RELEASE_CANDIDATE_LINT: "
    "${{ (github.event_name == 'pull_request' && "
    "github.event.pull_request.head.repo.full_name == github.repository && "
    "startsWith(github.head_ref, 'release-candidates/')) && '1' || '' }}\n"
)
if workflow.count(candidate_lint_marker) != 1:
    sys.exit("release-integrity candidate lint marker is not exactly scoped")
for path in sys.argv[2:]:
    if candidate_lint_marker in open(path).read():
        sys.exit(f"{path} unexpectedly grants the candidate lint marker")
native_contracts = open(sys.argv[5]).read()
vendor_manifest = open(sys.argv[3]).read()
for marker, expected_count in (
    ("      - scripts/libvlc-manifest-set.py\n", 2),
    ("      - scripts/tests/test_libvlc_manifest_set.py\n", 2),
    ("            scripts/tests/test_libvlc_manifest_set.py\n", 1),
    ("          ./scripts/check-libvlc-manifest.sh\n", 1),
):
    count = vendor_manifest.count(marker)
    if count != expected_count:
        sys.exit(
            "vendor manifest CI lost content-addressed inventory coverage: "
            f"{marker.strip()} occurred {count} times, expected {expected_count}"
        )
native_pr_trigger = native_contracts.split("  push:\n", 1)[0]
native_push_trigger = native_contracts.split("  push:\n", 1)[1].split(
    "\npermissions:\n", 1
)[0]
if "      - Package.swift\n" not in native_pr_trigger:
    sys.exit("release PR commits do not trigger exact-SHA native source contracts")
if "      - Package.swift\n" not in native_push_trigger:
    sys.exit("release merges do not trigger exact-main native source contracts")
for cache_workflow in (workflow, open(sys.argv[4]).read()):
    if "restore-keys:" in cache_workflow:
        sys.exit("release-authorizing compiled caches retain a broad restore key")
    for marker in (
        "${{ steps.xcf.outputs.sha }}-${{ hashFiles(",
        "path: |\n            .build/artifacts\n            Vendor\n",
        "Clean candidate build links",
    ):
        if marker not in cache_workflow:
            sys.exit(f"release-authorizing cache policy is incomplete: {marker}")
    for legacy in (
        "if: ${{ !startsWith(github.ref, 'refs/heads/release-candidates/') }}",
        "if: ${{ startsWith(github.ref, 'refs/heads/release-candidates/') }}",
    ):
        if legacy in cache_workflow:
            sys.exit("candidate PR cache isolation still relies only on github.ref")


def job_in(workflow_source, name, path):
    matches = list(
        re.finditer(
            rf"(?ms)^  {re.escape(name)}:\n.*?(?=^  [A-Za-z0-9_-]+:\n|\Z)",
            workflow_source,
        )
    )
    if len(matches) != 1:
        sys.exit(
            f"expected exactly one {name} workflow job in {path}, "
            f"found {len(matches)}"
        )
    return matches[0].group(0)


def job(name):
    return job_in(workflow, name, sys.argv[1])


privileged_jobs = (
    (workflow, sys.argv[1], ("ios-build", "test")),
    (open(sys.argv[2]).read(), sys.argv[2], ("dynamic-host",)),
    (vendor_manifest, sys.argv[3], ("check",)),
    (open(sys.argv[4]).read(), sys.argv[4], ("sanitize",)),
    (native_contracts, sys.argv[5], ()),
)
permission_marker = "    permissions:\n      contents: write\n"
for source, path, names in privileged_jobs:
    if source.count("permissions:\n  contents: read\n") != 1:
        sys.exit(f"{path} must keep read-only workflow-level permissions")
    if source.count(permission_marker) != len(names):
        sys.exit(
            f"{path} must grant draft visibility only to {list(names)}"
        )
    for name in names:
        candidate_job = job_in(source, name, path)
        header = candidate_job.split("\n    steps:\n", 1)[0]
        if header.count(permission_marker.rstrip("\n")) != 1:
            sys.exit(f"{path} job {name} lost draft-readable contents permission")
        if candidate_job.count("          persist-credentials: false\n") != 1:
            sys.exit(f"{path} job {name} persists its write-capable Git credential")


def named_step(job_source, name):
    marker = f"      - name: {name}\n"
    if job_source.count(marker) != 1:
        sys.exit(f"expected exactly one {name!r} step in ios-build")
    remainder = job_source.split(marker, 1)[1]
    next_step = re.search(r"(?m)^      - (?:name:|uses:)", remainder)
    if next_step is not None:
        remainder = remainder[: next_step.start()]
    return marker + remainder


workflow_header = workflow.split("\njobs:\n", 1)[0]
for trigger in (
    "  workflow_dispatch:\n",
    "  pull_request:\n    branches: [main]\n",
    "  push:\n    branches: [main]\n",
):
    if trigger not in workflow_header:
        sys.exit(f"test workflow lost required release trigger: {trigger.strip()}")

ios_build = job("ios-build")
ios_header = ios_build.split("\n    steps:\n", 1)[0]
if re.search(r"(?m)^    if:", ios_header):
    sys.exit("ios-build must remain enabled for pull requests")

job_timeout_match = re.search(
    r"(?m)^    timeout-minutes: ([0-9]+)$", ios_header
)
if job_timeout_match is None:
    sys.exit("ios-build lost its job-level timeout")
job_timeout = int(job_timeout_match.group(1))
step_timeouts = tuple(
    int(timeout)
    for timeout in re.findall(
        r"(?m)^        timeout-minutes: ([0-9]+)$", ios_build
    )
)
step_ceiling = sum(step_timeouts)
if job_timeout < step_ceiling + 5:
    sys.exit(
        "ios-build job timeout must leave at least five minutes above its "
        f"{step_ceiling}-minute explicit step ceiling: {job_timeout}"
    )

compile_step_name = "Compile Mac Catalyst and tvOS/visionOS tests"
compile_step = named_step(ios_build, compile_step_name)
if compile_step.count("        if: github.event_name == 'pull_request'\n") != 1:
    sys.exit("cross-platform compile step must be pull-request-only")
if compile_step.count("        timeout-minutes: 15\n") != 1:
    sys.exit("cross-platform compile step must retain its 15-minute cost bound")

setup_marker = "      - name: Set up Vendor + local Swift package\n"
compile_marker = f"      - name: {compile_step_name}\n"
if ios_build.index(setup_marker) > ios_build.index(compile_marker):
    sys.exit("cross-platform compile checks run before Vendor/package setup")

commands = []
lines = compile_step.splitlines()
for index, line in enumerate(lines):
    command_match = re.fullmatch(
        r"          xcodebuild ([a-z-]+) \\", line
    )
    if command_match is None:
        continue
    arguments = []
    for argument_line in lines[index + 1 :]:
        if not argument_line.startswith("            "):
            break
        argument = argument_line.strip()
        if argument.endswith("\\"):
            argument = argument[:-1].rstrip()
        arguments.append(argument)
    commands.append((command_match.group(1), tuple(arguments)))

common_arguments = (
    "-scheme SwiftVLC",
    "-configuration Debug",
    "-skipPackagePluginValidation",
    "-skipMacroValidation",
    "ONLY_ACTIVE_ARCH=NO",
    'CODE_SIGN_IDENTITY=""',
    "CODE_SIGNING_REQUIRED=NO",
    "CODE_SIGNING_ALLOWED=NO",
)
expected_argument_sets = (
    (
        common_arguments[0],
        '-destination "generic/platform=macOS,variant=Mac Catalyst"',
        *common_arguments[1:],
    ),
    *(
        (
            common_arguments[0],
            f'-destination "generic/platform={destination}"',
            *common_arguments[1:],
        )
        for destination in ("tvOS Simulator", "visionOS")
    ),
)
if (
    len(commands) != 3
    or tuple(command[0] for command in commands)
    != ("build-for-testing",) * 3
    or tuple(command[1] for command in commands) != expected_argument_sets
):
    sys.exit(
        "ios-build must contain exact Catalyst/tvOS/visionOS test-target "
        "compiles, all signing-disabled: "
        f"{commands}"
    )

xcodebuild_lines = [
    line.strip() for line in lines if re.search(r"\bxcodebuild\b", line)
]
if (
    len(xcodebuild_lines) != 3
    or xcodebuild_lines != ["xcodebuild build-for-testing \\"] * 3
):
    sys.exit("cross-platform pull-request step lost its exact test-compile shape")
for forbidden in (
    r"(?m)^\s*xcrun\s+simctl\b",
    r"(?m)^\s*xcrun\s+devicectl\b",
    r"(?m)^\s*xcodebuild\s+(?:test|test-without-building)\b",
):
    if re.search(forbidden, ios_build):
        sys.exit("ios-build must compile only and never boot or run a test runtime")

tvos_test = job("tvos-test")
tvos_header = tvos_test.split("\n    steps:\n", 1)[0]
if tvos_header.count("    if: github.event_name != 'pull_request'\n") != 1:
    sys.exit("tvos-test runtime job must remain post-merge/manual, not pull-request CI")
if "xcrun simctl boot \"$udid\"" not in tvos_test or "xcodebuild test \\" not in tvos_test:
    sys.exit("tvos-test no longer contains the post-merge tvOS runtime evidence")
PY

# Keep automated Copilot review traffic from creating misleading red Claude
# workflow rows. GitHub applies contributor approval before evaluating a job's
# `if`, so review events that do not mention Claude still become zero-job
# `action_required` runs. PR conversation comments remain the supported entry
# point for explicit `@claude` requests.
python3 - "$ROOT_DIR/.github/workflows/claude.yml" <<'PY'
import re
import sys

workflow = open(sys.argv[1]).read()
header = workflow.split("\njobs:\n", 1)[0]
if "  issue_comment:\n    types: [created]\n" not in header:
    sys.exit("Claude workflow lost its PR conversation-comment trigger")
for forbidden in ("pull_request_review:", "pull_request_review_comment:"):
    if forbidden in header:
        sys.exit(f"Claude workflow restored noisy review trigger: {forbidden}")
if "github.event_name == 'issue_comment'" not in workflow or "'@claude'" not in workflow:
    sys.exit("Claude workflow lost its explicit mention filter")
for action in re.findall(r"(?m)^\s*-?\s*uses:\s*([^\s#]+)", workflow):
    if not re.fullmatch(r"[^@]+@[0-9a-f]{40}", action):
        sys.exit(f"privileged Claude workflow contains an unpinned action: {action}")
PY

# This payload is the solo-maintainer governance contract applied out of band
# after the current release PR is green. Keep it exact so the release script's
# live verifier and the administrator handoff cannot silently diverge.
python3 - "$ROOT_DIR/.github/rulesets/protect-main.json" <<'PY'
import json
import sys

policy = json.load(open(sys.argv[1]))
expected = {
    "name": "Protect main",
    "target": "branch",
    "enforcement": "active",
    "bypass_actors": [],
    "conditions": {
        "ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}
    },
    "rules": [
        {"type": "deletion"},
        {"type": "non_fast_forward"},
        {
            "type": "pull_request",
            "parameters": {
                "required_approving_review_count": 0,
                "dismiss_stale_reviews_on_push": False,
                "require_code_owner_review": False,
                "require_last_push_approval": False,
                "required_review_thread_resolution": True,
                "allowed_merge_methods": ["merge"],
            },
        },
        {
            "type": "required_status_checks",
            "parameters": {
                "strict_required_status_checks_policy": True,
                "do_not_enforce_on_create": False,
                "required_status_checks": [
                    {"context": context, "integration_id": 15368}
                    for context in ("lint", "ios-build", "test")
                ],
            },
        },
    ],
}
if policy != expected:
    sys.exit(f"Protect main ruleset payload drifted:\n{policy!r}")
PY

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

# Draft release resolution is an internal, authenticated bridge used only by
# exact release-commit CI. The candidate tag is deliberately non-SemVer and is
# derived from the intended final tag plus all 40 commit hex digits.
resolver_root="$temp_dir/draft-resolver"
resolver_repo="$resolver_root/repository"
resolver_origin="$resolver_root/origin.git"
resolver_bin="$resolver_root/bin"
mkdir -p "$resolver_repo/scripts" "$resolver_bin"
cp "$SCRIPT_DIR/resolve-release-artifact.sh" \
  "$SCRIPT_DIR/release-artifact-info.py" \
  "$resolver_repo/scripts/"
cp "$temp_dir/Package.swift" "$resolver_repo/Package.swift"
git -C "$resolver_repo" init -q
git -C "$resolver_repo" branch -M main
git -C "$resolver_repo" config user.name "SwiftVLC Resolver Test"
git -C "$resolver_repo" config user.email \
  "swiftvlc-resolver-test@example.invalid"
git -C "$resolver_repo" add .
git -C "$resolver_repo" commit -qm "release commit"
resolver_commit=$(git -C "$resolver_repo" rev-parse HEAD)
git -C "$resolver_repo" tag v1.1.0-beta.1
git clone -q --bare "$resolver_repo" "$resolver_origin"
git -C "$resolver_repo" remote add origin "$resolver_origin"

cat > "$resolver_bin/gh" <<'SH'
#!/bin/sh
set -eu

if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  [ "${RESOLVER_AUTH_FAIL:-}" != 1 ]
  exit
fi
if [ "${1:-}" = release ] && [ "${2:-}" = view ]; then
  requested_tag=$3
  commit=$(/usr/bin/git rev-parse HEAD)
  python3 - "$requested_tag" "$commit" <<'PY'
import json
import os
import sys

checksum = "03a57454a6159c455406889c7867e0b284db028d2734a10bdf85a6a7285c862f"
digest = os.environ.get("RESOLVER_RELEASE_DIGEST", checksum)
requested_tag, commit = sys.argv[1:]
tag = os.environ.get("RESOLVER_RELEASE_TAG", requested_tag)
draft = os.environ.get("RESOLVER_RELEASE_DRAFT") == "1"
release_locator = (
    os.environ.get("RESOLVER_RELEASE_LOCATOR", "untagged-0123456789abcdef")
    if draft
    else tag
)
asset_locator = os.environ.get("RESOLVER_ASSET_LOCATOR", release_locator)
print(
    json.dumps(
        {
            "url": (
                "https://github.com/harflabs/SwiftVLC/releases/"
                f"tag/{release_locator}"
            ),
            "tagName": tag,
            "targetCommitish": os.environ.get("RESOLVER_RELEASE_TARGET", commit),
            "isDraft": draft,
            "isImmutable": False,
            "isPrerelease": True,
            "assets": [
                {
                    "name": "libvlc.xcframework.zip",
                    "digest": f"sha256:{digest}",
                    "url": (
                        "https://github.com/harflabs/SwiftVLC/releases/"
                        f"download/{asset_locator}/libvlc.xcframework.zip"
                    ),
                    "size": 1,
                }
            ],
        }
    )
)
PY
  exit 0
fi
exit 2
SH
cat > "$resolver_bin/curl" <<'SH'
#!/bin/sh
set -eu

request_url=""
for argument in "$@"; do
  request_url=$argument
done
requested_tag=${request_url##*/}
commit=$(/usr/bin/git rev-parse HEAD)
python3 - "$requested_tag" "$commit" <<'PY'
import json
import os
import sys

checksum = "03a57454a6159c455406889c7867e0b284db028d2734a10bdf85a6a7285c862f"
requested_tag, commit = sys.argv[1:]
tag = os.environ.get("RESOLVER_RELEASE_TAG", requested_tag)
print(
    json.dumps(
        {
            "html_url": (
                "https://github.com/harflabs/SwiftVLC/releases/"
                f"tag/{tag}"
            ),
            "tag_name": tag,
            "target_commitish": os.environ.get("RESOLVER_RELEASE_TARGET", commit),
            "draft": False,
            "immutable": False,
            "prerelease": True,
            "assets": [
                {
                    "name": "libvlc.xcframework.zip",
                    "digest": f"sha256:{checksum}",
                    "browser_download_url": (
                        "https://github.com/harflabs/SwiftVLC/releases/"
                        f"download/{tag}/libvlc.xcframework.zip"
                    ),
                    "size": 1,
                    "state": "uploaded",
                }
            ],
        }
    )
)
PY
SH
chmod +x "$resolver_bin/gh" "$resolver_bin/curl"

(
  cd "$resolver_repo"
  GH_TOKEN= GITHUB_TOKEN= \
    PATH="$resolver_bin:$PATH" \
    RESOLVER_RELEASE_DRAFT=0 \
    ./scripts/resolve-release-artifact.sh >/dev/null
)

# GitHub-hosted runners must use their ephemeral token instead of the shared
# anonymous API quota, without broadening which releases may be drafts.
(
  cd "$resolver_repo"
  GH_TOKEN=fixture-token \
    PATH="$resolver_bin:$PATH" \
    RESOLVER_RELEASE_DRAFT=0 \
    ./scripts/resolve-release-artifact.sh >/dev/null
)
if (
  cd "$resolver_repo"
  GH_TOKEN=fixture-token \
    PATH="$resolver_bin:$PATH" \
    RESOLVER_RELEASE_DRAFT=1 \
    ./scripts/resolve-release-artifact.sh >/dev/null 2>&1
); then
  fail "public authenticated resolution accepted a draft without candidate authorization"
fi

# Candidate staging removes the final SemVer tag from the equation entirely.
# Install only the deterministic candidate tag and exact candidate branch.
git -C "$resolver_repo" tag -d v1.1.0-beta.1 >/dev/null
git --git-dir="$resolver_origin" update-ref -d refs/tags/v1.1.0-beta.1
resolver_candidate_tag="swiftvlc-candidate-v1.1.0-beta.1-$resolver_commit"
git -C "$resolver_repo" tag "$resolver_candidate_tag" "$resolver_commit"
git --git-dir="$resolver_origin" update-ref \
  "refs/tags/$resolver_candidate_tag" "$resolver_commit"
git --git-dir="$resolver_origin" update-ref \
  refs/heads/release-candidates/v1.1.0-beta.1 "$resolver_commit"

if (
  cd "$resolver_repo"
  PATH="$resolver_bin:$PATH" \
    RESOLVER_RELEASE_DRAFT=1 \
    ./scripts/resolve-release-artifact.sh >/dev/null 2>&1
); then
  fail "draft release resolved without the explicit CI authorization"
fi

resolver_ci_env=(
  "GITHUB_ACTIONS=true"
  "GITHUB_EVENT_NAME=push"
  "GITHUB_REPOSITORY=harflabs/SwiftVLC"
  "GITHUB_REF=refs/heads/release-candidates/v1.1.0-beta.1"
  "GITHUB_SHA=$resolver_commit"
  "GITHUB_HEAD_REF="
  "GITHUB_BASE_REF="
  "SWIFTVLC_ALLOW_DRAFT_RELEASE=1"
  "RESOLVER_RELEASE_DRAFT=1"
)
(
  cd "$resolver_repo"
  env "${resolver_ci_env[@]}" PATH="$resolver_bin:$PATH" \
    ./scripts/resolve-release-artifact.sh \
    | python3 -c 'import json,sys; value=json.load(sys.stdin); assert value["isDraft"] and value["downloadTag"].startswith("swiftvlc-candidate-")'
)

if (
  cd "$resolver_repo"
  env "${resolver_ci_env[@]}" \
    GITHUB_EVENT_NAME=pull_request \
    GITHUB_REF=refs/pull/1/merge \
    GITHUB_HEAD_REF=release-attack \
    PATH="$resolver_bin:$PATH" \
    ./scripts/resolve-release-artifact.sh >/dev/null 2>&1
); then
  fail "an unauthenticated pull-request context opted into a draft release"
fi
if (
  cd "$resolver_repo"
  env "${resolver_ci_env[@]}" \
    GITHUB_REF=refs/heads/main \
    PATH="$resolver_bin:$PATH" \
    ./scripts/resolve-release-artifact.sh >/dev/null 2>&1
); then
  fail "main CI opted into a draft-only artifact"
fi
if (
  cd "$resolver_repo"
  env "${resolver_ci_env[@]}" \
    GITHUB_REF=refs/heads/release-candidates/v1.1.0-beta.2 \
    PATH="$resolver_bin:$PATH" \
    ./scripts/resolve-release-artifact.sh >/dev/null 2>&1
); then
  fail "an adjacent release-candidate branch opted into the draft"
fi
if (
  cd "$resolver_repo"
  env "${resolver_ci_env[@]}" \
    GITHUB_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    PATH="$resolver_bin:$PATH" \
    ./scripts/resolve-release-artifact.sh >/dev/null 2>&1
); then
  fail "draft release resolved for the wrong CI commit"
fi
if (
  cd "$resolver_repo"
  env "${resolver_ci_env[@]}" \
    RESOLVER_RELEASE_TAG=v1.1.0-beta.2 \
    PATH="$resolver_bin:$PATH" \
    ./scripts/resolve-release-artifact.sh >/dev/null 2>&1
); then
  fail "draft release resolved when GitHub returned the wrong tag"
fi
if (
  cd "$resolver_repo"
  env "${resolver_ci_env[@]}" \
    RESOLVER_RELEASE_TARGET=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    PATH="$resolver_bin:$PATH" \
    ./scripts/resolve-release-artifact.sh >/dev/null 2>&1
); then
  fail "draft release resolved when GitHub targeted the wrong commit"
fi
if (
  cd "$resolver_repo"
  env "${resolver_ci_env[@]}" \
    RESOLVER_RELEASE_DIGEST=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    PATH="$resolver_bin:$PATH" \
    ./scripts/resolve-release-artifact.sh >/dev/null 2>&1
); then
  fail "draft release resolved after asset digest drift"
fi
if (
  cd "$resolver_repo"
  env "${resolver_ci_env[@]}" \
    RESOLVER_ASSET_LOCATOR=untagged-fedcba9876543210 \
    PATH="$resolver_bin:$PATH" \
    ./scripts/resolve-release-artifact.sh >/dev/null 2>&1
); then
  fail "draft release resolved an asset from a different untagged locator"
fi
if (
  cd "$resolver_repo"
  env "${resolver_ci_env[@]}" \
    RESOLVER_AUTH_FAIL=1 \
    PATH="$resolver_bin:$PATH" \
    ./scripts/resolve-release-artifact.sh >/dev/null 2>&1
); then
  fail "draft release resolved without authenticated GitHub CLI access"
fi

# Even the otherwise exact candidate context must fail once a final SemVer tag
# appears; otherwise SwiftPM clients could select an unpublished package.
git --git-dir="$resolver_origin" update-ref \
  refs/tags/v1.1.0-beta.1 "$resolver_commit"
if (
  cd "$resolver_repo"
  env "${resolver_ci_env[@]}" PATH="$resolver_bin:$PATH" \
    ./scripts/resolve-release-artifact.sh >/dev/null 2>&1
); then
  fail "candidate CI accepted a prematurely exposed final SemVer tag"
fi
git --git-dir="$resolver_origin" update-ref -d refs/tags/v1.1.0-beta.1

# The protected release PR checks out GitHub's synthetic merge commit rather
# than its candidate head. Authenticate the same-repository event payload,
# bind the draft tag/release/remote branch to the exact head, and require the
# synthetic checkout to preserve that head's complete tree.
git -C "$resolver_repo" commit --allow-empty -qm "synthetic PR merge"
resolver_merge_commit=$(git -C "$resolver_repo" rev-parse HEAD)
resolver_event="$resolver_root/pull-request.json"
resolver_fork_event="$resolver_root/pull-request-fork.json"
resolver_wrong_head_event="$resolver_root/pull-request-wrong-head.json"
resolver_wrong_base_event="$resolver_root/pull-request-wrong-base.json"
python3 - \
  "$resolver_event" \
  "$resolver_fork_event" \
  "$resolver_wrong_head_event" \
  "$resolver_wrong_base_event" \
  "$resolver_commit" <<'PY'
import copy
import json
import sys

valid_path, fork_path, wrong_head_path, wrong_base_path, commit = sys.argv[1:]
valid = {
    "repository": {"full_name": "harflabs/SwiftVLC"},
    "pull_request": {
        "number": 17,
        "head": {
            "ref": "release-candidates/v1.1.0-beta.1",
            "sha": commit,
            "repo": {"full_name": "harflabs/SwiftVLC"},
        },
        "base": {
            "ref": "main",
            "repo": {"full_name": "harflabs/SwiftVLC"},
        },
    },
}


def write(path, value):
    with open(path, "w") as output:
        json.dump(value, output)


write(valid_path, valid)
fork = copy.deepcopy(valid)
fork["pull_request"]["head"]["repo"]["full_name"] = "attacker/SwiftVLC"
write(fork_path, fork)
wrong_head = copy.deepcopy(valid)
wrong_head["pull_request"]["head"]["sha"] = "b" * 40
write(wrong_head_path, wrong_head)
wrong_base = copy.deepcopy(valid)
wrong_base["pull_request"]["base"]["ref"] = "develop"
write(wrong_base_path, wrong_base)
PY

resolver_pr_env=(
  "GITHUB_ACTIONS=true"
  "GITHUB_EVENT_NAME=pull_request"
  "GITHUB_REPOSITORY=harflabs/SwiftVLC"
  "GITHUB_REF=refs/pull/17/merge"
  "GITHUB_SHA=$resolver_merge_commit"
  "GITHUB_HEAD_REF=release-candidates/v1.1.0-beta.1"
  "GITHUB_BASE_REF=main"
  "GITHUB_EVENT_PATH=$resolver_event"
  "SWIFTVLC_ALLOW_DRAFT_RELEASE=1"
  "RESOLVER_RELEASE_DRAFT=1"
  "RESOLVER_RELEASE_TARGET=$resolver_commit"
)
(
  cd "$resolver_repo"
  env "${resolver_pr_env[@]}" PATH="$resolver_bin:$PATH" \
    ./scripts/resolve-release-artifact.sh \
    | python3 -c 'import json,sys; value=json.load(sys.stdin); assert value["isDraft"] and value["releaseCommit"] == sys.argv[1]' "$resolver_commit"
)

for resolver_bad_event in \
  "$resolver_fork_event" \
  "$resolver_wrong_head_event" \
  "$resolver_wrong_base_event"; do
  if (
    cd "$resolver_repo"
    env "${resolver_pr_env[@]}" \
      GITHUB_EVENT_PATH="$resolver_bad_event" \
      PATH="$resolver_bin:$PATH" \
      ./scripts/resolve-release-artifact.sh >/dev/null 2>&1
  ); then
    fail "candidate PR accepted forged event identity: $resolver_bad_event"
  fi
done

printf 'changed merge tree\n' > "$resolver_repo/pr-tree-drift.txt"
git -C "$resolver_repo" add pr-tree-drift.txt
git -C "$resolver_repo" commit -qm "synthetic PR merge tree drift"
resolver_drift_merge_commit=$(git -C "$resolver_repo" rev-parse HEAD)
if (
  cd "$resolver_repo"
  env "${resolver_pr_env[@]}" \
    GITHUB_SHA="$resolver_drift_merge_commit" \
    PATH="$resolver_bin:$PATH" \
    ./scripts/resolve-release-artifact.sh >/dev/null 2>&1
); then
  fail "candidate PR accepted a synthetic merge with a different tree"
fi

# Candidate authorization must never be derived from Vendor cache metadata
# stored beside cached bytes. Forge a perfectly self-consistent malicious tree
# and install record, then prove draft setup redownloads the checksum-bound ZIP.
# Preserve the normal public-release cache fast path to avoid needless CI cost.
cache_root="$temp_dir/candidate-cache"
cache_repo="$cache_root/repository"
cache_bin="$cache_root/bin"
cache_good="$cache_root/good/libvlc.xcframework"
cache_zip="$cache_root/libvlc.xcframework.zip"
cache_downloads="$cache_root/downloads.log"
mkdir -p "$cache_repo/scripts" "$cache_repo/Vendor/libvlc.xcframework" \
  "$cache_bin" "$cache_good"
cp "$SCRIPT_DIR/setup-dev.sh" \
  "$SCRIPT_DIR/artifact-tree-digest.py" \
  "$cache_repo/scripts/"
printf '#!/bin/sh\n[ -d "$2" ]\n' > \
  "$cache_repo/scripts/fix-duplicate-symbols.sh"
chmod +x "$cache_repo/scripts/fix-duplicate-symbols.sh"
printf 'trusted release bytes\n' > "$cache_good/payload.txt"
ditto -c -k --keepParent "$cache_good" "$cache_zip"
cache_zip_checksum=$(shasum -a 256 "$cache_zip" | awk '{ print $1 }')
printf 'poisoned cache bytes\n' > \
  "$cache_repo/Vendor/libvlc.xcframework/payload.txt"
cache_poison_digest=$(
  "$cache_repo/scripts/artifact-tree-digest.py" \
    "$cache_repo/Vendor/libvlc.xcframework"
)
python3 - \
  "$cache_repo/Vendor/.swiftvlc-release.json" \
  "$cache_zip_checksum" \
  "$cache_poison_digest" <<'PY'
import json
import sys

path, checksum, digest = sys.argv[1:]
with open(path, "w") as output:
    json.dump(
        {
            "tag": "v1.1.0-beta.1",
            "url": "https://example.invalid/libvlc.xcframework.zip",
            "checksum": checksum,
            "treeDigest": digest,
        },
        output,
    )
PY
cat > "$cache_repo/scripts/resolve-release-artifact.sh" <<'SH'
#!/bin/sh
set -eu
python3 - <<'PY'
import json
import os

draft = os.environ.get("CACHE_IS_DRAFT") == "1"
tag = "v1.1.0-beta.1"
print(
    json.dumps(
        {
            "tag": tag,
            "downloadTag": (
                "swiftvlc-candidate-v1.1.0-beta.1-" + "a" * 40
                if draft
                else tag
            ),
            "url": "https://example.invalid/libvlc.xcframework.zip",
            "checksum": os.environ["CACHE_ZIP_CHECKSUM"],
            "isDraft": draft,
        }
    )
)
PY
SH
cat > "$cache_bin/gh" <<'SH'
#!/bin/sh
set -eu
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 0
fi
if [ "${1:-}" = release ] && [ "${2:-}" = download ]; then
  destination=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --dir ]; then
      destination=$2
      shift 2
    else
      shift
    fi
  done
  [ -n "$destination" ]
  cp "$CACHE_ASSET" "$destination/libvlc.xcframework.zip"
  printf 'download\n' >> "$CACHE_DOWNLOADS"
  exit 0
fi
exit 2
SH
cat > "$cache_bin/swift" <<'SH'
#!/bin/sh
set -eu
[ "$1" = package ]
[ "$2" = compute-checksum ]
shasum -a 256 "$3" | awk '{ print $1 }'
SH
chmod +x "$cache_repo/scripts/resolve-release-artifact.sh" \
  "$cache_bin/gh" "$cache_bin/swift"
printf '// cache fixture\n' > "$cache_repo/Package.swift"
: > "$cache_downloads"
(
  cd "$cache_repo"
  PATH="$cache_bin:$PATH" \
    CACHE_IS_DRAFT=1 \
    CACHE_ZIP_CHECKSUM="$cache_zip_checksum" \
    CACHE_ASSET="$cache_zip" \
    CACHE_DOWNLOADS="$cache_downloads" \
    ./scripts/setup-dev.sh --artifact-only >/dev/null
)
grep -q '^trusted release bytes$' \
  "$cache_repo/Vendor/libvlc.xcframework/payload.txt" || \
  fail "draft candidate setup retained poisoned cached Vendor bytes"
[[ $(wc -l < "$cache_downloads" | tr -d ' ') == 1 ]] || \
  fail "draft candidate setup did not redownload exactly once"
(
  cd "$cache_repo"
  PATH="$cache_bin:$PATH" \
    CACHE_IS_DRAFT=0 \
    CACHE_ZIP_CHECKSUM="$cache_zip_checksum" \
    CACHE_ASSET="$cache_zip" \
    CACHE_DOWNLOADS="$cache_downloads" \
    ./scripts/setup-dev.sh --artifact-only >/dev/null
)
[[ $(wc -l < "$cache_downloads" | tr -d ' ') == 1 ]] || \
  fail "verified public Vendor cache lost its non-candidate fast path"

rm -rf "$cache_repo/Vendor/libvlc.xcframework"
rm -f "$cache_repo/Vendor/.swiftvlc-release.json"
(
  cd "$cache_repo"
  GH_TOKEN=fixture-token \
    PATH="$cache_bin:$PATH" \
    CACHE_IS_DRAFT=0 \
    CACHE_ZIP_CHECKSUM="$cache_zip_checksum" \
    CACHE_ASSET="$cache_zip" \
    CACHE_DOWNLOADS="$cache_downloads" \
    ./scripts/setup-dev.sh --artifact-only >/dev/null
)
[[ $(wc -l < "$cache_downloads" | tr -d ' ') == 2 ]] || \
  fail "authenticated public setup did not use the reliable gh download path"
grep -q '^trusted release bytes$' \
  "$cache_repo/Vendor/libvlc.xcframework/payload.txt" || \
  fail "authenticated public setup installed unexpected Vendor bytes"

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

# Both digest implementations must preserve valid internal symlinks while
# refusing links whose bytes are hashed but whose effective content lives
# outside the artifact (or does not exist at all).
python3 - \
  "$SCRIPT_DIR/artifact-tree-digest.py" \
  "$SCRIPT_DIR/libvlc-provenance.py" \
  "$temp_dir" <<'PY'
import importlib.util
import os
import sys
from pathlib import Path


def load_module(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


standalone = load_module("swiftvlc_artifact_digest", sys.argv[1])
provenance = load_module("swiftvlc_provenance", sys.argv[2])
root = Path(sys.argv[3]) / "symlink-confinement"
outside = root.parent / "symlink-outside.h"
outside.write_text("outside\n")

valid = root / "valid"
valid.mkdir(parents=True)
(valid / "target.h").write_text("inside\n")
(valid / "current.h").symlink_to("target.h")
valid_digests = [
    implementation.tree_digest(valid)
    for implementation in (standalone, provenance)
]
if valid_digests[0] != valid_digests[1]:
    raise SystemExit("tree-digest implementations disagree on an internal symlink")

fixtures = {
    "absolute-escape": str(outside),
    "relative-escape": os.path.relpath(outside, root / "relative-escape"),
    "broken": "missing-target.h",
}
for name, target in fixtures.items():
    fixture = root / name
    fixture.mkdir()
    (fixture / "link.h").symlink_to(target)
    for implementation in (standalone, provenance):
        try:
            implementation.tree_digest(fixture)
        except SystemExit as error:
            if "escapes the tree or is broken" not in str(error):
                raise SystemExit(
                    f"{implementation.__name__} misdiagnosed {name}: {error}"
                )
        else:
            raise SystemExit(
                f"{implementation.__name__} accepted artifact symlink {name}"
            )
PY

# Complete engine provenance records exact slices, SDK/toolchain inputs, patch
# order, contrib checksums, and two-build reproducibility. Exercise it with a
# minimal valid XCFramework so release integrity does not depend on a 368 MB
# binary fixture.
mkdir -p "$temp_dir/fake-vlc/contrib/src/example"
printf 'example contrib checksum\n' > "$temp_dir/fake-vlc/contrib/src/example/SHA512SUMS"
printf '%064d  0001-example.patch\n' 0 > "$temp_dir/patch-manifest.sha256"
printf '#!/bin/sh\necho fixture\n' > "$temp_dir/build-config.sh"
printf '#!/bin/sh\necho validator fixture\n' > "$temp_dir/validator-config.sh"
fixture_source_date_epoch=1700000000
fixture_swiftvlc_revision=2222222222222222222222222222222222222222
mkdir -p "$temp_dir/build-a/macos-arm64/Headers"
printf 'header\n' > "$temp_dir/build-a/macos-arm64/Headers/libvlc.h"
ln -s libvlc.h "$temp_dir/build-a/macos-arm64/Headers/current.h"
printf 'int swiftvlc_provenance_fixture(void) { return 1; }\n' > "$temp_dir/member.c"
xcrun clang -c "$temp_dir/member.c" -o "$temp_dir/member.o"
ar rcs "$temp_dir/build-a/macos-arm64/libvlc.a" "$temp_dir/member.o"
python3 - "$temp_dir/build-a/Info.plist" <<'PY'
import plistlib
import sys

value = {
    "AvailableLibraries": [
        {
            "LibraryIdentifier": "macos-arm64",
            "LibraryPath": "libvlc.a",
            "HeadersPath": "Headers",
            "SupportedArchitectures": ["arm64"],
            "SupportedPlatform": "macos",
        }
    ],
    "CFBundlePackageType": "XFWK",
    "XCFrameworkFormatVersion": "1.0",
}
with open(sys.argv[1], "wb") as output:
    plistlib.dump(value, output, sort_keys=True)
PY
mkdir -p "$temp_dir/build-b/macos-arm64/Headers"
# Create the second logical tree in a different directory-entry order too.
cp "$temp_dir/build-a/Info.plist" "$temp_dir/build-b/Info.plist"
cp "$temp_dir/build-a/macos-arm64/libvlc.a" \
  "$temp_dir/build-b/macos-arm64/libvlc.a"
ln -s libvlc.h "$temp_dir/build-b/macos-arm64/Headers/current.h"
cp "$temp_dir/build-a/macos-arm64/Headers/libvlc.h" \
  "$temp_dir/build-b/macos-arm64/Headers/libvlc.h"

# Provenance deliberately ignores host filesystem metadata, while release ZIP
# bytes must not. Make the two logical trees differ in every excluded metadata
# class and prove canonical staging/archive removes that host dependence.
touch -t 203801190314 "$temp_dir/build-b/Info.plist"
xattr -w com.swiftvlc.release-integrity different \
  "$temp_dir/build-b/macos-arm64/Headers/libvlc.h"
xattr -w com.apple.ResourceFork resource-fork \
  "$temp_dir/build-b/macos-arm64/libvlc.a"
chmod +a "user:$(id -un) allow read" \
  "$temp_dir/build-b/macos-arm64/Headers/libvlc.h"

build_index=0
for build_name in a b; do
  build_index=$((build_index + 1))
  # Provenance records canonical second-resolution UTC completion times. A real
  # clean Apple build takes many minutes; keep the compact fixture ordered too.
  if [[ "$build_name" == b ]]; then
    sleep 1
  fi
  "$SCRIPT_DIR/libvlc-provenance.py" create \
    --xcframework "$temp_dir/build-$build_name" \
    --output "$temp_dir/provenance-$build_name.json" \
    --swiftvlc-revision "$fixture_swiftvlc_revision" \
    --vlc-source "$temp_dir/fake-vlc" \
    --source-revision 1111111111111111111111111111111111111111 \
    --pinned-revision 111111111 \
    --source-date-epoch "$fixture_source_date_epoch" \
    --patch-manifest "$temp_dir/patch-manifest.sha256" \
    --build-configuration-file "build-script=$temp_dir/build-config.sh" \
    --build-configuration-file "0037-validator=$temp_dir/validator-config.sh" \
    --build-invocation-id "00000000-0000-0000-0000-00000000000${build_index}" \
    --clean-build \
    --make-flags=-j1 \
    --deployment-target macos=15.0
done
"$SCRIPT_DIR/libvlc-provenance.py" compare \
  --first-provenance "$temp_dir/provenance-a.json" \
  --first-xcframework "$temp_dir/build-a" \
  --second-provenance "$temp_dir/provenance-b.json" \
  --second-xcframework "$temp_dir/build-b" \
  --output "$temp_dir/reproducibility.json" >/dev/null

# Creating evidence inside the tree it authenticates would make a successful
# command invalidate its own digest. Resolve parent symlinks as well as direct
# paths before any create/compare work or output write occurs.
ln -s "$temp_dir/build-a" "$temp_dir/build-a-output-alias"
create_outputs=(
  "$temp_dir/build-a/forbidden-provenance.json"
  "$temp_dir/build-a-output-alias/forbidden-provenance-alias.json"
)
for forbidden_output in "${create_outputs[@]}"; do
  if "$SCRIPT_DIR/libvlc-provenance.py" create \
    --xcframework "$temp_dir/build-a" \
    --output "$forbidden_output" \
    --swiftvlc-revision "$fixture_swiftvlc_revision" \
    --vlc-source "$temp_dir/fake-vlc" \
    --source-revision 1111111111111111111111111111111111111111 \
    --pinned-revision 111111111 \
    --source-date-epoch "$fixture_source_date_epoch" \
    --patch-manifest "$temp_dir/patch-manifest.sha256" \
    --build-configuration-file "build-script=$temp_dir/build-config.sh" \
    --build-configuration-file "0037-validator=$temp_dir/validator-config.sh" \
    --build-invocation-id 00000000-0000-0000-0000-000000000099 \
    --clean-build \
    --make-flags=-j1 \
    --deployment-target macos=15.0 >/dev/null 2>&1; then
    fail "provenance create wrote evidence inside its XCFramework"
  fi
  [[ ! -e "$forbidden_output" ]] || \
    fail "rejected in-artifact provenance output was still written"
done

compare_outputs=(
  "$temp_dir/build-a/forbidden-proof.json"
  "$temp_dir/build-a-output-alias/forbidden-proof-alias.json"
)
for forbidden_output in "${compare_outputs[@]}"; do
  if "$SCRIPT_DIR/libvlc-provenance.py" compare \
    --first-provenance "$temp_dir/provenance-a.json" \
    --first-xcframework "$temp_dir/build-a" \
    --second-provenance "$temp_dir/provenance-b.json" \
    --second-xcframework "$temp_dir/build-b" \
    --output "$forbidden_output" >/dev/null 2>&1; then
    fail "provenance compare wrote proof inside a compared XCFramework"
  fi
  [[ ! -e "$forbidden_output" ]] || \
    fail "rejected in-artifact proof output was still written"
done

"$SCRIPT_DIR/libvlc-provenance.py" verify \
  --provenance "$temp_dir/provenance-b.json" \
  --xcframework "$temp_dir/build-b" \
  --swiftvlc-revision "$fixture_swiftvlc_revision" \
  --pinned-revision 111111111 \
  --patch-manifest "$temp_dir/patch-manifest.sha256" \
  --build-configuration-file "build-script=$temp_dir/build-config.sh" \
  --build-configuration-file "0037-validator=$temp_dir/validator-config.sh" >/dev/null

if "$SCRIPT_DIR/libvlc-provenance.py" verify \
  --provenance "$temp_dir/provenance-b.json" \
  --xcframework "$temp_dir/build-b" \
  --swiftvlc-revision 3333333333333333333333333333333333333333 \
  --pinned-revision 111111111 \
  --patch-manifest "$temp_dir/patch-manifest.sha256" \
  --build-configuration-file "build-script=$temp_dir/build-config.sh" \
  --build-configuration-file "0037-validator=$temp_dir/validator-config.sh" \
  >/dev/null 2>&1; then
  fail "provenance verification accepted a different SwiftVLC commit"
fi

# Every named validator is part of the exact build-configuration inventory.
if "$SCRIPT_DIR/libvlc-provenance.py" verify \
  --provenance "$temp_dir/provenance-b.json" \
  --xcframework "$temp_dir/build-b" \
  --swiftvlc-revision "$fixture_swiftvlc_revision" \
  --pinned-revision 111111111 \
  --patch-manifest "$temp_dir/patch-manifest.sha256" \
  --build-configuration-file "build-script=$temp_dir/build-config.sh" >/dev/null 2>&1; then
  fail "provenance accepted an omitted 0037 validator configuration"
fi
"$SCRIPT_DIR/libvlc-provenance.py" verify-proof \
  --proof "$temp_dir/reproducibility.json" \
  --first-provenance "$temp_dir/provenance-a.json" \
  --second-provenance "$temp_dir/provenance-b.json" \
  --current-provenance "$temp_dir/provenance-b.json" \
  --xcframework "$temp_dir/build-b" >/dev/null

# Every field in the proof's per-slice output block is authoritative. Reject
# value, shape, and type mutations cleanly instead of treating it as display
# data or leaking a Python traceback for malformed schema input.
python3 - "$temp_dir/reproducibility.json" "$temp_dir" <<'PY'
import copy
import json
import sys
from pathlib import Path

source_path = Path(sys.argv[1])
output_root = Path(sys.argv[2])
source = json.loads(source_path.read_text())
slices = source["artifactIdentity"]["slices"]
slice_identifier = next(iter(slices))
slice_record = slices[slice_identifier]


def write(name, value):
    (output_root / f"proof-{name}.json").write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n"
    )


changed = copy.deepcopy(source)
changed["artifactIdentity"]["slices"][slice_identifier]["librarySha256"] = "0" * 64
write("changed-slice-value", changed)

missing_slice = copy.deepcopy(source)
del missing_slice["artifactIdentity"]["slices"][slice_identifier]
write("missing-slice", missing_slice)

extra_slice = copy.deepcopy(source)
extra_slice["artifactIdentity"]["slices"]["unexpected-slice"] = copy.deepcopy(
    slice_record
)
write("extra-slice", extra_slice)

missing_key = copy.deepcopy(source)
del missing_key["artifactIdentity"]["slices"][slice_identifier]["memberCount"]
write("missing-slice-key", missing_key)

extra_key = copy.deepcopy(source)
extra_key["artifactIdentity"]["slices"][slice_identifier][
    "uncheckedDisplayField"
] = "not-bound"
write("extra-slice-key", extra_key)

wrong_type = copy.deepcopy(source)
wrong_type["artifactIdentity"]["slices"][slice_identifier]["memberCount"] = True
write("wrong-slice-value-type", wrong_type)

non_object_slices = copy.deepcopy(source)
non_object_slices["artifactIdentity"]["slices"] = []
write("non-object-slices", non_object_slices)

changed_provenance_hash = copy.deepcopy(source)
changed_provenance_hash["firstBuild"]["provenanceSha256"] = "0" * 64
write("changed-provenance-hash", changed_provenance_hash)

missing_timestamp = copy.deepcopy(source)
del missing_timestamp["firstBuild"]["builtAt"]
write("missing-build-timestamp", missing_timestamp)

extra_top_level = copy.deepcopy(source)
extra_top_level["unverifiedDisplayField"] = True
write("extra-top-level", extra_top_level)

write("non-object-proof", [])

unsupported_schema = copy.deepcopy(source)
unsupported_schema["schemaVersion"] = source["schemaVersion"] + 1
write("unsupported-schema", unsupported_schema)

schema_float = copy.deepcopy(source)
schema_float["schemaVersion"] = float(source["schemaVersion"])
write("schema-float", schema_float)

wrong_build_input_type = copy.deepcopy(source)
wrong_build_input_type["buildInputs"]["sourceDateEpoch"] = True
write("wrong-build-input-type", wrong_build_input_type)

raw = source_path.read_text()
(output_root / "proof-duplicate-key.json").write_text(
    raw.replace(
        f'"schemaVersion": {source["schemaVersion"]},',
        f'"schemaVersion": {source["schemaVersion"]},\n'
        f'  "schemaVersion": {source["schemaVersion"]},',
        1,
    )
)
(output_root / "proof-non-finite.json").write_text(
    raw.replace(
        f'"sourceDateEpoch": {source["buildInputs"]["sourceDateEpoch"]}',
        '"sourceDateEpoch": NaN',
        1,
    )
)
PY
proof_mutations=(
  changed-slice-value
  missing-slice
  extra-slice
  missing-slice-key
  extra-slice-key
  wrong-slice-value-type
  non-object-slices
  changed-provenance-hash
  missing-build-timestamp
  extra-top-level
  non-object-proof
  unsupported-schema
  schema-float
  wrong-build-input-type
  duplicate-key
  non-finite
)
for mutation in "${proof_mutations[@]}"; do
  error_log="$temp_dir/proof-$mutation.stderr"
  if "$SCRIPT_DIR/libvlc-provenance.py" verify-proof \
    --proof "$temp_dir/proof-$mutation.json" \
    --first-provenance "$temp_dir/provenance-a.json" \
    --second-provenance "$temp_dir/provenance-b.json" \
    --current-provenance "$temp_dir/provenance-b.json" \
    --xcframework "$temp_dir/build-b" \
    >/dev/null 2>"$error_log"; then
    fail "reproducibility proof accepted mutation: $mutation"
  fi
  if grep -q 'Traceback' "$error_log"; then
    fail "reproducibility proof leaked a traceback for mutation: $mutation"
  fi
  grep -q '^Error:' "$error_log" \
    || fail "reproducibility proof did not report a schema error: $mutation"
done

mkdir -p "$temp_dir/canonical-a" "$temp_dir/canonical-b"
for build_name in a b; do
  "$SCRIPT_DIR/canonical-libvlc-artifact.sh" stage \
    "$temp_dir/build-$build_name" \
    "$temp_dir/canonical-$build_name/libvlc.xcframework" \
    "$temp_dir/provenance-$build_name.json"
  # Host reads and copies can leave arbitrary atimes after staging. Archive
  # normalization must occur after its final provenance read.
  touch -a -t 203801190314 \
    "$temp_dir/canonical-$build_name/libvlc.xcframework/Info.plist"
  "$SCRIPT_DIR/canonical-libvlc-artifact.sh" archive \
    "$temp_dir/canonical-$build_name/libvlc.xcframework" \
    "$temp_dir/canonical-$build_name.zip" \
    "$temp_dir/provenance-$build_name.json"
done
archive_timezones=(Pacific/Honolulu Europe/Amsterdam Asia/Tokyo UTC)
for archive_iteration in 1 2 3 4; do
  archive_timezone=${archive_timezones[$((archive_iteration - 1))]}
  for build_name in a b; do
    repeated_zip="$temp_dir/canonical-$build_name-repeat-$archive_iteration.zip"
    touch -a -t 203801190314 \
      "$temp_dir/canonical-$build_name/libvlc.xcframework/Info.plist"
    TZ="$archive_timezone" "$SCRIPT_DIR/canonical-libvlc-artifact.sh" archive \
      "$temp_dir/canonical-$build_name/libvlc.xcframework" \
      "$repeated_zip" \
      "$temp_dir/provenance-$build_name.json"
    cmp -s "$temp_dir/canonical-a.zip" "$repeated_zip" \
      || fail "canonical libVLC ZIP changed across repeated archives"
  done
done
if xattr -p com.swiftvlc.release-integrity \
  "$temp_dir/canonical-b/libvlc.xcframework/macos-arm64/Headers/libvlc.h" \
  >/dev/null 2>&1; then
  fail "canonical libVLC staging preserved a custom extended attribute"
fi
if xattr -p com.apple.ResourceFork \
  "$temp_dir/canonical-b/libvlc.xcframework/macos-arm64/libvlc.a" \
  >/dev/null 2>&1; then
  fail "canonical libVLC staging preserved a resource fork"
fi
staged_acl_lines=$(ls -lde \
  "$temp_dir/canonical-b/libvlc.xcframework/macos-arm64/Headers/libvlc.h" \
  | wc -l | tr -d ' ')
[[ "$staged_acl_lines" == 1 ]] \
  || fail "canonical libVLC staging preserved an ACL"
[[ $(stat -f%m "$temp_dir/canonical-b/libvlc.xcframework") \
  == "$fixture_source_date_epoch" ]] \
  || fail "canonical libVLC staging did not apply sourceDateEpoch"
cmp -s "$temp_dir/canonical-a.zip" "$temp_dir/canonical-b.zip" \
  || fail "canonical libVLC ZIP depends on excluded filesystem metadata"
python3 - "$temp_dir/canonical-a.zip" "$fixture_source_date_epoch" <<'PY'
from datetime import datetime, timezone
from pathlib import Path
import struct
import sys
import zipfile

archive_path = Path(sys.argv[1])
epoch = int(sys.argv[2])
timestamp = datetime.fromtimestamp(epoch, timezone.utc)
expected_timestamp = (
    timestamp.year,
    timestamp.month,
    timestamp.day,
    timestamp.hour,
    timestamp.minute,
    timestamp.second // 2 * 2,
)
with zipfile.ZipFile(archive_path) as archive:
    entries = archive.infolist()
names = [entry.filename for entry in entries]
if any(
    "/__MACOSX/" in f"/{name}"
    or name.rsplit("/", 1)[-1].startswith("._")
    for name in names
):
    raise SystemExit("canonical libVLC ZIP contains AppleDouble metadata")
with archive_path.open("rb") as raw_archive:
    for entry in entries:
        if entry.extra:
            raise SystemExit(
                f"canonical libVLC ZIP has a central extra field: {entry.filename}"
            )
        if entry.date_time != expected_timestamp:
            raise SystemExit(
                f"canonical libVLC ZIP has a noncanonical timestamp: {entry.filename}"
            )
        raw_archive.seek(entry.header_offset)
        header = raw_archive.read(30)
        if len(header) != 30:
            raise SystemExit("canonical libVLC ZIP has a truncated local header")
        values = struct.unpack("<IHHHHHIIIHH", header)
        if values[0] != 0x04034B50:
            raise SystemExit("canonical libVLC ZIP has an invalid local header")
        filename_size, extra_size = values[-2:]
        raw_archive.seek(filename_size, 1)
        local_extra = raw_archive.read(extra_size)
        if local_extra:
            raise SystemExit(
                f"canonical libVLC ZIP has a local extra field: {entry.filename}"
            )
        if len(local_extra) != extra_size:
            raise SystemExit(
                f"canonical libVLC ZIP has a truncated local extra field: "
                f"{entry.filename}"
            )
        if entry.create_system != 3:
            raise SystemExit(
                f"canonical libVLC ZIP lost Unix modes: {entry.filename}"
            )
        if entry.external_attr >> 16 == 0:
            raise SystemExit(
                f"canonical libVLC ZIP has an empty Unix mode: {entry.filename}"
            )
PY
mkdir -p "$temp_dir/canonical-unpacked"
ditto -x -k "$temp_dir/canonical-a.zip" "$temp_dir/canonical-unpacked"
canonical_digest=$("$SCRIPT_DIR/artifact-tree-digest.py" \
  "$temp_dir/canonical-unpacked/libvlc.xcframework")
recorded_digest=$(python3 - "$temp_dir/provenance-a.json" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1]))["xcframeworkTreeDigest"])
PY
)
[[ "$canonical_digest" == "$recorded_digest" ]] \
  || fail "canonical ZIP does not expand to the proven logical tree"
canonical_link="$temp_dir/canonical-unpacked/libvlc.xcframework/macos-arm64/Headers/current.h"
[[ -L "$canonical_link" && $(readlink "$canonical_link") == libvlc.h ]] \
  || fail "canonical ZIP did not preserve the provenance-covered symlink"

mode_before=$("$SCRIPT_DIR/artifact-tree-digest.py" "$temp_dir/build-a")
chmod +x "$temp_dir/build-a/macos-arm64/Headers/libvlc.h"
mode_after=$("$SCRIPT_DIR/artifact-tree-digest.py" "$temp_dir/build-a")
[[ "$mode_before" != "$mode_after" ]] \
  || fail "logical tree digest ignored a changed POSIX mode"
if "$SCRIPT_DIR/canonical-libvlc-artifact.sh" stage \
  "$temp_dir/build-a" "$temp_dir/mode-mutated/libvlc.xcframework" \
  "$temp_dir/provenance-a.json" >/dev/null 2>&1; then
  fail "canonical staging accepted a mode-mutated logical tree"
fi
chmod -x "$temp_dir/build-a/macos-arm64/Headers/libvlc.h"

# A changed effective build script invalidates otherwise matching provenance.
printf '#!/bin/sh\necho changed\n' > "$temp_dir/build-config.sh"
if "$SCRIPT_DIR/libvlc-provenance.py" verify \
  --provenance "$temp_dir/provenance-b.json" \
  --xcframework "$temp_dir/build-b" \
  --swiftvlc-revision "$fixture_swiftvlc_revision" \
  --pinned-revision 111111111 \
  --patch-manifest "$temp_dir/patch-manifest.sha256" \
  --build-configuration-file "build-script=$temp_dir/build-config.sh" \
  --build-configuration-file "0037-validator=$temp_dir/validator-config.sh" >/dev/null 2>&1; then
  fail "provenance accepted a changed build configuration"
fi
printf '#!/bin/sh\necho fixture\n' > "$temp_dir/build-config.sh"

printf '#!/bin/sh\necho changed validator\n' > "$temp_dir/validator-config.sh"
if "$SCRIPT_DIR/libvlc-provenance.py" verify \
  --provenance "$temp_dir/provenance-b.json" \
  --xcframework "$temp_dir/build-b" \
  --swiftvlc-revision "$fixture_swiftvlc_revision" \
  --pinned-revision 111111111 \
  --patch-manifest "$temp_dir/patch-manifest.sha256" \
  --build-configuration-file "build-script=$temp_dir/build-config.sh" \
  --build-configuration-file "0037-validator=$temp_dir/validator-config.sh" >/dev/null 2>&1; then
  fail "provenance accepted 0037 validator hash drift"
fi
printf '#!/bin/sh\necho validator fixture\n' > "$temp_dir/validator-config.sh"

# A clean-build marker without an independent invocation is not a second build.
cp "$temp_dir/provenance-b.json" "$temp_dir/provenance-same-invocation.json"
python3 - "$temp_dir/provenance-a.json" "$temp_dir/provenance-same-invocation.json" <<'PY'
import json
import sys

first = json.load(open(sys.argv[1]))
second = json.load(open(sys.argv[2]))
second["build"]["invocationId"] = first["build"]["invocationId"]
json.dump(second, open(sys.argv[2], "w"), indent=2, sort_keys=True)
PY
if "$SCRIPT_DIR/libvlc-provenance.py" compare \
  --first-provenance "$temp_dir/provenance-a.json" \
  --first-xcframework "$temp_dir/build-a" \
  --second-provenance "$temp_dir/provenance-same-invocation.json" \
  --second-xcframework "$temp_dir/build-b" >/dev/null 2>&1; then
  fail "reproducibility accepted the same build invocation twice"
fi

# Copying one provenance record and editing only its UUID is not evidence of a
# second build. Missing or equal timestamps are rejected before a proof exists.
python3 - "$temp_dir/provenance-a.json" "$temp_dir/provenance-b.json" "$temp_dir" <<'PY'
import copy
import json
import sys
from pathlib import Path

first = json.load(open(sys.argv[1]))
second = json.load(open(sys.argv[2]))
output = Path(sys.argv[3])

uuid_only = copy.deepcopy(first)
uuid_only["build"]["invocationId"] = "00000000-0000-0000-0000-000000000091"

missing_timestamp = copy.deepcopy(second)
del missing_timestamp["build"]["builtAt"]

equal_timestamp = copy.deepcopy(second)
equal_timestamp["build"]["builtAt"] = first["build"]["builtAt"]

noncanonical_timestamp = copy.deepcopy(second)
noncanonical_timestamp["build"]["builtAt"] = "2099-1-1T1:1:1Z"

coerced_build_input = copy.deepcopy(second)
coerced_build_input["build"]["assertionsEnabled"] = 0

coerced_both_first = copy.deepcopy(first)
coerced_both_first["build"]["assertionsEnabled"] = 0
coerced_both_second = copy.deepcopy(second)
coerced_both_second["build"]["assertionsEnabled"] = 0

schema_float_first = copy.deepcopy(first)
schema_float_first["schemaVersion"] = 4.0
schema_float_second = copy.deepcopy(second)
schema_float_second["schemaVersion"] = 4.0

cross_swiftvlc_revision = copy.deepcopy(second)
cross_swiftvlc_revision["swiftVLCRevision"] = "3" * 40

coerced_member_count = copy.deepcopy(second)
coerced_member_count["slices"][0]["memberCount"] = True

metadata_mismatch = copy.deepcopy(second)
metadata_mismatch["slices"][0]["architectures"] = ["x86_64"]

tampered_first = copy.deepcopy(first)
tampered_first["unboundAfterComparison"] = "tampered"

for name, value in (
    ("uuid-only", uuid_only),
    ("missing-timestamp", missing_timestamp),
    ("equal-timestamp", equal_timestamp),
    ("noncanonical-timestamp", noncanonical_timestamp),
    ("coerced-build-input", coerced_build_input),
    ("coerced-both-a", coerced_both_first),
    ("coerced-both-b", coerced_both_second),
    ("schema-float-a", schema_float_first),
    ("schema-float-b", schema_float_second),
    ("cross-swiftvlc-revision", cross_swiftvlc_revision),
    ("coerced-member-count", coerced_member_count),
    ("metadata-mismatch", metadata_mismatch),
    ("tampered-a", tampered_first),
):
    (output / f"provenance-{name}.json").write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n"
    )

raw = Path(sys.argv[2]).read_text()
(output / "provenance-duplicate-key.json").write_text(
    raw.replace(
        f'"schemaVersion": {second["schemaVersion"]},',
        f'"schemaVersion": {second["schemaVersion"]},\n'
        f'  "schemaVersion": {second["schemaVersion"]},',
        1,
    )
)
(output / "provenance-non-finite.json").write_text(
    raw.replace(
        f'"sourceDateEpoch": {second["build"]["sourceDateEpoch"]}',
        '"sourceDateEpoch": Infinity',
        1,
    )
)
PY

for forged_provenance in \
  uuid-only \
  missing-timestamp \
  equal-timestamp \
  noncanonical-timestamp \
  coerced-build-input \
  cross-swiftvlc-revision \
  duplicate-key \
  non-finite; do
  if "$SCRIPT_DIR/libvlc-provenance.py" compare \
    --first-provenance "$temp_dir/provenance-a.json" \
    --first-xcframework "$temp_dir/build-a" \
    --second-provenance "$temp_dir/provenance-$forged_provenance.json" \
    --second-xcframework "$temp_dir/build-b" >/dev/null 2>&1; then
    fail "reproducibility accepted forged provenance: $forged_provenance"
  fi
done

for malformed_pair in coerced-both schema-float; do
  if "$SCRIPT_DIR/libvlc-provenance.py" compare \
    --first-provenance "$temp_dir/provenance-$malformed_pair-a.json" \
    --first-xcframework "$temp_dir/build-a" \
    --second-provenance "$temp_dir/provenance-$malformed_pair-b.json" \
    --second-xcframework "$temp_dir/build-b" >/dev/null 2>&1; then
    fail "reproducibility accepted identically malformed A/B records: $malformed_pair"
  fi
done

# Provenance must match both byte content and the XCFramework's declared slice
# identity. JSON booleans must not compare equal to integer archive counts.
for mismatched_provenance in coerced-member-count metadata-mismatch; do
  if "$SCRIPT_DIR/libvlc-provenance.py" verify \
    --provenance "$temp_dir/provenance-$mismatched_provenance.json" \
    --xcframework "$temp_dir/build-b" \
    --swiftvlc-revision "$fixture_swiftvlc_revision" \
    --pinned-revision 111111111 \
    --patch-manifest "$temp_dir/patch-manifest.sha256" \
    --build-configuration-file "build-script=$temp_dir/build-config.sh" \
    --build-configuration-file "0037-validator=$temp_dir/validator-config.sh" \
    >/dev/null 2>&1; then
    fail "artifact verification accepted mismatched provenance: $mismatched_provenance"
  fi
done

if "$SCRIPT_DIR/libvlc-provenance.py" verify-proof \
  --proof "$temp_dir/reproducibility.json" \
  --first-provenance "$temp_dir/provenance-tampered-a.json" \
  --second-provenance "$temp_dir/provenance-b.json" \
  --current-provenance "$temp_dir/provenance-b.json" \
  --xcframework "$temp_dir/build-b" >/dev/null 2>&1; then
  fail "reproducibility proof accepted tampered retained provenance"
fi

for mismatched_build in a b; do
  cp -R "$temp_dir/build-$mismatched_build" \
    "$temp_dir/build-$mismatched_build-artifact-mismatch"
  printf 'mismatched header\n' > \
    "$temp_dir/build-$mismatched_build-artifact-mismatch/macos-arm64/Headers/libvlc.h"
  first_xcframework="$temp_dir/build-a"
  second_xcframework="$temp_dir/build-b"
  if [[ "$mismatched_build" == a ]]; then
    first_xcframework="$temp_dir/build-a-artifact-mismatch"
  else
    second_xcframework="$temp_dir/build-b-artifact-mismatch"
  fi
  if "$SCRIPT_DIR/libvlc-provenance.py" compare \
    --first-provenance "$temp_dir/provenance-a.json" \
    --first-xcframework "$first_xcframework" \
    --second-provenance "$temp_dir/provenance-b.json" \
    --second-xcframework "$second_xcframework" >/dev/null 2>&1; then
    fail "reproducibility comparison accepted an artifact/provenance mismatch: build $mismatched_build"
  fi
done

# Info.plist paths are untrusted artifact metadata. A path outside its slice and
# duplicate slice identifiers must fail even when a forged tree digest would
# otherwise make the record self-consistent.
cp -R "$temp_dir/build-b" "$temp_dir/build-b-escaping-path"
cp -R "$temp_dir/build-b/macos-arm64/Headers" "$temp_dir/outside-headers"
cp -R "$temp_dir/build-b" "$temp_dir/build-b-duplicate-identifier"
python3 - \
  "$temp_dir/build-b-escaping-path/Info.plist" \
  "$temp_dir/build-b-duplicate-identifier/Info.plist" <<'PY'
import copy
import plistlib
import sys

escaping_path, duplicate_path = sys.argv[1:]
with open(escaping_path, "rb") as source:
    escaping = plistlib.load(source)
escaping["AvailableLibraries"][0]["HeadersPath"] = "../../outside-headers"
with open(escaping_path, "wb") as output:
    plistlib.dump(escaping, output, sort_keys=True)

with open(duplicate_path, "rb") as source:
    duplicate = plistlib.load(source)
duplicate["AvailableLibraries"].append(
    copy.deepcopy(duplicate["AvailableLibraries"][0])
)
with open(duplicate_path, "wb") as output:
    plistlib.dump(duplicate, output, sort_keys=True)
PY

for malformed_artifact in escaping-path duplicate-identifier; do
  cp "$temp_dir/provenance-b.json" \
    "$temp_dir/provenance-$malformed_artifact.json"
  malformed_digest=$("$SCRIPT_DIR/artifact-tree-digest.py" \
    "$temp_dir/build-b-$malformed_artifact")
  python3 - \
    "$temp_dir/provenance-$malformed_artifact.json" \
    "$malformed_digest" <<'PY'
import json
import sys

path, digest = sys.argv[1:]
value = json.load(open(path))
value["xcframeworkTreeDigest"] = digest
with open(path, "w") as output:
    json.dump(value, output, indent=2, sort_keys=True)
    output.write("\n")
PY
  if "$SCRIPT_DIR/libvlc-provenance.py" verify \
    --provenance "$temp_dir/provenance-$malformed_artifact.json" \
    --xcframework "$temp_dir/build-b-$malformed_artifact" \
    --swiftvlc-revision "$fixture_swiftvlc_revision" \
    --pinned-revision 111111111 \
    --patch-manifest "$temp_dir/patch-manifest.sha256" \
    --build-configuration-file "build-script=$temp_dir/build-config.sh" \
    --build-configuration-file "0037-validator=$temp_dir/validator-config.sh" \
    >/dev/null 2>&1; then
    fail "artifact verification accepted malformed Info.plist: $malformed_artifact"
  fi
done

# An incremental build cannot participate even when its output is identical.
cp "$temp_dir/provenance-b.json" "$temp_dir/provenance-incremental.json"
python3 - "$temp_dir/provenance-incremental.json" <<'PY'
import json
import sys

path = sys.argv[1]
value = json.load(open(path))
value["build"]["cleanBuild"] = False
value["build"]["invocationId"] = "00000000-0000-0000-0000-000000000003"
json.dump(value, open(path, "w"), indent=2, sort_keys=True)
PY
if "$SCRIPT_DIR/libvlc-provenance.py" compare \
  --first-provenance "$temp_dir/provenance-a.json" \
  --first-xcframework "$temp_dir/build-a" \
  --second-provenance "$temp_dir/provenance-incremental.json" \
  --second-xcframework "$temp_dir/build-b" >/dev/null 2>&1; then
  fail "reproducibility accepted an incremental build"
fi

# There is no generic rebind escape hatch for a post-proof mutation.
if "$SCRIPT_DIR/libvlc-provenance.py" rebind >/dev/null 2>&1; then
  fail "removed provenance rebind command is still accepted"
fi
cp -R "$temp_dir/build-b" "$temp_dir/mutated-build"
printf 'int swiftvlc_provenance_fixture(void) { return 2; }\n' > "$temp_dir/member.c"
xcrun clang -c "$temp_dir/member.c" -o "$temp_dir/member.o"
ar rcs "$temp_dir/mutated-build/macos-arm64/libvlc.a" "$temp_dir/member.o"
"$SCRIPT_DIR/libvlc-provenance.py" create \
  --xcframework "$temp_dir/mutated-build" \
  --output "$temp_dir/mutated-provenance.json" \
  --swiftvlc-revision "$fixture_swiftvlc_revision" \
  --vlc-source "$temp_dir/fake-vlc" \
  --source-revision 1111111111111111111111111111111111111111 \
  --pinned-revision 111111111 \
  --source-date-epoch "$fixture_source_date_epoch" \
  --patch-manifest "$temp_dir/patch-manifest.sha256" \
  --build-configuration-file "build-script=$temp_dir/build-config.sh" \
  --build-configuration-file "0037-validator=$temp_dir/validator-config.sh" \
  --build-invocation-id 00000000-0000-0000-0000-000000000004 \
  --clean-build \
  --make-flags=-j1 \
  --deployment-target macos=15.0
if "$SCRIPT_DIR/libvlc-provenance.py" verify-proof \
  --proof "$temp_dir/reproducibility.json" \
  --first-provenance "$temp_dir/provenance-a.json" \
  --second-provenance "$temp_dir/provenance-b.json" \
  --current-provenance "$temp_dir/mutated-provenance.json" \
  --xcframework "$temp_dir/mutated-build" >/dev/null 2>&1; then
  fail "reproducibility proof accepted a mutated post-build tree"
fi

# The artifact binds the post-pin wrapper; the wrapper must in turn reject a
# drifted nested probe before any compiler/tool lookup can make the result
# environment-dependent.
post_pin_fixture="$temp_dir/post-pin-hash-fixture"
mkdir -p \
  "$post_pin_fixture/scripts/patches" \
  "$post_pin_fixture/vlc/modules/demux/json" \
  "$post_pin_fixture/vlc/modules/stream_out/chromecast" \
  "$post_pin_fixture/vlc/modules/services_discovery" \
  "$post_pin_fixture/vlc/src/text" \
  "$post_pin_fixture/vlc/compat" \
  "$post_pin_fixture/work"
cp "$SCRIPT_DIR/validate-post-pin-stability.sh" "$post_pin_fixture/scripts/"
cp -R "$SCRIPT_DIR/patches/validation" "$post_pin_fixture/scripts/patches/"
for fixture_input in \
  modules/demux/json/json.c \
  modules/demux/json/json.h \
  modules/demux/json/grammar.y \
  modules/demux/json/lexicon.l \
  modules/stream_out/chromecast/chromecast_protocol.hpp \
  modules/stream_out/chromecast/chromecast_demux_duration.hpp \
  modules/services_discovery/upnp-wrapper.cpp \
  modules/services_discovery/upnp-wrapper.hpp \
  src/text/url.c \
  src/text/memstream.c \
  compat/memrchr.c; do
  : > "$post_pin_fixture/vlc/$fixture_input"
done
printf '\n// release-integrity nested hash drift\n' >> \
  "$post_pin_fixture/scripts/patches/validation/post-pin-stability-probe.cpp"
if "$post_pin_fixture/scripts/validate-post-pin-stability.sh" \
  "$post_pin_fixture/vlc" "$post_pin_fixture/work" \
  >"$post_pin_fixture/hash-drift.log" 2>&1; then
  fail "post-pin wrapper accepted a drifted nested native probe"
fi
grep -Fq "linked JSON/Cast probe hash changed" \
  "$post_pin_fixture/hash-drift.log" || \
  fail "post-pin wrapper did not diagnose nested native-probe hash drift"

python3 - \
  "$SCRIPT_DIR/build-libvlc.sh" \
  "$SCRIPT_DIR/release.sh" \
  "$SCRIPT_DIR/patches/manifest.sha256" \
  "$SCRIPT_DIR/validate-chromecast-load-transition.sh" \
  "$SCRIPT_DIR/patches/validation/chromecast-load-transition-source-check.py" \
  "$SCRIPT_DIR/validate-post-pin-stability.sh" \
  "$SCRIPT_DIR/native-validator-assets.sha256" \
  "$SCRIPT_DIR/verify-native-validator-assets.py" \
  "$SCRIPT_DIR/validate-audio-media-services-reset.sh" \
  "$SCRIPT_DIR/libvlc-provenance.py" \
  "$SCRIPT_DIR/validate-strict-frame-step.sh" \
  "$SCRIPT_DIR/patches/validation/effective-playback-rate-event-probe.c" \
  "$SCRIPT_DIR/patches/validation/vmem-picture-pts-probe.c" \
  "$SCRIPT_DIR/validate-native-extension-contract.sh" \
  "$SCRIPT_DIR/patches/validation/native-extension-version-probe.c" \
  "$SCRIPT_DIR/patches/validation/pip_extension_version.py" \
  "$ROOT_DIR/Sources/CLibVLC/shim.c" \
  "$SCRIPT_DIR/validate-native-patch-series-source.sh" <<'PY'
import ast
import re
import sys

build = open(sys.argv[1]).read()
release = open(sys.argv[2]).read()
load_transition_validator = open(sys.argv[4]).read()
load_transition_checker = open(sys.argv[5]).read()
post_pin_validator = open(sys.argv[6]).read()
validator_asset_manifest = [
    line.rstrip("\n").split("  ", 1)
    for line in open(sys.argv[7])
]
validator_asset_verifier = open(sys.argv[8]).read()
audio_reset_validator = open(sys.argv[9]).read()
provenance_tool = open(sys.argv[10]).read()
strict_frame_validator = open(sys.argv[11]).read()
effective_rate_probe = open(sys.argv[12]).read()
vmem_pts_probe = open(sys.argv[13]).read()
native_extension_validator = open(sys.argv[14]).read()
native_extension_probe = open(sys.argv[15]).read()
extension_resolver = open(sys.argv[16]).read()
clibvlc_shim = open(sys.argv[17]).read()
native_patch_series_validator = open(sys.argv[18]).read()
manifest_lines = [
    line.strip() for line in open(sys.argv[3]) if line.strip() and not line.lstrip().startswith("#")
]
expected_manifest_tail = [
    "dd3c672da9b7a6fcd82e6eadd298d1c5f86ce75e55d86800de8fd83683461105  0037-chromecast-load-transition-correctness.patch",
    "5f1a58d162c798b2d6f5c2a2fdac9f728279f195ef192405b80272bc2f164c59  0038-apple-assembly-metadata.patch",
    "f78050944caf0c291cac76e28cc4238b3e407d104446e2876c6e0213923d3581  0039-aom-3.13.2-nasm-detection.patch",
    "a4945772122ce3d02f9a5c0c7136fa5dae940f251081238260b760b86c834681  0040-headless-vout-teardown-deadlock.patch",
    "3587daa9ccd017cf109e3c809315b09e8f378d63b8d17600bd6c0366dbd750c8  0041-native-pip-output-identity.patch",
    "6675edb052faa037c763451b6c9aae9b43dc42769d9311332371eda8bd788611  0042-adaptive-es-recycling-extradata-identity.patch",
    "8bf97e191e0f5765a8daa1d8d7848e7453f0c6f4dda57eff6bfff82744e64ab2  0043-text-subtitle-callback.patch",
]
if manifest_lines[-7:] != expected_manifest_tail:
    sys.exit(
        "patch manifest must end with frozen 0037 through 0040, native PiP "
        "output identity 0041, adaptive ES recycling 0042, then text-subtitle "
        "callback 0043: "
        f"got {manifest_lines[-7:]}"
    )

required_validator_assets = (
    "scripts/patches/validation/adaptive-es-recycling-source-check.py",
    "scripts/patches/validation/aom-nasm3-detection-probe.cmake",
    "scripts/patches/validation/aom-nasm3-detection-source-check.py",
    "scripts/patches/validation/audio-media-services-reset-source-check.py",
    "scripts/patches/validation/effective-playback-rate-event-abi.c",
    "scripts/patches/validation/effective-playback-rate-event-abi.cpp",
    "scripts/patches/validation/effective-playback-rate-event-probe.c",
    "scripts/patches/validation/effective-playback-rate-event-source-check.py",
    "scripts/patches/validation/headless-vout-teardown-probe.c",
    "scripts/patches/validation/headless-vout-teardown-source-check.py",
    "scripts/patches/validation/native-extension-version-probe.c",
    "scripts/patches/validation/native-pip-output-identity-race.c",
    "scripts/patches/validation/native-pip-output-identity-source-check.py",
    "scripts/patches/validation/native-sample-buffer-renderer-immediate-sample.m",
    "scripts/patches/validation/native-sample-buffer-renderer-recovery.c",
    "scripts/patches/validation/pip-playback-snapshot-probe.c",
    "scripts/patches/validation/pip_extension_version.py",
    "scripts/patches/validation/sample-buffer-renderer-snapshot-abi.c",
    "scripts/patches/validation/sample-buffer-renderer-snapshot-abi.cpp",
    "scripts/patches/validation/strict-frame-step-probe.c",
    "scripts/patches/validation/strict-frame-step-source-check.py",
    "scripts/patches/validation/subtitle-text-snapshot.c",
    "scripts/patches/validation/test_pip_extension_version.py",
    "scripts/patches/validation/vmem-configuration-race.c",
    "scripts/patches/validation/vmem-picture-pts-abi.cpp",
    "scripts/patches/validation/vmem-picture-pts-probe.c",
    "scripts/patches/validation/vmem-picture-pts-source-check.py",
    "scripts/tests/test_pip_extension_version.py",
    "scripts/validate-aom-nasm3-detection.sh",
    "scripts/validate-audio-media-services-reset.sh",
    "scripts/validate-effective-playback-rate-event.sh",
    "scripts/validate-headless-vout-teardown.sh",
    "scripts/validate-native-extension-contract.sh",
    "scripts/validate-native-patch-series-source.sh",
    "scripts/validate-pip-playback-snapshot.sh",
    "scripts/validate-sample-buffer-renderer-recovery.sh",
    "scripts/validate-strict-frame-step.sh",
    "scripts/validate-vmem-picture-pts.sh",
)
required_executable_validator_assets = (
    "scripts/patches/validation/effective-playback-rate-event-source-check.py",
    "scripts/patches/validation/vmem-picture-pts-source-check.py",
    "scripts/validate-aom-nasm3-detection.sh",
    "scripts/validate-audio-media-services-reset.sh",
    "scripts/validate-effective-playback-rate-event.sh",
    "scripts/validate-headless-vout-teardown.sh",
    "scripts/validate-native-extension-contract.sh",
    "scripts/validate-native-patch-series-source.sh",
    "scripts/validate-pip-playback-snapshot.sh",
    "scripts/validate-sample-buffer-renderer-recovery.sh",
    "scripts/validate-strict-frame-step.sh",
    "scripts/validate-vmem-picture-pts.sh",
)
manifest_asset_paths = tuple(path for _, path in validator_asset_manifest)
if manifest_asset_paths != required_validator_assets:
    sys.exit(
        "native validator asset manifest inventory drifted: "
        f"{manifest_asset_paths}"
    )
if len(set(manifest_asset_paths)) != len(manifest_asset_paths):
    sys.exit("native validator asset manifest contains a duplicate path")

verifier_tree = ast.parse(validator_asset_verifier)
verifier_asset_paths = None
verifier_executable_asset_paths = None
for statement in verifier_tree.body:
    if isinstance(statement, ast.Assign) and any(
        isinstance(target, ast.Name) and target.id == "ASSET_PATHS"
        for target in statement.targets
    ):
        verifier_asset_paths = ast.literal_eval(statement.value)
    if isinstance(statement, ast.Assign) and any(
        isinstance(target, ast.Name) and target.id == "EXECUTABLE_ASSET_PATHS"
        for target in statement.targets
    ):
        verifier_executable_asset_paths = ast.literal_eval(statement.value)
if verifier_asset_paths != required_validator_assets:
    sys.exit(
        "native validator verifier inventory drifted: "
        f"{verifier_asset_paths}"
    )
if verifier_executable_asset_paths != required_executable_validator_assets:
    sys.exit(
        "native validator executable-mode inventory drifted: "
        f"{verifier_executable_asset_paths}"
    )

assembly_manifest_detection = build.index(
    'if [ "$manifest_entry" = "0038-apple-assembly-metadata.patch" ]; then'
)
aom_manifest_detection = build.index(
    'if [ "$manifest_entry" = "0039-aom-3.13.2-nasm-detection.patch" ]; then'
)
headless_manifest_detection = build.index(
    'if [ "$manifest_entry" = "0040-headless-vout-teardown-deadlock.patch" ]; then'
)
warning_manifest_detection = build.index(
    'if [ "$manifest_entry" = "0035-chromecast-metadata-warning.patch" ]; then'
)
schema_manifest_detection = build.index(
    'if [ "$manifest_entry" = "0036-chromecast-metadata-schema-correctness.patch" ]; then'
)
load_transition_manifest_detection = build.index(
    'if [ "$manifest_entry" = "0037-chromecast-load-transition-correctness.patch" ]; then'
)
clean_build_gate = build.index('error "Patch 0038 requires --clean-build;')
aom_clean_build_gate = build.index('error "Patch 0039 requires --clean-build;')
patch_replay = build.index('if [ "$patch_series_matches" = yes ]; then')
assembly_source_gate = build.index(
    'info "Validating Apple assembly tool and Mach-O metadata source contract..."'
)
aom_source_gate = build.index(
    'info "Validating libaom 3.13.2 and NASM 3 detection source contract..."'
)
headless_source_gate = build.index(
    'info "Validating headless video-output teardown source contract..."'
)
first_other_post_replay_gate = build.index(
    '# Patches 0035–0037 deliberately change no public API'
)
dynamic_source_edit = build.index('\npatch_vlc_snapshot_filter_owner\n')
if not (
    warning_manifest_detection
    < schema_manifest_detection
    < load_transition_manifest_detection
    < assembly_manifest_detection
    < aom_manifest_detection
    < headless_manifest_detection
    < clean_build_gate
    < aom_clean_build_gate
    < patch_replay
    < assembly_source_gate
    < aom_source_gate
    < headless_source_gate
    < first_other_post_replay_gate
    < dynamic_source_edit
):
    sys.exit(
        "0038 clean-build/source validation is not ordered before dynamic source edits"
    )
if (
    'if [ "$apple_assembly_metadata_patch_listed" = yes ] &&\n'
    '       [ "$CLEAN_BUILD" != yes ]; then'
    not in build
):
    sys.exit("0038 is not guarded by an exact clean-build requirement")
if (
    '"${SCRIPT_DIR}/validate-apple-assembly-metadata-patch.sh" \\\n'
    '            "${VLC_SRC}" "${BUILD_DIR}/validation/0038-apple-assembly-metadata"'
    not in build
):
    sys.exit("build does not invoke the standalone 0038 validator exactly")
if (
    'if [ "$aom_nasm3_detection_patch_listed" = yes ] &&\n'
    '       [ "$CLEAN_BUILD" != yes ]; then'
    not in build
):
    sys.exit("0039 is not guarded by an exact clean-build requirement")
if (
    '"${SCRIPT_DIR}/validate-aom-nasm3-detection.sh" \\\n'
    '            "${VLC_SRC}" "${BUILD_DIR}/validation/0039-aom-nasm3-detection"'
    not in build
):
    sys.exit("build does not invoke the standalone 0039 validator exactly")
if (
    '"${SCRIPT_DIR}/validate-headless-vout-teardown.sh" \\\n'
    '            --source-root "${VLC_SRC}" \\\n'
    '            --work-root "${BUILD_DIR}/validation/0040-headless-vout-teardown"'
    not in build
):
    sys.exit("build does not invoke the standalone 0040 source validator exactly")

for assignment in (
    "chromecast_metadata_warning_patch_listed=no",
    "chromecast_metadata_schema_patch_listed=no",
    "chromecast_load_transition_patch_listed=no",
    "apple_assembly_metadata_patch_listed=no",
    "aom_nasm3_detection_patch_listed=no",
    "headless_vout_teardown_patch_listed=no",
    "chromecast_metadata_warning_patch_listed=yes",
    "chromecast_metadata_schema_patch_listed=yes",
    "chromecast_load_transition_patch_listed=yes",
    "apple_assembly_metadata_patch_listed=yes",
    "aom_nasm3_detection_patch_listed=yes",
    "headless_vout_teardown_patch_listed=yes",
):
    if build.count(assignment) != 1:
        sys.exit(f"native patch selector is not initialized exactly once: {assignment}")
load_transition_selection = build.index(
    'if [ "$chromecast_load_transition_patch_listed" = yes ]; then',
    assembly_source_gate,
)
schema_fallback = build.index(
    'elif [ "$chromecast_metadata_schema_patch_listed" = yes ]; then',
    load_transition_selection,
)
warning_fallback = build.index(
    'elif [ "$chromecast_metadata_warning_patch_listed" = yes ]; then',
    schema_fallback,
)
if not (
    assembly_source_gate
    < load_transition_selection
    < schema_fallback
    < warning_fallback
    < dynamic_source_edit
):
    sys.exit("Chromecast validators are not selected newest-first before source edits")
if build.count('"${SCRIPT_DIR}/validate-chromecast-load-transition.sh"') != 1:
    sys.exit("build must invoke the 0037 final-source validator exactly once")
if build.count('"${SCRIPT_DIR}/validate-chromecast-metadata-schema.sh"') != 1:
    sys.exit("build must retain exactly one 0036-only fallback validator")
if (
    '"${SCRIPT_DIR}/validate-chromecast-metadata-schema.sh" \\\n'
    '            "${VLC_SRC}" "${BUILD_DIR}/validation/0036-chromecast-metadata-schema"'
    not in build
):
    sys.exit("0036 fallback does not keep generated validation work external")
if (
    '"${SCRIPT_DIR}/validate-chromecast-load-transition.sh" \\\n'
    '            "${VLC_SRC}" "${BUILD_DIR}/validation/0037-chromecast-load-transition"'
    not in build
):
    sys.exit("build does not invoke the 0037 validator with an external build work root")
if (
    'if [ "$chromecast_load_transition_patch_listed" != yes ] &&\n'
    '       [ -f "${VLC_SRC}/modules/stream_out/chromecast/chromecast_demux_eof.hpp" ]; then'
    not in build
):
    sys.exit("build does not suppress the redundant frozen 0034 gate under 0037")
if build.count('"${SCRIPT_DIR}/validate-chromecast-state.sh"') != 1:
    sys.exit("build must retain exactly one direct 0034 fallback gate")
if build.count('"${SCRIPT_DIR}/validate-post-pin-stability.sh"') != 1:
    sys.exit("build must retain the complete post-pin linked/native gate exactly once")
tools_build = build.index('info "Building VLC build tools..."')
post_pin_call = build.index(
    '"${SCRIPT_DIR}/validate-post-pin-stability.sh" \\\n'
    '        "${VLC_SRC}" "${BUILD_DIR}/validation"'
)
if post_pin_call < tools_build:
    sys.exit("post-pin linked/native validation runs before its generated tools exist")

checker_call = load_transition_validator.index(
    'PYTHONDONTWRITEBYTECODE=1 python3 "$CHECKER" "$VLC_SOURCE_ROOT" "$PATCH"'
)
base_probe_call = load_transition_validator.index(
    'compile_and_run "$BASE_PROBE"'
)
schema_probe_call = load_transition_validator.index(
    'compile_and_run "$SCHEMA_PROBE"'
)
load_transition_probe_call = load_transition_validator.index(
    'compile_and_run "$PROBE"'
)
if not checker_call < base_probe_call < schema_probe_call < load_transition_probe_call:
    sys.exit("0037 standalone validation does not run its checker and inherited probes in order")
for marker in (
    'check_hash "$SCHEMA_CHECKER" "$EXPECTED_SCHEMA_CHECKER_SHA"',
    'check_hash "$SCHEMA_PROBE" "$EXPECTED_SCHEMA_PROBE_SHA"',
    'check_hash "$SCHEMA_PATCH" "$EXPECTED_SCHEMA_PATCH_SHA"',
    'check_hash "$WARNING_CHECKER" "$EXPECTED_WARNING_CHECKER_SHA"',
    'check_hash "$WARNING_PATCH" "$EXPECTED_WARNING_PATCH_SHA"',
    'check_hash "$BASE_CHECKER" "$EXPECTED_BASE_CHECKER_SHA"',
    'check_hash "$BASE_PROBE" "$EXPECTED_BASE_PROBE_SHA"',
    'check_hash "$COMPAT" "$EXPECTED_COMPAT_SHA"',
):
    if load_transition_validator.count(marker) != 1:
        sys.exit(f"0037 standalone validator does not hash-bind {marker}")

final_schema_contract = load_transition_checker.index(
    "schema_checker.validate_sources(final_schema_sources)"
)
reverse_to_predecessor = load_transition_checker.index(
    "reconstructed = dict(sources)", final_schema_contract
)
predecessor_schema_contract = load_transition_checker.index(
    "schema_checker.validate_sources(predecessor_schema_sources)",
    reverse_to_predecessor,
)
predecessor_schema_mutations = load_transition_checker.index(
    "schema_checker.run_source_mutations(\n        predecessor_schema_sources",
    predecessor_schema_contract,
)
new_source_mutations = load_transition_checker.index(
    "source_mutations = run_source_mutations(sources)",
    predecessor_schema_mutations,
)
if not (
    final_schema_contract
    < reverse_to_predecessor
    < predecessor_schema_contract
    < predecessor_schema_mutations
    < new_source_mutations
):
    sys.exit("0037 does not separate final 0036 semantics from predecessor mutations")
if load_transition_checker.count("schema_checker.run_source_mutations(") != 1:
    sys.exit("frozen 0036 mutation suite must run exactly once")
if "schema_checker.run_source_mutations(final_schema_sources)" in load_transition_checker:
    sys.exit("frozen 0036 mutations are incorrectly running on 0037 final source")
if "source.count(old) != 1" not in load_transition_checker:
    sys.exit("0037 mutation fixtures are not fail-closed on exact uniqueness")

post_pin_hash_inputs = (
    '"$SOURCE_CHECK"',
    '"$PROBE"',
    '"$ICONV_SUPPORT"',
    '"$COMPAT"',
    '"$UPNP_PROBE"',
    '"$UPNP_FAKES/vlc_common.h"',
    '"$UPNP_FAKES/vlc_threads.h"',
    '"$UPNP_FAKES/vlc_cxx_helpers.hpp"',
    '"$UPNP_FAKES/vlc_charset.h"',
    '"$UPNP_FAKES/upnp.h"',
    '"$UPNP_FAKES/upnptools.h"',
    '"$UPNP_FAKES/TargetConditionals.h"',
)
for bound_input in post_pin_hash_inputs:
    marker = f"verify_sha256 {bound_input}"
    if post_pin_validator.count(marker) != 1:
        sys.exit(f"post-pin wrapper does not hash-bind exactly once: {bound_input}")
for retained_evidence in (
    'python3 "$SOURCE_CHECK" --self-test',
    'python3 "$SOURCE_CHECK" "$VLC_SOURCE_ROOT"',
    '\n"$VALIDATION_DIR/post-pin-stability-probe"\n',
    '\n"$VALIDATION_DIR/upnp-lifecycle-probe"\n',
):
    if post_pin_validator.count(retained_evidence) != 1:
        sys.exit(f"post-pin linked/native evidence was dropped: {retained_evidence}")

staged_output_setup = build.index(
    'STAGED_OUTPUT_CHILD=".swiftvlc-native-output"'
)
staged_output_initialization = build.index(
    '"${SCRIPT_DIR}/detach-managed-build-directory.py" initialize \\\n',
    staged_output_setup,
)
staged_output_require_new = build.index(
    '    --require-new; then', staged_output_initialization
)
staged_output_anchor = build.index(
    'cd "${STAGED_OUTPUT_CHILD}"', staged_output_require_new
)
artifact_creation = build.index('\nxcodebuild -create-xcframework \\\n')
if not (
    staged_output_setup
    < staged_output_initialization
    < staged_output_require_new
    < staged_output_anchor
    < artifact_creation
):
    sys.exit("native artifact is not assembled in a fresh bound staging directory")
if 'rm -rf "${OUTPUT_DIR}/libvlc.xcframework"' in build:
    sys.exit("native artifact replacement regressed to pathname-recursive deletion")
stage_phase = build[staged_output_anchor:]
if (
    'retire_directory_binding \\\n'
    '    "${STAGED_OUTPUT_BINDING_NAME}" "${STAGED_OUTPUT_BINDING_CONTENT}"'
    in stage_phase
):
    sys.exit("native output stage retires its generation binding before cleanup")
if stage_phase.count(
    'verify_directory_binding \\\n'
    '    "${STAGED_OUTPUT_BINDING_NAME}" "${STAGED_OUTPUT_BINDING_CONTENT}"'
) != 2:
    sys.exit("native output stage is not generation-verified at entry and publication")

build_metadata_verification = build.index(
    'info "Verifying per-object Mach-O platform metadata and section alignment..."'
)
provenance = build.index('python3 "${SCRIPT_DIR}/libvlc-provenance.py" create')
if provenance < build_metadata_verification:
    sys.exit("provenance is written before per-object Mach-O verification")
evidence_invalidation = (
    'rm -f ./libvlc-provenance-a.json \\\n'
    '    ./libvlc-provenance.json \\\n'
    '    ./libvlc-reproducibility.json \\\n'
    '    ./libvlc-macho-metadata.json'
)
if build.count(evidence_invalidation) != 2:
    sys.exit(
        "native build does not invalidate A/B provenance, proof, and Mach-O "
        "evidence as one exact set at startup and final publication"
    )
startup_evidence_invalidation = build.index(evidence_invalidation)
if startup_evidence_invalidation > build.index(
    'info "Setting up VLC source..."'
):
    sys.exit("native build invalidates stale two-build evidence after source setup")

output_lock_call = build.index('\nacquire_output_lock\n')
original_vendor_bind = build.index(
    'if ! bind_directory_for_handoff \\\n'
    '            . Vendor \\\n',
    output_lock_call,
)
external_root_reanchor = build.index(
    'configure_external_build_root "${BUILD_ROOT_OVERRIDE}"',
    original_vendor_bind,
)
if not (
    output_lock_call
    < original_vendor_bind
    < external_root_reanchor
    < startup_evidence_invalidation
):
    sys.exit("checkout lock/Vendor continuity is established after external re-anchor")
if (
    'cd -P ..\n'
    '        if [ "$(/bin/pwd -P)" != "${REPO_ROOT}" ]; then'
    not in build[output_lock_call:original_vendor_bind]
):
    sys.exit("original Vendor bind is not rooted in the physical checkout parent")
if '$(pwd -P)' in build:
    sys.exit("native path identity relies on Bash 3.2's stale cached pwd builtin")

output_lock_function_start = build.index('acquire_output_lock() {')
output_lock_function_end = build.index(
    '\n}\n\ninitialize_managed_build_directory()', output_lock_function_start
)
output_lock_function = build[output_lock_function_start:output_lock_function_end]
for lock_marker in (
    'lock-acquire',
    '--root-fd "${OUTPUT_LOCK_PARENT_FD}"',
    '--child "${OUTPUT_LOCK_NAME}"',
    '--token-name "${LOCK_TOKEN_NAME}"',
    '--token-content "${OUTPUT_LOCK_TOKEN_CONTENT}"',
):
    if output_lock_function.count(lock_marker) != 1:
        sys.exit(f"checkout output lock is not descriptor-anchored: {lock_marker}")
release_output_lock_start = build.index('release_output_lock() {')
release_output_lock_end = build.index(
    '\n}\n\nclose_output_lock_parent()', release_output_lock_start
)
release_output_lock_function = build[
    release_output_lock_start:release_output_lock_end
]
for lock_marker in (
    'lock-release',
    '--root-fd "${OUTPUT_LOCK_PARENT_FD}"',
    '--child "${OUTPUT_LOCK_NAME}"',
    '--token-name "${LOCK_TOKEN_NAME}"',
    '--token-content "${OUTPUT_LOCK_TOKEN_CONTENT}"',
):
    if release_output_lock_function.count(lock_marker) != 1:
        sys.exit(f"checkout output lock release is not descriptor-safe: {lock_marker}")
if 'rmdir "${OUTPUT_LOCK_DIR}"' in build:
    sys.exit("checkout output lock release regressed to an absolute pathname")

build_lock_function_start = build.index('acquire_build_root_lock() {')
build_lock_function_end = build.index(
    '\n}\n\nreject_stale_managed_build_state()', build_lock_function_start
)
build_lock_function = build[build_lock_function_start:build_lock_function_end]
for lock_marker in (
    'exec 8<.',
    'lock-acquire',
    '--root-fd "${BUILD_LOCK_PARENT_FD}"',
    '--child "${BUILD_LOCK_DIR}"',
    '--token-name "${LOCK_TOKEN_NAME}"',
    '--token-content "${BUILD_LOCK_TOKEN_CONTENT}"',
):
    if build_lock_function.count(lock_marker) != 1:
        sys.exit(f"external build-root lock is not generation-bound: {lock_marker}")
release_build_lock_start = build.index('release_build_root_lock() {')
release_build_lock_end = build.index(
    '\n}\n\nclose_build_lock_parent()', release_build_lock_start
)
release_build_lock_function = build[
    release_build_lock_start:release_build_lock_end
]
for lock_marker in (
    'lock-release',
    '--root-fd "${BUILD_LOCK_PARENT_FD}"',
    '--child "${BUILD_LOCK_DIR}"',
    '--token-name "${LOCK_TOKEN_NAME}"',
    '--token-content "${BUILD_LOCK_TOKEN_CONTENT}"',
):
    if release_build_lock_function.count(lock_marker) != 1:
        sys.exit(f"external build-root lock release is not generation-safe: {lock_marker}")
if 'mkdir "${BUILD_LOCK_DIR}"' in build or 'rmdir "${BUILD_LOCK_DIR}"' in build:
    sys.exit("external build-root lock regressed to pathname-only mkdir/rmdir")

publication_binding = build.index(
    '    "${PUBLISHING_BINDING_NAME}" "${PUBLISHING_BINDING_CONTENT}" \\\n'
    '    --create; then'
)
publication_copy = build.index(
    '    "${STAGED_OUTPUT_DIRECTORY}/libvlc.xcframework" \\\n'
    '    ./libvlc.xcframework',
    publication_binding,
)
published_tree_verification = build.index(
    'module.verify_recorded_artifact(record, published_path, "published XCFramework")',
    publication_copy,
)
old_artifact_cleanup = build.index(
    '"${SCRIPT_DIR}/detach-managed-build-directory.py" clean \\\n'
    '        --root . \\\n'
    '        --child libvlc.xcframework',
    published_tree_verification,
)
final_evidence_invalidation = build.index(
    evidence_invalidation, old_artifact_cleanup
)
publication = build.index(
    '"${SCRIPT_DIR}/detach-managed-build-directory.py" publish \\\n',
    final_evidence_invalidation,
)
publication_command_end = build.index(
    '; then', publication
)
publication_command = build[publication:publication_command_end]
expected_publication_entries = (
    '    --entry libvlc.xcframework \\\n'
    '    --entry libvlc-macho-metadata.json \\\n'
    '    --entry libvlc-provenance.json'
)
if publication_command.count(expected_publication_entries) != 1:
    sys.exit("native publication does not move provenance last as its commit marker")
if not (
    provenance
    < publication_binding
    < publication_copy
    < published_tree_verification
    < old_artifact_cleanup
    < final_evidence_invalidation
    < publication
):
    sys.exit("native publication is not bound, verified, invalidated, and committed in order")
for unsafe_publication in (
    'mkdir "${PUBLISHING_CHILD}"',
    'mv "${PUBLISHING_CHILD}/',
    'rmdir "${PUBLISHING_CHILD}"',
):
    if unsafe_publication in build:
        sys.exit(f"native publication bypasses the fd-safe helper: {unsafe_publication}")
stage_cleanup = build.index(
    '"${SCRIPT_DIR}/detach-managed-build-directory.py" clean \\\n'
    '    --root . \\\n'
    '    --child "${STAGED_OUTPUT_CHILD}"',
    publication,
)
stage_cleanup_end = build.index('; then', stage_cleanup)
stage_cleanup_command = build[stage_cleanup:stage_cleanup_end]
for generation_marker in (
    '--marker-name "${STAGED_OUTPUT_BINDING_NAME}"',
    '--marker-content "${STAGED_OUTPUT_BINDING_CONTENT}"',
):
    if stage_cleanup_command.count(generation_marker) != 1:
        sys.exit(
            "native output cleanup is not authorized by its invocation binding: "
            f"{generation_marker}"
        )
for preserved_state in (
    'for preserved_checkout_state in \\\n'
    '            ./.swiftvlc-managed-build.initializing-*',
    './.swiftvlc-native-output-publishing-* \\\n'
    '    ./.swiftvlc-published-artifact.removing-* \\\n'
    '    ./.swiftvlc-managed-build.initializing-*',
    './.swiftvlc-native-output \\\n'
    '    ./.swiftvlc-native-output.removing-* \\\n'
    '    ./.swiftvlc-managed-build.initializing-*',
):
    if build.count(preserved_state) != 1:
        sys.exit(f"native build does not surface preserved helper state: {preserved_state}")

build_validator_asset_verification = build.index(
    'if ! python3 "${SCRIPT_DIR}/verify-native-validator-assets.py"; then'
)
build_source_setup = build.index('info "Setting up VLC source..."')
if build_validator_asset_verification > build_source_setup:
    sys.exit("native validator assets are verified after VLC source setup")

expected_extension_patch_versions = {
    "0004-samplebuffer-pip-safety-geometry.patch": 1,
    "0022-atomic-pip-playback-snapshot.patch": 2,
    "0024-native-pip-overlays.patch": 3,
    "0027-strict-frame-step-contract.patch": 4,
    "0029-sample-buffer-renderer-recovery.patch": 5,
    "0030-vmem-picture-pts.patch": 6,
    "0031-effective-playback-rate-event.patch": 7,
    "0032-audio-media-services-reset.patch": 8,
    "0041-native-pip-output-identity.patch": 9,
    "0043-text-subtitle-callback.patch": 10,
}
for patch_name, version in expected_extension_patch_versions.items():
    marker = (
        f"{patch_name})\n"
        f"                manifest_extension_candidate={version} ;;"
    )
    if build.count(marker) != 1:
        sys.exit(
            "build does not map the patch manifest to one exact native "
            f"extension version: {patch_name} -> {version}"
        )
lease_marker = (
    "0033-apple-audio-session-policy-leases.patch)\n"
    "                swiftvlc_apple_audio_session_leases_listed=yes ;;"
)
if build.count(lease_marker) != 1:
    sys.exit("build does not track the 0033 same-version lease refinement")
inherited_lease_guard = (
    'if [ -n "$swiftvlc_manifest_extension_version" ] &&\n'
    '   [ "$swiftvlc_manifest_extension_version" -ge 9 ] &&\n'
    '   [ "$swiftvlc_apple_audio_session_leases_listed" != yes ]; then'
)
if build.count(inherited_lease_guard) != 1:
    sys.exit("build lets extension v9 erase the inherited 0033 lease refinement")

for marker in (
    '"native-pip-playback-identity",\n        9,',
    '"PiP playback identity typedef"',
    '"PiP playback identity setter declaration"',
    '"PiP playback identity setter implementation"',
    '"PiP playback identity setter export"',
    '"exact preserved PiP controller take declaration"',
    '"exact preserved PiP controller publication declaration"',
    '"exact PiP controller readiness declaration"',
    '"exact PiP controller claim declaration"',
    '"unclaimed PiP controller rollback declaration"',
    '"exact PiP controller handoff cancellation declaration"',
    '"exact PiP controller handoff timeout declaration"',
    '"fail-closed exact PiP lifecycle preflight"',
    'def validate_v9_native_pip_identity_semantics(',
    'def validate_v9_native_pip_claim_semantics(',
    'def validate_weak_compatibility_shim(shim_source: str) -> None:',
    'effective_required_groups.add("apple-audio-session-leases")',
    '"subtitle-text-snapshot",\n        10,',
    '"subtitle text snapshot declaration"',
    '"subtitle text snapshot implementation"',
    '"subtitle text snapshot export"',
    'subtitle_weak_signature = re.compile(',
    '"weak subtitle text snapshot fallback",',
    'subtitle_wrapper_contract = (',
    '"version-gated subtitle text snapshot wrapper",',
    'subtitle_availability_contract = (',
    '"subtitle text snapshot availability helper",',
    'expected version must be an integer from 4 through 10',
):
    if extension_resolver.count(marker) != 1:
        sys.exit(f"v10 source resolver contract is incomplete: {marker}")
for marker in (
    'Usage: $0 --expected-version <1..10>',
    'if [[ ! "$EXPECTED_VERSION" =~ ^([1-9]|10)$ ]]; then',
    'An exact expected extension version from 1 through 10 is required.',
    'VERSION_9_SYMBOLS=(\n'
    '        swiftvlc_libvlc_media_player_set_pip_playback_identity\n'
    '    )',
    'VERSION_10_SYMBOLS=(\n'
    '        swiftvlc_libvlc_media_player_set_subtitle_text_snapshot_callback\n'
    '    )',
    'if (( EXPECTED_VERSION >= 9 )); then\n'
    '    # v9 succeeds the final v8+0033 profile. Do not let omission of an optional\n'
    '    # command-line flag turn an inherited safety contract back into an option.\n'
    '    REQUIRE_LEASES=yes\n'
    'fi',
    'if (( EXPECTED_VERSION >= 10 )); then',
    'if (( EXPECTED_VERSION < 10 )); then',
    'resolver.validate_weak_compatibility_shim(',
):
    if native_extension_validator.count(marker) != 1:
        sys.exit(f"v10 archive/compatibility validator is incomplete: {marker}")
for marker in (
    'SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION > 10',
    'sizeof(swiftvlc_pip_playback_identity_t) == 16',
    'offsetof(swiftvlc_pip_playback_identity_t,',
    'swiftvlc_libvlc_media_player_set_pip_playback_identity,',
    'native PiP identity setter accepted a null player',
    'swiftvlc_set_subtitle_text_snapshot_callback_function_t',
    'swiftvlc_libvlc_media_player_set_subtitle_text_snapshot_callback,',
    'subtitle text callback setter accepted a null player',
    '#if SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION >= 9 \\\n'
    ' && !SWIFTVLC_REQUIRE_APPLE_AUDIO_SESSION_LEASES',
):
    if marker not in native_extension_probe:
        sys.exit(f"v10 linked type/runtime probe is incomplete: {marker}")
for marker in (
    '__attribute__((weak))\n'
    'bool swiftvlc_libvlc_media_player_set_pip_playback_identity(',
    'swiftvlc_libvlc_pip_extensions_version() < 9',
    'swiftvlc_libvlc_pip_extensions_version() >= 9',
):
    if clibvlc_shim.count(marker) != 1:
        sys.exit(f"v9 weak compatibility source is incomplete: {marker}")
for marker in (
    '__attribute__((weak))\n'
    'bool swiftvlc_libvlc_media_player_set_subtitle_text_snapshot_callback(',
    'swiftvlc_libvlc_pip_extensions_version() < 10',
    'swiftvlc_libvlc_pip_extensions_version() >= 10',
):
    if clibvlc_shim.count(marker) != 1:
        sys.exit(f"v10 weak callback compatibility source is incomplete: {marker}")
adaptive_source_gate = native_patch_series_validator.index(
    'section "Validating adaptive ES codec-configuration recycling"'
)
v10_source_gate = native_patch_series_validator.index(
    'section "Validating exact integrated extension version 10"'
)
subtitle_snapshot_gate = native_patch_series_validator.index(
    'section "Validating ordered semantic subtitle-text snapshots"'
)
pip_identity_gate = native_patch_series_validator.index(
    'section "Validating native PiP output identity and race semantics"'
)
strict_source_gate = native_patch_series_validator.index(
    'section "Validating strict frame-step source semantics"'
)
if not (
    adaptive_source_gate
    < v10_source_gate
    < subtitle_snapshot_gate
    < pip_identity_gate
    < strict_source_gate
):
    sys.exit(
        "0042/v10/0043/0041/legacy native source gates are out of fail-closed "
        "order"
    )
for marker in (
    '--expected-version 10',
    '"$SCRIPT_DIR/patches/validation/adaptive-es-recycling-source-check.py"',
    '"$SCRIPT_DIR/patches/0042-adaptive-es-recycling-extradata-identity.patch"',
    '"$SCRIPT_DIR/patches/validation/native-pip-output-identity-source-check.py"',
    '"$SCRIPT_DIR/patches/0041-native-pip-output-identity.patch"',
    '"$SCRIPT_DIR/patches/validation/native-pip-output-identity-race.c"',
    '-std=c11 -O2 -Wall -Wextra -Werror -pthread',
):
    if native_patch_series_validator.count(marker) != 1:
        sys.exit(f"native source replay is missing one exact 0041/0042 proof: {marker}")
for marker in (
    'section "Validating ordered semantic subtitle-text snapshots"',
    'subtitle_snapshot_compiler="${CC:-cc}"',
    'C compiler not found for subtitle-text snapshot proof',
    '"$subtitle_snapshot_compiler" -std=c11 -O2 -Wall -Wextra -Werror \\\n'
    '    "$SCRIPT_DIR/patches/validation/subtitle-text-snapshot.c" \\\n'
    '    -o "$REPLAY_DIR/subtitle-text-snapshot"',
    '"$REPLAY_DIR/subtitle-text-snapshot"\n\n'
    'section "Validating native PiP output identity and race semantics"',
):
    if native_patch_series_validator.count(marker) != 1:
        sys.exit(
            "native source replay is missing the exact 0043 semantic-text "
            f"snapshot proof: {marker}"
        )
for export_marker in (
    'export SWIFTVLC_EXPECTED_EXTENSION_VERSION="$swiftvlc_manifest_extension_version"',
    'export SWIFTVLC_REQUIRE_APPLE_AUDIO_SESSION_LEASES="$swiftvlc_apple_audio_session_leases_listed"',
):
    if build.count(export_marker) != 1:
        sys.exit(f"build does not export manifest-owned validator intent: {export_marker}")

native_source_contract_setup = build.index(
    'native_source_contract_args=('
)
native_source_contract = build.index(
    'info "Validating the manifest-owned native extension source and vendored-header contract..."'
)
first_legacy_native_source_gate = build.index(
    '# Exercise the exact production helper whenever this patch is in the engine'
)
if not (
    patch_replay
    < native_source_contract_setup
    < native_source_contract
    < first_legacy_native_source_gate
):
    sys.exit(
        "manifest-owned native extension source validation is not between "
        "exact patch replay and legacy source gates"
    )
native_source_command = build[
    native_source_contract_setup:first_legacy_native_source_gate
]
for marker in (
    '--source-root "$VLC_SRC"',
    '--expected-version "$SWIFTVLC_EXPECTED_EXTENSION_VERSION"',
    '--run-mutations',
    'native_source_contract_args+=(--require-apple-audio-session-leases)',
):
    if native_source_command.count(marker) != 1:
        sys.exit(f"native extension source contract is incomplete: {marker}")

audio_source_contract = build.index(
    'info "Validating Apple audio reset/ownership ARC source contract before native compilation..."'
)
dynamic_source_edit = build.index('\npatch_vlc_snapshot_filter_owner\n')
if not native_source_contract < audio_source_contract < dynamic_source_edit:
    sys.exit(
        "Apple audio ARC source validation is not between exact patch replay "
        "and native compilation setup"
    )
audio_source_region = build[audio_source_contract:dynamic_source_edit]
if audio_source_region.count(
    '"${SCRIPT_DIR}/validate-audio-media-services-reset.sh" "${VLC_SRC}"'
) != 1:
    sys.exit("pre-build Apple audio ARC source validation is missing or duplicated")

arc_broker_syntax = (
    '"$CLANG" "${COMMON[@]}" -fobjc-arc \\\n'
    '    "$VLC_SOURCE_ROOT/src/darwin/apple_audio_session.m"'
)
if audio_reset_validator.count(arc_broker_syntax) != 1:
    sys.exit("Apple audio broker syntax proof does not mirror its ARC build mode")

for marker in (
    'if [[ -f "$VLC_BUILD_ROOT/config.h" ]]; then',
    'VLC_BUILD_DIR="$(cd "$VLC_BUILD_ROOT" && pwd)"',
    'elif [[ -f "$VLC_BUILD_ROOT/build/config.h" ]]; then',
    'VLC_BUILD_DIR="$(cd "$VLC_BUILD_ROOT/build" && pwd)"',
):
    if strict_frame_validator.count(marker) != 1:
        sys.exit(
            "strict-frame validator does not normalize direct and nested "
            f"configured VLC roots exactly once: {marker}"
        )
for stale_include in (
    '-I "$VLC_BUILD_ROOT"',
    '-I "$VLC_BUILD_ROOT/include"',
):
    if stale_include in strict_frame_validator:
        sys.exit(
            "strict-frame validator bypasses its normalized VLC build root: "
            f"{stale_include}"
        )
for marker in (
    'if [[ "$EXPECTED_EXTENSION_VERSION" == 9 ||\n'
    '      "$EXPECTED_EXTENSION_VERSION" == 10 ]]; then\n'
    '  REQUIRE_APPLE_AUDIO_SESSION_LEASES=yes\n'
    'fi',
    'if [[ "$EXPECTED_EXTENSION_VERSION" -ge 9 &&\n'
    '        "$REQUIRE_APPLE_AUDIO_SESSION_LEASES" != yes ]]; then',
    'LEASE_DEFINE="-DSWIFTVLC_REQUIRE_APPLE_AUDIO_SESSION_LEASES=',
):
    if strict_frame_validator.count(marker) != 1:
        sys.exit(
            "strict-frame validator does not inherit the v9+ Apple audio lease "
            f"contract exactly once: {marker}"
        )
for marker in (
    'STRICT_MACOS_BUILD_CONTAINER="${VLC_SRC}/build-macosx-${HOST_MACOS_ARCH}"',
    'if [ -f "${STRICT_MACOS_BUILD_CONTAINER}/config.h" ]; then',
    'STRICT_MACOS_BUILD_ROOT="${STRICT_MACOS_BUILD_CONTAINER}"',
    'elif [ -f "${STRICT_MACOS_BUILD_CONTAINER}/build/config.h" ]; then',
    'STRICT_MACOS_BUILD_ROOT="${STRICT_MACOS_BUILD_CONTAINER}/build"',
    '"${VLC_SRC}" "${STRICT_MACOS_BUILD_ROOT}"',
):
    if build.count(marker) != 1:
        sys.exit(
            "native build does not pass one normalized strict-frame host "
            f"build root: {marker}"
        )

for marker in (
    'if (event->type == libvlc_MediaPlayerPlaying)',
    'libvlc_MediaPlayerPlaying,',
    'libvlc_event_attach(events, lifecycle_events[index],',
    'wait_for_playing(&observations, 5000)',
    'TIMEOUT effective-rate playback or teardown did not terminate',
):
    if effective_rate_probe.count(marker) != 1:
        sys.exit(
            "effective-rate runtime probe lost its event-driven bounded "
            f"startup contract: {marker}"
        )
if 'state == libvlc_Error || state == libvlc_Stopped' in effective_rate_probe:
    sys.exit("effective-rate runtime probe again treats initial Stopped as terminal")

for marker in (
    'libvlc_event_attach(events, libvlc_MediaPlayerPlaying,',
    'if (count >= 3 && distinct)',
    'if (state == libvlc_Stopped && saw_started)',
    'if (!stop_completed)',
    'TIMEOUT vmem PTS playback or teardown did not terminate',
):
    if vmem_pts_probe.count(marker) != 1:
        sys.exit(
            "vmem PTS runtime probe lost its transition/evidence-complete "
            f"wait contract: {marker}"
        )
if re.search(r"if \(count >= 3\)\s+return true;", vmem_pts_probe):
    sys.exit("vmem PTS runtime probe again accepts duplicate-only callbacks")
vmem_stop_gate = vmem_pts_probe.index('    if (!stop_completed)\n')
vmem_quiescing_release = vmem_pts_probe.index(
    '    libvlc_media_player_release(player);\n'
    '    player = NULL;\n'
    '    events = NULL;\n'
)
vmem_final_snapshot = vmem_pts_probe.index(
    '    pthread_mutex_lock(&context.lock);\n'
    '    count = context.callback_count;\n'
)
if not vmem_stop_gate < vmem_quiescing_release < vmem_final_snapshot:
    sys.exit(
        "vmem PTS runtime probe snapshots evidence before bounded stop and "
        "callback-quiescing player release"
    )

archive_repair = build.index(
    '"${SCRIPT_DIR}/fix-duplicate-symbols.sh" "${OUTPUT_DIR}/libvlc.xcframework"'
)
headless_runtime_selection = build.index(
    'if [ "$headless_vout_teardown_patch_listed" = yes ] && [ "$BUILD_MACOS" = "yes" ]; then'
)
headless_runtime_gate = build.index(
    'info "Validating bounded headless video-output stop and natural-EOF teardown..."'
)
final_archive_mutation = build.index(
    'find "${OUTPUT_DIR}/libvlc.xcframework" -name \'*.a\' -exec xcrun ranlib -D {} \\;'
)
checkout_path_gate = build.index(
    'if [ "${EXTERNAL_BUILD_ROOT}" = yes ]; then\n'
    '    info "Verifying that the release artifact contains no checkout-local paths..."'
)
native_archive_contract_setup = build.index(
    'native_archive_contract_args=('
)
native_archive_contract = build.index(
    'info "Validating the exact linked native extension archive contract across every produced slice..."'
)
archive_metadata_gate = build.index(
    'info "Verifying per-object Mach-O platform metadata and section alignment..."'
)
if not (
    archive_repair
    < headless_runtime_selection
    < headless_runtime_gate
    < final_archive_mutation
    < checkout_path_gate
    < native_archive_contract_setup
    < native_archive_contract
    < archive_metadata_gate
):
    sys.exit(
        "exact linked native extension validation is not after the final "
        "archive mutation and before artifact metadata/provenance gates"
    )
checkout_path_gate_region = build[
    checkout_path_gate:native_archive_contract_setup
]
checkout_path_function_start = build.index(
    'verify_checkout_path_not_embedded() {'
)
checkout_path_function = build[
    checkout_path_function_start:build.index(
        '\n}\n\ntrap release_build_locks EXIT', checkout_path_function_start
    )
]
for marker in (
    '"${SCRIPT_DIR}/verify-libvlc-build-paths.py"',
    '--xcframework-parent-fd 7',
    '--xcframework-child "libvlc.xcframework"',
    '--forbidden-path "${REPO_ROOT}"',
    '7<.',
):
    if checkout_path_function.count(marker) != 1:
        sys.exit(f"checkout-path verifier invocation is incomplete: {marker}")
for stale_path in (
    '${STAGED_OUTPUT_DIRECTORY}/libvlc.xcframework',
    '${OUTPUT_DIR}/libvlc.xcframework',
):
    if stale_path in checkout_path_function:
        sys.exit(f"checkout-path verifier re-entered pathname resolution: {stale_path}")
for marker in (
    'if [ "${EXTERNAL_BUILD_ROOT}" = yes ]; then',
    'verify_checkout_path_not_embedded',
):
    if checkout_path_gate_region.count(marker) != 1:
        sys.exit(f"checkout-path gate is not ordered after archive normalization: {marker}")
if (
    'if [ "${CLEAN_BUILD}" = yes ] && [ "${BUILD_ROOT_OVERRIDE_SET}" != yes ]; then'
    not in build
    or '--clean-build requires a canonical external --build-root' not in build
):
    sys.exit("clean provenance builds do not require the canonical external root")
headless_runtime_region = build[headless_runtime_selection:final_archive_mutation]
for marker in (
    'if [ "$headless_vout_teardown_patch_listed" = yes ] && [ "$BUILD_MACOS" = "yes" ]; then',
    '"${SCRIPT_DIR}/validate-headless-vout-teardown.sh" \\\n',
    '        --source-root "${VLC_SRC}" \\\n',
    '        --xcframework "${OUTPUT_DIR}/libvlc.xcframework" \\\n',
    '        --work-root "${BUILD_DIR}/validation/0040-headless-vout-teardown-runtime"',
):
    if headless_runtime_region.count(marker) != 1:
        sys.exit(f"0040 bounded runtime gate is incomplete: {marker}")
native_archive_command = build[
    native_archive_contract_setup:archive_metadata_gate
]
if 'if [ "$BUILD_MACOS" = yes ]; then' in native_archive_command:
    sys.exit("device-only builds bypass the all-slice native extension contract")
if "Exact linked native extension validation skipped" in native_archive_command:
    sys.exit("build retains a device-only native extension validation skip")
for marker in (
    '--xcframework "${OUTPUT_DIR}/libvlc.xcframework"',
    '--expected-version "$SWIFTVLC_EXPECTED_EXTENSION_VERSION"',
    'native_archive_contract_args+=(--require-apple-audio-session-leases)',
):
    if native_archive_command.count(marker) != 1:
        sys.exit(f"native extension archive contract is incomplete: {marker}")

release_validator_asset_verification = release.index(
    'if ! python3 "$SCRIPT_DIR/verify-native-validator-assets.py"; then'
)
release_provenance_verification = release.index(
    'if ! verify_artifact_provenance "$EXPECTED_ARTIFACT_SWIFTVLC_REVISION"; then'
)
if release_validator_asset_verification > release_provenance_verification:
    sys.exit("release verifies native validator assets after artifact provenance")

expected_configurations = {
    "build-libvlc.sh",
    "detach-managed-build-directory.py",
    "fix-duplicate-symbols.sh",
    "native-validator-assets.sha256",
    "native-extension-version-probe.c",
    "pip_extension_version.py",
    "validate-libvlc-macho-metadata.py",
    "verify-libvlc-build-paths.py",
    "validate-apple-assembly-metadata-patch.sh",
    "validate-aom-nasm3-detection.sh",
    "validate-headless-vout-teardown.sh",
    "validate-chromecast-load-transition.sh",
    "validate-native-extension-contract.sh",
    "validate-post-pin-stability.sh",
    "verify-native-validator-assets.py",
}
configuration_pattern = re.compile(
    r'--build-configuration-file "([^"=]+)=[^"\n]+"'
)
build_configurations = set(configuration_pattern.findall(build))
release_configurations = set(configuration_pattern.findall(release))
if build_configurations != expected_configurations:
    sys.exit(
        f"build provenance configuration is incomplete: {sorted(build_configurations)}"
    )
if release_configurations != build_configurations:
    sys.exit(
        "build/release provenance configuration sets differ: "
        f"build={sorted(build_configurations)}, release={sorted(release_configurations)}"
    )

for marker in (
    'compare_parser.add_argument("--first-xcframework", type=Path, required=True)',
    'compare_parser.add_argument("--second-xcframework", type=Path, required=True)',
    'verify_recorded_artifact(first, first_xcframework, "first XCFramework")',
    'verify_recorded_artifact(second, second_xcframework, "second XCFramework")',
    'write_json_atomic(arguments.output, proof)',
    'os.replace(temporary_path, path)',
    '"provenanceSha256": first_provenance_sha256',
    '"provenanceSha256": second_provenance_sha256',
):
    if marker not in provenance_tool:
        sys.exit(f"reproducibility implementation is missing: {marker}")

for marker in (
    'libvlc-provenance-a.json',
    '"firstProvenanceChecksum"',
    '--first-provenance "$RELEASE_FIRST_PROVENANCE"',
    '--second-provenance "$RELEASE_PROVENANCE"',
    '--current-provenance "$RELEASE_PROVENANCE"',
    '--xcframework "$WORK_XCFW"',
    '"$RELEASE_FIRST_PROVENANCE"',
):
    if marker not in release:
        sys.exit(f"release does not retain both build records: {marker}")

deployment_constants = {
    "SWIFTVLC_MIN_IOS": "18.0",
    "SWIFTVLC_MIN_TVOS": "18.0",
    "SWIFTVLC_MIN_VISIONOS": "2.0",
    "SWIFTVLC_MIN_MACOS": "15.0",
    "SWIFTVLC_MIN_CATALYST": "18.0",
}
deployment_policies = {
    "ios": "SWIFTVLC_MIN_IOS",
    "tvos": "SWIFTVLC_MIN_TVOS",
    "xros": "SWIFTVLC_MIN_VISIONOS",
    "macos": "SWIFTVLC_MIN_MACOS",
    "catalyst": "SWIFTVLC_MIN_CATALYST",
}
for variable, expected_value in deployment_constants.items():
    assignment = f'{variable}="{expected_value}"'
    if assignment not in build or assignment not in release:
        sys.exit(f"build/release deployment constant drifted: {assignment}")

release_member_manifest = release.index(
    'check-libvlc-manifest.sh" --xcframework "$XCFW_PATH"'
)
release_native_extension_contract = release.index(
    'echo "Verifying exact linked native extension contract..."'
)
release_metadata_report = release.index(
    'MACHO_METADATA_REPORT="$(dirname "$XCFW_PATH")/libvlc-macho-metadata.json"'
)
release_metadata_report_removal = release.index(
    'rm -f "$MACHO_METADATA_REPORT"', release_metadata_report
)
release_metadata_verification = release.index(
    'echo "Verifying release artifact Mach-O platform metadata and section alignment..."'
)
release_provenance = release.index(
    'if ! verify_artifact_provenance "$EXPECTED_ARTIFACT_SWIFTVLC_REVISION"; then'
)
if not (
    release_member_manifest
    < release_native_extension_contract
    < release_metadata_report
    < release_metadata_report_removal
    < release_metadata_verification
    < release_provenance
):
    sys.exit("release Mach-O validation is not ordered before provenance/package work")
release_native_extension_command = release[
    release_native_extension_contract:release_metadata_report
]
for marker in (
    '"$SCRIPT_DIR/validate-native-extension-contract.sh"',
    '--xcframework "$XCFW_PATH"',
    '--expected-version 10',
    '--require-apple-audio-session-leases',
):
    if release_native_extension_command.count(marker) != 1:
        sys.exit(f"release native extension contract is incomplete: {marker}")
if release.count('"$SCRIPT_DIR/validate-libvlc-macho-metadata.py"') != 1:
    sys.exit("release must directly invoke the Mach-O parser exactly once")
build_metadata_command = build[
    build_metadata_verification : build.index(
        'info "Verified every Mach-O object;', build_metadata_verification
    )
]
release_metadata_command = release[
    release_metadata_verification : release.index(
        '# Refuse to publish a debug-configured libVLC',
        release_metadata_verification,
    )
]
if build_metadata_command.count("--deployment-target ") != 5:
    sys.exit("build Mach-O parser invocation does not have exactly five policies")
if release_metadata_command.count("--deployment-target ") != 5:
    sys.exit("release Mach-O parser invocation does not have exactly five policies")
if release_metadata_command.count('--json-output "$MACHO_METADATA_REPORT"') != 1:
    sys.exit("release Mach-O parser does not refresh the invalidated metadata report")
for platform_name, variable in deployment_policies.items():
    marker = f'--deployment-target "{platform_name}=${{{variable}}}"'
    if marker not in build_metadata_command or marker not in release_metadata_command:
        sys.exit(f"build/release Mach-O policy is missing: {marker}")

if "libvlc-provenance.py\" rebind" in release or "find \"$WORK_XCFW\" -name '*.a'" in release:
    sys.exit("release packaging still mutates or rebinds the proven artifact")
if (
    'cp -R "$XCFW_PATH" "$WORK_XCFW"' in release
    or "ditto -c -k --keepParent libvlc.xcframework" in release
):
    sys.exit("release packaging bypasses canonical libVLC staging/archive")
for marker in (
    '"releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1"',
    '"releaseSourceDigest": os.environ["RELEASE_SOURCE_DIGEST"]',
    '"qualificationMatrixChecksum": os.environ["QUALIFICATION_MATRIX_CHECKSUM"]',
    '"featureManifestChecksum": os.environ["FEATURE_MANIFEST_CHECKSUM"]',
    'SWIFTVLC_CANDIDATE_SOURCE_DIGEST="$CANDIDATE_SOURCE_DIGEST"',
    'SWIFTVLC_CANDIDATE_FEATURE_MANIFEST_CHECKSUM="$CANDIDATE_FEATURE_MANIFEST_CHECKSUM"',
    'SWIFTVLC_FEATURE_MANIFEST="$FEATURE_MANIFEST"',
    'check-libvlc-manifest.sh" --xcframework "$XCFW_PATH"',
    'canonical-libvlc-artifact.sh" stage',
    'canonical-libvlc-artifact.sh" archive',
    'elif [[ "$DRY_RUN" == true ]]; then',
):
    if marker not in release:
        sys.exit(f"release candidate is not bound to qualification input: {marker}")

for marker in (
    'if [[ "$DRY_RUN" == false && -z "$CANDIDATE_DIR" ]]; then',
    'verify_github_release() {',
    'verify_required_release_workflows() {',
    'native-source-contracts.yml',
    'sanitize.yml',
    '--commit "$required_commit"',
    '--event "$required_event"',
    'if run.get("conclusion") != "success":',
    'candidate_tag_for_commit() {',
    'canonical_release_commit_matches() {',
    'reconcile_candidate_assets() {',
    "printf 'swiftvlc-candidate-%s-%s\\n'",
    'repos/$REPO/immutable-releases',
    'gh release verify "$TAG"',
    'gh release verify-asset "$TAG"',
    'verify_anonymous_public_artifact',
    'verify_external_swiftpm_consumer',
    'verify_main_governance() {',
    "required_approving_review_count\": 0",
    "required_review_thread_resolution\": True",
    '"repos/$REPO/pulls/$RELEASE_PR_NUMBER/merge"',
    '-f "sha=$STAGED_COMMIT"',
    "-f 'merge_method=merge'",
    'git merge-base --is-ancestor "$STAGED_COMMIT" "$RELEASE_PR_MERGE_COMMIT"',
    '--force-with-lease="refs/tags/$CANDIDATE_TAG:"',
    '--force-with-lease="refs/heads/$RELEASE_BRANCH:"',
    '--force-with-lease="refs/tags/$TAG:"',
    'rollback_reserved_final_tag() {',
    '--force-with-lease="refs/heads/$RELEASE_BRANCH:$STAGED_COMMIT"',
):
    if marker not in release:
        sys.exit(f"two-phase release gate is incomplete: {marker}")
stage_pause = release.index('echo "No final SemVer tag exists.')
workflow_gate = release.index(
    'verify_required_release_workflows', stage_pause
)
publish = release.index(
    'if ! gh release edit "$CANDIDATE_TAG"', workflow_gate
)
if not stage_pause < workflow_gate < publish:
    sys.exit("release publication is not ordered after its explicit CI pause/gate")
publish_command = release[publish : release.index('then', publish)]
for marker in (
    '--tag "$TAG"',
    '--target "$STAGED_COMMIT"',
    '--draft=false',
):
    if publish_command.count(marker) != 1:
        sys.exit(f"atomic release publication is missing {marker}")
if 'git push origin "refs/tags/$TAG' in release:
    sys.exit("release stages the final SemVer tag before atomic publication")
for direct_main_push in (
    ':refs/heads/main',
    'refs/heads/main:$',
    '$STAGED_COMMIT:refs/heads/main',
):
    if direct_main_push in release:
        sys.exit("release retains a direct main push path")
PY

source_repo="$temp_dir/release-source-repo"
mkdir -p "$source_repo/Sources" \
  "$source_repo/scripts/qualification/evidence/1.1.0" \
  "$source_repo/Showcase/SwiftVLCShowcase.xcodeproj"
git -C "$source_repo" init -q
git -C "$source_repo" config user.name "SwiftVLC Test"
git -C "$source_repo" config user.email "swiftvlc-test@example.invalid"
printf 'public let value = 1\n' > "$source_repo/Sources/Value.swift"
printf '{"scenarios":[],"hardware":[]}\n' > \
  "$source_repo/scripts/qualification/matrix.json"
cp "$ROOT_DIR/Package.swift" "$source_repo/Package.swift"
cp "$ROOT_DIR/Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj" \
  "$source_repo/Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj"
git -C "$source_repo" add .
git -C "$source_repo" commit -qm "source"
source_digest_a=$("$SCRIPT_DIR/release-source-digest.py" 1.1.0 --root "$source_repo")

cp "$source_repo/Package.swift" "$temp_dir/source-Package.swift"
cp "$source_repo/Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj" \
  "$temp_dir/source-project.pbxproj"
python3 - "$source_repo/Package.swift" \
  "$source_repo/Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj" <<'PY'
import re
import sys

package_path, project_path = sys.argv[1:]
package = open(package_path).read()
package = re.sub(
    r"v1\.1\.0-beta\.5/libvlc\.xcframework\.zip",
    "v1.1.0/libvlc.xcframework.zip",
    package,
)
package = re.sub(r'checksum: "[0-9a-f]{64}"', 'checksum: "' + "0" * 64 + '"', package)
open(package_path, "w").write(package)
project = open(project_path).read().replace(
    "version = 1.1.0-beta.5;", "version = 1.1.0;"
)
open(project_path, "w").write(project)
PY
source_digest_rewritten=$(
  "$SCRIPT_DIR/release-source-digest.py" 1.1.0 --root "$source_repo"
)
if [[ "$source_digest_a" != "$source_digest_rewritten" ]]; then
  fail "deterministic release reference rewrites changed the source digest"
fi
cp "$temp_dir/source-Package.swift" "$source_repo/Package.swift"
cp "$temp_dir/source-project.pbxproj" \
  "$source_repo/Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj"

printf 'public let untracked = true\n' > "$source_repo/Sources/Untracked.swift"
if "$SCRIPT_DIR/release-source-digest.py" 1.1.0 \
  --root "$source_repo" >/dev/null 2>&1; then
  fail "untracked Swift source did not invalidate the release-source digest"
fi
rm "$source_repo/Sources/Untracked.swift"

printf '{"version":"1.1.0"}\n' > \
  "$source_repo/scripts/qualification/1.1.0.json"
printf '{"result":"pass"}\n' > \
  "$source_repo/scripts/qualification/evidence/1.1.0/result.json"
git -C "$source_repo" add .
git -C "$source_repo" commit -qm "evidence"
source_digest_b=$("$SCRIPT_DIR/release-source-digest.py" 1.1.0 --root "$source_repo")
if [[ "$source_digest_a" != "$source_digest_b" ]]; then
  fail "qualification records changed the release-source digest"
fi

printf 'public let value = 2\n' > "$source_repo/Sources/Value.swift"
source_digest_dirty=$(
  "$SCRIPT_DIR/release-source-digest.py" 1.1.0 --root "$source_repo"
)
if [[ "$source_digest_b" == "$source_digest_dirty" ]]; then
  fail "an uncommitted Swift source change did not change the source digest"
fi
git -C "$source_repo" add Sources/Value.swift
git -C "$source_repo" commit -qm "source change"
source_digest_c=$("$SCRIPT_DIR/release-source-digest.py" 1.1.0 --root "$source_repo")
if [[ "$source_digest_dirty" != "$source_digest_c" ]]; then
  fail "committing unchanged worktree source changed the release-source digest"
fi

printf '{"scenarios":[{"id":"new"}],"hardware":[]}\n' > \
  "$source_repo/scripts/qualification/matrix.json"
git -C "$source_repo" add scripts/qualification/matrix.json
git -C "$source_repo" commit -qm "matrix change"
source_digest_d=$("$SCRIPT_DIR/release-source-digest.py" 1.1.0 --root "$source_repo")
if [[ "$source_digest_c" == "$source_digest_d" ]]; then
  fail "a qualification matrix change did not change the release-source digest"
fi

python3 - "$temp_dir/matrix.json" "$temp_dir/record.json" \
  "$temp_dir/feature-manifest.json" "$digest_a" \
  "$SCRIPT_DIR/qualification" <<'PY'
import json
import sys

(
    matrix_path,
    record_path,
    feature_manifest_path,
    digest,
    qualification_directory,
) = sys.argv[1:6]
sys.path.insert(0, qualification_directory)
import qualification_policy as policy

matrix = {
    "scenarios": [
        {
            "id": "vod",
            "summary": "Fixture VOD playback",
            "hardware": ["iphone-current"],
            "minimumDurationSeconds": 60,
            "requiredEvidenceFields": ["metrics.cpu", "outcome", "retryCount"],
            "expectedEvidenceValues": {
                "metrics.errors": 0,
                "rates": [1, 2],
            },
            "allowedEvidenceValues": {
                "outcome": ["stable", "recovered"],
                "retryCount": [0, 1],
            },
        }
    ],
    "hardware": [
        {
            "id": "iphone-current",
            "deviceFamily": "iPhone",
            "osMajor": 26,
            "summary": "Fixture iPhone",
        },
        {
            "id": "ipad-current",
            "deviceFamily": "iPad",
            "osMajor": 26,
            "summary": "Fixture iPad",
        },
    ],
    "runnerContracts": [
        {
            "id": runner,
            "selection": {
                "kind": "exact",
                "testIdentifiers": [
                    "iOSUITests/FixtureTests/test_releaseIntegrity"
                ],
            },
            "outputs": [],
        }
        for runner in sorted(policy.REQUIRED_RELEASE_RUNNER_SCENARIOS)
    ]
    + [
        {
            "id": "vod",
            "selection": {
                "kind": "exact",
                "testIdentifiers": [
                    "iOSUITests/FixtureTests/test_releaseIntegrity"
                ],
            },
            "outputs": [
                {
                    "scenario": "vod",
                    "attachmentName": "qualification-vod.json",
                    "testIdentifiers": [
                        "iOSUITests/FixtureTests/test_releaseIntegrity"
                    ],
                }
            ],
        }
    ],
}
feature_manifest = {
    "formatVersion": 1,
    "id": "release-integrity-features",
    "manifestVersion": "1.0.0",
    "releaseVersionPrefix": "1.1.0",
    "title": "Release integrity feature policy",
    "categories": [{"id": "playback", "title": "Playback"}],
    "features": [
        {
            "id": feature_id,
            "category": "playback",
            "title": feature_id.replace("-", " ").title(),
            "description": "The release-integrity fixture maps this canonical obligation to its VOD proof.",
            "releaseRequirement": "required",
            "execution": "automated",
            "evidenceLevel": "engine-output",
            "scenarioIds": ["vod"],
            "runnerScenarioIds": ["vod"],
        }
        for feature_id in sorted(policy.REQUIRED_FEATURE_IDS)
    ],
}
json.dump(matrix, open(matrix_path, "w"))
json.dump(feature_manifest, open(feature_manifest_path, "w"))
PY

export SWIFTVLC_FEATURE_MANIFEST="$temp_dir/feature-manifest.json"

qualification_source_digest=$("$SCRIPT_DIR/release-source-digest.py" 1.1.0)
qualification_source_commit=$(git rev-parse HEAD)
qualification_matrix_checksum=$(shasum -a 256 \
  "$temp_dir/matrix.json" | cut -d' ' -f1)
fixture_feature_checksum=$(shasum -a 256 \
  "$temp_dir/feature-manifest.json" | cut -d' ' -f1)
qualification_profiles_checksum=$(shasum -a 256 \
  "$SCRIPT_DIR/qualification/profiles-v1.json" | cut -d' ' -f1)

mkdir -p "$temp_dir/fake-bin"
cat > "$temp_dir/fake-bin/xcrun" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "xcresulttool" ]; then
  if [ "${2:-}" = "export" ] && [ "${3:-}" = "attachments" ]; then
    output=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--output-path" ]; then
        shift
        output="${1:-}"
        break
      fi
      shift
    done
    [ -n "$output" ] || exit 2
    mkdir -p "$output"
    cp -R "$SWIFTVLC_RELEASE_TEST_ATTACHMENT_EXPORT/." "$output/"
    exit 0
  fi
  printf '%s\n' '{"testNodes":[{"nodeType":"Test Case","nodeIdentifier":"iOSUITests/FixtureTests/test_releaseIntegrity","result":"Passed"}]}'
  exit 0
fi
exec /usr/bin/xcrun "$@"
EOF
chmod +x "$temp_dir/fake-bin/xcrun"
export SWIFTVLC_RELEASE_TEST_ATTACHMENT_EXPORT="$temp_dir/retained-report/vod-attachments"
export PATH="$temp_dir/fake-bin:$PATH"

python3 - "$temp_dir/record.json" "$temp_dir/evidence.json" \
  "$qualification_source_commit" "$qualification_source_digest" \
  "$qualification_matrix_checksum" "$digest_a" "$fixture_feature_checksum" \
  "$qualification_profiles_checksum" "$SCRIPT_DIR/qualification" "$temp_dir" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

(
    record_path_value,
    evidence_path_value,
    commit,
    source_digest,
    matrix_checksum,
    artifact_digest,
    feature_checksum,
    profiles_checksum,
    qualification_directory,
    temporary_directory,
) = sys.argv[1:]
sys.path.insert(0, qualification_directory)
import qualification_policy as policy
sys.path.insert(0, str(Path(qualification_directory) / "tests"))
from test_qualification_harness import (
    fixture_candidate_build_attestation_fields,
    report_validation,
    validation_plan,
)

record_path = Path(record_path_value)
evidence_path = Path(evidence_path_value)
root = Path(temporary_directory)
retained_root = root / "retained-report"
retained_root.mkdir()

catalog = ["iOSUITests/FixtureTests/test_releaseIntegrity"]
catalog_record = policy.catalog_record(catalog)
identity = {
    "formatVersion": 2,
    "version": "1.1.0",
    "candidateAppBundleIdentifier": "com.swiftvlc.validation.fixture.app",
    "sourceCommit": commit,
    "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
    "releaseSourceDigest": source_digest,
    "artifactDigestAlgorithm": "swiftvlc-tree-v1",
    "artifactDigest": artifact_digest,
    "candidateAppDigestAlgorithm": "swiftvlc-tree-v1",
    "candidateAppDigest": "a" * 64,
    "testRunnerBundleIdentifier": (
        "com.swiftvlc.validation.fixture.uitests.xctrunner"
    ),
    "testRunnerDigestAlgorithm": "swiftvlc-tree-v1",
    "testRunnerDigest": "b" * 64,
    "testBundleRelativePath": "PlugIns/iOSUITests.xctest",
    "testBundleDigestAlgorithm": "swiftvlc-tree-v1",
    "testBundleDigest": "c" * 64,
    "baseXCTestRunDigestAlgorithm": "sha256",
    "baseXCTestRunDigest": "d" * 64,
    "baseXCTestRunName": "fixture.xctestrun",
    "testCatalogDigestAlgorithm": "swiftvlc-test-catalog-v1",
    "testCatalogDigest": catalog_record["digest"],
    "testCatalogCount": catalog_record["testCount"],
    "testCatalog": catalog_record["testIdentifiers"],
    "qualificationMatrixChecksum": matrix_checksum,
    "featureManifestChecksum": feature_checksum,
    "qualificationProfilesChecksum": profiles_checksum,
    "fixtureManifestChecksum": "f" * 64,
    "qualificationPolicyDigestAlgorithm": "swiftvlc-qualification-policy-v1",
    "qualificationPolicyDigest": policy.policy_digest(),
}
identity.update(
    fixture_candidate_build_attestation_fields(
        source_commit=commit,
        release_source_digest=source_digest,
        artifact_digest=artifact_digest,
        version=identity["version"],
        catalog=catalog,
        candidate_app_digest=identity["candidateAppDigest"],
        test_runner_digest=identity["testRunnerDigest"],
        test_bundle_digest=identity["testBundleDigest"],
        base_xctestrun_digest=identity["baseXCTestRunDigest"],
        base_xctestrun_name=identity["baseXCTestRunName"],
    )
)
execution = {
    "expected": catalog_record,
    "executed": catalog_record,
    "identityAndCountMatch": True,
    "allPassed": True,
}

runner_rows = []
runner_data = {}
for runner in sorted(policy.REQUIRED_RELEASE_RUNNER_SCENARIOS | {"vod"}):
    attempt_root = retained_root / f"{runner}-attempt-artifacts"
    attempt_root.mkdir()
    attempt_log = attempt_root / "attempt-1.log"
    attempt_log.write_text("** TEST EXECUTE SUCCEEDED **\n")
    attempt_bundle = attempt_root / "attempt-1.xcresult"
    attempt_bundle.mkdir()
    (attempt_bundle / "Info.plist").write_text("fixture xcresult")
    attempts = policy.bind_attempt_artifacts(
        [
            {
                "attempt": 1,
                "classification": "passed",
                "retryable": False,
                "intendedTestBegan": True,
                "xcodebuildExitCode": 0,
                "logArtifact": attempt_log.relative_to(retained_root).as_posix(),
                "xcresultArtifact": attempt_bundle.relative_to(
                    retained_root
                ).as_posix(),
                "testExecution": execution,
            }
        ],
        retained_root,
    )
    inventory = None
    app_log = "none"
    if runner != "analyzer":
        raw_root = retained_root / f"{runner}-raw-jsonl"
        raw_root.mkdir()
        raw_record = (
            json.dumps(
                {
                    "ts": "2026-08-31T12:00:00Z",
                    "level": "debug",
                    "module": policy.LOG_MIRROR_HEALTH_MODULE,
                    "message": policy.LOG_MIRROR_HEALTH_MESSAGE,
                }
            )
            + "\n"
        )
        raw_name = policy.test_log_filename(
            "run",
            catalog_record["testIdentifiers"][0],
            "00000000-0000-4000-8000-000000000001",
        )
        (raw_root / raw_name).write_text(raw_record)
        declared_children = policy.DECLARED_TEST_CHILD_LOGS.get(runner)
        if declared_children is not None:
            for child in sorted(declared_children):
                raw_name = policy.test_log_filename(
                    "run",
                    catalog_record["testIdentifiers"][0],
                    "00000000-0000-4000-8000-000000000001",
                    child=child,
                )
                (raw_root / raw_name).write_text(raw_record)
        inventory = policy.build_error_inventory(
            raw_root,
            "run",
            runner,
            retained_root=raw_root.name,
            expected_test_catalog=catalog_record,
        )
        app_log = "captured"
    runner_rows.append(
        {
            "scenario": runner,
            "result": "pass",
            "xcodebuildExitCode": 0,
            "libraryErrorCount": 0,
            "appLog": app_log,
            "qualificationEvidence": (
                "captured" if runner == "vod" else "not-applicable"
            ),
            "durationSeconds": 120,
            "expectedTestCatalog": catalog_record,
            "testExecution": execution,
            "attempts": attempts,
            "attemptArtifactRoot": attempt_root.name,
            "hostErrorInventory": inventory,
        }
    )
    runner_data[runner] = {"attempts": attempts, "inventory": inventory}

attachment_root = retained_root / "vod-attachments"
attachment_root.mkdir()
attachment_payload = attachment_root / "vod.json"
raw_evidence = {
    "scenario": "vod",
    "durationSeconds": 120,
    "metrics": {"cpu": 0, "errors": 0},
    "rates": [1.0, 2],
    "outcome": "stable",
    "retryCount": 0,
}
attachment_payload.write_text(
    json.dumps(
        {
            **raw_evidence,
            "qualificationSessionBinding": "9" * 64,
            "candidateRuntimeBinding": identity["candidateRuntimeBinding"],
        },
        sort_keys=True,
    )
)
attachment_manifest = attachment_root / "manifest.json"
attachment_manifest.write_text(
    json.dumps(
        [
            {
                "testIdentifier": "iOSUITests/FixtureTests/test_releaseIntegrity",
                "attachments": [
                    {
                        "suggestedHumanReadableName": "qualification-vod.json",
                        "exportedFileName": attachment_payload.name,
                    }
                ]
            }
        ],
        sort_keys=True,
    )
)
vod_attempts = runner_data["vod"]["attempts"]
evidence = {
    **raw_evidence,
    **{field: identity[field] for field in policy.CORE_IDENTITY_FIELDS},
    "hardware": "iphone-current",
    "deviceIdentifier": "fixture-device",
    "testExecution": execution,
    "hostErrorInventory": runner_data["vod"]["inventory"],
    "qualificationProducer": {
        "runnerScenario": "vod",
        "sourceAttempt": 1,
        "sourceXcresultArtifact": vod_attempts[-1]["xcresultArtifact"],
        "sourceXcresultDigestAlgorithm": vod_attempts[-1][
            "xcresultDigestAlgorithm"
        ],
        "sourceXcresultDigest": vod_attempts[-1]["xcresultDigest"],
        "sourceXcresultSizeBytes": vod_attempts[-1]["xcresultSizeBytes"],
        "attachmentName": "qualification-vod.json",
        "attachmentTestIdentifier": "iOSUITests/FixtureTests/test_releaseIntegrity",
        "retainedAttachmentRoot": attachment_root.name,
        "manifestRelativePath": attachment_manifest.relative_to(
            retained_root
        ).as_posix(),
        "manifestDigestAlgorithm": "sha256",
        "manifestDigest": policy.sha256_file(attachment_manifest),
        "manifestSizeBytes": attachment_manifest.stat().st_size,
        "attachmentRelativePath": attachment_payload.relative_to(
            retained_root
        ).as_posix(),
        "attachmentDigestAlgorithm": "sha256",
        "attachmentDigest": policy.sha256_file(attachment_payload),
        "attachmentSizeBytes": attachment_payload.stat().st_size,
    },
}
row = {
    "scenario": "vod",
    "runnerScenario": "vod",
    "hardware": "iphone-current",
    "device": "Test phone",
    "deviceFamily": "iPhone",
    "productType": "iPhone16,1",
    "osVersion": "26.6",
    "osBuild": "23G80",
    "osReleaseType": "stable",
    "fixture": f"qualification-fixtures:{identity['fixtureManifestChecksum']}",
    "duration": "120s",
    "durationSeconds": 120,
    "evidence": "evidence.json",
    "result": "pass",
}
(retained_root / "evidence.json").write_text(json.dumps(evidence, sort_keys=True))
selected_device = {
    "id": "fixture-coredevice",
    "udid": "fixture-device",
    "ecid": 42,
    "ecidHex": "0x2A",
    "name": "Test phone",
    "marketingName": "Test phone",
    "productType": "iPhone16,1",
    "deviceFamily": "iPhone",
    "osVersion": "26.6",
    "osMajor": 26,
    "osBuild": "23G80",
    "osReleaseType": "stable",
    "transport": "wired",
    "tunnelIPAddress": "fd00::1",
    "connected": True,
    "qualificationEligible": True,
    "matchingHardwareRows": ["iphone-current"],
}
(retained_root / policy.DEVICE_SNAPSHOT_RELATIVE_PATH).write_text(
    json.dumps(
        {
            "selected": selected_device,
            "connected": [selected_device],
            "allPhysicalIOSDevices": [selected_device],
            "mode": "qualification",
        },
        sort_keys=True,
    )
)
report_path = retained_root / "report.json"
completed_at = datetime.now(timezone.utc).replace(microsecond=0)
started_at = completed_at - timedelta(seconds=120)
session_binding = "9" * 64
report_path.write_text(
    json.dumps(
        {
            **identity,
            "startedAtUTC": started_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "orchestratorSessionBinding": session_binding,
            "orchestratorStartedAtUTC": started_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "completedAtUTC": completed_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "wallDurationSeconds": 120,
            "mode": "qualification",
            "qualificationEligibleEnvironment": True,
            "reportOnly": False,
            "releaseGateSatisfied": False,
            "releaseGateReason": policy.ORDINARY_RELEASE_GATE_REASON,
            "device": selected_device,
            "deviceSnapshot": policy.device_snapshot_binding(retained_root),
            "result": "pass",
            "scenarios": runner_rows,
            "qualificationRows": [row],
        },
        sort_keys=True,
    )
)
candidate_path = retained_root / "candidate-metadata.json"
candidate_path.write_text(json.dumps(identity, sort_keys=True))
runner_scenario_ids = [runner["scenario"] for runner in runner_rows]
plan = validation_plan.build_plan(
    {"mode": "qualification", "selected": selected_device},
    json.loads((root / "matrix.json").read_text()),
    runner_scenario_ids,
    runner_scenario_ids,
    started_at_utc=started_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
    orchestrator_session_binding=session_binding,
    orchestrator_started_at_utc=started_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
    selection_scope="partial",
)
report_validation.atomic_write_json(
    retained_root / report_validation.PLAN_FILENAME,
    plan,
)
report_validation.validate_and_mark(
    retained_root,
    matrix_path=root / "matrix.json",
    candidate_path=candidate_path,
    stable_required=True,
)
source_binding = {
    "path": retained_root.relative_to(root).as_posix(),
    "reportRelativePath": report_path.name,
    "reportDigestAlgorithm": "sha256",
    "reportDigest": policy.sha256_file(report_path),
    "reportSizeBytes": report_path.stat().st_size,
    "treeDigestAlgorithm": "swiftvlc-tree-v1",
    "treeDigest": policy.tree_digest(retained_root),
    "treeSizeBytes": policy.tree_size_bytes(retained_root),
}
evidence_path.write_text(json.dumps(evidence, sort_keys=True))
source_report_relative = (
    Path(source_binding["path"]) / source_binding["reportRelativePath"]
).as_posix()
record_path.write_text(
    json.dumps(
        {
            **identity,
            "sourceReports": [source_binding],
            "runnerScenarios": [
                policy.runner_record_summary(
                    runner_row, "iphone-current", source_report_relative
                )
                for runner_row in runner_rows
            ],
            "rows": [row],
        },
        sort_keys=True,
    )
)
PY

SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null

if SWIFTVLC_CANDIDATE_FEATURE_MANIFEST_CHECKSUM=$(printf '%064d' 0) \
  SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification accepted a feature policy from another prepared candidate"
fi

SWIFTVLC_CANDIDATE_SOURCE_COMMIT="$qualification_source_commit" \
  SWIFTVLC_CANDIDATE_SOURCE_DIGEST="$qualification_source_digest" \
  SWIFTVLC_CANDIDATE_MATRIX_CHECKSUM="$qualification_matrix_checksum" \
  SWIFTVLC_CANDIDATE_FEATURE_MANIFEST_CHECKSUM="$fixture_feature_checksum" \
  SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null

if SWIFTVLC_FEATURE_MANIFEST="$temp_dir/missing-feature-manifest.json" \
  SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification accepted a missing feature policy"
fi

python3 - "$temp_dir/feature-manifest.json" \
  "$temp_dir/blocked-feature-manifest.json" \
  "$temp_dir/advisory-feature-manifest.json" <<'PY'
import json
import sys

source, blocked_output, advisory_output = sys.argv[1:]
manifest = json.load(open(source))
receiver = {
    "id": "receiver-output",
    "category": "playback",
    "title": "Receiver output",
    "description": "Fixture receiver output must be proven.",
    "releaseRequirement": "required",
    "execution": "external-lab",
    "evidenceLevel": "receiver-output",
    "blocker": "No fixture receiver evidence exists.",
}
manifest["features"].append(receiver)
json.dump(manifest, open(blocked_output, "w"))
receiver["releaseRequirement"] = "advisory"
json.dump(manifest, open(advisory_output, "w"))
PY
if SWIFTVLC_FEATURE_MANIFEST="$temp_dir/blocked-feature-manifest.json" \
  SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification accepted an incomplete required feature policy"
fi

if SWIFTVLC_FEATURE_MANIFEST="$temp_dir/advisory-feature-manifest.json" \
  SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification accepted advisory feature policy drift"
fi

python3 - "$temp_dir/feature-manifest.json" \
  "$temp_dir/unclassified-feature-manifest.json" <<'PY'
import json
import sys

source, output = sys.argv[1:]
manifest = json.load(open(source))
manifest["features"][0]["scenarioIds"] = []
manifest["features"][0]["execution"] = "planned"
manifest["features"][0]["blocker"] = "Fixture scenario was removed from policy."
manifest["features"][0]["runnerScenarioIds"] = []
json.dump(manifest, open(output, "w"))
PY
if SWIFTVLC_FEATURE_MANIFEST="$temp_dir/unclassified-feature-manifest.json" \
  SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification accepted a feature policy that omitted a matrix scenario"
fi

# The scenario is scoped to iPhone, so the unrecorded iPad row must not be
# invented by the checker. The successful call above is the regression test.

python3 - "$temp_dir/record.json" <<'PY'
import json
import sys

path = sys.argv[1]
record = json.load(open(path))
record["releaseSourceDigest"] = "0" * 64
json.dump(record, open(path, "w"))
PY
if SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification survived a Swift wrapper source change"
fi

python3 - "$temp_dir/record.json" "$qualification_source_digest" <<'PY'
import json
import sys

path, source_digest = sys.argv[1:]
record = json.load(open(path))
record["releaseSourceDigest"] = source_digest
json.dump(record, open(path, "w"))
PY
python3 - "$temp_dir/evidence.json" <<'PY'
import json
import sys

path = sys.argv[1]
evidence = json.load(open(path))
evidence["releaseSourceDigest"] = "0" * 64
json.dump(evidence, open(path, "w"))
PY
if SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification accepted evidence from another Swift wrapper source"
fi

python3 - "$temp_dir/evidence.json" "$qualification_source_digest" <<'PY'
import json
import sys

path, source_digest = sys.argv[1:]
evidence = json.load(open(path))
evidence["releaseSourceDigest"] = source_digest
json.dump(evidence, open(path, "w"))
PY
cp "$temp_dir/matrix.json" "$temp_dir/matrix-original.json"
python3 - "$temp_dir/matrix.json" <<'PY'
import json
import sys

path = sys.argv[1]
matrix = json.load(open(path))
matrix["changedAfterQualification"] = True
json.dump(matrix, open(path, "w"))
PY
if SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification survived a matrix change"
fi
cp "$temp_dir/matrix-original.json" "$temp_dir/matrix.json"

if SWIFTVLC_CANDIDATE_SOURCE_COMMIT=0000000000000000000000000000000000000000 \
  SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification accepted a record from another candidate commit"
fi

python3 - "$temp_dir/record.json" <<'PY'
import json
import sys

path = sys.argv[1]
record = json.load(open(path))
record["rows"][0]["durationSeconds"] = 30
json.dump(record, open(path, "w"))
PY
if SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification accepted a run shorter than the scenario minimum"
fi

for non_finite in nan infinity; do
  python3 - "$temp_dir/record.json" "$non_finite" <<'PY'
import json
import sys

path, kind = sys.argv[1:3]
record = json.load(open(path))
record["rows"][0]["durationSeconds"] = (
    float("nan") if kind == "nan" else float("inf")
)
json.dump(record, open(path, "w"))
PY
  if SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
    SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
    "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
    fail "qualification accepted a non-finite duration: $non_finite"
  fi
done

python3 - "$temp_dir/record.json" "$temp_dir/evidence.json" <<'PY'
import json
import sys

record_path, evidence_path = sys.argv[1:3]
record = json.load(open(record_path))
record["rows"][0]["durationSeconds"] = 120
json.dump(record, open(record_path, "w"))
evidence = json.load(open(evidence_path))
evidence["metrics"].pop("cpu")
json.dump(evidence, open(evidence_path, "w"))
PY
if SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification accepted evidence missing a required metric"
fi

python3 - "$temp_dir/evidence.json" <<'PY'
import json
import sys

path = sys.argv[1]
evidence = json.load(open(path))
evidence["metrics"]["cpu"] = 0
json.dump(evidence, open(path, "w"))
PY

SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null

python3 - "$temp_dir/evidence.json" <<'PY'
import json
import sys

path = sys.argv[1]
evidence = json.load(open(path))
evidence["metrics"]["errors"] = 1
json.dump(evidence, open(path, "w"))
PY
if SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification accepted evidence with a wrong expected value"
fi

python3 - "$temp_dir/evidence.json" <<'PY'
import json
import sys

path = sys.argv[1]
evidence = json.load(open(path))
evidence["metrics"]["errors"] = False
json.dump(evidence, open(path, "w"))
PY
if SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification treated a boolean as an expected number"
fi

python3 - "$temp_dir/evidence.json" <<'PY'
import json
import sys

path = sys.argv[1]
evidence = json.load(open(path))
evidence["metrics"]["errors"] = 0
evidence["rates"] = [True, 2]
json.dump(evidence, open(path, "w"))
PY
if SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification treated a boolean as a number inside an expected array"
fi

python3 - "$temp_dir/evidence.json" <<'PY'
import json
import sys

path = sys.argv[1]
evidence = json.load(open(path))
evidence["rates"] = [1.0, 2]
evidence["retryCount"] = False
json.dump(evidence, open(path, "w"))
PY
if SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification treated a boolean as an allowed number"
fi

python3 - "$temp_dir/evidence.json" <<'PY'
import json
import sys

path = sys.argv[1]
evidence = json.load(open(path))
evidence["retryCount"] = 0
evidence["outcome"] = "failed"
json.dump(evidence, open(path, "w"))
PY
if SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification accepted evidence outside the allowed values"
fi

python3 - "$temp_dir/evidence.json" <<'PY'
import json
import sys

path = sys.argv[1]
evidence = json.load(open(path))
evidence["outcome"] = "stable"
json.dump(evidence, open(path, "w"))
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

python3 - "$ROOT_DIR/scripts/qualification/matrix.json" <<'PY'
import json
import sys

matrix = json.load(open(sys.argv[1]))
for scenario in matrix["scenarios"]:
    if 88 not in scenario.get("issues", []):
        continue
    expected = scenario.get("expectedEvidenceValues", {})
    if not any(field.startswith("events.") for field in expected):
        raise SystemExit(
            f"issue 88 scenario {scenario['id']} does not enforce lifecycle outcomes"
        )
    if "controls" in scenario.get("requiredEvidenceFields", []):
        allowed = scenario.get("allowedEvidenceValues", {})
        if not any(
            field == "controls" or field.startswith("controls.")
            for field in expected.keys() | allowed.keys()
        ):
            raise SystemExit(
                f"issue 88 scenario {scenario['id']} does not enforce control outcomes"
            )
PY

# Exercise the production release shell in an isolated repository with local
# command doubles. Static source markers cannot prove candidate field ordering,
# private snapshot use, or the exact bytes handed to `gh release create`.
release_flow_root="$temp_dir/release-flow"
release_flow_repo="$release_flow_root/repository"
release_flow_origin="$release_flow_root/origin.git"
release_flow_candidate="$release_flow_root/candidate"
release_flow_expected="$release_flow_root/expected-upload"
release_flow_capture="$release_flow_root/captured-upload"
release_flow_fake_bin="$release_flow_root/fake-bin"
release_flow_tmp="$release_flow_root/tmp"
mkdir -p \
  "$release_flow_repo/scripts/patches/validation" \
  "$release_flow_repo/scripts/qualification" \
  "$release_flow_repo/Showcase/SwiftVLCShowcase.xcodeproj" \
  "$release_flow_repo/Vendor" \
  "$release_flow_expected" \
  "$release_flow_capture" \
  "$release_flow_fake_bin" \
  "$release_flow_tmp"

cp "$SCRIPT_DIR/release.sh" "$release_flow_repo/scripts/release.sh"
cp "$SCRIPT_DIR/artifact-tree-digest.py" \
  "$release_flow_repo/scripts/artifact-tree-digest.py"
cp "$SCRIPT_DIR/release-artifact-info.py" \
  "$release_flow_repo/scripts/release-artifact-info.py"
cp "$ROOT_DIR/Package.swift" "$release_flow_repo/Package.swift"
cp "$ROOT_DIR/Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj" \
  "$release_flow_repo/Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj"
printf 'Vendor/\n' > "$release_flow_repo/.gitignore"
printf '{"fixture":true}\n' > \
  "$release_flow_repo/scripts/qualification/matrix.json"
printf '{"fixture":true}\n' > \
  "$release_flow_repo/scripts/qualification/feature-manifest-v1.json"
printf '%064d  0001-fixture.patch\n' 0 > \
  "$release_flow_repo/scripts/patches/manifest.sha256"
printf 'fixture native probe\n' > \
  "$release_flow_repo/scripts/patches/validation/native-extension-version-probe.c"
printf 'fixture extension parser\n' > \
  "$release_flow_repo/scripts/patches/validation/pip_extension_version.py"

cat > "$release_flow_repo/scripts/release-version-policy.py" <<'PY'
#!/usr/bin/env python3
import sys

if len(sys.argv) != 4 or sys.argv[2:] != ["--field", "kind"]:
    raise SystemExit(2)
print("stable")
PY
cat > "$release_flow_repo/scripts/verify-native-validator-assets.py" <<'PY'
#!/usr/bin/env python3
raise SystemExit(0)
PY
cat > "$release_flow_repo/scripts/validate-libvlc-macho-metadata.py" <<'PY'
#!/usr/bin/env python3
import json
import sys
from pathlib import Path

arguments = sys.argv[1:]
output = Path(arguments[arguments.index("--json-output") + 1])
output.write_text(json.dumps({"fixture": True}) + "\n")
PY
cat > "$release_flow_repo/scripts/libvlc-provenance.py" <<'PY'
#!/usr/bin/env python3
import os
import sys
from pathlib import Path

arguments = sys.argv[1:]
command = arguments[0]


def value(flag):
    return Path(arguments[arguments.index(flag) + 1]).resolve()


def require_private_snapshot(paths):
    parents = {path.parent for path in paths}
    if len(parents) != 1 or next(iter(parents)).name != "release-assets":
        raise SystemExit(
            "Error: release provenance verification bypassed its private snapshot"
        )
    if any(not path.exists() for path in paths):
        raise SystemExit("Error: snapshotted release input is missing")


if command == "verify":
    require_private_snapshot([value("--provenance"), value("--xcframework")])
    expected_revision = os.environ["SWIFTVLC_RELEASE_TEST_EXPECTED_REVISION"]
    actual_revision = arguments[arguments.index("--swiftvlc-revision") + 1]
    if actual_revision != expected_revision:
        raise SystemExit(
            "Error: release verified provenance against the wrong SwiftVLC "
            f"revision: {actual_revision} != {expected_revision}"
        )
elif command == "verify-proof":
    require_private_snapshot(
        [
            value("--proof"),
            value("--first-provenance"),
            value("--second-provenance"),
            value("--current-provenance"),
            value("--xcframework"),
        ]
    )
else:
    raise SystemExit(f"Error: unexpected provenance command: {command}")
PY
cat > "$release_flow_repo/scripts/release-source-digest.py" <<'PY'
#!/usr/bin/env python3
print("a" * 64)
PY

cat > "$release_flow_repo/scripts/canonical-libvlc-artifact.sh" <<'SH'
#!/bin/sh
set -eu

command_name=$1
source_path=$2
output_path=$3
case "$command_name" in
  stage)
    [ ! -e "$output_path" ]
    mkdir -p "$(dirname "$output_path")"
    cp -R "$source_path" "$output_path"
    ;;
  archive)
    [ ! -e "$output_path" ]
    source_parent=$(cd "$(dirname "$source_path")" && pwd)
    source_name=$(basename "$source_path")
    output_parent=$(dirname "$output_path")
    mkdir -p "$output_parent"
    output_path=$(cd "$output_parent" && pwd)/$(basename "$output_path")
    (
      cd "$source_parent"
      COPYFILE_DISABLE=1 LC_ALL=C TZ=UTC \
        /usr/bin/zip -q -r -X -y "$output_path" "$source_name"
    )
    ;;
  *)
    exit 2
    ;;
esac
SH

cat > "$release_flow_repo/scripts/check-libvlc-manifest.sh" <<'SH'
#!/bin/sh
set -eu

if [ -n "${SWIFTVLC_RELEASE_TEST_MUTATE_VENDOR:-}" ]; then
  for name in \
    libvlc-provenance-a.json \
    libvlc-provenance.json \
    libvlc-reproducibility.json; do
    printf 'mutated after private snapshot\n' >> \
      "$SWIFTVLC_RELEASE_TEST_MUTATE_VENDOR/$name"
  done
  printf 'mutated after private snapshot\n' > \
    "$SWIFTVLC_RELEASE_TEST_MUTATE_VENDOR/libvlc.xcframework/ios-arm64/libvlc.a"
fi
SH

cat > "$release_flow_repo/scripts/check-qualification.sh" <<'SH'
#!/bin/sh
set -eu

case "$2" in
  */swiftvlc-release.*/release-assets/libvlc.xcframework) ;;
  *)
    echo "qualification did not receive the private XCFramework snapshot: $2" >&2
    exit 1
    ;;
esac
if [ -n "${SWIFTVLC_RELEASE_TEST_MUTATE_CANDIDATE:-}" ]; then
  for name in \
    libvlc.xcframework.zip \
    libvlc-provenance-a.json \
    libvlc-provenance.json \
    libvlc-reproducibility.json \
    release-candidate.json; do
    printf 'mutated after private snapshot\n' >> \
      "$SWIFTVLC_RELEASE_TEST_MUTATE_CANDIDATE/$name"
  done
fi
SH

for release_flow_stub in \
  fix-duplicate-symbols.sh \
  validate-native-extension-contract.sh \
  validate-apple-assembly-metadata-patch.sh \
  validate-aom-nasm3-detection.sh \
  validate-headless-vout-teardown.sh \
  validate-chromecast-load-transition.sh \
  validate-post-pin-stability.sh \
  verify-patch-manifest.sh; do
  printf '#!/bin/sh\nexit 0\n' > \
    "$release_flow_repo/scripts/$release_flow_stub"
done
printf '#!/bin/sh\nVLC_HASH="111111111"\n' > \
  "$release_flow_repo/scripts/build-libvlc.sh"

cat > "$release_flow_fake_bin/swift" <<'SH'
#!/bin/sh
set -eu

if [ "$#" -eq 3 ] && [ "$1" = package ] && \
    [ "$2" = compute-checksum ]; then
  shasum -a 256 "$3" | cut -d' ' -f1
  exit 0
fi
if [ "${1:-}" = build ]; then
  package_path=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --package-path ]; then
      package_path=$2
      break
    fi
    shift
  done
  [ -n "$package_path" ]
  grep -Fq '.package(url: "https://github.com/harflabs/SwiftVLC.git", exact: "1.1.0")' \
    "$package_path/Package.swift"
  grep -Fq 'import SwiftVLC' "$package_path/Sources/SwiftVLCSmoke/main.swift"
  exit 0
fi
exit 2
SH
cat > "$release_flow_fake_bin/curl" <<'SH'
#!/bin/sh
set -eu

output=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then
    output=$2
    shift 2
  else
    shift
  fi
done
[ -n "$output" ]
cp "$SWIFTVLC_RELEASE_TEST_CAPTURE/uploaded/libvlc.xcframework.zip" "$output"
SH
cat > "$release_flow_fake_bin/git" <<'SH'
#!/bin/sh
set -eu

if [ "${1:-}" = push ]; then
  printf '%s\n' "$*" >> "$SWIFTVLC_RELEASE_TEST_GIT_LOG"
  if [ "${SWIFTVLC_RELEASE_TEST_CLEANUP_RACE:-}" = branch ]; then
    case "$*" in
      *:refs/heads/release-candidates/v1.1.0*)
        /usr/bin/git --git-dir="$SWIFTVLC_RELEASE_TEST_ORIGIN" update-ref \
          refs/heads/release-candidates/v1.1.0 \
          "$SWIFTVLC_RELEASE_TEST_RACE_COMMIT"
        ;;
    esac
  elif [ "${SWIFTVLC_RELEASE_TEST_CLEANUP_RACE:-}" = tag ]; then
    case "$*" in
      *:refs/tags/swiftvlc-candidate-v1.1.0-*)
        candidate_ref=$(printf '%s\n' "$*" | sed -n \
          's/.*:\(refs\/tags\/swiftvlc-candidate-v1\.1\.0-[0-9a-f]*\).*/\1/p')
        [ -n "$candidate_ref" ]
        /usr/bin/git --git-dir="$SWIFTVLC_RELEASE_TEST_ORIGIN" update-ref \
          "$candidate_ref" "$SWIFTVLC_RELEASE_TEST_RACE_COMMIT"
        ;;
    esac
  fi
fi
exec /usr/bin/git "$@"
SH
cat > "$release_flow_fake_bin/gh" <<'SH'
#!/bin/sh
set -eu

if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 0
fi
if [ "${1:-}" = release ] && [ "${3:-}" = --help ]; then
  case "${2:-}" in
    edit|verify|verify-asset) exit 0 ;;
  esac
fi

state_file=$SWIFTVLC_RELEASE_TEST_GH_STATE
capture=$SWIFTVLC_RELEASE_TEST_CAPTURE
origin=$SWIFTVLC_RELEASE_TEST_ORIGIN
pr_state="$capture/pr.state"
pr_base="$capture/pr.base"
pr_head="$capture/pr.head"
pr_merge="$capture/pr.merge"

current_tag() {
  [ -f "$state_file" ] || return 1
  state=$(cat "$state_file")
  if [ "$state" = draft ]; then
    cat "$capture/release.tag"
  else
    printf 'v1.1.0\n'
  fi
}

perform_merge() {
  expected=$1
  [ "$(cat "$pr_state")" = open ]
  head=$(cat "$pr_head")
  base=$(cat "$pr_base")
  [ "$expected" = "$head" ]
  [ "${SWIFTVLC_RELEASE_TEST_MERGE_MODE:-}" != fail-before ] || return 42
  tree=$(/usr/bin/git --git-dir="$origin" rev-parse "${head}^{tree}")
  merge_commit=$(printf 'Merge release PR #17\n' | \
    GIT_AUTHOR_NAME='SwiftVLC Release Test' \
    GIT_AUTHOR_EMAIL='swiftvlc-release-test@example.invalid' \
    GIT_COMMITTER_NAME='SwiftVLC Release Test' \
    GIT_COMMITTER_EMAIL='swiftvlc-release-test@example.invalid' \
    /usr/bin/git --git-dir="$origin" commit-tree "$tree" -p "$base" -p "$head")
  /usr/bin/git --git-dir="$origin" update-ref refs/heads/main "$merge_commit" "$base"
  printf '%s\n' "$merge_commit" > "$pr_merge"
  printf 'merged\n' > "$pr_state"
  [ "${SWIFTVLC_RELEASE_TEST_MERGE_MODE:-}" != fail-after ] || return 42
  printf '{"sha":"%s","merged":true,"message":"Pull Request successfully merged"}\n' \
    "$merge_commit"
}

if [ "${1:-}" = api ]; then
  case " $* " in
    *" repos/harflabs/SwiftVLC "*)
      if [ "${SWIFTVLC_RELEASE_TEST_RULESET_DRIFT:-}" = repository-merge ]; then
        allow_merge=false
      else
        allow_merge=true
      fi
      printf '{"full_name":"harflabs/SwiftVLC","default_branch":"main","archived":false,"disabled":false,"allow_merge_commit":%s}\n' \
        "$allow_merge"
      exit 0
      ;;
    *" repos/harflabs/SwiftVLC/pulls/17/merge "*)
      expected=""
      merge_method=""
      method=""
      previous=""
      for argument in "$@"; do
        case "$argument" in
          sha=*) expected=${argument#sha=} ;;
          merge_method=*) merge_method=${argument#merge_method=} ;;
        esac
        if [ "$previous" = --method ]; then
          method=$argument
        fi
        previous=$argument
      done
      [ "$method" = PUT ] && [ "$merge_method" = merge ]
      perform_merge "$expected"
      exit $?
      ;;
    *" repos/harflabs/SwiftVLC/rulesets?includes_parents=true&per_page=100 "*)
      printf '%s\n' '[{"id":15683730,"name":"Protect main","target":"branch","source_type":"Repository","source":"harflabs/SwiftVLC","enforcement":"active"}]'
      exit 0
      ;;
    *" repos/harflabs/SwiftVLC/rulesets/15683730 "*)
      python3 - "${SWIFTVLC_RELEASE_TEST_RULESET_DRIFT:-}" <<'PY'
import json
import sys

drift = sys.argv[1]
policy = {
    "id": 15683730,
    "name": "Protect main",
    "target": "branch",
    "source_type": "Repository",
    "source": "harflabs/SwiftVLC",
    "enforcement": "active",
    "bypass_actors": [],
    "conditions": {
        "ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}
    },
    "rules": [
        {"type": "deletion"},
        {"type": "non_fast_forward"},
        {
            "type": "pull_request",
            "parameters": {
                "required_approving_review_count": 0,
                "dismiss_stale_reviews_on_push": False,
                "require_code_owner_review": False,
                "require_last_push_approval": False,
                "required_review_thread_resolution": True,
                "allowed_merge_methods": ["merge"],
            },
        },
        {
            "type": "required_status_checks",
            "parameters": {
                "strict_required_status_checks_policy": True,
                "do_not_enforce_on_create": False,
                "required_status_checks": [
                    {"context": name, "integration_id": 15368}
                    for name in ("lint", "ios-build", "test")
                ],
            },
        },
    ],
}
rules = {rule["type"]: rule for rule in policy["rules"]}
if drift == "disabled":
    policy["enforcement"] = "disabled"
elif drift == "bypass":
    policy["bypass_actors"] = [
        {"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}
    ]
elif drift == "approvals":
    rules["pull_request"]["parameters"]["required_approving_review_count"] = 1
elif drift == "conversations":
    rules["pull_request"]["parameters"]["required_review_thread_resolution"] = False
elif drift == "merge-method":
    rules["pull_request"]["parameters"]["allowed_merge_methods"] = ["squash"]
elif drift == "deletion":
    policy["rules"] = [rule for rule in policy["rules"] if rule["type"] != "deletion"]
elif drift == "force-push":
    policy["rules"] = [
        rule for rule in policy["rules"] if rule["type"] != "non_fast_forward"
    ]
elif drift == "checks":
    rules["required_status_checks"]["parameters"]["required_status_checks"] = [
        {"context": "lint", "integration_id": 15368}
    ]
elif drift == "integration":
    rules["required_status_checks"]["parameters"]["required_status_checks"][0][
        "integration_id"
    ] = None
elif drift:
    raise SystemExit(f"unknown ruleset drift fixture: {drift}")
print(json.dumps(policy))
PY
      exit 0
      ;;
    *" repos/harflabs/SwiftVLC/immutable-releases "*)
      [ "${SWIFTVLC_RELEASE_TEST_IMMUTABLE_DISABLED:-}" != 1 ] || exit 1
      printf 'true\n'
      exit 0
      ;;
    *" --method DELETE https://api.github.com/repos/harflabs/SwiftVLC/releases/assets/"*)
      asset_url=${!#}
      asset_name=${asset_url##*/}
      rm -f "$capture/starters/$asset_name"
      exit 0
      ;;
  esac
fi

if [ "${1:-}" = release ] && [ "${2:-}" = view ]; then
  requested_tag=$3
  actual_tag=$(current_tag) || exit 1
  [ "$requested_tag" = "$actual_tag" ] || exit 1
  case " $* " in
    *" --json "*)
      python3 - \
        "$state_file" \
        "$capture" \
        "$actual_tag" \
        "${SWIFTVLC_RELEASE_TEST_ASSET_DRIFT:-}" \
        "${SWIFTVLC_RELEASE_TEST_IMMUTABLE_DRIFT:-}" \
        "${SWIFTVLC_RELEASE_TEST_METADATA_DRIFT:-}" <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path

state_path, capture_path, tag, drift, immutable_drift, metadata_drift = sys.argv[1:]
state = Path(state_path).read_text().strip()
capture = Path(capture_path)
release_locator = (
    "untagged-0123456789abcdef" if state == "draft" else tag
)
asset_locator = (
    "untagged-fedcba9876543210"
    if os.environ.get("SWIFTVLC_RELEASE_TEST_ASSET_URL_DRIFT") == "1"
    else release_locator
)
assets = []
for path in sorted((capture / "uploaded").iterdir()):
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if drift and path.name == "libvlc.xcframework.zip":
        digest = "0" * 64
    assets.append(
        {
            "name": path.name,
            "digest": f"sha256:{digest}",
            "url": (
                "https://github.com/harflabs/SwiftVLC/releases/download/"
                f"{asset_locator}/{path.name}"
            ),
            "apiUrl": (
                "https://api.github.com/repos/harflabs/SwiftVLC/"
                f"releases/assets/{path.name}"
            ),
            "state": "uploaded",
            "size": path.stat().st_size,
        }
    )
for path in sorted((capture / "starters").iterdir()):
    assets.append(
        {
            "name": path.name,
            "digest": None,
            "url": (
                "https://github.com/harflabs/SwiftVLC/releases/download/"
                f"{asset_locator}/{path.name}"
            ),
            "apiUrl": (
                "https://api.github.com/repos/harflabs/SwiftVLC/"
                f"releases/assets/{path.name}"
            ),
            "state": "starter",
            "size": 0,
        }
    )
print(
    json.dumps(
        {
            "url": (
                "https://github.com/harflabs/SwiftVLC/releases/"
                f"tag/{release_locator}"
            ),
            "tagName": tag,
            "targetCommitish": (capture / "release.commit").read_text().strip(),
            "isDraft": state == "draft",
            "isImmutable": state == "published" and not immutable_drift,
            "isPrerelease": False,
            "name": (
                "drifted title"
                if metadata_drift == "title"
                else (capture / "release.title").read_text()
            ),
            "body": (
                "drifted notes"
                if metadata_drift == "body"
                else (capture / "release.notes").read_text()
            ),
            "assets": assets,
        }
    )
)
PY
      ;;
  esac
  exit 0
fi

if [ "${1:-}" = release ] && [ "${2:-}" = create ]; then
  tag=$3
  shift 3
  commit=""
  title=""
  notes=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --target) commit=$2; shift 2 ;;
      --title) title=$2; shift 2 ;;
      --notes) notes=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$commit" ] && [ -n "$title" ] && [ -n "$notes" ]
  mkdir -p "$capture/uploaded" "$capture/starters"
  : > "$capture/assets.paths"
  printf '%s\n' "$tag" > "$capture/release.tag"
  printf '%s\n' "$commit" > "$capture/release.commit"
  printf '%s' "$title" > "$capture/release.title"
  printf '%s' "$notes" > "$capture/release.notes"
  printf 'draft\n' > "$state_file"
  exit 0
fi

if [ "${1:-}" = release ] && [ "${2:-}" = upload ]; then
  tag=$3
  source_path=$4
  [ "$tag" = "$(current_tag)" ]
  asset_name=$(basename "$source_path")
  if [ "${SWIFTVLC_RELEASE_TEST_FAIL_UPLOAD_NAME:-}" = "$asset_name" ] && \
      [ ! -e "$capture/upload-failed-$asset_name" ]; then
    : > "$capture/upload-failed-$asset_name"
    : > "$capture/starters/$asset_name"
    exit 42
  fi
  [ ! -e "$capture/uploaded/$asset_name" ] || exit 3
  cp "$source_path" "$capture/uploaded/$asset_name"
  printf '%s\n' "$source_path" >> "$capture/assets.paths"
  exit 0
fi

if [ "${1:-}" = release ] && [ "${2:-}" = edit ]; then
  candidate_tag=$3
  [ "$candidate_tag" = "$(current_tag)" ]
  [ "${SWIFTVLC_RELEASE_TEST_EDIT_MODE:-}" != fail-before ] || exit 42
  shift 3
  commit=""
  tag=""
  title=""
  notes=""
  draft=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --target) commit=$2; shift 2 ;;
      --tag) tag=$2; shift 2 ;;
      --title) title=$2; shift 2 ;;
      --notes) notes=$2; shift 2 ;;
      --draft=false) draft=false; shift ;;
      *) shift ;;
    esac
  done
  [ "$tag" = v1.1.0 ] && [ "$draft" = false ]
  [ "$commit" = "$(cat "$capture/release.commit")" ]
  [ -n "$title" ] && [ -n "$notes" ]
  /usr/bin/git --git-dir="$origin" update-ref refs/tags/v1.1.0 "$commit"
  printf '%s' "$title" > "$capture/release.title"
  printf '%s' "$notes" > "$capture/release.notes"
  printf 'published\n' > "$state_file"
  if [ "${SWIFTVLC_RELEASE_TEST_EDIT_MODE:-}" = fail-after ]; then
    exit 42
  fi
  exit 0
fi

if [ "${1:-}" = pr ] && [ "${2:-}" = create ]; then
  [ ! -e "$pr_state" ]
  /usr/bin/git --git-dir="$origin" rev-parse refs/heads/main > "$pr_base"
  /usr/bin/git --git-dir="$origin" \
    rev-parse refs/heads/release-candidates/v1.1.0 > "$pr_head"
  printf 'open\n' > "$pr_state"
  printf 'https://github.com/harflabs/SwiftVLC/pull/17\n'
  exit 0
fi

if [ "${1:-}" = pr ] && [ "${2:-}" = list ]; then
  if [ ! -e "$pr_state" ]; then
    case " $* " in
      *" --jq length "*) printf '0\n' ;;
      *) printf '[]\n' ;;
    esac
    exit 0
  fi
  case " $* " in
    *" --jq length "*)
      printf '1\n'
      ;;
    *)
      python3 - "$pr_state" "$pr_base" "$pr_head" "$pr_merge" <<'PY'
import json
import sys
from pathlib import Path

state_path, base_path, head_path, merge_path = map(Path, sys.argv[1:])
state = state_path.read_text().strip()
merge = merge_path.read_text().strip() if merge_path.exists() else ""
print(
    json.dumps(
        [
            {
                "number": 17,
                "state": state.upper(),
                "isDraft": False,
                "isCrossRepository": False,
                "headRefName": "release-candidates/v1.1.0",
                "headRefOid": head_path.read_text().strip(),
                "baseRefName": "main",
                "baseRefOid": base_path.read_text().strip(),
                "mergedAt": "2026-09-02T00:00:00Z" if state == "merged" else None,
                "mergeCommit": {"oid": merge} if merge else None,
                "url": "https://github.com/harflabs/SwiftVLC/pull/17",
            }
        ]
    )
)
PY
      ;;
  esac
  exit 0
fi

if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
  [ -e "$pr_state" ]
  python3 - \
    "$pr_state" "$pr_base" "$pr_head" \
    "${SWIFTVLC_RELEASE_TEST_PR_CHECK_STATE:-success}" <<'PY'
import json
import sys
from pathlib import Path

state_path, base_path, head_path, check_state = sys.argv[1:]
names = ("lint", "ios-build", "test", "dynamic-host", "check", "replay")
checks = [
    {"name": name, "status": "COMPLETED", "conclusion": "SUCCESS"}
    for name in names
]
if check_state == "missing":
    checks.pop()
elif check_state == "pending":
    checks[0].update(status="IN_PROGRESS", conclusion=None)
elif check_state == "failed":
    checks[0]["conclusion"] = "FAILURE"
elif check_state == "skipped-required":
    checks[0]["conclusion"] = "SKIPPED"
elif check_state == "duplicate":
    checks.append(dict(checks[0]))
elif check_state != "success":
    raise SystemExit(f"unknown PR check state: {check_state}")
print(
    json.dumps(
        {
            "number": 17,
            "state": Path(state_path).read_text().strip().upper(),
            "isDraft": False,
            "isCrossRepository": False,
            "headRefName": "release-candidates/v1.1.0",
            "headRefOid": Path(head_path).read_text().strip(),
            "baseRefName": "main",
            "baseRefOid": Path(base_path).read_text().strip(),
            "mergeable": "MERGEABLE",
            "mergeStateStatus": "CLEAN",
            "statusCheckRollup": checks,
        }
    )
)
PY
  exit 0
fi

if [ "${1:-}" = pr ] && [ "${2:-}" = merge ]; then
  [ "$(cat "$pr_state")" = open ]
  expected=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --match-head-commit ]; then
      expected=$2
      break
    fi
    shift
  done
  perform_merge "$expected"
  exit $?
fi

if [ "${1:-}" = release ] && [ "$2" = verify ]; then
  [ "$(cat "$state_file")" = published ]
  printf '{"verified":true}\n'
  exit 0
fi

if [ "${1:-}" = release ] && [ "$2" = verify-asset ]; then
  [ "$(cat "$state_file")" = published ]
  asset_path=$4
  cmp -s "$asset_path" "$capture/uploaded/$(basename "$asset_path")"
  printf '{"verified":true}\n'
  exit 0
fi

if [ "${1:-}" = run ] && [ "${2:-}" = list ]; then
  commit=""
  event=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --commit) commit=$2; shift 2 ;;
      --event) event=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  branch="release-candidates/v1.1.0"
  expected_event=pull_request
  run_state=${SWIFTVLC_RELEASE_TEST_RUN_STATE:-success}
  if [ -s "$pr_merge" ] && [ "$commit" = "$(cat "$pr_merge")" ]; then
    branch=main
    expected_event=push
    run_state=${SWIFTVLC_RELEASE_TEST_MAIN_RUN_STATE:-$run_state}
  fi
  [ "$event" = "$expected_event" ] || exit 4
  case "$run_state" in
    missing)
      printf '[]\n'
      ;;
    pending)
      printf '[{"databaseId":1,"attempt":1,"createdAt":"2026-09-02T00:00:01Z","status":"in_progress","conclusion":"","headSha":"%s","headBranch":"%s","event":"%s"}]\n' "$commit" "$branch" "$event"
      ;;
    failed)
      printf '[{"databaseId":1,"attempt":1,"createdAt":"2026-09-02T00:00:01Z","status":"completed","conclusion":"failure","headSha":"%s","headBranch":"%s","event":"%s"}]\n' "$commit" "$branch" "$event"
      ;;
    stale-failure-recovered)
      printf '[{"databaseId":1,"attempt":1,"createdAt":"2026-09-02T00:00:01Z","status":"completed","conclusion":"failure","headSha":"%s","headBranch":"%s","event":"%s"},{"databaseId":2,"attempt":1,"createdAt":"2026-09-02T00:00:02Z","status":"completed","conclusion":"success","headSha":"%s","headBranch":"%s","event":"%s"}]\n' "$commit" "$branch" "$event" "$commit" "$branch" "$event"
      ;;
    stale-success-pending)
      printf '[{"databaseId":1,"attempt":1,"createdAt":"2026-09-02T00:00:01Z","status":"completed","conclusion":"success","headSha":"%s","headBranch":"%s","event":"%s"},{"databaseId":2,"attempt":1,"createdAt":"2026-09-02T00:00:02Z","status":"in_progress","conclusion":"","headSha":"%s","headBranch":"%s","event":"%s"}]\n' "$commit" "$branch" "$event" "$commit" "$branch" "$event"
      ;;
    success)
      printf '[{"databaseId":1,"attempt":1,"createdAt":"2026-09-02T00:00:01Z","status":"completed","conclusion":"success","headSha":"%s","headBranch":"%s","event":"%s"}]\n' "$commit" "$branch" "$event"
      ;;
    *) exit 4 ;;
  esac
  exit 0
fi

echo "unexpected gh invocation: $*" >&2
exit 2
SH
chmod +x \
  "$release_flow_repo/scripts/"*.sh \
  "$release_flow_repo/scripts/"*.py \
  "$release_flow_fake_bin/git" \
  "$release_flow_fake_bin/gh" \
  "$release_flow_fake_bin/curl" \
  "$release_flow_fake_bin/swift"

for slice in \
  ios-arm64 \
  ios-arm64_x86_64-simulator \
  tvos-arm64 \
  tvos-arm64_x86_64-simulator \
  xros-arm64 \
  xros-arm64_x86_64-simulator \
  macos-arm64_x86_64 \
  ios-arm64_x86_64-maccatalyst; do
  mkdir -p "$release_flow_repo/Vendor/libvlc.xcframework/$slice"
  printf 'fixture archive for %s\n' "$slice" > \
    "$release_flow_repo/Vendor/libvlc.xcframework/$slice/libvlc.a"
done
printf 'fixture first provenance\n' > \
  "$release_flow_repo/Vendor/libvlc-provenance-a.json"
printf 'fixture second provenance\n' > \
  "$release_flow_repo/Vendor/libvlc-provenance.json"
printf 'fixture reproducibility proof\n' > \
  "$release_flow_repo/Vendor/libvlc-reproducibility.json"

git -C "$release_flow_repo" init -q
git -C "$release_flow_repo" branch -M main
git -C "$release_flow_repo" config user.name "SwiftVLC Release Test"
git -C "$release_flow_repo" config user.email \
  "swiftvlc-release-test@example.invalid"
git -C "$release_flow_repo" add .
git -C "$release_flow_repo" commit -qm "release fixture"
release_flow_source_commit=$(git -C "$release_flow_repo" rev-parse HEAD)
git clone -q --bare "$release_flow_repo" "$release_flow_origin"
git -C "$release_flow_repo" remote add origin "$release_flow_origin"
git -C "$release_flow_repo" fetch -q origin main

release_flow_vendor_digest=$(
  "$release_flow_repo/scripts/artifact-tree-digest.py" \
    "$release_flow_repo/Vendor/libvlc.xcframework"
)
for release_flow_sidecar in \
  libvlc-provenance-a.json \
  libvlc-provenance.json \
  libvlc-reproducibility.json; do
  cp "$release_flow_repo/Vendor/$release_flow_sidecar" \
    "$release_flow_expected/$release_flow_sidecar"
done

release_flow_git_log="$release_flow_root/git-pushes.log"
release_flow_gh_state="$release_flow_root/github-release.state"
: > "$release_flow_git_log"
(
  cd "$release_flow_repo"
  PATH="$release_flow_fake_bin:$PATH" \
    TMPDIR="$release_flow_tmp" \
    SWIFTVLC_RELEASE_TEST_EXPECTED_REVISION="$release_flow_source_commit" \
    SWIFTVLC_RELEASE_TEST_GIT_LOG="$release_flow_git_log" \
    SWIFTVLC_RELEASE_TEST_MUTATE_VENDOR="$release_flow_repo/Vendor" \
    ./scripts/release.sh 1.1.0 --prepare "$release_flow_candidate" \
    > "$release_flow_root/prepare.log"
)

for release_flow_sidecar in \
  libvlc-provenance-a.json \
  libvlc-provenance.json \
  libvlc-reproducibility.json; do
  cmp -s "$release_flow_expected/$release_flow_sidecar" \
    "$release_flow_candidate/$release_flow_sidecar" || \
    fail "prepared candidate used a post-snapshot $release_flow_sidecar"
done
release_flow_candidate_digest=$(
  "$release_flow_repo/scripts/artifact-tree-digest.py" \
    "$release_flow_candidate/libvlc.xcframework"
)
[[ "$release_flow_candidate_digest" == "$release_flow_vendor_digest" ]] || \
  fail "prepared candidate used a post-snapshot XCFramework"

python3 - \
  "$release_flow_candidate/release-candidate.json" \
  "$release_flow_candidate" \
  "$release_flow_repo/scripts/artifact-tree-digest.py" \
  "$release_flow_source_commit" \
  "$release_flow_repo/scripts/qualification/matrix.json" \
  "$release_flow_repo/scripts/qualification/feature-manifest-v1.json" <<'PY'
import hashlib
import json
import subprocess
import sys
from pathlib import Path

(
    manifest_path_value,
    candidate_root_value,
    digest_tool_value,
    source_commit,
    matrix_path_value,
    feature_path_value,
) = sys.argv[1:]
manifest_path = Path(manifest_path_value)
candidate_root = Path(candidate_root_value)


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


candidate = json.loads(manifest_path.read_text())
expected = {
    "version": "1.1.0",
    "artifactDigestAlgorithm": "swiftvlc-tree-v1",
    "artifactDigest": subprocess.check_output(
        [digest_tool_value, candidate_root / "libvlc.xcframework"], text=True
    ).strip(),
    "zipChecksum": sha256(candidate_root / "libvlc.xcframework.zip"),
    "firstProvenanceChecksum": sha256(
        candidate_root / "libvlc-provenance-a.json"
    ),
    "provenanceChecksum": sha256(candidate_root / "libvlc-provenance.json"),
    "reproducibilityChecksum": sha256(
        candidate_root / "libvlc-reproducibility.json"
    ),
    "sourceCommit": source_commit,
    "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
    "releaseSourceDigest": "a" * 64,
    "qualificationMatrixChecksum": sha256(matrix_path_value),
    "featureManifestChecksum": sha256(feature_path_value),
}
if candidate != expected:
    raise SystemExit(
        "release candidate field/checksum mapping differs:\n"
        f"expected={expected}\nactual={candidate}"
    )
PY

for release_flow_asset in \
  libvlc.xcframework.zip \
  libvlc-provenance-a.json \
  libvlc-provenance.json \
  libvlc-reproducibility.json \
  release-candidate.json; do
  cp "$release_flow_candidate/$release_flow_asset" \
    "$release_flow_expected/$release_flow_asset"
done

# Candidate consumption may happen after qualification evidence advances main.
# The artifact must still be checked against the candidate's source commit, not
# the newer checkout HEAD, while the candidate source remains an ancestor.
mkdir -p "$release_flow_repo/scripts/qualification/evidence/1.1.0"
printf '{"fixture":"qualified"}\n' > \
  "$release_flow_repo/scripts/qualification/evidence/1.1.0/device.json"
git -C "$release_flow_repo" add \
  scripts/qualification/evidence/1.1.0/device.json
git -C "$release_flow_repo" commit -qm "Record qualification evidence"
/usr/bin/git -C "$release_flow_repo" push -q origin main
release_flow_origin_before_release=$(
  git --git-dir="$release_flow_origin" rev-parse refs/heads/main
)
[[ "$release_flow_origin_before_release" != "$release_flow_source_commit" ]] || \
  fail "release revision fixture did not advance main after preparation"

release_flow_common_env=(
  "PATH=$release_flow_fake_bin:$PATH"
  "TMPDIR=$release_flow_tmp"
  "SWIFTVLC_RELEASE_TEST_EXPECTED_REVISION=$release_flow_source_commit"
  "SWIFTVLC_RELEASE_TEST_CAPTURE=$release_flow_capture"
  "SWIFTVLC_RELEASE_TEST_GH_STATE=$release_flow_gh_state"
  "SWIFTVLC_RELEASE_TEST_GIT_LOG=$release_flow_git_log"
  "SWIFTVLC_RELEASE_TEST_ORIGIN=$release_flow_origin"
)

# Staging fails before any ref/release mutation unless repository-level
# immutable releases are enabled. The script only reads the setting.
if (
  cd "$release_flow_repo"
  env "${release_flow_common_env[@]}" \
    SWIFTVLC_RELEASE_TEST_IMMUTABLE_DISABLED=1 \
    ./scripts/release.sh 1.1.0 --candidate "$release_flow_candidate" \
      > "$release_flow_root/immutable-disabled.log" 2>&1
); then
  fail "release staging accepted disabled repository immutability"
fi
[[ ! -e "$release_flow_gh_state" ]] || \
  fail "immutable-release preflight mutated GitHub release state"
[[ -z $(git --git-dir="$release_flow_origin" tag -l 'v1.1.0') ]] || \
  fail "immutable-release preflight exposed the final SemVer tag"

for release_flow_ruleset_drift in \
  disabled \
  bypass \
  approvals \
  conversations \
  merge-method \
  deletion \
  force-push \
  checks \
  integration \
  repository-merge; do
  # Keep repository-level merge-method compatibility in the same fail-closed
  # governance matrix as the ruleset itself.
  if (
    cd "$release_flow_repo"
    env "${release_flow_common_env[@]}" \
      SWIFTVLC_RELEASE_TEST_RULESET_DRIFT="$release_flow_ruleset_drift" \
      ./scripts/release.sh 1.1.0 --candidate "$release_flow_candidate" \
        > "$release_flow_root/ruleset-$release_flow_ruleset_drift.log" 2>&1
  ); then
    fail "release staging accepted weakened main ruleset: $release_flow_ruleset_drift"
  fi
  [[ ! -e "$release_flow_gh_state" ]] || \
    fail "ruleset preflight mutated GitHub release state: $release_flow_ruleset_drift"
  [[ -z $(git --git-dir="$release_flow_origin" \
    branch --list 'release-candidates/v1.1.0') ]] || \
    fail "ruleset preflight pushed a release branch: $release_flow_ruleset_drift"
  [[ -z $(git --git-dir="$release_flow_origin" tag -l 'v1.1.0') ]] || \
    fail "ruleset preflight exposed a final tag: $release_flow_ruleset_drift"
done

# Fail each asset upload once. Every rerun must retain exact completed assets,
# remove only an incomplete starter, and continue with the missing asset. This
# is the recovery shape produced by gh's separate asset upload API calls.
expected_release_assets=(
  libvlc.xcframework.zip
  libvlc-provenance-a.json
  libvlc-provenance.json
  libvlc-reproducibility.json
  release-candidate.json
)
for release_flow_failed_asset in "${expected_release_assets[@]}"; do
  if (
    cd "$release_flow_repo"
    env "${release_flow_common_env[@]}" \
      SWIFTVLC_RELEASE_TEST_FAIL_UPLOAD_NAME="$release_flow_failed_asset" \
      ./scripts/release.sh 1.1.0 --candidate "$release_flow_candidate" \
        > "$release_flow_root/upload-$release_flow_failed_asset.log" 2>&1
  ); then
    fail "release hid a failed $release_flow_failed_asset upload"
  fi
  [[ $(tr -d '\n' < "$release_flow_gh_state") == draft ]] || \
    fail "asset upload failure changed draft visibility"
  [[ -z $(git --git-dir="$release_flow_origin" \
    branch --list 'release-candidates/v1.1.0') ]] || \
    fail "candidate CI started before every asset upload completed"
  [[ -z $(git --git-dir="$release_flow_origin" tag -l 'v1.1.0') ]] || \
    fail "asset upload failure exposed the final SemVer tag"
done

# Complete staging with an original-directory TOCTOU mutation after the private
# snapshot. Already-uploaded exact bytes must not be replaced or duplicated.
(
  cd "$release_flow_repo"
  env "${release_flow_common_env[@]}" \
    SWIFTVLC_RELEASE_TEST_MUTATE_CANDIDATE="$release_flow_candidate" \
    ./scripts/release.sh 1.1.0 --candidate "$release_flow_candidate" \
      > "$release_flow_root/release.log"
)

captured_release_count=0
while IFS= read -r captured_release_path; do
  captured_release_paths[$captured_release_count]="$captured_release_path"
  captured_release_count=$((captured_release_count + 1))
done < "$release_flow_capture/assets.paths"
[[ $captured_release_count -eq ${#expected_release_assets[@]} ]] || \
  fail "resumed release uploaded or replaced an asset more than once"
for ((release_flow_index = 0;
      release_flow_index < ${#expected_release_assets[@]};
      release_flow_index++)); do
  release_flow_asset=${expected_release_assets[$release_flow_index]}
  release_flow_path=${captured_release_paths[$release_flow_index]}
  [[ $(basename "$release_flow_path") == "$release_flow_asset" ]] || \
    fail "release asset order/name drifted: expected $release_flow_asset, got $release_flow_path"
  case "$release_flow_path" in
    "$release_flow_tmp"/swiftvlc-release.*/release-assets/*) ;;
    *) fail "release uploaded an asset outside its private snapshot: $release_flow_path" ;;
  esac
  cmp -s "$release_flow_expected/$release_flow_asset" \
    "$release_flow_capture/uploaded/$release_flow_asset" || \
    fail "release uploaded changed bytes for $release_flow_asset"
  if cmp -s "$release_flow_expected/$release_flow_asset" \
    "$release_flow_candidate/$release_flow_asset"; then
    fail "release TOCTOU fixture did not mutate original $release_flow_asset"
  fi
done
[[ -z $(find "$release_flow_capture/starters" -type f -print -quit) ]] || \
  fail "release left an incomplete starter asset after recovery"

release_flow_release_commit=$(git -C "$release_flow_repo" rev-parse HEAD)
release_flow_candidate_tag="swiftvlc-candidate-v1.1.0-$release_flow_release_commit"
[[ $(git --git-dir="$release_flow_origin" rev-parse refs/heads/main) == \
  "$release_flow_origin_before_release" ]] || \
  fail "staging exposed a draft-only artifact through origin/main"
if git --git-dir="$release_flow_origin" rev-parse refs/tags/v1.1.0 \
    >/dev/null 2>&1; then
  fail "staging exposed the final SemVer tag before CI"
fi
[[ $(git --git-dir="$release_flow_origin" \
  rev-parse "refs/tags/$release_flow_candidate_tag") == \
  "$release_flow_release_commit" ]] || \
  fail "staging did not bind the non-SemVer candidate tag to the release commit"
[[ $(git --git-dir="$release_flow_origin" \
  rev-parse refs/heads/release-candidates/v1.1.0) == \
  "$release_flow_release_commit" ]] || \
  fail "staging did not push the exact release-candidate branch"
[[ $(tr -d '\n' < "$release_flow_gh_state") == draft ]] || \
  fail "the first release phase published instead of retaining a draft"
grep -q 'No final SemVer tag exists' "$release_flow_root/release.log" || \
  fail "the first release phase did not report its safe CI pause"
[[ $(wc -l < "$release_flow_git_log" | tr -d ' ') == 2 ]] || \
  fail "staging did not use exactly candidate-tag and candidate-branch pushes"

# Restore the deliberately mutated source candidate. Every finalize retry
# independently verifies the operator-supplied immutable candidate directory.
rm -rf "$release_flow_candidate/libvlc.xcframework"
ditto -x -k \
  "$release_flow_expected/libvlc.xcframework.zip" \
  "$release_flow_candidate"
for release_flow_asset in "${expected_release_assets[@]}"; do
  cp "$release_flow_expected/$release_flow_asset" \
    "$release_flow_candidate/$release_flow_asset"
done

# GitHub represents mutable draft downloads with an opaque `untagged-*`
# locator. It must come from the exact release's top-level URL; a matching
# digest at another draft locator is not the staged candidate.
if (
  cd "$release_flow_repo"
  env "${release_flow_common_env[@]}" \
    SWIFTVLC_RELEASE_TEST_ASSET_URL_DRIFT=1 \
    ./scripts/release.sh 1.1.0 --candidate "$release_flow_candidate" \
      > "$release_flow_root/draft-asset-url-drift.log" 2>&1
); then
  fail "release accepted a candidate asset from a different draft locator"
fi
grep -q 'existing candidate asset conflicts with local bytes' \
  "$release_flow_root/draft-asset-url-drift.log" || \
  fail "candidate draft-locator drift did not produce a fail-closed diagnostic"
[[ $(tr -d '\n' < "$release_flow_gh_state") == draft ]] || \
  fail "candidate draft-locator drift changed release visibility"

# A checksum-looking staged Package.swift is not sufficient. Move the mutable
# candidate anchors to a one-parent commit containing the canonical release
# files plus an unrelated Package.swift edit; fresh finalize must reconstruct
# and reject it byte-for-byte before querying CI.
release_flow_malicious_repo="$release_flow_root/malicious-repository"
git clone -q "$release_flow_origin" "$release_flow_malicious_repo"
git -C "$release_flow_malicious_repo" config user.name "SwiftVLC Release Test"
git -C "$release_flow_malicious_repo" config user.email \
  "swiftvlc-release-test@example.invalid"
git -C "$release_flow_malicious_repo" checkout -q \
  "$release_flow_release_commit" -- Package.swift \
  Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj
printf '\n// unrelated staged dependency mutation\n' >> \
  "$release_flow_malicious_repo/Package.swift"
git -C "$release_flow_malicious_repo" add Package.swift \
  Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj
git -C "$release_flow_malicious_repo" commit -qm "Malicious release rewrite"
release_flow_malicious_commit=$(git -C "$release_flow_malicious_repo" rev-parse HEAD)
release_flow_malicious_tag="swiftvlc-candidate-v1.1.0-$release_flow_malicious_commit"
git --git-dir="$release_flow_origin" update-ref -d \
  "refs/tags/$release_flow_candidate_tag"
/usr/bin/git -C "$release_flow_malicious_repo" push -q origin \
  "$release_flow_malicious_commit:refs/tags/$release_flow_malicious_tag"
git --git-dir="$release_flow_origin" update-ref \
  refs/heads/release-candidates/v1.1.0 "$release_flow_malicious_commit"
printf '%s\n' "$release_flow_malicious_tag" > "$release_flow_capture/release.tag"
printf '%s\n' "$release_flow_malicious_commit" > \
  "$release_flow_capture/release.commit"
release_flow_malicious_finalize="$release_flow_root/malicious-finalize"
git clone -q "$release_flow_origin" "$release_flow_malicious_finalize"
git -C "$release_flow_malicious_finalize" config user.name \
  "SwiftVLC Release Test"
git -C "$release_flow_malicious_finalize" config user.email \
  "swiftvlc-release-test@example.invalid"
if (
  cd "$release_flow_malicious_finalize"
  env "${release_flow_common_env[@]}" SWIFTVLC_RELEASE_TEST_RUN_STATE=success \
    ./scripts/release.sh 1.1.0 \
      --candidate "$release_flow_candidate" --finalize \
      > "$release_flow_root/malicious-finalize.log" 2>&1
); then
  fail "finalize accepted an unrelated Package.swift mutation"
fi
git --git-dir="$release_flow_origin" update-ref -d \
  "refs/tags/$release_flow_malicious_tag"
git --git-dir="$release_flow_origin" update-ref \
  "refs/tags/$release_flow_candidate_tag" "$release_flow_release_commit"
git --git-dir="$release_flow_origin" update-ref \
  refs/heads/release-candidates/v1.1.0 "$release_flow_release_commit"
printf '%s\n' "$release_flow_candidate_tag" > "$release_flow_capture/release.tag"
printf '%s\n' "$release_flow_release_commit" > \
  "$release_flow_capture/release.commit"

# Finalize from a fresh clone whose main still points at the last public
# commit. Candidate push evidence and protected-PR evidence fail independently.
release_flow_finalize_repo="$release_flow_root/finalize-repository"
git clone -q "$release_flow_origin" "$release_flow_finalize_repo"
git -C "$release_flow_finalize_repo" config user.name \
  "SwiftVLC Release Test"
git -C "$release_flow_finalize_repo" config user.email \
  "swiftvlc-release-test@example.invalid"

for release_flow_run_state in missing pending failed stale-success-pending; do
  if (
    cd "$release_flow_finalize_repo"
    env "${release_flow_common_env[@]}" \
      SWIFTVLC_RELEASE_TEST_RUN_STATE="$release_flow_run_state" \
      ./scripts/release.sh 1.1.0 \
        --candidate "$release_flow_candidate" --finalize \
        > "$release_flow_root/finalize-$release_flow_run_state.log" 2>&1
  ); then
    fail "finalize accepted $release_flow_run_state exact-commit CI"
  fi
  [[ $(tr -d '\n' < "$release_flow_gh_state") == draft ]] || \
    fail "finalize published after $release_flow_run_state CI"
done

for release_flow_pr_state in \
  missing pending failed skipped-required duplicate; do
  if (
    cd "$release_flow_finalize_repo"
    env "${release_flow_common_env[@]}" \
      SWIFTVLC_RELEASE_TEST_RUN_STATE=success \
      SWIFTVLC_RELEASE_TEST_PR_CHECK_STATE="$release_flow_pr_state" \
      ./scripts/release.sh 1.1.0 \
        --candidate "$release_flow_candidate" --finalize \
        > "$release_flow_root/finalize-pr-$release_flow_pr_state.log" 2>&1
  ); then
    fail "finalize accepted $release_flow_pr_state protected-PR checks"
  fi
  [[ $(tr -d '\n' < "$release_flow_gh_state") == draft ]] || \
    fail "finalize published after $release_flow_pr_state protected-PR checks"
done

if (
  cd "$release_flow_finalize_repo"
  env "${release_flow_common_env[@]}" \
    SWIFTVLC_RELEASE_TEST_RUN_STATE=success \
    SWIFTVLC_RELEASE_TEST_ASSET_DRIFT=1 \
    ./scripts/release.sh 1.1.0 \
      --candidate "$release_flow_candidate" --finalize \
      > "$release_flow_root/finalize-asset-drift.log" 2>&1
); then
  fail "finalize accepted GitHub asset digest drift"
fi
[[ $(tr -d '\n' < "$release_flow_gh_state") == draft ]] || \
  fail "finalize published after GitHub asset digest drift"

for release_flow_metadata_drift in title body; do
  if (
    cd "$release_flow_finalize_repo"
    env "${release_flow_common_env[@]}" \
      SWIFTVLC_RELEASE_TEST_RUN_STATE=success \
      SWIFTVLC_RELEASE_TEST_METADATA_DRIFT="$release_flow_metadata_drift" \
      ./scripts/release.sh 1.1.0 \
        --candidate "$release_flow_candidate" --finalize \
        > "$release_flow_root/finalize-metadata-$release_flow_metadata_drift.log" 2>&1
  ); then
    fail "finalize accepted candidate release $release_flow_metadata_drift drift"
  fi
  [[ $(tr -d '\n' < "$release_flow_gh_state") == draft ]] || \
    fail "candidate metadata drift reached publication"
done

# Candidate branch, candidate tag, and main are all mutable before publish.
# Move each boundary independently and prove finalize refuses it, then restore
# the isolated bare fixture for the next case.
git --git-dir="$release_flow_origin" update-ref \
  refs/heads/release-candidates/v1.1.0 "$release_flow_origin_before_release"
if (
  cd "$release_flow_finalize_repo"
  env "${release_flow_common_env[@]}" SWIFTVLC_RELEASE_TEST_RUN_STATE=success \
    ./scripts/release.sh 1.1.0 --candidate "$release_flow_candidate" --finalize \
      > "$release_flow_root/finalize-branch-drift.log" 2>&1
); then
  fail "finalize accepted a moved candidate branch"
fi
git --git-dir="$release_flow_origin" update-ref \
  refs/heads/release-candidates/v1.1.0 "$release_flow_release_commit"

git --git-dir="$release_flow_origin" update-ref \
  "refs/tags/$release_flow_candidate_tag" "$release_flow_origin_before_release"
if (
  cd "$release_flow_finalize_repo"
  env "${release_flow_common_env[@]}" SWIFTVLC_RELEASE_TEST_RUN_STATE=success \
    ./scripts/release.sh 1.1.0 --candidate "$release_flow_candidate" --finalize \
      > "$release_flow_root/finalize-tag-drift.log" 2>&1
); then
  fail "finalize accepted a moved candidate tag"
fi
git --git-dir="$release_flow_origin" update-ref \
  "refs/tags/$release_flow_candidate_tag" "$release_flow_release_commit"

git --git-dir="$release_flow_origin" update-ref refs/heads/main \
  "$release_flow_malicious_commit"
if (
  cd "$release_flow_finalize_repo"
  env "${release_flow_common_env[@]}" SWIFTVLC_RELEASE_TEST_RUN_STATE=success \
    ./scripts/release.sh 1.1.0 --candidate "$release_flow_candidate" --finalize \
      > "$release_flow_root/finalize-main-drift.log" 2>&1
); then
  fail "finalize accepted an advanced origin/main"
fi
git --git-dir="$release_flow_origin" update-ref refs/heads/main \
  "$release_flow_origin_before_release"

# A concurrently/preemptively created final tag cannot be frozen into the
# immutable release. The final identity must either be absent or equal H.
git --git-dir="$release_flow_origin" update-ref refs/tags/v1.1.0 \
  "$release_flow_origin_before_release"
if (
  cd "$release_flow_finalize_repo"
  env "${release_flow_common_env[@]}" SWIFTVLC_RELEASE_TEST_RUN_STATE=success \
    ./scripts/release.sh 1.1.0 --candidate "$release_flow_candidate" --finalize \
      > "$release_flow_root/finalize-final-tag-race.log" 2>&1
); then
  fail "finalize accepted a wrong preexisting final tag"
fi
[[ $(tr -d '\n' < "$release_flow_gh_state") == draft ]] || \
  fail "wrong final-tag race reached publication"
git --git-dir="$release_flow_origin" update-ref -d refs/tags/v1.1.0

# A failed atomic update that did not commit must remain an exact draft and
# leave final tag/main absent. A later invocation, not an in-process blind
# retry, is the only allowed recovery.
if (
  cd "$release_flow_finalize_repo"
  env "${release_flow_common_env[@]}" \
    SWIFTVLC_RELEASE_TEST_RUN_STATE=stale-failure-recovered \
    SWIFTVLC_RELEASE_TEST_EDIT_MODE=fail-before \
    ./scripts/release.sh 1.1.0 --candidate "$release_flow_candidate" --finalize \
      > "$release_flow_root/finalize-publish-failed-before.log" 2>&1
); then
  fail "finalize hid a publication update that failed before commit"
fi
[[ $(tr -d '\n' < "$release_flow_gh_state") == draft ]] || \
  fail "failed publication update did not remain a draft"
if git --git-dir="$release_flow_origin" rev-parse refs/tags/v1.1.0 \
    >/dev/null 2>&1; then
  fail "failed publication update created the final SemVer tag"
fi

# An uncertain publication response that did commit is recovered by inspecting
# the final identity, not by blindly repeating the PATCH. Inject a PR merge
# failure before commit: the public immutable release remains usable, main is
# still intact, and the already-green protected PR remains the recovery path.
if (
  cd "$release_flow_finalize_repo"
  env "${release_flow_common_env[@]}" \
    SWIFTVLC_RELEASE_TEST_RUN_STATE=success \
    SWIFTVLC_RELEASE_TEST_EDIT_MODE=fail-after \
    SWIFTVLC_RELEASE_TEST_MERGE_MODE=fail-before \
    ./scripts/release.sh 1.1.0 \
      --candidate "$release_flow_candidate" --finalize \
      > "$release_flow_root/finalize-pr-merge-failed-before.log" 2>&1
); then
  fail "finalize hid a failed protected-PR merge after publication"
fi
[[ $(tr -d '\n' < "$release_flow_gh_state") == published ]] || \
  fail "uncertain successful publication was not recovered"
[[ $(git --git-dir="$release_flow_origin" rev-parse refs/tags/v1.1.0) == \
  "$release_flow_release_commit" ]] || \
  fail "atomic publication did not create the exact final SemVer tag"
[[ $(git --git-dir="$release_flow_origin" rev-parse refs/heads/main) == \
  "$release_flow_origin_before_release" ]] || \
  fail "failed PR merge unexpectedly changed origin/main"
[[ $(git --git-dir="$release_flow_origin" \
  rev-parse refs/heads/release-candidates/v1.1.0) == \
  "$release_flow_release_commit" ]] || \
  fail "failed PR merge removed the recovery branch"
[[ $(tr -d '\n' < "$release_flow_capture/pr.state") == open ]] || \
  fail "failed PR merge did not retain the open recovery PR"

# A public release whose immutable state can no longer be proven must not merge
# or clean any authorization ref, even if all prior checks were green.
if (
  cd "$release_flow_finalize_repo"
  env "${release_flow_common_env[@]}" \
    SWIFTVLC_RELEASE_TEST_RUN_STATE=success \
    SWIFTVLC_RELEASE_TEST_IMMUTABLE_DRIFT=1 \
    ./scripts/release.sh 1.1.0 \
      --candidate "$release_flow_candidate" --finalize \
      > "$release_flow_root/finalize-public-immutability-drift.log" 2>&1
); then
  fail "finalize merged a release whose immutable state drifted"
fi
[[ $(tr -d '\n' < "$release_flow_capture/pr.state") == open ]] || \
  fail "immutable-state drift changed the release PR"

# A merge response may fail after GitHub committed it. Re-read PR and main,
# prove the exact two-parent tree relationship, and pause for fresh main CI.
(
  cd "$release_flow_finalize_repo"
  env "${release_flow_common_env[@]}" \
    SWIFTVLC_RELEASE_TEST_RUN_STATE=success \
    SWIFTVLC_RELEASE_TEST_MERGE_MODE=fail-after \
    ./scripts/release.sh 1.1.0 \
      --candidate "$release_flow_candidate" --finalize \
      > "$release_flow_root/finalize-pr-merge-uncertain.log"
)
release_flow_merge_commit=$(cat "$release_flow_capture/pr.merge")
[[ $(tr -d '\n' < "$release_flow_capture/pr.state") == merged ]] || \
  fail "uncertain successful PR merge was not recovered"
[[ $(git --git-dir="$release_flow_origin" rev-parse refs/heads/main) == \
  "$release_flow_merge_commit" ]] || \
  fail "protected PR merge did not become origin/main"
[[ "$release_flow_merge_commit" != "$release_flow_release_commit" ]] || \
  fail "protected-main flow did not create a merge commit"
git --git-dir="$release_flow_origin" merge-base --is-ancestor \
  "$release_flow_release_commit" "$release_flow_merge_commit" || \
  fail "tagged release head is not an ancestor of the main merge"
[[ $(git --git-dir="$release_flow_origin" rev-parse \
  "${release_flow_release_commit}^{tree}") == \
  $(git --git-dir="$release_flow_origin" rev-parse \
  "${release_flow_merge_commit}^{tree}") ]] || \
  fail "protected PR merge changed the qualified release tree"
grep -q 'exact-main CI is running' \
  "$release_flow_root/finalize-pr-merge-uncertain.log" || \
  fail "first protected-main merge did not pause for fresh main CI"
[[ $(git --git-dir="$release_flow_origin" rev-parse refs/tags/v1.1.0) == \
  "$release_flow_release_commit" ]] || \
  fail "protected-main merge moved the immutable release tag"

# Post-merge authorization is a fresh push run for the exact main merge SHA,
# never a reuse of either the candidate push or PR checks.
for release_flow_main_run_state in missing pending failed; do
  if (
    cd "$release_flow_finalize_repo"
    env "${release_flow_common_env[@]}" \
      SWIFTVLC_RELEASE_TEST_RUN_STATE=success \
      SWIFTVLC_RELEASE_TEST_MAIN_RUN_STATE="$release_flow_main_run_state" \
      ./scripts/release.sh 1.1.0 \
        --candidate "$release_flow_candidate" --finalize \
        > "$release_flow_root/finalize-main-$release_flow_main_run_state.log" 2>&1
  ); then
    fail "finalize accepted $release_flow_main_run_state exact-main CI"
  fi
  [[ $(git --git-dir="$release_flow_origin" \
    rev-parse refs/heads/release-candidates/v1.1.0) == \
    "$release_flow_release_commit" ]] || \
    fail "$release_flow_main_run_state main CI removed the recovery branch"
done

# Compare-and-delete cleanup must fail closed if either temporary ref moves
# after verification. The force-with-lease rejection preserves the moved ref.
if (
  cd "$release_flow_finalize_repo"
  env "${release_flow_common_env[@]}" \
    SWIFTVLC_RELEASE_TEST_RUN_STATE=success \
    SWIFTVLC_RELEASE_TEST_MAIN_RUN_STATE=success \
    SWIFTVLC_RELEASE_TEST_CLEANUP_RACE=branch \
    SWIFTVLC_RELEASE_TEST_RACE_COMMIT="$release_flow_origin_before_release" \
    ./scripts/release.sh 1.1.0 \
      --candidate "$release_flow_candidate" --finalize \
      > "$release_flow_root/finalize-cleanup-branch-race.log" 2>&1
); then
  fail "cleanup hid a candidate-branch compare-and-delete race"
fi
[[ $(git --git-dir="$release_flow_origin" \
  rev-parse refs/heads/release-candidates/v1.1.0) == \
  "$release_flow_origin_before_release" ]] || \
  fail "branch cleanup race deleted or overwrote the moved ref"
git --git-dir="$release_flow_origin" update-ref \
  refs/heads/release-candidates/v1.1.0 "$release_flow_release_commit"

if (
  cd "$release_flow_finalize_repo"
  env "${release_flow_common_env[@]}" \
    SWIFTVLC_RELEASE_TEST_RUN_STATE=success \
    SWIFTVLC_RELEASE_TEST_MAIN_RUN_STATE=success \
    SWIFTVLC_RELEASE_TEST_CLEANUP_RACE=tag \
    SWIFTVLC_RELEASE_TEST_RACE_COMMIT="$release_flow_origin_before_release" \
    ./scripts/release.sh 1.1.0 \
      --candidate "$release_flow_candidate" --finalize \
      > "$release_flow_root/finalize-cleanup-tag-race.log" 2>&1
); then
  fail "cleanup hid a candidate-tag compare-and-delete race"
fi
[[ $(git --git-dir="$release_flow_origin" \
  rev-parse "refs/tags/$release_flow_candidate_tag") == \
  "$release_flow_origin_before_release" ]] || \
  fail "tag cleanup race deleted or overwrote the moved ref"
git --git-dir="$release_flow_origin" update-ref \
  "refs/tags/$release_flow_candidate_tag" "$release_flow_release_commit"

# A clean retry verifies the immutable public artifact, exact PR merge, and
# fresh main CI before removing only the remaining temporary ref.
(
  cd "$release_flow_finalize_repo"
  env "${release_flow_common_env[@]}" \
    SWIFTVLC_RELEASE_TEST_RUN_STATE=success \
    SWIFTVLC_RELEASE_TEST_MAIN_RUN_STATE=success \
    ./scripts/release.sh 1.1.0 \
      --candidate "$release_flow_candidate" --finalize \
      > "$release_flow_root/finalize-recovery.log"
)
[[ $(git --git-dir="$release_flow_origin" rev-parse refs/heads/main) == \
  "$release_flow_merge_commit" ]] || \
  fail "finalize recovery moved protected main"
if git --git-dir="$release_flow_origin" rev-parse \
    refs/heads/release-candidates/v1.1.0 >/dev/null 2>&1; then
  fail "completed release retained its candidate branch"
fi
if git --git-dir="$release_flow_origin" rev-parse \
    "refs/tags/$release_flow_candidate_tag" >/dev/null 2>&1; then
  fail "completed release retained its non-SemVer candidate tag"
fi
grep -q '^SwiftVLC v1.1.0$' "$release_flow_capture/release.title" || \
  fail "immutable final release retained candidate title"
grep -q '^## libVLC xcframework$' "$release_flow_capture/release.notes" || \
  fail "immutable final release retained candidate notes"

# A fully completed rerun performs the same verification with no ref writes.
release_flow_pushes_before=$(wc -l < "$release_flow_git_log" | tr -d ' ')
(
  cd "$release_flow_finalize_repo"
  env "${release_flow_common_env[@]}" \
    SWIFTVLC_RELEASE_TEST_RUN_STATE=success \
    SWIFTVLC_RELEASE_TEST_MAIN_RUN_STATE=success \
    ./scripts/release.sh 1.1.0 \
      --candidate "$release_flow_candidate" --finalize \
      > "$release_flow_root/finalize-idempotent.log"
)
[[ $(wc -l < "$release_flow_git_log" | tr -d ' ') == 9 ]] || \
  fail "release flow did not use the expected leased temporary-ref writes"
[[ $(wc -l < "$release_flow_git_log" | tr -d ' ') == \
  "$release_flow_pushes_before" ]] || \
  fail "completed finalize repeated a candidate or cleanup ref write"
cd "$ROOT_DIR"
bash -n \
  scripts/build-libvlc.sh \
  scripts/canonical-libvlc-artifact.sh \
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

if [[ "$candidate_lint" == "1" ]]; then
  # Candidate build jobs perform the authenticated live download. Keep this
  # broad fault-matrix/lint job read-only while still checking that its release
  # and Showcase declarations agree.
  artifact_info=$(python3 scripts/release-artifact-info.py Package.swift)
else
  artifact_info=$(./scripts/resolve-release-artifact.sh)
fi
actual_tag=$(printf '%s' "$artifact_info" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag"])')
showcase_version=$(sed -n \
  's/^[[:space:]]*version = \([^;]*\);$/\1/p' \
  Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj)
[[ -n "$showcase_version" ]] || fail "Showcase release version was not found"
[[ "$actual_tag" == "v$showcase_version" ]] \
  || fail "checkout resolves $actual_tag but Showcase resolves v$showcase_version"

stable_info=$(SWIFTVLC_RELEASE_TAG=v1.0.0 ./scripts/resolve-release-artifact.sh)
stable_tag=$(printf '%s' "$stable_info" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag"])')
[[ "$stable_tag" == "v1.0.0" ]] \
  || fail "explicit release override resolved $stable_tag instead of v1.0.0"

if ./scripts/release.sh 1.1.0 >/dev/null 2>&1; then
  fail "stable release was accepted without a prepared candidate"
fi
if ./scripts/release.sh 1.1.0 --unqualified >/dev/null 2>&1; then
  fail "stable release bypassed qualification through --unqualified"
fi

echo "Release-integrity tests passed."
