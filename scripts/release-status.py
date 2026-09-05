#!/usr/bin/env python3
"""Read-only release preflight. This never grants publication approval."""

import argparse
import json
import subprocess
from pathlib import Path


def inspect(root, version, candidate=None):
    blockers = []
    facts = {}

    def command(*args):
        try:
            return subprocess.check_output(args, cwd=root, text=True, stderr=subprocess.PIPE,
                                           timeout=30).strip()
        except (OSError, subprocess.SubprocessError):
            blockers.append(f"Could not complete read-only check: {' '.join(args)}")
            return None

    facts["checkout"] = command("git", "rev-parse", "HEAD")
    facts["branch"] = command("git", "branch", "--show-current")
    if facts["branch"] != "main":
        blockers.append("Release execution requires a main checkout.")
    dirty = command("git", "status", "--porcelain")
    if dirty:
        blockers.append("The checkout has uncommitted or untracked files.")
    facts["remoteMain"] = command("git", "ls-remote", "origin", "refs/heads/main")
    command("gh", "auth", "status")
    artifact = candidate / "libvlc.xcframework" if candidate else root / "Vendor/libvlc.xcframework"
    facts["artifact"] = str(artifact)
    if not artifact.is_dir():
        blockers.append("The native artifact is missing; build/prepare it before publishing.")
    if candidate:
        try:
            metadata = json.loads((candidate / "release-candidate.json").read_text())
            if not isinstance(metadata, dict):
                raise ValueError("candidate manifest is not an object")
            facts["candidate"] = metadata
            if metadata.get("version") != version:
                blockers.append("Candidate version does not match the requested release.")
        except (OSError, ValueError):
            blockers.append("Candidate manifest is missing or invalid.")
    pull = command("gh", "pr", "list", "--repo", "harflabs/SwiftVLC", "--head",
                   f"release-candidates/v{version}", "--state", "all", "--json",
                   "number,state,url,headRefOid,statusCheckRollup")
    if pull is not None:
        try:
            facts["releasePullRequests"] = json.loads(pull)
        except ValueError:
            blockers.append("GitHub returned malformed PR metadata.")
    pulls = facts.get("releasePullRequests", [])
    if not isinstance(pulls, list) or any(not isinstance(pull, dict) for pull in pulls):
        blockers.append("GitHub returned invalid PR metadata.")
        pulls = []
    if len(pulls) > 1:
        blockers.append("Multiple release PRs need reconciliation before continuing.")
    for pull in pulls:
        checks = pull.get("statusCheckRollup") or []
        if not checks:
            blockers.append(f"Release PR #{pull.get('number')} has no visible CI evidence.")
        for check in checks:
            name = check.get("name") or check.get("context") or "unnamed check"
            conclusion = check.get("conclusion") or check.get("state")
            if conclusion not in {"SUCCESS", "NEUTRAL", "SKIPPED"}:
                blockers.append(f"Release CI {name}: {conclusion or check.get('status') or 'unknown'}.")
        if pull.get("state") == "CLOSED":
            blockers.append("The release PR was closed without merging; inspect its remote state.")
    facts["blockers"] = blockers
    facts["nextAction"] = "Resolve the listed blockers." if blockers else (
        "Resume --candidate ... --finalize to verify main CI and reconcile publication." if any(pull.get("state") == "MERGED" for pull in pulls)
        else "Run --candidate ... --finalize; it will recheck exact workflow identities." if pulls
        else "Stage the prepared candidate." if candidate else "Prepare a candidate from verified native build evidence."
    )
    facts["qualification"] = "Not evaluated: this status does not hash artifacts, run validation, or authorize publication."
    return facts


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("version")
    parser.add_argument("--candidate", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    report = inspect(root, args.version, args.candidate)
    print(json.dumps(report, indent=2))
    return 1 if report["blockers"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
