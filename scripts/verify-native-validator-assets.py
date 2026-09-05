#!/usr/bin/env python3
"""Verify the complete, ordered native-validator asset inventory.

The libVLC artifact provenance records this verifier and its manifest. The
manifest in turn binds every source checker, ABI fixture, and native probe used
to decide whether the shared SwiftVLC extension contract is fit to ship.
"""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import re
import stat
import tempfile
from typing import Optional

MANIFEST_RELATIVE_PATH = Path("scripts/native-validator-assets.sha256")
MANIFEST_LINE = re.compile(r"([0-9a-f]{64})  ([!-~]+)")

# Keep this tuple bytewise sorted. Verification requires the manifest to have
# this exact inventory and order, so deleting a line cannot silently remove a
# validator from artifact provenance.
ASSET_PATHS = (
    "scripts/patches/validation/adaptive-es-recycling-source-check.py",
    "scripts/patches/validation/aom-nasm3-detection-probe.cmake",
    "scripts/patches/validation/aom-nasm3-detection-source-check.py",
    "scripts/patches/validation/audio-media-services-reset-source-check.py",
    "scripts/patches/validation/effective-playback-rate-event-abi.c",
    "scripts/patches/validation/effective-playback-rate-event-abi.cpp",
    "scripts/patches/validation/effective-playback-rate-event-probe.c",
    "scripts/patches/validation/effective-playback-rate-event-source-check.py",
    "scripts/patches/validation/headless-vout-teardown-probe.c",
    "scripts/patches/validation/headless-vout-teardown-source-check.py",
    "scripts/patches/validation/native-extension-version-probe.c",
    "scripts/patches/validation/native-pip-output-identity-race.c",
    "scripts/patches/validation/native-pip-output-identity-source-check.py",
    "scripts/patches/validation/native-sample-buffer-renderer-immediate-sample.m",
    "scripts/patches/validation/native-sample-buffer-renderer-recovery.c",
    "scripts/patches/validation/pip-playback-snapshot-probe.c",
    "scripts/patches/validation/pip_extension_version.py",
    "scripts/patches/validation/sample-buffer-renderer-snapshot-abi.c",
    "scripts/patches/validation/sample-buffer-renderer-snapshot-abi.cpp",
    "scripts/patches/validation/strict-frame-step-probe.c",
    "scripts/patches/validation/strict-frame-step-source-check.py",
    "scripts/patches/validation/subtitle-text-snapshot.c",
    "scripts/patches/validation/test_pip_extension_version.py",
    "scripts/patches/validation/vmem-configuration-race.c",
    "scripts/patches/validation/vmem-picture-pts-abi.cpp",
    "scripts/patches/validation/vmem-picture-pts-probe.c",
    "scripts/patches/validation/vmem-picture-pts-source-check.py",
    "scripts/tests/test_pip_extension_version.py",
    "scripts/validate-aom-nasm3-detection.sh",
    "scripts/validate-audio-media-services-reset.sh",
    "scripts/validate-effective-playback-rate-event.sh",
    "scripts/validate-headless-vout-teardown.sh",
    "scripts/validate-native-extension-contract.sh",
    "scripts/validate-native-patch-series-source.sh",
    "scripts/validate-pip-playback-snapshot.sh",
    "scripts/validate-sample-buffer-renderer-recovery.sh",
    "scripts/validate-strict-frame-step.sh",
    "scripts/validate-vmem-picture-pts.sh",
)

# File modes are part of the executable evidence contract too. Most Python/C
# assets are data consumed explicitly by an interpreter or compiler. The two
# historically executable source checkers and every shell entry point retain
# their tracked executable intent; everything else must remain non-executable.
EXECUTABLE_ASSET_PATHS = (
    "scripts/patches/validation/effective-playback-rate-event-source-check.py",
    "scripts/patches/validation/vmem-picture-pts-source-check.py",
    "scripts/validate-aom-nasm3-detection.sh",
    "scripts/validate-audio-media-services-reset.sh",
    "scripts/validate-effective-playback-rate-event.sh",
    "scripts/validate-headless-vout-teardown.sh",
    "scripts/validate-native-extension-contract.sh",
    "scripts/validate-native-patch-series-source.sh",
    "scripts/validate-pip-playback-snapshot.sh",
    "scripts/validate-sample-buffer-renderer-recovery.sh",
    "scripts/validate-strict-frame-step.sh",
    "scripts/validate-vmem-picture-pts.sh",
)


class ManifestError(RuntimeError):
    """A validator asset or its manifest is incomplete or inconsistent."""


def validate_inventory() -> None:
    if ASSET_PATHS != tuple(sorted(ASSET_PATHS)):
        raise ManifestError(
            "native validator asset inventory is not in canonical bytewise order"
        )
    if len(set(ASSET_PATHS)) != len(ASSET_PATHS):
        raise ManifestError("native validator asset inventory contains a duplicate path")
    if EXECUTABLE_ASSET_PATHS != tuple(sorted(EXECUTABLE_ASSET_PATHS)):
        raise ManifestError(
            "native validator executable-mode inventory is not in canonical bytewise order"
        )
    if len(set(EXECUTABLE_ASSET_PATHS)) != len(EXECUTABLE_ASSET_PATHS):
        raise ManifestError(
            "native validator executable-mode inventory contains a duplicate path"
        )
    unexpected = set(EXECUTABLE_ASSET_PATHS).difference(ASSET_PATHS)
    if unexpected:
        raise ManifestError(
            "native validator executable-mode inventory has unexpected paths: "
            + ", ".join(sorted(unexpected))
        )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def asset_path(root: Path, relative: str) -> Path:
    path = root / relative
    if path.is_symlink() or not path.is_file() or path.resolve() != path.absolute():
        raise ManifestError(
            f"native validator asset is missing, linked, or not a regular file: {relative}"
        )
    expected_mode = 0o755 if relative in EXECUTABLE_ASSET_PATHS else 0o644
    actual_mode = stat.S_IMODE(path.stat().st_mode)
    if actual_mode != expected_mode:
        raise ManifestError(
            "native validator asset mode mismatch: "
            f"{relative}\n  expected {expected_mode:04o}\n  actual   {actual_mode:04o}"
        )
    return path


def expected_records(root: Path) -> list[tuple[str, str]]:
    return [
        (sha256_file(asset_path(root, relative)), relative) for relative in ASSET_PATHS
    ]


def read_manifest(path: Path) -> list[tuple[str, str]]:
    try:
        raw = path.read_bytes()
    except OSError as error:
        raise ManifestError(
            f"cannot read native validator asset manifest {path}: {error}"
        ) from error
    if b"\r" in raw:
        raise ManifestError("native validator asset manifest must use LF line endings")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ManifestError("native validator asset manifest is not UTF-8") from error
    if not text or not text.endswith("\n"):
        raise ManifestError(
            "native validator asset manifest must be nonempty and newline-terminated"
        )

    records: list[tuple[str, str]] = []
    seen: set[str] = set()
    for line_number, line in enumerate(text.splitlines(), 1):
        match = MANIFEST_LINE.fullmatch(line)
        if match is None:
            raise ManifestError(
                f"invalid native validator manifest line {line_number}: {line!r}"
            )
        digest, relative = match.groups()
        if relative in seen:
            raise ManifestError(f"duplicate native validator asset: {relative}")
        seen.add(relative)
        records.append((digest, relative))
    return records


def verify(root: Path, manifest: Path) -> None:
    if (
        manifest.is_symlink()
        or not manifest.is_file()
        or manifest.resolve() != manifest.absolute()
    ):
        raise ManifestError(
            f"native validator asset manifest is missing, linked, or not a regular file: {manifest}"
        )
    actual = read_manifest(manifest)
    actual_paths = tuple(relative for _, relative in actual)
    if actual_paths != ASSET_PATHS:
        missing = sorted(set(ASSET_PATHS) - set(actual_paths))
        unexpected = sorted(set(actual_paths) - set(ASSET_PATHS))
        details = []
        if missing:
            details.append("missing: " + ", ".join(missing))
        if unexpected:
            details.append("unexpected: " + ", ".join(unexpected))
        if not details:
            details.append("entries are not in canonical bytewise order")
        raise ManifestError(
            "native validator asset inventory mismatch (" + "; ".join(details) + ")"
        )

    for (expected_digest, relative), (current_digest, _) in zip(
        actual, expected_records(root)
    ):
        if expected_digest != current_digest:
            raise ManifestError(
                "native validator asset hash mismatch: "
                f"{relative}\n  expected {expected_digest}\n  actual   {current_digest}\n"
                "If the change is intentional, run "
                "`python3 scripts/verify-native-validator-assets.py --update`."
            )


def update(root: Path, manifest: Path) -> None:
    records = expected_records(root)
    manifest.parent.mkdir(parents=True, exist_ok=True)
    if (
        manifest.is_symlink()
        or (manifest.exists() and not manifest.is_file())
        or manifest.parent.resolve() != manifest.parent.absolute()
    ):
        raise ManifestError(
            f"refusing to replace a linked or non-regular manifest: {manifest}"
        )
    payload = "".join(f"{digest}  {relative}\n" for digest, relative in records)
    descriptor, staged_name = tempfile.mkstemp(
        prefix=f".{manifest.name}.", suffix=".tmp", dir=manifest.parent
    )
    staged = Path(staged_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(staged, 0o644)
        os.replace(staged, manifest)
    finally:
        staged.unlink(missing_ok=True)


def resolve_manifest(root: Path, value: Optional[Path]) -> Path:
    if value is None:
        return root / MANIFEST_RELATIVE_PATH
    return value if value.is_absolute() else root / value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path)
    parser.add_argument("--manifest", type=Path)
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument("--update", action="store_true")
    actions.add_argument("--list", action="store_true")
    arguments = parser.parse_args()

    try:
        validate_inventory()
        if arguments.list:
            print("\n".join(ASSET_PATHS))
            return 0

        root = (
            arguments.root.resolve()
            if arguments.root is not None
            else Path(__file__).resolve().parent.parent
        )
        manifest = resolve_manifest(root, arguments.manifest).absolute()
        if arguments.update:
            update(root, manifest)
            print(f"Wrote {manifest} ({len(ASSET_PATHS)} native validator assets)")
        else:
            verify(root, manifest)
            print(f"Verified {len(ASSET_PATHS)} native validator assets: {manifest}")
    except (ManifestError, OSError) as error:
        parser.exit(1, f"error: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
