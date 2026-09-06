#!/usr/bin/env python3
"""Record effective build tools and bind compiled caches to their identity."""

import hashlib
import json
import os
import platform
import subprocess
from pathlib import Path


def capture(*command):
    return subprocess.check_output(command, text=True, timeout=30).strip()


def main():
    identity = {
        "architecture": platform.machine(),
        "os": capture("sw_vers"),
        "xcode": capture("xcodebuild", "-version"),
        "swift": capture("xcrun", "swift", "--version"),
        "sdk": capture("xcrun", "--sdk", "macosx", "--show-sdk-version"),
        "sdkBuild": capture("xcrun", "--sdk", "macosx", "--show-sdk-build-version"),
        "python": platform.python_version(),
    }
    payload = json.dumps(identity, sort_keys=True, indent=2)
    fingerprint = hashlib.sha256(payload.encode()).hexdigest()
    print(payload)
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as stream:
            stream.write(f"fingerprint={fingerprint}\n")
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a") as stream:
            stream.write(f"## Build environment\n\n```json\n{payload}\n```\n")
    destination = Path(".build/ci-results/environment.json")
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(payload + "\n")


if __name__ == "__main__":
    main()
