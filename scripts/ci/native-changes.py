#!/usr/bin/env python3
"""Select compiled native validation from actual changed build inputs."""

import os
import re
import subprocess

WORKFLOW = ".github/workflows/test.yml"
# The jobs that decide whether the compiled lane runs, and run it.
NATIVE_LANE_JOBS = ("native-changes", "native-build")


def needs_build(paths):
    exact_inputs = {
        "Tests/SwiftVLCTests/Player/PausedSeekPlaybackTests.swift",
        "Tests/SwiftVLCTests/Player/RemoteMP4SeekTests.swift",
        "Tests/SwiftVLCTests/Player/SeekOutputPlaybackTests.swift",
        "Tests/SwiftVLCTests/Player/ResumeTimelinePlaybackTests.swift",
        "Tests/SwiftVLCTests/Player/TimestampJumpResumePlaybackTests.swift",
        "Tests/SwiftVLCTests/Player/HLSDiscontinuityPlaybackTests.swift",
        "Tests/SwiftVLCTests/Player/RateChangePlaybackTests.swift",
        "Tests/SwiftVLCTests/Player/PlaybackOutcomeNativeTests.swift",
        "Tests/SwiftVLCTests/Support/SeekVideoSink.swift",
        "Tests/SwiftVLCTests/Fixtures/paused-seek.mp4",
        "Package.swift", WORKFLOW,
        "scripts/ci/check-rtsp.py",
        "scripts/ci/tests/test_rtsp_transport.py",
    }
    return any(path in exact_inputs or path.startswith((
        "Tests/SwiftVLCTests/Fixtures/seek-oracle/", "scripts/ci/rtsp", "Sources/CLibVLC/", "scripts/patches/", "scripts/build-libvlc",
        "scripts/native-validator-assets", "scripts/validate-", "scripts/verify-",
        "scripts/fix-duplicate-symbols", "scripts/libvlc-provenance",
        "scripts/artifact-tree-digest.py", "scripts/canonical-libvlc-artifact", "scripts/detach-managed-build-directory",
    )) for path in paths)


def native_lane_definition(workflow):
    """Return the lines of the Tests workflow that define the compiled lane.

    That is everything above `jobs:` (triggers, permissions, concurrency) and
    the jobs in NATIVE_LANE_JOBS. Blank and comment-only lines are dropped: they
    carry no behavior. Every other job runs on each pull request regardless, so
    a change to one is already exercised without an engine build. Returns None
    when the workflow does not have the expected shape, which callers must
    treat as a change.
    """
    lines = [line.rstrip() for line in workflow.splitlines()
             if line.strip() and not line.lstrip().startswith("#")]
    if "jobs:" not in lines:
        return None
    start = lines.index("jobs:")
    kept, found, keep = lines[:start + 1], set(), False
    for line in lines[start + 1:]:
        job = re.fullmatch(r"  ([A-Za-z0-9_-]+):", line)
        if job:
            keep = job.group(1) in NATIVE_LANE_JOBS
            if keep:
                found.add(job.group(1))
        elif not line.startswith(" "):
            keep = True  # a later top-level key applies to every job
        if keep:
            kept.append(line)
    return kept if found == set(NATIVE_LANE_JOBS) else None


def workflow_lane_changed(base, head):
    """Whether two versions of the Tests workflow define the lane differently."""
    before, after = native_lane_definition(base), native_lane_definition(head)
    return before is None or after is None or before != after


def revision_text(revision, path):
    result = subprocess.run(["git", "show", f"{revision}:{path}"],
                            capture_output=True, text=True, timeout=30)
    return result.stdout if result.returncode == 0 else ""


def main():
    build = os.environ.get("FORCE_NATIVE") == "true"
    if os.environ.get("CANDIDATE") != "true" and os.environ.get("EVENT") == "pull_request":
        base = os.environ["BASE_SHA"]
        # A rename outside native directories still removes a native input.
        paths = subprocess.check_output(["git", "diff", "--no-renames", "--name-only", "-z", base, "HEAD", "--"],
                                        text=True, timeout=30).split("\0")
        # An edit to the workflow is a native change only when it alters the
        # lane itself. A missing or unrecognised file compares as changed.
        if WORKFLOW in paths and not workflow_lane_changed(
                revision_text(base, WORKFLOW), revision_text("HEAD", WORKFLOW)):
            paths = [path for path in paths if path != WORKFLOW]
        build = build or needs_build(paths)
    print(f"Compiled native integration required: {build}")
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"build={'true' if build else 'false'}\n")


if __name__ == "__main__":
    main()
