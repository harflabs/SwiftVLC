#!/usr/bin/env python3
"""Replay diagnostics against a failed CI build; never grant release evidence."""

import os
import re
import subprocess
import sys
from pathlib import Path


def source_revision(log):
    revisions = set(re.findall(r"SwiftVLC source provenance: ([0-9a-f]{40})\b", log))
    if len(revisions) != 1:
        raise ValueError("retained build log must contain one unambiguous compiled source revision")
    return revisions.pop()


def main():
    run_id = os.environ["RETAINED_RUN"]
    if not re.fullmatch(r"[0-9]+", run_id):
        raise SystemExit("retained run must be a numeric GitHub run ID")
    repo = os.environ["GITHUB_REPOSITORY"]
    temporary = Path(os.environ["RUNNER_TEMP"])
    retained = temporary / "retained-native-build"
    checkout = temporary / "retained-source-checkout"
    replay = temporary / "retained-native-source"
    evidence = temporary / "retained-native-evidence"
    subprocess.run(["gh", "run", "download", run_id, "--repo", repo,
                    "--name", "compiled-native-evidence", "--dir", str(evidence)],
                   check=True, timeout=120)
    logs = list(evidence.rglob("native-build.log"))
    if len(logs) != 1:
        raise SystemExit("expected one retained native build log")
    revision = source_revision(logs[0].read_text())
    # PR jobs build a synthetic merge commit, which may contain native changes
    # from main absent from the branch head reported by the workflow-run API.
    subprocess.run(["git", "fetch", "--no-tags", "origin", revision],
                   check=True, timeout=120)
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
