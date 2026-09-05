#!/usr/bin/env python3
"""Prove native inputs unchanged before reusing an immutable candidate artifact.

Unknown paths fail closed. This does not rewrite provenance or grant test or
device qualification credit; release.sh still verifies the bytes and proof.
"""

import argparse
import importlib.util
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def non_native_path(path):
    return path.startswith(("Sources/SwiftVLC/", "Tests/SwiftVLCTests/", "Showcase/",
                            ".github/", "docs/", "scripts/ci/", "scripts/tests/",
                            "scripts/qualification/")) or path in {
        "README.md", "CHANGELOG.md", "CONTRIBUTING.md", "CLAUDE.md", "AGENTS.md",
        "LICENSE", ".gitignore", ".swiftlint.yml", ".swiftformat",
        "scripts/release.sh", "scripts/release-runner.py", "scripts/release-status.py",
        "scripts/release-source-digest.py", "scripts/release-version-policy.py",
        "scripts/native-reuse.py", "scripts/check-qualification.sh",
        "scripts/check-engine-coverage.sh", "scripts/ci-run-with-timeouts.py",
    }


def verify(root, revision):
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("native source revision must be a full commit SHA")
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=root, timeout=30)
    subprocess.run(["git", "merge-base", "--is-ancestor", revision, "HEAD"],
                   cwd=root, check=True, timeout=30)
    paths = git("diff", "--name-only", "-z", revision, "HEAD", "--").decode().split("\0")
    blocked = [path for path in paths if path and path != "Package.swift" and not non_native_path(path)]
    if "Package.swift" in paths:
        # Only the existing canonical URL/local-artifact rewrite is exempt.
        spec = importlib.util.spec_from_file_location("release_digest", ROOT / "scripts/release-source-digest.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        old = module.normalized_package_manifest(git("show", f"{revision}:Package.swift"))
        new = module.normalized_package_manifest(git("show", "HEAD:Package.swift"))
        if old != new:
            blocked.append("Package.swift")
    if blocked:
        raise ValueError("native reuse requires a rebuild for changed/unknown inputs: " + ", ".join(blocked))
    return revision


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("revision")
    args = parser.parse_args()
    try:
        print(verify(ROOT, args.revision))
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Error: {error}\n")


if __name__ == "__main__":
    main()
