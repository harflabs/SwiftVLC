#!/usr/bin/env python3
"""Replay diagnostics against a failed CI build; never grant release evidence."""

import json
import os
import re
import subprocess
import sys
from pathlib import Path


def main():
    run_id = os.environ["RETAINED_RUN"]
    if not re.fullmatch(r"[0-9]+", run_id):
        raise SystemExit("retained run must be a numeric GitHub run ID")
    repo = os.environ["GITHUB_REPOSITORY"]
    temporary = Path(os.environ["RUNNER_TEMP"])
    retained = temporary / "retained-native-build"
    checkout = temporary / "retained-source-checkout"
    replay = temporary / "retained-native-source"
    metadata = json.loads(subprocess.check_output(
        ["gh", "run", "view", run_id, "--repo", repo, "--json", "headSha"],
        text=True, timeout=30))
    revision = metadata["headSha"]
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise SystemExit("retained run has no exact source revision")
    subprocess.run(["gh", "run", "download", run_id, "--repo", repo,
                    "--name", "unqualified-native-build", "--dir", str(retained)],
                   check=True, timeout=300)
    subprocess.run(["git", "worktree", "add", "--detach", str(checkout), revision],
                   check=True, timeout=60)
    # Replay the retained revision's frozen patches, so private struct layouts
    # match that engine even when the current checkout's probes have changed.
    subprocess.run(["bash", str(checkout / "scripts/validate-native-patch-series-source.sh"),
                    "--work-root", str(replay), "--keep-worktree"],
                   cwd=checkout, check=True, timeout=600)
    roots = list(replay.glob(".swiftvlc-native-source.*/vlc"))
    if len(roots) != 1:
        raise SystemExit("expected one exact retained source replay")
    print(f"DIAGNOSTIC ONLY: retained run {run_id}, source {revision}", flush=True)
    subprocess.run([sys.executable, "-B", "scripts/ci/check-strict-frame-step.py",
                    "--archive", str(retained / ".swiftvlc-native-output/libvlc.xcframework/macos-arm64_x86_64/libvlc.a"),
                    "--source-root", str(roots[0]),
                    "--build-root", str(retained / "build-macosx-arm64/build"),
                    "--repetitions", "20"], check=True, timeout=600)


if __name__ == "__main__":
    main()
