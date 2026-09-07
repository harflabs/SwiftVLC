#!/usr/bin/env python3
"""Configure the disposable iOS qualification project for a tester's team."""

from __future__ import annotations

import argparse
import os
import re
import tempfile
from pathlib import Path


TEAM_PATTERN = re.compile(r"^[A-Z0-9]{10}$")
BUNDLE_PREFIX_PATTERN = re.compile(
    r"^[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+$"
)


def configure(project: Path, team: str, bundle_prefix: str) -> tuple[str, str]:
    if not TEAM_PATTERN.fullmatch(team):
        raise ValueError("development team must be a 10-character Apple team identifier")
    if not BUNDLE_PREFIX_PATTERN.fullmatch(bundle_prefix):
        raise ValueError("bundle prefix must be a reverse-DNS identifier")

    text = project.read_text()
    text, team_count = re.subn(
        r"DEVELOPMENT_TEAM = [A-Z0-9]{10};",
        f"DEVELOPMENT_TEAM = {team};",
        text,
    )
    if team_count != 2:
        raise ValueError(f"expected 2 iOS development-team settings, found {team_count}")

    app_id = f"{bundle_prefix}.app"
    tests_id = f"{bundle_prefix}.uitests"
    text, app_count = re.subn(
        r"PRODUCT_BUNDLE_IDENTIFIER = com\.swiftvlc\.showcase\.ios;",
        f"PRODUCT_BUNDLE_IDENTIFIER = {app_id};",
        text,
    )
    text, tests_count = re.subn(
        r"PRODUCT_BUNDLE_IDENTIFIER = com\.swiftvlc\.showcase\.ios\.uitests;",
        f"PRODUCT_BUNDLE_IDENTIFIER = {tests_id};",
        text,
    )
    if app_count != 2 or tests_count != 2:
        raise ValueError(
            "expected 2 app and 2 UI-test bundle-id settings, "
            f"found {app_count} and {tests_count}"
        )

    with tempfile.NamedTemporaryFile(
        mode="w", dir=project.parent, prefix=f".{project.name}.", delete=False
    ) as output:
        os.fchmod(output.fileno(), project.stat().st_mode & 0o7777)
        output.write(text)
        temporary = Path(output.name)
    temporary.replace(project)
    return app_id, tests_id


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("project", type=Path)
    parser.add_argument("--team", required=True)
    parser.add_argument("--bundle-prefix", required=True)
    args = parser.parse_args()

    try:
        app_id, tests_id = configure(args.project, args.team, args.bundle_prefix)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(f"appBundleIdentifier={app_id}")
    print(f"uiTestBundleIdentifier={tests_id}")


if __name__ == "__main__":
    main()
