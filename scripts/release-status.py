#!/usr/bin/env python3
"""Read-only release preflight. This never grants publication approval."""

import argparse
import json
import re
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
    remote_ref = command("git", "ls-remote", "origin", "refs/heads/main")
    remote_match = re.fullmatch(r"([0-9a-f]{40}|[0-9a-f]{64})\s+refs/heads/main", remote_ref or "")
    facts["remoteMain"] = remote_match.group(1) if remote_match else None
    if remote_ref is not None and not remote_match:
        blockers.append("Origin did not return a valid main revision.")
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
    local, remote = facts["checkout"], facts["remoteMain"]
    if local and remote and local != remote:
        # Match release.sh's ancestry preflight for the suggested next action.
        # Read the advertised remote SHA, never a potentially stale origin/main.
        counts = command("git", "rev-list", "--left-right", "--count", f"{local}...{remote}")
        if counts is None:
            blockers.append("Fetch origin main, then rerun status to inspect its history locally.")
        else:
            ahead, behind = map(int, counts.split())
            allowed = ahead == 1 and behind == 0
            if not allowed and pulls and ahead == 0 and behind > 0:
                local_tree = command("git", "rev-parse", f"{local}^{{tree}}")
                remote_tree = command("git", "rev-parse", f"{remote}^{{tree}}")
                allowed = local_tree is not None and local_tree == remote_tree
            if not allowed:
                blockers.append("Local main is not an allowed release state: start from exact origin/main, "
                                "resume its one release commit, or finalize an identical-tree fast-forward.")
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
