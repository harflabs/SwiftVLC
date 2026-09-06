#!/usr/bin/env python3
"""Exercise the released engine's frame-step probe without rebuilding VLC.

This is diagnostic behavior evidence, not native provenance or release approval.
The caller must resolve the declared artifact or explicitly supply a retained
CI archive with its matching source and generated build headers.
"""

import argparse
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FRAMEWORKS = """AppKit AudioToolbox AudioUnit AVFoundation AVKit CoreAudio
CoreFoundation CoreGraphics CoreImage CoreMedia CoreServices CoreText CoreVideo
Foundation IOKit IOSurface OpenGL QuartzCore Security SystemConfiguration
VideoToolbox""".split()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repetitions", type=int, default=20)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--build-root", type=Path)
    args = parser.parse_args()
    if bool(args.source_root) != bool(args.build_root):
        parser.error("source and build roots must be supplied together")
    if not 1 <= args.repetitions <= 100:
        parser.error("repetitions must be between 1 and 100")
    archive = args.archive or ROOT / "Vendor/libvlc.xcframework/macos-arm64_x86_64/libvlc.a"
    fixture = ROOT / "Tests/SwiftVLCTests/Fixtures/twosec.mp4"
    if not archive.is_file() or not fixture.is_file():
        parser.error("verified macOS artifact and seekable fixture are required")
    with tempfile.TemporaryDirectory(prefix="swiftvlc-ci-native-probe-") as temporary:
        work = Path(temporary)
        links = [str(archive)]
        for framework in FRAMEWORKS:
            links += ["-framework", framework]
        links += ["-lbz2", "-lc++", "-liconv", "-lresolv", "-lsqlite3", "-lxml2", "-lz"]

        def compile(source, output, *flags):
            subprocess.run(["xcrun", "clang", "-std=c11", *flags,
                            "-I", str(ROOT / "Sources/CLibVLC/include"),
                            str(source), *links, "-o", str(output)], check=True, timeout=120)

        # Match the declared binary's ABI; fresh-build qualification separately
        # enforces the source revision and exact required extension version.
        identity = work / "identity.c"
        identity.write_text('#include <stdio.h>\n#include <vlc/vlc.h>\n'
                            'int main(void) { printf("%u\\n", swiftvlc_libvlc_pip_extensions_version()); }\n')
        compile(identity, work / "identity")
        version = int(subprocess.check_output([str(work / "identity")], text=True, timeout=10))
        if not 4 <= version <= 127:
            parser.error(f"unsupported strict-frame ABI version: {version}")
        flags = [f"-DSWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION={version}"]
        if args.source_root:
            if not (args.build_root / "config.h").is_file():
                parser.error("retained generated config.h is required")
            if version >= 9:
                flags += ["-DSWIFTVLC_REQUIRE_APPLE_AUDIO_SESSION_LEASES=1"]
            flags += ["-std=gnu17", "-DHAVE_CONFIG_H", "-DSWIFTVLC_SOURCE_LINKED_PROBE"]
            # Use the retained build's private headers before current public ones.
            for include in (args.build_root, args.source_root, args.source_root / "include",
                            args.source_root / "lib", args.source_root / "src", args.build_root / "include"):
                flags += ["-I", str(include)]
        probe = work / "probe"
        compile(ROOT / "scripts/patches/validation/strict-frame-step-probe.c", probe,
                *flags)
        registry_probe = work / "registry-probe" if args.source_root else None
        if registry_probe:
            compile(ROOT / "scripts/patches/validation/vmem-configuration-race.c",
                    registry_probe, *flags)
        for attempt in range(1, args.repetitions + 1):
            print(f"Strict-frame diagnostic probe {attempt}/{args.repetitions}, ABI {version}", flush=True)
            subprocess.run([str(probe), str(fixture)], check=True, timeout=60)
            if registry_probe:
                subprocess.run([str(registry_probe)], check=True, timeout=30)


if __name__ == "__main__":
    main()
