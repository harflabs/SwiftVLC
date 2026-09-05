from __future__ import annotations

import json
import os
import plistlib
import subprocess
import sys
from pathlib import Path
import tempfile
import textwrap
from typing import Optional
import unittest


VALIDATION_DIRECTORY = (
    Path(__file__).resolve().parents[1] / "patches" / "validation"
)
sys.path.insert(0, str(VALIDATION_DIRECTORY))
import pip_extension_version as version  # noqa: E402


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
ARCHIVE_VALIDATOR = REPOSITORY_ROOT / "scripts/validate-native-extension-contract.sh"

VERSIONED_ARCHIVE_SYMBOLS = {
    1: (
        "swiftvlc_libvlc_pip_extensions_version",
        "swiftvlc_libvlc_media_player_get_media_length_snapshot",
        "swiftvlc_libvlc_video_set_format_callbacks_ex",
    ),
    2: ("swiftvlc_libvlc_media_player_get_playback_snapshot",),
    4: (
        "swiftvlc_libvlc_media_player_request_next_frame",
        "swiftvlc_libvlc_media_player_cancel_next_frame_request",
        "swiftvlc_libvlc_video_set_display_status_callback",
        "swiftvlc_libvlc_video_set_callbacks_atomic",
    ),
    5: (
        "swiftvlc_libvlc_media_player_get_sample_buffer_renderer_snapshot",
    ),
    6: ("swiftvlc_libvlc_video_set_callbacks_atomic_v2",),
    8: (
        "swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot",
        "swiftvlc_libvlc_media_player_set_pause_without_reset_authorization",
    ),
    9: ("swiftvlc_libvlc_media_player_set_pip_playback_identity",),
    10: ("swiftvlc_libvlc_media_player_set_subtitle_text_snapshot_callback",),
}
LEASE_ARCHIVE_SYMBOLS = (
    "swiftvlc_libvlc_media_player_acquire_apple_audio_session_lease",
    "swiftvlc_libvlc_media_player_release_apple_audio_session_lease",
)


def synthetic_sources(
        highest_version: int, *, leases: bool = False,
        omitted_versions: tuple[int, ...] = ()) -> dict[str, str]:
    sources = {
        "public_header": (
            "unsigned swiftvlc_libvlc_pip_extensions_version(void);\n"
        ),
        "events_header": "typedef struct libvlc_event_t libvlc_event_t;\n",
        "media_player": (
            "unsigned swiftvlc_libvlc_pip_extensions_version(void)\n"
            f"{{ return {highest_version}; }}\n"
        ),
        "exports": "swiftvlc_libvlc_pip_extensions_version\n",
        "drawable_header": "",
        "media_player_internal": "",
        "pip_controller": "",
        "pip_controller_header": "",
        "sample_buffer_display": "",
    }
    fragments = {
        4: {
            "public_header": (
                "typedef enum swiftvlc_next_frame_request_result_t {\n"
                "    swiftvlc_next_frame_request_accepted = 0,\n"
                "} swiftvlc_next_frame_request_result_t;\n"
                "swiftvlc_next_frame_request_result_t\n"
                "swiftvlc_libvlc_media_player_request_next_frame(void);\n"
                "bool swiftvlc_libvlc_media_player_cancel_next_frame_request(void);\n"
                "void swiftvlc_libvlc_video_set_display_status_callback(void);\n"
                "int swiftvlc_libvlc_video_set_callbacks_atomic(void);\n"
            ),
            "media_player": (
                "int swiftvlc_libvlc_media_player_request_next_frame(void) "
                "{ return 0; }\n"
                "bool swiftvlc_libvlc_media_player_cancel_next_frame_request(void) "
                "{ return false; }\n"
                "void swiftvlc_libvlc_video_set_display_status_callback(void) "
                "{}\n"
                "int swiftvlc_libvlc_video_set_callbacks_atomic(void) "
                "{ return 0; }\n"
            ),
            "exports": (
                "swiftvlc_libvlc_media_player_request_next_frame\n"
                "swiftvlc_libvlc_media_player_cancel_next_frame_request\n"
                "swiftvlc_libvlc_video_set_display_status_callback\n"
                "swiftvlc_libvlc_video_set_callbacks_atomic\n"
            ),
        },
        5: {
            "public_header": (
                "bool swiftvlc_libvlc_media_player_get_sample_buffer_renderer_snapshot(void);\n"
            ),
            "media_player": (
                "bool swiftvlc_libvlc_media_player_get_sample_buffer_renderer_snapshot(void) "
                "{ return false; }\n"
            ),
            "exports": (
                "swiftvlc_libvlc_media_player_get_sample_buffer_renderer_snapshot\n"
            ),
        },
        6: {
            "public_header": (
                "int swiftvlc_libvlc_video_set_callbacks_atomic_v2(void);\n"
            ),
            "media_player": (
                "int swiftvlc_libvlc_video_set_callbacks_atomic_v2(void) "
                "{ return 0; }\n"
            ),
            "exports": "swiftvlc_libvlc_video_set_callbacks_atomic_v2\n",
        },
        7: {
            "events_header": (
                "enum { libvlc_MediaPlayerRateChanged, };\n"
                "struct { float new_rate; } media_player_rate_changed;\n"
            ),
            "media_player": (
                "void publish_rate(void) { event.type = "
                "libvlc_MediaPlayerRateChanged, "
                "event.u.media_player_rate_changed.new_rate = 1; }\n"
            ),
        },
        8: {
            "public_header": (
                "#define SWIFTVLC_APPLE_AUDIO_RECOVERY_SNAPSHOT_VERSION 1\n"
                "typedef struct swiftvlc_apple_audio_recovery_snapshot_t {\n"
                "    unsigned version;\n"
                "} swiftvlc_apple_audio_recovery_snapshot_t;\n"
                "bool swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot(void);\n"
                "void swiftvlc_libvlc_media_player_set_pause_without_reset_authorization(void);\n"
            ),
            "media_player": (
                "bool swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot(void) "
                "{ return false; }\n"
                "void swiftvlc_libvlc_media_player_set_pause_without_reset_authorization(void) "
                "{}\n"
            ),
            "exports": (
                "swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot\n"
                "swiftvlc_libvlc_media_player_set_pause_without_reset_authorization\n"
            ),
        },
        9: {
            "public_header": (
                "typedef struct swiftvlc_pip_playback_identity_t {\n"
                "    uint64_t native_handle_identity;\n"
                "    uint64_t playback_generation;\n"
                "} swiftvlc_pip_playback_identity_t;\n"
                "LIBVLC_API bool\n"
                "swiftvlc_libvlc_media_player_set_pip_playback_identity(\n"
                "    libvlc_media_player_t *p_mi,\n"
                "    uint64_t native_handle_identity,\n"
                "    uint64_t playback_generation);\n"
            ),
            "media_player": (
                "struct swiftvlc_pip_playback_identity_node {\n"
                "    swiftvlc_pip_playback_identity_t identity;\n"
                "    struct swiftvlc_pip_playback_identity_node *next;\n"
                "};\n"
                "libvlc_media_player_t *libvlc_media_player_new("
                "libvlc_instance_t *instance) {\n"
                "    libvlc_media_player_t *mp = vlc_object_create("
                "instance, sizeof(*mp));\n"
                "    mp->pip_playback_identities = NULL;\n"
                "    mp->pip_native_handle_identity = 0;\n"
                "    var_Create(mp, \"swiftvlc-pip-playback-identity\", VLC_VAR_ADDRESS);\n"
                "    return mp;\n"
                "}\n"
                "static void libvlc_media_player_destroy(libvlc_media_player_t *p_mi) {\n"
                "    vlc_player_Delete(p_mi->player);\n"
                "    struct swiftvlc_pip_playback_identity_node *identity =\n"
                "        p_mi->pip_playback_identities;\n"
                "    while (identity != NULL) {\n"
                "        struct swiftvlc_pip_playback_identity_node *next = identity->next;\n"
                "        free(identity);\n"
                "        identity = next;\n"
                "    }\n"
                "    vlc_object_delete(p_mi);\n"
                "}\n"
                "bool swiftvlc_libvlc_media_player_set_pip_playback_identity(\n"
                "    libvlc_media_player_t *p_mi,\n"
                "    uint64_t native_handle_identity,\n"
                "    uint64_t playback_generation) "
                "{\n"
                "    if (p_mi == NULL || native_handle_identity == 0 || "
                "playback_generation == 0) return false;\n"
                "    vlc_player_Lock(p_mi->player);\n"
                "    if (p_mi->pip_native_handle_identity != 0 && "
                "p_mi->pip_native_handle_identity != native_handle_identity) {\n"
                "        vlc_player_Unlock(p_mi->player); return false;\n"
                "    }\n"
                "    struct swiftvlc_pip_playback_identity_node *current = "
                "p_mi->pip_playback_identities;\n"
                "    if (current != NULL && "
                "current->identity.native_handle_identity == native_handle_identity && "
                "current->identity.playback_generation == playback_generation) {\n"
                "        vlc_player_Unlock(p_mi->player); return true;\n"
                "    }\n"
                "    if (current != NULL && playback_generation < "
                "current->identity.playback_generation) {\n"
                "        vlc_player_Unlock(p_mi->player); return false;\n"
                "    }\n"
                "    struct swiftvlc_pip_playback_identity_node *node = "
                "malloc(sizeof(*node));\n"
                "    if (node == NULL) {\n"
                "        vlc_player_Unlock(p_mi->player); return false;\n"
                "    }\n"
                "    node->identity = (swiftvlc_pip_playback_identity_t) {\n"
                "        .native_handle_identity = native_handle_identity,\n"
                "        .playback_generation = playback_generation,\n"
                "    };\n"
                "    p_mi->pip_native_handle_identity = native_handle_identity;\n"
                "    node->next = current;\n"
                "    p_mi->pip_playback_identities = node;\n"
                "    var_SetAddress(p_mi, \"swiftvlc-pip-playback-identity\", "
                "&node->identity);\n"
                "    vlc_player_Unlock(p_mi->player);\n"
                "    return true;\n"
                "}\n"
            ),
            "exports": (
                "swiftvlc_libvlc_media_player_set_pip_playback_identity\n"
            ),
            "drawable_header": (
                "- (id<VLCPictureInPictureWindowControlling>)\n"
                "    takePreservedPictureInPictureWindowControllerForNativeHandle:\n"
                "        (uint64_t)nativeHandle\n"
                "    playbackGeneration:(uint64_t)playbackGeneration\n"
                "    outputIdentity:(uint64_t)outputIdentity\n"
                "    wasSuperseded:(BOOL *)wasSuperseded;\n"
                "- (BOOL)preservePictureInPictureWindowController:\n"
                "    (id<VLCPictureInPictureWindowControlling>)controller\n"
                "    fromNativeHandle:(uint64_t)nativeHandle\n"
                "    playbackGeneration:(uint64_t)playbackGeneration\n"
                "    outputIdentity:(uint64_t)outputIdentity\n"
                "    sameMediaGenerationRebuild:(BOOL)sameMediaGenerationRebuild;\n"
                "- (BOOL)pictureInPictureWindowController:\n"
                "    (id<VLCPictureInPictureWindowControlling>)controller\n"
                "    didBecomeReadyForNativeHandle:(uint64_t)nativeHandle\n"
                "    playbackGeneration:(uint64_t)playbackGeneration\n"
                "    outputIdentity:(uint64_t)outputIdentity;\n"
                "- (BOOL)pictureInPictureWindowController:\n"
                "    (id<VLCPictureInPictureWindowControlling>)controller\n"
                "    didClaimNativeHandle:(uint64_t)nativeHandle\n"
                "    playbackGeneration:(uint64_t)playbackGeneration\n"
                "    outputIdentity:(uint64_t)outputIdentity;\n"
                "- (void)pictureInPictureControllerCreationFailedForNativeHandle:\n"
                "    (uint64_t)nativeHandle\n"
                "    playbackGeneration:(uint64_t)playbackGeneration\n"
                "    outputIdentity:(uint64_t)outputIdentity;\n"
                "- (void)pictureInPictureWindowController:\n"
                "    (id<VLCPictureInPictureWindowControlling>)controller\n"
                "    cancelHandoffForNativeHandle:(uint64_t)nativeHandle\n"
                "    playbackGeneration:(uint64_t)playbackGeneration\n"
                "    outputIdentity:(uint64_t)outputIdentity;\n"
                "- (void)pictureInPictureWindowController:\n"
                "    (id<VLCPictureInPictureWindowControlling>)controller\n"
                "    handoffDidTimeOutForNativeHandle:(uint64_t)nativeHandle\n"
                "    playbackGeneration:(uint64_t)playbackGeneration\n"
                "    outputIdentity:(uint64_t)outputIdentity;\n"
            ),
            "media_player_internal": (
                "struct libvlc_media_player_t {\n"
                "    struct swiftvlc_pip_playback_identity_node "
                "*pip_playback_identities;\n"
                "    uint64_t pip_native_handle_identity;\n"
                "};\n"
            ),
            "pip_controller": """
static int OpenController(pip_controller_t *pipcontroller)
{
    id<VLCPictureInPictureDrawable> drawable =
        (__bridge id)pipcontroller->drawable;
    BOOL hasExactIdentity =
        pipcontroller->native_handle_identity != 0 &&
        pipcontroller->playback_generation != 0 &&
        pipcontroller->output_identity != 0 &&
        pipcontroller->output_identity != VLC_PIP_HANDOFF_TOKEN_CLAIMED;
    BOOL missingExactLifecycle =
        ![drawable respondsToSelector:@selector(
            takePreservedPictureInPictureWindowControllerForNativeHandle:
            playbackGeneration:outputIdentity:wasSuperseded:)] ||
        ![drawable respondsToSelector:@selector(
            pictureInPictureWindowController:didClaimNativeHandle:
            playbackGeneration:outputIdentity:)] ||
        ![drawable respondsToSelector:@selector(
            pictureInPictureControllerCreationFailedForNativeHandle:
            playbackGeneration:outputIdentity:)] ||
        ![drawable respondsToSelector:@selector(
            pictureInPictureWindowController:cancelHandoffForNativeHandle:
            playbackGeneration:outputIdentity:)] ||
        ![drawable respondsToSelector:@selector(
            pictureInPictureWindowController:didBecomeReadyForNativeHandle:
            playbackGeneration:outputIdentity:)] ||
        ![drawable respondsToSelector:@selector(
            preservePictureInPictureWindowController:fromNativeHandle:
            playbackGeneration:outputIdentity:sameMediaGenerationRebuild:)] ||
        ![drawable respondsToSelector:@selector(
            pictureInPictureWindowController:handoffDidTimeOutForNativeHandle:
            playbackGeneration:outputIdentity:)];
    if (!hasExactIdentity || missingExactLifecycle)
        return VLC_EGENERIC;
    BOOL handoffWasSuperseded = NO;
    id preserved = [drawable
        takePreservedPictureInPictureWindowControllerForNativeHandle:
            pipcontroller->native_handle_identity
        playbackGeneration:pipcontroller->playback_generation
        outputIdentity:pipcontroller->output_identity
        wasSuperseded:&handoffWasSuperseded];
    VLCPictureInPictureController *sys = nil;
    if (preserved != nil) {
        sys = preserved;
        BOOL didClaim = [drawable pictureInPictureWindowController:sys
            didClaimNativeHandle:pipcontroller->native_handle_identity
            playbackGeneration:pipcontroller->playback_generation
            outputIdentity:pipcontroller->output_identity];
        if (!didClaim) {
            [drawable pictureInPictureWindowController:sys
                cancelHandoffForNativeHandle:pipcontroller->native_handle_identity
                playbackGeneration:pipcontroller->playback_generation
                outputIdentity:pipcontroller->output_identity];
            [sys close];
            return VLC_EGENERIC;
        }
        if (![sys rebindToPipController:pipcontroller]) {
            [drawable pictureInPictureWindowController:sys
                cancelHandoffForNativeHandle:pipcontroller->native_handle_identity
                playbackGeneration:pipcontroller->playback_generation
                outputIdentity:pipcontroller->output_identity];
            [sys close];
            return VLC_EGENERIC;
        }
    } else {
        sys = [[VLCPictureInPictureController alloc]
            initWithPipController:pipcontroller];
        if (sys == nil) {
            [drawable pictureInPictureControllerCreationFailedForNativeHandle:
                pipcontroller->native_handle_identity
                playbackGeneration:pipcontroller->playback_generation
                outputIdentity:pipcontroller->output_identity];
            return VLC_EGENERIC;
        }
        BOOL didClaim = [drawable pictureInPictureWindowController:sys
            didClaimNativeHandle:pipcontroller->native_handle_identity
            playbackGeneration:pipcontroller->playback_generation
            outputIdentity:pipcontroller->output_identity];
        if (!didClaim) {
            [drawable pictureInPictureControllerCreationFailedForNativeHandle:
                pipcontroller->native_handle_identity
                playbackGeneration:pipcontroller->playback_generation
                outputIdentity:pipcontroller->output_identity];
            [sys closeForNativeHandle:pipcontroller->native_handle_identity
                playbackGeneration:pipcontroller->playback_generation
                outputIdentity:pipcontroller->output_identity];
            return VLC_EGENERIC;
        }
    }
    if (![sys startPreparationTimeoutForNativeHandle:
            pipcontroller->native_handle_identity
            playbackGeneration:pipcontroller->playback_generation
            outputIdentity:pipcontroller->output_identity]) {
        [drawable pictureInPictureWindowController:sys
            cancelHandoffForNativeHandle:pipcontroller->native_handle_identity
            playbackGeneration:pipcontroller->playback_generation
            outputIdentity:pipcontroller->output_identity];
        [sys closeForNativeHandle:pipcontroller->native_handle_identity
            playbackGeneration:pipcontroller->playback_generation
            outputIdentity:pipcontroller->output_identity];
        return VLC_EGENERIC;
    }
    pipcontroller->p_sys = (__bridge_retained void *)sys;
    return VLC_SUCCESS;
}
""",
            "pip_controller_header": (
                "typedef struct swiftvlc_pip_inherited_identity_t {\n"
                "    uint64_t native_handle_identity;\n"
                "    uint64_t playback_generation;\n"
                "} swiftvlc_pip_inherited_identity_t;\n"
                "struct pip_controller_t {\n"
                "    void *drawable;\n"
                "    uint64_t native_handle_identity;\n"
                "    uint64_t playback_generation;\n"
                "    uint64_t output_identity;\n"
                "};\n"
            ),
            "sample_buffer_display": (
                "static atomic_uint_fast64_t pipOutputIdentitySource = "
                "ATOMIC_VAR_INIT(0);\n"
                "static uint64_t NextPipOutputIdentity(void) {\n"
                "    uint_fast64_t current = atomic_load_explicit(\n"
                "        &pipOutputIdentitySource, memory_order_relaxed);\n"
                "    for (;;) {\n"
                "        if (current >= UINT64_MAX - 1) {\n"
                "            if (current == UINT64_MAX - 1)\n"
                "                atomic_compare_exchange_strong_explicit(\n"
                "                    &pipOutputIdentitySource, &current, UINT64_MAX,\n"
                "                    memory_order_relaxed, memory_order_relaxed);\n"
                "            return 0;\n"
                "        }\n"
                "        uint_fast64_t next = current + 1;\n"
                "        if (atomic_compare_exchange_weak_explicit(\n"
                "                &pipOutputIdentitySource, &current, next,\n"
                "                memory_order_relaxed, memory_order_relaxed))\n"
                "            return next;\n"
                "    }\n"
                "}\n"
                "static pip_controller_t *CreatePipController(\n"
                "    vout_display_t *vd, void *cbs_opaque) {\n"
                "    pip_controller_t *pip_controller = vlc_object_create(vd, "
                "sizeof(*pip_controller));\n"
                "    id drawable = (__bridge id)var_InheritAddress(vd, "
                "\"drawable-nsobject\");\n"
                "    pip_controller->drawable = (__bridge_retained void *)drawable;\n"
                "    const void *identity = var_InheritAddress(vd, "
                "\"swiftvlc-pip-playback-identity\");\n"
                "    if (identity != NULL) {\n"
                "        swiftvlc_pip_inherited_identity_t snapshot;\n"
                "        memcpy(&snapshot, identity, sizeof(snapshot));\n"
                "        pip_controller->native_handle_identity = "
                "snapshot.native_handle_identity;\n"
                "        pip_controller->playback_generation = "
                "snapshot.playback_generation;\n"
                "    } else {\n"
                "        pip_controller->native_handle_identity = 0;\n"
                "        pip_controller->playback_generation = 0;\n"
                "    }\n"
                "    pip_controller->output_identity = NextPipOutputIdentity();\n"
                "    if (pip_controller->output_identity == 0) {\n"
                "        CFBridgingRelease(pip_controller->drawable);\n"
                "        vlc_object_delete(pip_controller);\n"
                "        return NULL;\n"
                "    }\n"
                "    int (*open)(pip_controller_t *) = "
                "vlc_module_map(vd->obj.logger, module);\n"
                "    if (open) return pip_controller;\n"
                "    CFBridgingRelease(pip_controller->drawable);\n"
                "    vlc_object_delete(pip_controller);\n"
                "    return NULL;\n"
                "}\n"
            ),
        },
        10: {
            "public_header": (
                "bool swiftvlc_libvlc_media_player_"
                "set_subtitle_text_snapshot_callback(void);\n"
            ),
            "media_player": (
                "bool swiftvlc_libvlc_media_player_"
                "set_subtitle_text_snapshot_callback(void) "
                "{ return true; }\n"
            ),
            "exports": (
                "swiftvlc_libvlc_media_player_"
                "set_subtitle_text_snapshot_callback\n"
            ),
        },
    }
    for current_version in range(4, highest_version + 1):
        if current_version in omitted_versions:
            continue
        for source_key, fragment in fragments[current_version].items():
            sources[source_key] += fragment
    if leases:
        sources["public_header"] += (
            "typedef uint64_t swiftvlc_apple_audio_session_lease_t;\n"
            "typedef enum swiftvlc_apple_audio_session_lease_result_t {\n"
            "    swiftvlc_apple_audio_session_lease_failed = -1,\n"
            "} swiftvlc_apple_audio_session_lease_result_t;\n"
            "int swiftvlc_libvlc_media_player_acquire_apple_audio_session_lease(void);\n"
            "bool swiftvlc_libvlc_media_player_release_apple_audio_session_lease(void);\n"
        )
        sources["media_player"] += (
            "int swiftvlc_libvlc_media_player_acquire_apple_audio_session_lease(void) "
            "{ return 1; }\n"
            "bool swiftvlc_libvlc_media_player_release_apple_audio_session_lease(void) "
            "{ return true; }\n"
        )
        sources["exports"] += (
            "swiftvlc_libvlc_media_player_acquire_apple_audio_session_lease\n"
            "swiftvlc_libvlc_media_player_release_apple_audio_session_lease\n"
        )
    return sources


class PiPExtensionVersionTests(unittest.TestCase):
    def assert_rejected(self, sources: dict[str, str], **kwargs) -> None:
        with self.assertRaises(version.ExtensionVersionError):
            version.resolve_extension_version(sources, **kwargs)

    def test_every_supported_version_resolves_exactly(self) -> None:
        for expected in range(4, 11):
            with self.subTest(expected=expected):
                sources = synthetic_sources(expected, leases=expected >= 9)
                self.assertEqual(
                    version.resolve_extension_version(
                        sources, expected_version=expected
                    ).version,
                    expected,
                )

    def test_v8_lease_extension_is_full_or_absent_without_bumping(self) -> None:
        without = version.resolve_extension_version(synthetic_sources(8))
        self.assertEqual(without.version, 8)
        self.assertEqual(without.same_version_groups, ())

        sources = synthetic_sources(8, leases=True)
        with_leases = version.resolve_extension_version(
            sources,
            expected_version=8,
            required_same_version_groups=("apple-audio-session-leases",),
        )
        self.assertEqual(with_leases.version, 8)
        self.assertEqual(
            with_leases.same_version_groups,
            ("apple-audio-session-leases",),
        )

        sources["exports"] = sources["exports"].replace(
            "swiftvlc_libvlc_media_player_release_apple_audio_session_lease\n",
            "",
        )
        self.assert_rejected(sources)

    def test_v9_inherits_the_required_v8_lease_refinement(self) -> None:
        self.assert_rejected(synthetic_sources(9), expected_version=9)
        sources = synthetic_sources(9, leases=True)
        resolution = version.resolve_extension_version(
            sources,
            expected_version=9,
        )
        self.assertEqual(resolution.version, 9)
        self.assertEqual(
            resolution.same_version_groups,
            ("apple-audio-session-leases",),
        )

    def test_checked_in_v9_v10_weak_compatibility_fails_closed(self) -> None:
        shim = (REPOSITORY_ROOT / "Sources/CLibVLC/shim.c").read_text(
            encoding="utf-8"
        )
        version.validate_weak_compatibility_shim(shim)
        mutations = {
            "strong-fallback": shim.replace(
                "__attribute__((weak))\n"
                "bool swiftvlc_libvlc_media_player_set_pip_playback_identity",
                "bool swiftvlc_libvlc_media_player_set_pip_playback_identity",
                1,
            ),
            "successful-fallback": shim.replace(
                "    (void)playback_generation;\n    return false;\n}\n\n"
                "__attribute__((weak))\n"
                "void swiftvlc_libvlc_media_player_set_pause_without_reset_"
                "authorization",
                "    (void)playback_generation;\n    return true;\n}\n\n"
                "__attribute__((weak))\n"
                "void swiftvlc_libvlc_media_player_set_pause_without_reset_"
                "authorization",
                1,
            ),
            "version-eight-wrapper": shim.replace(
                "swiftvlc_libvlc_pip_extensions_version() < 9",
                "swiftvlc_libvlc_pip_extensions_version() < 8",
                1,
            ),
            "version-eight-availability": shim.replace(
                "swiftvlc_libvlc_pip_extensions_version() >= 9",
                "swiftvlc_libvlc_pip_extensions_version() >= 8",
                1,
            ),
            "native-call-before-gate": shim.replace(
                "    if (swiftvlc_libvlc_pip_extensions_version() < 9) {",
                "    swiftvlc_libvlc_media_player_set_pip_playback_identity("
                "player, native_handle_identity, playback_generation);\n"
                "    if (swiftvlc_libvlc_pip_extensions_version() < 9) {",
                1,
            ),
            "early-true-availability": shim.replace(
                "    return swiftvlc_libvlc_pip_extensions_version() >= 9;",
                "    return true;\n"
                "    return swiftvlc_libvlc_pip_extensions_version() >= 9;",
                1,
            ),
            "strong-v10-fallback": shim.replace(
                "__attribute__((weak))\n"
                "bool swiftvlc_libvlc_media_player_"
                "set_subtitle_text_snapshot_callback",
                "bool swiftvlc_libvlc_media_player_"
                "set_subtitle_text_snapshot_callback",
                1,
            ),
            "successful-v10-fallback": shim.replace(
                "    (void)opaque;\n"
                "    return false;\n"
                "}\n\n"
                "__attribute__((weak))\n"
                "bool swiftvlc_libvlc_media_player_"
                "get_sample_buffer_renderer_snapshot",
                "    (void)opaque;\n"
                "    return true;\n"
                "}\n\n"
                "__attribute__((weak))\n"
                "bool swiftvlc_libvlc_media_player_"
                "get_sample_buffer_renderer_snapshot",
                1,
            ),
            "version-nine-subtitle-wrapper": shim.replace(
                "swiftvlc_libvlc_pip_extensions_version() < 10",
                "swiftvlc_libvlc_pip_extensions_version() < 9",
                1,
            ),
            "version-nine-subtitle-availability": shim.replace(
                "swiftvlc_libvlc_pip_extensions_version() >= 10",
                "swiftvlc_libvlc_pip_extensions_version() >= 9",
                1,
            ),
            "subtitle-native-call-before-gate": shim.replace(
                "    if (swiftvlc_libvlc_pip_extensions_version() < 10) {",
                "    swiftvlc_libvlc_media_player_"
                "set_subtitle_text_snapshot_callback("
                "player, callback, opaque);\n"
                "    if (swiftvlc_libvlc_pip_extensions_version() < 10) {",
                1,
            ),
            "early-true-subtitle-availability": shim.replace(
                "    return swiftvlc_libvlc_pip_extensions_version() >= 10;",
                "    return true;\n"
                "    return swiftvlc_libvlc_pip_extensions_version() >= 10;",
                1,
            ),
        }
        for name, candidate in mutations.items():
            with self.subTest(mutation=name):
                self.assertNotEqual(candidate, shim)
                with self.assertRaises(version.ExtensionVersionError):
                    version.validate_weak_compatibility_shim(candidate)

    def test_manifest_intent_rejects_complete_version_or_lease_removal(self) -> None:
        self.assert_rejected(
            synthetic_sources(8, leases=True), expected_version=9
        )
        self.assert_rejected(
            synthetic_sources(8),
            expected_version=8,
            required_same_version_groups=("apple-audio-session-leases",),
        )

    def test_partial_duplicate_and_gapped_stages_fail_closed(self) -> None:
        partial = synthetic_sources(8)
        partial["exports"] = partial["exports"].replace(
            "swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot\n",
            "",
        )
        self.assert_rejected(partial)

        duplicate = synthetic_sources(8)
        duplicate["exports"] += (
            "swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot\n"
        )
        self.assert_rejected(duplicate)

        self.assert_rejected(synthetic_sources(8, omitted_versions=(5,)))

    def test_prototype_and_call_cannot_impersonate_any_implementation(self) -> None:
        cases = [
            (
                group,
                synthetic_sources(group.version, leases=group.version >= 9),
                (),
            )
            for group in version.VERSION_GROUPS
        ]
        cases.extend(
            (
                group,
                synthetic_sources(group.version, leases=True),
                (group.name,),
            )
            for group in version.SAME_VERSION_GROUPS
        )
        for group, baseline, required_groups in cases:
            implementations = [
                current for current in group.markers
                if current.source_key == "media_player"
                and "implementation" in current.label
            ]
            for current in implementations:
                for replacement_kind in ("prototype", "call"):
                    with self.subTest(
                        group=group.name,
                        marker=current.label,
                        decoy=replacement_kind,
                    ):
                        candidate = dict(baseline)
                        candidate["media_player"] = (
                            version._replace_implementation_definition(
                                candidate["media_player"],
                                current,
                                replacement_kind,
                            )
                        )
                        self.assert_rejected(
                            candidate,
                            expected_version=group.version,
                            required_same_version_groups=required_groups,
                        )

    def test_comments_and_strings_cannot_create_a_new_stage(self) -> None:
        comments = synthetic_sources(7)
        v8 = synthetic_sources(8)
        v7 = synthetic_sources(7)
        for source_key in ("public_header", "media_player"):
            added = v8[source_key].replace(v7[source_key], "", 1)
            comments[source_key] += "\n/*\n" + added + "\n*/\n"
        comments["exports"] += (
            "# swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot\n"
            "# swiftvlc_libvlc_media_player_set_pause_without_reset_authorization\n"
        )
        self.assertEqual(
            version.resolve_extension_version(comments).version, 7
        )

        strings = synthetic_sources(7)
        strings["public_header"] += (
            'const char *fake_v8_a = "#define '
            'SWIFTVLC_APPLE_AUDIO_RECOVERY_SNAPSHOT_VERSION 1";\n'
            'const char *fake_v8_b = "typedef struct '
            'swiftvlc_apple_audio_recovery_snapshot_t";\n'
            'const char *fake_v8_c = "'
            'swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot(";\n'
            'const char *fake_v8_d = "'
            'swiftvlc_libvlc_media_player_set_pause_without_reset_authorization(";\n'
        )
        strings["media_player"] += (
            'const char *fake_v8_e = "'
            'swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot(";\n'
            'const char *fake_v8_f = "'
            'swiftvlc_libvlc_media_player_set_pause_without_reset_authorization(";\n'
        )
        self.assertEqual(version.resolve_extension_version(strings).version, 7)

        v9_decoys = synthetic_sources(8, leases=True)
        v9 = synthetic_sources(9, leases=True)
        v8 = synthetic_sources(8, leases=True)
        for source_key in ("public_header", "media_player"):
            added = v9[source_key].replace(v8[source_key], "", 1)
            v9_decoys[source_key] += "\n/*\n" + added + "\n*/\n"
        v9_decoys["exports"] += (
            "# swiftvlc_libvlc_media_player_set_pip_playback_identity\n"
        )
        self.assertEqual(
            version.resolve_extension_version(v9_decoys).version, 8
        )

    def test_v9_semantic_publications_cannot_be_detached_from_their_owner(self) -> None:
        baseline = synthetic_sources(9, leases=True)
        mutations = {
            "identity-address-outside-setter": baseline["media_player"].replace(
                'var_SetAddress(p_mi, "swiftvlc-pip-playback-identity", '
                '&node->identity);',
                'var_SetAddress(p_mi, "wrong-identity", &node->identity);',
                1,
            ) + (
                '\nvoid decoy(void) { var_SetAddress(p_mi, '
                '"swiftvlc-pip-playback-identity", &node->identity); }\n'
            ),
            "identity-variable-outside-setup": baseline["media_player"].replace(
                'var_Create(mp, "swiftvlc-pip-playback-identity", '
                'VLC_VAR_ADDRESS);',
                'var_Create(mp, "wrong-identity", VLC_VAR_ADDRESS);',
                1,
            ) + (
                '\nvoid decoy(void) { var_Create(mp, '
                '"swiftvlc-pip-playback-identity", VLC_VAR_ADDRESS); }\n'
            ),
        }
        for name, media_player in mutations.items():
            with self.subTest(mutation=name):
                candidate = dict(baseline)
                candidate["media_player"] = media_player
                self.assert_rejected(candidate, expected_version=9)

    def test_v9_identity_concurrency_bypasses_fail_closed(self) -> None:
        baseline = synthetic_sources(9, leases=True)
        mutations = (
            (
                "always-exhausted-allocator",
                "sample_buffer_display",
                "if (current >= UINT64_MAX - 1)",
                "if (true || current >= UINT64_MAX - 1)",
            ),
            (
                "unconditional-cas",
                "sample_buffer_display",
                "if (atomic_compare_exchange_weak_explicit(",
                "if (true || atomic_compare_exchange_weak_explicit(",
            ),
            (
                "missing-locked-exit",
                "media_player",
                "        vlc_player_Unlock(p_mi->player); return false;",
                "        return false;",
            ),
            (
                "nonadvancing-destroy-loop",
                "media_player",
                "        identity = next;",
                "        identity = identity;",
            ),
            (
                "unconditional-null-copy",
                "sample_buffer_display",
                "if (identity != NULL)",
                "if (true)",
            ),
            (
                "wrong-private-copy-layout",
                "pip_controller_header",
                "    uint64_t native_handle_identity;\n"
                "    uint64_t playback_generation;\n"
                "} swiftvlc_pip_inherited_identity_t;",
                "    uint32_t native_handle_identity;\n"
                "    uint32_t playback_generation;\n"
                "} swiftvlc_pip_inherited_identity_t;",
            ),
            (
                "reset-global-output-source",
                "sample_buffer_display",
                "static atomic_uint_fast64_t pipOutputIdentitySource = "
                "ATOMIC_VAR_INIT(0);",
                "static atomic_uint_fast64_t pipOutputIdentitySource = "
                "ATOMIC_VAR_INIT(0);\n"
                "void reset(void) { atomic_store_explicit("
                "&pipOutputIdentitySource, 0, memory_order_relaxed); }",
            ),
            (
                "overwrite-copied-handle-before-map",
                "sample_buffer_display",
                "    int (*open)(pip_controller_t *) =",
                "    pip_controller->native_handle_identity = 0;\n"
                "    int (*open)(pip_controller_t *) =",
            ),
            (
                "mutate-input-before-lock",
                "media_player",
                "    vlc_player_Lock(p_mi->player);",
                "    playback_generation = 0;\n"
                "    vlc_player_Lock(p_mi->player);",
            ),
            (
                "discard-predecessor-before-link",
                "media_player",
                "    node->next = current;",
                "    current = NULL;\n    node->next = current;",
            ),
            (
                "overwrite-predecessor-link",
                "media_player",
                "    node->next = current;",
                "    node->next = current;\n    node->next = NULL;",
            ),
            (
                "null-node-after-allocation-check",
                "media_player",
                "    node->identity = (swiftvlc_pip_playback_identity_t) {",
                "    node = NULL;\n"
                "    node->identity = (swiftvlc_pip_playback_identity_t) {",
            ),
            (
                "compound-handle-field-mutation",
                "media_player",
                "    return true;\n}",
                "    p_mi->pip_native_handle_identity++;\n"
                "    return true;\n}",
            ),
            (
                "compound-list-link-mutation",
                "media_player",
                "    node->next = current;",
                "    node->next = current;\n    node->next += 1;",
            ),
            (
                "duplicate-identity-publication",
                "media_player",
                "    var_SetAddress(p_mi, \"swiftvlc-pip-playback-identity\", "
                "&node->identity);",
                "    var_SetAddress(p_mi, \"swiftvlc-pip-playback-identity\", "
                "&node->identity);\n"
                "    var_SetAddress(p_mi, \"swiftvlc-pip-playback-identity\", "
                "&node->identity);",
            ),
            (
                "destroy-identity-variable",
                "media_player",
                "    return true;\n}",
                "    var_Destroy(p_mi, \"swiftvlc-pip-playback-identity\");\n"
                "    return true;\n}",
            ),
            (
                "discard-inherited-identity-local",
                "sample_buffer_display",
                "    if (identity != NULL) {",
                "    identity = NULL;\n    if (identity != NULL) {",
            ),
            (
                "discard-retained-drawable-before-map",
                "sample_buffer_display",
                "vlc_module_map(vd->obj.logger, module);",
                "pip_controller->drawable = NULL;\n"
                "        vlc_module_map(vd->obj.logger, module);",
            ),
            (
                "leak-drawable-on-module-failure",
                "sample_buffer_display",
                "    CFBridgingRelease(pip_controller->drawable);\n"
                "    vlc_object_delete(pip_controller);\n"
                "    return NULL;\n}",
                "    vlc_object_delete(pip_controller);\n"
                "    return NULL;\n}",
            ),
        )
        for name, source_key, needle, replacement in mutations:
            with self.subTest(mutation=name):
                mutated = baseline[source_key].replace(needle, replacement, 1)
                self.assertNotEqual(mutated, baseline[source_key])
                candidate = dict(baseline)
                candidate[source_key] = mutated
                self.assert_rejected(candidate, expected_version=9)

    def test_v9_owner_scoping_and_claim_controls_fail_closed(self) -> None:
        baseline = synthetic_sources(9, leases=True)
        mutations = []

        detached_setup = dict(baseline)
        setup = (
            "    mp->pip_playback_identities = NULL;\n"
            "    mp->pip_native_handle_identity = 0;\n"
            "    var_Create(mp, \"swiftvlc-pip-playback-identity\", "
            "VLC_VAR_ADDRESS);\n"
        )
        detached_setup["media_player"] = detached_setup["media_player"].replace(
            setup, "", 1
        ) + "\nstatic void dead(libvlc_media_player_t *mp) {\n" + setup + "}\n"
        mutations.append(("dead-constructor-helper", detached_setup))

        detached_open = dict(baseline)
        detached_open["pip_controller"] = detached_open["pip_controller"].replace(
            "OpenController(pip_controller_t *pipcontroller)",
            "DetachedOpenController(pip_controller_t *pipcontroller)",
            1,
        ) + (
            "\nstatic int OpenController(pip_controller_t *pipcontroller) "
            "{ (void)pipcontroller; return VLC_EGENERIC; }\n"
        )
        mutations.append(("detached-open-helper", detached_open))

        claim_mutations = (
            (
                "overwritten-claim-result",
                "        if (!didClaim) {",
                "        didClaim = true;\n        if (!didClaim) {",
            ),
            (
                "closed-before-publication",
                "    pipcontroller->p_sys = (__bridge_retained void *)sys;",
                "    [sys close];\n"
                "    pipcontroller->p_sys = (__bridge_retained void *)sys;",
            ),
            (
                "rebind-before-preserved-claim",
                "        sys = preserved;",
                "        sys = preserved;\n"
                "        [sys rebindToPipController:pipcontroller];",
            ),
            (
                "duplicate-preserved-claim",
                "            outputIdentity:pipcontroller->output_identity];\n"
                "        if (!didClaim) {",
                "            outputIdentity:pipcontroller->output_identity];\n"
                "        [drawable pictureInPictureWindowController:sys\n"
                "            didClaimNativeHandle:pipcontroller->native_handle_identity\n"
                "            playbackGeneration:pipcontroller->playback_generation\n"
                "            outputIdentity:pipcontroller->output_identity];\n"
                "        if (!didClaim) {",
            ),
        )
        for name, needle, replacement in claim_mutations:
            candidate = dict(baseline)
            candidate["pip_controller"] = candidate["pip_controller"].replace(
                needle, replacement, 1
            )
            self.assertNotEqual(
                candidate["pip_controller"], baseline["pip_controller"]
            )
            mutations.append((name, candidate))

        for name, candidate in mutations:
            with self.subTest(mutation=name):
                self.assert_rejected(candidate, expected_version=9)

    def test_version_body_must_be_only_one_canonical_literal_return(self) -> None:
        mutations = (
            "{ return 10; }",
            "{ return 4 + 5; }",
            "{ if (1) return 9; return 9; }",
            "{ int ignored = 0; return 9; }",
            "{ return 09; }",
        )
        for body in mutations:
            with self.subTest(body=body):
                sources = version._replace_version_body(
                    synthetic_sources(9, leases=True), body
                )
                sources["media_player"] += (
                    "\nint unrelated(void) { return 9; }\n"
                )
                self.assert_rejected(sources)

    def test_native_and_vendored_headers_must_classify_identically(self) -> None:
        sources = synthetic_sources(9, leases=True)
        resolution = version.validate_vendored_headers(
            sources,
            sources["public_header"],
            sources["events_header"],
            9,
            ("apple-audio-session-leases",),
        )
        self.assertEqual(resolution.version, 9)
        with self.assertRaises(version.ExtensionVersionError):
            version.validate_vendored_headers(
                sources,
                synthetic_sources(8, leases=True)["public_header"],
                synthetic_sources(8, leases=True)["events_header"],
                9,
                ("apple-audio-session-leases",),
            )
        with self.assertRaises(version.ExtensionVersionError):
            version.validate_vendored_headers(
                sources,
                sources["public_header"],
                synthetic_sources(6)["events_header"],
                9,
                ("apple-audio-session-leases",),
            )

    def test_realistic_negative_mutation_matrix_is_complete(self) -> None:
        self.assertEqual(
            version.run_negative_mutations(synthetic_sources(4), 4),
            41,
        )
        caught = version.run_negative_mutations(
            synthetic_sources(8, leases=True),
            8,
            ("apple-audio-session-leases",),
        )
        self.assertEqual(caught, 49)
        v9_caught = version.run_negative_mutations(
            synthetic_sources(9, leases=True),
            9,
            ("apple-audio-session-leases",),
        )
        self.assertEqual(v9_caught, 103)

    def test_invalid_manifest_intent_is_rejected(self) -> None:
        sources = synthetic_sources(8, leases=True)
        for expected in (3, 10, True):
            with self.subTest(expected=expected):
                self.assert_rejected(sources, expected_version=expected)
        self.assert_rejected(
            sources, required_same_version_groups=("unknown",)
        )
        self.assert_rejected(
            sources,
            required_same_version_groups=(
                "apple-audio-session-leases",
                "apple-audio-session-leases",
            ),
        )


class NativeExtensionArchiveContractTests(unittest.TestCase):
    """Exercise the all-slice archive gate with deterministic fake Mach-O tools."""

    def setUp(self) -> None:
        external_root = os.environ.get("SWIFTVLC_VALIDATION_TMP_ROOT")
        temporary_parent = None
        if external_root:
            temporary_parent = Path(external_root)
            temporary_parent.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(
            prefix="swiftvlc-native-archive-test.", dir=temporary_parent
        )
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)
        self.xcframework = self.root / "Fixture.xcframework"
        self.xcframework.mkdir()
        self.libraries: list[dict[str, object]] = []
        self.fake_tools = self.root / "fake-tools"
        self.fake_tools.mkdir()
        self._write_fake_tools()

    def _write_executable(self, name: str, body: str) -> None:
        path = self.fake_tools / name
        path.write_text(textwrap.dedent(body), encoding="utf-8")
        path.chmod(0o755)

    def _write_fake_tools(self) -> None:
        self._write_executable(
            "uname",
            """\
            #!/bin/sh
            if [ "${1:-}" = "-s" ]; then
                echo Darwin
            elif [ "${1:-}" = "-m" ]; then
                echo arm64
            else
                echo Darwin
            fi
            """,
        )
        self._write_executable(
            "xcrun",
            """\
            #!/usr/bin/env python3
            from pathlib import Path
            import sys

            tools = Path(__file__).resolve().parent
            arguments = sys.argv[1:]
            if arguments == ["--find", "lipo"]:
                print(tools / "lipo")
            elif arguments == ["--find", "nm"]:
                print(tools / "nm")
            elif arguments == ["--sdk", "macosx", "--find", "clang"]:
                print(tools / "clang")
            elif arguments == ["--sdk", "macosx", "--show-sdk-path"]:
                print("/")
            else:
                print(f"unexpected fake xcrun arguments: {arguments}", file=sys.stderr)
                raise SystemExit(2)
            """,
        )
        self._write_executable(
            "lipo",
            """\
            #!/usr/bin/env python3
            import json
            from pathlib import Path
            import sys

            if len(sys.argv) != 3 or sys.argv[1] != "-archs":
                raise SystemExit("fake lipo expects -archs <archive>")
            payload = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
            print(" ".join(payload["architectures"]))
            """,
        )
        self._write_executable(
            "nm",
            """\
            #!/usr/bin/env python3
            import json
            from pathlib import Path
            import sys

            arguments = sys.argv[1:]
            if len(arguments) != 4 or arguments[0] != "-arch" or arguments[2] != "-gm":
                raise SystemExit(f"unexpected fake nm arguments: {arguments}")
            architecture = arguments[1]
            payload = json.loads(Path(arguments[3]).read_text(encoding="utf-8"))
            for kind, symbol in payload["symbols"].get(architecture, []):
                if kind == "strong":
                    print(f"0000000000000000 (__TEXT,__text) external _{symbol}")
                elif kind == "weak":
                    print(f"0000000000000000 (__TEXT,__text) weak external _{symbol}")
                elif kind == "data":
                    print(f"0000000000000000 (__DATA,__data) external _{symbol}")
                else:
                    raise SystemExit(f"unknown fake symbol kind: {kind}")
            """,
        )
        self._write_executable(
            "clang",
            """\
            #!/usr/bin/env python3
            from pathlib import Path
            import os
            import sys

            arguments = sys.argv[1:]
            output = Path(arguments[arguments.index("-o") + 1])
            prefix = "-DSWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION="
            version = next(value[len(prefix):] for value in arguments if value.startswith(prefix))
            lease_prefix = "-DSWIFTVLC_REQUIRE_APPLE_AUDIO_SESSION_LEASES="
            next(value for value in arguments if value.startswith(lease_prefix))
            output.write_text(f"#!/bin/sh\\nprintf '%s\\\\n' '{version}'\\n", encoding="utf-8")
            os.chmod(output, 0o755)
            """,
        )

    @staticmethod
    def symbols_through(extension_version: int, *, leases: bool) -> list[str]:
        symbols = []
        for introduced, introduced_symbols in VERSIONED_ARCHIVE_SYMBOLS.items():
            if introduced <= extension_version:
                symbols.extend(introduced_symbols)
        if leases:
            symbols.extend(LEASE_ARCHIVE_SYMBOLS)
        return symbols

    def add_slice(
        self,
        identifier: str,
        architectures: tuple[str, ...],
        *,
        platform: str,
        extension_version: int,
        leases: bool = False,
        variant: Optional[str] = None,
    ) -> Path:
        directory = self.xcframework / identifier
        directory.mkdir()
        archive = directory / "libvlc.a"
        symbols = self.symbols_through(extension_version, leases=leases)
        payload = {
            "architectures": list(architectures),
            "symbols": {
                architecture: [["strong", symbol] for symbol in symbols]
                for architecture in architectures
            },
        }
        archive.write_text(json.dumps(payload), encoding="utf-8")
        library: dict[str, object] = {
            "LibraryIdentifier": identifier,
            "LibraryPath": "libvlc.a",
            "BinaryPath": "libvlc.a",
            "SupportedArchitectures": list(architectures),
            "SupportedPlatform": platform,
        }
        if variant is not None:
            library["SupportedPlatformVariant"] = variant
        self.libraries.append(library)
        return archive

    @staticmethod
    def mutate_symbol(
        archive: Path,
        architecture: str,
        symbol: str,
        replacement: list[list[str]],
    ) -> None:
        payload = json.loads(archive.read_text(encoding="utf-8"))
        retained = [
            entry for entry in payload["symbols"][architecture]
            if entry[1] != symbol
        ]
        payload["symbols"][architecture] = retained + replacement
        archive.write_text(json.dumps(payload), encoding="utf-8")

    def run_contract(
        self, expected_version: int, *, require_leases: bool = False
    ) -> subprocess.CompletedProcess[str]:
        (self.xcframework / "Info.plist").write_bytes(
            plistlib.dumps({"AvailableLibraries": self.libraries})
        )
        environment = dict(os.environ)
        environment["PATH"] = str(self.fake_tools) + os.pathsep + environment["PATH"]
        environment["SWIFTVLC_VALIDATION_TMP_ROOT"] = str(self.root / "work")
        command = [
            "/bin/bash",
            str(ARCHIVE_VALIDATOR),
            "--xcframework",
            str(self.xcframework),
            "--expected-version",
            str(expected_version),
        ]
        if require_leases:
            command.append("--require-apple-audio-session-leases")
        return subprocess.run(
            command, capture_output=True, text=True, env=environment, check=False
        )

    def test_device_only_contract_checks_every_slice_and_architecture(self) -> None:
        self.add_slice(
            "ios-arm64", ("arm64",), platform="ios",
            extension_version=9, leases=True,
        )
        self.add_slice(
            "ios-arm64_x86_64-simulator", ("arm64", "x86_64"),
            platform="ios", variant="simulator", extension_version=9,
            leases=True,
        )
        # v9 inherits the v8+0033 profile even when the caller omits the
        # historical v8 opt-in flag.
        result = self.run_contract(9)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("runtime=skipped", result.stdout)
        self.assertIn("slices=2 architectures=3", result.stdout)

    def test_v9_archive_cannot_omit_inherited_lease_symbols(self) -> None:
        self.add_slice(
            "ios-arm64", ("arm64",), platform="ios",
            extension_version=9, leases=False,
        )
        result = self.run_contract(9)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Required Apple audio-session lease symbols are absent", result.stderr)

    def test_non_host_slice_missing_required_symbol_is_rejected(self) -> None:
        self.add_slice(
            "ios-arm64", ("arm64",), platform="ios", extension_version=9,
            leases=True,
        )
        simulator = self.add_slice(
            "ios-arm64_x86_64-simulator", ("arm64", "x86_64"),
            platform="ios", variant="simulator", extension_version=9,
            leases=True,
        )
        missing = VERSIONED_ARCHIVE_SYMBOLS[9][0]
        self.mutate_symbol(simulator, "x86_64", missing, [])
        result = self.run_contract(9, require_leases=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ios-arm64_x86_64-simulator/x86_64", result.stderr)
        self.assertIn(missing, result.stderr)

    def test_future_and_partial_same_version_groups_are_rejected(self) -> None:
        archive = self.add_slice(
            "ios-arm64", ("arm64",), platform="ios", extension_version=8,
            leases=True,
        )
        future = VERSIONED_ARCHIVE_SYMBOLS[9][0]
        self.mutate_symbol(archive, "arm64", future, [["strong", future]])
        result = self.run_contract(8, require_leases=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Future native extension symbol is present", result.stderr)

        self.mutate_symbol(archive, "arm64", future, [])
        # Preserve the v8 base and make its same-version lease refinement
        # partial: v9 must not erase the independent lease contract.
        self.mutate_symbol(archive, "arm64", LEASE_ARCHIVE_SYMBOLS[1], [])
        result = self.run_contract(8)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("lease symbol group is partial", result.stderr)

    def test_duplicate_and_weak_only_required_symbols_are_rejected(self) -> None:
        archive = self.add_slice(
            "ios-arm64", ("arm64",), platform="ios", extension_version=9,
            leases=True,
        )
        required = VERSIONED_ARCHIVE_SYMBOLS[9][0]
        self.mutate_symbol(
            archive, "arm64", required,
            [["strong", required], ["strong", required]],
        )
        result = self.run_contract(9, require_leases=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("strong=2 definitions=2", result.stderr)

        self.mutate_symbol(archive, "arm64", required, [["weak", required]])
        result = self.run_contract(9, require_leases=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("strong=0 definitions=1", result.stderr)

    def test_plist_architecture_and_archive_inventory_drift_is_rejected(self) -> None:
        self.add_slice(
            "ios-arm64", ("arm64",), platform="ios", extension_version=8,
        )
        self.libraries[0]["SupportedArchitectures"] = ["arm64", "x86_64"]
        result = self.run_contract(8)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("architecture mismatch", result.stderr)

        self.libraries[0]["SupportedArchitectures"] = ["arm64"]
        extra = self.xcframework / "unexpected" / "libvlc.a"
        extra.parent.mkdir()
        extra.write_text("not declared", encoding="utf-8")
        result = self.run_contract(8)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("archive inventory differs", result.stderr)


if __name__ == "__main__":
    unittest.main()
