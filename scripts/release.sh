#!/usr/bin/env bash
#
# release.sh — Strip, zip, checksum, and publish the libVLC xcframework.
#
# Prerequisites:
#   - Two canonical-root ./scripts/build-libvlc.sh --clean-build --all
#     invocations, compared byte-for-byte
#     with both provenance records retained beside Vendor/libvlc.xcframework
#   - gh authed (gh auth login)
#   - A completely clean, up-to-date main checkout
#
# Usage:
#   ./scripts/release.sh 0.1.0 --prepare /path/to/candidate
#   ./scripts/release.sh 0.1.0 --candidate /path/to/candidate
#   ./scripts/release.sh 0.1.0 --candidate /path/to/candidate --finalize
#   ./scripts/release.sh 0.1.0 --dry-run          # strip/zip/checksum only, no push
#
set -euo pipefail

REPO="harflabs/SwiftVLC"
XCFW_PATH="Vendor/libvlc.xcframework"
SHOWCASE_PROJECT="Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj"
ZIP_NAME="libvlc.xcframework.zip"
MAX_SIZE=$((2 * 1024 * 1024 * 1024))  # 2 GB (GitHub release asset limit)

# Release re-runs the direct per-object metadata gate with the same five
# deployment policies as build-libvlc.sh. Keep these values in sync with
# Package.swift and the corresponding SWIFTVLC_MIN_* build constants.
SWIFTVLC_MIN_IOS="18.0"
SWIFTVLC_MIN_TVOS="18.0"
SWIFTVLC_MIN_VISIONOS="2.0"
SWIFTVLC_MIN_MACOS="15.0"
SWIFTVLC_MIN_CATALYST="18.0"

# All 8 slices the xcframework must contain. If a slice is missing, the release
# would ship a partial artifact that fails on one of SwiftVLC's Apple platforms.
EXPECTED_SLICES=(
  "ios-arm64"
  "ios-arm64_x86_64-simulator"
  "tvos-arm64"
  "tvos-arm64_x86_64-simulator"
  "xros-arm64"
  "xros-arm64_x86_64-simulator"
  "macos-arm64_x86_64"
  "ios-arm64_x86_64-maccatalyst"
)

# ── Args ──────────────────────────────────────────────────────────────────────

VERSION=""
DRY_RUN=false
UNQUALIFIED=false
PREPARE_DIR=""
CANDIDATE_DIR=""
CANDIDATE_SOURCE_COMMIT=""
CANDIDATE_SOURCE_DIGEST=""
CANDIDATE_MATRIX_CHECKSUM=""
CANDIDATE_FEATURE_MANIFEST_CHECKSUM=""
FINALIZE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift ;;
    --unqualified)
      UNQUALIFIED=true
      shift ;;
    --prepare)
      [[ $# -ge 2 ]] || { echo "Error: --prepare requires a directory." >&2; exit 2; }
      PREPARE_DIR="$2"
      DRY_RUN=true
      shift 2 ;;
    --candidate)
      [[ $# -ge 2 ]] || { echo "Error: --candidate requires a directory." >&2; exit 2; }
      CANDIDATE_DIR="$2"
      shift 2 ;;
    --finalize)
      FINALIZE=true
      shift ;;
    --allow-dirty-branch)
      echo "Error: --allow-dirty-branch is no longer supported." >&2
      echo "  Releases are staged from main and merged only through a protected PR." >&2
      exit 1 ;;
    --help|-h)
      sed -n 's/^# \{0,1\}//p' "$0" | sed -n '/^Usage:/,/^$/p'
      exit 0 ;;
    -*)
      echo "Error: unknown flag '$1'" >&2
      exit 1 ;;
    *)
      if [[ -n "$VERSION" ]]; then
        echo "Error: version already specified ('$VERSION'), got extra arg '$1'" >&2
        exit 1
      fi
      VERSION="$1"
      shift ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version> [--dry-run]" >&2
  echo "  e.g. $0 0.1.0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FEATURE_MANIFEST="$SCRIPT_DIR/qualification/feature-manifest-v1.json"

# SwiftPM classifies versions from git tags, not GitHub's pre-release flag.
# Parse the version before touching an artifact so a caller cannot use
# `--unqualified` to publish a stable-looking tag without device qualification.
if ! RELEASE_KIND=$(python3 "$SCRIPT_DIR/release-version-policy.py" \
  "$VERSION" --field kind); then
  exit 2
fi
if [[ "$RELEASE_KIND" == "prerelease" ]]; then
  # Pre-release routing is version-derived. The flag remains accepted for
  # backwards compatibility, but beta/alpha/RC versions do not require it.
  UNQUALIFIED=true
elif [[ "$UNQUALIFIED" == true ]]; then
  echo "Error: --unqualified is only valid for a SemVer pre-release." >&2
  echo "  Use a version such as 1.1.0-beta.1; stable tags require qualification." >&2
  exit 2
fi

TAG="v${VERSION}"
RELEASE_BRANCH="release-candidates/${TAG}"
RELEASE_URL="https://github.com/$REPO/releases/download/$TAG/$ZIP_NAME"
cd "$ROOT_DIR"

if [[ -n "$PREPARE_DIR" && -n "$CANDIDATE_DIR" ]]; then
  echo "Error: --prepare and --candidate are mutually exclusive." >&2
  exit 2
fi
if [[ "$FINALIZE" == true && ( "$DRY_RUN" == true || -n "$PREPARE_DIR" ) ]]; then
  echo "Error: --finalize requires --candidate and cannot be a dry run." >&2
  exit 2
fi
if [[ "$DRY_RUN" == false && -z "$CANDIDATE_DIR" ]]; then
  echo "Error: every published release must consume a prepared candidate directory." >&2
  echo "  First: $0 $VERSION --prepare /path/to/candidate" >&2
  echo "  Then stage with --candidate and publish with --candidate --finalize." >&2
  exit 1
fi
if [[ -n "$CANDIDATE_DIR" ]]; then
  CANDIDATE_DIR="$(cd "$CANDIDATE_DIR" 2>/dev/null && pwd)" || {
    echo "Error: candidate directory not found." >&2
    exit 1
  }
  XCFW_PATH="$CANDIDATE_DIR/libvlc.xcframework"
fi

echo "Verifying native validator asset manifest..."
if ! python3 "$SCRIPT_DIR/verify-native-validator-assets.py"; then
  echo "Error: native validator asset manifest verification failed." >&2
  echo "  Rebuild after restoring or intentionally rebinding the audited validator assets." >&2
  exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

WORK_DIR=""
RELEASE_SNAPSHOT_DIR=""
RELEASE_RESTORE_DIR=""
RELEASE_RESTORE_FILES=false

make_temp_dir() {
  local temp_root="${TMPDIR:-/tmp}"
  mkdir -p "$temp_root"
  mktemp -d "$temp_root/swiftvlc-release.XXXXXX"
}

cleanup() {
  local status=$?

  if [[ "$RELEASE_RESTORE_FILES" == true ]]; then
    if [[ -n "$RELEASE_RESTORE_DIR" && -f "$RELEASE_RESTORE_DIR/Package.swift" ]]; then
      cp "$RELEASE_RESTORE_DIR/Package.swift" Package.swift
    fi
    if [[ -n "$RELEASE_RESTORE_DIR" && -f "$RELEASE_RESTORE_DIR/project.pbxproj" ]]; then
      cp "$RELEASE_RESTORE_DIR/project.pbxproj" "$SHOWCASE_PROJECT"
    fi
    git reset -q -- Package.swift "$SHOWCASE_PROJECT" 2>/dev/null || true
    if [[ "$status" -ne 0 ]]; then
      echo "Restored Package.swift and $SHOWCASE_PROJECT after failed release rewrite." >&2
    fi
  fi

  if [[ -n "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
  if [[ -n "$RELEASE_RESTORE_DIR" ]]; then
    rm -rf "$RELEASE_RESTORE_DIR"
  fi
}
trap cleanup EXIT

begin_release_file_restore() {
  RELEASE_RESTORE_DIR=$(make_temp_dir)
  cp Package.swift "$RELEASE_RESTORE_DIR/Package.swift"
  cp "$SHOWCASE_PROJECT" "$RELEASE_RESTORE_DIR/project.pbxproj"
  RELEASE_RESTORE_FILES=true
}

switch_package_to_release_url() {
  RELEASE_URL="$RELEASE_URL" CHECKSUM="$CHECKSUM" python3 - <<'PYEOF'
import os
import re
import sys
import tempfile

url = os.environ["RELEASE_URL"]
checksum = os.environ["CHECKSUM"]
path = "Package.swift"

with open(path, "r") as f:
    text = f.read()

pattern = r'\.binaryTarget\(\s*name:\s*"libvlc"[^)]*\)'
replacement = (
    '.binaryTarget(\n'
    '      name: "libvlc",\n'
    f'      url: "{url}",\n'
    f'      checksum: "{checksum}"\n'
    '    )'
)
result, n = re.subn(pattern, replacement, text, count=1, flags=re.DOTALL)
if n == 0:
    print("ERROR: binaryTarget pattern not found in Package.swift", file=sys.stderr)
    sys.exit(1)

fd, tmp = tempfile.mkstemp(dir=".", prefix=".Package.swift.", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        f.write(result)
    os.replace(tmp, path)
except Exception:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise
PYEOF
}

switch_showcase_to_release_version() {
  RELEASE_VERSION="$VERSION" SHOWCASE_PROJECT="$SHOWCASE_PROJECT" python3 - <<'PYEOF'
import os
import re
import sys
import tempfile

version = os.environ["RELEASE_VERSION"]
path = os.environ["SHOWCASE_PROJECT"]

with open(path, "r") as f:
    text = f.read()

remote_block = f"""/* Begin XCRemoteSwiftPackageReference section */
\t\tBA000001 /* XCRemoteSwiftPackageReference \"SwiftVLC\" */ = {{
\t\t\tisa = XCRemoteSwiftPackageReference;
\t\t\trepositoryURL = \"https://github.com/harflabs/SwiftVLC\";
\t\t\trequirement = {{
\t\t\t\tkind = exactVersion;
\t\t\t\tversion = {version};
\t\t\t}};
\t\t}};
/* End XCRemoteSwiftPackageReference section */"""

local_pattern = re.compile(
    r'/\* Begin XCLocalSwiftPackageReference section \*/\n'
    r'\t\tBA000001 /\* XCLocalSwiftPackageReference "\.\." \*/ = \{\n'
    r'\t\t\tisa = XCLocalSwiftPackageReference;\n'
    r'\t\t\trelativePath = (?:"\.\."|\.\.);\n'
    r'\t\t\};\n'
    r'/\* End XCLocalSwiftPackageReference section \*/'
)

remote_pattern = re.compile(
    r'/\* Begin XCRemoteSwiftPackageReference section \*/\n'
    r'\t\tBA000001 /\* XCRemoteSwiftPackageReference "SwiftVLC" \*/ = \{\n'
    r'\t\t\tisa = XCRemoteSwiftPackageReference;\n'
    r'\t\t\trepositoryURL = "https://github.com/harflabs/SwiftVLC";\n'
    r'\t\t\trequirement = \{\n'
    r'\t\t\t\tkind = (?:upToNextMajorVersion|exactVersion);\n'
    # Pre-release identifiers carry letters and hyphens: 1.1.0-beta.1.
    r'\t\t\t\t(?:minimumVersion|version) = [0-9][0-9A-Za-z.\-]*;\n'
    r'\t\t\t\};\n'
    r'\t\t\};\n'
    r'/\* End XCRemoteSwiftPackageReference section \*/'
)

result, n = local_pattern.subn(remote_block, text, count=1)
if n == 0:
    result, n = remote_pattern.subn(remote_block, text, count=1)
    if n == 0:
        print("ERROR: Showcase package reference block not found", file=sys.stderr)
        sys.exit(1)

result = result.replace(
    'BA000001 /* XCLocalSwiftPackageReference ".." */',
    'BA000001 /* XCRemoteSwiftPackageReference "SwiftVLC" */',
)

fd, tmp = tempfile.mkstemp(dir=".", prefix=".SwiftVLCShowcase.", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        f.write(result)
    os.replace(tmp, path)
except Exception:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise
PYEOF
}

validate_release_rewrites() {
  local validation_dir
  local validation_status=0
  validation_dir=$(make_temp_dir)
  cp Package.swift "$validation_dir/Package.swift"
  cp "$SHOWCASE_PROJECT" "$validation_dir/project.pbxproj"

  (
    set -e
    cd "$validation_dir"
    SHOWCASE_PROJECT="$validation_dir/project.pbxproj"
    CHECKSUM="0000000000000000000000000000000000000000000000000000000000000000"
    switch_package_to_release_url
    switch_showcase_to_release_version
    grep -q 'name: "CLibVLC"' Package.swift
    grep -q 'kind = exactVersion;' "$SHOWCASE_PROJECT"

    # Round trip. The release direction alone is not enough: setup-dev.sh has
    # to be able to flip the *result* back to a local reference, and CI runs it
    # on every job. v1.1.0-beta.1 passed this validator and still broke every
    # PR, because setup-dev's version pattern was digits-only and could not
    # match a pre-release identifier.
    python3 - "$SHOWCASE_PROJECT" <<'ROUNDTRIP'
import re
import sys

text = open(sys.argv[1]).read()
# Keep in sync with the same pattern in setup-dev.sh.
remote = re.compile(
    r'/\* Begin XCRemoteSwiftPackageReference section \*/\n'
    r'\t\tBA000001 /\* XCRemoteSwiftPackageReference "SwiftVLC" \*/ = \{\n'
    r'\t\t\tisa = XCRemoteSwiftPackageReference;\n'
    r'\t\t\trepositoryURL = "https://github.com/harflabs/SwiftVLC";\n'
    r'\t\t\trequirement = \{\n'
    r'\t\t\t\tkind = (?:upToNextMajorVersion|exactVersion);\n'
    r'\t\t\t\t(?:minimumVersion|version) = [0-9][0-9A-Za-z.\-]*;\n'
    r'\t\t\t\};\n'
    r'\t\t\};\n'
    r'/\* End XCRemoteSwiftPackageReference section \*/'
)
if not remote.search(text):
    sys.exit(
        "setup-dev.sh could not match the released Showcase reference.\n"
        "  CI flips this back to a local package on every job, so releasing\n"
        "  this would break every pull request."
    )
ROUNDTRIP
    grep -q "version = $VERSION;" "$SHOWCASE_PROJECT"
  ) || validation_status=$?

  rm -rf "$validation_dir"
  return "$validation_status"
}

# Freeze every release input in a script-owned temporary directory before any
# validation that can later authorize qualification, tagging, or upload. The
# prepared candidate normally lives outside git and the Vendor sidecars are
# ignored, so a clean working tree alone cannot prevent either source from
# changing between verification and `gh release create`.
snapshot_release_inputs() {
  local source_xcframework="$XCFW_PATH"
  local source_directory
  source_directory=$(dirname "$source_xcframework")
  local required_files=(
    "libvlc-provenance-a.json"
    "libvlc-provenance.json"
    "libvlc-reproducibility.json"
  )

  if [[ ! -d "$source_xcframework" ]]; then
    echo "Error: $source_xcframework not found." >&2
    echo "  Build it first: ./scripts/build-libvlc.sh --build-root=/absolute/path/to/shared-native-root --clean-build --all" >&2
    exit 1
  fi
  if [[ -n "$CANDIDATE_DIR" ]]; then
    required_files+=("release-candidate.json" "$ZIP_NAME")
  fi
  for required_file in "${required_files[@]}"; do
    if [[ ! -f "$source_directory/$required_file" ]]; then
      echo "Error: complete release input is missing $source_directory/$required_file." >&2
      exit 1
    fi
  done

  WORK_DIR=$(make_temp_dir)
  RELEASE_SNAPSHOT_DIR="$WORK_DIR/release-assets"
  mkdir "$RELEASE_SNAPSHOT_DIR"
  for required_file in "${required_files[@]}"; do
    cp "$source_directory/$required_file" "$RELEASE_SNAPSHOT_DIR/$required_file"
  done

  echo "Snapshotting release XCFramework into a private work directory..."
  "$SCRIPT_DIR/canonical-libvlc-artifact.sh" stage \
    "$source_xcframework" \
    "$RELEASE_SNAPSHOT_DIR/libvlc.xcframework" \
    "$RELEASE_SNAPSHOT_DIR/libvlc-provenance.json"

  XCFW_PATH="$RELEASE_SNAPSHOT_DIR/libvlc.xcframework"
  WORK_XCFW="$XCFW_PATH"
  RELEASE_FIRST_PROVENANCE="$RELEASE_SNAPSHOT_DIR/libvlc-provenance-a.json"
  RELEASE_PROVENANCE="$RELEASE_SNAPSHOT_DIR/libvlc-provenance.json"
  RELEASE_REPRODUCIBILITY="$RELEASE_SNAPSHOT_DIR/libvlc-reproducibility.json"
  if [[ -n "$CANDIDATE_DIR" ]]; then
    CANDIDATE_DIR="$RELEASE_SNAPSHOT_DIR"
    ZIP_PATH="$RELEASE_SNAPSHOT_DIR/$ZIP_NAME"
  fi
}

snapshot_release_inputs

# Keep this helper above preflight: both staging and the last publication
# boundary call it, and Bash resolves functions only after their definition has
# executed.
verify_immutable_releases_enabled() {
  local enabled
  if ! enabled=$(gh api \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2026-03-10' \
      "repos/$REPO/immutable-releases" \
      --jq '.enabled == true' 2>/dev/null) \
      || [[ "$enabled" != "true" ]]; then
    echo "Error: repository immutable releases must be enabled." >&2
    echo "  Enable release immutability in repository Settings, then rerun." >&2
    echo "  This script never changes repository settings." >&2
    return 1
  fi
}

# Publishing is allowed only while the repository's live default-branch
# contract matches the checked-in policy. This is intentionally read-only:
# enabling or repairing the ruleset is a separate, reviewed administration
# action, and a release fails closed when policy or token visibility drifts.
verify_main_governance() {
  local rulesets="$WORK_DIR/main-rulesets.json"
  local ruleset="$WORK_DIR/main-ruleset.json"
  local repository="$WORK_DIR/repository-settings.json"
  local ruleset_id

  if ! gh api \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      "repos/$REPO" > "$repository"; then
    echo "Error: cannot read repository merge settings." >&2
    return 1
  fi
  python3 - "$repository" "$REPO" <<'PY'
import json
import sys

path, repository = sys.argv[1:]
try:
    settings = json.load(open(path))
except (OSError, ValueError) as error:
    sys.exit(f"Error: cannot parse repository settings: {error}")
if settings.get("full_name") != repository or settings.get("default_branch") != "main":
    sys.exit("Error: repository/default-branch identity drifted")
if settings.get("archived") is not False or settings.get("disabled") is not False:
    sys.exit("Error: repository is archived or disabled")
if settings.get("allow_merge_commit") is not True:
    sys.exit("Error: repository must allow the ruleset's merge-commit method")
PY
  if ! gh api \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      "repos/$REPO/rulesets?includes_parents=true&per_page=100" \
      > "$rulesets"; then
    echo "Error: cannot read repository rulesets; Administration:read is required." >&2
    return 1
  fi
  if ! ruleset_id=$(python3 - "$rulesets" "$REPO" <<'PY'
import json
import sys

path, repository = sys.argv[1:]
try:
    rulesets = json.load(open(path))
except (OSError, ValueError) as error:
    sys.exit(f"Error: cannot parse repository rulesets: {error}")
if not isinstance(rulesets, list):
    sys.exit("Error: repository ruleset response is not a list")
matches = [
    item for item in rulesets
    if item.get("name") == "Protect main"
    and item.get("target") == "branch"
    and item.get("source_type") == "Repository"
    and item.get("source") in (None, repository)
]
if len(matches) != 1:
    sys.exit(
        "Error: expected exactly one repository ruleset named 'Protect main'; "
        f"found {len(matches)}"
    )
identifier = matches[0].get("id")
if type(identifier) is not int or identifier <= 0:
    sys.exit("Error: Protect main ruleset has an invalid id")
print(identifier)
PY
  ); then
    return 1
  fi
  if ! gh api \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      "repos/$REPO/rulesets/$ruleset_id" > "$ruleset"; then
    echo "Error: cannot read Protect main ruleset details." >&2
    return 1
  fi
  python3 - "$ruleset" "$REPO" <<'PY'
import json
import sys

path, repository = sys.argv[1:]
try:
    policy = json.load(open(path))
except (OSError, ValueError) as error:
    sys.exit(f"Error: cannot parse Protect main ruleset: {error}")
if (
    policy.get("name") != "Protect main"
    or policy.get("target") != "branch"
    or policy.get("source_type") != "Repository"
    or policy.get("source") not in (None, repository)
    or policy.get("enforcement") != "active"
):
    sys.exit("Error: Protect main ruleset identity/enforcement drifted")
if policy.get("bypass_actors") != []:
    sys.exit("Error: Protect main ruleset must not grant bypass actors")
conditions = policy.get("conditions") or {}
refs = conditions.get("ref_name") or {}
if refs.get("include") != ["~DEFAULT_BRANCH"] or refs.get("exclude") != []:
    sys.exit("Error: Protect main ruleset must target only the default branch")
rules = policy.get("rules")
if not isinstance(rules, list):
    sys.exit("Error: Protect main rules are unavailable")
by_type = {}
for rule in rules:
    kind = rule.get("type") if isinstance(rule, dict) else None
    if kind in by_type:
        sys.exit(f"Error: duplicate Protect main rule: {kind!r}")
    by_type[kind] = rule
for required in ("deletion", "non_fast_forward", "pull_request", "required_status_checks"):
    if required not in by_type:
        sys.exit(f"Error: Protect main ruleset is missing {required}")
pull = by_type["pull_request"].get("parameters") or {}
expected_pull = {
    "required_approving_review_count": 0,
    "dismiss_stale_reviews_on_push": False,
    "require_code_owner_review": False,
    "require_last_push_approval": False,
    "required_review_thread_resolution": True,
}
for key, expected in expected_pull.items():
    actual = pull.get(key)
    if ((type(expected) is bool and actual is not expected) or
            (type(expected) is not bool and actual != expected)):
        sys.exit(f"Error: Protect main pull-request parameter drifted: {key}")
if pull.get("allowed_merge_methods") != ["merge"]:
    sys.exit("Error: Protect main must allow merge commits only")
status = by_type["required_status_checks"].get("parameters") or {}
if status.get("strict_required_status_checks_policy") is not True:
    sys.exit("Error: Protect main required checks must be strict")
if status.get("do_not_enforce_on_create") is not False:
    sys.exit("Error: Protect main checks must be enforced on creation")
checks = status.get("required_status_checks")
if not isinstance(checks, list):
    sys.exit("Error: Protect main required checks are unavailable")
expected_checks = {"lint", "ios-build", "test"}
found = {}
for check in checks:
    if not isinstance(check, dict) or not isinstance(check.get("context"), str):
        sys.exit("Error: Protect main contains an invalid required check")
    context = check["context"]
    if context in found:
        sys.exit(f"Error: Protect main duplicates required check {context}")
    found[context] = check.get("integration_id")
missing = sorted(expected_checks - set(found))
if missing:
    sys.exit("Error: Protect main is missing required checks: " + ", ".join(missing))
for context in expected_checks:
    if found[context] != 15368:
        sys.exit(
            f"Error: Protect main check {context} is not pinned to GitHub Actions"
        )
PY
}

# A prepared candidate may be released from a later main commit when the
# release-significant source digest is unchanged. Its native artifact must still
# prove the exact commit that created the candidate, not merely the current HEAD.
SOURCE_COMMIT=$(git rev-parse HEAD)
EXPECTED_ARTIFACT_SWIFTVLC_REVISION="$SOURCE_COMMIT"
if [[ -n "$CANDIDATE_DIR" ]]; then
  CANDIDATE_SOURCE_COMMIT=$(python3 - "$CANDIDATE_DIR/release-candidate.json" \
    "$VERSION" <<'PY'
import json
import re
import sys


def unique_object(pairs):
    output = {}
    for key, value in pairs:
        if key in output:
            raise ValueError(f"duplicate JSON key: {key!r}")
        output[key] = value
    return output


def reject_constant(value):
    raise ValueError(f"non-finite JSON number: {value}")


path, version = sys.argv[1:3]
try:
    with open(path) as source:
        candidate = json.load(
            source,
            object_pairs_hook=unique_object,
            parse_constant=reject_constant,
        )
except (OSError, ValueError) as error:
    sys.exit(f"Error: cannot read candidate manifest: {error}")
if not isinstance(candidate, dict):
    sys.exit("Error: candidate manifest is not an object")
if candidate.get("version") != version:
    sys.exit("Error: candidate manifest version does not match the release")
revision = candidate.get("sourceCommit")
if not isinstance(revision, str) or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
    sys.exit("Error: candidate has an invalid sourceCommit")
print(revision)
PY
  )
  EXPECTED_ARTIFACT_SWIFTVLC_REVISION="$CANDIDATE_SOURCE_COMMIT"
fi

# ── Preflight ─────────────────────────────────────────────────────────────────

if [[ ! -d "$XCFW_PATH" ]]; then
  echo "Error: $XCFW_PATH not found. Build it first: ./scripts/build-libvlc.sh --all" >&2
  exit 1
fi

# Verify every expected platform slice is present. Missing slices would produce
# a release that breaks at SPM-resolution time for affected platforms.
missing_slices=()
for slice in "${EXPECTED_SLICES[@]}"; do
  if [[ ! -d "$XCFW_PATH/$slice" ]]; then
    missing_slices+=("$slice")
  fi
done
if [[ ${#missing_slices[@]} -gt 0 ]]; then
  echo "Error: xcframework is missing slices: ${missing_slices[*]}" >&2
  echo "  Re-run ./scripts/build-libvlc.sh --all to build all platforms." >&2
  exit 1
fi

# A byte-for-byte member manifest catches unreviewed plugin drift, while the
# semantic contract prevents an intentionally regenerated manifest from
# blessing missing renderer/Chromecast objects or Chromecast on tvOS. Run this
# for betas, prepared candidates, and stable releases alike.
if ! "$SCRIPT_DIR/check-libvlc-manifest.sh" --xcframework "$XCFW_PATH"; then
  echo "Error: libVLC archive members do not satisfy the release contract." >&2
  exit 1
fi

# Release 1.1.0's frozen patch manifest owns extension version 10 plus the 0033
# Apple audio-session lease refinement inherited from version 8. Probe the
# actual linked macOS archive in this checkout before accepting its recorded
# provenance; current headers or provenance metadata alone cannot establish the
# binary's runtime identity.
echo "Verifying exact linked native extension contract..."
if ! "$SCRIPT_DIR/validate-native-extension-contract.sh" \
  --xcframework "$XCFW_PATH" \
  --expected-version 10 \
  --require-apple-audio-session-leases; then
  echo "Error: release artifact does not implement native extension version 10 with Apple audio-session leases." >&2
  echo "  Rebuild it from the current patch manifest before preparing a release." >&2
  exit 1
fi

# Provenance proves which gate implementation was used by the build, but it is
# not a substitute for evaluating the artifact in this release checkout.
# Parse every archive member again and require exact platform/minimum metadata,
# CPU attribution, and bounded section alignment before packaging any bytes.
# Delete the build-time report first so a failed release audit cannot leave an
# older PASS beside the rejected artifact. The parser then records this exact
# release-checkout evaluation, including a structured FAIL report on violations.
MACHO_METADATA_REPORT="$(dirname "$XCFW_PATH")/libvlc-macho-metadata.json"
rm -f "$MACHO_METADATA_REPORT"
echo "Verifying release artifact Mach-O platform metadata and section alignment..."
PYTHONDONTWRITEBYTECODE=1 python3 \
  "$SCRIPT_DIR/validate-libvlc-macho-metadata.py" \
  --xcframework "$XCFW_PATH" \
  --deployment-target "ios=${SWIFTVLC_MIN_IOS}" \
  --deployment-target "tvos=${SWIFTVLC_MIN_TVOS}" \
  --deployment-target "xros=${SWIFTVLC_MIN_VISIONOS}" \
  --deployment-target "macos=${SWIFTVLC_MIN_MACOS}" \
  --deployment-target "catalyst=${SWIFTVLC_MIN_CATALYST}" \
  --json-output "$MACHO_METADATA_REPORT"

# Refuse to publish a debug-configured libVLC. Run-time assertions turn
# malformed-media edge cases into process-killing abort()s (issue #30);
# build-libvlc.sh disables them by default. assert() embeds its stringified
# condition only when NDEBUG is undefined, so finding this hxxx_helper assertion
# text proves the slices were built with --with-asserts by mistake. grep -c
# (not -q) consumes the whole stream, avoiding a pipefail/SIGPIPE false negative.
#
# We match a VLC-specific assert *condition*, not the __assert_rtn symbol:
# contrib libraries (libaom, etc.) reference __assert_rtn even in a correct
# --disable-debug build (~348 refs on macOS), so a symbol-presence check would
# false-positive and block every release. Revalidate this signature whenever
# VLC_HASH is bumped to a revision where hxxx_helper.c changes.
assert_hits=$(strings -a "$XCFW_PATH"/*/libvlc.a 2>/dev/null \
  | grep -c 'i_input_nal_length_size || !hh->i_output_nal_length_size' || true)
if [[ "${assert_hits:-0}" -gt 0 ]]; then
  echo "Error: libVLC slices were built with run-time assertions enabled." >&2
  echo "  Shipping them would re-introduce the issue #30 abort() crash." >&2
  echo "  Rebuild without --with-asserts: ./scripts/build-libvlc.sh --build-root=/absolute/path/to/shared-native-root --clean-build --all" >&2
  exit 1
fi

if ! command -v gh &>/dev/null; then
  echo "Error: GitHub CLI (gh) is required. Install with: brew install gh" >&2
  exit 1
fi

if [[ "$DRY_RUN" == false || -n "$PREPARE_DIR" ]]; then
  if ! gh auth status &>/dev/null; then
    echo "Error: Not authenticated with gh. Run: gh auth login" >&2
    exit 1
  fi

  if [[ -n "$(git status --porcelain)" ]]; then
    echo "Error: the working tree is not clean." >&2
    echo "  Every release input and script must come from a committed checkout." >&2
    git status --short >&2
    exit 1
  fi

  # The engine binary's inputs must be answerable from the repository, so a
  # release refuses to proceed while the patch directory disagrees with its
  # committed manifest — an unlisted patch is exactly the case that would
  # otherwise ship without appearing in release history. Same check the build
  # performs; repeated here because a release can package an xcframework built
  # by an earlier invocation.
  if [[ -n "$(git status --porcelain -- scripts/patches)" ]]; then
    echo "Error: scripts/patches has uncommitted changes." >&2
    echo "  A release must be reproducible from committed sources." >&2
    exit 1
  fi
  if ! MANIFEST_OUTPUT=$("$SCRIPT_DIR/verify-patch-manifest.sh" 2>&1); then
    echo "Error: patch manifest verification failed." >&2
    echo "$MANIFEST_OUTPUT" >&2
    exit 1
  fi

  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  if [[ "$CURRENT_BRANCH" != "main" ]]; then
    echo "Error: refusing to release from branch '$CURRENT_BRANCH'." >&2
    echo "  Release PRs must be staged from an exact local main checkout." >&2
    exit 1
  fi

  # Remote release identities are inspected with ls-remote and fetched into
  # private refs below. Do not update local tag names here: a diagnosed remote
  # tag race must not leave a stale local tag that wedges safe recovery.
  git fetch --quiet origin main
  LOCAL_HEAD=$(git rev-parse HEAD)
  REMOTE_MAIN=$(git rev-parse origin/main)
  if [[ "$LOCAL_HEAD" != "$REMOTE_MAIN" ]]; then
    # After the release PR is merged, a finalize retry may still be sitting on
    # its exact head commit. Fast-forward only when origin/main descends from
    # that commit and has the identical tree (the expected merge-commit shape).
    if [[ "$FINALIZE" == true ]] \
        && git merge-base --is-ancestor "$LOCAL_HEAD" "$REMOTE_MAIN" \
        && git diff --quiet "$LOCAL_HEAD" "$REMOTE_MAIN" --; then
      git merge --quiet --ff-only origin/main
      LOCAL_HEAD=$(git rev-parse HEAD)
    # A stage/finalize retry may resume its one generated release commit.
    # Canonical byte-for-byte reconstruction validates that commit below.
    elif ! git merge-base --is-ancestor "$REMOTE_MAIN" "$LOCAL_HEAD" \
        || [[ $(git rev-list --count "$REMOTE_MAIN..$LOCAL_HEAD") -ne 1 ]]; then
      echo "Error: local main is not an allowed release state." >&2
      echo "  local:       $LOCAL_HEAD" >&2
      echo "  origin/main: $REMOTE_MAIN" >&2
      echo "  Start staging from exact origin/main, or finalize the one release commit." >&2
      exit 1
    fi
  fi

  if [[ "$FINALIZE" != true ]] && git rev-parse "$TAG" &>/dev/null; then
    echo "Error: tag '$TAG' already exists locally." >&2
    echo "  Final SemVer tags are never created during candidate staging." >&2
    exit 1
  fi

  if [[ "$FINALIZE" != true ]] \
      && git ls-remote --exit-code --tags origin "refs/tags/$TAG" &>/dev/null; then
    echo "Error: tag '$TAG' already exists on origin." >&2
    echo "  Never move, delete, or reuse a public release tag; audit this version." >&2
    exit 1
  fi

  if [[ "$FINALIZE" != true ]] \
      && gh release view "$TAG" --repo "$REPO" &>/dev/null; then
    echo "Error: GitHub Release '$TAG' already exists." >&2
    echo "  Audit it with --finalize recovery or choose a new version; never reuse the tag." >&2
    exit 1
  fi

  # Immutable releases are a publication invariant, not an optional UI
  # preference. This read-only preflight intentionally fails both when the
  # setting is disabled and when the token lacks Administration:read.
  if [[ "$DRY_RUN" == false ]]; then
    for required_gh_command in \
      "release edit" \
      "release verify" \
      "release verify-asset"; do
      if ! gh $required_gh_command --help >/dev/null 2>&1; then
        echo "Error: installed GitHub CLI lacks 'gh $required_gh_command'." >&2
        echo "  Upgrade gh before staging; these commands are release invariants." >&2
        exit 1
      fi
    done
    verify_main_governance
    verify_immutable_releases_enabled
  fi
fi

echo "Validating release manifest rewrites..."
validate_release_rewrites
echo "Release rewrite validation passed."

# These two files contain narrowly validated release-managed references. The
# digest normalizes only those fields, so local Showcase wiring and the final
# URL/version rewrite describe the same runtime source while every other
# tracked byte remains qualification-significant.
RELEASE_SOURCE_DIGEST=$("$SCRIPT_DIR/release-source-digest.py" "$VERSION")
QUALIFICATION_MATRIX_CHECKSUM=$(shasum -a 256 \
  "$SCRIPT_DIR/qualification/matrix.json" | cut -d' ' -f1)
if [[ ! -f "$FEATURE_MANIFEST" ]]; then
  echo "Error: release feature policy is missing: $FEATURE_MANIFEST" >&2
  exit 1
fi
FEATURE_MANIFEST_CHECKSUM=$(shasum -a 256 "$FEATURE_MANIFEST" | cut -d' ' -f1)

# ── Artifact freshness ────────────────────────────────────────────────────────
#
# Everything below packages whatever xcframework is in Vendor/. Nothing so far
# has established that it was built from the sources this release will claim,
# so a binary produced months ago against a different pin or patch set would be
# published as new and nothing would notice (#97, second criterion).
#
# The build records its complete inputs and every slice checksum beside the
# artifact. A separate proof records two byte-identical clean builds. Both have
# to match the exact tree entering the release pipeline.
verify_artifact_provenance() {
  local expected_swiftvlc_revision=$1
  # Derived from XCFW_PATH rather than hard-coded, so the provenance always
  # describes the artifact actually being packaged even if Vendor/ moves.
  local provenance="$(dirname "$XCFW_PATH")/libvlc-provenance.json"
  local first_provenance="$(dirname "$XCFW_PATH")/libvlc-provenance-a.json"
  local reproducibility="$(dirname "$XCFW_PATH")/libvlc-reproducibility.json"

  if [[ ! -f "$first_provenance" || ! -f "$provenance" || \
      ! -f "$reproducibility" ]]; then
    echo "Error: complete provenance is missing beside $XCFW_PATH." >&2
    echo "  Required: $first_provenance" >&2
    echo "  Required: $provenance" >&2
    echo "  Required: $reproducibility" >&2
    echo "  $XCFW_PATH was built before provenance was recorded, so its inputs" >&2
    echo "  cannot be established. Rebuild with:" >&2
    echo "    ./scripts/build-libvlc.sh --build-root=/absolute/path/to/shared-native-root --clean-build --all" >&2
    return 1
  fi

  local current_pin current_manifest
  current_pin=$(sed -n 's/^VLC_HASH="\(.*\)"$/\1/p' "$SCRIPT_DIR/build-libvlc.sh" | head -1)
  current_manifest=$(shasum -a 256 "$SCRIPT_DIR/patches/manifest.sha256" | cut -d' ' -f1)

  if ! python3 "$SCRIPT_DIR/libvlc-provenance.py" verify \
    --provenance "$provenance" \
    --xcframework "$XCFW_PATH" \
    --swiftvlc-revision "$expected_swiftvlc_revision" \
    --pinned-revision "$current_pin" \
    --patch-manifest "$SCRIPT_DIR/patches/manifest.sha256" \
    --build-configuration-file "build-libvlc.sh=$SCRIPT_DIR/build-libvlc.sh" \
    --build-configuration-file "detach-managed-build-directory.py=$SCRIPT_DIR/detach-managed-build-directory.py" \
    --build-configuration-file "fix-duplicate-symbols.sh=$SCRIPT_DIR/fix-duplicate-symbols.sh" \
    --build-configuration-file "validate-libvlc-macho-metadata.py=$SCRIPT_DIR/validate-libvlc-macho-metadata.py" \
    --build-configuration-file "verify-libvlc-build-paths.py=$SCRIPT_DIR/verify-libvlc-build-paths.py" \
    --build-configuration-file "validate-apple-assembly-metadata-patch.sh=$SCRIPT_DIR/validate-apple-assembly-metadata-patch.sh" \
    --build-configuration-file "validate-aom-nasm3-detection.sh=$SCRIPT_DIR/validate-aom-nasm3-detection.sh" \
    --build-configuration-file "validate-headless-vout-teardown.sh=$SCRIPT_DIR/validate-headless-vout-teardown.sh" \
    --build-configuration-file "validate-chromecast-load-transition.sh=$SCRIPT_DIR/validate-chromecast-load-transition.sh" \
    --build-configuration-file "validate-native-extension-contract.sh=$SCRIPT_DIR/validate-native-extension-contract.sh" \
    --build-configuration-file "native-extension-version-probe.c=$SCRIPT_DIR/patches/validation/native-extension-version-probe.c" \
    --build-configuration-file "pip_extension_version.py=$SCRIPT_DIR/patches/validation/pip_extension_version.py" \
    --build-configuration-file "validate-post-pin-stability.sh=$SCRIPT_DIR/validate-post-pin-stability.sh" \
    --build-configuration-file "native-validator-assets.sha256=$SCRIPT_DIR/native-validator-assets.sha256" \
    --build-configuration-file "verify-native-validator-assets.py=$SCRIPT_DIR/verify-native-validator-assets.py"; then
    echo "  Rebuild so every shipped slice and input has current provenance:" >&2
    echo "    ./scripts/build-libvlc.sh --build-root=/absolute/path/to/shared-native-root --clean-build --all" >&2
    return 1
  fi
  if ! python3 "$SCRIPT_DIR/libvlc-provenance.py" verify-proof \
    --proof "$reproducibility" \
    --first-provenance "$first_provenance" \
    --second-provenance "$provenance" \
    --current-provenance "$provenance" \
    --xcframework "$XCFW_PATH"; then
    echo "  Retain both clean-build provenance records and compare both actual" >&2
    echo "  XCFrameworks before release." >&2
    return 1
  fi

  echo "Artifact provenance verified: pin $current_pin, patch manifest ${current_manifest:0:12}…"
}

if ! verify_artifact_provenance "$EXPECTED_ARTIFACT_SWIFTVLC_REVISION"; then
  exit 1
fi

# ── Prepare or load immutable candidate ───────────────────────────────────────

if [[ -n "$CANDIDATE_DIR" ]]; then
  CANDIDATE_MANIFEST="$CANDIDATE_DIR/release-candidate.json"
  ZIP_PATH="$CANDIDATE_DIR/$ZIP_NAME"
  WORK_XCFW="$XCFW_PATH"

  RELEASE_FIRST_PROVENANCE="$CANDIDATE_DIR/libvlc-provenance-a.json"
  RELEASE_PROVENANCE="$CANDIDATE_DIR/libvlc-provenance.json"
  RELEASE_REPRODUCIBILITY="$CANDIDATE_DIR/libvlc-reproducibility.json"
  for candidate_file in "$CANDIDATE_MANIFEST" "$ZIP_PATH" \
    "$RELEASE_FIRST_PROVENANCE" "$RELEASE_PROVENANCE" \
    "$RELEASE_REPRODUCIBILITY"; do
    if [[ ! -f "$candidate_file" ]]; then
      echo "Error: prepared candidate is missing $candidate_file." >&2
      exit 1
    fi
  done

  echo "Verifying immutable release candidate..."
  CANDIDATE_VALUES=$(python3 - "$CANDIDATE_MANIFEST" "$VERSION" <<'PY'
import json
import re
import sys


def unique_object(pairs):
    output = {}
    for key, value in pairs:
        if key in output:
            raise ValueError(f"duplicate JSON key: {key!r}")
        output[key] = value
    return output


def reject_constant(value):
    raise ValueError(f"non-finite JSON number: {value}")


path, version = sys.argv[1:3]
try:
    with open(path) as source:
        candidate = json.load(
            source,
            object_pairs_hook=unique_object,
            parse_constant=reject_constant,
        )
except (OSError, ValueError) as error:
    sys.exit(f"Error: cannot read candidate manifest: {error}")
if not isinstance(candidate, dict):
    sys.exit("Error: candidate manifest is not an object")

required = {
    "version",
    "artifactDigestAlgorithm",
    "artifactDigest",
    "zipChecksum",
    "firstProvenanceChecksum",
    "provenanceChecksum",
    "reproducibilityChecksum",
    "sourceCommit",
    "releaseSourceDigestAlgorithm",
    "releaseSourceDigest",
    "qualificationMatrixChecksum",
    "featureManifestChecksum",
}
missing = sorted(required - candidate.keys())
if missing:
    sys.exit(f"Error: candidate manifest is missing: {', '.join(missing)}")
unexpected = sorted(candidate.keys() - required)
if unexpected:
    sys.exit(f"Error: candidate manifest has unsupported fields: {', '.join(unexpected)}")
if candidate["version"] != version:
    sys.exit(
        f"Error: candidate is for {candidate['version']!r}, not {version!r}"
    )
if candidate["artifactDigestAlgorithm"] != "swiftvlc-tree-v1":
    sys.exit("Error: candidate uses an unsupported artifact digest algorithm")
if candidate["releaseSourceDigestAlgorithm"] != "swiftvlc-git-tree-v1":
    sys.exit("Error: candidate uses an unsupported release source digest algorithm")
for field, length in (
    ("sourceCommit", 40),
    ("artifactDigest", 64),
    ("zipChecksum", 64),
    ("firstProvenanceChecksum", 64),
    ("provenanceChecksum", 64),
    ("reproducibilityChecksum", 64),
    ("releaseSourceDigest", 64),
    ("qualificationMatrixChecksum", 64),
    ("featureManifestChecksum", 64),
):
    value = candidate[field]
    if not isinstance(value, str) or not re.fullmatch(
        rf"[0-9a-f]{{{length}}}", value
    ):
        sys.exit(f"Error: candidate has an invalid {field}")
print(candidate["artifactDigest"])
print(candidate["zipChecksum"])
print(candidate["firstProvenanceChecksum"])
print(candidate["provenanceChecksum"])
print(candidate["reproducibilityChecksum"])
print(candidate["sourceCommit"])
print(candidate["releaseSourceDigestAlgorithm"])
print(candidate["releaseSourceDigest"])
print(candidate["qualificationMatrixChecksum"])
print(candidate["featureManifestChecksum"])
PY
)
  CANDIDATE_TREE_DIGEST=$(printf '%s\n' "$CANDIDATE_VALUES" | sed -n '1p')
  EXPECTED_ZIP_CHECKSUM=$(printf '%s\n' "$CANDIDATE_VALUES" | sed -n '2p')
  EXPECTED_FIRST_PROVENANCE_CHECKSUM=$(printf '%s\n' \
    "$CANDIDATE_VALUES" | sed -n '3p')
  EXPECTED_PROVENANCE_CHECKSUM=$(printf '%s\n' "$CANDIDATE_VALUES" | sed -n '4p')
  EXPECTED_REPRODUCIBILITY_CHECKSUM=$(printf '%s\n' "$CANDIDATE_VALUES" | sed -n '5p')
  CANDIDATE_SOURCE_COMMIT=$(printf '%s\n' "$CANDIDATE_VALUES" | sed -n '6p')
  CANDIDATE_SOURCE_DIGEST_ALGORITHM=$(printf '%s\n' "$CANDIDATE_VALUES" | sed -n '7p')
  CANDIDATE_SOURCE_DIGEST=$(printf '%s\n' "$CANDIDATE_VALUES" | sed -n '8p')
  CANDIDATE_MATRIX_CHECKSUM=$(printf '%s\n' "$CANDIDATE_VALUES" | sed -n '9p')
  CANDIDATE_FEATURE_MANIFEST_CHECKSUM=$(printf '%s\n' \
    "$CANDIDATE_VALUES" | sed -n '10p')

  ACTUAL_TREE_DIGEST=$("$SCRIPT_DIR/artifact-tree-digest.py" "$WORK_XCFW")
  CHECKSUM=$(swift package compute-checksum "$ZIP_PATH")
  ACTUAL_FIRST_PROVENANCE_CHECKSUM=$(shasum -a 256 \
    "$RELEASE_FIRST_PROVENANCE" | cut -d' ' -f1)
  ACTUAL_PROVENANCE_CHECKSUM=$(shasum -a 256 \
    "$RELEASE_PROVENANCE" | cut -d' ' -f1)
  ACTUAL_REPRODUCIBILITY_CHECKSUM=$(shasum -a 256 \
    "$RELEASE_REPRODUCIBILITY" | cut -d' ' -f1)
  if [[ "$ACTUAL_TREE_DIGEST" != "$CANDIDATE_TREE_DIGEST" ]]; then
    echo "Error: prepared XCFramework changed after candidate creation." >&2
    exit 1
  fi
  if [[ "$CHECKSUM" != "$EXPECTED_ZIP_CHECKSUM" ]]; then
    echo "Error: prepared zip changed after candidate creation." >&2
    exit 1
  fi
  if [[ "$ACTUAL_FIRST_PROVENANCE_CHECKSUM" != \
      "$EXPECTED_FIRST_PROVENANCE_CHECKSUM" ]]; then
    echo "Error: prepared first-build provenance changed after candidate creation." >&2
    exit 1
  fi
  if [[ "$ACTUAL_PROVENANCE_CHECKSUM" != "$EXPECTED_PROVENANCE_CHECKSUM" ]]; then
    echo "Error: prepared provenance changed after candidate creation." >&2
    exit 1
  fi
  if [[ "$ACTUAL_REPRODUCIBILITY_CHECKSUM" != "$EXPECTED_REPRODUCIBILITY_CHECKSUM" ]]; then
    echo "Error: prepared reproducibility proof changed after candidate creation." >&2
    exit 1
  fi
  if [[ "$RELEASE_SOURCE_DIGEST" != "$CANDIDATE_SOURCE_DIGEST" ]]; then
    echo "Error: release-significant Swift source changed after candidate creation." >&2
    echo "  candidate: $CANDIDATE_SOURCE_DIGEST" >&2
    echo "  current:   $RELEASE_SOURCE_DIGEST" >&2
    exit 1
  fi
  if [[ "$QUALIFICATION_MATRIX_CHECKSUM" != "$CANDIDATE_MATRIX_CHECKSUM" ]]; then
    echo "Error: the qualification matrix changed after candidate creation." >&2
    exit 1
  fi
  if [[ "$FEATURE_MANIFEST_CHECKSUM" != "$CANDIDATE_FEATURE_MANIFEST_CHECKSUM" ]]; then
    echo "Error: the release feature policy changed after candidate creation." >&2
    exit 1
  fi
  if ! git cat-file -e "${CANDIDATE_SOURCE_COMMIT}^{commit}" 2>/dev/null || \
      ! git merge-base --is-ancestor "$CANDIDATE_SOURCE_COMMIT" HEAD; then
    echo "Error: candidate source commit is not an ancestor of the release checkout." >&2
    exit 1
  fi

  # Prove the zip expands to the qualified tree; matching independent digests
  # is stronger than trusting that the side-by-side directory was the source.
  ditto -x -k "$ZIP_PATH" "$WORK_DIR/unpacked"
  PACKED_TREE_DIGEST=$("$SCRIPT_DIR/artifact-tree-digest.py" \
    "$WORK_DIR/unpacked/libvlc.xcframework")
  if [[ "$PACKED_TREE_DIGEST" != "$CANDIDATE_TREE_DIGEST" ]]; then
    echo "Error: prepared zip does not contain the qualified XCFramework." >&2
    exit 1
  fi
else
  echo "Verifying duplicate symbols in release-ready libraries..."
  "$SCRIPT_DIR/fix-duplicate-symbols.sh" --verify "$WORK_XCFW"

  python3 "$SCRIPT_DIR/libvlc-provenance.py" verify-proof \
    --proof "$RELEASE_REPRODUCIBILITY" \
    --first-provenance "$RELEASE_FIRST_PROVENANCE" \
    --second-provenance "$RELEASE_PROVENANCE" \
    --current-provenance "$RELEASE_PROVENANCE" \
    --xcframework "$WORK_XCFW"

  echo "Creating zip..."
  ZIP_PATH="$RELEASE_SNAPSHOT_DIR/$ZIP_NAME"
  "$SCRIPT_DIR/canonical-libvlc-artifact.sh" archive \
    "$WORK_XCFW" "$ZIP_PATH" "$RELEASE_PROVENANCE"

  echo "Computing checksum..."
  CHECKSUM=$(swift package compute-checksum "$ZIP_PATH")
fi

ZIP_SIZE=$(stat -f%z "$ZIP_PATH")
ZIP_SIZE_MB=$((ZIP_SIZE / 1024 / 1024))
echo "  Zip size: ${ZIP_SIZE_MB} MB"
echo "  SHA256: $CHECKSUM"

if [[ "$ZIP_SIZE" -ge "$MAX_SIZE" ]]; then
  echo "Error: Zip is ${ZIP_SIZE_MB} MB — exceeds GitHub's 2 GB limit." >&2
  echo "  The xcframework may need further size reduction." >&2
  exit 1
fi

if [[ -n "$PREPARE_DIR" ]]; then
  if [[ -e "$PREPARE_DIR" ]]; then
    echo "Error: prepare destination already exists: $PREPARE_DIR" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$PREPARE_DIR")"
  mkdir "$PREPARE_DIR"
  "$SCRIPT_DIR/canonical-libvlc-artifact.sh" stage \
    "$WORK_XCFW" "$PREPARE_DIR/libvlc.xcframework" "$RELEASE_PROVENANCE"
  cp "$ZIP_PATH" "$PREPARE_DIR/$ZIP_NAME"
  cp "$RELEASE_FIRST_PROVENANCE" "$PREPARE_DIR/libvlc-provenance-a.json"
  cp "$RELEASE_PROVENANCE" "$PREPARE_DIR/libvlc-provenance.json"
  cp "$RELEASE_REPRODUCIBILITY" "$PREPARE_DIR/libvlc-reproducibility.json"

  CANDIDATE_TREE_DIGEST=$("$SCRIPT_DIR/artifact-tree-digest.py" "$WORK_XCFW")
  FIRST_PROVENANCE_CHECKSUM=$(shasum -a 256 \
    "$PREPARE_DIR/libvlc-provenance-a.json" | cut -d' ' -f1)
  PROVENANCE_CHECKSUM=$(shasum -a 256 \
    "$PREPARE_DIR/libvlc-provenance.json" | cut -d' ' -f1)
  REPRODUCIBILITY_CHECKSUM=$(shasum -a 256 \
    "$PREPARE_DIR/libvlc-reproducibility.json" | cut -d' ' -f1)
  VERSION="$VERSION" \
    CANDIDATE_TREE_DIGEST="$CANDIDATE_TREE_DIGEST" \
    CHECKSUM="$CHECKSUM" \
    FIRST_PROVENANCE_CHECKSUM="$FIRST_PROVENANCE_CHECKSUM" \
    PROVENANCE_CHECKSUM="$PROVENANCE_CHECKSUM" \
    REPRODUCIBILITY_CHECKSUM="$REPRODUCIBILITY_CHECKSUM" \
    SOURCE_COMMIT="$SOURCE_COMMIT" \
    RELEASE_SOURCE_DIGEST="$RELEASE_SOURCE_DIGEST" \
    QUALIFICATION_MATRIX_CHECKSUM="$QUALIFICATION_MATRIX_CHECKSUM" \
    FEATURE_MANIFEST_CHECKSUM="$FEATURE_MANIFEST_CHECKSUM" \
    python3 - "$PREPARE_DIR/release-candidate.json" <<'PY'
import json
import os
import sys

candidate = {
    "version": os.environ["VERSION"],
    "artifactDigestAlgorithm": "swiftvlc-tree-v1",
    "artifactDigest": os.environ["CANDIDATE_TREE_DIGEST"],
    "zipChecksum": os.environ["CHECKSUM"],
    "firstProvenanceChecksum": os.environ["FIRST_PROVENANCE_CHECKSUM"],
    "provenanceChecksum": os.environ["PROVENANCE_CHECKSUM"],
    "reproducibilityChecksum": os.environ["REPRODUCIBILITY_CHECKSUM"],
    "sourceCommit": os.environ["SOURCE_COMMIT"],
    "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
    "releaseSourceDigest": os.environ["RELEASE_SOURCE_DIGEST"],
    "qualificationMatrixChecksum": os.environ["QUALIFICATION_MATRIX_CHECKSUM"],
    "featureManifestChecksum": os.environ["FEATURE_MANIFEST_CHECKSUM"],
}
with open(sys.argv[1], "w") as output:
    json.dump(candidate, output, indent=2, sort_keys=True)
    output.write("\n")
PY
  echo "Prepared immutable candidate at $PREPARE_DIR"
fi

# Device qualification must describe the exact provenance-covered tree that the
# zip contains. Preparation intentionally precedes qualification; stable
# publishing later requires --candidate and refuses to rebuild or mutate bytes.
if [[ -n "$PREPARE_DIR" ]]; then
  echo "Candidate prepared but not yet device-qualified."
elif [[ "$UNQUALIFIED" == true ]]; then
  echo "WARNING: releasing WITHOUT device qualification."
  echo "  Publishing as a pre-release. It must not be described as qualified,"
  echo "  and the device/feature gates in scripts/qualification remain owed."
elif [[ "$DRY_RUN" == true ]]; then
  echo "Dry run only; no device qualification is claimed."
else
  if ! SWIFTVLC_CANDIDATE_SOURCE_COMMIT="$CANDIDATE_SOURCE_COMMIT" \
    SWIFTVLC_CANDIDATE_SOURCE_DIGEST="$CANDIDATE_SOURCE_DIGEST" \
    SWIFTVLC_CANDIDATE_MATRIX_CHECKSUM="$CANDIDATE_MATRIX_CHECKSUM" \
    SWIFTVLC_CANDIDATE_FEATURE_MANIFEST_CHECKSUM="$CANDIDATE_FEATURE_MANIFEST_CHECKSUM" \
    SWIFTVLC_FEATURE_MANIFEST="$FEATURE_MANIFEST" \
    "$SCRIPT_DIR/check-qualification.sh" "$VERSION" "$WORK_XCFW"; then
    echo "" >&2
    echo "  Qualify the prepared candidate before publishing stable." >&2
    exit 1
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== Release Summary ==="
echo "  Version:  $VERSION ($TAG)"
echo "  Zip:      ${ZIP_SIZE_MB} MB"
echo "  Checksum: $CHECKSUM"
echo "  URL:      $RELEASE_URL"

if [[ "$DRY_RUN" == true ]]; then
  echo ""
  echo "Dry run complete. No changes pushed."
  echo ""
  echo "Package.swift snippet:"
  echo "  .binaryTarget("
  echo "    name: \"libvlc\","
  echo "    url: \"$RELEASE_URL\","
  echo "    checksum: \"$CHECKSUM\""
  echo "  )"
  echo ""
  echo "Showcase package requirement:"
  echo "  kind = exactVersion"
  echo "  version = $VERSION"
  exit 0
fi

# ── Staged publication and exact-commit CI gate ────────────────────────────
#
# Candidate staging deliberately exposes no SemVer tag. SwiftPM discovers
# versions from Git tags, independently of whether a GitHub Release is a draft,
# so the only pre-CI tag is `swiftvlc-candidate-vX.Y.Z-<full commit SHA>`.
# The draft is renamed to the final tag and published in one GitHub release
# update. The final SemVer tag therefore becomes visible only with public,
# immutable, already-qualified assets.

RELEASE_ASSETS=(
  "$ZIP_PATH"
  "$RELEASE_FIRST_PROVENANCE"
  "$RELEASE_PROVENANCE"
  "$RELEASE_REPRODUCIBILITY"
  "$CANDIDATE_DIR/release-candidate.json"
)
RELEASE_FLAGS=(--draft)
QUALIFICATION_NOTE=""
if [[ "$UNQUALIFIED" == true ]]; then
  RELEASE_FLAGS+=(--prerelease)
  QUALIFICATION_NOTE=$'\n> **Not release-qualified.** The physical-device matrix and required feature policy in `scripts/qualification` have not both been satisfied for this artifact. Published as a pre-release for that reason.\n'
fi
CANDIDATE_RELEASE_TITLE="SwiftVLC $TAG candidate"
CANDIDATE_RELEASE_NOTES=""
FINAL_RELEASE_TITLE="SwiftVLC $TAG"
FINAL_RELEASE_NOTES=""

remote_ref_sha() {
  local ref=$1
  git ls-remote origin "$ref" | awk -v expected="$ref" \
    '$2 == expected { print $1; exit }'
}

verify_remote_ref() {
  local ref=$1
  local expected=$2
  local actual
  actual=$(remote_ref_sha "$ref")
  if [[ "$actual" != "$expected" ]]; then
    echo "Error: remote $ref does not resolve to the release commit." >&2
    echo "  expected: $expected" >&2
    echo "  actual:   ${actual:-missing}" >&2
    return 1
  fi
}

verify_remote_ref_absent() {
  local ref=$1
  local actual
  actual=$(remote_ref_sha "$ref")
  if [[ -n "$actual" ]]; then
    echo "Error: remote $ref unexpectedly exists at $actual." >&2
    return 1
  fi
}

rollback_reserved_final_tag() {
  local actual
  actual=$(remote_ref_sha "refs/tags/$TAG")
  if [[ -z "$actual" ]]; then
    return 0
  fi
  if [[ "$actual" != "$STAGED_COMMIT" ]]; then
    echo "Error: cannot roll back $TAG because its identity changed." >&2
    return 1
  fi
  git push \
    --force-with-lease="refs/tags/$TAG:$STAGED_COMMIT" \
    origin ":refs/tags/$TAG"
  verify_remote_ref_absent "refs/tags/$TAG"
}

candidate_tag_for_commit() {
  local commit=$1
  printf 'swiftvlc-candidate-%s-%s\n' "$TAG" "$commit"
}

# Reconstruct the only two generated files from the release commit's parent.
# A checksum-looking Package.swift is insufficient: this catches unrelated or
# malicious edits hidden in either file, including changes normalized out of
# release-source-digest.py.
canonical_release_commit_matches() {
  local commit=$1
  local parent
  local reconstruction
  local actual
  local changed
  local expected_changed

  if [[ $(git rev-list --parents -n 1 "$commit" | awk '{ print NF }') -ne 2 ]]; then
    echo "Error: release commit must have exactly one parent." >&2
    return 1
  fi
  parent=$(git rev-parse "${commit}^")
  changed=$(git diff --name-only "$parent" "$commit" | LC_ALL=C sort)
  expected_changed=$(printf '%s\n%s\n' Package.swift "$SHOWCASE_PROJECT" \
    | LC_ALL=C sort)
  if [[ "$changed" != "$expected_changed" ]]; then
    echo "Error: staged release commit changes files outside the canonical rewrite." >&2
    echo "$changed" >&2
    return 1
  fi

  reconstruction=$(make_temp_dir)
  mkdir -p "$reconstruction/$(dirname "$SHOWCASE_PROJECT")"
  git show "$parent:Package.swift" > "$reconstruction/Package.swift"
  git show "$parent:$SHOWCASE_PROJECT" > "$reconstruction/$SHOWCASE_PROJECT"
  (
    cd "$reconstruction"
    SHOWCASE_PROJECT="$SHOWCASE_PROJECT"
    switch_package_to_release_url
    switch_showcase_to_release_version
  )

  actual=$(make_temp_dir)
  mkdir -p "$actual/$(dirname "$SHOWCASE_PROJECT")"
  git show "$commit:Package.swift" > "$actual/Package.swift"
  git show "$commit:$SHOWCASE_PROJECT" > "$actual/$SHOWCASE_PROJECT"
  if ! cmp -s "$reconstruction/Package.swift" "$actual/Package.swift" \
      || ! cmp -s "$reconstruction/$SHOWCASE_PROJECT" \
        "$actual/$SHOWCASE_PROJECT"; then
    echo "Error: staged release files are not the exact canonical rewrite." >&2
    rm -rf "$reconstruction" "$actual"
    return 1
  fi
  rm -rf "$reconstruction" "$actual"
}

verify_github_release() {
  local release_tag=$1
  local visibility=$2
  local immutable=$3
  local url_tag=$4
  local expected_commit=$5
  local expected_name=$6
  local expected_body=$7
  local metadata="$WORK_DIR/github-release-${release_tag}.json"

  gh release view "$release_tag" --repo "$REPO" \
    --json url,tagName,targetCommitish,isDraft,isImmutable,isPrerelease,name,body,assets \
    > "$metadata"
  EXPECTED_PRERELEASE="$UNQUALIFIED" \
  EXPECTED_RELEASE_NAME="$expected_name" \
  EXPECTED_RELEASE_BODY="$expected_body" \
  python3 - \
    "$metadata" "$release_tag" "$visibility" "$immutable" "$url_tag" \
    "$REPO" "$expected_commit" "${RELEASE_ASSETS[@]}" <<'PY'
import hashlib
import json
import os
import re
import sys
from pathlib import Path

(
    metadata_path,
    release_tag,
    visibility,
    immutable,
    url_tag,
    repository,
    commit,
    *asset_paths,
) = sys.argv[1:]
release = json.load(open(metadata_path))
if release.get("tagName") != release_tag:
    sys.exit(f"Error: GitHub release tag drifted: {release.get('tagName')!r}")
if release.get("targetCommitish") != commit:
    sys.exit("Error: GitHub release target does not equal the release commit")
if bool(release.get("isDraft")) != (visibility == "draft"):
    sys.exit(f"Error: GitHub release is not {visibility}")
if bool(release.get("isImmutable")) != (immutable == "immutable"):
    sys.exit(f"Error: GitHub release immutable state is not {immutable}")
expected_prerelease = os.environ["EXPECTED_PRERELEASE"] == "true"
if bool(release.get("isPrerelease")) != expected_prerelease:
    sys.exit("Error: GitHub pre-release classification drifted")
if release.get("name") != os.environ["EXPECTED_RELEASE_NAME"]:
    sys.exit("Error: GitHub release title drifted")
if release.get("body") != os.environ["EXPECTED_RELEASE_BODY"]:
    sys.exit("Error: GitHub release notes drifted")

release_url = release.get("url")
release_url_prefix = f"https://github.com/{repository}/releases/tag/"
if visibility == "draft":
    if not isinstance(release_url, str) or not release_url.startswith(
        release_url_prefix
    ):
        sys.exit("Error: draft release URL does not belong to the exact repository")
    download_ref = release_url[len(release_url_prefix) :]
    if re.fullmatch(r"untagged-[0-9A-Za-z._-]+", download_ref) is None:
        sys.exit("Error: draft release URL has an unsafe GitHub locator")
else:
    expected_release_url = f"{release_url_prefix}{url_tag}"
    if release_url != expected_release_url:
        sys.exit("Error: published release URL does not match its exact tag")
    download_ref = url_tag

expected = {Path(path).name: Path(path) for path in asset_paths}
actual_assets = release.get("assets")
if not isinstance(actual_assets, list):
    sys.exit("Error: GitHub release assets are unavailable")
actual = {}
for asset in actual_assets:
    name = asset.get("name")
    if name in actual:
        sys.exit(f"Error: duplicate GitHub release asset: {name}")
    actual[name] = asset
if set(actual) != set(expected):
    sys.exit(
        "Error: GitHub release asset set drifted\n"
        f"  expected: {sorted(expected)}\n"
        f"  actual:   {sorted(actual)}"
    )
for name, path in expected.items():
    asset = actual[name]
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if asset.get("state") != "uploaded":
        sys.exit(f"Error: GitHub release asset is incomplete: {name}")
    if asset.get("digest") != f"sha256:{digest}":
        sys.exit(f"Error: GitHub release asset digest drifted: {name}")
    expected_url = (
        f"https://github.com/{repository}/releases/download/{download_ref}/{name}"
    )
    if asset.get("url") != expected_url:
        sys.exit(f"Error: GitHub release asset URL drifted: {name}")
PY
}

verify_candidate_release_header() {
  local metadata="$WORK_DIR/candidate-release-header.json"
  gh release view "$CANDIDATE_TAG" --repo "$REPO" \
    --json tagName,targetCommitish,isDraft,isImmutable,isPrerelease,name,body,assets \
    > "$metadata"
  EXPECTED_PRERELEASE="$UNQUALIFIED" \
  EXPECTED_RELEASE_NAME="$CANDIDATE_RELEASE_TITLE" \
  EXPECTED_RELEASE_BODY="$CANDIDATE_RELEASE_NOTES" \
  python3 - \
    "$metadata" "$CANDIDATE_TAG" "$STAGED_COMMIT" "${RELEASE_ASSETS[@]}" <<'PY'
import json
import os
import sys
from pathlib import Path

metadata_path, tag, commit, *asset_paths = sys.argv[1:]
release = json.load(open(metadata_path))
if release.get("tagName") != tag:
    sys.exit("Error: candidate release tag drifted")
if release.get("targetCommitish") != commit:
    sys.exit("Error: candidate release target drifted")
if release.get("isDraft") is not True or release.get("isImmutable") is True:
    sys.exit("Error: candidate release must remain a mutable draft")
if bool(release.get("isPrerelease")) != (
    os.environ["EXPECTED_PRERELEASE"] == "true"
):
    sys.exit("Error: candidate pre-release classification drifted")
if release.get("name") != os.environ["EXPECTED_RELEASE_NAME"]:
    sys.exit("Error: candidate release title drifted")
if release.get("body") != os.environ["EXPECTED_RELEASE_BODY"]:
    sys.exit("Error: candidate release notes drifted")

expected_names = {Path(path).name for path in asset_paths}
seen = set()
for asset in release.get("assets", []):
    name = asset.get("name")
    if name in seen:
        sys.exit(f"Error: duplicate candidate asset: {name}")
    seen.add(name)
    if name not in expected_names:
        sys.exit(f"Error: unexpected candidate asset: {name}")
PY
}

candidate_asset_status() {
  local asset_path=$1
  local metadata="$WORK_DIR/candidate-assets.json"
  gh release view "$CANDIDATE_TAG" --repo "$REPO" \
    --json url,tagName,targetCommitish,isDraft,isImmutable,isPrerelease,assets \
    > "$metadata"
  python3 - "$metadata" "$asset_path" "$REPO" "$CANDIDATE_TAG" \
    "$STAGED_COMMIT" "$UNQUALIFIED" <<'PY'
import hashlib
import json
import re
import sys
from pathlib import Path

metadata_path, asset_path, repository, tag, commit, prerelease = sys.argv[1:]
path = Path(asset_path)
release = json.load(open(metadata_path))
if release.get("tagName") != tag:
    raise SystemExit("Error: candidate release tag drifted")
if release.get("targetCommitish") != commit:
    raise SystemExit("Error: candidate release target drifted")
if release.get("isDraft") is not True or release.get("isImmutable") is not False:
    raise SystemExit("Error: candidate release must remain a mutable draft")
if bool(release.get("isPrerelease")) != (prerelease == "true"):
    raise SystemExit("Error: candidate pre-release classification drifted")
release_url_prefix = f"https://github.com/{repository}/releases/tag/"
release_url = release.get("url")
if not isinstance(release_url, str) or not release_url.startswith(
    release_url_prefix
):
    raise SystemExit("Error: draft release URL does not belong to the exact repository")
download_ref = release_url[len(release_url_prefix) :]
if re.fullmatch(r"untagged-[0-9A-Za-z._-]+", download_ref) is None:
    raise SystemExit("Error: draft release URL has an unsafe GitHub locator")
matches = [asset for asset in release.get("assets", []) if asset.get("name") == path.name]
if not matches:
    print("missing")
    raise SystemExit
if len(matches) != 1:
    raise SystemExit(f"Error: duplicate candidate asset: {path.name}")
asset = matches[0]
state = asset.get("state")
if state == "starter":
    api_url = asset.get("apiUrl")
    expected_prefix = f"https://api.github.com/repos/{repository}/releases/assets/"
    if not isinstance(api_url, str) or not api_url.startswith(expected_prefix):
        raise SystemExit(f"Error: incomplete candidate asset has an unsafe API URL: {path.name}")
    print(f"starter\t{api_url}")
    raise SystemExit
if state != "uploaded":
    raise SystemExit(f"Error: candidate asset has unsupported state {state!r}: {path.name}")
digest = hashlib.sha256(path.read_bytes()).hexdigest()
expected_url = (
    f"https://github.com/{repository}/releases/download/{download_ref}/{path.name}"
)
if asset.get("digest") != f"sha256:{digest}" or asset.get("url") != expected_url:
    raise SystemExit(f"Error: existing candidate asset conflicts with local bytes: {path.name}")
print("exact")
PY
}

reconcile_candidate_assets() {
  local asset_path
  local status_line
  local status
  local detail
  local attempt

  verify_candidate_release_header
  for asset_path in "${RELEASE_ASSETS[@]}"; do
    status_line=$(candidate_asset_status "$asset_path")
    IFS=$'\t' read -r status detail <<< "$status_line"
    if [[ "$status" == "starter" ]]; then
      echo "Removing incomplete starter upload for $(basename "$asset_path")..."
      gh api --method DELETE "$detail"
      status="missing"
    fi
    if [[ "$status" == "missing" ]]; then
      echo "Uploading $(basename "$asset_path")..."
      if ! gh release upload "$CANDIDATE_TAG" "$asset_path" --repo "$REPO"; then
        echo "Error: candidate asset upload failed; rerun to resume without replacing completed assets." >&2
        return 1
      fi
    elif [[ "$status" != "exact" ]]; then
      echo "Error: unsupported candidate asset reconciliation state: $status" >&2
      return 1
    fi

    for attempt in 1 2 3 4 5; do
      status_line=$(candidate_asset_status "$asset_path")
      if [[ "$status_line" == "exact" ]]; then
        break
      fi
      if [[ "$attempt" -eq 5 ]]; then
        echo "Error: uploaded candidate asset did not settle to its exact digest: $(basename "$asset_path")" >&2
        return 1
      fi
      sleep 1
    done
  done
  verify_github_release \
    "$CANDIDATE_TAG" draft mutable "$CANDIDATE_TAG" "$STAGED_COMMIT" \
    "$CANDIDATE_RELEASE_TITLE" "$CANDIDATE_RELEASE_NOTES"
}

verify_required_release_workflows() {
  local required_commit=$1
  local required_branch=$2
  local required_event=$3
  local required_workflows=(
    test.yml
    fixtures.yml
    vendor-manifest.yml
    native-source-contracts.yml
    sanitize.yml
  )
  local workflow
  local workflow_json
  for workflow in "${required_workflows[@]}"; do
    workflow_json="$WORK_DIR/workflow-${workflow%.yml}.json"
    if ! gh run list \
        --repo "$REPO" \
        --workflow "$workflow" \
        --commit "$required_commit" \
        --event "$required_event" \
        --limit 100 \
        --json databaseId,attempt,createdAt,status,conclusion,headSha,headBranch,event \
        > "$workflow_json"; then
      echo "Error: could not read $workflow workflow runs." >&2
      return 1
    fi
    if ! python3 - \
        "$workflow_json" "$workflow" "$required_commit" "$required_branch" \
        "$required_event" <<'PY'
import json
from datetime import datetime
import sys

path, workflow, commit, release_branch, event = sys.argv[1:]
runs = json.load(open(path))
if not isinstance(runs, list):
    sys.exit(f"Error: {workflow} workflow response is not a list")
exact = []
seen_ids = set()
for run in runs:
    if (
        run.get("headSha") != commit
        or run.get("headBranch") != release_branch
        or run.get("event") != event
    ):
        continue
    identifier = run.get("databaseId")
    if type(identifier) is not int or identifier <= 0 or identifier in seen_ids:
        sys.exit(f"Error: {workflow} returned an invalid/duplicate run id")
    seen_ids.add(identifier)
    created = run.get("createdAt")
    if not isinstance(created, str):
        sys.exit(f"Error: {workflow} exact run has no creation timestamp")
    try:
        created_key = datetime.fromisoformat(created.replace("Z", "+00:00"))
    except ValueError:
        sys.exit(f"Error: {workflow} exact run has an invalid creation timestamp")
    if created_key.tzinfo is None:
        sys.exit(f"Error: {workflow} exact run timestamp has no timezone")
    attempt = run.get("attempt")
    if type(attempt) is not int or attempt <= 0:
        sys.exit(f"Error: {workflow} exact run has an invalid attempt")
    exact.append((created_key, identifier, run))
if not exact:
    sys.exit(
        f"Error: {workflow} requires a {release_branch}/{event} run for {commit}"
    )
# A manual rerun updates one database id in place, while close/reopen or a
# superseded base event can create another run for the same immutable head.
# The newest exact event is authoritative: a newer pending/failure blocks, and
# a later successful recovery can safely supersede stale failures without
# permanently wedging an otherwise identical release commit.
_, _, run = max(exact, key=lambda item: (item[0], item[1]))
if run.get("status") != "completed":
    sys.exit(f"Error: {workflow} is not complete for {commit}: {run.get('status')!r}")
if run.get("conclusion") != "success":
    sys.exit(f"Error: {workflow} did not succeed for {commit}: {run.get('conclusion')!r}")
print(
    f"  {workflow}: success (run {run.get('databaseId')}, "
    f"attempt {run.get('attempt')})"
)
PY
    then
      return 1
    fi
  done
}

load_release_pr() {
  local metadata="$WORK_DIR/release-pr-list.json"
  local values

  gh pr list \
    --repo "$REPO" \
    --state all \
    --base main \
    --head "$RELEASE_BRANCH" \
    --limit 100 \
    --json number,state,isDraft,isCrossRepository,headRefName,headRefOid,baseRefName,baseRefOid,mergedAt,mergeCommit,url \
    > "$metadata"
  values=$(python3 - \
    "$metadata" "$RELEASE_BRANCH" "$STAGED_COMMIT" "$RELEASE_PARENT" <<'PY'
import json
import re
import sys

path, release_branch, staged_commit, release_parent = sys.argv[1:]
pulls = json.load(open(path))
if not isinstance(pulls, list):
    sys.exit("Error: release pull-request response is not a list")
if len(pulls) != 1:
    sys.exit(
        f"Error: expected exactly one pull request for {release_branch}; "
        f"found {len(pulls)}"
    )
pull = pulls[0]
if type(pull.get("number")) is not int or pull["number"] <= 0:
    sys.exit("Error: release pull request has an invalid number")
if pull.get("isCrossRepository") is not False:
    sys.exit("Error: release pull request must come from this repository")
if pull.get("headRefName") != release_branch:
    sys.exit("Error: release pull-request head branch drifted")
if pull.get("headRefOid") != staged_commit:
    sys.exit("Error: release pull-request head commit drifted")
if pull.get("baseRefName") != "main":
    sys.exit("Error: release pull-request base branch drifted")
if pull.get("baseRefOid") != release_parent:
    sys.exit("Error: main advanced after release staging; restage from fresh main")
if pull.get("isDraft") is not False:
    sys.exit("Error: release pull request must be ready for review")
state = pull.get("state")
if state not in ("OPEN", "MERGED"):
    sys.exit(f"Error: release pull request has unsupported state {state!r}")
merge_commit = (pull.get("mergeCommit") or {}).get("oid") or ""
if merge_commit and re.fullmatch(r"[0-9a-f]{40}", merge_commit) is None:
    sys.exit("Error: release pull request has an invalid merge commit")
print(pull["number"])
print(state)
print(merge_commit)
print(pull.get("url") or "")
PY
  )
  RELEASE_PR_NUMBER=$(printf '%s\n' "$values" | sed -n '1p')
  RELEASE_PR_STATE=$(printf '%s\n' "$values" | sed -n '2p')
  RELEASE_PR_MERGE_COMMIT=$(printf '%s\n' "$values" | sed -n '3p')
  RELEASE_PR_URL=$(printf '%s\n' "$values" | sed -n '4p')
}

verify_release_pr_ready() {
  local metadata="$WORK_DIR/release-pr-ready.json"

  gh pr view "$RELEASE_PR_NUMBER" --repo "$REPO" \
    --json number,state,isDraft,isCrossRepository,headRefName,headRefOid,baseRefName,baseRefOid,mergeable,mergeStateStatus,statusCheckRollup \
    > "$metadata"
  python3 - \
    "$metadata" "$RELEASE_BRANCH" "$STAGED_COMMIT" "$RELEASE_PARENT" <<'PY'
import json
import sys

path, release_branch, staged_commit, release_parent = sys.argv[1:]
pull = json.load(open(path))
if (
    pull.get("state") != "OPEN"
    or pull.get("isDraft") is not False
    or pull.get("isCrossRepository") is not False
    or pull.get("headRefName") != release_branch
    or pull.get("headRefOid") != staged_commit
    or pull.get("baseRefName") != "main"
    or pull.get("baseRefOid") != release_parent
):
    sys.exit("Error: release pull-request identity changed before publication")
if pull.get("mergeable") != "MERGEABLE" or pull.get("mergeStateStatus") != "CLEAN":
    sys.exit(
        "Error: release pull request is not cleanly mergeable: "
        f"{pull.get('mergeable')!r}/{pull.get('mergeStateStatus')!r}"
    )
checks = pull.get("statusCheckRollup")
if not isinstance(checks, list):
    sys.exit("Error: release pull-request checks are unavailable")
required = {"lint", "ios-build", "test", "dynamic-host", "check", "replay"}
required_rows = {name: [] for name in required}
for check in checks:
    name = check.get("name") or check.get("context")
    if name in required_rows:
        required_rows[name].append(check)
missing = sorted(name for name, rows in required_rows.items() if not rows)
if missing:
    sys.exit("Error: release pull request is missing checks: " + ", ".join(missing))
accepted = {"SUCCESS", "SKIPPED", "NEUTRAL"}
for check in checks:
    status = check.get("status") or "COMPLETED"
    conclusion = check.get("conclusion") or check.get("state")
    if status != "COMPLETED" or conclusion not in accepted:
        sys.exit(
            "Error: release pull request has a non-green check: "
            f"{check.get('name') or check.get('context')}: "
            f"{status}/{conclusion}"
        )
for name, rows in required_rows.items():
    if len(rows) != 1:
        sys.exit(f"Error: release pull request duplicates required check {name}")
    row = rows[0]
    status = row.get("status") or "COMPLETED"
    conclusion = row.get("conclusion") or row.get("state")
    if status != "COMPLETED" or conclusion != "SUCCESS":
        sys.exit(
            f"Error: required release check {name} is not successful: "
            f"{status}/{conclusion}"
        )
PY
}

verify_release_attestation() {
  local attempt
  local asset_path
  local verified=false
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if gh release verify "$TAG" --repo "$REPO" --format json \
        > "$WORK_DIR/release-attestation.json" 2>/dev/null; then
      verified=true
      break
    fi
    sleep 5
  done
  if [[ "$verified" != true ]]; then
    echo "Error: GitHub did not produce a valid release attestation for $TAG." >&2
    return 1
  fi
  # The release verification binds tag + commit + the complete asset inventory;
  # verify-asset additionally proves each exact local byte stream is a subject.
  for asset_path in "${RELEASE_ASSETS[@]}"; do
    gh release verify-asset "$TAG" "$asset_path" --repo "$REPO" \
      --format json >/dev/null
  done
}

verify_anonymous_public_artifact() {
  local anonymous_zip="$WORK_DIR/anonymous-$ZIP_NAME"
  echo "Verifying anonymous public asset download..."
  (
    unset GH_TOKEN GITHUB_TOKEN
    # --disable must be the first curl option; it prevents an operator .curlrc
    # from silently adding credentials to this anonymous-consumption proof.
    curl --disable --fail --location --retry 3 --retry-all-errors \
      --output "$anonymous_zip" "$RELEASE_URL"
  )
  local anonymous_checksum
  anonymous_checksum=$(swift package compute-checksum "$anonymous_zip")
  if [[ "$anonymous_checksum" != "$CHECKSUM" ]]; then
    echo "Error: anonymous public asset checksum differs from Package.swift." >&2
    return 1
  fi
}

verify_external_swiftpm_consumer() {
  local smoke_dir="$WORK_DIR/external-consumer"
  mkdir -p "$smoke_dir/Sources/SwiftVLCSmoke"
  cat > "$smoke_dir/Package.swift" <<EOF
// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "SwiftVLCReleaseSmoke",
  platforms: [.macOS(.v15)],
  dependencies: [
    .package(url: "https://github.com/$REPO.git", exact: "$VERSION")
  ],
  targets: [
    .executableTarget(
      name: "SwiftVLCSmoke",
      dependencies: [.product(name: "SwiftVLC", package: "SwiftVLC")]
    )
  ]
)
EOF
  cat > "$smoke_dir/Sources/SwiftVLCSmoke/main.swift" <<'EOF'
import SwiftVLC

print("SwiftVLC external release smoke")
EOF
  echo "Building a clean external SwiftPM consumer of $TAG..."
  (
    unset GH_TOKEN GITHUB_TOKEN GIT_ASKPASS SSH_ASKPASS SSH_AUTH_SOCK
    # Ignore operator/machine URL rewrites and credential helpers. The smoke
    # test must prove a public consumer can resolve the tag and artifact, not
    # accidentally succeed through the maintainer's global Git credentials.
    GIT_CONFIG_GLOBAL=/dev/null \
      GIT_CONFIG_SYSTEM=/dev/null \
      GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_COUNT=1 \
      GIT_CONFIG_KEY_0=credential.helper \
      GIT_CONFIG_VALUE_0= \
      GIT_TERMINAL_PROMPT=0 \
      swift build \
      --package-path "$smoke_dir" \
      --scratch-path "$smoke_dir/.build" \
      --disable-dependency-cache
  )
}

echo ""

# Discover an interrupted stage from its exact branch/non-SemVer tag, or an
# uncertain/completed publication from the final immutable tag. All three refs
# identify the canonical release-PR head; main is advanced only by GitHub's PR
# merge path and therefore normally becomes a distinct merge commit.
REMOTE_MAIN_COMMIT=$(remote_ref_sha refs/heads/main)
REMOTE_FINAL_TAG_COMMIT=$(remote_ref_sha "refs/tags/$TAG")
REMOTE_RELEASE_BRANCH_COMMIT=$(remote_ref_sha "refs/heads/$RELEASE_BRANCH")
CANDIDATE_ROWS=$(git ls-remote --tags origin \
  "refs/tags/swiftvlc-candidate-${TAG}-*" \
  | awk '$2 !~ /\^\{\}$/')
CANDIDATE_ROW_COUNT=$(printf '%s\n' "$CANDIDATE_ROWS" \
  | awk 'NF { count += 1 } END { print count + 0 }')
if [[ "$CANDIDATE_ROW_COUNT" -gt 1 ]]; then
  echo "Error: multiple candidate tags exist for $TAG; audit them manually." >&2
  exit 1
fi
REMOTE_CANDIDATE_TAG_COMMIT=""
REMOTE_CANDIDATE_TAG_NAME=""
if [[ "$CANDIDATE_ROW_COUNT" -eq 1 ]]; then
  REMOTE_CANDIDATE_TAG_COMMIT=$(printf '%s\n' "$CANDIDATE_ROWS" | awk '{ print $1 }')
  REMOTE_CANDIDATE_TAG_NAME=$(printf '%s\n' "$CANDIDATE_ROWS" \
    | awk '{ sub("refs/tags/", "", $2); print $2 }')
  if [[ "$REMOTE_CANDIDATE_TAG_NAME" != \
      "$(candidate_tag_for_commit "$REMOTE_CANDIDATE_TAG_COMMIT")" ]]; then
    echo "Error: candidate tag name is not bound to its full commit SHA." >&2
    exit 1
  fi
fi

STAGED_COMMIT=""
for discovered_commit in \
  "$REMOTE_FINAL_TAG_COMMIT" \
  "$REMOTE_RELEASE_BRANCH_COMMIT" \
  "$REMOTE_CANDIDATE_TAG_COMMIT"; do
  if [[ -n "$discovered_commit" && -n "$STAGED_COMMIT" \
      && "$discovered_commit" != "$STAGED_COMMIT" ]]; then
    echo "Error: release candidate branch/tag identities disagree." >&2
    exit 1
  fi
  if [[ -n "$discovered_commit" ]]; then
    STAGED_COMMIT="$discovered_commit"
  fi
done
if [[ -z "$STAGED_COMMIT" \
    && "$(git rev-parse HEAD)" != "$REMOTE_MAIN_COMMIT" ]]; then
  STAGED_COMMIT=$(git rev-parse HEAD)
fi

if [[ -n "$STAGED_COMMIT" \
    && "$(git cat-file -t "$STAGED_COMMIT" 2>/dev/null || true)" != "commit" ]]; then
  if [[ -n "$REMOTE_FINAL_TAG_COMMIT" ]]; then
    git fetch --quiet --force origin \
      "refs/tags/$TAG:refs/swiftvlc-final/$TAG"
  elif [[ -n "$REMOTE_RELEASE_BRANCH_COMMIT" ]]; then
    git fetch --quiet --force origin \
      "refs/heads/$RELEASE_BRANCH:refs/swiftvlc-candidate/$TAG"
  else
    git fetch --quiet --force origin \
      "refs/tags/$REMOTE_CANDIDATE_TAG_NAME:refs/swiftvlc-candidate/$TAG"
  fi
fi

if [[ -z "$STAGED_COMMIT" ]]; then
  if [[ "$(git rev-parse HEAD)" != "$REMOTE_MAIN_COMMIT" ]]; then
    echo "Error: cannot create a release commit away from exact origin/main." >&2
    exit 1
  fi
  echo "Creating canonical release PR commit on $CURRENT_BRANCH..."
  begin_release_file_restore
  switch_package_to_release_url
  switch_showcase_to_release_version
  git add Package.swift "$SHOWCASE_PROJECT"
  git commit --quiet -m "Release $TAG"
  RELEASE_RESTORE_FILES=false
  STAGED_COMMIT=$(git rev-parse HEAD)
elif [[ "$(git rev-parse HEAD)" != "$STAGED_COMMIT" ]]; then
  if [[ "$(git rev-parse HEAD)" == "$REMOTE_MAIN_COMMIT" \
      && "$(git rev-parse "${STAGED_COMMIT}^")" == "$REMOTE_MAIN_COMMIT" ]]; then
    echo "Recovering exact staged release commit $STAGED_COMMIT..."
    git merge --quiet --ff-only "$STAGED_COMMIT"
  elif [[ "$FINALIZE" != true ]] \
      || ! git merge-base --is-ancestor "$STAGED_COMMIT" HEAD \
      || ! git diff --quiet "$STAGED_COMMIT" HEAD --; then
    echo "Error: checkout is neither the staged release commit nor its exact-tree PR merge." >&2
    exit 1
  fi
fi

if ! canonical_release_commit_matches "$STAGED_COMMIT"; then
  exit 1
fi
RELEASE_PARENT=$(git rev-parse "${STAGED_COMMIT}^")
CANDIDATE_TAG=$(candidate_tag_for_commit "$STAGED_COMMIT")
if [[ -n "$REMOTE_CANDIDATE_TAG_NAME" \
    && "$REMOTE_CANDIDATE_TAG_NAME" != "$CANDIDATE_TAG" ]]; then
  echo "Error: discovered candidate tag name differs from the canonical identity." >&2
  exit 1
fi

# Recovery recomputes the normalized tree from the actual checkout. The PR
# merge commit is accepted only when its tree is byte-identical to this staged
# head, so the same candidate digest covers both commits.
RELEASE_SOURCE_DIGEST=$("$SCRIPT_DIR/release-source-digest.py" "$VERSION")
if [[ "$RELEASE_SOURCE_DIGEST" != "$CANDIDATE_SOURCE_DIGEST" ]]; then
  echo "Error: release checkout does not match the candidate source digest." >&2
  exit 1
fi

CANDIDATE_RELEASE_NOTES="$(cat <<EOF
## libVLC xcframework release candidate
$QUALIFICATION_NOTE
Intended final tag: **$TAG**
Exact release PR commit: **$STAGED_COMMIT**
Artifact checksum: **$CHECKSUM**

This is a mutable draft under a deliberately non-SemVer tag. Publication is
allowed only after exact-candidate CI and the protected release PR are green.
EOF
)"
FINAL_RELEASE_NOTES="$(cat <<EOF
## libVLC xcframework
$QUALIFICATION_NOTE
Pre-built static XCFramework for libVLC 4.0.

Exact release commit: **$STAGED_COMMIT**
Artifact checksum: **$CHECKSUM**

Swift Package Manager resolves this artifact from the immutable tag and checksum.
EOF
)"

FINAL_RELEASE_PRESENT=false
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  FINAL_RELEASE_PRESENT=true
fi

if [[ "$FINAL_RELEASE_PRESENT" != true ]]; then
  if [[ -n "$REMOTE_FINAL_TAG_COMMIT" ]]; then
    if [[ "$FINALIZE" != true \
        || "$REMOTE_FINAL_TAG_COMMIT" != "$STAGED_COMMIT" ]]; then
      echo "Error: unpublished final tag $TAG is not a recoverable reservation." >&2
      exit 1
    fi
    echo "Recovering exact unpublished final-tag reservation $TAG..."
  else
    verify_remote_ref_absent "refs/tags/$TAG"
  fi

  REMOTE_CANDIDATE_TAG_COMMIT=$(remote_ref_sha "refs/tags/$CANDIDATE_TAG")
  if [[ -z "$REMOTE_CANDIDATE_TAG_COMMIT" ]]; then
    echo "Pushing non-SemVer candidate tag $CANDIDATE_TAG..."
    git push \
      --force-with-lease="refs/tags/$CANDIDATE_TAG:" \
      origin "$STAGED_COMMIT:refs/tags/$CANDIDATE_TAG"
  elif [[ "$REMOTE_CANDIDATE_TAG_COMMIT" != "$STAGED_COMMIT" ]]; then
    echo "Error: candidate tag resolves to the wrong commit." >&2
    exit 1
  fi
  verify_remote_ref "refs/tags/$CANDIDATE_TAG" "$STAGED_COMMIT"

  if gh release view "$CANDIDATE_TAG" --repo "$REPO" >/dev/null 2>&1; then
    verify_candidate_release_header
  else
    echo "Creating empty draft candidate release..."
    gh release create "$CANDIDATE_TAG" \
      --repo "$REPO" \
      --verify-tag \
      --target "$STAGED_COMMIT" \
      "${RELEASE_FLAGS[@]}" \
      --title "$CANDIDATE_RELEASE_TITLE" \
      --notes "$CANDIDATE_RELEASE_NOTES"
  fi
  reconcile_candidate_assets

  # Trigger exact-artifact CI only after every draft asset is complete.
  REMOTE_RELEASE_BRANCH_COMMIT=$(remote_ref_sha "refs/heads/$RELEASE_BRANCH")
  if [[ -z "$REMOTE_RELEASE_BRANCH_COMMIT" ]]; then
    echo "Pushing exact release commit to $RELEASE_BRANCH for CI and review..."
    git push \
      --force-with-lease="refs/heads/$RELEASE_BRANCH:" \
      origin "$STAGED_COMMIT:refs/heads/$RELEASE_BRANCH"
  elif [[ "$REMOTE_RELEASE_BRANCH_COMMIT" != "$STAGED_COMMIT" ]]; then
    echo "Error: $RELEASE_BRANCH exists at the wrong commit." >&2
    exit 1
  fi
  verify_remote_ref "refs/heads/$RELEASE_BRANCH" "$STAGED_COMMIT"
  if [[ -z "$(remote_ref_sha "refs/tags/$TAG")" ]]; then
    verify_remote_ref_absent "refs/tags/$TAG"
  else
    verify_remote_ref "refs/tags/$TAG" "$STAGED_COMMIT"
  fi

  RELEASE_PR_COUNT=$(gh pr list --repo "$REPO" --state all \
    --base main --head "$RELEASE_BRANCH" --limit 100 --json number --jq length)
  if [[ "$RELEASE_PR_COUNT" == "0" ]]; then
    echo "Opening protected-main release pull request..."
    gh pr create \
      --repo "$REPO" \
      --base main \
      --head "$RELEASE_BRANCH" \
      --title "Release $TAG" \
      --body "$(cat <<EOF
Publishes the already-prepared libVLC candidate for **$TAG**.

- Exact release commit: **$STAGED_COMMIT**
- Artifact checksum: **$CHECKSUM**
- The final SemVer tag remains absent until candidate CI and this PR are green.
EOF
)" >/dev/null
  elif [[ "$RELEASE_PR_COUNT" != "1" ]]; then
    echo "Error: expected at most one release pull request; found $RELEASE_PR_COUNT." >&2
    exit 1
  fi
  load_release_pr

  if [[ "$FINALIZE" != true ]]; then
    echo ""
    echo "Release $TAG is staged as non-SemVer candidate $CANDIDATE_TAG."
    echo "No final SemVer tag exists. CI and $RELEASE_PR_URL must become green."
    echo "Then rerun:"
    echo "  $0 $VERSION --candidate <original-candidate-directory> --finalize"
    exit 0
  fi
elif [[ "$FINALIZE" != true ]]; then
  echo "Error: final release $TAG already exists; only --finalize may audit recovery." >&2
  exit 1
fi

echo "Verifying exact candidate workflows for $STAGED_COMMIT..."
verify_required_release_workflows \
  "$STAGED_COMMIT" "$RELEASE_BRANCH" pull_request
load_release_pr

if [[ "$FINAL_RELEASE_PRESENT" != true ]]; then
  if [[ "$RELEASE_PR_STATE" != "OPEN" ]]; then
    echo "Error: unpublished release PR is not open; audit the temporary main break." >&2
    exit 1
  fi
  verify_release_pr_ready

  # Close every mutable boundary immediately before one publication update.
  verify_remote_ref "refs/tags/$CANDIDATE_TAG" "$STAGED_COMMIT"
  verify_remote_ref "refs/heads/$RELEASE_BRANCH" "$STAGED_COMMIT"
  if [[ -z "$(remote_ref_sha "refs/tags/$TAG")" ]]; then
    verify_remote_ref_absent "refs/tags/$TAG"
  else
    verify_remote_ref "refs/tags/$TAG" "$STAGED_COMMIT"
  fi
  verify_github_release \
    "$CANDIDATE_TAG" draft mutable "$CANDIDATE_TAG" "$STAGED_COMMIT" \
    "$CANDIDATE_RELEASE_TITLE" "$CANDIDATE_RELEASE_NOTES"
  REMOTE_MAIN_COMMIT=$(remote_ref_sha refs/heads/main)
  if [[ "$REMOTE_MAIN_COMMIT" != "$RELEASE_PARENT" ]]; then
    echo "Error: origin/main changed after release staging." >&2
    echo "  expected: $RELEASE_PARENT" >&2
    echo "  actual:   ${REMOTE_MAIN_COMMIT:-missing}" >&2
    exit 1
  fi
  verify_main_governance
  verify_immutable_releases_enabled

  # GitHub ignores target_commitish when a tag already exists. Reserve the
  # final tag with an absent-value lease first, so a concurrent wrong tag can
  # never be frozen into an immutable release. Candidate CI and the protected
  # PR are already green; a failed publication rolls this reservation back.
  if [[ -z "$(remote_ref_sha "refs/tags/$TAG")" ]]; then
    echo "Reserving exact final tag $TAG..."
    git push \
      --force-with-lease="refs/tags/$TAG:" \
      origin "$STAGED_COMMIT:refs/tags/$TAG"
  fi
  verify_remote_ref "refs/tags/$TAG" "$STAGED_COMMIT"

  echo "Publishing the verified draft as $TAG..."
  PUBLISH_COMMAND_OK=true
  PUBLISH_PRERELEASE_FLAG="--prerelease=false"
  if [[ "$UNQUALIFIED" == true ]]; then
    PUBLISH_PRERELEASE_FLAG="--prerelease"
  fi
  if ! gh release edit "$CANDIDATE_TAG" \
      --repo "$REPO" \
      --tag "$TAG" \
      --target "$STAGED_COMMIT" \
      --title "$FINAL_RELEASE_TITLE" \
      --notes "$FINAL_RELEASE_NOTES" \
      "$PUBLISH_PRERELEASE_FLAG" \
      --draft=false; then
    PUBLISH_COMMAND_OK=false
    echo "Publication response was uncertain; classifying remote state..." >&2
  fi

  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    FINAL_RELEASE_PRESENT=true
  elif gh release view "$CANDIDATE_TAG" --repo "$REPO" >/dev/null 2>&1; then
    verify_github_release \
      "$CANDIDATE_TAG" draft mutable "$CANDIDATE_TAG" "$STAGED_COMMIT" \
      "$CANDIDATE_RELEASE_TITLE" "$CANDIDATE_RELEASE_NOTES"
    echo "Publication did not commit; rolling back the final-tag reservation." >&2
    rollback_reserved_final_tag
    echo "Error: candidate remains a draft; main was not merged." >&2
    exit 1
  else
    echo "Error: publication response left no verifiable release identity." >&2
    exit 1
  fi
  if [[ "$PUBLISH_COMMAND_OK" != true ]]; then
    echo "Recovered a successful publication after an uncertain response."
  fi
fi

# Publication is externally visible but main still changes only through the
# already-green PR. Verify immutable bytes and public consumption first.
verify_remote_ref "refs/tags/$TAG" "$STAGED_COMMIT"
verify_github_release \
  "$TAG" published immutable "$TAG" "$STAGED_COMMIT" \
  "$FINAL_RELEASE_TITLE" "$FINAL_RELEASE_NOTES"
verify_anonymous_public_artifact
verify_external_swiftpm_consumer
verify_release_attestation

load_release_pr
MERGED_DURING_INVOCATION=false
if [[ "$RELEASE_PR_STATE" == "OPEN" ]]; then
  verify_release_pr_ready
  verify_main_governance
  echo "Merging release PR #$RELEASE_PR_NUMBER through protected main..."
  MERGE_COMMAND_OK=true
  if ! gh api \
      --method PUT \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2026-03-10' \
      "repos/$REPO/pulls/$RELEASE_PR_NUMBER/merge" \
      -f "sha=$STAGED_COMMIT" \
      -f 'merge_method=merge' \
      > "$WORK_DIR/pr-merge-response.json"; then
    MERGE_COMMAND_OK=false
    echo "PR merge response was uncertain; classifying remote state..." >&2
  elif ! python3 - "$WORK_DIR/pr-merge-response.json" <<'PY'
import json
import re
import sys

try:
    response = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    raise SystemExit(1)
if response.get("merged") is not True:
    raise SystemExit(1)
commit = response.get("sha")
if not isinstance(commit, str) or re.fullmatch(r"[0-9a-f]{40}", commit) is None:
    raise SystemExit(1)
PY
  then
    MERGE_COMMAND_OK=false
    echo "PR merge response was invalid; classifying remote state..." >&2
  fi
  git fetch --quiet origin main
  load_release_pr
  if [[ "$RELEASE_PR_STATE" != "MERGED" ]]; then
    echo "Error: release PR remains unmerged; immutable release recovery is required." >&2
    exit 1
  fi
  if [[ "$MERGE_COMMAND_OK" != true ]]; then
    echo "Recovered a successful protected-main merge after an uncertain response."
  fi
  MERGED_DURING_INVOCATION=true
fi

if [[ "$RELEASE_PR_STATE" != "MERGED" \
    || -z "$RELEASE_PR_MERGE_COMMIT" ]]; then
  echo "Error: release PR does not have a verifiable merge commit." >&2
  exit 1
fi
git fetch --quiet origin main
REMOTE_MAIN_COMMIT=$(remote_ref_sha refs/heads/main)
if ! git merge-base --is-ancestor "$RELEASE_PR_MERGE_COMMIT" "$REMOTE_MAIN_COMMIT"; then
  echo "Error: the protected release PR merge is not on origin/main." >&2
  exit 1
fi
if ! git merge-base --is-ancestor "$STAGED_COMMIT" "$RELEASE_PR_MERGE_COMMIT" \
    || ! git diff --quiet "$STAGED_COMMIT" "$RELEASE_PR_MERGE_COMMIT" --; then
  echo "Error: protected-main merge does not preserve the exact release tree." >&2
  exit 1
fi
verify_remote_ref "refs/tags/$TAG" "$STAGED_COMMIT"
verify_github_release \
  "$TAG" published immutable "$TAG" "$STAGED_COMMIT" \
  "$FINAL_RELEASE_TITLE" "$FINAL_RELEASE_NOTES"

if [[ "$MERGED_DURING_INVOCATION" == true ]]; then
  echo ""
  echo "Release PR merged at $RELEASE_PR_MERGE_COMMIT; exact-main CI is running."
  echo "Update the local main checkout, wait for CI, then rerun --finalize."
  exit 0
fi

echo "Verifying fresh workflows for exact main merge $RELEASE_PR_MERGE_COMMIT..."
verify_required_release_workflows "$RELEASE_PR_MERGE_COMMIT" main push

# Final postcondition binds immutable public bytes, the release PR head/tree,
# its exact main merge, and fresh main CI before temporary authorization refs
# are removed. Compare-and-delete leases prevent cleanup from deleting a ref
# another actor moved after verification.
verify_remote_ref "refs/tags/$TAG" "$STAGED_COMMIT"
verify_github_release \
  "$TAG" published immutable "$TAG" "$STAGED_COMMIT" \
  "$FINAL_RELEASE_TITLE" "$FINAL_RELEASE_NOTES"
if [[ -n "$(remote_ref_sha "refs/heads/$RELEASE_BRANCH")" ]]; then
  verify_remote_ref "refs/heads/$RELEASE_BRANCH" "$STAGED_COMMIT"
  git push \
    --force-with-lease="refs/heads/$RELEASE_BRANCH:$STAGED_COMMIT" \
    origin ":refs/heads/$RELEASE_BRANCH"
fi
if [[ -n "$(remote_ref_sha "refs/tags/$CANDIDATE_TAG")" ]]; then
  verify_remote_ref "refs/tags/$CANDIDATE_TAG" "$STAGED_COMMIT"
  git push \
    --force-with-lease="refs/tags/$CANDIDATE_TAG:$STAGED_COMMIT" \
    origin ":refs/tags/$CANDIDATE_TAG"
fi
verify_remote_ref_absent "refs/heads/$RELEASE_BRANCH"
verify_remote_ref_absent "refs/tags/$CANDIDATE_TAG"

echo ""
echo "Release $TAG published and merged through PR #$RELEASE_PR_NUMBER: https://github.com/$REPO/releases/tag/$TAG"
