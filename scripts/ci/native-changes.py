#!/usr/bin/env python3
"""Select compiled native validation from actual changed build inputs."""

import os
import subprocess


def needs_build(paths):
    return any(path == "Package.swift" or path.startswith((
        "Sources/CLibVLC/", "scripts/patches/", "scripts/build-libvlc",
        "scripts/native-validator-assets", "scripts/validate-", "scripts/verify-",
        "scripts/fix-duplicate-symbols", "scripts/libvlc-provenance",
        "scripts/artifact-tree-digest.py", "scripts/canonical-libvlc-artifact", "scripts/detach-managed-build-directory",
    )) for path in paths)


def main():
    build = os.environ.get("FORCE_NATIVE") == "true"
    if os.environ.get("CANDIDATE") != "true" and os.environ.get("EVENT") == "pull_request":
        base = os.environ["BASE_SHA"]
        # A rename outside native directories still removes a native input.
        paths = subprocess.check_output(["git", "diff", "--no-renames", "--name-only", "-z", base, "HEAD", "--"],
                                        text=True, timeout=30).split("\0")
        build = build or needs_build(paths)
    print(f"Compiled native integration required: {build}")
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"build={'true' if build else 'false'}\n")


if __name__ == "__main__":
    main()
