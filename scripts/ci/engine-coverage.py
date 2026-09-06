#!/usr/bin/env python3
"""Report native patch divergence without granting lint draft access."""

import hashlib
import json
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def patch_changes(released, current):
    return {
        "added": sorted(current.keys() - released.keys()),
        "removed": sorted(released.keys() - current.keys()),
        "modified": sorted(name for name in current.keys() & released.keys()
                           if current[name] != released[name]),
    }


def emit(state, message):
    message = message.replace("\r", " ").replace("\n", " ")
    print(f"Engine coverage {state}: {message}")
    if state != "covered" and os.environ.get("GITHUB_ACTIONS") == "true":
        print(f"::warning title=Engine coverage {state}::{message.replace('%', '%25')}")
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a") as output:
            output.write(f"\nEngine coverage **{state}**: {message}\n")


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True, stderr=subprocess.PIPE,
                                   timeout=60)


def main():
    # Lint cannot read drafts. Exact-draft verification belongs to build jobs.
    if os.environ.get("SWIFTVLC_RELEASE_CANDIDATE_LINT") == "1":
        emit("candidate", "Exact draft artifact validation belongs to candidate build jobs; public release coverage is not yet available.")
        return
    try:
        info = json.loads(run(str(ROOT / "scripts/resolve-release-artifact.sh")))
        entries = run("git", "ls-tree", "-r", info["releaseCommit"], "scripts/patches/")
        released = {}
        for entry in entries.splitlines():
            metadata, name = entry.split("\t", 1)
            if name.endswith(".patch"):
                payload = subprocess.check_output(["git", "cat-file", "blob", metadata.split()[2]], cwd=ROOT, timeout=10)
                released[Path(name).name] = hashlib.sha256(payload).hexdigest()
        current = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                   for p in (ROOT / "scripts/patches").glob("*.patch")}
        if not released or not current:
            raise ValueError("empty patch inventory")
        changes = patch_changes(released, current)
        if any(changes.values()):
            emit("diverged", f"{info['tag']}: " + json.dumps(changes, sort_keys=True))
        else:
            emit("covered", f"All {len(current)} patch contents match {info['tag']}.")
    except (OSError, subprocess.SubprocessError, ValueError, KeyError) as error:
        emit("unknown", f"Cannot establish released-engine coverage ({type(error).__name__}); inspect artifact access and metadata. No coverage claim made.")


if __name__ == "__main__":
    main()
