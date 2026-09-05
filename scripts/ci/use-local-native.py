#!/usr/bin/env python3
"""Use the just-built CI artifact, without invoking a released-artifact resolver."""

import re
from pathlib import Path

manifest = Path("Package.swift")
text, count = re.subn(
    r'\.binaryTarget\(\s*name:\s*"libvlc"[^)]*\)',
    '.binaryTarget(name: "libvlc", path: "Vendor/libvlc.xcframework")',
    manifest.read_text(),
)
if count != 1 or not Path("Vendor/libvlc.xcframework/Info.plist").is_file():
    raise SystemExit("Expected one native target and a complete local XCFramework.")
manifest.write_text(text)
