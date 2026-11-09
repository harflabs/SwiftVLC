#!/usr/bin/env python3
"""Build a counterfactual macOS-arm64 engine in about 20 seconds.

Patched copies of individual VLC source files are compiled with an existing
build-libvlc.sh build tree's recorded compile commands, swapped into copies of
its installed archives, and the static library is relinked and packaged as an
xcframework. The build tree itself is never modified, so a no-op patch makes
the control for every A/B comparison.

Usage: build_variant.py VLC_TREE HEADERS_XCFRAMEWORK OUT.xcframework PATCH [PATCH ...]

VLC_TREE is the patched VLC checkout that build-libvlc.sh built (it contains
build-macosx-arm64/). Each PATCH is a unified diff with a/ b/ prefixes relative
to it, applied on top of the tree's current sources. A tree configured for an
SDK that is no longer installed is compiled against the installed macOS SDK.
"""
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def sh(cmd, cwd=None):
    result = subprocess.run(cmd, cwd=cwd, shell=isinstance(cmd, str), capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stdout + result.stderr)
        raise SystemExit("failed: %s" % (cmd if isinstance(cmd, str) else " ".join(cmd)))
    return result.stdout


def units(inst):
    """Source path -> (build subdir, make target, installed archive, member)."""
    plugin = inst + "/lib/vlc/plugins/"
    table = {
        "modules/video_output/apple/VLCSampleBufferDisplay.m": (
            "modules", "video_output/apple/libsamplebufferdisplay_plugin_la-VLCSampleBufferDisplay.lo",
            plugin + "video_output/libsamplebufferdisplay_plugin.a",
            "libsamplebufferdisplay_plugin_la-VLCSampleBufferDisplay.o"),
        "modules/codec/videotoolbox/decoder.c": (
            "modules", "codec/videotoolbox/libvideotoolbox_plugin_la-decoder.lo",
            plugin + "codec/libvideotoolbox_plugin.a", "libvideotoolbox_plugin_la-decoder.o"),
        "modules/demux/adaptive/PlaylistManager.cpp": (
            "modules", "demux/adaptive/libvlc_adaptive_la-PlaylistManager.lo",
            plugin + "demux/libadaptive_plugin.a", "libvlc_adaptive_la-PlaylistManager.o"),
        "modules/demux/adaptive/plumbing/FakeESOut.cpp": (
            "modules", "demux/adaptive/plumbing/libvlc_adaptive_la-FakeESOut.lo",
            plugin + "demux/libadaptive_plugin.a", "libvlc_adaptive_la-FakeESOut.o"),
        "modules/demux/subtitle.c": (
            "modules", "demux/subtitle.lo", plugin + "demux/libsubtitle_plugin.a", "subtitle.o"),
        "modules/demux/mp4/mp4.c": (
            "modules", "demux/mp4/mp4.lo", plugin + "demux/libmp4_plugin.a", "mp4.o"),
    }
    # input.c and timer.c have duplicate archive members and are not listed.
    for name in ("audio_output/dec.c", "audio_output/output.c", "clock/clock.c",
                 "input/decoder.c", "input/es_out.c", "input/es_out_timeshift.c",
                 "input/resource.c", "player/player.c", "video_output/video_output.c",
                 "video_output/vout_subpictures.c"):
        base = os.path.splitext(os.path.basename(name))[0]
        table["src/" + name] = ("src", "%s/libvlccore_la-%s.lo" % (os.path.dirname(name), base),
                                inst + "/lib/libvlccore.a", "libvlccore_la-%s.o" % base)
    return table


def main():
    if len(sys.argv) < 5:
        raise SystemExit(__doc__)
    tree, headers_xcf, out_xcf = (os.path.abspath(p) for p in sys.argv[1:4])
    patches = [os.path.abspath(p) for p in sys.argv[4:]]
    build = tree + "/build-macosx-arm64/build"
    inst = glob.glob(tree + "/build-macosx-arm64/vlc-macosx*-arm64")[0]
    table = units(inst)
    configured_sdk = re.search(r"MacOSX[0-9.]*\.sdk", open(build + "/Makefile").read()).group(0)
    installed_sdk = os.path.basename(os.path.realpath(sh(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()))

    work = tempfile.mkdtemp(prefix="vlc-variant-")
    src_root = os.path.join(work, "src")
    touched = sorted({m.group(1) for p in patches for m in re.finditer(r"(?m)^\+\+\+ b/(\S+)", open(p).read())})
    for rel in touched:
        if rel not in table:
            raise SystemExit("no build recipe for %s" % rel)
        os.makedirs(os.path.dirname(os.path.join(src_root, rel)), exist_ok=True)
        shutil.copy2(os.path.join(tree, rel), os.path.join(src_root, rel))
    for patch in patches:
        sh(["patch", "-p1", "-s", "-d", src_root, "-i", patch])

    archives = {}
    for rel in touched:
        subdir, target, archive, member = table[rel]
        source = os.path.join(tree, rel)
        line = next(line for line in sh("make -n -W %s %s" % (source, target), cwd=os.path.join(build, subdir)).splitlines()
                    if "--mode=compile" in line or "doltcompile " in line)
        cmd = line.split("--mode=compile" if "--mode=compile" in line else "doltcompile ", 1)[1]
        cmd = cmd.replace(configured_sdk, installed_sdk)
        cmd = re.sub(r"-MT \S+ -MD -MP -MF \S+", "", cmd)
        cmd = re.sub(r"-c -o \S+ .*$", "", cmd)
        obj = os.path.join(work, member)
        sh(cmd + " -I%s -c -o %s %s" % (os.path.dirname(source), obj, os.path.join(src_root, rel)),
           cwd=os.path.join(build, subdir))
        if archive not in archives:
            archives[archive] = shutil.copy2(archive, os.path.join(work, os.path.basename(archive)))
        member_dir = os.path.join(work, "members", os.path.basename(archive))
        os.makedirs(member_dir, exist_ok=True)
        shutil.copy2(obj, os.path.join(member_dir, member))
        sh(["ar", "r", archives[archive], member], cwd=member_dir)
        print("rebuilt", rel)
    for copy in archives.values():
        sh(["ranlib", copy])

    libs = open(tree + "/build-macosx-arm64/static-lib/static-libs-list").read()
    for original, copy in archives.items():
        libs = libs.replace(original, copy)
    open(os.path.join(work, "static-libs-list"), "w").write(libs)
    package = os.path.join(work, "package")
    shutil.copytree(glob.glob(headers_xcf + "/macos-*/Headers")[0], package + "/Headers")
    sh(["xcrun", "libtool", "-static", "-no_warning_for_no_symbols",
        "-filelist", os.path.join(work, "static-libs-list"), "-o", package + "/libvlc.a"])
    sh([REPO + "/scripts/fix-duplicate-symbols.sh", package + "/libvlc.a"])
    shutil.rmtree(out_xcf, ignore_errors=True)
    sh(["xcodebuild", "-create-xcframework", "-library", package + "/libvlc.a",
        "-headers", package + "/Headers", "-output", out_xcf])
    shutil.rmtree(work)
    print("packaged", out_xcf)


main()
