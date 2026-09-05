#!/usr/bin/env python3
"""Adversarial unit tests for the shared PiP extension-version resolver."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import re
import unittest
from typing import Dict


HELPER_PATH = Path(__file__).with_name("pip_extension_version.py")
SPEC = importlib.util.spec_from_file_location(
    "swiftvlc_pip_extension_version", HELPER_PATH
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot import resolver: {HELPER_PATH}")
VERSION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERSION)


def make_sources(version: int, leases: bool = False) -> Dict[str, str]:
    """Build one minimal but realistic contiguous v4-v10 source surface."""
    if version not in range(4, 11):
        raise ValueError(f"unsupported fixture version: {version}")
    if leases and version < 8:
        raise ValueError("the lease refinement requires version 8 or newer")

    public_header = [
        "unsigned swiftvlc_libvlc_pip_extensions_version(void);",
        "typedef enum swiftvlc_next_frame_request_result_t {",
        "    swiftvlc_next_frame_request_accepted = 0,",
        "} swiftvlc_next_frame_request_result_t;",
        "int swiftvlc_libvlc_media_player_request_next_frame(void);",
        "int swiftvlc_libvlc_media_player_cancel_next_frame_request(void);",
        "void swiftvlc_libvlc_video_set_display_status_callback(void);",
        "int swiftvlc_libvlc_video_set_callbacks_atomic(void);",
    ]
    media_player = [
        "unsigned swiftvlc_libvlc_pip_extensions_version(void)",
        "{",
        f"    return {version};",
        "}",
        "int swiftvlc_libvlc_media_player_request_next_frame(void)",
        "{",
        "    return 0;",
        "}",
        "int swiftvlc_libvlc_media_player_cancel_next_frame_request(void)",
        "{",
        "    return 0;",
        "}",
        "void swiftvlc_libvlc_video_set_display_status_callback(void)",
        "{",
        "}",
        "int swiftvlc_libvlc_video_set_callbacks_atomic(void)",
        "{",
        "    return 0;",
        "}",
    ]
    events_header = []
    exports = [
        "swiftvlc_libvlc_pip_extensions_version",
        "swiftvlc_libvlc_media_player_request_next_frame",
        "swiftvlc_libvlc_media_player_cancel_next_frame_request",
        "swiftvlc_libvlc_video_set_display_status_callback",
        "swiftvlc_libvlc_video_set_callbacks_atomic",
    ]

    if version >= 5:
        public_header.extend([
            "typedef struct swiftvlc_sample_buffer_renderer_snapshot_t {",
            "    unsigned abi_version;",
            "} swiftvlc_sample_buffer_renderer_snapshot_t;",
            "bool swiftvlc_libvlc_media_player_get_sample_buffer_renderer_"
            "snapshot(void);",
        ])
        media_player.extend([
            "bool swiftvlc_libvlc_media_player_get_sample_buffer_renderer_"
            "snapshot(void)",
            "{",
            "    return false;",
            "}",
        ])
        exports.append(
            "swiftvlc_libvlc_media_player_get_sample_buffer_renderer_snapshot"
        )

    if version >= 6:
        public_header.extend([
            "#define SWIFTVLC_VMEM_INVALID_PICTURE_PTS_US INT64_MIN",
            "typedef int (*swiftvlc_video_display_status_v2_cb)"
            "(void *, void *, long long);",
            "int swiftvlc_libvlc_video_set_callbacks_atomic_v2(void);",
        ])
        media_player.extend([
            "int swiftvlc_libvlc_video_set_callbacks_atomic_v2(void)",
            "{",
            "    return 0;",
            "}",
        ])
        exports.append("swiftvlc_libvlc_video_set_callbacks_atomic_v2")

    if version >= 7:
        events_header.extend([
            "enum libvlc_event_e {",
            "    libvlc_MediaPlayerRateChanged,",
            "};",
            "struct event_payload {",
            "    struct { float new_rate; } media_player_rate_changed;",
            "};",
        ])
        media_player.extend([
            "static void publish_rate_event(void)",
            "{",
            "    event.type = libvlc_MediaPlayerRateChanged,",
            "    event.u.media_player_rate_changed.new_rate = 1.0f;",
            "}",
        ])

    if version >= 8:
        public_header.extend([
            "#define SWIFTVLC_APPLE_AUDIO_RECOVERY_SNAPSHOT_VERSION 1",
            "typedef struct swiftvlc_apple_audio_recovery_snapshot_t {",
            "    unsigned version;",
            "} swiftvlc_apple_audio_recovery_snapshot_t;",
            "bool swiftvlc_libvlc_media_player_get_apple_audio_recovery_"
            "snapshot(void);",
            "void swiftvlc_libvlc_media_player_set_pause_without_reset_"
            "authorization(void);",
        ])
        media_player.extend([
            "bool swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot(void)",
            "{",
            "    return false;",
            "}",
            "void swiftvlc_libvlc_media_player_set_pause_without_reset_"
            "authorization(void)",
            "{",
            "}",
        ])
        exports.extend([
            "swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot",
            "swiftvlc_libvlc_media_player_set_pause_without_reset_authorization",
        ])

    if version >= 9:
        public_header.extend([
            "typedef struct swiftvlc_pip_playback_identity_t {",
            "    uint64_t native_handle_identity;",
            "    uint64_t playback_generation;",
            "} swiftvlc_pip_playback_identity_t;",
            "LIBVLC_API bool",
            "swiftvlc_libvlc_media_player_set_pip_playback_identity(",
            "    libvlc_media_player_t *p_mi,",
            "    uint64_t native_handle_identity,",
            "    uint64_t playback_generation);",
        ])
        media_player.extend([
            "struct swiftvlc_pip_playback_identity_node {",
            "    swiftvlc_pip_playback_identity_t identity;",
            "    struct swiftvlc_pip_playback_identity_node *next;",
            "};",
            "libvlc_media_player_t *",
            "libvlc_media_player_new(libvlc_instance_t *instance)",
            "{",
            "    libvlc_media_player_t *mp = vlc_object_create(instance, sizeof(*mp));",
            "    mp->pip_playback_identities = NULL;",
            "    mp->pip_native_handle_identity = 0;",
            "    var_Create(mp, \"swiftvlc-pip-playback-identity\", VLC_VAR_ADDRESS);",
            "    return mp;",
            "}",
            "static void libvlc_media_player_destroy(libvlc_media_player_t *p_mi)",
            "{",
            "    vlc_player_Delete(p_mi->player);",
            "    struct swiftvlc_pip_playback_identity_node *identity =",
            "        p_mi->pip_playback_identities;",
            "    while (identity != NULL) {",
            "        struct swiftvlc_pip_playback_identity_node *next = identity->next;",
            "        free(identity);",
            "        identity = next;",
            "    }",
            "    vlc_object_delete(p_mi);",
            "}",
            "bool swiftvlc_libvlc_media_player_set_pip_playback_identity(",
            "    libvlc_media_player_t *p_mi,",
            "    uint64_t native_handle_identity,",
            "    uint64_t playback_generation)",
            "{",
            "    if (p_mi == NULL || native_handle_identity == 0 || playback_generation == 0)",
            "        return false;",
            "    vlc_player_Lock(p_mi->player);",
            "    if (p_mi->pip_native_handle_identity != 0 &&",
            "        p_mi->pip_native_handle_identity != native_handle_identity) {",
            "        vlc_player_Unlock(p_mi->player);",
            "        return false;",
            "    }",
            "    struct swiftvlc_pip_playback_identity_node *current =",
            "        p_mi->pip_playback_identities;",
            "    if (current != NULL &&",
            "        current->identity.native_handle_identity == native_handle_identity &&",
            "        current->identity.playback_generation == playback_generation) {",
            "        vlc_player_Unlock(p_mi->player);",
            "        return true;",
            "    }",
            "    if (current != NULL &&",
            "        playback_generation < current->identity.playback_generation) {",
            "        vlc_player_Unlock(p_mi->player);",
            "        return false;",
            "    }",
            "    struct swiftvlc_pip_playback_identity_node *node = malloc(sizeof(*node));",
            "    if (node == NULL) {",
            "        vlc_player_Unlock(p_mi->player);",
            "        return false;",
            "    }",
            "    node->identity = (swiftvlc_pip_playback_identity_t) {",
            "        .native_handle_identity = native_handle_identity,",
            "        .playback_generation = playback_generation,",
            "    };",
            "    p_mi->pip_native_handle_identity = native_handle_identity;",
            "    node->next = current;",
            "    p_mi->pip_playback_identities = node;",
            "    var_SetAddress(p_mi, \"swiftvlc-pip-playback-identity\", &node->identity);",
            "    vlc_player_Unlock(p_mi->player);",
            "    return true;",
            "}",
        ])
        exports.append(
            "swiftvlc_libvlc_media_player_set_pip_playback_identity"
        )

    if version >= 10:
        public_header.append(
            "bool swiftvlc_libvlc_media_player_"
            "set_subtitle_text_snapshot_callback(void);"
        )
        media_player.extend([
            "bool swiftvlc_libvlc_media_player_"
            "set_subtitle_text_snapshot_callback(void)",
            "{",
            "    return true;",
            "}",
        ])
        exports.append(
            "swiftvlc_libvlc_media_player_"
            "set_subtitle_text_snapshot_callback"
        )

    drawable_header = ""
    media_player_internal = ""
    pip_controller = ""
    pip_controller_header = ""
    sample_buffer_display = ""
    if version >= 9:
        drawable_header = "\n".join([
            "- (id<VLCPictureInPictureWindowControlling>)",
            "    takePreservedPictureInPictureWindowControllerForNativeHandle:",
            "        (uint64_t)nativeHandle",
            "    playbackGeneration:(uint64_t)playbackGeneration",
            "    outputIdentity:(uint64_t)outputIdentity",
            "    wasSuperseded:(BOOL *)wasSuperseded;",
            "- (BOOL)preservePictureInPictureWindowController:",
            "    (id<VLCPictureInPictureWindowControlling>)controller",
            "    fromNativeHandle:(uint64_t)nativeHandle",
            "    playbackGeneration:(uint64_t)playbackGeneration",
            "    outputIdentity:(uint64_t)outputIdentity",
            "    sameMediaGenerationRebuild:(BOOL)sameMediaGenerationRebuild;",
            "- (BOOL)pictureInPictureWindowController:",
            "    (id<VLCPictureInPictureWindowControlling>)controller",
            "    didBecomeReadyForNativeHandle:(uint64_t)nativeHandle",
            "    playbackGeneration:(uint64_t)playbackGeneration",
            "    outputIdentity:(uint64_t)outputIdentity;",
            "- (BOOL)pictureInPictureWindowController:",
            "    (id<VLCPictureInPictureWindowControlling>)controller",
            "    didClaimNativeHandle:(uint64_t)nativeHandle",
            "    playbackGeneration:(uint64_t)playbackGeneration",
            "    outputIdentity:(uint64_t)outputIdentity;",
            "- (void)pictureInPictureControllerCreationFailedForNativeHandle:",
            "    (uint64_t)nativeHandle",
            "    playbackGeneration:(uint64_t)playbackGeneration",
            "    outputIdentity:(uint64_t)outputIdentity;",
            "- (void)pictureInPictureWindowController:",
            "    (id<VLCPictureInPictureWindowControlling>)controller",
            "    cancelHandoffForNativeHandle:(uint64_t)nativeHandle",
            "    playbackGeneration:(uint64_t)playbackGeneration",
            "    outputIdentity:(uint64_t)outputIdentity;",
            "- (void)pictureInPictureWindowController:",
            "    (id<VLCPictureInPictureWindowControlling>)controller",
            "    handoffDidTimeOutForNativeHandle:(uint64_t)nativeHandle",
            "    playbackGeneration:(uint64_t)playbackGeneration",
            "    outputIdentity:(uint64_t)outputIdentity;",
        ]) + "\n"
        media_player_internal = "\n".join([
            "struct libvlc_media_player_t {",
            "    struct swiftvlc_pip_playback_identity_node *pip_playback_identities;",
            "    uint64_t pip_native_handle_identity;",
            "};",
        ]) + "\n"
        pip_controller_header = "\n".join([
            "typedef struct swiftvlc_pip_inherited_identity_t {",
            "    uint64_t native_handle_identity;",
            "    uint64_t playback_generation;",
            "} swiftvlc_pip_inherited_identity_t;",
            "struct pip_controller_t {",
            "    void *drawable;",
            "    uint64_t native_handle_identity;",
            "    uint64_t playback_generation;",
            "    uint64_t output_identity;",
            "};",
        ]) + "\n"
        sample_buffer_display = "\n".join([
            "static atomic_uint_fast64_t pipOutputIdentitySource = ATOMIC_VAR_INIT(0);",
            "static uint64_t NextPipOutputIdentity(void)",
            "{",
            "    uint_fast64_t current = atomic_load_explicit(",
            "        &pipOutputIdentitySource, memory_order_relaxed);",
            "    for (;;) {",
            "        if (current >= UINT64_MAX - 1) {",
            "            if (current == UINT64_MAX - 1)",
            "                atomic_compare_exchange_strong_explicit(",
            "                    &pipOutputIdentitySource, &current, UINT64_MAX,",
            "                    memory_order_relaxed, memory_order_relaxed);",
            "            return 0;",
            "        }",
            "        uint_fast64_t next = current + 1;",
            "        if (atomic_compare_exchange_weak_explicit(",
            "                &pipOutputIdentitySource, &current, next,",
            "                memory_order_relaxed, memory_order_relaxed))",
            "            return next;",
            "    }",
            "}",
            "static pip_controller_t *CreatePipController(",
            "    vout_display_t *vd, void *cbs_opaque)",
            "{",
            "    pip_controller_t *pip_controller = vlc_object_create(vd, sizeof(*pip_controller));",
            "    id drawable = (__bridge id)var_InheritAddress(vd, \"drawable-nsobject\");",
            "    pip_controller->drawable = (__bridge_retained void *)drawable;",
            "    const void *identity =",
            "        var_InheritAddress(vd, \"swiftvlc-pip-playback-identity\");",
            "    if (identity != NULL) {",
            "        swiftvlc_pip_inherited_identity_t snapshot;",
            "        memcpy(&snapshot, identity, sizeof(snapshot));",
            "        pip_controller->native_handle_identity = snapshot.native_handle_identity;",
            "        pip_controller->playback_generation = snapshot.playback_generation;",
            "    } else {",
            "        pip_controller->native_handle_identity = 0;",
            "        pip_controller->playback_generation = 0;",
            "    }",
            "    pip_controller->output_identity = NextPipOutputIdentity();",
            "    if (pip_controller->output_identity == 0) {",
            "        CFBridgingRelease(pip_controller->drawable);",
            "        vlc_object_delete(pip_controller);",
            "        return NULL;",
            "    }",
            "    int (*open)(pip_controller_t *) =",
            "        vlc_module_map(vd->obj.logger, module);",
            "    if (open)",
            "        return pip_controller;",
            "    CFBridgingRelease(pip_controller->drawable);",
            "    vlc_object_delete(pip_controller);",
            "    return NULL;",
            "}",
        ]) + "\n"
        pip_controller = "\n".join([
            "static int OpenController(pip_controller_t *pipcontroller)",
            "{",
            "    id<VLCPictureInPictureDrawable> drawable =",
            "        (__bridge id)pipcontroller->drawable;",
            "    BOOL hasExactIdentity =",
            "        pipcontroller->native_handle_identity != 0 &&",
            "        pipcontroller->playback_generation != 0 &&",
            "        pipcontroller->output_identity != 0 &&",
            "        pipcontroller->output_identity != VLC_PIP_HANDOFF_TOKEN_CLAIMED;",
            "    BOOL missingExactLifecycle =",
            "        ![drawable respondsToSelector:@selector(",
            "            takePreservedPictureInPictureWindowControllerForNativeHandle:",
            "            playbackGeneration:outputIdentity:wasSuperseded:)] ||",
            "        ![drawable respondsToSelector:@selector(",
            "            pictureInPictureWindowController:didClaimNativeHandle:",
            "            playbackGeneration:outputIdentity:)] ||",
            "        ![drawable respondsToSelector:@selector(",
            "            pictureInPictureControllerCreationFailedForNativeHandle:",
            "            playbackGeneration:outputIdentity:)] ||",
            "        ![drawable respondsToSelector:@selector(",
            "            pictureInPictureWindowController:cancelHandoffForNativeHandle:",
            "            playbackGeneration:outputIdentity:)] ||",
            "        ![drawable respondsToSelector:@selector(",
            "            pictureInPictureWindowController:didBecomeReadyForNativeHandle:",
            "            playbackGeneration:outputIdentity:)] ||",
            "        ![drawable respondsToSelector:@selector(",
            "            preservePictureInPictureWindowController:fromNativeHandle:",
            "            playbackGeneration:outputIdentity:",
            "            sameMediaGenerationRebuild:)] ||",
            "        ![drawable respondsToSelector:@selector(",
            "            pictureInPictureWindowController:handoffDidTimeOutForNativeHandle:",
            "            playbackGeneration:outputIdentity:)];",
            "    if (!hasExactIdentity || missingExactLifecycle)",
            "        return VLC_EGENERIC;",
            "    BOOL handoffWasSuperseded = NO;",
            "    id preserved = [drawable",
            "        takePreservedPictureInPictureWindowControllerForNativeHandle:",
            "            pipcontroller->native_handle_identity",
            "        playbackGeneration:pipcontroller->playback_generation",
            "        outputIdentity:pipcontroller->output_identity",
            "        wasSuperseded:&handoffWasSuperseded];",
            "    VLCPictureInPictureController *sys = nil;",
            "    if (preserved != nil) {",
            "        sys = preserved;",
            "        BOOL didClaim = [drawable pictureInPictureWindowController:sys",
            "            didClaimNativeHandle:pipcontroller->native_handle_identity",
            "            playbackGeneration:pipcontroller->playback_generation",
            "            outputIdentity:pipcontroller->output_identity];",
            "        if (!didClaim) {",
            "            [drawable pictureInPictureWindowController:sys",
            "                cancelHandoffForNativeHandle:",
            "                    pipcontroller->native_handle_identity",
            "                playbackGeneration:pipcontroller->playback_generation",
            "                outputIdentity:pipcontroller->output_identity];",
            "            [sys close];",
            "            return VLC_EGENERIC;",
            "        }",
            "        if (![sys rebindToPipController:pipcontroller]) {",
            "            [drawable pictureInPictureWindowController:sys",
            "                cancelHandoffForNativeHandle:",
            "                    pipcontroller->native_handle_identity",
            "                playbackGeneration:pipcontroller->playback_generation",
            "                outputIdentity:pipcontroller->output_identity];",
            "            [sys close];",
            "            return VLC_EGENERIC;",
            "        }",
            "    } else {",
            "        sys = [[VLCPictureInPictureController alloc]",
            "            initWithPipController:pipcontroller];",
            "        if (sys == nil) {",
            "            [drawable",
            "                pictureInPictureControllerCreationFailedForNativeHandle:",
            "                    pipcontroller->native_handle_identity",
            "                playbackGeneration:pipcontroller->playback_generation",
            "                outputIdentity:pipcontroller->output_identity];",
            "            return VLC_EGENERIC;",
            "        }",
            "        BOOL didClaim = [drawable pictureInPictureWindowController:sys",
            "            didClaimNativeHandle:pipcontroller->native_handle_identity",
            "            playbackGeneration:pipcontroller->playback_generation",
            "            outputIdentity:pipcontroller->output_identity];",
            "        if (!didClaim) {",
            "            [drawable",
            "                pictureInPictureControllerCreationFailedForNativeHandle:",
            "                    pipcontroller->native_handle_identity",
            "                playbackGeneration:pipcontroller->playback_generation",
            "                outputIdentity:pipcontroller->output_identity];",
            "            [sys closeForNativeHandle:pipcontroller->native_handle_identity",
            "                playbackGeneration:pipcontroller->playback_generation",
            "                outputIdentity:pipcontroller->output_identity];",
            "            return VLC_EGENERIC;",
            "        }",
            "    }",
            "    if (![sys startPreparationTimeoutForNativeHandle:",
            "            pipcontroller->native_handle_identity",
            "            playbackGeneration:pipcontroller->playback_generation",
            "            outputIdentity:pipcontroller->output_identity]) {",
            "        [drawable pictureInPictureWindowController:sys",
            "            cancelHandoffForNativeHandle:",
            "                pipcontroller->native_handle_identity",
            "            playbackGeneration:pipcontroller->playback_generation",
            "            outputIdentity:pipcontroller->output_identity];",
            "        [sys closeForNativeHandle:pipcontroller->native_handle_identity",
            "            playbackGeneration:pipcontroller->playback_generation",
            "            outputIdentity:pipcontroller->output_identity];",
            "        return VLC_EGENERIC;",
            "    }",
            "    pipcontroller->p_sys = (__bridge_retained void *)sys;",
            "    return VLC_SUCCESS;",
            "}",
        ]) + "\n"

    if leases:
        public_header.extend([
            "typedef uint64_t swiftvlc_apple_audio_session_lease_t;",
            "typedef enum swiftvlc_apple_audio_session_lease_result_t {",
            "    swiftvlc_apple_audio_session_lease_failed = -1,",
            "} swiftvlc_apple_audio_session_lease_result_t;",
            "int swiftvlc_libvlc_media_player_acquire_apple_audio_session_lease(void);",
            "bool swiftvlc_libvlc_media_player_release_apple_audio_session_"
            "lease(void);",
        ])
        media_player.extend([
            "int swiftvlc_libvlc_media_player_acquire_apple_audio_session_lease(void)",
            "{",
            "    return 0;",
            "}",
            "bool swiftvlc_libvlc_media_player_release_apple_audio_session_lease(void)",
            "{",
            "    return false;",
            "}",
        ])
        exports.extend([
            "swiftvlc_libvlc_media_player_acquire_apple_audio_session_lease",
            "swiftvlc_libvlc_media_player_release_apple_audio_session_lease",
        ])

    return {
        "media_player": "\n".join(media_player) + "\n",
        "public_header": "\n".join(public_header) + "\n",
        "events_header": "\n".join(events_header) + "\n",
        "exports": "\n".join(exports) + "\n",
        "drawable_header": drawable_header,
        "media_player_internal": media_player_internal,
        "pip_controller": pip_controller,
        "pip_controller_header": pip_controller_header,
        "sample_buffer_display": sample_buffer_display,
    }


def marker_matches(sources: Dict[str, str], current: object):
    source_key = current.source_key
    source = sources[source_key]
    searchable = (
        source
        if source_key == "exports"
        else VERSION.strip_c_comments_and_literals(source)
    )
    return tuple(re.finditer(current.pattern, searchable))


def remove_marker(sources: Dict[str, str], current: object) -> Dict[str, str]:
    candidate = dict(sources)
    matches = marker_matches(candidate, current)
    if len(matches) != 1:
        raise AssertionError(
            f"fixture marker count for {current.label} is {len(matches)}, not one"
        )
    found = matches[0]
    source = candidate[current.source_key]
    candidate[current.source_key] = (
        source[: found.start()] + "SWIFTVLC_REMOVED_MARKER" + source[found.end() :]
    )
    return candidate


def remove_group(sources: Dict[str, str], group: object) -> Dict[str, str]:
    candidate = dict(sources)
    for current in group.markers:
        candidate = remove_marker(candidate, current)
    return candidate


def duplicate_marker(
    sources: Dict[str, str], current: object
) -> Dict[str, str]:
    candidate = dict(sources)
    matches = marker_matches(candidate, current)
    if len(matches) != 1:
        raise AssertionError(
            f"fixture marker count for {current.label} is {len(matches)}, not one"
        )
    found = matches[0]
    source = candidate[current.source_key]
    duplicate = source[found.start() : found.end()]
    candidate[current.source_key] = source + "\n" + duplicate + "\n"
    return candidate


def replace_version_body(
    sources: Dict[str, str], replacement: str
) -> Dict[str, str]:
    candidate = dict(sources)
    cleaned = VERSION.strip_c_comments_and_literals(candidate["media_player"])
    start, end, _ = VERSION.version_function_body(cleaned)
    source = candidate["media_player"]
    candidate["media_player"] = source[:start] + replacement + source[end:]
    return candidate


def compatibility_shim() -> str:
    return """
__attribute__((weak))
bool swiftvlc_libvlc_media_player_set_pip_playback_identity(
    libvlc_media_player_t *player,
    uint64_t native_handle_identity,
    uint64_t playback_generation) {
    (void)player;
    (void)native_handle_identity;
    (void)playback_generation;
    return false;
}

bool swiftvlc_media_player_set_pip_playback_identity_if_available(
    libvlc_media_player_t *player,
    uint64_t native_handle_identity,
    uint64_t playback_generation) {
#if defined(__APPLE__)
    if (swiftvlc_libvlc_pip_extensions_version() < 9) {
        return false;
    }
    return swiftvlc_libvlc_media_player_set_pip_playback_identity(
        player, native_handle_identity, playback_generation);
#else
    (void)player;
    (void)native_handle_identity;
    (void)playback_generation;
    return false;
#endif
}

bool swiftvlc_native_pip_handoff_v9_available(void) {
#if defined(__APPLE__)
    return swiftvlc_libvlc_pip_extensions_version() >= 9;
#else
    return false;
#endif
}

__attribute__((weak))
bool swiftvlc_libvlc_media_player_set_subtitle_text_snapshot_callback(
    libvlc_media_player_t *player,
    swiftvlc_subtitle_text_snapshot_cb callback,
    void *opaque) {
    (void)player;
    (void)callback;
    (void)opaque;
    return false;
}

bool swiftvlc_media_player_set_subtitle_text_snapshot_callback_if_available(
    libvlc_media_player_t *player,
    swiftvlc_subtitle_text_snapshot_cb callback,
    void *opaque) {
#if defined(__APPLE__)
    if (swiftvlc_libvlc_pip_extensions_version() < 10) {
        return false;
    }
    return swiftvlc_libvlc_media_player_set_subtitle_text_snapshot_callback(
        player, callback, opaque);
#else
    (void)player;
    (void)callback;
    (void)opaque;
    return false;
#endif
}

bool swiftvlc_subtitle_text_snapshot_callback_available(void) {
#if defined(__APPLE__)
    return swiftvlc_libvlc_pip_extensions_version() >= 10;
#else
    return false;
#endif
}
"""


class PiPExtensionVersionTests(unittest.TestCase):
    def assert_rejected(self, sources: Dict[str, str], **kwargs: object) -> None:
        with self.assertRaises(VERSION.ExtensionVersionError):
            VERSION.resolve_extension_version(sources, **kwargs)

    def test_every_historical_version_boundary_resolves_exactly(self) -> None:
        for expected in range(4, 11):
            with self.subTest(version=expected):
                resolution = VERSION.resolve_extension_version(
                    make_sources(expected, leases=expected >= 9),
                    expected_version=expected,
                )
                self.assertEqual(resolution.version, expected)
                self.assertEqual(
                    resolution.same_version_groups,
                    (("apple-audio-session-leases",) if expected >= 9 else ()),
                )

    def test_version_8_accepts_0032_base_and_0033_final_profiles(self) -> None:
        base = VERSION.resolve_extension_version(
            make_sources(8), expected_version=8
        )
        final = VERSION.resolve_extension_version(
            make_sources(8, leases=True), expected_version=8
        )
        self.assertEqual(base.same_version_groups, ())
        self.assertEqual(
            final.same_version_groups, ("apple-audio-session-leases",)
        )

    def test_version_9_retains_the_version_8_lease_refinement(self) -> None:
        self.assert_rejected(make_sources(9), expected_version=9)
        final = VERSION.resolve_extension_version(
            make_sources(9, leases=True),
            expected_version=9,
        )
        self.assertEqual(final.version, 9)
        self.assertEqual(
            final.same_version_groups, ("apple-audio-session-leases",)
        )

    def test_v9_v10_weak_compatibility_is_fail_closed(self) -> None:
        baseline = compatibility_shim()
        VERSION.validate_weak_compatibility_shim(baseline)
        mutations = {
            "strong-fallback": baseline.replace(
                "__attribute__((weak))\n", "", 1
            ),
            "successful-fallback": baseline.replace(
                "(void)playback_generation;\n    return false;",
                "(void)playback_generation;\n    return true;",
                1,
            ),
            "version-eight-wrapper": baseline.replace("< 9", "< 8", 1),
            "version-eight-availability": baseline.replace(">= 9", ">= 8", 1),
            "unguarded-native-call": baseline.replace(
                "    if (swiftvlc_libvlc_pip_extensions_version() < 9) {\n"
                "        return false;\n"
                "    }\n",
                "",
                1,
            ),
            "native-call-before-gate": baseline.replace(
                "    if (swiftvlc_libvlc_pip_extensions_version() < 9) {",
                "    swiftvlc_libvlc_media_player_set_pip_playback_identity("
                "player, native_handle_identity, playback_generation);\n"
                "    if (swiftvlc_libvlc_pip_extensions_version() < 9) {",
                1,
            ),
            "early-true-availability": baseline.replace(
                "    return swiftvlc_libvlc_pip_extensions_version() >= 9;",
                "    return true;\n"
                "    return swiftvlc_libvlc_pip_extensions_version() >= 9;",
                1,
            ),
            "strong-v10-fallback": baseline.replace(
                "__attribute__((weak))\n"
                "bool swiftvlc_libvlc_media_player_"
                "set_subtitle_text_snapshot_callback",
                "bool swiftvlc_libvlc_media_player_"
                "set_subtitle_text_snapshot_callback",
                1,
            ),
            "successful-v10-fallback": baseline.replace(
                "(void)opaque;\n"
                "    return false;\n"
                "}\n\n"
                "bool swiftvlc_media_player_"
                "set_subtitle_text_snapshot_callback_if_available",
                "(void)opaque;\n"
                "    return true;\n"
                "}\n\n"
                "bool swiftvlc_media_player_"
                "set_subtitle_text_snapshot_callback_if_available",
                1,
            ),
            "version-nine-subtitle-wrapper": baseline.replace(
                "< 10", "< 9", 1
            ),
            "version-nine-subtitle-availability": baseline.replace(
                ">= 10", ">= 9", 1
            ),
            "unguarded-subtitle-native-call": baseline.replace(
                "    if (swiftvlc_libvlc_pip_extensions_version() < 10) {\n"
                "        return false;\n"
                "    }\n",
                "",
                1,
            ),
            "subtitle-native-call-before-gate": baseline.replace(
                "    if (swiftvlc_libvlc_pip_extensions_version() < 10) {",
                "    swiftvlc_libvlc_media_player_"
                "set_subtitle_text_snapshot_callback("
                "player, callback, opaque);\n"
                "    if (swiftvlc_libvlc_pip_extensions_version() < 10) {",
                1,
            ),
            "early-true-subtitle-availability": baseline.replace(
                "    return swiftvlc_libvlc_pip_extensions_version() >= 10;",
                "    return true;\n"
                "    return swiftvlc_libvlc_pip_extensions_version() >= 10;",
                1,
            ),
        }
        for name, candidate in mutations.items():
            with self.subTest(mutation=name):
                self.assertNotEqual(candidate, baseline)
                with self.assertRaises(VERSION.ExtensionVersionError):
                    VERSION.validate_weak_compatibility_shim(candidate)

    def test_manifest_intent_can_require_the_version_8_lease_refinement(self) -> None:
        required = ("apple-audio-session-leases",)
        with self.assertRaises(VERSION.ExtensionVersionError):
            VERSION.resolve_extension_version(
                make_sources(8),
                expected_version=8,
                required_same_version_groups=required,
            )
        resolution = VERSION.resolve_extension_version(
            make_sources(8, leases=True),
            expected_version=8,
            required_same_version_groups=required,
        )
        self.assertEqual(resolution.same_version_groups, required)

    def test_comment_and_string_markers_do_not_advance_version(self) -> None:
        baseline = make_sources(4)
        complete = make_sources(10, leases=True)
        marker_index = 0
        for group in VERSION.VERSION_GROUPS[1:] + VERSION.SAME_VERSION_GROUPS:
            for current in group.markers:
                matches = marker_matches(complete, current)
                self.assertEqual(len(matches), 1, current.label)
                found = matches[0]
                token = complete[current.source_key][found.start() : found.end()]
                if current.source_key == "exports":
                    baseline["exports"] += "# " + token + "\n"
                elif marker_index % 2 == 0:
                    baseline[current.source_key] += "/* " + token + " */\n"
                else:
                    escaped = token.replace("\\", "\\\\").replace('"', '\\"')
                    baseline[current.source_key] += '"' + escaped + '";\n'
                marker_index += 1
        resolution = VERSION.resolve_extension_version(
            baseline, expected_version=4
        )
        self.assertEqual(resolution.version, 4)

    def test_v9_semantic_publications_cannot_be_detached_from_their_owner(self) -> None:
        baseline = make_sources(9, leases=True)
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
        baseline = make_sources(9, leases=True)
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
                "        vlc_player_Unlock(p_mi->player);\n"
                "        return false;",
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
        baseline = make_sources(9, leases=True)
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

    def test_every_stage_marker_is_required_exactly_once(self) -> None:
        for group in (VERSION.COMMON_GROUP,) + VERSION.VERSION_GROUPS:
            fixture_version = max(4, group.version)
            baseline = make_sources(
                fixture_version, leases=fixture_version >= 9
            )
            for current in group.markers:
                with self.subTest(
                    group=group.name, marker=current.label, mutation="missing"
                ):
                    self.assert_rejected(
                        remove_marker(baseline, current),
                        expected_version=fixture_version,
                    )
                with self.subTest(
                    group=group.name, marker=current.label, mutation="duplicate"
                ):
                    self.assert_rejected(
                        duplicate_marker(baseline, current),
                        expected_version=fixture_version,
                    )

    def test_every_lease_marker_is_required_exactly_once_when_present(self) -> None:
        baseline = make_sources(8, leases=True)
        group = VERSION.SAME_VERSION_GROUPS[0]
        for current in group.markers:
            with self.subTest(marker=current.label, mutation="missing"):
                self.assert_rejected(
                    remove_marker(baseline, current), expected_version=8
                )
            with self.subTest(marker=current.label, mutation="duplicate"):
                self.assert_rejected(
                    duplicate_marker(baseline, current), expected_version=8
                )

    def test_prototype_and_call_cannot_impersonate_any_implementation(self) -> None:
        cases = [
            (
                group,
                make_sources(group.version, leases=group.version >= 9),
                (),
            )
            for group in VERSION.VERSION_GROUPS
        ]
        cases.extend(
            (
                group,
                make_sources(group.version, leases=True),
                (group.name,),
            )
            for group in VERSION.SAME_VERSION_GROUPS
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
                            VERSION._replace_implementation_definition(
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

    def test_all_predecessor_gaps_are_rejected(self) -> None:
        baseline = make_sources(9, leases=True)
        for predecessor in VERSION.VERSION_GROUPS[:-1]:
            with self.subTest(missing=predecessor.name):
                self.assert_rejected(
                    remove_group(baseline, predecessor), expected_version=9
                )

    def test_version_body_must_be_only_the_exact_literal_return(self) -> None:
        baseline = make_sources(9, leases=True)
        invalid_bodies = {
            "stale-eight": "{ return 8; }",
            "unknown-ten": "{ return 10; }",
            "computed": "{ return 8 + 1; }",
            "multiple": "{ if (ready) return 9; return 9; }",
            "side-effect": "{ observe_version(); return 9; }",
        }
        for name, body in invalid_bodies.items():
            with self.subTest(mutation=name):
                self.assert_rejected(
                    replace_version_body(baseline, body), expected_version=9
                )

    def test_matching_return_elsewhere_does_not_rescue_stale_version_body(self) -> None:
        candidate = replace_version_body(
            make_sources(9, leases=True), "{ return 8; }"
        )
        candidate["media_player"] += (
            "unsigned unrelated_version(void) { return 9; }\n"
        )
        self.assert_rejected(candidate, expected_version=9)

    def test_implementation_and_export_drift_is_rejected(self) -> None:
        cases = (
            (5, False, VERSION.VERSION_GROUPS[1].markers[1]),
            (6, False, VERSION.VERSION_GROUPS[2].markers[2]),
            (8, False, VERSION.VERSION_GROUPS[4].markers[5]),
            (8, True, VERSION.SAME_VERSION_GROUPS[0].markers[7]),
            (9, True, VERSION.VERSION_GROUPS[5].markers[3]),
        )
        for fixture_version, leases, current in cases:
            with self.subTest(version=fixture_version, marker=current.label):
                self.assert_rejected(
                    remove_marker(
                        make_sources(fixture_version, leases=leases), current
                    ),
                    expected_version=fixture_version,
                )

    def test_expected_version_prevents_complete_stage_downgrade(self) -> None:
        predecessor = make_sources(8, leases=True)
        self.assertEqual(
            VERSION.resolve_extension_version(predecessor).version, 8
        )
        self.assert_rejected(predecessor, expected_version=9)

    def test_native_and_vendored_public_surfaces_must_match(self) -> None:
        final = make_sources(9, leases=True)
        v8_final = make_sources(8, leases=True)
        same = VERSION.validate_vendored_headers(
            final,
            final["public_header"],
            final["events_header"],
            expected_version=9,
        )
        self.assertEqual(same.version, 9)
        self.assertEqual(
            same.same_version_groups, ("apple-audio-session-leases",)
        )

        mismatches = (
            (
                final,
                make_sources(8, leases=True)["public_header"],
                make_sources(8, leases=True)["events_header"],
                9,
                "native-v9-vendored-v8",
            ),
            (
                make_sources(8, leases=True),
                final["public_header"],
                final["events_header"],
                8,
                "native-v8-vendored-v9",
            ),
            (
                v8_final,
                make_sources(8)["public_header"],
                make_sources(8)["events_header"],
                8,
                "native-v8-final-vendored-pre-lease",
            ),
            (
                make_sources(8),
                v8_final["public_header"],
                v8_final["events_header"],
                8,
                "native-pre-lease-vendored-v8-final",
            ),
        )
        for (
            native,
            vendored_public,
            vendored_events,
            expected_version,
            name,
        ) in mismatches:
            with self.subTest(mismatch=name):
                with self.assertRaises(VERSION.ExtensionVersionError):
                    VERSION.validate_vendored_headers(
                        native,
                        vendored_public,
                        vendored_events,
                        expected_version=expected_version,
                    )


if __name__ == "__main__":
    unittest.main()
