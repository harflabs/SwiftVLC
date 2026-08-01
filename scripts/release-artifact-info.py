#!/usr/bin/env python3
"""Read and validate SwiftVLC's libvlc binary-target release identity."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Dict, NoReturn, Optional


TARGET_PATTERN = re.compile(
    r'\.binaryTarget\(\s*name:\s*"libvlc"(?P<body>.*?)\n\s*\)',
    re.DOTALL,
)
URL_PATTERN = re.compile(r'\burl:\s*"(?P<url>[^"]+)"')
CHECKSUM_PATTERN = re.compile(r'\bchecksum:\s*"(?P<checksum>[a-f0-9]{64})"')
TAG_PATTERN = re.compile(
    r"^https://github\.com/harflabs/SwiftVLC/releases/download/"
    r"(?P<tag>v[^/]+)/libvlc\.xcframework\.zip$"
)


def fail(message: str) -> NoReturn:
    raise SystemExit(f"Error: {message}")


def parse_manifest(text: str, expected_tag: Optional[str]) -> Dict[str, str]:
    matches = list(TARGET_PATTERN.finditer(text))
    if len(matches) != 1:
        fail(f"expected exactly one libvlc binary target, found {len(matches)}")

    body = matches[0].group("body")
    url_match = URL_PATTERN.search(body)
    checksum_match = CHECKSUM_PATTERN.search(body)
    if url_match is None or checksum_match is None:
        fail("libvlc binary target must use a release URL and a 64-character checksum")

    url = url_match.group("url")
    checksum = checksum_match.group("checksum")
    tag_match = TAG_PATTERN.match(url)
    if tag_match is None:
        fail(f"libvlc URL is not a SwiftVLC GitHub release asset: {url}")

    tag = tag_match.group("tag")
    if expected_tag is not None and tag != expected_tag:
        fail(f"manifest resolves {tag}, expected {expected_tag}")

    return {"tag": tag, "url": url, "checksum": checksum}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path, help="Package.swift to inspect")
    parser.add_argument("--expect-tag")
    parser.add_argument("--field", choices=("tag", "url", "checksum"))
    arguments = parser.parse_args()

    try:
        text = arguments.manifest.read_text()
    except OSError as error:
        fail(f"cannot read {arguments.manifest}: {error}")

    result = parse_manifest(text, arguments.expect_tag)
    if arguments.field is not None:
        print(result[arguments.field])
    else:
        print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
