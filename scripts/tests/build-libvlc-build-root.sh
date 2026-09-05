#!/usr/bin/env bash
set -euo pipefail

SOURCE_SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/swiftvlc-build-root-tests.XXXXXX")
trap 'rm -rf "$temporary_root"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

expect_failure() {
  local description="$1"
  local expected="$2"
  shift 2
  if "$BUILD_SCRIPT" "$@" > "$temporary_root/failure.log" 2>&1; then
    fail "$description was accepted"
  fi
  grep -Fq -- "$expected" "$temporary_root/failure.log" || {
    cat "$temporary_root/failure.log" >&2
    fail "$description did not produce the expected diagnostic"
  }
}

fixture_repo="$temporary_root/repository"
mkdir -p "$fixture_repo/scripts"
cp "$SOURCE_SCRIPT_DIR/build-libvlc.sh" "$fixture_repo/scripts/build-libvlc.sh"
cp "$SOURCE_SCRIPT_DIR/detach-managed-build-directory.py" \
  "$fixture_repo/scripts/detach-managed-build-directory.py"
git -C "$fixture_repo" init -q
ROOT_DIR=$(cd "$fixture_repo" && pwd -P)
BUILD_SCRIPT="$ROOT_DIR/scripts/build-libvlc.sh"
DETACH_HELPER="$ROOT_DIR/scripts/detach-managed-build-directory.py"
real_python3=$(python3 -c 'import os, sys; print(os.path.realpath(sys.executable))')

external_root="$temporary_root/external-root"
mkdir -p "$external_root"
external_root=$(cd "$external_root" && pwd -P)
managed_child="$external_root/swiftvlc-libvlc-build"
lock_directory="$external_root/.swiftvlc-libvlc-build.lock"
marker="$managed_child/.swiftvlc-managed-libvlc-build-v1"
checkout_lock=$(git -C "$ROOT_DIR" rev-parse --git-path swiftvlc-libvlc-output.lock)
case "$checkout_lock" in
  /*) ;;
  *) checkout_lock="$ROOT_DIR/$checkout_lock" ;;
esac

expect_failure \
  "relative external build root" \
  "--build-root must be an absolute directory path" \
  --build-root=relative --clean

expect_failure \
  "empty external build root" \
  "--build-root requires an absolute directory path" \
  --build-root= --clean

expect_failure \
  "missing external build root" \
  "External build root does not exist" \
  --build-root="$temporary_root/missing" --clean

expect_failure \
  "build root inside the checkout" \
  "--build-root must be outside the SwiftVLC checkout" \
  --build-root="$ROOT_DIR" --clean

root_alias="$temporary_root/root-alias"
ln -s "$external_root" "$root_alias"
expect_failure \
  "non-canonical external build root" \
  "--build-root must use its canonical physical path" \
  --build-root="$root_alias" --clean

mkdir -p "$managed_child"
printf 'user data\n' > "$managed_child/keep.txt"
expect_failure \
  "unowned external build directory" \
  "Refusing unowned external build directory" \
  --build-root="$external_root" --clean
[[ -f "$managed_child/keep.txt" ]] || \
  fail "unowned external data was removed"

rm -rf "$managed_child"
mkdir -p "$temporary_root/symlink-target"
printf 'user data\n' > "$temporary_root/symlink-target/keep.txt"
ln -s "$temporary_root/symlink-target" "$managed_child"
expect_failure \
  "symlinked managed build directory" \
  "Refusing symlinked managed build directory" \
  --build-root="$external_root" --clean
[[ -f "$temporary_root/symlink-target/keep.txt" ]] || \
  fail "symlink target data was removed"

rm "$managed_child"
ln -s "$temporary_root/missing-symlink-target" "$managed_child"
expect_failure \
  "dangling managed build-directory symlink" \
  "Refusing symlinked managed build directory" \
  --build-root="$external_root" --clean
rm "$managed_child"

mkdir -p "$managed_child"
printf 'wrong marker\n' > "$marker"
expect_failure \
  "incorrect managed-directory marker" \
  "Refusing unowned external build directory" \
  --build-root="$external_root" --clean

printf 'SwiftVLC managed libVLC build directory v1\n\n' > "$marker"
expect_failure \
  "managed-directory marker with extra bytes" \
  "Refusing unowned external build directory" \
  --build-root="$external_root" --clean

marker_target="$temporary_root/marker-target"
printf 'SwiftVLC managed libVLC build directory v1\n' > "$marker_target"
rm "$marker"
ln -s "$marker_target" "$marker"
expect_failure \
  "symlinked managed-directory marker" \
  "Refusing unowned external build directory" \
  --build-root="$external_root" --clean
rm "$marker"

printf 'SwiftVLC managed libVLC build directory v1\n' > "$marker"
printf 'managed data\n' > "$managed_child/remove.txt"
cleanup_symlink_target="$temporary_root/cleanup-symlink-target"
mkdir "$cleanup_symlink_target"
printf 'outside data\n' > "$cleanup_symlink_target/preserve.txt"
ln -s "$cleanup_symlink_target" "$managed_child/outside-link"
printf 'sibling data\n' > "$external_root/preserve.txt"
"$BUILD_SCRIPT" --clean --build-root="$external_root" \
  > "$temporary_root/clean.log" 2>&1
[[ ! -e "$managed_child" ]] || fail "managed build child was not removed"
[[ -f "$external_root/preserve.txt" ]] || fail "build-root sibling was removed"
[[ -f "$cleanup_symlink_target/preserve.txt" ]] || \
  fail "cleanup followed a nested symlink outside the managed directory"
[[ ! -e "$lock_directory" ]] || fail "successful cleanup left its lock behind"
[[ ! -e "$checkout_lock" ]] || fail "successful cleanup left checkout lock behind"

# Renaming and replacing the absolute external-root pathname after the script
# has entered it must not redirect either cleanup or EXIT lock release. The
# helper receives --root . and therefore remains anchored to the original CWD.
root_swap_public="$temporary_root/root-swap-public"
root_swap_state="$temporary_root/root-swap-state"
root_swap_bin="$temporary_root/root-swap-bin"
mkdir "$root_swap_public" "$root_swap_bin"
root_swap_public=$(cd "$root_swap_public" && pwd -P)
root_swap_original="$(dirname "$root_swap_public")/root-swap-original"
"$real_python3" -B "$DETACH_HELPER" initialize \
  --root "$root_swap_public" \
  --child swiftvlc-libvlc-build \
  --marker-name .swiftvlc-managed-libvlc-build-v1 \
  --marker-content 'SwiftVLC managed libVLC build directory v1'
printf 'original managed data\n' > \
  "$root_swap_public/swiftvlc-libvlc-build/remove.txt"
printf 'original root sibling\n' > "$root_swap_public/preserve.txt"
cat > "$root_swap_bin/python3" <<'EOF'
#!/bin/bash
set -eu
if [ "${1:-}" = "$SWIFTVLC_DETACH_HELPER" ] &&
   [ "${2:-}" = clean ] &&
   [ ! -e "$SWIFTVLC_RACE_STATE" ]; then
  : > "$SWIFTVLC_RACE_STATE"
  /bin/mv "$SWIFTVLC_PUBLIC_ROOT" "$SWIFTVLC_ORIGINAL_ROOT"
  /bin/mkdir "$SWIFTVLC_PUBLIC_ROOT"
  /bin/mkdir "$SWIFTVLC_PUBLIC_ROOT/swiftvlc-libvlc-build"
  printf 'SwiftVLC managed libVLC build directory v1\n' > \
    "$SWIFTVLC_PUBLIC_ROOT/swiftvlc-libvlc-build/.swiftvlc-managed-libvlc-build-v1"
  printf 'replacement managed data\n' > \
    "$SWIFTVLC_PUBLIC_ROOT/swiftvlc-libvlc-build/do-not-delete"
  printf 'replacement root data\n' > \
    "$SWIFTVLC_PUBLIC_ROOT/do-not-delete"
fi
exec "$SWIFTVLC_REAL_PYTHON3" "$@"
EOF
chmod +x "$root_swap_bin/python3"
PATH="$root_swap_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  SWIFTVLC_REAL_PYTHON3="$real_python3" \
  SWIFTVLC_DETACH_HELPER="$DETACH_HELPER" \
  SWIFTVLC_PUBLIC_ROOT="$root_swap_public" \
  SWIFTVLC_ORIGINAL_ROOT="$root_swap_original" \
  SWIFTVLC_RACE_STATE="$root_swap_state" \
  "$BUILD_SCRIPT" --build-root="$root_swap_public" --clean \
  > "$temporary_root/root-swap.log" 2>&1
[[ -e "$root_swap_state" ]] || fail "external-root pathname race did not execute"
[[ ! -e "$root_swap_original/swiftvlc-libvlc-build" ]] || \
  fail "cleanup did not remove the managed child from the anchored root"
[[ -f "$root_swap_original/preserve.txt" ]] || \
  fail "cleanup removed an anchored-root sibling"
[[ -f "$root_swap_public/do-not-delete" ]] || \
  fail "cleanup touched the replacement external root"
[[ -f "$root_swap_public/swiftvlc-libvlc-build/do-not-delete" ]] || \
  fail "cleanup followed the replaced root pathname into unrelated data"
[[ -f "$root_swap_public/swiftvlc-libvlc-build/.swiftvlc-managed-libvlc-build-v1" ]] || \
  fail "cleanup removed the replacement directory's ownership marker"
[[ ! -e "$root_swap_original/.swiftvlc-libvlc-build.lock" ]] || \
  fail "root-path replacement redirected lock cleanup away from the anchored root"
[[ ! -e "$root_swap_public/.swiftvlc-libvlc-build.lock" ]] || \
  fail "root-path replacement created a lock in the replacement root"
[[ ! -e "$checkout_lock" ]] || \
  fail "root-path replacement left the checkout lock behind"
/bin/rm -rf "$root_swap_original" "$root_swap_public"

# Checkout-local cleanup must anchor the scripts directory itself. If a
# worktree move replaces that public pathname after startup, --root . must
# still remove only the build child beneath the original live CWD.
default_swap_repo="$temporary_root/default-swap-repository"
default_swap_bin="$temporary_root/default-swap-bin"
default_swap_state="$temporary_root/default-swap-state"
default_helper_source="$temporary_root/default-helper-source.py"
mkdir -p "$default_swap_repo/scripts/.build-libvlc" "$default_swap_bin"
default_swap_repo=$(cd "$default_swap_repo" && pwd -P)
cp "$SOURCE_SCRIPT_DIR/build-libvlc.sh" \
  "$default_swap_repo/scripts/build-libvlc.sh"
cp "$SOURCE_SCRIPT_DIR/detach-managed-build-directory.py" \
  "$default_swap_repo/scripts/detach-managed-build-directory.py"
cp "$SOURCE_SCRIPT_DIR/detach-managed-build-directory.py" \
  "$default_helper_source"
git -C "$default_swap_repo" init -q
printf 'SwiftVLC managed libVLC build directory v1\n' > \
  "$default_swap_repo/scripts/.build-libvlc/.swiftvlc-managed-libvlc-build-v1"
printf 'original managed data\n' > \
  "$default_swap_repo/scripts/.build-libvlc/remove.txt"
printf 'original scripts sibling\n' > \
  "$default_swap_repo/scripts/preserve.txt"
cat > "$default_swap_bin/python3" <<'EOF'
#!/bin/bash
set -eu
if [ "${1:-}" = "$SWIFTVLC_PUBLIC_HELPER" ] &&
   [ "${2:-}" = clean ] &&
   [ ! -e "$SWIFTVLC_RACE_STATE" ]; then
  : > "$SWIFTVLC_RACE_STATE"
  /bin/mv "$SWIFTVLC_PUBLIC_SCRIPTS" "$SWIFTVLC_ORIGINAL_SCRIPTS"
  /bin/mkdir -p "$SWIFTVLC_PUBLIC_SCRIPTS/.build-libvlc"
  /bin/cp "$SWIFTVLC_HELPER_SOURCE" "$SWIFTVLC_PUBLIC_HELPER"
  printf 'SwiftVLC managed libVLC build directory v1\n' > \
    "$SWIFTVLC_PUBLIC_SCRIPTS/.build-libvlc/.swiftvlc-managed-libvlc-build-v1"
  printf 'replacement managed data\n' > \
    "$SWIFTVLC_PUBLIC_SCRIPTS/.build-libvlc/do-not-delete"
fi
exec "$SWIFTVLC_REAL_PYTHON3" "$@"
EOF
chmod +x "$default_swap_bin/python3"
default_public_scripts="$default_swap_repo/scripts"
default_original_scripts="$default_swap_repo/scripts-original"
default_checkout_lock=$(git -C "$default_swap_repo" \
  rev-parse --git-path swiftvlc-libvlc-output.lock)
case "$default_checkout_lock" in
  /*) ;;
  *) default_checkout_lock="$default_swap_repo/$default_checkout_lock" ;;
esac
PATH="$default_swap_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  SWIFTVLC_REAL_PYTHON3="$real_python3" \
  SWIFTVLC_PUBLIC_HELPER="$default_public_scripts/detach-managed-build-directory.py" \
  SWIFTVLC_PUBLIC_SCRIPTS="$default_public_scripts" \
  SWIFTVLC_ORIGINAL_SCRIPTS="$default_original_scripts" \
  SWIFTVLC_HELPER_SOURCE="$default_helper_source" \
  SWIFTVLC_RACE_STATE="$default_swap_state" \
  "$default_public_scripts/build-libvlc.sh" --clean \
  > "$temporary_root/default-swap.log" 2>&1
[[ -e "$default_swap_state" ]] || {
  cat "$temporary_root/default-swap.log" >&2
  fail "checkout-local scripts-path race did not execute"
}
[[ ! -e "$default_original_scripts/.build-libvlc" ]] || \
  fail "checkout-local cleanup missed the anchored original build child"
[[ -f "$default_original_scripts/preserve.txt" ]] || \
  fail "checkout-local cleanup removed an original scripts sibling"
[[ -f "$default_public_scripts/.build-libvlc/do-not-delete" ]] || \
  fail "checkout-local cleanup followed the replaced scripts pathname"
[[ -f "$default_public_scripts/.build-libvlc/.swiftvlc-managed-libvlc-build-v1" ]] || \
  fail "checkout-local cleanup removed the replacement ownership marker"
[[ ! -e "$default_checkout_lock" ]] || \
  fail "checkout-local scripts-path race left the output lock behind"
/bin/rm -rf "$default_original_scripts" "$default_public_scripts"

# A crash after detachment can preserve a full native tree under a hidden
# quarantine. Never silently start another large build while that recovery
# state consumes the external volume; report it and leave it untouched.
stale_quarantine=".swiftvlc-libvlc-build.removing-stale-test"
"$real_python3" -B "$DETACH_HELPER" initialize \
  --root "$external_root" \
  --child swiftvlc-libvlc-build \
  --marker-name .swiftvlc-managed-libvlc-build-v1 \
  --marker-content 'SwiftVLC managed libVLC build directory v1'
printf 'recoverable native data\n' > "$managed_child/recover.txt"
"$real_python3" -B "$DETACH_HELPER" detach \
  --root "$external_root" \
  --child swiftvlc-libvlc-build \
  --quarantine "$stale_quarantine" \
  --marker-name .swiftvlc-managed-libvlc-build-v1 \
  --marker-content 'SwiftVLC managed libVLC build directory v1'
if "$BUILD_SCRIPT" --build-root="$external_root" --clean \
  > "$temporary_root/stale-quarantine.log" 2>&1; then
  fail "stale quarantine was silently ignored"
fi
grep -Fq "Found preserved managed-build state" \
  "$temporary_root/stale-quarantine.log" || \
  fail "stale quarantine did not produce recovery guidance"
[[ -f "$external_root/$stale_quarantine/payload/recover.txt" ]] || \
  fail "stale quarantine data was modified"
[[ ! -e "$lock_directory" ]] || fail "stale quarantine failure left root lock"
[[ ! -e "$checkout_lock" ]] || fail "stale quarantine failure left output lock"
"$real_python3" -B "$DETACH_HELPER" remove \
  --root "$external_root" \
  --child swiftvlc-libvlc-build \
  --quarantine "$stale_quarantine" \
  --marker-name .swiftvlc-managed-libvlc-build-v1 \
  --marker-content 'SwiftVLC managed libVLC build directory v1'

# An absent result is safe only if the public name is still absent when the
# shell receives it. Simulate a writer creating unrelated data after the
# helper's final absence observation but before it returns to the caller.
absent_race_bin="$temporary_root/absent-race-bin"
absent_race_state="$temporary_root/absent-race-state"
mkdir "$absent_race_bin"
cat > "$absent_race_bin/python3" <<'EOF'
#!/bin/bash
set -u
"$SWIFTVLC_REAL_PYTHON3" "$@"
status=$?
if [ "${1:-}" = "$SWIFTVLC_DETACH_HELPER" ] &&
   [ "${2:-}" = clean ] &&
   [ "$status" -eq 3 ] &&
   [ ! -e "$SWIFTVLC_RACE_STATE" ]; then
  : > "$SWIFTVLC_RACE_STATE"
  /bin/mkdir "$SWIFTVLC_PUBLIC_BUILD_DIR"
  printf 'unrelated late arrival\n' > \
    "$SWIFTVLC_PUBLIC_BUILD_DIR/do-not-delete"
fi
exit "$status"
EOF
chmod +x "$absent_race_bin/python3"
if PATH="$absent_race_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  SWIFTVLC_REAL_PYTHON3="$real_python3" \
  SWIFTVLC_DETACH_HELPER="$DETACH_HELPER" \
  SWIFTVLC_PUBLIC_BUILD_DIR="$managed_child" \
  SWIFTVLC_RACE_STATE="$absent_race_state" \
  "$BUILD_SCRIPT" --build-root="$external_root" --clean \
  > "$temporary_root/absent-race.log" 2>&1; then
  fail "late-arriving unowned build directory produced a false clean success"
fi
[[ -e "$absent_race_state" ]] || fail "absent-result race did not execute"
grep -Fq "Managed build path appeared during cleanup and was left untouched" \
  "$temporary_root/absent-race.log" || \
  fail "late-arriving build directory did not fail closed"
[[ -f "$managed_child/do-not-delete" ]] || \
  fail "late-arriving build-directory data was deleted"
[[ ! -e "$lock_directory" ]] || fail "absent-result race left root lock"
[[ ! -e "$checkout_lock" ]] || fail "absent-result race left output lock"
/bin/rm -rf "$managed_child"

# Reproduce the original check/use race exactly: the script's initial marker
# verification succeeds, then a non-cooperating writer replaces the public
# child immediately before the descriptor-safe cleanup helper starts. Neither
# the original directory nor the unrelated replacement may be deleted.
mkdir -p "$managed_child"
printf 'SwiftVLC managed libVLC build directory v1\n' > "$marker"
printf 'original managed data\n' > "$managed_child/original.txt"
pre_clean_bin="$temporary_root/pre-clean-bin"
pre_clean_original="$temporary_root/pre-clean-original"
pre_clean_state="$temporary_root/pre-clean-state"
pre_clean_rm_log="$temporary_root/pre-clean-rm.log"
mkdir "$pre_clean_bin"
: > "$pre_clean_rm_log"
cat > "$pre_clean_bin/python3" <<'EOF'
#!/bin/bash
set -eu
if [ "${1:-}" = "$SWIFTVLC_DETACH_HELPER" ] &&
   [ "${2:-}" = clean ] &&
   [ ! -e "$SWIFTVLC_RACE_STATE" ]; then
  : > "$SWIFTVLC_RACE_STATE"
  /bin/mv "$SWIFTVLC_PUBLIC_BUILD_DIR" "$SWIFTVLC_ORIGINAL_BUILD_DIR"
  /bin/mkdir "$SWIFTVLC_PUBLIC_BUILD_DIR"
  printf 'unrelated replacement\n' > \
    "$SWIFTVLC_PUBLIC_BUILD_DIR/do-not-delete"
fi
exec "$SWIFTVLC_REAL_PYTHON3" "$@"
EOF
cat > "$pre_clean_bin/rm" <<'EOF'
#!/bin/bash
set -eu
target=
for argument in "$@"; do
  target="$argument"
done
printf '%s\n' "$target" >> "$SWIFTVLC_RM_LOG"
exec /bin/rm "$@"
EOF
chmod +x "$pre_clean_bin/python3" "$pre_clean_bin/rm"
if PATH="$pre_clean_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  SWIFTVLC_REAL_PYTHON3="$real_python3" \
  SWIFTVLC_DETACH_HELPER="$DETACH_HELPER" \
  SWIFTVLC_PUBLIC_BUILD_DIR="$managed_child" \
  SWIFTVLC_ORIGINAL_BUILD_DIR="$pre_clean_original" \
  SWIFTVLC_RACE_STATE="$pre_clean_state" \
  SWIFTVLC_RM_LOG="$pre_clean_rm_log" \
  "$BUILD_SCRIPT" --build-root="$external_root" --clean \
  > "$temporary_root/pre-clean-race.log" 2>&1; then
  fail "pre-clean replacement was accepted"
fi
[[ -e "$pre_clean_state" ]] || fail "pre-clean race did not execute"
grep -Fq "Could not safely clean managed build directory" \
  "$temporary_root/pre-clean-race.log" || \
  fail "pre-clean race did not fail closed"
[[ -f "$pre_clean_original/original.txt" ]] || \
  fail "original managed directory was lost"
[[ -f "$managed_child/do-not-delete" ]] || \
  fail "unrelated public replacement was deleted"
if grep -Fqx -- "$managed_child" "$pre_clean_rm_log"; then
  fail "recursive rm targeted the public managed path"
fi
[[ ! -e "$lock_directory" ]] || fail "pre-clean race left root lock"
[[ ! -e "$checkout_lock" ]] || fail "pre-clean race left output lock"
/bin/rm -rf "$pre_clean_original" "$managed_child"

mkdir "$lock_directory"
printf 'foreign lock data\n' > "$lock_directory/do-not-delete"
expect_failure \
  "locked external build root" \
  "External build root is locked or has preserved lock state; verify no build is active and inspect this exact managed lock: $lock_directory" \
  --build-root="$external_root" --clean
[[ -f "$lock_directory/do-not-delete" ]] || \
  fail "contended external-root lock was modified"
rm "$lock_directory/do-not-delete"
rmdir "$lock_directory"

expect_failure \
  "duplicate external build root" \
  "--build-root may be specified only once" \
  --build-root="$external_root" --build-root="$external_root" --clean

expect_failure \
  "unknown option after locking" \
  "Unknown argument '--definitely-unknown'" \
  --build-root="$external_root" --definitely-unknown
[[ ! -e "$lock_directory" ]] || fail "failed invocation left its lock behind"

mkdir "$checkout_lock"
printf 'foreign lock data\n' > "$checkout_lock/do-not-delete"
expect_failure \
  "locked checkout artifact output" \
  "This checkout already has a native build or cleanup in progress, or preserved lock state; verify no build is active and inspect this exact managed lock: $checkout_lock" \
  --build-root="$external_root" --clean
[[ ! -e "$lock_directory" ]] || \
  fail "checkout-lock contention left the external-root lock behind"
[[ -f "$checkout_lock/do-not-delete" ]] || \
  fail "contended checkout lock was modified"
rm "$checkout_lock/do-not-delete"
rmdir "$checkout_lock"

# A normal build acquires the checkout lock before resolving HEAD. This fixture
# intentionally has no commit, so the later provenance preflight fails and
# proves the EXIT trap releases the already-acquired lock.
if "$BUILD_SCRIPT" > "$temporary_root/post-lock-failure.log" 2>&1; then
  fail "commitless build fixture unexpectedly passed"
fi
[[ ! -e "$checkout_lock" ]] || fail "post-lock failure left checkout lock behind"

# A failure while releasing one lock must not short-circuit the composed EXIT
# cleanup before the independent external-root lock is attempted.
lock_failure_bin="$temporary_root/lock-failure-bin"
lock_failure_helper_log="$temporary_root/lock-failure-helper.log"
mkdir "$lock_failure_bin"
: > "$lock_failure_helper_log"
cat > "$lock_failure_bin/python3" <<'EOF'
#!/bin/bash
set -eu
if [ "${1:-}" = "$SWIFTVLC_DETACH_HELPER" ] &&
   [ "${2:-}" = lock-release ]; then
  child=
  previous=
  for argument in "$@"; do
    if [ "$previous" = --child ]; then
      child=$argument
    fi
    previous=$argument
  done
  printf '%s\n' "$child" >> "$SWIFTVLC_HELPER_LOG"
  if [ "$child" = swiftvlc-libvlc-output.lock ]; then
    exit 73
  fi
fi
exec "$SWIFTVLC_REAL_PYTHON3" "$@"
EOF
chmod +x "$lock_failure_bin/python3"
if PATH="$lock_failure_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  SWIFTVLC_REAL_PYTHON3="$real_python3" \
  SWIFTVLC_DETACH_HELPER="$DETACH_HELPER" \
  SWIFTVLC_HELPER_LOG="$lock_failure_helper_log" \
  "$BUILD_SCRIPT" --build-root="$external_root" --macos-only \
  > "$temporary_root/lock-cleanup-failure.log" 2>&1; then
  fail "commitless fixture unexpectedly passed with forced lock cleanup failure"
fi
grep -Fq "Could not remove checkout artifact lock: $checkout_lock" \
  "$temporary_root/lock-cleanup-failure.log" || \
  fail "output lock removal failure was not reported"
grep -Fqx -- "swiftvlc-libvlc-output.lock" "$lock_failure_helper_log" || \
  fail "output lock cleanup did not use the descriptor-safe helper"
grep -Fqx -- ".swiftvlc-libvlc-build.lock" "$lock_failure_helper_log" || \
  fail "root-lock cleanup was not attempted after output cleanup failed"
[[ ! -e "$lock_directory" ]] || \
  fail "output cleanup failure prevented root-lock release"
[[ -d "$checkout_lock" ]] || \
  fail "forced output lock removal failure did not preserve the lock"
[[ -f "$checkout_lock/.swiftvlc-lock-generation-v1" ]] || \
  fail "preserved checkout lock lost its generation token"
[[ "$(find "$checkout_lock" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = 1 ]] || \
  fail "preserved checkout lock contains unexpected state"
/bin/rm "$checkout_lock/.swiftvlc-lock-generation-v1"
/bin/rmdir "$checkout_lock"

overlap_root="$temporary_root/overlap-root"
mkdir -p "$overlap_root"
overlap_root=$(cd "$overlap_root" && pwd -P)
overlap_checkout="$overlap_root/swiftvlc-libvlc-build/checkout"
mkdir -p "$overlap_checkout/scripts"
cp "$SOURCE_SCRIPT_DIR/build-libvlc.sh" \
  "$overlap_checkout/scripts/build-libvlc.sh"
cp "$SOURCE_SCRIPT_DIR/detach-managed-build-directory.py" \
  "$overlap_checkout/scripts/detach-managed-build-directory.py"
git -C "$overlap_checkout" init -q
printf 'SwiftVLC managed libVLC build directory v1\n' > \
  "$overlap_root/swiftvlc-libvlc-build/.swiftvlc-managed-libvlc-build-v1"
printf 'preserve checkout\n' > "$overlap_checkout/preserve.txt"
overlap_alias="$temporary_root/overlap-checkout-alias"
ln -s "$overlap_checkout" "$overlap_alias"
if "$overlap_alias/scripts/build-libvlc.sh" \
  --build-root="$overlap_root" --clean \
  > "$temporary_root/overlap.log" 2>&1; then
  fail "managed build directory containing its checkout was accepted"
fi
grep -Fq "external build directory that contains the SwiftVLC checkout" \
  "$temporary_root/overlap.log" || \
  fail "checkout-ancestor rejection did not produce the expected diagnostic"
[[ -f "$overlap_checkout/preserve.txt" ]] || \
  fail "checkout was removed through its logical symlink path"

expect_failure \
  "clean build without external root" \
  "--clean-build requires a canonical external --build-root" \
  --clean-build --all

# Reach real initialization without cloning VLC. The wrapper creates an
# unrelated public child after the script's early absence check but before the
# helper's exclusive staged publish. The helper must neither reuse nor mark it.
git -C "$ROOT_DIR" add scripts
git -C "$ROOT_DIR" \
  -c user.name=SwiftVLC -c user.email=swiftvlc@example.invalid \
  commit -qm fixture

# Vendor authority must be minted while the original checkout is still the
# shell's anchored parent. Move the checkout immediately after output-lock
# acquisition: the physical parent check must reject the public replacement,
# and descriptor-relative EXIT cleanup must still release the original lock.
checkout_swap_bin="$temporary_root/checkout-swap-bin"
checkout_swap_state="$temporary_root/checkout-swap-state"
checkout_swap_original="$temporary_root/repository-bound-original"
checkout_swap_helper_source="$temporary_root/checkout-swap-helper.py"
mkdir "$checkout_swap_bin"
cp "$SOURCE_SCRIPT_DIR/detach-managed-build-directory.py" \
  "$checkout_swap_helper_source"
cat > "$checkout_swap_bin/python3" <<'EOF'
#!/bin/bash
set -eu
"$SWIFTVLC_REAL_PYTHON3" "$@"
status=$?
if [ "$status" -eq 0 ] &&
   [ "${1:-}" = "$SWIFTVLC_PUBLIC_HELPER" ] &&
   [ "${2:-}" = lock-acquire ] &&
   [ ! -e "$SWIFTVLC_RACE_STATE" ]; then
  : > "$SWIFTVLC_RACE_STATE"
  /bin/mv "$SWIFTVLC_PUBLIC_REPO" "$SWIFTVLC_ORIGINAL_REPO"
  /bin/mkdir -p "$SWIFTVLC_PUBLIC_REPO/scripts" \
    "$SWIFTVLC_PUBLIC_REPO/Vendor"
  /bin/cp "$SWIFTVLC_HELPER_SOURCE" "$SWIFTVLC_PUBLIC_HELPER"
  printf 'replacement checkout data\n' > \
    "$SWIFTVLC_PUBLIC_REPO/Vendor/do-not-delete"
fi
exit "$status"
EOF
chmod +x "$checkout_swap_bin/python3"
if PATH="$checkout_swap_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  SWIFTVLC_REAL_PYTHON3="$real_python3" \
  SWIFTVLC_PUBLIC_HELPER="$DETACH_HELPER" \
  SWIFTVLC_PUBLIC_REPO="$ROOT_DIR" \
  SWIFTVLC_ORIGINAL_REPO="$checkout_swap_original" \
  SWIFTVLC_HELPER_SOURCE="$checkout_swap_helper_source" \
  SWIFTVLC_RACE_STATE="$checkout_swap_state" \
  "$BUILD_SCRIPT" --build-root="$external_root" --macos-only \
  > "$temporary_root/checkout-swap.log" 2>&1; then
  fail "checkout replacement before Vendor bind was accepted"
fi
[[ -e "$checkout_swap_state" ]] || \
  fail "checkout replacement before Vendor bind did not execute"
grep -Fq "checkout path changed before Vendor could be anchored" \
  "$temporary_root/checkout-swap.log" || {
  cat "$temporary_root/checkout-swap.log" >&2
  fail "checkout replacement did not fail at the original-parent gate"
}
[[ -f "$ROOT_DIR/Vendor/do-not-delete" ]] || \
  fail "Vendor binding mutated the replacement checkout"
if find "$ROOT_DIR/Vendor" -maxdepth 1 \
  -name '.swiftvlc-managed-output-binding-*' -print -quit | grep -q .; then
  fail "replacement checkout inherited original Vendor authority"
fi
[[ ! -e "$checkout_swap_original/.git/swiftvlc-libvlc-output.lock" ]] || \
  fail "checkout replacement redirected descriptor-safe output-lock cleanup"
/bin/rm -rf "$ROOT_DIR"
/bin/mv "$checkout_swap_original" "$ROOT_DIR"

initialize_bin="$temporary_root/initialize-bin"
initialize_state="$temporary_root/initialize-race-state"
mkdir "$initialize_bin"
cat > "$initialize_bin/tool-ok" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$initialize_bin/tool-ok"
for tool in xcode-select xcodebuild autoconf automake libtool \
  autopoint pkg-config cmake; do
  ln -s tool-ok "$initialize_bin/$tool"
done
cat > "$initialize_bin/df" <<'EOF'
#!/bin/bash
printf '%s\n' \
  'Filesystem 1024-blocks Used Available Capacity Mounted on' \
  'fixture 999999999 0 999999999 0% /'
EOF
chmod +x "$initialize_bin/df"
cat > "$initialize_bin/python3" <<'EOF'
#!/bin/bash
set -eu
if [ "${1:-}" = "$SWIFTVLC_ASSET_VALIDATOR" ]; then
  exit 0
fi
if [ "${1:-}" = "$SWIFTVLC_DETACH_HELPER" ] &&
   [ "${2:-}" = initialize ] &&
   [ ! -e "$SWIFTVLC_RACE_STATE" ]; then
  : > "$SWIFTVLC_RACE_STATE"
  /bin/mkdir "$SWIFTVLC_PUBLIC_BUILD_DIR"
  printf 'unrelated initialization winner\n' > \
    "$SWIFTVLC_PUBLIC_BUILD_DIR/do-not-delete"
fi
exec "$SWIFTVLC_REAL_PYTHON3" "$@"
EOF
chmod +x "$initialize_bin/python3"
if PATH="$initialize_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  MAKEFLAGS=-j1 TERM=dumb LC_ALL=C \
  SWIFTVLC_REAL_PYTHON3="$real_python3" \
  SWIFTVLC_ASSET_VALIDATOR="$ROOT_DIR/scripts/verify-native-validator-assets.py" \
  SWIFTVLC_DETACH_HELPER="$DETACH_HELPER" \
  SWIFTVLC_PUBLIC_BUILD_DIR="$managed_child" \
  SWIFTVLC_RACE_STATE="$initialize_state" \
  "$BUILD_SCRIPT" --build-root="$external_root" --macos-only \
  > "$temporary_root/initialize-race.log" 2>&1; then
  fail "racing unowned build directory was initialized"
fi
[[ -e "$initialize_state" ]] || fail "initialization race did not execute"
grep -Fq "Could not safely initialize managed build directory" \
  "$temporary_root/initialize-race.log" || \
  fail "initialization race did not fail closed"
[[ -f "$managed_child/do-not-delete" ]] || \
  fail "initialization removed the racing directory"
[[ ! -e "$marker" && ! -L "$marker" ]] || \
  fail "initialization blessed a racing unowned directory"
[[ ! -e "$lock_directory" ]] || fail "initialization race left root lock"
[[ ! -e "$checkout_lock" ]] || fail "initialization race left output lock"
/bin/rm -rf "$managed_child" "$ROOT_DIR/Vendor"

# Even a replacement carrying the normal ownership marker must not inherit the
# authority of a directory that this invocation just initialized. Swap the
# child only after the real helper has published its invocation-unique binding;
# the build body must reject the replacement before attempting to clone VLC.
binding_root="$temporary_root/binding-root"
binding_state="$temporary_root/binding-race-state"
binding_clone_log="$temporary_root/binding-clone-attempted"
binding_bin="$temporary_root/binding-bin"
mkdir "$binding_root" "$binding_bin"
binding_root=$(cd "$binding_root" && pwd -P)
binding_original="$binding_root/initialized-original"
binding_replacement="$binding_root/swiftvlc-libvlc-build"
for tool in xcode-select xcodebuild autoconf automake libtool \
  autopoint pkg-config cmake; do
  ln -s "$initialize_bin/tool-ok" "$binding_bin/$tool"
done
ln -s "$initialize_bin/df" "$binding_bin/df"
cat > "$binding_bin/python3" <<'EOF'
#!/bin/bash
set -u
if [ "${1:-}" = "$SWIFTVLC_ASSET_VALIDATOR" ]; then
  exit 0
fi
"$SWIFTVLC_REAL_PYTHON3" "$@"
status=$?
if [ "$status" -eq 0 ] &&
   [ "${1:-}" = "$SWIFTVLC_DETACH_HELPER" ] &&
   [ "${2:-}" = initialize ] &&
   [ ! -e "$SWIFTVLC_RACE_STATE" ]; then
  : > "$SWIFTVLC_RACE_STATE"
  /bin/mv swiftvlc-libvlc-build initialized-original
  printf 'preserve initialized directory\n' > \
    initialized-original/do-not-delete
  /bin/mkdir swiftvlc-libvlc-build
  printf 'SwiftVLC managed libVLC build directory v1\n' > \
    swiftvlc-libvlc-build/.swiftvlc-managed-libvlc-build-v1
  printf 'preserve replacement directory\n' > \
    swiftvlc-libvlc-build/do-not-delete
fi
exit "$status"
EOF
cat > "$binding_bin/git" <<'EOF'
#!/bin/bash
set -eu
if [ "${1:-}" = clone ]; then
  : > "$SWIFTVLC_CLONE_LOG"
  exit 79
fi
exec "$SWIFTVLC_REAL_GIT" "$@"
EOF
chmod +x "$binding_bin/python3" "$binding_bin/git"
if PATH="$binding_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  MAKEFLAGS=-j1 TERM=dumb LC_ALL=C \
  SWIFTVLC_REAL_PYTHON3="$real_python3" \
  SWIFTVLC_REAL_GIT="$(command -v git)" \
  SWIFTVLC_ASSET_VALIDATOR="$ROOT_DIR/scripts/verify-native-validator-assets.py" \
  SWIFTVLC_DETACH_HELPER="$DETACH_HELPER" \
  SWIFTVLC_RACE_STATE="$binding_state" \
  SWIFTVLC_CLONE_LOG="$binding_clone_log" \
  "$BUILD_SCRIPT" --build-root="$binding_root" --macos-only \
  > "$temporary_root/binding-race.log" 2>&1; then
  fail "marker-only replacement bypassed the invocation binding"
fi
[[ -e "$binding_state" ]] || fail "post-initialize binding race did not execute"
grep -Fq "Managed build directory changed before it could be anchored" \
  "$temporary_root/binding-race.log" || \
  fail "marker-only replacement did not fail at the binding gate"
[[ ! -e "$binding_clone_log" ]] || \
  fail "binding mismatch reached the VLC clone step"
[[ -f "$binding_original/.swiftvlc-managed-libvlc-build-v1" ]] || \
  fail "initialized directory lost its ownership marker"
if ! find "$binding_original" -maxdepth 1 -type f \
  -name '.swiftvlc-managed-build-binding-*' -print -quit | grep -q .; then
  fail "initialized directory lost its invocation binding"
fi
[[ -f "$binding_original/do-not-delete" ]] || \
  fail "initialized directory was mutated after being swapped aside"
[[ -f "$binding_replacement/do-not-delete" ]] || \
  fail "marker-only replacement was mutated"
[[ -f "$binding_replacement/.swiftvlc-managed-libvlc-build-v1" ]] || \
  fail "marker-only replacement lost its ownership marker"
if find "$binding_replacement" -maxdepth 1 \
  -name '.swiftvlc-managed-build-binding-*' -print -quit | grep -q .; then
  fail "replacement unexpectedly received an invocation binding"
fi
[[ ! -e "$binding_original/vlc" && ! -e "$binding_replacement/vlc" ]] || \
  fail "binding mismatch mutated a build directory before rejection"
[[ ! -e "$binding_root/.swiftvlc-libvlc-build.lock" ]] || \
  fail "binding mismatch left the external-root lock behind"
[[ ! -e "$checkout_lock" ]] || \
  fail "binding mismatch left the checkout lock behind"
/bin/rm -rf "$binding_root" "$ROOT_DIR/Vendor"

# Exercise the source and checkout-output handoffs without reaching a native
# build. Direct Git commands are blocked so a missing guard cannot reset,
# clean, or clone a fixture before the test reports the regression.
handoff_bin="$temporary_root/handoff-bin"
handoff_git_log="$temporary_root/handoff-direct-git.log"
handoff_race_state="$temporary_root/handoff-race-state"
mkdir "$handoff_bin"
for tool in xcode-select xcodebuild autoconf automake libtool \
  autopoint pkg-config cmake; do
  ln -s "$initialize_bin/tool-ok" "$handoff_bin/$tool"
done
ln -s "$initialize_bin/df" "$handoff_bin/df"
cat > "$handoff_bin/git" <<'EOF'
#!/bin/bash
set -eu
if [ "${1:-}" != -C ]; then
  printf '%s\n' "$*" >> "$SWIFTVLC_GIT_LOG"
  exit 79
fi
exec "$SWIFTVLC_REAL_GIT" "$@"
EOF
cat > "$handoff_bin/python3" <<'EOF'
#!/bin/bash
set -u
if [ "${1:-}" = "$SWIFTVLC_ASSET_VALIDATOR" ]; then
  exit 0
fi
"$SWIFTVLC_REAL_PYTHON3" "$@"
status=$?
if [ "$status" -ne 0 ]; then
  exit "$status"
fi
child=
next_is_child=no
for argument in "$@"; do
  if [ "$next_is_child" = yes ]; then
    child="$argument"
    next_is_child=no
  elif [ "$argument" = --child ]; then
    next_is_child=yes
  fi
done
if [ "${1:-}" = "$SWIFTVLC_DETACH_HELPER" ] &&
   [ "${2:-}" = bind ] &&
   [ "${SWIFTVLC_RACE_MODE:-none}" = source ] &&
   [ "$child" = vlc ] &&
   [ ! -e "$SWIFTVLC_RACE_STATE" ]; then
  : > "$SWIFTVLC_RACE_STATE"
  /bin/mv vlc vlc-bound-original
  /bin/mkdir vlc
  printf 'preserve replacement source\n' > vlc/do-not-delete
fi
exit 0
EOF
chmod +x "$handoff_bin/git" "$handoff_bin/python3"

# A managed build directory does not authorize a symlink at its top-level
# `vlc` entry. Reject it before binding or running any source Git mutation, and
# leave the outside target and the public symlink exactly as they were.
source_symlink_root="$temporary_root/source-symlink-root"
source_symlink_target="$temporary_root/source-symlink-target"
source_symlink_log="$temporary_root/source-symlink.log"
mkdir -p "$source_symlink_root/swiftvlc-libvlc-build" \
  "$source_symlink_target"
source_symlink_root=$(cd "$source_symlink_root" && pwd -P)
printf 'SwiftVLC managed libVLC build directory v1\n' > \
  "$source_symlink_root/swiftvlc-libvlc-build/.swiftvlc-managed-libvlc-build-v1"
printf 'outside source data\n' > "$source_symlink_target/do-not-delete"
ln -s "$source_symlink_target" \
  "$source_symlink_root/swiftvlc-libvlc-build/vlc"
: > "$handoff_git_log"
if PATH="$handoff_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  MAKEFLAGS=-j1 TERM=dumb LC_ALL=C \
  SWIFTVLC_REAL_PYTHON3="$real_python3" \
  SWIFTVLC_REAL_GIT="$(command -v git)" \
  SWIFTVLC_ASSET_VALIDATOR="$ROOT_DIR/scripts/verify-native-validator-assets.py" \
  SWIFTVLC_DETACH_HELPER="$DETACH_HELPER" \
  SWIFTVLC_GIT_LOG="$handoff_git_log" \
  SWIFTVLC_RACE_MODE=none \
  SWIFTVLC_RACE_STATE="$handoff_race_state" \
  "$BUILD_SCRIPT" --build-root="$source_symlink_root" --macos-only \
  > "$source_symlink_log" 2>&1; then
  fail "symlinked VLC source directory was accepted"
fi
grep -Fq \
  "Refusing a symlinked VLC source directory: $source_symlink_root/swiftvlc-libvlc-build/vlc" \
  "$source_symlink_log" || \
  fail "symlinked VLC source did not produce the expected diagnostic"
[[ -L "$source_symlink_root/swiftvlc-libvlc-build/vlc" ]] || \
  fail "symlinked VLC source entry was mutated before rejection"
[[ -f "$source_symlink_target/do-not-delete" ]] || \
  fail "symlinked VLC source target was mutated before rejection"
if find "$source_symlink_target" -maxdepth 1 \
  -name '.swiftvlc-managed-vlc-binding-*' -print -quit | grep -q .; then
  fail "VLC source handoff followed a symlink and bound its outside target"
fi
[[ ! -s "$handoff_git_log" ]] || \
  fail "symlinked VLC source reached a direct Git command"
[[ ! -e "$source_symlink_root/.swiftvlc-libvlc-build.lock" ]] || \
  fail "symlinked VLC source failure left the external-root lock behind"
[[ ! -e "$checkout_lock" ]] || \
  fail "symlinked VLC source failure left the checkout lock behind"
/bin/rm -rf "$source_symlink_root" "$source_symlink_target" "$ROOT_DIR/Vendor"

# Vendor is an independent checkout output boundary. Its descriptor-safe bind
# must reject a symlink without deleting prior evidence through the link.
vendor_symlink_root="$temporary_root/vendor-symlink-root"
vendor_symlink_target="$temporary_root/vendor-symlink-target"
vendor_symlink_log="$temporary_root/vendor-symlink.log"
mkdir "$vendor_symlink_root" "$vendor_symlink_target"
vendor_symlink_root=$(cd "$vendor_symlink_root" && pwd -P)
printf 'outside output data\n' > \
  "$vendor_symlink_target/libvlc-provenance.json"
printf 'outside output sentinel\n' > "$vendor_symlink_target/do-not-delete"
ln -s "$vendor_symlink_target" "$ROOT_DIR/Vendor"
: > "$handoff_git_log"
if PATH="$handoff_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  MAKEFLAGS=-j1 TERM=dumb LC_ALL=C \
  SWIFTVLC_REAL_PYTHON3="$real_python3" \
  SWIFTVLC_REAL_GIT="$(command -v git)" \
  SWIFTVLC_ASSET_VALIDATOR="$ROOT_DIR/scripts/verify-native-validator-assets.py" \
  SWIFTVLC_DETACH_HELPER="$DETACH_HELPER" \
  SWIFTVLC_GIT_LOG="$handoff_git_log" \
  SWIFTVLC_RACE_MODE=none \
  SWIFTVLC_RACE_STATE="$handoff_race_state" \
  "$BUILD_SCRIPT" --build-root="$vendor_symlink_root" --macos-only \
  > "$vendor_symlink_log" 2>&1; then
  fail "symlinked checkout Vendor directory was accepted"
fi
grep -Fq "binding child Vendor is not a directory" \
  "$vendor_symlink_log" || \
  fail "symlinked Vendor was not rejected by the descriptor-safe bind"
grep -Fq "Could not safely anchor the original checkout Vendor output directory" \
  "$vendor_symlink_log" || \
  fail "symlinked Vendor did not produce the expected build diagnostic"
[[ -L "$ROOT_DIR/Vendor" ]] || \
  fail "symlinked Vendor entry was mutated before rejection"
[[ -f "$vendor_symlink_target/do-not-delete" ]] || \
  fail "symlinked Vendor target was mutated before rejection"
grep -Fqx 'outside output data' \
  "$vendor_symlink_target/libvlc-provenance.json" || \
  fail "symlinked Vendor target lost prior provenance evidence"
if find "$vendor_symlink_target" -maxdepth 1 \
  -name '.swiftvlc-managed-output-binding-*' -print -quit | grep -q .; then
  fail "Vendor handoff followed a symlink and bound its outside target"
fi
[[ ! -s "$handoff_git_log" ]] || \
  fail "symlinked Vendor rejection reached a direct Git command"
[[ ! -e "$vendor_symlink_root/.swiftvlc-libvlc-build.lock" ]] || \
  fail "symlinked Vendor failure left the external-root lock behind"
[[ ! -e "$checkout_lock" ]] || \
  fail "symlinked Vendor failure left the checkout lock behind"
/bin/rm "$ROOT_DIR/Vendor"
/bin/rm -rf "$vendor_symlink_root" "$vendor_symlink_target"

# The real helper can bind an existing source directory, after which a
# non-cooperating writer can still replace its public name. The one-use binding
# must make that replacement fail before Git sees either directory.
source_swap_root="$temporary_root/source-swap-root"
source_swap_log="$temporary_root/source-swap.log"
mkdir -p "$source_swap_root/swiftvlc-libvlc-build/vlc"
source_swap_root=$(cd "$source_swap_root" && pwd -P)
printf 'SwiftVLC managed libVLC build directory v1\n' > \
  "$source_swap_root/swiftvlc-libvlc-build/.swiftvlc-managed-libvlc-build-v1"
printf 'preserve original source\n' > \
  "$source_swap_root/swiftvlc-libvlc-build/vlc/do-not-delete"
/bin/rm -f "$handoff_race_state"
: > "$handoff_git_log"
if PATH="$handoff_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  MAKEFLAGS=-j1 TERM=dumb LC_ALL=C \
  SWIFTVLC_REAL_PYTHON3="$real_python3" \
  SWIFTVLC_REAL_GIT="$(command -v git)" \
  SWIFTVLC_ASSET_VALIDATOR="$ROOT_DIR/scripts/verify-native-validator-assets.py" \
  SWIFTVLC_DETACH_HELPER="$DETACH_HELPER" \
  SWIFTVLC_GIT_LOG="$handoff_git_log" \
  SWIFTVLC_RACE_MODE=source \
  SWIFTVLC_RACE_STATE="$handoff_race_state" \
  "$BUILD_SCRIPT" --build-root="$source_swap_root" --macos-only \
  > "$source_swap_log" 2>&1; then
  fail "post-bind VLC source replacement was accepted"
fi
[[ -e "$handoff_race_state" ]] || \
  fail "post-bind VLC source replacement race did not execute"
grep -Fq "Managed VLC source directory changed before it could be anchored" \
  "$source_swap_log" || \
  fail "post-bind VLC source replacement did not fail at the binding gate"
[[ -f "$source_swap_root/swiftvlc-libvlc-build/vlc-bound-original/do-not-delete" ]] || \
  fail "bound original VLC source directory was mutated"
if ! find "$source_swap_root/swiftvlc-libvlc-build/vlc-bound-original" \
  -maxdepth 1 -type f -name '.swiftvlc-managed-vlc-binding-*' \
  -print -quit | grep -q .; then
  fail "bound original VLC source directory lost its one-use binding"
fi
[[ -f "$source_swap_root/swiftvlc-libvlc-build/vlc/do-not-delete" ]] || \
  fail "replacement VLC source directory was mutated"
if find "$source_swap_root/swiftvlc-libvlc-build/vlc" -maxdepth 1 \
  -name '.swiftvlc-managed-vlc-binding-*' -print -quit | grep -q .; then
  fail "replacement VLC source directory inherited the original binding"
fi
[[ ! -s "$handoff_git_log" ]] || \
  fail "post-bind VLC source replacement reached a direct Git command"
[[ ! -e "$source_swap_root/.swiftvlc-libvlc-build.lock" ]] || \
  fail "post-bind VLC source replacement left the external-root lock behind"
[[ ! -e "$checkout_lock" ]] || \
  fail "post-bind VLC source replacement left the checkout lock behind"
/bin/rm -rf "$source_swap_root" "$ROOT_DIR/Vendor"

dirty_repo="$temporary_root/dirty-repository"
mkdir -p "$dirty_repo/scripts"
cp "$SOURCE_SCRIPT_DIR/build-libvlc.sh" "$dirty_repo/scripts/build-libvlc.sh"
cp "$SOURCE_SCRIPT_DIR/detach-managed-build-directory.py" \
  "$dirty_repo/scripts/detach-managed-build-directory.py"
git -C "$dirty_repo" init -q
git -C "$dirty_repo" add \
  scripts/build-libvlc.sh scripts/detach-managed-build-directory.py
git -C "$dirty_repo" \
  -c user.name=SwiftVLC -c user.email=swiftvlc@example.invalid \
  commit -qm fixture
printf 'untracked input\n' > "$dirty_repo/untracked"
dirty_root="$temporary_root/dirty-external-root"
mkdir -p "$dirty_root/swiftvlc-libvlc-build"
dirty_root=$(cd "$dirty_root" && pwd -P)
printf 'SwiftVLC managed libVLC build directory v1\n' > \
  "$dirty_root/swiftvlc-libvlc-build/.swiftvlc-managed-libvlc-build-v1"
printf 'preserve native cache\n' > \
  "$dirty_root/swiftvlc-libvlc-build/preserve.txt"
if "$dirty_repo/scripts/build-libvlc.sh" \
  --build-root="$dirty_root" --clean-build --all \
  > "$temporary_root/dirty-checkout.log" 2>&1; then
  fail "dirty checkout was accepted for a clean native build"
fi
grep -Fq "requires a clean SwiftVLC checkout" \
  "$temporary_root/dirty-checkout.log" || \
  fail "dirty checkout did not produce the expected diagnostic"
[[ -f "$dirty_root/swiftvlc-libvlc-build/preserve.txt" ]] || \
  fail "clean build deleted its cache before rejecting a dirty checkout"
[[ ! -e "$dirty_root/.swiftvlc-libvlc-build.lock" ]] || \
  fail "dirty-checkout failure left external build lock behind"

# Exercise the real startup environment without compiling VLC. A child import
# at --help exit must run, but must not create bytecode in its source directory.
bytecode_fixture="$temporary_root/bytecode-fixture"
mkdir -p "$bytecode_fixture"
printf 'value = 1\n' > "$bytecode_fixture/native_build_fixture_dependency.py"
cat > "$temporary_root/bytecode-env.sh" <<'EOF'
exit() {
  "$SWIFTVLC_REAL_PYTHON3" -c 'import sys; sys.pycache_prefix = None; import native_build_fixture_dependency as dependency; from pathlib import Path; Path(dependency.__file__).with_suffix(".ran").touch()'
  builtin exit "$@"
}
EOF
env -u PYTHONDONTWRITEBYTECODE \
  BASH_ENV="$temporary_root/bytecode-env.sh" \
  PYTHONPATH="$bytecode_fixture" \
  SWIFTVLC_REAL_PYTHON3="$real_python3" \
  "$BUILD_SCRIPT" --help > "$temporary_root/bytecode-help.log"
[[ -f "$bytecode_fixture/native_build_fixture_dependency.ran" ]] || \
  fail "native startup bytecode fixture did not execute"
[[ ! -d "$bytecode_fixture/__pycache__" ]] || \
  fail "native startup allowed validator imports to dirty the checkout"
grep -Fq '?? untracked' "$temporary_root/dirty-checkout.log" || \
  fail "dirty-checkout diagnostic omitted the changed path"

help_output=$("$BUILD_SCRIPT" --help)
grep -Fq -- '--build-root=DIR' <<< "$help_output" || \
  fail "help does not document the external build root"

echo "libVLC build-root tests passed."
