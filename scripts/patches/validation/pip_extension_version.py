#!/usr/bin/env python3
"""Fail-closed resolver for SwiftVLC's additive libVLC extension ABI.

The extension function is shared by several otherwise independent patches.
This module is the single composition proof for versions 4 through 10: every
stage must be complete, unique, and contiguous, and the implementation must be
exactly one literal return of the resolved version.  Release callers should
also provide ``expected_version`` from the ordered patch manifest so removing
an entire final stage cannot silently downgrade the intended artifact.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys
from typing import Dict, Mapping, NamedTuple, Optional, Sequence, Tuple


class ExtensionVersionError(AssertionError):
    """The source tree does not encode one supported, complete ABI version."""


class Marker(NamedTuple):
    source_key: str
    label: str
    pattern: str


class MarkerGroup(NamedTuple):
    name: str
    version: int
    markers: Tuple[Marker, ...]


class Resolution(NamedTuple):
    version: int
    same_version_groups: Tuple[str, ...]


BASE_SOURCE_KEYS = frozenset(
    {"media_player", "public_header", "events_header", "exports"}
)
OPTIONAL_SUCCESSOR_SOURCE_KEYS = frozenset(
    {
        "drawable_header",
        "media_player_internal",
        "pip_controller",
        "pip_controller_header",
        "sample_buffer_display",
    }
)
V9_LIFECYCLE_MARKER_LABEL = "fail-closed exact PiP lifecycle preflight"


def marker(source_key: str, label: str, symbol: str) -> Marker:
    return Marker(
        source_key,
        label,
        r"\b" + re.escape(symbol) + r"\s*\(",
    )


def implementation_marker(label: str, symbol: str) -> Marker:
    """Match one ordinary C function definition, never a prototype or call.

    SwiftVLC's extension entry points use typedef names for callback parameters,
    so their declarators contain no nested parentheses. Requiring the opening
    function-body brace immediately after that declarator keeps a declaration,
    direct call, and an ``if (function(...)) {`` decoy from satisfying an
    implementation marker.
    """
    return Marker(
        "media_player",
        label,
        r"\b" + re.escape(symbol) + r"\s*\([^(){};]*\)\s*\{",
    )


COMMON_GROUP = MarkerGroup(
    "shared-version-function",
    4,
    (
        marker("public_header", "public version declaration",
               "swiftvlc_libvlc_pip_extensions_version"),
        Marker("exports", "version export",
               r"(?m)^swiftvlc_libvlc_pip_extensions_version$"),
    ),
)


VERSION_GROUPS = (
    MarkerGroup(
        "strict-frame-step",
        4,
        (
            Marker("public_header", "strict result typedef",
                   r"\btypedef\s+enum\s+"
                   r"swiftvlc_next_frame_request_result_t\b"),
            marker("public_header", "strict request declaration",
                   "swiftvlc_libvlc_media_player_request_next_frame"),
            implementation_marker(
                "strict request implementation",
                "swiftvlc_libvlc_media_player_request_next_frame"),
            Marker("exports", "strict request export",
                   r"(?m)^swiftvlc_libvlc_media_player_request_next_frame$"),
            marker("public_header", "strict cancel declaration",
                   "swiftvlc_libvlc_media_player_cancel_next_frame_request"),
            implementation_marker(
                "strict cancel implementation",
                "swiftvlc_libvlc_media_player_cancel_next_frame_request"),
            Marker("exports", "strict cancel export",
                   r"(?m)^swiftvlc_libvlc_media_player_cancel_next_frame_request$"),
            marker("public_header", "display-status setter declaration",
                   "swiftvlc_libvlc_video_set_display_status_callback"),
            implementation_marker(
                "display-status setter implementation",
                "swiftvlc_libvlc_video_set_display_status_callback"),
            Marker("exports", "display-status setter export",
                   r"(?m)^swiftvlc_libvlc_video_set_display_status_callback$"),
            marker("public_header", "atomic setter declaration",
                   "swiftvlc_libvlc_video_set_callbacks_atomic"),
            implementation_marker(
                "atomic setter implementation",
                "swiftvlc_libvlc_video_set_callbacks_atomic"),
            Marker("exports", "atomic setter export",
                   r"(?m)^swiftvlc_libvlc_video_set_callbacks_atomic$"),
        ),
    ),
    MarkerGroup(
        "sample-buffer-renderer-snapshot",
        5,
        (
            marker("public_header", "renderer snapshot declaration",
                   "swiftvlc_libvlc_media_player_get_sample_buffer_renderer_snapshot"),
            implementation_marker(
                "renderer snapshot implementation",
                "swiftvlc_libvlc_media_player_get_sample_buffer_renderer_snapshot"),
            Marker("exports", "renderer snapshot export",
                   r"(?m)^swiftvlc_libvlc_media_player_get_sample_buffer_renderer_snapshot$"),
        ),
    ),
    MarkerGroup(
        "timestamp-bearing-vmem",
        6,
        (
            marker("public_header", "vmem v2 declaration",
                   "swiftvlc_libvlc_video_set_callbacks_atomic_v2"),
            implementation_marker(
                "vmem v2 implementation",
                "swiftvlc_libvlc_video_set_callbacks_atomic_v2"),
            Marker("exports", "vmem v2 export",
                   r"(?m)^swiftvlc_libvlc_video_set_callbacks_atomic_v2$"),
        ),
    ),
    MarkerGroup(
        "effective-rate-event",
        7,
        (
            Marker("events_header", "rate event enumerator",
                   r"\blibvlc_MediaPlayerRateChanged\s*,"),
            Marker("events_header", "rate event payload",
                   r"\bmedia_player_rate_changed\s*;"),
            Marker("media_player", "rate event publication",
                   r"\.type\s*=\s*libvlc_MediaPlayerRateChanged\s*,"),
            Marker("media_player", "rate payload publication",
                   r"\.u\.media_player_rate_changed\.new_rate\s*="),
        ),
    ),
    MarkerGroup(
        "apple-audio-recovery",
        8,
        (
            Marker("public_header", "recovery snapshot version",
                   r"(?m)^#define\s+"
                   r"SWIFTVLC_APPLE_AUDIO_RECOVERY_SNAPSHOT_VERSION\s+1$"),
            Marker("public_header", "recovery snapshot typedef",
                   r"\btypedef\s+struct\s+"
                   r"swiftvlc_apple_audio_recovery_snapshot_t\b"),
            marker("public_header", "recovery snapshot declaration",
                   "swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot"),
            marker("public_header", "non-authorizing pause declaration",
                   "swiftvlc_libvlc_media_player_set_pause_without_reset_authorization"),
            implementation_marker(
                "recovery snapshot implementation",
                "swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot"),
            implementation_marker(
                "non-authorizing pause implementation",
                "swiftvlc_libvlc_media_player_set_pause_without_reset_authorization"),
            Marker("exports", "recovery snapshot export",
                   r"(?m)^swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot$"),
            Marker("exports", "non-authorizing pause export",
                   r"(?m)^swiftvlc_libvlc_media_player_set_pause_without_reset_authorization$"),
        ),
    ),
    MarkerGroup(
        "native-pip-playback-identity",
        9,
        (
            Marker(
                "public_header",
                "PiP playback identity typedef",
                r"\btypedef\s+struct\s+swiftvlc_pip_playback_identity_t\s*"
                r"\{\s*uint64_t\s+native_handle_identity\s*;\s*"
                r"uint64_t\s+playback_generation\s*;\s*\}\s*"
                r"swiftvlc_pip_playback_identity_t\s*;",
            ),
            Marker(
                "public_header",
                "PiP playback identity setter declaration",
                r"\bLIBVLC_API\s+bool\s+"
                r"swiftvlc_libvlc_media_player_set_pip_playback_identity\s*"
                r"\(\s*libvlc_media_player_t\s*\*\s*"
                r"(?:[A-Za-z_][A-Za-z0-9_]*)?\s*,\s*"
                r"uint64_t\s+native_handle_identity\s*,\s*"
                r"uint64_t\s+playback_generation\s*\)\s*;",
            ),
            implementation_marker(
                "PiP playback identity setter implementation",
                "swiftvlc_libvlc_media_player_set_pip_playback_identity",
            ),
            Marker(
                "exports",
                "PiP playback identity setter export",
                r"(?m)^swiftvlc_libvlc_media_player_set_pip_playback_identity$",
            ),
            Marker(
                "drawable_header",
                "exact preserved PiP controller take declaration",
                r"-\s*\(\s*id\s*<\s*VLCPictureInPictureWindowControlling\s*>"
                r"\s*\)\s*"
                r"takePreservedPictureInPictureWindowControllerForNativeHandle"
                r"\s*:\s*\(\s*uint64_t\s*\)\s*nativeHandle\s+"
                r"playbackGeneration\s*:\s*\(\s*uint64_t\s*\)\s*"
                r"playbackGeneration\s+outputIdentity\s*:\s*"
                r"\(\s*uint64_t\s*\)\s*outputIdentity\s+"
                r"wasSuperseded\s*:\s*\(\s*BOOL\s*\*\s*\)\s*"
                r"wasSuperseded\s*;",
            ),
            Marker(
                "drawable_header",
                "exact preserved PiP controller publication declaration",
                r"-\s*\(\s*BOOL\s*\)\s*"
                r"preservePictureInPictureWindowController\s*:\s*"
                r"\(\s*id\s*<\s*VLCPictureInPictureWindowControlling\s*>"
                r"\s*\)\s*controller\s+fromNativeHandle\s*:\s*"
                r"\(\s*uint64_t\s*\)\s*nativeHandle\s+"
                r"playbackGeneration\s*:\s*\(\s*uint64_t\s*\)\s*"
                r"playbackGeneration\s+outputIdentity\s*:\s*"
                r"\(\s*uint64_t\s*\)\s*outputIdentity\s+"
                r"sameMediaGenerationRebuild\s*:\s*\(\s*BOOL\s*\)\s*"
                r"sameMediaGenerationRebuild\s*;",
            ),
            Marker(
                "drawable_header",
                "exact PiP controller readiness declaration",
                r"-\s*\(\s*BOOL\s*\)\s*"
                r"pictureInPictureWindowController\s*:\s*"
                r"\(\s*id\s*<\s*VLCPictureInPictureWindowControlling\s*>\s*\)"
                r"\s*controller\s+didBecomeReadyForNativeHandle\s*:\s*"
                r"\(\s*uint64_t\s*\)\s*nativeHandle\s+"
                r"playbackGeneration\s*:\s*\(\s*uint64_t\s*\)\s*"
                r"playbackGeneration\s+outputIdentity\s*:\s*"
                r"\(\s*uint64_t\s*\)\s*outputIdentity\s*;",
            ),
            Marker(
                "drawable_header",
                "exact PiP controller claim declaration",
                r"-\s*\(\s*BOOL\s*\)\s*"
                r"pictureInPictureWindowController\s*:\s*"
                r"\(\s*id\s*<\s*VLCPictureInPictureWindowControlling\s*>\s*\)"
                r"\s*controller\s+didClaimNativeHandle\s*:\s*"
                r"\(\s*uint64_t\s*\)\s*nativeHandle\s+"
                r"playbackGeneration\s*:\s*\(\s*uint64_t\s*\)\s*"
                r"playbackGeneration\s+outputIdentity\s*:\s*"
                r"\(\s*uint64_t\s*\)\s*outputIdentity\s*;",
            ),
            Marker(
                "drawable_header",
                "unclaimed PiP controller rollback declaration",
                r"-\s*\(\s*void\s*\)\s*"
                r"pictureInPictureControllerCreationFailedForNativeHandle\s*"
                r":\s*\(\s*uint64_t\s*\)\s*nativeHandle\s+"
                r"playbackGeneration\s*:\s*\(\s*uint64_t\s*\)\s*"
                r"playbackGeneration\s+outputIdentity\s*:\s*"
                r"\(\s*uint64_t\s*\)\s*outputIdentity\s*;",
            ),
            Marker(
                "drawable_header",
                "exact PiP controller handoff cancellation declaration",
                r"-\s*\(\s*void\s*\)\s*"
                r"pictureInPictureWindowController\s*:\s*"
                r"\(\s*id\s*<\s*VLCPictureInPictureWindowControlling\s*>\s*\)"
                r"\s*controller\s+cancelHandoffForNativeHandle\s*:\s*"
                r"\(\s*uint64_t\s*\)\s*nativeHandle\s+"
                r"playbackGeneration\s*:\s*\(\s*uint64_t\s*\)\s*"
                r"playbackGeneration\s+outputIdentity\s*:\s*"
                r"\(\s*uint64_t\s*\)\s*outputIdentity\s*;",
            ),
            Marker(
                "drawable_header",
                "exact PiP controller handoff timeout declaration",
                r"-\s*\(\s*void\s*\)\s*"
                r"pictureInPictureWindowController\s*:\s*"
                r"\(\s*id\s*<\s*VLCPictureInPictureWindowControlling\s*>\s*\)"
                r"\s*controller\s+handoffDidTimeOutForNativeHandle\s*:\s*"
                r"\(\s*uint64_t\s*\)\s*nativeHandle\s+"
                r"playbackGeneration\s*:\s*\(\s*uint64_t\s*\)\s*"
                r"playbackGeneration\s+outputIdentity\s*:\s*"
                r"\(\s*uint64_t\s*\)\s*outputIdentity\s*;",
            ),
            Marker(
                "pip_controller",
                V9_LIFECYCLE_MARKER_LABEL,
                r"\bBOOL\s+missingExactLifecycle\s*=\s*!\s*"
                r"\[\s*drawable\s+respondsToSelector\s*:\s*@selector\s*\(\s*"
                r"takePreservedPictureInPictureWindowControllerForNativeHandle\s*:"
                r"\s*playbackGeneration\s*:\s*outputIdentity\s*:\s*"
                r"wasSuperseded\s*:\s*\)\s*\]",
            ),
        ),
    ),
    MarkerGroup(
        "subtitle-text-snapshot",
        10,
        (
            marker(
                "public_header",
                "subtitle text snapshot declaration",
                "swiftvlc_libvlc_media_player_set_subtitle_text_snapshot_callback",
            ),
            implementation_marker(
                "subtitle text snapshot implementation",
                "swiftvlc_libvlc_media_player_set_subtitle_text_snapshot_callback",
            ),
            Marker(
                "exports",
                "subtitle text snapshot export",
                r"(?m)^swiftvlc_libvlc_media_player_set_subtitle_text_snapshot_callback$",
            ),
        ),
    ),
)


# Patch 0033 extends the already-version-8 audio policy.  It is deliberately
# not a new version stage, but if any lease surface appears, every declaration,
# implementation, and export must be present exactly once.
SAME_VERSION_GROUPS = (
    MarkerGroup(
        "apple-audio-session-leases",
        8,
        (
            Marker("public_header", "lease token typedef",
                   r"\btypedef\s+uint64_t\s+"
                   r"swiftvlc_apple_audio_session_lease_t\s*;"),
            Marker("public_header", "lease result typedef",
                   r"\btypedef\s+enum\s+"
                   r"swiftvlc_apple_audio_session_lease_result_t\b"),
            marker("public_header", "lease acquire declaration",
                   "swiftvlc_libvlc_media_player_acquire_apple_audio_session_lease"),
            marker("public_header", "lease release declaration",
                   "swiftvlc_libvlc_media_player_release_apple_audio_session_lease"),
            implementation_marker(
                "lease acquire implementation",
                "swiftvlc_libvlc_media_player_acquire_apple_audio_session_lease"),
            implementation_marker(
                "lease release implementation",
                "swiftvlc_libvlc_media_player_release_apple_audio_session_lease"),
            Marker("exports", "lease acquire export",
                   r"(?m)^swiftvlc_libvlc_media_player_acquire_apple_audio_session_lease$"),
            Marker("exports", "lease release export",
                   r"(?m)^swiftvlc_libvlc_media_player_release_apple_audio_session_lease$"),
        ),
    ),
)


def strip_c_comments_and_literals(source: str) -> str:
    """Blank comments and quoted literals while preserving offsets/newlines."""
    output = list(source)
    state = "code"
    index = 0
    while index < len(source):
        current = source[index]
        following = source[index + 1] if index + 1 < len(source) else ""
        if state == "code":
            if current == "/" and following == "/":
                output[index] = output[index + 1] = " "
                index += 2
                state = "line-comment"
                continue
            if current == "/" and following == "*":
                output[index] = output[index + 1] = " "
                index += 2
                state = "block-comment"
                continue
            if current == '"':
                output[index] = " "
                index += 1
                state = "string"
                continue
            if current == "'":
                output[index] = " "
                index += 1
                state = "character"
                continue
            index += 1
            continue
        if state == "line-comment":
            if current == "\n":
                state = "code"
            else:
                output[index] = " "
            index += 1
            continue
        if state == "block-comment":
            if current == "*" and following == "/":
                output[index] = output[index + 1] = " "
                index += 2
                state = "code"
                continue
            if current != "\n":
                output[index] = " "
            index += 1
            continue
        if state in ("string", "character"):
            quote = '"' if state == "string" else "'"
            if current == "\\":
                output[index] = " "
                if index + 1 < len(source):
                    if source[index + 1] != "\n":
                        output[index + 1] = " "
                    index += 2
                else:
                    index += 1
                continue
            if current == quote:
                output[index] = " "
                index += 1
                state = "code"
                continue
            if current != "\n":
                output[index] = " "
            index += 1
            continue
    if state in ("block-comment", "string", "character"):
        raise ExtensionVersionError(
            f"unterminated C lexical construct while stripping {state}")
    return "".join(output)


def strip_c_comments_preserving_literals(source: str) -> str:
    """Blank only comments while preserving offsets and literal spelling."""
    output = list(source)
    state = "code"
    index = 0
    while index < len(source):
        current = source[index]
        following = source[index + 1] if index + 1 < len(source) else ""
        if state == "code":
            if current == "/" and following == "/":
                output[index] = output[index + 1] = " "
                index += 2
                state = "line-comment"
                continue
            if current == "/" and following == "*":
                output[index] = output[index + 1] = " "
                index += 2
                state = "block-comment"
                continue
            if current == '"':
                state = "string"
            elif current == "'":
                state = "character"
            index += 1
            continue
        if state == "line-comment":
            if current == "\n":
                state = "code"
            else:
                output[index] = " "
            index += 1
            continue
        if state == "block-comment":
            if current == "*" and following == "/":
                output[index] = output[index + 1] = " "
                index += 2
                state = "code"
                continue
            if current != "\n":
                output[index] = " "
            index += 1
            continue
        quote = '"' if state == "string" else "'"
        if current == "\\":
            index += 2
            continue
        if current == quote:
            state = "code"
        index += 1
    if state == "block-comment":
        raise ExtensionVersionError(
            "unterminated C block comment while preserving literals")
    return "".join(output)


def normalized_sources(sources: Mapping[str, str]) -> Dict[str, str]:
    required = BASE_SOURCE_KEYS
    missing = required.difference(sources)
    allowed = required.union(OPTIONAL_SUCCESSOR_SOURCE_KEYS)
    extra = set(sources).difference(allowed)
    if missing or extra:
        raise ExtensionVersionError(
            f"version source keys differ: missing={sorted(missing)} "
            f"extra={sorted(extra)}")
    cleaned = {
        "media_player": strip_c_comments_and_literals(sources["media_player"]),
        "public_header": strip_c_comments_and_literals(sources["public_header"]),
        "events_header": strip_c_comments_and_literals(sources["events_header"]),
        "exports": sources["exports"],
    }
    for source_key in OPTIONAL_SUCCESSOR_SOURCE_KEYS:
        cleaned[source_key] = strip_c_comments_and_literals(
            sources.get(source_key, "")
        )
    return cleaned


def marker_matches(source: str, current: Marker) -> Sequence[re.Match[str]]:
    return tuple(re.finditer(current.pattern, source))


def classify_group(group: MarkerGroup,
                   sources: Mapping[str, str]) -> str:
    counts = tuple(
        len(marker_matches(sources[current.source_key], current))
        for current in group.markers
    )
    if all(count == 0 for count in counts):
        return "absent"
    if all(count == 1 for count in counts):
        return "full"
    details = ", ".join(
        f"{current.label}={count}"
        for current, count in zip(group.markers, counts)
    )
    raise ExtensionVersionError(
        f"{group.name} v{group.version} marker group is partial or duplicated: "
        f"{details}")


def validate_v9_native_pip_claim_semantics(sources: Mapping[str, str]) -> None:
    """Require exact preserved/fresh claims before native controller exposure."""
    source = sources["pip_controller"]
    v9_group = next(group for group in VERSION_GROUPS if group.version == 9)
    lifecycle_marker = next(
        current for current in v9_group.markers
        if current.label == V9_LIFECYCLE_MARKER_LABEL
    )
    lifecycle_markers = marker_matches(source, lifecycle_marker)
    if len(lifecycle_markers) != 1:
        # The group classifier normally owns this diagnostic. Keep this helper
        # independently fail-closed for direct callers and future refactors.
        raise ExtensionVersionError(
            "exact PiP lifecycle preflight count is not one: "
            f"{len(lifecycle_markers)}")

    open_signature = re.compile(
        r"\bstatic\s+int\s+OpenController\s*"
        r"\(\s*pip_controller_t\s*\*\s*pipcontroller\s*\)\s*\{")
    open_body = function_body_for_signature(
        source, open_signature, "native PiP OpenController")

    def block_after(
            container: str, pattern: str, label: str
            ) -> Tuple[int, int, str]:
        matches = tuple(re.finditer(pattern, container))
        if len(matches) != 1:
            raise ExtensionVersionError(
                f"{label} branch count is not one: {len(matches)}")
        opening = container.find("{", matches[0].start(), matches[0].end())
        depth = 0
        for index in range(opening, len(container)):
            token = container[index]
            if token == "{":
                depth += 1
            elif token == "}":
                depth -= 1
                if depth == 0:
                    return matches[0].start(), index + 1, container[
                        opening + 1:index]
        raise ExtensionVersionError(f"unterminated {label} branch")

    failure_return = (
        r"\breturn\s+(?!VLC_SUCCESS\b)VLC_[A-Z0-9_]+\s*;"
    )

    def require_failure_branch(
            container: str, condition: str, label: str,
            required_patterns: Sequence[Tuple[str, str]]) -> Tuple[int, int, str]:
        start, end, body = block_after(
            container, r"if\s*\(\s*" + condition + r"\s*\)\s*\{", label)
        returns = tuple(re.finditer(failure_return, body))
        if len(returns) != 1:
            raise ExtensionVersionError(
                f"{label} must return exactly one non-success Open result")
        for required_label, required_pattern in required_patterns:
            unique_pattern(body, required_pattern, f"{label} {required_label}")
        exact_body = (
            r"\s*" + r"\s*".join(
                pattern for _, pattern in required_patterns
            ) + r"\s*" + failure_return + r"\s*"
        )
        if re.fullmatch(exact_body, body) is None:
            raise ExtensionVersionError(
                f"{label} contains state changes outside its exact rollback")
        return start, end, body

    exact_identity = unique_pattern(
        open_body,
        r"\bBOOL\s+hasExactIdentity\s*=\s*"
        r"pipcontroller\s*->\s*native_handle_identity\s*!=\s*0\s*&&\s*"
        r"pipcontroller\s*->\s*playback_generation\s*!=\s*0\s*&&\s*"
        r"pipcontroller\s*->\s*output_identity\s*!=\s*0\s*&&\s*"
        r"pipcontroller\s*->\s*output_identity\s*!=\s*"
        r"VLC_PIP_HANDOFF_TOKEN_CLAIMED\s*;",
        "exact nonzero PiP identity triple guard",
    )
    lifecycle_assignment = unique_pattern(
        open_body,
        r"\bBOOL\s+missingExactLifecycle\s*=\s*"
        r"(?P<expression>[\s\S]*?)\s*;",
        "exact PiP lifecycle selector preflight",
    )
    lifecycle_expression = lifecycle_assignment.group("expression")
    selector_patterns = (
        r"!\s*\[\s*drawable\s+respondsToSelector\s*:\s*@selector\s*\(\s*"
        r"takePreservedPictureInPictureWindowControllerForNativeHandle\s*:"
        r"\s*playbackGeneration\s*:\s*outputIdentity\s*:\s*"
        r"wasSuperseded\s*:\s*\)\s*\]",
        r"!\s*\[\s*drawable\s+respondsToSelector\s*:\s*@selector\s*\(\s*"
        r"pictureInPictureWindowController\s*:\s*didClaimNativeHandle\s*:"
        r"\s*playbackGeneration\s*:\s*outputIdentity\s*:\s*\)\s*\]",
        r"!\s*\[\s*drawable\s+respondsToSelector\s*:\s*@selector\s*\(\s*"
        r"pictureInPictureControllerCreationFailedForNativeHandle\s*:"
        r"\s*playbackGeneration\s*:\s*outputIdentity\s*:\s*\)\s*\]",
        r"!\s*\[\s*drawable\s+respondsToSelector\s*:\s*@selector\s*\(\s*"
        r"pictureInPictureWindowController\s*:\s*cancelHandoffForNativeHandle"
        r"\s*:\s*playbackGeneration\s*:\s*outputIdentity\s*:\s*\)\s*\]",
        r"!\s*\[\s*drawable\s+respondsToSelector\s*:\s*@selector\s*\(\s*"
        r"pictureInPictureWindowController\s*:\s*"
        r"didBecomeReadyForNativeHandle\s*:\s*playbackGeneration\s*:"
        r"\s*outputIdentity\s*:\s*\)\s*\]",
        r"!\s*\[\s*drawable\s+respondsToSelector\s*:\s*@selector\s*\(\s*"
        r"preservePictureInPictureWindowController\s*:\s*fromNativeHandle\s*:"
        r"\s*playbackGeneration\s*:\s*outputIdentity\s*:"
        r"\s*sameMediaGenerationRebuild\s*:\s*\)\s*\]",
        r"!\s*\[\s*drawable\s+respondsToSelector\s*:\s*@selector\s*\(\s*"
        r"pictureInPictureWindowController\s*:\s*"
        r"handoffDidTimeOutForNativeHandle\s*:\s*playbackGeneration\s*:"
        r"\s*outputIdentity\s*:\s*\)\s*\]",
    )
    selector_matches = tuple(
        unique_pattern(
            lifecycle_expression, pattern,
            f"lifecycle preflight selector {index + 1}")
        for index, pattern in enumerate(selector_patterns)
    )
    if lifecycle_expression[:selector_matches[0].start()].strip():
        raise ExtensionVersionError(
            "PiP lifecycle preflight has an expression before its first selector")
    for first, second in zip(selector_matches, selector_matches[1:]):
        if re.fullmatch(
                r"\s*\|\|\s*",
                lifecycle_expression[first.end():second.start()]) is None:
            raise ExtensionVersionError(
                "PiP lifecycle preflight selectors are not one exact OR chain")
    if lifecycle_expression[selector_matches[-1].end():].strip():
        raise ExtensionVersionError(
            "PiP lifecycle preflight has an expression after its last selector")
    if len(tuple(re.finditer(
            r"respondsToSelector\s*:\s*@selector", lifecycle_expression))) != 7:
        raise ExtensionVersionError(
            "PiP lifecycle preflight must require exactly seven selectors")
    if exact_identity.start() >= lifecycle_assignment.start():
        raise ExtensionVersionError(
            "PiP exact identity must be checked before lifecycle availability")
    lifecycle_gate = unique_pattern(
        open_body,
        r"if\s*\(\s*!\s*hasExactIdentity\s*\|\|\s*"
        r"missingExactLifecycle\s*\)\s*" + failure_return,
        "exact PiP identity and lifecycle rejection",
    )
    if lifecycle_assignment.end() >= lifecycle_gate.start():
        raise ExtensionVersionError(
            "PiP lifecycle preflight is not ordered before its rejection gate")

    take_call = unique_pattern(
        open_body,
        r"\bid\s+preserved\s*=\s*\[\s*drawable\s+"
        r"takePreservedPictureInPictureWindowControllerForNativeHandle\s*:"
        r"\s*pipcontroller\s*->\s*native_handle_identity\s+"
        r"playbackGeneration\s*:\s*pipcontroller\s*->\s*playback_generation"
        r"\s+outputIdentity\s*:\s*pipcontroller\s*->\s*output_identity\s+"
        r"wasSuperseded\s*:\s*&\s*handoffWasSuperseded\s*\]\s*;",
        "exact preserved PiP controller take",
    )
    if lifecycle_gate.end() >= take_call.start():
        raise ExtensionVersionError(
            "PiP preserved-controller lookup precedes fail-closed preflight")

    rollback_call = (
        r"\[\s*drawable\s+"
        r"pictureInPictureControllerCreationFailedForNativeHandle\s*:\s*"
        r"pipcontroller\s*->\s*native_handle_identity\s+"
        r"playbackGeneration\s*:\s*"
        r"pipcontroller\s*->\s*playback_generation\s+"
        r"outputIdentity\s*:\s*"
        r"pipcontroller\s*->\s*output_identity\s*\]\s*;"
    )
    exact_claim_call = (
        r"\[\s*drawable\s+pictureInPictureWindowController\s*:\s*sys\s+"
        r"didClaimNativeHandle\s*:\s*"
        r"pipcontroller\s*->\s*native_handle_identity\s+"
        r"playbackGeneration\s*:\s*pipcontroller\s*->\s*playback_generation"
        r"\s+outputIdentity\s*:\s*pipcontroller\s*->\s*output_identity"
        r"\s*\]"
    )
    exact_cancel_call = (
        r"\[\s*drawable\s+pictureInPictureWindowController\s*:\s*sys\s+"
        r"cancelHandoffForNativeHandle\s*:\s*"
        r"pipcontroller\s*->\s*native_handle_identity\s+"
        r"playbackGeneration\s*:\s*pipcontroller\s*->\s*playback_generation"
        r"\s+outputIdentity\s*:\s*pipcontroller\s*->\s*output_identity"
        r"\s*\]\s*;"
    )
    exact_close_call = (
        r"\[\s*sys\s+closeForNativeHandle\s*:\s*"
        r"pipcontroller\s*->\s*native_handle_identity\s+"
        r"playbackGeneration\s*:\s*pipcontroller\s*->\s*playback_generation"
        r"\s+outputIdentity\s*:\s*pipcontroller\s*->\s*output_identity"
        r"\s*\]\s*;"
    )
    rollbacks = tuple(re.finditer(rollback_call, open_body))
    if len(rollbacks) != 2:
        raise ExtensionVersionError(
            "fresh PiP controller creation must have exactly two exact-output "
            f"rollback calls, found {len(rollbacks)}")
    claims = tuple(re.finditer(exact_claim_call, open_body))
    if len(claims) != 2:
        raise ExtensionVersionError(
            "preserved and fresh paths must each claim the exact PiP identity "
            f"once, found {len(claims)} calls")
    if len(tuple(re.finditer(r"\bdidClaim\s*=(?!=)", open_body))) != 2:
        raise ExtensionVersionError(
            "PiP claim results must be initialized once in each branch and "
            "never overwritten")

    sys_declaration = unique_pattern(
        open_body,
        r"VLCPictureInPictureController\s*\*\s*sys\s*=\s*nil\s*;",
        "PiP controller transaction local",
    )
    transaction_tail = open_body[sys_declaration.end():]
    preserved_start, preserved_end, preserved_body = block_after(
        transaction_tail,
        r"if\s*\(\s*preserved\s*!=\s*nil\s*\)\s*\{",
        "preserved PiP controller transaction",
    )
    after_preserved = transaction_tail[preserved_end:]
    fresh_start, fresh_end, fresh_body = block_after(
        after_preserved,
        r"^\s*else\s*\{",
        "fresh PiP controller transaction",
    )
    if after_preserved[:fresh_start].strip():
        raise ExtensionVersionError(
            "fresh PiP transaction is detached from the preserved branch")

    preserved_claim = unique_pattern(
        preserved_body,
        r"\bBOOL\s+didClaim\s*=\s*" + exact_claim_call + r"\s*;",
        "preserved PiP identity claim",
    )
    preserved_claim_failure = require_failure_branch(
        preserved_body, r"!\s*didClaim", "preserved claim rejection",
        (("exact cancellation", exact_cancel_call),
         ("controller close", r"\[\s*sys\s+close\s*\]\s*;")),
    )
    rebind_failure = require_failure_branch(
        preserved_body,
        r"!\s*\[\s*sys\s+rebindToPipController\s*:\s*pipcontroller\s*\]",
        "preserved controller rebind rejection",
        (("exact cancellation", exact_cancel_call),
         ("controller close", r"\[\s*sys\s+close\s*\]\s*;")),
    )
    if not (
            preserved_claim.start() < preserved_claim_failure[0]
            < rebind_failure[0]):
        raise ExtensionVersionError(
            "preserved controller must be claimed before rebind and both "
            "rejections must precede fresh/publication state")
    if (re.fullmatch(
            r"\s*sys\s*=\s*preserved\s*;\s*",
            preserved_body[:preserved_claim.start()]) is None
            or preserved_body[
                preserved_claim.end():preserved_claim_failure[0]].strip()
            or preserved_body[
                preserved_claim_failure[1]:rebind_failure[0]].strip()
            or preserved_body[rebind_failure[1]:].strip()):
        raise ExtensionVersionError(
            "preserved PiP claim/rebind transaction contains an unbound state "
            "change")

    construction = unique_pattern(
        fresh_body,
        r"\bsys\s*=\s*\[\[\s*VLCPictureInPictureController\s+alloc\s*\]"
        r"\s*initWithPipController\s*:\s*pipcontroller\s*\]\s*;",
        "fresh PiP controller construction",
    )
    init_failure = require_failure_branch(
        fresh_body, r"sys\s*==\s*nil", "fresh init failure",
        (("exact unclaimed rollback", rollback_call),),
    )
    fresh_claim = unique_pattern(
        fresh_body,
        r"\bBOOL\s+didClaim\s*=\s*" + exact_claim_call + r"\s*;",
        "fresh PiP identity claim",
    )
    fresh_claim_failure = require_failure_branch(
        fresh_body, r"!\s*didClaim", "fresh claim rejection",
        (("exact unclaimed rollback", rollback_call),
         ("exact controller close", exact_close_call)),
    )
    if not (
            construction.start() < init_failure[0] < fresh_claim.start()
            < fresh_claim_failure[0]):
        raise ExtensionVersionError(
            "fresh controller construction, init rollback, claim, and claim "
            "rollback are not transactionally ordered")
    if (fresh_body[:construction.start()].strip()
            or fresh_body[construction.end():init_failure[0]].strip()
            or fresh_body[init_failure[1]:fresh_claim.start()].strip()
            or fresh_body[
                fresh_claim.end():fresh_claim_failure[0]].strip()
            or fresh_body[fresh_claim_failure[1]:].strip()):
        raise ExtensionVersionError(
            "fresh PiP construction/claim transaction contains an unbound "
            "state change")

    publication = unique_pattern(
        open_body,
        r"pipcontroller\s*->\s*p_sys\s*=\s*"
        r"\(\s*__bridge_retained\s+void\s*\*\s*\)\s*sys\s*;",
        "claimed PiP controller publication",
    )
    timeout_tail = after_preserved[fresh_end:]
    timeout_start, timeout_end, _ = require_failure_branch(
        timeout_tail,
        r"!\s*\[\s*sys\s+startPreparationTimeoutForNativeHandle\s*:\s*"
        r"pipcontroller\s*->\s*native_handle_identity\s+"
        r"playbackGeneration\s*:\s*pipcontroller\s*->\s*playback_generation"
        r"\s+outputIdentity\s*:\s*pipcontroller\s*->\s*output_identity\s*\]",
        "claimed controller timeout arming rejection",
        (("exact cancellation", exact_cancel_call),
         ("exact controller close", exact_close_call)),
    )
    timeout_global_end = (
        sys_declaration.end() + preserved_end + fresh_end + timeout_end
    )
    # The offset above includes slices with different origins. Derive the
    # authoritative end directly from the exact timeout branch text instead.
    timeout_branch = timeout_tail[timeout_start:timeout_end]
    timeout_in_open = open_body.find(timeout_branch, sys_declaration.end())
    if timeout_in_open < 0:
        raise ExtensionVersionError(
            "cannot bind timeout arming rejection to OpenController")
    timeout_global_end = timeout_in_open + len(timeout_branch)
    if timeout_global_end >= publication.start():
        raise ExtensionVersionError(
            "PiP controller is published before timeout arming succeeds")
    if open_body[timeout_global_end:publication.start()].strip():
        raise ExtensionVersionError(
            "PiP controller state changes between timeout arming and publication")

    if len(tuple(re.finditer(r"\bsys\s*=(?!=)", open_body))) != 3:
        raise ExtensionVersionError(
            "PiP controller transaction local has an unexpected reassignment")
    for local, expected in (
            ("hasExactIdentity", 1), ("missingExactLifecycle", 1),
            ("handoffWasSuperseded", 1), ("preserved", 1)):
        assignments = len(tuple(re.finditer(
            rf"\b{local}\s*=(?!=)", open_body)))
        if assignments != expected:
            raise ExtensionVersionError(
                f"PiP OpenController mutates {local}: assignments={assignments}")
    if re.search(
            r"\b(?:sys|didClaim|hasExactIdentity|missingExactLifecycle|"
            r"handoffWasSuperseded|preserved)\s*"
            r"(?:\+\+|--|[+\-*/%&|^]=)", open_body):
        raise ExtensionVersionError(
            "PiP OpenController transaction locals use a noncanonical mutation")
    if re.search(r"\bdispatch_(?:async|sync|after)\b|\bprepare\s*:",
                 open_body[:publication.start()]):
        raise ExtensionVersionError(
            "PiP identity claim must remain synchronous and precede preparation")
    success = unique_pattern(
        open_body, r"\breturn\s+VLC_SUCCESS\s*;",
        "successful PiP OpenController return",
    )
    if publication.end() >= success.start():
        raise ExtensionVersionError(
            "PiP OpenController success precedes claimed controller publication")


def version_function_body(media_player: str) -> Tuple[int, int, str]:
    signature = re.compile(
        r"\bunsigned\s+swiftvlc_libvlc_pip_extensions_version\s*"
        r"\(\s*void\s*\)\s*\{")
    matches = tuple(signature.finditer(media_player))
    if len(matches) != 1:
        raise ExtensionVersionError(
            "shared extension version definition count is not one: "
            f"{len(matches)}")
    opening = media_player.find("{", matches[0].start(), matches[0].end())
    depth = 0
    for index in range(opening, len(media_player)):
        current = media_player[index]
        if current == "{":
            depth += 1
        elif current == "}":
            depth -= 1
            if depth == 0:
                return opening, index + 1, media_player[opening:index + 1]
    raise ExtensionVersionError("unterminated shared extension version body")


def function_body_for_signature(
        source: str, signature: re.Pattern[str], label: str) -> str:
    """Return the unique function body beginning at an exact signature."""
    matches = tuple(signature.finditer(source))
    if len(matches) != 1:
        raise ExtensionVersionError(
            f"{label} definition count is not one: {len(matches)}")
    opening = source.find("{", matches[0].start(), matches[0].end())
    depth = 0
    for index in range(opening, len(source)):
        current = source[index]
        if current == "{":
            depth += 1
        elif current == "}":
            depth -= 1
            if depth == 0:
                return source[opening:index + 1]
    raise ExtensionVersionError(f"unterminated {label} definition")


def unique_pattern(
        source: str, pattern: str, label: str) -> re.Match[str]:
    """Return one required semantic pattern from already-cleaned source."""
    matches = tuple(re.finditer(pattern, source))
    if len(matches) != 1:
        raise ExtensionVersionError(
            f"{label} count is not one: {len(matches)}")
    return matches[0]


def require_ordered_patterns(
        source: str, patterns: Sequence[Tuple[str, str]], label: str
        ) -> Tuple[re.Match[str], ...]:
    """Require unique semantic statements in one fail-closed order."""
    matches = tuple(
        unique_pattern(source, pattern, f"{label} {name}")
        for name, pattern in patterns
    )
    if any(first.start() >= second.start()
           for first, second in zip(matches, matches[1:])):
        raise ExtensionVersionError(
            f"{label} semantic statements are out of order")
    return matches


def validate_v9_native_pip_identity_semantics(
        sources: Mapping[str, str], raw_sources: Mapping[str, str]) -> None:
    """Prove v9 identity publication is immutable and copied before mapping."""
    media_player = sources["media_player"]
    setter_signature = re.compile(
        r"\bbool\s+"
        r"swiftvlc_libvlc_media_player_set_pip_playback_identity\s*"
        r"\(\s*libvlc_media_player_t\s*\*\s*p_mi\s*,\s*"
        r"uint64_t\s+native_handle_identity\s*,\s*"
        r"uint64_t\s+playback_generation\s*\)\s*\{")
    setter = function_body_for_signature(
        media_player, setter_signature, "native PiP identity setter")
    setter_start = media_player.find(setter)
    raw_media_player = strip_c_comments_preserving_literals(
        raw_sources["media_player"])
    raw_setter = raw_media_player[setter_start:setter_start + len(setter)]
    identity_list = r"p_mi\s*->\s*(?:p_)?pip_playback_identities"
    handle_field = r"p_mi\s*->\s*pip_native_handle_identity"
    locked_exit = (
        r"vlc_player_Unlock\s*\(\s*p_mi\s*->\s*player\s*\)\s*;"
    )
    setter_steps = require_ordered_patterns(
        setter,
        (
            (
                "invalid-input rejection",
                r"if\s*\(\s*p_mi\s*==\s*NULL\s*\|\|\s*"
                r"native_handle_identity\s*==\s*0(?:\s*\|\|\s*"
                r"playback_generation\s*==\s*0)?\s*\)\s*"
                r"return\s+false\s*;",
            ),
            ("player lock", r"vlc_player_Lock\s*\(\s*p_mi\s*->\s*player\s*\)\s*;"),
            (
                "write-once native-handle guard",
                r"if\s*\(\s*" + handle_field + r"\s*!=\s*0\s*&&\s*"
                + handle_field + r"\s*!=\s*native_handle_identity\s*\)\s*"
                r"\{\s*" + locked_exit + r"\s*return\s+false\s*;\s*\}",
            ),
            (
                "immutable-list snapshot",
                r"struct\s+swiftvlc_pip_playback_identity_node\s*\*\s*"
                r"current\s*=\s*" + identity_list + r"\s*;",
            ),
            (
                "idempotent exact-pair acceptance",
                r"if\s*\(\s*current\s*!=\s*NULL\s*&&\s*"
                r"current\s*->\s*identity\s*\.\s*native_handle_identity\s*"
                r"==\s*native_handle_identity\s*&&\s*"
                r"current\s*->\s*identity\s*\.\s*playback_generation\s*"
                r"==\s*playback_generation\s*\)\s*"
                r"\{\s*" + locked_exit + r"\s*return\s+true\s*;\s*\}",
            ),
            (
                "generation-regression rejection",
                r"if\s*\(\s*current\s*!=\s*NULL\s*&&\s*"
                r"playback_generation\s*<\s*current\s*->\s*identity\s*\.\s*"
                r"playback_generation\s*\)\s*"
                r"\{\s*" + locked_exit + r"\s*return\s+false\s*;\s*\}",
            ),
            (
                "immutable-node allocation",
                r"struct\s+swiftvlc_pip_playback_identity_node\s*\*\s*"
                r"node\s*=\s*malloc\s*\(\s*sizeof\s*\(\s*\*\s*node\s*\)"
                r"\s*\)\s*;",
            ),
            (
                "allocation failure rejection",
                r"if\s*\(\s*node\s*==\s*NULL\s*\)\s*"
                r"\{\s*" + locked_exit + r"\s*return\s+false\s*;\s*\}",
            ),
            (
                "complete immutable identity initialization",
                r"node\s*->\s*identity\s*=\s*"
                r"\(\s*swiftvlc_pip_playback_identity_t\s*\)\s*\{\s*"
                r"\.\s*native_handle_identity\s*=\s*native_handle_identity\s*,"
                r"\s*\.\s*playback_generation\s*=\s*playback_generation\s*,?"
                r"\s*\}\s*;",
            ),
            (
                "write-once handle publication",
                handle_field + r"\s*=\s*native_handle_identity\s*;",
            ),
            ("immutable-list link", r"node\s*->\s*next\s*=\s*current\s*;"),
            ("immutable-list head publication", identity_list + r"\s*=\s*node\s*;"),
            (
                "inherited address publication",
                r"var_SetAddress\s*\(\s*p_mi\s*,\s*,\s*"
                r"&\s*node\s*->\s*identity\s*\)\s*;",
            ),
            (
                "successful unlock",
                r"vlc_player_Unlock\s*\(\s*p_mi\s*->\s*player\s*\)\s*;"
                r"\s*return\s+true\s*;\s*\}\s*$",
            ),
        ),
        "native PiP identity setter",
    )
    if setter_steps[0].start() > setter_steps[1].start():
        raise ExtensionVersionError(
            "native PiP identity setter dereferences before input validation")
    exact_address_publication = unique_pattern(
        raw_setter,
        r"var_SetAddress\s*\(\s*p_mi\s*,\s*"
        r"\"swiftvlc-pip-playback-identity\"\s*,\s*"
        r"&\s*node\s*->\s*identity\s*\)\s*;",
        "exact inherited PiP identity address publication",
    )
    if len(tuple(re.finditer(
            r"var_SetAddress\s*\(\s*[A-Za-z_][A-Za-z0-9_]*\s*,\s*"
            r"\"swiftvlc-pip-playback-identity\"\s*,",
            raw_media_player))) != 1:
        raise ExtensionVersionError(
            "inherited PiP identity address must be published exactly once by "
            "the transactional setter")
    if len(tuple(re.finditer(
            r"\"swiftvlc-pip-playback-identity\"",
            raw_media_player))) != 2:
        raise ExtensionVersionError(
            "the player-lifetime PiP identity variable may only be created "
            "once and published once")
    if exact_address_publication.start() != setter_steps[-2].start():
        raise ExtensionVersionError(
            "exact PiP identity variable name is not attached to the "
            "transactional address publication")

    setter_assignment_contracts = (
        (r"\bnative_handle_identity\s*=(?!=)", 1, "native-handle input"),
        (r"\bplayback_generation\s*=(?!=)", 1, "playback-generation input"),
        (r"\bcurrent\s*=(?!=)", 1, "immutable-list snapshot local"),
        (r"\bnode\s*=(?!=)", 1, "immutable-node allocation local"),
        (r"node\s*->\s*next\s*=(?!=)", 1, "immutable predecessor link"),
    )
    for pattern, expected, label in setter_assignment_contracts:
        count = len(tuple(re.finditer(pattern, setter)))
        if count != expected:
            raise ExtensionVersionError(
                f"native PiP identity setter mutates {label}: "
                f"assignments={count}")
    if re.search(
            r"\b(?:native_handle_identity|playback_generation|current|node)\s*"
            r"(?:\+\+|--|[+\-*/%&|^]=)", setter):
        raise ExtensionVersionError(
            "native PiP identity setter mutates transactional inputs or locals")

    unique_pattern(
        media_player,
        r"struct\s+swiftvlc_pip_playback_identity_node\s*\{\s*"
        r"swiftvlc_pip_playback_identity_t\s+identity\s*;\s*"
        r"struct\s+swiftvlc_pip_playback_identity_node\s*\*\s*next\s*;\s*"
        r"\}\s*;",
        "immutable PiP identity node type",
    )
    handle_assignments = tuple(re.finditer(
        r"(?:mp|p_mi)\s*->\s*pip_native_handle_identity\s*=(?!=)",
        media_player,
    ))
    if len(handle_assignments) != 2:
        raise ExtensionVersionError(
            "native PiP handle identity is not lifetime-write-once: "
            f"assignments={len(handle_assignments)}")
    list_assignments = tuple(re.finditer(
        r"(?:mp|p_mi)\s*->\s*(?:p_)?pip_playback_identities\s*=(?!=)",
        media_player,
    ))
    if len(list_assignments) != 2:
        raise ExtensionVersionError(
            "immutable PiP identity list has an unexpected mutation: "
            f"assignments={len(list_assignments)}")
    if re.search(
            r"(?:mp|p_mi)\s*->\s*(?:pip_native_handle_identity|"
            r"(?:p_)?pip_playback_identities)\s*"
            r"(?:\+\+|--|[+\-*/%&|^]=)", media_player):
        raise ExtensionVersionError(
            "media-player PiP identity lifetime fields use a noncanonical "
            "mutation")
    identity_mutations = tuple(re.finditer(
        r"(?:node|current|identity)\s*->\s*identity"
        r"(?:\s*\.\s*[A-Za-z_][A-Za-z0-9_]*)?\s*=(?!=)",
        media_player,
    ))
    if len(identity_mutations) != 1:
        raise ExtensionVersionError(
            "published PiP identity nodes are not immutable: "
            f"writes={len(identity_mutations)}")
    if re.search(
            r"(?:node|current|identity)\s*->\s*(?:next|identity(?:\s*\.\s*"
            r"[A-Za-z_][A-Za-z0-9_]*)?)\s*"
            r"(?:\+\+|--|[+\-*/%&|^]=)", media_player):
        raise ExtensionVersionError(
            "retained PiP identity nodes use a noncanonical mutation")
    identity_frees = tuple(re.finditer(
        r"\bfree\s*\(\s*(?:node|current|identity)\s*\)\s*;",
        media_player,
    ))
    if len(identity_frees) != 1:
        raise ExtensionVersionError(
            "PiP identity storage has an unexpected lifetime endpoint: "
            f"frees={len(identity_frees)}")
    unique_pattern(
        sources["media_player_internal"],
        r"struct\s+swiftvlc_pip_playback_identity_node\s*\*\s*"
        r"(?:p_)?pip_playback_identities\s*;\s*"
        r"uint64_t\s+pip_native_handle_identity\s*;",
        "media-player PiP identity lifetime fields",
    )
    constructor_signature = re.compile(
        r"\blibvlc_media_player_t\s*\*\s*libvlc_media_player_new\s*"
        r"\(\s*libvlc_instance_t\s*\*\s*instance\s*\)\s*\{")
    constructor = function_body_for_signature(
        media_player, constructor_signature, "media-player constructor")
    constructor_start = media_player.find(constructor)
    raw_constructor = raw_media_player[
        constructor_start:constructor_start + len(constructor)]
    setup_steps = require_ordered_patterns(
        constructor,
        (
            (
                "empty identity list initialization",
                r"mp\s*->\s*(?:p_)?pip_playback_identities\s*=\s*NULL\s*;",
            ),
            (
                "empty handle initialization",
                r"mp\s*->\s*pip_native_handle_identity\s*=\s*0\s*;",
            ),
        ),
        "media-player PiP identity setup",
    )
    identity_variable_creation = unique_pattern(
        raw_constructor,
        r"var_Create\s*\(\s*mp\s*,\s*"
        r"\"swiftvlc-pip-playback-identity\"\s*,\s*"
        r"VLC_VAR_ADDRESS\s*\)\s*;",
        "exact inherited PiP identity variable creation",
    )
    if setup_steps[-1].start() >= identity_variable_creation.start():
        raise ExtensionVersionError(
            "inherited PiP identity variable is created before lifetime fields "
            "are initialized")
    if re.match(
            r"var_Create\s*\(\s*mp\s*,\s*,\s*VLC_VAR_ADDRESS\s*\)\s*;",
            constructor[identity_variable_creation.start():]) is None:
        raise ExtensionVersionError(
            "exact inherited PiP identity variable name is not attached to a "
            "real address-variable creation")
    for label, position in (
            ("identity list initialization", setup_steps[0].start()),
            ("native-handle initialization", setup_steps[1].start()),
            ("identity variable creation", identity_variable_creation.start())):
        depth = (
            constructor[:position].count("{")
            - constructor[:position].count("}")
        )
        if depth != 1:
            raise ExtensionVersionError(
                f"media-player {label} is not in the constructor's top-level "
                "successful initialization path")
    destroy_signature = re.compile(
        r"\bstatic\s+void\s+libvlc_media_player_destroy\s*"
        r"\(\s*libvlc_media_player_t\s*\*\s*p_mi\s*\)\s*\{")
    destroy = function_body_for_signature(
        media_player, destroy_signature, "media-player destroy")
    require_ordered_patterns(
        destroy,
        (
            (
                "output join",
                r"vlc_player_Delete\s*\(\s*p_mi\s*->\s*player\s*\)\s*;",
            ),
            (
                "retained-list acquisition",
                r"struct\s+swiftvlc_pip_playback_identity_node\s*\*\s*"
                r"identity\s*=\s*p_mi\s*->\s*(?:p_)?"
                r"pip_playback_identities\s*;",
            ),
            (
                "retained-node destruction",
                r"while\s*\(\s*identity\s*!=\s*NULL\s*\)\s*\{\s*"
                r"struct\s+swiftvlc_pip_playback_identity_node\s*\*\s*"
                r"next\s*=\s*identity\s*->\s*next\s*;\s*"
                r"free\s*\(\s*identity\s*\)\s*;\s*"
                r"identity\s*=\s*next\s*;\s*\}",
            ),
            (
                "media-player object destruction",
                r"vlc_object_delete\s*\(\s*p_mi\s*\)\s*;",
            ),
        ),
        "media-player PiP identity destruction",
    )

    unique_pattern(
        sources["pip_controller_header"],
        r"typedef\s+struct\s+swiftvlc_pip_inherited_identity_t\s*\{\s*"
        r"uint64_t\s+native_handle_identity\s*;\s*"
        r"uint64_t\s+playback_generation\s*;\s*"
        r"\}\s*swiftvlc_pip_inherited_identity_t\s*;",
        "private inherited PiP identity copy layout",
    )
    unique_pattern(
        sources["pip_controller_header"],
        r"void\s*\*\s*drawable\s*;\s*"
        r"uint64_t\s+native_handle_identity\s*;\s*"
        r"uint64_t\s+playback_generation\s*;\s*"
        r"uint64_t\s+output_identity\s*;",
        "private PiP controller immutable snapshot fields",
    )
    sample_display = sources["sample_buffer_display"]
    unique_pattern(
        sample_display,
        r"static\s+atomic_uint_fast64_t\s+pipOutputIdentitySource\s*=\s*"
        r"ATOMIC_VAR_INIT\s*\(\s*0\s*\)\s*;",
        "process-wide PiP output identity source",
    )
    allocator_signature = re.compile(
        r"\bstatic\s+uint64_t\s+NextPipOutputIdentity\s*"
        r"\(\s*void\s*\)\s*\{")
    allocator = function_body_for_signature(
        sample_display, allocator_signature, "PiP output identity allocator")
    allocator_contract = (
        r"\{\s*"
        r"uint_fast64_t\s+current\s*=\s*atomic_load_explicit\s*\(\s*"
        r"&\s*pipOutputIdentitySource\s*,\s*memory_order_relaxed\s*\)\s*;\s*"
        r"for\s*\(\s*;\s*;\s*\)\s*\{\s*"
        r"if\s*\(\s*current\s*>=\s*UINT64_MAX\s*-\s*1\s*\)\s*\{\s*"
        r"if\s*\(\s*current\s*==\s*UINT64_MAX\s*-\s*1\s*\)\s*"
        r"atomic_compare_exchange_strong_explicit\s*\(\s*"
        r"&\s*pipOutputIdentitySource\s*,\s*&\s*current\s*,\s*UINT64_MAX\s*,"
        r"\s*memory_order_relaxed\s*,\s*memory_order_relaxed\s*\)\s*;\s*"
        r"return\s+0\s*;\s*\}\s*"
        r"uint_fast64_t\s+next\s*=\s*current\s*\+\s*1\s*;\s*"
        r"if\s*\(\s*atomic_compare_exchange_weak_explicit\s*\(\s*"
        r"&\s*pipOutputIdentitySource\s*,\s*&\s*current\s*,\s*next\s*,"
        r"\s*memory_order_relaxed\s*,\s*memory_order_relaxed\s*\)\s*\)\s*"
        r"return\s+next\s*;\s*\}\s*\}"
    )
    if re.fullmatch(allocator_contract, allocator) is None:
        raise ExtensionVersionError(
            "PiP output identity allocator must atomically saturate without "
            "wrapping and publish an identity only after its unique CAS")
    if len(tuple(re.finditer(
            r"\bpipOutputIdentitySource\b", sample_display))) != 4:
        raise ExtensionVersionError(
            "process-wide PiP output identity source may only be initialized, "
            "loaded, saturated, and advanced by its allocator")
    create_signature = re.compile(
        r"\bstatic\s+pip_controller_t\s*\*\s*CreatePipController\s*"
        r"\(\s*vout_display_t\s*\*\s*vd\s*,\s*void\s*\*\s*"
        r"cbs_opaque\s*\)\s*\{")
    create = function_body_for_signature(
        sample_display, create_signature, "PiP controller creation")
    create_start = sample_display.find(create)
    raw_sample_display = strip_c_comments_preserving_literals(
        raw_sources["sample_buffer_display"])
    raw_create = raw_sample_display[create_start:create_start + len(create)]
    create_steps = require_ordered_patterns(
        create,
        (
            (
                "retained drawable snapshot",
                r"id\s+drawable\s*=\s*\(\s*__bridge\s+id\s*\)\s*"
                r"var_InheritAddress\s*\(\s*vd\s*,\s*\)\s*;\s*"
                r"pip_controller\s*->\s*drawable\s*=\s*"
                r"\(\s*__bridge_retained\s+void\s*\*\s*\)\s*drawable\s*;",
            ),
            (
                "identity address snapshot",
                r"const\s+void\s*\*\s*identity\s*=\s*"
                r"var_InheritAddress\s*\(\s*vd\s*,\s*\)\s*;",
            ),
            (
                "identity value copy",
                r"memcpy\s*\(\s*&\s*snapshot\s*,\s*identity\s*,\s*"
                r"sizeof\s*\(\s*snapshot\s*\)\s*\)\s*;",
            ),
            (
                "native-handle snapshot publication",
                r"pip_controller\s*->\s*native_handle_identity\s*=\s*"
                r"snapshot\s*\.\s*native_handle_identity\s*;",
            ),
            (
                "playback-generation snapshot publication",
                r"pip_controller\s*->\s*playback_generation\s*=\s*"
                r"snapshot\s*\.\s*playback_generation\s*;",
            ),
            (
                "fresh output identity allocation",
                r"pip_controller\s*->\s*output_identity\s*=\s*"
                r"NextPipOutputIdentity\s*\(\s*\)\s*;",
            ),
            (
                "zero output rejection",
                r"if\s*\(\s*pip_controller\s*->\s*output_identity\s*==\s*0"
                r"\s*\)\s*\{\s*"
                r"CFBridgingRelease\s*\(\s*pip_controller\s*->\s*drawable\s*\)"
                r"\s*;\s*vlc_object_delete\s*\(\s*pip_controller\s*\)\s*;"
                r"\s*return\s+NULL\s*;\s*\}",
            ),
            (
                "module mapping",
                r"vlc_module_map\s*\(\s*vd\s*->\s*obj\s*\.\s*logger\s*,",
            ),
        ),
        "PiP controller immutable creation snapshot",
    )
    unique_pattern(
        create,
        r"if\s*\(\s*identity\s*!=\s*NULL\s*\)\s*\{\s*"
        r"swiftvlc_pip_inherited_identity_t\s+snapshot\s*;\s*"
        r"memcpy\s*\(\s*&\s*snapshot\s*,\s*identity\s*,\s*"
        r"sizeof\s*\(\s*snapshot\s*\)\s*\)\s*;\s*"
        r"pip_controller\s*->\s*native_handle_identity\s*=\s*"
        r"snapshot\s*\.\s*native_handle_identity\s*;\s*"
        r"pip_controller\s*->\s*playback_generation\s*=\s*"
        r"snapshot\s*\.\s*playback_generation\s*;\s*\}\s*else\s*\{\s*"
        r"pip_controller\s*->\s*native_handle_identity\s*=\s*0\s*;\s*"
        r"pip_controller\s*->\s*playback_generation\s*=\s*0\s*;\s*\}",
        "null-safe inherited PiP identity snapshot",
    )
    exact_drawable_inheritance = unique_pattern(
        raw_create,
        r"id\s+drawable\s*=\s*\(\s*__bridge\s+id\s*\)\s*"
        r"var_InheritAddress\s*\(\s*vd\s*,\s*\"drawable-nsobject\"\s*\)",
        "exact drawable inheritance",
    )
    exact_identity_inheritance = unique_pattern(
        raw_create,
        r"const\s+void\s*\*\s*identity\s*=\s*"
        r"var_InheritAddress\s*\(\s*vd\s*,\s*"
        r"\"swiftvlc-pip-playback-identity\"\s*\)",
        "exact PiP identity inheritance",
    )
    unique_pattern(
        raw_sample_display,
        r"var_InheritAddress\s*\(\s*vd\s*,\s*"
        r"\"swiftvlc-pip-playback-identity\"\s*\)",
        "single PiP identity inheritance point",
    )
    if (exact_drawable_inheritance.start() != create_steps[0].start()
            or exact_identity_inheritance.start() != create_steps[1].start()):
        raise ExtensionVersionError(
            "exact inherited variable names are not attached to the immutable "
            "PiP creation snapshot")
    if len(tuple(re.finditer(r"\bvar_InheritAddress\s*\(", create))) != 2:
        raise ExtensionVersionError(
            "PiP controller creation must inherit only drawable and identity "
            "before module mapping")
    for local in ("drawable", "identity"):
        assignments = tuple(re.finditer(
            rf"(?<![>.])\b{local}\s*=(?!=)", create))
        if len(assignments) != 1:
            raise ExtensionVersionError(
                "PiP controller creation mutates an inherited snapshot local: "
                f"local={local} assignments={len(assignments)}")
    for field in ("native_handle_identity", "playback_generation"):
        assignments = tuple(re.finditer(
            rf"pip_controller\s*->\s*{field}\s*=(?!=)", create))
        if len(assignments) != 2:
            raise ExtensionVersionError(
                "PiP inherited identity snapshot field has an unexpected "
                f"mutation: field={field} assignments={len(assignments)}")
    drawable_assignments = tuple(re.finditer(
        r"pip_controller\s*->\s*drawable\s*=(?!=)", create))
    if len(drawable_assignments) != 1:
        raise ExtensionVersionError(
            "retained PiP drawable snapshot is not assigned exactly once")
    if re.search(
            r"(?:\b(?:drawable|identity)|pip_controller\s*->\s*(?:drawable|"
            r"native_handle_identity|playback_generation|output_identity))\s*"
            r"(?:\+\+|--|[+\-*/%&|^]=)", sample_display):
        raise ExtensionVersionError(
            "PiP controller immutable identity fields use a noncanonical "
            "mutation")
    if len(tuple(re.finditer(
            r"pip_controller\s*->\s*output_identity\s*=(?!=)",
            sample_display))) != 1:
        raise ExtensionVersionError(
            "PiP output identity is not assigned exactly once at creation")
    if len(tuple(re.finditer(
            r"CFBridgingRelease\s*\(\s*pip_controller\s*->\s*drawable\s*\)"
            r"\s*;", create))) != 2:
        raise ExtensionVersionError(
            "retained PiP drawable must be released on both allocation and "
            "module-mapping failure")
    if len(tuple(re.finditer(
            r"vlc_object_delete\s*\(\s*pip_controller\s*\)\s*;",
            create))) != 2:
        raise ExtensionVersionError(
            "failed PiP controller creation must delete its object on every "
            "post-allocation failure path")
    unique_pattern(
        create,
        r"CFBridgingRelease\s*\(\s*pip_controller\s*->\s*drawable\s*\)\s*;"
        r"\s*vlc_object_delete\s*\(\s*pip_controller\s*\)\s*;\s*"
        r"return\s+NULL\s*;\s*\}\s*$",
        "PiP module-mapping failure cleanup",
    )
    if re.search(r"\bvar_InheritAddress\s*\(", sources["pip_controller"]):
        raise ExtensionVersionError(
            "PiP controller module dynamically re-inherits immutable output state")


def validate_weak_compatibility_shim(shim_source: str) -> None:
    """Prove an older archive cannot advertise or mutate v9/v10 state."""
    cleaned = strip_c_comments_and_literals(shim_source)
    pip_setter = "swiftvlc_libvlc_media_player_set_pip_playback_identity"
    weak_signature = re.compile(
        r"__attribute__\s*\(\(\s*weak\s*\)\)\s*bool\s+"
        + pip_setter
        + r"\s*\(\s*libvlc_media_player_t\s*\*\s*player\s*,\s*"
          r"uint64_t\s+native_handle_identity\s*,\s*"
          r"uint64_t\s+playback_generation\s*\)\s*\{")
    weak_body = function_body_for_signature(
        cleaned, weak_signature, "weak PiP playback identity fallback")
    if re.fullmatch(
            r"\{\s*\(\s*void\s*\)\s*player\s*;\s*"
            r"\(\s*void\s*\)\s*native_handle_identity\s*;\s*"
            r"\(\s*void\s*\)\s*playback_generation\s*;\s*"
            r"return\s+false\s*;\s*\}", weak_body) is None:
        raise ExtensionVersionError(
            "weak PiP playback identity fallback must be a side-effect-free "
            "false result")

    wrapper_signature = re.compile(
        r"\bbool\s+"
        r"swiftvlc_media_player_set_pip_playback_identity_if_available\s*"
        r"\(\s*libvlc_media_player_t\s*\*\s*player\s*,\s*"
        r"uint64_t\s+native_handle_identity\s*,\s*"
        r"uint64_t\s+playback_generation\s*\)\s*\{")
    wrapper_body = function_body_for_signature(
        cleaned, wrapper_signature, "version-gated PiP identity wrapper")
    wrapper_contract = (
        r"\{\s*#if\s+defined\s*\(\s*__APPLE__\s*\)\s*"
        r"if\s*\(\s*swiftvlc_libvlc_pip_extensions_version\s*\(\s*\)"
        r"\s*<\s*9\s*\)\s*\{\s*return\s+false\s*;\s*\}\s*"
        r"return\s+" + pip_setter + r"\s*\(\s*player\s*,\s*"
        r"native_handle_identity\s*,\s*playback_generation\s*\)\s*;\s*"
        r"#else\s*\(\s*void\s*\)\s*player\s*;\s*"
        r"\(\s*void\s*\)\s*native_handle_identity\s*;\s*"
        r"\(\s*void\s*\)\s*playback_generation\s*;\s*"
        r"return\s+false\s*;\s*#endif\s*\}"
    )
    if re.fullmatch(wrapper_contract, wrapper_body) is None:
        raise ExtensionVersionError(
            "PiP identity compatibility wrapper must gate its only native "
            "setter call on exact extension version 9 before any side effect")

    availability_signature = re.compile(
        r"\bbool\s+swiftvlc_native_pip_handoff_v9_available\s*"
        r"\(\s*void\s*\)\s*\{")
    availability_body = function_body_for_signature(
        cleaned, availability_signature, "native PiP v9 availability helper")
    availability_contract = (
        r"\{\s*#if\s+defined\s*\(\s*__APPLE__\s*\)\s*"
        r"return\s+swiftvlc_libvlc_pip_extensions_version\s*\(\s*\)"
        r"\s*>=\s*9\s*;\s*#else\s*return\s+false\s*;\s*#endif\s*\}"
    )
    if re.fullmatch(availability_contract, availability_body) is None:
        raise ExtensionVersionError(
            "native PiP availability must be exactly the fail-closed v9 check")

    subtitle_setter = (
        "swiftvlc_libvlc_media_player_set_subtitle_text_snapshot_callback"
    )
    subtitle_weak_signature = re.compile(
        r"__attribute__\s*\(\(\s*weak\s*\)\)\s*bool\s+"
        + subtitle_setter
        + r"\s*\(\s*libvlc_media_player_t\s*\*\s*player\s*,\s*"
          r"swiftvlc_subtitle_text_snapshot_cb\s+callback\s*,\s*"
          r"void\s*\*\s*opaque\s*\)\s*\{")
    subtitle_weak_body = function_body_for_signature(
        cleaned,
        subtitle_weak_signature,
        "weak subtitle text snapshot fallback",
    )
    if re.fullmatch(
            r"\{\s*\(\s*void\s*\)\s*player\s*;\s*"
            r"\(\s*void\s*\)\s*callback\s*;\s*"
            r"\(\s*void\s*\)\s*opaque\s*;\s*"
            r"return\s+false\s*;\s*\}", subtitle_weak_body) is None:
        raise ExtensionVersionError(
            "weak subtitle text snapshot fallback must be a side-effect-free "
            "false result")

    subtitle_wrapper_signature = re.compile(
        r"\bbool\s+"
        r"swiftvlc_media_player_set_subtitle_text_snapshot_callback_if_available"
        r"\s*\(\s*libvlc_media_player_t\s*\*\s*player\s*,\s*"
        r"swiftvlc_subtitle_text_snapshot_cb\s+callback\s*,\s*"
        r"void\s*\*\s*opaque\s*\)\s*\{")
    subtitle_wrapper_body = function_body_for_signature(
        cleaned,
        subtitle_wrapper_signature,
        "version-gated subtitle text snapshot wrapper",
    )
    subtitle_wrapper_contract = (
        r"\{\s*#if\s+defined\s*\(\s*__APPLE__\s*\)\s*"
        r"if\s*\(\s*swiftvlc_libvlc_pip_extensions_version\s*\(\s*\)"
        r"\s*<\s*10\s*\)\s*\{\s*return\s+false\s*;\s*\}\s*"
        r"return\s+" + subtitle_setter + r"\s*\(\s*player\s*,\s*"
        r"callback\s*,\s*opaque\s*\)\s*;\s*"
        r"#else\s*\(\s*void\s*\)\s*player\s*;\s*"
        r"\(\s*void\s*\)\s*callback\s*;\s*"
        r"\(\s*void\s*\)\s*opaque\s*;\s*"
        r"return\s+false\s*;\s*#endif\s*\}"
    )
    if re.fullmatch(
            subtitle_wrapper_contract, subtitle_wrapper_body) is None:
        raise ExtensionVersionError(
            "subtitle text snapshot compatibility wrapper must gate its only "
            "native setter call on exact extension version 10 before any "
            "side effect")

    subtitle_availability_signature = re.compile(
        r"\bbool\s+swiftvlc_subtitle_text_snapshot_callback_available\s*"
        r"\(\s*void\s*\)\s*\{")
    subtitle_availability_body = function_body_for_signature(
        cleaned,
        subtitle_availability_signature,
        "subtitle text snapshot availability helper",
    )
    subtitle_availability_contract = (
        r"\{\s*#if\s+defined\s*\(\s*__APPLE__\s*\)\s*"
        r"return\s+swiftvlc_libvlc_pip_extensions_version\s*\(\s*\)"
        r"\s*>=\s*10\s*;\s*#else\s*return\s+false\s*;\s*#endif\s*\}"
    )
    if re.fullmatch(
            subtitle_availability_contract, subtitle_availability_body) is None:
        raise ExtensionVersionError(
            "subtitle text snapshot availability must be exactly the "
            "fail-closed v10 check")


def resolve_extension_version(
        sources: Mapping[str, str],
        expected_version: Optional[int] = None,
        required_same_version_groups: Sequence[str] = ()) -> Resolution:
    if (expected_version is not None
            and (isinstance(expected_version, bool)
                 or expected_version not in range(4, 11))):
        raise ExtensionVersionError(
            f"expected version must be an integer from 4 through 10: "
            f"{expected_version!r}")
    if isinstance(required_same_version_groups, (str, bytes)):
        raise ExtensionVersionError(
            "required same-version groups must be a sequence of names")
    required_groups = tuple(required_same_version_groups)
    known_groups = {group.name for group in SAME_VERSION_GROUPS}
    if len(set(required_groups)) != len(required_groups):
        raise ExtensionVersionError(
            f"required same-version groups contain duplicates: "
            f"{required_groups!r}")
    unknown_groups = set(required_groups).difference(known_groups)
    if unknown_groups:
        raise ExtensionVersionError(
            f"unknown required same-version groups: {sorted(unknown_groups)}")

    cleaned = normalized_sources(sources)
    if classify_group(COMMON_GROUP, cleaned) != "full":
        raise ExtensionVersionError("shared extension declaration/export missing")

    resolved = 3
    missing_predecessor = False
    for group in VERSION_GROUPS:
        state = classify_group(group, cleaned)
        if state == "absent":
            missing_predecessor = True
            continue
        if missing_predecessor:
            raise ExtensionVersionError(
                f"{group.name} v{group.version} exists after a missing "
                "predecessor stage")
        resolved = group.version
    if resolved < 4:
        raise ExtensionVersionError("strict-frame-step v4 base marker group missing")
    if resolved >= 9:
        validate_v9_native_pip_identity_semantics(cleaned, sources)
        validate_v9_native_pip_claim_semantics(cleaned)

    complete_same_version = []
    for group in SAME_VERSION_GROUPS:
        state = classify_group(group, cleaned)
        if state == "full":
            if resolved < group.version:
                raise ExtensionVersionError(
                    f"{group.name} requires extension version {group.version}")
            complete_same_version.append(group.name)
    effective_required_groups = set(required_groups)
    if resolved >= 9:
        # Version 9 is a successor to the final v8 profile, not merely the
        # pre-0033 v8 base. A custom manifest cannot erase the inherited audio
        # ownership contract by omitting the caller-side flag.
        effective_required_groups.add("apple-audio-session-leases")
    missing_groups = effective_required_groups.difference(
        complete_same_version)
    if missing_groups:
        raise ExtensionVersionError(
            f"required same-version groups are absent: "
            f"{sorted(missing_groups)}")

    _, _, body = version_function_body(cleaned["media_player"])
    exact_return = re.fullmatch(
        r"\{\s*return\s+([0-9]+)\s*;\s*\}", body)
    if exact_return is None:
        raise ExtensionVersionError(
            "shared extension version body must contain only one literal return")
    returned_literal = exact_return.group(1)
    if returned_literal != str(resolved):
        raise ExtensionVersionError(
            f"shared extension version returns {returned_literal}, but complete "
            f"markers resolve to {resolved}")
    if expected_version is not None and resolved != expected_version:
        raise ExtensionVersionError(
            f"resolved extension version {resolved} does not match caller "
            f"intent {expected_version}")
    return Resolution(resolved, tuple(complete_same_version))


def _replace_match(source: str, current: Marker, replacement: str) -> str:
    cleaned = (source if current.source_key == "exports"
               else strip_c_comments_and_literals(source))
    matches = marker_matches(cleaned, current)
    if len(matches) != 1:
        raise ExtensionVersionError(
            f"cannot mutate {current.label}: count={len(matches)}")
    found = matches[0]
    return source[:found.start()] + replacement + source[found.end():]


def _replace_implementation_definition(
        source: str, current: Marker, replacement_kind: str) -> str:
    """Replace one implementation with a prototype-only or call-only decoy."""
    if current.source_key != "media_player" or "implementation" not in current.label:
        raise ExtensionVersionError(
            f"cannot replace non-implementation marker: {current.label}")
    cleaned = strip_c_comments_and_literals(source)
    matches = marker_matches(cleaned, current)
    if len(matches) != 1:
        raise ExtensionVersionError(
            f"cannot replace {current.label}: count={len(matches)}")
    found = matches[0]
    opening = cleaned.find("{", found.start(), found.end())
    if opening < 0:
        raise ExtensionVersionError(
            f"implementation marker has no opening brace: {current.label}")

    depth = 0
    closing = -1
    for index in range(opening, len(cleaned)):
        token = cleaned[index]
        if token == "{":
            depth += 1
        elif token == "}":
            depth -= 1
            if depth == 0:
                closing = index + 1
                break
    if closing < 0:
        raise ExtensionVersionError(
            f"implementation body is unterminated: {current.label}")

    declarator = source[found.start():opening].rstrip()
    function_name_match = re.match(r"[A-Za-z_][A-Za-z0-9_]*", declarator)
    if function_name_match is None:
        raise ExtensionVersionError(
            f"cannot identify implementation symbol: {current.label}")
    function_name = function_name_match.group(0)
    if replacement_kind == "prototype":
        replacement = declarator + ";"
    elif replacement_kind == "call":
        replacement = (
            "swiftvlc_removed_implementation(void)\n"
            "{\n"
            f"    {function_name}();\n"
            "}"
        )
    else:
        raise ExtensionVersionError(
            f"unknown implementation replacement: {replacement_kind}")
    return source[:found.start()] + replacement + source[closing:]


def _replace_version_body(sources: Mapping[str, str], body: str) -> Dict[str, str]:
    candidate = dict(sources)
    cleaned = strip_c_comments_and_literals(sources["media_player"])
    start, end, _ = version_function_body(cleaned)
    candidate["media_player"] = (
        sources["media_player"][:start] + body + sources["media_player"][end:]
    )
    return candidate


def _replace_pattern_once(
        source: str, pattern: str, replacement: str, label: str) -> str:
    matches = tuple(re.finditer(pattern, source))
    if len(matches) != 1:
        raise ExtensionVersionError(
            f"cannot mutate {label}: count={len(matches)}")
    found = matches[0]
    return source[:found.start()] + replacement + source[found.end():]


def run_negative_mutations(
        sources: Mapping[str, str], expected_version: int,
        required_same_version_groups: Sequence[str] = ()) -> int:
    """Prove realistic version/marker corruptions fail the shared gate."""
    baseline = resolve_extension_version(
        sources, expected_version, required_same_version_groups)
    mutation_required_groups = tuple(sorted(set(
        required_same_version_groups
    ).union(baseline.same_version_groups)))
    caught = 0

    def rejects(name: str, candidate: Mapping[str, str],
                intended: Optional[int] = expected_version) -> None:
        nonlocal caught
        try:
            resolve_extension_version(
                candidate, intended, mutation_required_groups)
        except ExtensionVersionError:
            caught += 1
            return
        raise ExtensionVersionError(
            f"negative mutation escaped extension-version gate: {name}")

    prior = baseline.version - 1
    rejects("stale-return", _replace_version_body(
        sources, f"{{ return {prior}; }}"))
    unrelated = _replace_version_body(sources, f"{{ return {prior}; }}")
    unrelated["media_player"] += (
        f"\nint unrelated_version_fixture(void) {{ return {baseline.version}; }}\n"
    )
    rejects("unrelated-return", unrelated)
    rejects("computed-return", _replace_version_body(
        sources, f"{{ return {baseline.version - 1} + 1; }}"))
    rejects("multiple-return", _replace_version_body(
        sources, f"{{ if (1) return {baseline.version}; "
                 f"return {baseline.version}; }}"))
    rejects("unknown-future-return", _replace_version_body(
        sources, f"{{ return {baseline.version + 1}; }}"))
    rejects("statement-before-return", _replace_version_body(
        sources, f"{{ int ignored = 0; return {baseline.version}; }}"))

    highest = VERSION_GROUPS[baseline.version - 4]
    for current in highest.markers:
        partial = dict(sources)
        partial[current.source_key] = _replace_match(
            partial[current.source_key], current, "SWIFTVLC_REMOVED_MARKER")
        rejects(f"partial-{highest.name}-{current.label}", partial)

        duplicate = dict(sources)
        cleaned = (duplicate[current.source_key]
                   if current.source_key == "exports"
                   else strip_c_comments_and_literals(
                       duplicate[current.source_key]))
        found = marker_matches(cleaned, current)[0]
        duplicate[current.source_key] += (
            "\n" + duplicate[current.source_key][found.start():found.end()] + "\n"
        )
        rejects(f"duplicate-{highest.name}-{current.label}", duplicate)

        if (current.source_key == "media_player"
                and "implementation" in current.label):
            for replacement_kind in ("prototype", "call"):
                decoy = dict(sources)
                decoy[current.source_key] = _replace_implementation_definition(
                    decoy[current.source_key], current, replacement_kind)
                rejects(
                    f"{replacement_kind}-only-{highest.name}-{current.label}",
                    decoy)

    for group in SAME_VERSION_GROUPS:
        if group.name not in baseline.same_version_groups:
            continue
        for current in group.markers:
            partial = dict(sources)
            partial[current.source_key] = _replace_match(
                partial[current.source_key], current,
                "SWIFTVLC_REMOVED_MARKER")
            rejects(f"partial-{group.name}-{current.label}", partial)

            duplicate = dict(sources)
            cleaned = (duplicate[current.source_key]
                       if current.source_key == "exports"
                       else strip_c_comments_and_literals(
                           duplicate[current.source_key]))
            found = marker_matches(cleaned, current)[0]
            duplicate[current.source_key] += (
                "\n" + duplicate[current.source_key][
                    found.start():found.end()
                ] + "\n"
            )
            rejects(f"duplicate-{group.name}-{current.label}", duplicate)

            if (current.source_key == "media_player"
                    and "implementation" in current.label):
                for replacement_kind in ("prototype", "call"):
                    decoy = dict(sources)
                    decoy[current.source_key] = _replace_implementation_definition(
                        decoy[current.source_key], current, replacement_kind)
                    rejects(
                        f"{replacement_kind}-only-{group.name}-{current.label}",
                        decoy)

        removed = dict(sources)
        for current in group.markers:
            removed[current.source_key] = _replace_match(
                removed[current.source_key], current,
                "SWIFTVLC_REMOVED_MARKER")
        rejects(f"removed-{group.name}", removed)

    # Removing an entire final stage and changing the return is structurally a
    # valid historical predecessor. Caller intent is what makes that a release
    # failure, so exercise the explicit expected-version boundary directly.
    downgraded = dict(sources)
    removable_groups = [highest]
    removable_groups.extend(
        group for group in SAME_VERSION_GROUPS
        if group.version == baseline.version
        and group.name in baseline.same_version_groups
    )
    for group in removable_groups:
        for current in group.markers:
            downgraded[current.source_key] = _replace_match(
                downgraded[current.source_key], current,
                "SWIFTVLC_REMOVED_MARKER")
    downgraded = _replace_version_body(
        downgraded, f"{{ return {baseline.version - 1}; }}")
    rejects("complete-stage-downgrade", downgraded)

    if baseline.version >= 6:
        gap = dict(sources)
        predecessor = VERSION_GROUPS[1]  # v5
        for current in predecessor.markers:
            gap[current.source_key] = _replace_match(
                gap[current.source_key], current, "SWIFTVLC_REMOVED_MARKER")
        rejects("missing-v5-predecessor", gap)
    if baseline.version >= 9:
        identity_semantic_mutations = (
            (
                "accept-zero-native-handle",
                "media_player",
                r"native_handle_identity\s*==\s*0",
                "native_handle_identity != 0",
            ),
            (
                "mutable-native-handle",
                "media_player",
                r"p_mi\s*->\s*pip_native_handle_identity\s*!=\s*"
                r"native_handle_identity",
                "p_mi->pip_native_handle_identity == native_handle_identity",
            ),
            (
                "unretained-identity-node",
                "media_player",
                r"p_mi\s*->\s*(?:p_)?pip_playback_identities\s*=\s*node\s*;",
                "SWIFTVLC_REMOVED_IDENTITY_RETENTION",
            ),
            (
                "publish-node-not-immutable-pair",
                "media_player",
                r"&\s*node\s*->\s*identity",
                "node",
            ),
            (
                "free-identities-before-output-join",
                "media_player",
                r"vlc_player_Delete\s*\(\s*p_mi\s*->\s*player\s*\)\s*;",
                "SWIFTVLC_REMOVED_OUTPUT_JOIN",
            ),
            (
                "wrapping-output-identity-source",
                "sample_buffer_display",
                r"current\s*>=\s*UINT64_MAX\s*-\s*1",
                "current > UINT64_MAX",
            ),
            (
                "always-exhausted-output-identity-source",
                "sample_buffer_display",
                r"current\s*>=\s*UINT64_MAX\s*-\s*1",
                "true || current >= UINT64_MAX - 1",
            ),
            (
                "unconditional-output-identity-cas",
                "sample_buffer_display",
                r"if\s*\(\s*(?=atomic_compare_exchange_weak_explicit)",
                "if (true || ",
            ),
            (
                "missing-locked-rejection-unlock",
                "media_player",
                r"if\s*\(\s*p_mi\s*->\s*pip_native_handle_identity\s*!=\s*0"
                r"\s*&&\s*p_mi\s*->\s*pip_native_handle_identity\s*!=\s*"
                r"native_handle_identity\s*\)\s*\{\s*"
                r"vlc_player_Unlock\s*\(\s*p_mi\s*->\s*player\s*\)\s*;"
                r"\s*return\s+false\s*;\s*\}",
                "if (p_mi->pip_native_handle_identity != 0 && "
                "p_mi->pip_native_handle_identity != native_handle_identity) "
                "{ return false; }",
            ),
            (
                "nonadvancing-identity-destruction",
                "media_player",
                r"identity\s*=\s*next\s*;",
                "identity = identity;",
            ),
            (
                "uncopied-inherited-identity",
                "sample_buffer_display",
                r"memcpy\s*\(\s*&\s*snapshot\s*,\s*identity\s*,\s*"
                r"sizeof\s*\(\s*snapshot\s*\)\s*\)\s*;",
                "SWIFTVLC_REMOVED_IDENTITY_COPY",
            ),
            (
                "accept-zero-output-identity",
                "sample_buffer_display",
                r"if\s*\(\s*pip_controller\s*->\s*output_identity\s*"
                r"==\s*0\s*\)",
                "if (false)",
            ),
            (
                "unconditional-inherited-identity-copy",
                "sample_buffer_display",
                r"if\s*\(\s*identity\s*!=\s*NULL\s*\)",
                "if (true)",
            ),
            (
                "overwrite-inherited-native-handle-snapshot",
                "sample_buffer_display",
                r"(?=vlc_module_map\s*\()",
                "pip_controller->native_handle_identity = 0;\n        ",
            ),
            (
                "wrong-private-inherited-identity-layout",
                "pip_controller_header",
                r"typedef\s+struct\s+swiftvlc_pip_inherited_identity_t\s*\{\s*"
                r"uint64_t\s+native_handle_identity\s*;\s*"
                r"uint64_t\s+playback_generation\s*;\s*"
                r"\}\s*swiftvlc_pip_inherited_identity_t\s*;",
                "typedef struct swiftvlc_pip_inherited_identity_t { "
                "uint32_t native_handle_identity; "
                "uint32_t playback_generation; "
                "} swiftvlc_pip_inherited_identity_t;",
            ),
            (
                "discard-inherited-identity-local",
                "sample_buffer_display",
                r"(?=if\s*\(\s*identity\s*!=\s*NULL\s*\))",
                "identity = NULL;\n    ",
            ),
            (
                "discard-retained-drawable-before-map",
                "sample_buffer_display",
                r"(?=vlc_module_map\s*\()",
                "pip_controller->drawable = NULL;\n        ",
            ),
            (
                "mutated-playback-generation-input",
                "media_player",
                r"(?=vlc_player_Lock\s*\(\s*p_mi\s*->\s*player\s*\)\s*;"
                r"\s*if\s*\(\s*p_mi\s*->\s*pip_native_handle_identity)",
                "playback_generation = 0;\n    ",
            ),
            (
                "discarded-predecessor-list",
                "media_player",
                r"(?=node\s*->\s*next\s*=\s*current\s*;)",
                "current = NULL;\n    ",
            ),
            (
                "overwritten-predecessor-link",
                "media_player",
                r"node\s*->\s*next\s*=\s*current\s*;",
                "node->next = current; node->next = NULL;",
            ),
            (
                "nulled-allocated-identity-node",
                "media_player",
                r"(?=node\s*->\s*identity\s*=)",
                "node = NULL;\n    ",
            ),
        )
        for name, source_key, pattern, replacement in identity_semantic_mutations:
            candidate = dict(sources)
            candidate[source_key] = _replace_pattern_once(
                candidate[source_key], pattern, replacement, name)
            rejects(name, candidate)
        release_pattern = (
            r"CFBridgingRelease\s*\(\s*pip_controller\s*->\s*drawable\s*\)"
            r"\s*;"
        )
        sample_display_cleaned = strip_c_comments_and_literals(
            sources["sample_buffer_display"])
        create_body = function_body_for_signature(
            sample_display_cleaned,
            re.compile(
                r"\bstatic\s+pip_controller_t\s*\*\s*CreatePipController\s*"
                r"\(\s*vout_display_t\s*\*\s*vd\s*,\s*void\s*\*\s*"
                r"cbs_opaque\s*\)\s*\{"),
            "mutation PiP controller creation",
        )
        create_offset = sample_display_cleaned.find(create_body)
        release_matches = tuple(re.finditer(release_pattern, create_body))
        if len(release_matches) != 2:
            raise ExtensionVersionError(
                "cannot mutate PiP creation failure releases: "
                f"count={len(release_matches)}")
        candidate = dict(sources)
        removed_release = release_matches[-1]
        release_start = create_offset + removed_release.start()
        release_end = create_offset + removed_release.end()
        candidate["sample_buffer_display"] = (
            candidate["sample_buffer_display"][:release_start]
            + "SWIFTVLC_REMOVED_DRAWABLE_RELEASE"
            + candidate["sample_buffer_display"][release_end:]
        )
        rejects("missing-module-failure-drawable-release", candidate)

        detached_setup = dict(sources)
        setup_statements = (
            r"mp\s*->\s*(?:p_)?pip_playback_identities\s*=\s*NULL\s*;",
            r"mp\s*->\s*pip_native_handle_identity\s*=\s*0\s*;",
            r"var_Create\s*\(\s*mp\s*,\s*"
            r"\"swiftvlc-pip-playback-identity\"\s*,\s*"
            r"VLC_VAR_ADDRESS\s*\)\s*;",
        )
        moved_setup = []
        for index, pattern in enumerate(setup_statements):
            matches = tuple(re.finditer(
                pattern, detached_setup["media_player"]))
            if len(matches) != 1:
                raise ExtensionVersionError(
                    f"cannot detach v9 constructor setup {index}: "
                    f"count={len(matches)}")
            found = matches[0]
            moved_setup.append(
                detached_setup["media_player"][found.start():found.end()])
            detached_setup["media_player"] = (
                detached_setup["media_player"][:found.start()]
                + "SWIFTVLC_MOVED_SETUP"
                + detached_setup["media_player"][found.end():]
            )
        detached_setup["media_player"] += (
            "\nstatic void dead_pip_identity_setup(libvlc_media_player_t *mp) {\n"
            + "\n".join(moved_setup)
            + "\n}\n"
        )
        rejects("detached-media-player-constructor-setup", detached_setup)
        dynamic_inherit = dict(sources)
        dynamic_inherit["pip_controller"] += (
            "\nvoid *forbidden = var_InheritAddress(pipcontroller, "
            "\"swiftvlc-pip-playback-identity\");\n"
        )
        rejects("dynamic-pip-controller-reinherit", dynamic_inherit)
        lifetime_mutations = (
            (
                "hidden-native-handle-reset",
                "media_player",
                "\nvoid forbidden(libvlc_media_player_t *p_mi) { "
                "p_mi->pip_native_handle_identity = 0; }\n",
            ),
            (
                "post-publication-identity-mutation",
                "media_player",
                "\nvoid forbidden(struct swiftvlc_pip_playback_identity_node "
                "*current) { current->identity.playback_generation = 0; }\n",
            ),
            (
                "compound-native-handle-mutation",
                "media_player",
                "\nvoid forbidden(libvlc_media_player_t *p_mi) { "
                "p_mi->pip_native_handle_identity++; }\n",
            ),
            (
                "compound-predecessor-link-mutation",
                "media_player",
                "\nvoid forbidden(struct swiftvlc_pip_playback_identity_node "
                "*node) { node->next += 1; }\n",
            ),
            (
                "duplicate-inherited-identity-publication",
                "media_player",
                "\nvoid forbidden(libvlc_media_player_t *p_mi, void *value) { "
                "var_SetAddress(p_mi, \"swiftvlc-pip-playback-identity\", "
                "value); }\n",
            ),
            (
                "destroy-player-lifetime-identity-variable",
                "media_player",
                "\nvoid forbidden(libvlc_media_player_t *p_mi) { "
                "var_Destroy(p_mi, \"swiftvlc-pip-playback-identity\"); }\n",
            ),
            (
                "second-identity-inheritance-point",
                "sample_buffer_display",
                "\nvoid *forbidden(vout_display_t *vd) { return "
                "var_InheritAddress(vd, "
                "\"swiftvlc-pip-playback-identity\"); }\n",
            ),
            (
                "reset-process-output-identity-source",
                "sample_buffer_display",
                "\nvoid forbidden(void) { atomic_store_explicit("
                "&pipOutputIdentitySource, 0, memory_order_relaxed); }\n",
            ),
        )
        for name, source_key, addition in lifetime_mutations:
            candidate = dict(sources)
            candidate[source_key] += addition
            rejects(name, candidate)

        semantic_mutations = (
            (
                "missing-fresh-controller-construction",
                r"\bsys\s*=\s*\[\[\s*VLCPictureInPictureController\s+alloc"
                r"\s*\]\s*initWithPipController\s*:\s*pipcontroller\s*\]"
                r"\s*;",
                "SWIFTVLC_REMOVED_SEMANTIC",
            ),
            (
                "missing-p-sys-publication",
                r"pipcontroller\s*->\s*p_sys\s*=\s*"
                r"\(\s*__bridge_retained\s+void\s*\*\s*\)\s*sys\s*;",
                "SWIFTVLC_REMOVED_SEMANTIC",
            ),
            (
                "missing-preserved-rebind",
                r"if\s*\(\s*!\s*\[\s*sys\s+rebindToPipController\s*:"
                r"\s*pipcontroller\s*\]\s*\)",
                "if (SWIFTVLC_REMOVED_SEMANTIC)",
            ),
            (
                "missing-timeout-arming",
                r"if\s*\(\s*!\s*\[\s*sys\s+"
                r"startPreparationTimeoutForNativeHandle\s*:",
                "if (![sys SWIFTVLC_REMOVED_SEMANTIC:",
            ),
            (
                "controller-reset-before-publication",
                r"(?=pipcontroller\s*->\s*p_sys\s*=\s*"
                r"\(\s*__bridge_retained\s+void\s*\*\s*\)\s*sys\s*;)",
                "sys = nil;\n        ",
            ),
            (
                "asynchronous-fresh-construction",
                r"(?=sys\s*=\s*\[\[\s*VLCPictureInPictureController\s+alloc)",
                "dispatch_async(queue, block);\n            ",
            ),
        )
        for name, pattern, replacement in semantic_mutations:
            candidate = dict(sources)
            candidate["pip_controller"] = _replace_pattern_once(
                candidate["pip_controller"], pattern, replacement, name)
            rejects(name, candidate)

        exact_claim_pattern = (
            r"\[\s*drawable\s+pictureInPictureWindowController\s*:\s*sys\s+"
            r"didClaimNativeHandle\s*:\s*"
            r"pipcontroller\s*->\s*native_handle_identity\s+"
            r"playbackGeneration\s*:\s*"
            r"pipcontroller\s*->\s*playback_generation\s+"
            r"outputIdentity\s*:\s*"
            r"pipcontroller\s*->\s*output_identity\s*\]"
        )
        claim_matches = tuple(re.finditer(
            exact_claim_pattern, sources["pip_controller"]))
        if len(claim_matches) != 2:
            raise ExtensionVersionError(
                "cannot mutate v9 preserved/fresh claims: "
                f"count={len(claim_matches)}")
        for index, found in enumerate(claim_matches):
            candidate = dict(sources)
            candidate["pip_controller"] = (
                candidate["pip_controller"][:found.start()]
                + "SWIFTVLC_REMOVED_CLAIM"
                + candidate["pip_controller"][found.end():]
            )
            rejects(f"missing-identity-claim-{index}", candidate)
        first_claim = claim_matches[0]
        candidate = dict(sources)
        candidate["pip_controller"] = (
            candidate["pip_controller"][:first_claim.end()]
            + ";\n        "
            + candidate["pip_controller"][first_claim.start():first_claim.end()]
            + candidate["pip_controller"][first_claim.end():]
        )
        rejects("duplicate-identity-claim", candidate)

        rejection_pattern = r"if\s*\(\s*!\s*didClaim\s*\)"
        rejection_matches = tuple(re.finditer(
            rejection_pattern, sources["pip_controller"]))
        if len(rejection_matches) != 2:
            raise ExtensionVersionError(
                "cannot mutate v9 claim rejection branches: "
                f"count={len(rejection_matches)}")
        for index, found in enumerate(rejection_matches):
            candidate = dict(sources)
            candidate["pip_controller"] = (
                candidate["pip_controller"][:found.start()]
                + "SWIFTVLC_REMOVED_REJECTION"
                + candidate["pip_controller"][found.end():]
            )
            rejects(f"missing-claim-rejection-{index}", candidate)
            candidate = dict(sources)
            candidate["pip_controller"] = (
                candidate["pip_controller"][:found.start()]
                + "didClaim = true;\n        "
                + candidate["pip_controller"][found.start():]
            )
            rejects(f"overwritten-claim-result-{index}", candidate)

        rollback_pattern = (
            r"\[\s*drawable\s+"
            r"pictureInPictureControllerCreationFailedForNativeHandle\s*:\s*"
            r"pipcontroller\s*->\s*native_handle_identity\s+"
            r"playbackGeneration\s*:\s*"
            r"pipcontroller\s*->\s*playback_generation\s+"
            r"outputIdentity\s*:\s*"
            r"pipcontroller\s*->\s*output_identity\s*\]\s*;"
        )
        rollback_matches = tuple(re.finditer(
            rollback_pattern, sources["pip_controller"]))
        if len(rollback_matches) != 2:
            raise ExtensionVersionError(
                "cannot mutate v9 rollback calls: "
                f"count={len(rollback_matches)}")
        for index, removed in enumerate(rollback_matches):
            candidate = dict(sources)
            candidate["pip_controller"] = (
                candidate["pip_controller"][:removed.start()]
                + "SWIFTVLC_REMOVED_ROLLBACK"
                + candidate["pip_controller"][removed.end():]
            )
            rejects(f"missing-fresh-rollback-{index}", candidate)
        detached_open = dict(sources)
        detached_open["pip_controller"] = detached_open[
            "pip_controller"].replace(
                "OpenController(pip_controller_t *pipcontroller)",
                "DetachedOpenController(pip_controller_t *pipcontroller)",
                1,
            )
        detached_open["pip_controller"] += (
            "\nstatic int OpenController(pip_controller_t *pipcontroller) { "
            "(void)pipcontroller; return VLC_EGENERIC; }\n"
        )
        rejects("detached-OpenController-semantics", detached_open)
    return caught


def read_source_root(root: Path) -> Dict[str, str]:
    source_paths = {
        "media_player": root / "lib/media_player.c",
        "public_header": root / "include/vlc/libvlc_media_player.h",
        "events_header": root / "include/vlc/libvlc_events.h",
        "exports": root / "lib/libvlc.sym",
    }
    missing = [str(current) for current in source_paths.values()
               if not current.is_file()]
    if missing:
        raise ExtensionVersionError(
            f"missing extension-version source inputs: {missing}")
    sources = {
        key: current.read_text(encoding="utf-8")
        for key, current in source_paths.items()
    }
    optional_source_paths = {
        "drawable_header": (
            root / "modules/video_output/apple/VLCDrawable.h"
        ),
        "media_player_internal": root / "lib/media_player_internal.h",
        "pip_controller": (
            root
            / "modules/video_output/apple/VLCPictureInPictureController.m"
        ),
        "pip_controller_header": (
            root / "modules/video_output/apple/vlc_pip_controller.h"
        ),
        "sample_buffer_display": (
            root / "modules/video_output/apple/VLCSampleBufferDisplay.m"
        ),
    }
    sources.update({
        key: (current.read_text(encoding="utf-8")
              if current.is_file() else "")
        for key, current in optional_source_paths.items()
    })
    return sources


def validate_vendored_headers(
        sources: Mapping[str, str], vendored_public_header: str,
        vendored_events_header: str,
        expected_version: int,
        required_same_version_groups: Sequence[str] = ()) -> Resolution:
    native = resolve_extension_version(
        sources, expected_version, required_same_version_groups)
    vendored_sources = dict(sources)
    vendored_sources["public_header"] = vendored_public_header
    vendored_sources["events_header"] = vendored_events_header
    vendored = resolve_extension_version(
        vendored_sources, expected_version, required_same_version_groups)
    if vendored != native:
        raise ExtensionVersionError(
            "native/vendored extension-version surface classification differs: "
            f"native={native} vendored={vendored}")
    return native


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--expected-version", type=int)
    parser.add_argument(
        "--require-same-version-group", action="append", default=[])
    parser.add_argument("--vendored-public-header", type=Path)
    parser.add_argument("--vendored-events-header", type=Path)
    parser.add_argument("--compatibility-shim", type=Path)
    parser.add_argument("--run-mutations", action="store_true")
    arguments = parser.parse_args(argv[1:])
    try:
        sources = read_source_root(arguments.source_root.resolve())
        resolution = resolve_extension_version(
            sources, arguments.expected_version,
            arguments.require_same_version_group)
        vendored_arguments = (
            arguments.vendored_public_header,
            arguments.vendored_events_header,
        )
        if any(current is not None for current in vendored_arguments):
            if any(current is None for current in vendored_arguments):
                raise ExtensionVersionError(
                    "vendored public and events headers must be supplied together")
            assert arguments.vendored_public_header is not None
            assert arguments.vendored_events_header is not None
            vendored_public_path = arguments.vendored_public_header.resolve()
            vendored_events_path = arguments.vendored_events_header.resolve()
            missing_vendored = [
                str(current)
                for current in (vendored_public_path, vendored_events_path)
                if not current.is_file()
            ]
            if missing_vendored:
                raise ExtensionVersionError(
                    f"vendored extension headers not found: {missing_vendored}")
            resolution = validate_vendored_headers(
                sources,
                vendored_public_path.read_text(encoding="utf-8"),
                vendored_events_path.read_text(encoding="utf-8"),
                resolution.version, arguments.require_same_version_group)
        if arguments.run_mutations:
            run_negative_mutations(
                sources, resolution.version,
                arguments.require_same_version_group)
        if arguments.compatibility_shim is not None:
            compatibility_shim = arguments.compatibility_shim.resolve()
            if not compatibility_shim.is_file():
                raise ExtensionVersionError(
                    f"compatibility shim not found: {compatibility_shim}")
            validate_weak_compatibility_shim(
                compatibility_shim.read_text(encoding="utf-8"))
    except (OSError, ExtensionVersionError) as error:
        print(f"FAIL shared PiP extension-version proof: {error}",
              file=sys.stderr)
        return 1
    print(resolution.version)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
