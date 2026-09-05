#!/usr/bin/env python3
"""Validate non-negotiable features in one libvlc archive-member list.

Archive manifests are useful drift detectors, but a regenerated manifest can
otherwise bless a broken rebuild.  This validator encodes the small set of
semantic object-level invariants that must survive every intentional rebuild.
"""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from pathlib import Path
import sys


RENDERER_CORE_OBJECTS = (
    "libvlc_la-renderer_discoverer.o",
    "libvlccore_la-renderer_discovery.o",
)

CHROMECAST_OBJECTS = (
    "libdemux_chromecast_plugin_la-chromecast_demux.o",
    "libstream_out_chromecast_plugin_la-cast.o",
    "libstream_out_chromecast_plugin_la-cast_channel.pb.o",
    "libstream_out_chromecast_plugin_la-chromecast_communication.o",
    "libstream_out_chromecast_plugin_la-chromecast_ctrl.o",
    "libstream_out_chromecast_plugin_la-renderer_common.o",
)

APPLE_AUDIO_SESSION_OBJECT = "libvlccore_objc_la-apple_audio_session.o"

CASTING_SLICE_PREFIXES = ("ios-", "macos-", "xros-")
TVOS_SLICE_PREFIX = "tvos-"


def parse_members(path: Path) -> tuple[dict[str, Counter[str]], list[str]]:
    members_by_arch: dict[str, Counter[str]] = defaultdict(Counter)
    errors: list[str] = []

    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        return {}, [f"cannot read {path}: {error}"]

    for line_number, line in enumerate(lines, start=1):
        fields = line.split()
        if len(fields) != 2:
            errors.append(
                f"{path}:{line_number}: expected '<arch> <member>', got {line!r}"
            )
            continue
        arch, member = fields
        members_by_arch[arch][member] += 1

    if not members_by_arch and not errors:
        errors.append(f"{path}: archive-member list is empty")

    return dict(members_by_arch), errors


def validate_contract(slice_name: str, path: Path) -> list[str]:
    members_by_arch, errors = parse_members(path)
    if errors:
        return errors

    if slice_name.startswith(CASTING_SLICE_PREFIXES):
        required_objects = RENDERER_CORE_OBJECTS + CHROMECAST_OBJECTS
        for arch, members in sorted(members_by_arch.items()):
            for member in required_objects:
                count = members[member]
                if count == 0:
                    errors.append(
                        f"{slice_name}/{arch}: required object is missing: {member}"
                    )
                elif count != 1:
                    errors.append(
                        f"{slice_name}/{arch}: required object occurs {count} times: "
                        f"{member}"
                    )
    elif slice_name.startswith(TVOS_SLICE_PREFIX):
        forbidden = set(CHROMECAST_OBJECTS)
        for arch, members in sorted(members_by_arch.items()):
            for member in RENDERER_CORE_OBJECTS:
                count = members[member]
                if count == 0:
                    errors.append(
                        f"{slice_name}/{arch}: required object is missing: {member}"
                    )
                elif count != 1:
                    errors.append(
                        f"{slice_name}/{arch}: required object occurs {count} times: "
                        f"{member}"
                    )

            forbidden_members = sorted(
                member
                for member in members
                if member in forbidden or "chromecast" in member.lower()
            )
            for member in forbidden_members:
                errors.append(
                    f"{slice_name}/{arch}: Chromecast object is forbidden on tvOS: "
                    f"{member}"
                )
    else:
        return [
            f"{slice_name}: unsupported slice; classify its renderer/casting policy "
            "before accepting the artifact"
        ]

    # beta.8 predates the Objective-C audio-session broker, so historical
    # inventories may omit it. Once any architecture contains the broker,
    # require one copy in every architecture: a partial universal archive is
    # never a valid transition state. The release gate separately requires the
    # complete native-v10 lease contract for 1.1.0 candidates.
    audio_counts = {
        arch: members[APPLE_AUDIO_SESSION_OBJECT]
        for arch, members in members_by_arch.items()
    }
    if any(audio_counts.values()):
        for arch, count in sorted(audio_counts.items()):
            if count != 1:
                errors.append(
                    f"{slice_name}/{arch}: Apple audio-session object occurs "
                    f"{count} times; expected exactly once in every architecture"
                )

    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--slice", required=True, dest="slice_name")
    parser.add_argument("--members", required=True, type=Path)
    arguments = parser.parse_args()

    errors = validate_contract(arguments.slice_name, arguments.members)
    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
