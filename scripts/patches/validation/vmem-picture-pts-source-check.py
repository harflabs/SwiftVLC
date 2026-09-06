#!/usr/bin/env python3
"""Structural and mutation proof for SwiftVLC's v6 vmem picture-PTS ABI."""

from pathlib import Path
import sys

from pip_extension_version import (
    BASE_SOURCE_KEYS,
    OPTIONAL_SUCCESSOR_SOURCE_KEYS,
    read_source_root,
    resolve_extension_version,
    run_negative_mutations,
)


def extension_sources(sources: dict[str, str]) -> dict[str, str]:
    keys = BASE_SOURCE_KEYS | OPTIONAL_SUCCESSOR_SOURCE_KEYS
    return {key: sources[key] for key in keys}


def function_body(source: str, signature: str) -> str:
    start = -1
    while True:
        start = source.find(signature, start + 1)
        if start < 0:
            raise AssertionError(f"missing function: {signature}")
        opening = source.find("{", start)
        if opening < 0:
            raise AssertionError(f"missing body: {signature}")
        if source.find(";", start, opening) < 0:
            break
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening : index + 1]
    raise AssertionError(f"unterminated body: {signature}")


def normalized(source: str) -> str:
    return " ".join(source.split())


def require(source: str, *needles: str) -> None:
    for needle in needles:
        if needle not in source:
            raise AssertionError(f"missing invariant: {needle}")


def forbid(source: str, *needles: str) -> None:
    for needle in needles:
        if needle in source:
            raise AssertionError(f"forbidden invariant: {needle}")


def ordered(source: str, *needles: str) -> None:
    cursor = 0
    for needle in needles:
        position = source.find(needle, cursor)
        if position < 0:
            raise AssertionError(f"missing/out-of-order invariant: {needle}")
        cursor = position + len(needle)


def validate_public_abi(vmem_header: str, public_header: str,
                        exports: str) -> None:
    compact_vmem = normalized(vmem_header)
    compact_public = normalized(public_header)
    require(
        compact_vmem,
        "typedef int (*swiftvlc_video_display_status_cb)(void *opaque, "
        "void *picture);",
        "#define SWIFTVLC_VMEM_INVALID_PICTURE_PTS_US INT64_MIN",
        "typedef int (*swiftvlc_video_display_status_v2_cb)( void *opaque, "
        "void *picture, int64_t picture_pts_us);",
    )
    require(
        compact_public,
        "int swiftvlc_libvlc_video_set_callbacks_atomic( "
        "libvlc_media_player_t *mp, libvlc_video_lock_cb lock, "
        "libvlc_video_unlock_cb unlock, libvlc_video_display_cb display, "
        "swiftvlc_video_display_status_cb display_status, "
        "swiftvlc_video_format_ex_cb setup, "
        "libvlc_video_cleanup_cb cleanup, void *opaque );",
        "int swiftvlc_libvlc_video_set_callbacks_atomic_v2( "
        "libvlc_media_player_t *mp, libvlc_video_lock_cb lock, "
        "libvlc_video_unlock_cb unlock, libvlc_video_display_cb display, "
        "swiftvlc_video_display_status_v2_cb display_status_v2, "
        "swiftvlc_video_format_ex_cb setup, "
        "libvlc_video_cleanup_cb cleanup, void *opaque );",
        "Version 6",
        "The invalid sentinel does not reject the picture.",
    )
    require(exports, "swiftvlc_libvlc_video_set_callbacks_atomic_v2\n")


def validate_registry(configuration: str) -> None:
    clone = function_body(configuration, "swiftvlc_vmem_configuration_Clone(")
    ordered(
        clone,
        "configuration->display_status = source->display_status;",
        "configuration->display_status_v2 = source->display_status_v2;",
    )

    legacy_callbacks = function_body(
        configuration,
        "swiftvlc_vmem_configuration_registry_PublishCallbacks(")
    require(
        legacy_callbacks,
        "next->display_status = NULL;",
        "next->display_status_v2 = NULL;",
    )

    publish_v4 = function_body(
        configuration,
        "swiftvlc_vmem_configuration_registry_PublishComplete(")
    ordered(
        publish_v4,
        "swiftvlc_vmem_configuration_NewEmpty();",
        "next->lock = lock;",
        "next->unlock = unlock;",
        "next->display = display;",
        "next->display_status = display_status;",
        "next->display_status_v2 = NULL;",
        "next->setup_ex = setup_ex;",
        "next->cleanup = cleanup;",
        "next->opaque = opaque;",
        "registry->current = next;",
    )

    publish_v6 = function_body(
        configuration,
        "swiftvlc_vmem_configuration_registry_PublishCompleteV2(")
    ordered(
        publish_v6,
        "swiftvlc_vmem_configuration_NewEmpty();",
        "next->lock = lock;",
        "next->unlock = unlock;",
        "next->display = display;",
        "next->display_status = NULL;",
        "next->display_status_v2 = display_status_v2;",
        "next->setup_ex = setup_ex;",
        "next->cleanup = cleanup;",
        "next->opaque = opaque;",
        "registry->current = next;",
    )
    require(
        publish_v6,
        "force_allocation_failure",
        "return false;",
        "swiftvlc_vmem_configuration_Release(previous);",
    )

    publish_status_v4 = function_body(
        configuration,
        "swiftvlc_vmem_configuration_registry_PublishDisplayStatus(")
    ordered(
        publish_status_v4,
        "next->display_status = display_status;",
        "next->display_status_v2 = NULL;",
        "registry->current = next;",
    )


def validate_setters(media_player: str) -> None:
    require(media_player, 'var_Create (mp, "vmem-display-status-v2",')

    legacy = function_body(media_player, "void libvlc_video_set_callbacks(")
    ordered(
        legacy,
        "swiftvlc_vmem_configuration_registry_PublishCallbacks(",
        'var_SetAddress( mp, "vmem-display-status", NULL );',
        'var_SetAddress( mp, "vmem-display-status-v2", NULL );',
    )

    status_v4 = function_body(
        media_player,
        "void swiftvlc_libvlc_video_set_display_status_callback(")
    ordered(
        status_v4,
        "swiftvlc_vmem_configuration_registry_PublishDisplayStatus(",
        'var_SetAddress( mp, "vmem-display-status", display );',
        'var_SetAddress( mp, "vmem-display-status-v2", NULL );',
    )

    atomic_v4 = function_body(
        media_player, "int swiftvlc_libvlc_video_set_callbacks_atomic(")
    ordered(
        atomic_v4,
        "display_status_cb == NULL",
        "lock_cb != NULL && display_status_cb != NULL",
        "swiftvlc_vmem_configuration_registry_PublishComplete(",
        'var_SetAddress(mp, "vmem-display-status", display_status_cb);',
        'var_SetAddress(mp, "vmem-display-status-v2", NULL);',
    )
    forbid(atomic_v4, "PublishCompleteV2", "display_status_v2_cb")

    atomic_v6 = function_body(
        media_player, "int swiftvlc_libvlc_video_set_callbacks_atomic_v2(")
    ordered(
        atomic_v6,
        "display_status_v2_cb == NULL",
        "lock_cb != NULL && display_status_v2_cb != NULL",
        "swiftvlc_vmem_configuration_registry_PublishCompleteV2(",
        'var_SetAddress(mp, "vmem-display-status", NULL);',
        'var_SetAddress(mp, "vmem-display-status-v2", display_status_v2_cb);',
    )
    forbid(atomic_v6, "PublishComplete(", "display_status_cb")


def validate_vmem(vmem: str) -> None:
    open_body = function_body(vmem, "static int Open(")
    ordered(
        open_body,
        "swiftvlc_vmem_configuration_registry_Acquire(registry);",
        "sys->display_status = sys->configuration->display_status;",
        "sys->display_status_v2 = sys->configuration->display_status_v2;",
    )

    prepare = function_body(vmem, "static void Prepare(")
    ordered(
        prepare,
        "VLC_UNUSED(date);",
        "sys->picture_ready = false;",
        "sys->submission_status = -EIO;",
        "sys->picture_pts_us = pic->date >= VLC_TICK_0",
        "US_FROM_VLC_TICK(pic->date - VLC_TICK_0)",
        ": SWIFTVLC_VMEM_INVALID_PICTURE_PTS_US;",
        "sys->pic_opaque = sys->lock(sys->opaque, planes);",
        "picture_CopyPixels(locked, pic);",
        "sys->picture_ready = true;",
    )
    forbid(
        prepare,
        "US_FROM_VLC_TICK(date",
        "if (sys->picture_pts_us ==",
        "if (sys->picture_pts_us !=",
    )

    display = function_body(vmem, "static void Display(")
    ordered(
        display,
        "if (sys->picture_ready)",
        "if (sys->display_status_v2 != NULL)",
        "sys->display_status_v2(",
        "sys->opaque, sys->pic_opaque, sys->picture_pts_us);",
        "else if (sys->display_status != NULL)",
        "sys->display_status(sys->opaque, sys->pic_opaque);",
        "else if (sys->display != NULL)",
        "sys->picture_ready = false;",
        "sys->picture_pts_us = SWIFTVLC_VMEM_INVALID_PICTURE_PTS_US;",
    )


def validate_all(sources: dict[str, str]) -> int:
    resolution = resolve_extension_version(extension_sources(sources))
    if resolution.version < 6:
        raise AssertionError(
            "v6 picture-PTS contract requires extension version 6 or newer")
    validate_public_abi(
        sources["vmem_header"], sources["public_header"], sources["exports"])
    validate_registry(sources["configuration"])
    validate_setters(sources["media_player"])
    validate_vmem(sources["vmem"])
    return resolution.version


def require_mutation_rejected(sources: dict[str, str], key: str,
                              old: str, new: str, description: str) -> None:
    if old not in sources[key]:
        raise AssertionError(f"cannot construct mutation: {description}")
    candidate = dict(sources)
    candidate[key] = candidate[key].replace(old, new, 1)
    try:
        validate_all(candidate)
    except AssertionError:
        return
    raise AssertionError(f"mutation escaped source gate: {description}")


def validate_race_probe(probe: str) -> None:
    publisher = function_body(probe, "static void *publisher(")
    opener = function_body(probe, "static void *opener(")
    ordered(publisher,
            "publish_generation(stress, true)",
            "rendezvous(stress, a_published);",
            "rendezvous(stress, a_acquired);",
            "publish_generation(stress, false)",
            "rendezvous(stress, b_published);",
            "rendezvous(stress, b_acquired);",
            "swiftvlc_vmem_configuration_registry_PublishCompleteV2(",
            "rendezvous(stress, disabled_published);",
            "rendezvous(stress, snapshots_exercised);",
            "iteration < publish_iterations")
    ordered(opener,
            "rendezvous(stress, a_published);",
            "*a =",
            "rendezvous(stress, a_acquired);",
            "rendezvous(stress, b_published);",
            "*b =",
            "rendezvous(stress, b_acquired);",
            "rendezvous(stress, disabled_published);",
            "a->opaque != &generation_a",
            "b->opaque != &generation_b",
            "exercise_snapshot(a);",
            "exercise_snapshot(b);",
            "exercise_snapshot(disabled);",
            "swiftvlc_vmem_configuration_Release(a);",
            "swiftvlc_vmem_configuration_Release(b);",
            "rendezvous(stress, snapshots_exercised);",
            "iteration < acquire_iterations")
    require(probe, "publish_iterations = 50000, acquire_iterations = 100000",
            "a_setups != 0 && b_setups != 0",
            "a_setups == atomic_load_explicit(&generation_a.cleanups,",
            "b_setups == atomic_load_explicit(&generation_b.cleanups,")


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <patched-vlc-source>", file=sys.stderr)
        return 2
    root = Path(sys.argv[1]).resolve()
    paths = {
        "vmem_header": root / "include/vlc/swiftvlc_vmem.h",
        "public_header": root / "include/vlc/libvlc_media_player.h",
        "events_header": root / "include/vlc/libvlc_events.h",
        "configuration": root / "include/vlc_vmem_configuration.h",
        "media_player": root / "lib/media_player.c",
        "exports": root / "lib/libvlc.sym",
        "vmem": root / "modules/video_output/vmem.c",
    }
    for path in paths.values():
        if not path.is_file():
            raise AssertionError(f"missing v6 source input: {path}")
    sources = {name: path.read_text() for name, path in paths.items()}
    sources.update(read_source_root(root))
    integrated_extension_version = validate_all(sources)
    probe = Path(__file__).with_name("vmem-configuration-race.c").read_text()
    validate_race_probe(probe)
    for original in ("rendezvous(stress, a_acquired);",
                     "rendezvous(stress, b_acquired);",
                     "exercise_snapshot(a);", "exercise_snapshot(b);"):
        if original not in probe:
            raise AssertionError(f"cannot construct race mutation: {original}")
        try:
            validate_race_probe(probe.replace(original, "/* removed */", 1))
        except AssertionError:
            continue
        raise AssertionError(f"race lifetime mutation escaped: {original}")

    require_mutation_rejected(
        sources, "vmem",
        "sys->picture_pts_us = pic->date >= VLC_TICK_0",
        "sys->picture_pts_us = date >= VLC_TICK_0",
        "scheduled deadline substituted for vmem output-attempt picture PTS")
    require_mutation_rejected(
        sources, "vmem",
        "US_FROM_VLC_TICK(pic->date - VLC_TICK_0)",
        "US_FROM_VLC_TICK(pic->date)",
        "VLC private tick origin leaked through the public API")
    require_mutation_rejected(
        sources, "vmem",
        ": SWIFTVLC_VMEM_INVALID_PICTURE_PTS_US;",
        ": INT64_C(0);",
        "missing timestamp silently converted to zero")
    require_mutation_rejected(
        sources, "configuration",
        "configuration->display_status_v2 = source->display_status_v2;",
        "configuration->display_status_v2 = NULL;",
        "v6 callback dropped while cloning a retained generation")
    run_negative_mutations(
        extension_sources(sources), integrated_extension_version)

    print("PASS v6 vmem picture-PTS source and mutation contract "
          f"(integrated extension version {integrated_extension_version})")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as error:
        print(f"FAIL v6 vmem picture-PTS source contract: {error}",
              file=sys.stderr)
        raise SystemExit(1)
