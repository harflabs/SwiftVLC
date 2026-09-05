#!/usr/bin/env python3
"""Structural proof for patch 0027's cross-thread strict-frame contract."""

from pathlib import Path
import sys

from pip_extension_version import (
    read_source_root,
    resolve_extension_version,
    run_negative_mutations as run_extension_version_mutations,
    validate_vendored_headers,
)


def function_body(source: str, signature: str) -> str:
    start = -1
    while True:
        start = source.find(signature, start + 1)
        if start < 0:
            raise AssertionError(f"missing function: {signature}")
        opening = source.find("{", start)
        if opening < 0:
            raise AssertionError(f"missing body: {signature}")
        semicolon = source.find(";", start, opening)
        if semicolon < 0:
            break
    depth = 0
    for index in range(opening, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[opening : index + 1]
    raise AssertionError(f"unterminated body: {signature}")


def ordered(body: str, *needles: str) -> None:
    cursor = 0
    for needle in needles:
        position = body.find(needle, cursor)
        if position < 0:
            raise AssertionError(f"missing/out-of-order invariant: {needle}")
        cursor = position + len(needle)


def require(body: str, *needles: str) -> None:
    for needle in needles:
        if needle not in body:
            raise AssertionError(f"missing invariant: {needle}")


def forbid(body: str, *needles: str) -> None:
    for needle in needles:
        if needle in body:
            raise AssertionError(f"forbidden invariant: {needle}")


def validate_apple_submission_contract(apple: str, vout: str) -> None:
    """Prove strict success crosses the renderer's validated commit point.

    AVSampleBufferVideoRenderer's enqueue method is void.  The Apple output
    therefore centralizes its only direct enqueue in a helper which performs
    live preflight and postflight gates.  RenderPicture may publish its overlay
    and recovery base, and VLC may update the video clock, only after that
    helper returns Ready for the exact sample.
    """
    enqueue = function_body(
        apple,
        "- (VLCSampleBufferRendererGateResult)enqueueSampleBufferLocked:",
    )
    if enqueue.count("[renderer enqueueSampleBuffer:sampleBuffer];") != 1:
        raise AssertionError(
            "central renderer helper must own exactly one direct enqueue")
    ordered(
        enqueue,
        "[self prepareRendererLocked:renderer",
        "if (result != VLCSampleBufferRendererGateResultReady)",
        "if (requireReadiness && !renderer.isReadyForMoreMediaData)",
        "rendererEnqueueInProgress = true;",
        "[renderer enqueueSampleBuffer:sampleBuffer];",
        "rendererEnqueueInProgress = false;",
        "context:\"post-enqueue validation\"",
        "if (result != VLCSampleBufferRendererGateResultReady)",
        "if (didFlush)",
        "&rendererSuccessfulSubmissionCount",
        "if (rememberForRecovery)",
        "recoverySampleBuffer = retained;",
        "vlc_samplebuffer_renderer_record_submission(&rendererRecovery);",
        "return VLCSampleBufferRendererGateResultReady;",
    )
    require(
        enqueue,
        "for (unsigned attempt = 0; attempt < 2; ++attempt)",
        "if (attempt == 0)",
        "continue;",
        "rendererRetryableSubmissionCount",
    )

    apple_render = function_body(apple, "static int RenderPicture(")
    helper_call = "[sys enqueueSampleBufferLocked:sampleBuffer"
    if apple_render.count(helper_call) != 1:
        raise AssertionError(
            "RenderPicture must have exactly one centralized enqueue origin")
    forbid(apple_render, "[renderer enqueueSampleBuffer:sampleBuffer];")
    tail = apple_render[apple_render.find("int submissionStatus = -EAGAIN;") :]
    ordered(
        tail,
        helper_call,
        "requireReadiness:YES",
        "rememberForRecovery:YES",
        "if (result == VLCSampleBufferRendererGateResultReady)",
        "sys->latestUncompositedPixelBuffer =",
        "sys->latestSampleTiming = sampleTimingInfo;",
        "++sys->latestFrameSequence;",
        "++sys->overlayAcceptedSubmissionSequence;",
        "submissionStatus = VLC_SUCCESS;",
    )
    publish = "sys->latestUncompositedPixelBuffer ="
    if apple_render.count(publish) != 1:
        raise AssertionError(
            "Apple current-picture identity must have one commit publication")
    ordered(
        apple_render,
        "CMSampleBufferCreateReadyWithImageBuffer",
        "int submissionStatus = -EAGAIN;",
        helper_call,
        publish,
        "if (submissionStatus == VLC_SUCCESS)",
        "commitOverlayUICompositionEnabled:submittedComposition",
        "prewarmOverlayForPixelBuffer:uncompositedPixelBuffer",
    )

    # No display path may bypass the helper.  Its direct enqueue is the only
    # one in this translation unit; recovery and overlay refresh use it too.
    if apple.count("[renderer enqueueSampleBuffer:sampleBuffer];") != 1:
        raise AssertionError("renderer enqueue escaped the centralized gate")

    # The core obtains the synchronous status written by Prepare/RenderPicture
    # before updating the exact picture's clock and consuming strict work.
    core_render = function_body(vout, "static int RenderPicture(")
    ordered(
        core_render,
        "vout_display_Display(vd, todisplay);",
        "vout_display_GetPictureSubmissionStatus(vd, todisplay);",
        "vlc_clock_UpdateVideoFrameStep(",
        "vout_ConsumeStrictFrameAttempt(sys,",
    )


def mutation_rejects_apple_submission_bypass_or_reordering(
        apple: str, vout: str) -> None:
    """Keep the structural proof sensitive to realistic integration bugs."""
    apple_render = function_body(apple, "static int RenderPicture(")
    call_start = apple_render.find(
        "VLCSampleBufferRendererGateResult result =\n"
        "                [sys enqueueSampleBufferLocked:sampleBuffer")
    if call_start < 0:
        raise AssertionError("cannot construct centralized-enqueue bypass")
    call_end = apple_render.find(";", call_start)
    if call_end < 0:
        raise AssertionError("cannot locate centralized-enqueue terminator")
    original_call = apple_render[call_start : call_end + 1]
    bypass_call = (
        "[renderer enqueueSampleBuffer:sampleBuffer];\n"
        "            VLCSampleBufferRendererGateResult result =\n"
        "                VLCSampleBufferRendererGateResultReady;")
    bypass = apple.replace(original_call, bypass_call, 1)
    try:
        validate_apple_submission_contract(bypass, vout)
    except AssertionError:
        pass
    else:
        raise AssertionError(
            "direct RenderPicture enqueue bypass escaped qualification gate")

    successful_commit = (
        "vlc_samplebuffer_renderer_increment(\n"
        "            &rendererSuccessfulSubmissionCount);")
    postflight = "BOOL didFlush = NO;"
    if successful_commit not in apple or postflight not in apple:
        raise AssertionError("cannot construct postflight-order mutation")
    reordered = apple.replace(successful_commit, "", 1).replace(
        postflight, successful_commit + "\n        " + postflight, 1)
    try:
        validate_apple_submission_contract(reordered, vout)
    except AssertionError:
        return
    raise AssertionError(
        "successful-count-before-postflight mutation escaped qualification gate")


def validate_frame_next_submission_probe(vout: str) -> None:
    """Pin the validation-only oracle to accepted NEXT submissions.

    The runtime probe deliberately stays paused long enough for forced
    redisplays. If this predicate admits FORCED, its exact equality barriers
    fail. This structural half keeps that mutation from silently changing the
    meaning of the source-linked oracle.
    """
    render = function_body(vout, "static int RenderPicture(")
    needle = (
        "if (render_type == RENDER_PICTURE_NEXT\n"
        "     && submission_status == VLC_SUCCESS\n"
        "     && atomic_load_explicit("
        "&sys->frame_next_submission_probe_enabled,"
    )
    require(render, needle,
            "atomic_fetch_add_explicit(&sys->frame_next_submission_count, 1,")
    if render.count(
            "atomic_fetch_add_explicit(&sys->frame_next_submission_count, 1,") != 1:
        raise AssertionError("NEXT submission oracle must have one origin")
    require(vout,
            "atomic_bool frame_next_submission_probe_enabled;",
            "atomic_init(&sys->frame_next_submission_probe_enabled, false);",
            "void vout_EnableFrameNextSubmissionProbe(",
            "atomic_bool frame_next_terminal_in_flight;",
            "atomic_uint_fast64_t frame_next_empty_while_terminal_count;",
            "atomic_init(&sys->frame_next_terminal_in_flight, false);",
            "atomic_init(&sys->frame_next_empty_while_terminal_count, 0);")


def mutation_rejects_forced_submission_count(vout: str) -> None:
    original = "if (render_type == RENDER_PICTURE_NEXT\n     && submission_status"
    mutated = "if (render_type == RENDER_PICTURE_FORCED\n     && submission_status"
    if original not in vout:
        raise AssertionError("cannot construct FORCED-submission mutation")
    candidate = vout.replace(original, mutated, 1)
    try:
        validate_frame_next_submission_probe(candidate)
    except AssertionError:
        return
    raise AssertionError("FORCED redisplay mutation escaped qualification gate")


def validate_eof_observer_lifetime(vout: str, decoder: str,
                                   input_source: str) -> None:
    """Pin the two producer-quiescence invariants found by loaded replay."""
    complete = function_body(vout, "bool vout_CompleteNextPictureStrict(")
    require(complete,
            "sys->strict_frame.committed_request_id = 0;",
            "sys->strict_frame.committed_generation = 0;",
            "sys->strict_frame.observer_request_id != 0")
    forbid(complete, "vout_ClearStrictFrame(sys);")

    empty = function_body(vout, "bool vout_IsEmpty(")
    ordered(empty,
            "vout_control_Hold(&sys->control);",
            "picture_fifo_IsEmpty(sys->decoder_fifo)",
            "&& sys->frame_next_count == 0",
            "&& !atomic_load_explicit(&sys->frame_next_terminal_in_flight,",
            "vout_control_Release(&sys->control);")
    require(empty,
            "frame_next_empty_while_terminal_count",
            "frame_next_submission_probe_enabled")

    # vout_control_Hold cannot complete while DisplayPicture/RenderPicture is
    # running. Thus the count decrement and its synchronous callback queueing
    # are one producer-quiescence unit: EOF cannot observe zero in the middle.
    display_next = function_body(vout, "static int DisplayNextFrame(")
    ordered(display_next, "--sys->frame_next_count;",
            "const int ret = RenderPicture(sys, RENDER_PICTURE_NEXT);",
            "frame_next_terminal_in_flight, false",
            "return ret;")
    render = function_body(vout, "static int RenderPicture(")
    require(render, "vout_SendStrictFrameTerminal(&strict_terminal);")
    consume = function_body(vout, "vout_ConsumeStrictFrameAttempt(")
    legacy_final = consume[
        consume.find("if (sys->strict_frame.target_request_id == 0)"):
        consume.find("assert(sys->strict_frame.countdown > 0);")
    ]
    require(legacy_final,
            "terminal->wake_callback = sys->strict_frame.needs_pictures;",
            "terminal->wake_observation = 0;")
    forbid(legacy_final, "vout_ClearStrictFrame(sys);")

    legacy_observed = function_body(vout, "int vout_NextPictureObserved(")
    ordered(legacy_observed,
            "sys->frame_next_count += request_frame_count;",
            "sys->strict_frame.observer_request_id = observer_request_id;",
            "sys->strict_frame.standard = standard;",
            "vout_control_ReleaseAndWake(&sys->control);")
    forbid(legacy_observed, "picture_fifo_GetCount")

    complete_observer = function_body(
        vout, "bool vout_CompleteNextPictureObserver(")
    ordered(complete_observer,
            "sys->strict_frame.observer_request_id == request_id",
            "sys->frame_next_count == 0",
            "sys->strict_frame.target_request_id == 0",
            "sys->strict_frame.committed_request_id == 0",
            "vout_ClearStrictFrame(sys);")

    install_legacy = function_body(
        decoder, "Decoder_InstallLegacyFrameNextObserverLocked(")
    ordered(install_legacy,
            "Decoder_AllocateFrameNextObserverToken(&token)",
            "vout_NextPictureObserved(",
            "owner->frame_next_observer_request_id = token;",
            "owner->frames_countdown = 0;")

    drained = function_body(decoder,
                            "static bool vlc_input_decoder_IsDrainedLocked(")
    ordered(drained,
            "owner->cat == VIDEO_ES && owner->video.vout != NULL",
            "!Decoder_HasFrameNextObserverLocked(owner)",
            "owner->frames_countdown > 0",
            "owner->strict_frame_request_id != 0",
            "return vout_IsEmpty(owner->video.vout);")

    run_input = function_body(input_source, "static void *Run(")
    ordered(run_input,
            "priv->frame_next_natural_eof_quiescing =",
            "bool eof_set_pending = false;",
            "pending->i_type == INPUT_CONTROL_SET_FRAME_NEXT",
            "if (eof_set_pending)",
            "input_ControlPushFrameNextDisplayed(",
            "VLC_INPUT_FRAME_STEP_NO_FRAME",
            "End( p_input );",
            "DrainFrameNextTerminals( p_input );")


def mutation_rejects_eof_observer_regressions(vout: str, decoder: str,
                                               input_source: str) -> None:
    mutations = (
        ("commit-ack-clears-observer",
         vout.replace(
             "sys->strict_frame.committed_generation = 0;\n"
             "        /* Do not clear an otherwise idle observer",
             "sys->strict_frame.committed_generation = 0;\n"
             "        vout_ClearStrictFrame(sys);\n"
             "        /* Do not clear an otherwise idle observer", 1),
         decoder, input_source),
        ("raw-fifo-only-eof",
         vout.replace(
             "bool empty = picture_fifo_IsEmpty(sys->decoder_fifo)\n"
             "              && sys->frame_next_count == 0\n"
             "              && !atomic_load_explicit("
             "&sys->frame_next_terminal_in_flight,\n"
             "                                       memory_order_acquire);",
             "bool empty = picture_fifo_IsEmpty(sys->decoder_fifo);", 1),
         decoder, input_source),
        ("decoder-forgets-unadmitted-request", vout,
         decoder.replace(
             "if (!Decoder_HasFrameNextObserverLocked(owner)\n"
             "         && (owner->frames_countdown > 0\n"
             "          || owner->strict_frame_request_id != 0))",
             "if (false)", 1),
         input_source),
        ("natural-eof-does-not-identify-pending-set", vout, decoder,
         input_source.replace(
             "pending->i_type == INPUT_CONTROL_SET_FRAME_NEXT",
             "false /* pending SET identity removed */", 1)),
        ("standalone-legacy-uses-raw-fifo", vout,
         decoder.replace(
             "vout_NextPictureObserved(\n"
             "        owner->video.vout, request_count, token, token,",
             "vout_NextPicture(owner->video.vout, request_count);\n"
             "    const int ret = VLC_SUCCESS;\n"
             "    /* raw FIFO mutation */",
             1), input_source),
        ("legacy-observer-cleared-before-ack",
         vout.replace(
             "sys->strict_frame.no_output_observation = 0;\n"
             "        }\n"
             "        return;",
             "vout_ClearStrictFrame(sys);\n"
             "        }\n"
             "        return;", 1),
         decoder, input_source),
    )
    for name, candidate_vout, candidate_decoder, candidate_input in mutations:
        try:
            validate_eof_observer_lifetime(
                candidate_vout, candidate_decoder, candidate_input)
        except AssertionError:
            continue
        raise AssertionError(f"{name} mutation escaped qualification gate")


def validate_runtime_probe_fidelity(native_probe: str) -> None:
    """Pin the source-linked rows to exact engine barriers and identities."""
    stop = function_body(native_probe, "static bool stop_at_quiescence(")
    ordered(stop,
            "libvlc_media_player_stop_async(player);",
            "wait_for_state(player, libvlc_Stopped, 5000)",
            "completion->count == exact_terminal_count")
    forbid(stop, "sleep_milliseconds")

    opening = function_body(native_probe, "static bool play_through_opening(")
    ordered(opening,
            "libvlc_event_attach(events, libvlc_MediaPlayerOpening,",
            "libvlc_media_player_play(player) == 0",
            "while (started && !barrier.opened)",
            "pthread_cond_timedwait(",
            "bool opened = started && barrier.opened;",
            "libvlc_event_detach(events, libvlc_MediaPlayerOpening,",
            "return opened;")
    forbid(opening, "sleep_milliseconds(")

    rebind = function_body(native_probe, "static int run_vmem_atomic_rebind_case(")
    disabled = rebind[rebind.index("/* Invalid partial publication above") :]
    ordered(disabled,
            "play_through_opening(player)",
            "stop_player(player)",
            "atomic_load_explicit(&a.setup_count, memory_order_relaxed) != 1",
            "atomic_load_explicit(&b.setup_count, memory_order_relaxed) != 1")

    vmem_case = function_body(native_probe, "static int run_vmem_submission_case(")
    ordered(vmem_case,
            "wait_for_state(player, libvlc_Paused, 5000)",
            "check_terminal(&completion, 1, request_id + 2000, expected_status)",
            "before_strict =",
            "check_terminal(&completion, 2, request_id, expected_status)",
            "await_atomic_exact(submission_counter, before_strict + 3, 5000)",
            "check_terminal(&completion, 3, request_id + 1000,",
            "await_atomic_exact(submission_counter, before_strict + 4, 5000)",
            "const unsigned exact_terminals = install_status_callback ? 3 : 2;",
            "stop_at_quiescence(player, &completion, exact_terminals)")
    forbid(vmem_case, "sleep_milliseconds(")

    overflow_case = function_body(native_probe, "static int run_terminal_overflow_case(")
    ordered(overflow_case,
            "wait_for_state(player, libvlc_Paused, 5000)",
            "check_terminal(&completion, 1, 989,",
            "baseline = atomic_load_explicit(",
            "force_terminal_allocation_failure(player, true)",
            "check_terminal(&completion, 2, 990, -EOVERFLOW)",
            "force_terminal_allocation_failure(player, false)",
            "check_terminal(&completion, 3, 991,",
            "await_atomic_exact(&vmem.status_count, baseline + 2, 5000)",
            "stop_at_quiescence(player, &completion, 3)",
            "!= baseline + 2")
    forbid(overflow_case, "sleep_milliseconds(")

    lifecycle = function_body(native_probe, "static int run_committed_terminal_lifecycle_case(")
    transit = lifecycle[lifecycle.index("struct lifecycle_fixture transit;"):]
    ordered(transit,
            "set_terminal_pop_barrier(transit_handle, true)",
            "swiftvlc_libvlc_media_player_request_next_frame(transit.player, 1220)",
            "await_terminal_pop_barrier(transit_handle, 5000)",
            "libvlc_media_player_lock(transit.player);",
            "set_terminal_pop_barrier(transit_handle, false)",
            "await_terminal_in_transit(transit_handle, 1220, 5000)",
            "libvlc_media_player_stop_async(transit.player);",
            "!lifecycle_exact_after_stop(&transit, 1220)")

    static_case = function_body(native_probe,
                                "static int run_static_filter_case(")
    ordered(static_case,
            'libvlc_media_add_option(media, ":start-paused");',
            "libvlc_media_player_play(player)",
            "wait_for_state(player, libvlc_Paused, 5000)",
            "await_atomic_at_least(&vmem.status_count, 1,")
    forbid(static_case, "wait_for_state(player, libvlc_Playing,", "libvlc_media_player_set_pause(")
    require(
        static_case,
        'expansion ? "--deinterlace=1" : "--video-filter=fps"',
        'expansion ? "--deinterlace-mode=bob" : "--fps-fps=1/1"',
        "cancel_rebind ? 75u : 25u",
        "player, before_burst + 3,",
        "check_core_cancel_rebind_order(&core_order, before_core,",
        "await_frame_next_submission_count(player, before_drop + 1, 5000)",
        "frame_next_submission_count(player) != expected_submissions",
        "await_core_step_count(&core_order, expected_core_events, 0)",
        "stop_at_quiescence(player, &completion, expected_terminal_count)",
    )
    legacy_branch = static_case[
        static_case.find("if (legacy_pending)"):
        static_case.find("else if (expansion)")
    ]
    ordered(legacy_branch,
            "set_submission_barrier(&vmem, true);",
            "libvlc_media_player_next_frame(player);",
            "await_submission_barrier(&vmem, 5000)",
            "input_ControlSetFrameNextNeedData(legacy_handle.input, true);",
            "await_frame_next_empty_while_terminal_count(",
            "input_ControlFrameNextNaturalEofQuiescing(",
            "set_submission_barrier(&vmem, false);",
            "await_frame_next_submission_count(player, before_legacy + 1,",
            "check_core_legacy_order(&core_order, before_core, 1,",
            "expected_submissions = before_legacy + 1;")
    forbid(legacy_branch,
           "swiftvlc_libvlc_media_player_request_next_frame(")
    expansion_branch = static_case[
        static_case.find("if (expansion)"):
        static_case.find("else if (cancel_rebind)")
    ]
    ordered(expansion_branch,
            "swiftvlc_libvlc_media_player_request_next_frame(",
            "check_terminal(&completion, 1, request_id,",
            "The strict observer has now received its completion acknowledgement",
            "libvlc_media_player_next_frame(player);",
            "player, before_burst + 3,")
    cancel_order = function_body(native_probe,
                                 "check_core_cancel_rebind_order(")
    ordered(cancel_order,
            "events[0].kind == core_step_legacy",
            "events[1].kind == core_step_strict",
            "events[1].request_id == canceled_id",
            "events[1].status == -ECANCELED",
            "events[2].kind == core_step_legacy",
            "events[3].kind == core_step_strict",
            "events[3].request_id == rebound_id")

    unknown = function_body(native_probe,
                            "static int run_unknown_length_case(")
    require(unknown,
            "completion.history[0].position == -1.0",
            "stop_at_quiescence(player, &completion, 1)")

    deferred = function_body(native_probe,
                             "static int run_deferred_error_reentry_case(")
    ordered(deferred,
            "input_ControlForceFrameNextStrictSetPopBarrier(gate.input, true)",
            "withdraw_strict_set_for_deferred_probe(first, 1200)",
            "input_ControlPushFrameNextDisplayed(first.input, 1200",
            "await_reentrant_result(&completion,",
            "withdraw_strict_set_for_deferred_probe(second, 1201)",
            "input_ControlPushFrameNextDisplayed(second.input, 1201",
            "stop_at_quiescence(player, &completion, 2)")

    main_probe = function_body(native_probe, "int main(")
    require(main_probe,
            "player, mixed_submission_baseline + 9, 5000)",
            "check_core_mixed_order(&core_order, mixed_core_baseline, 300,",
            "4, 4, VLC_SUCCESS, VLC_SUCCESS",
            "first_delta != 200000 || second_delta != 200000",
            "post_eof_seek_time != clean_post_seek_time",
            "run_static_filter_case(965, static_filter_legacy_pending)")


def mutation_rejects_weakened_runtime_probe(native_probe: str) -> None:
    mutations = (
        ("removed-static-start-paused-inventory",
         'libvlc_media_add_option(media, ":start-paused");',
         '/* removed startup pause */'),
        ("removed-transit-queue-boundary",
         "await_terminal_pop_barrier(transit_handle, 5000)",
         "true /* no queue acknowledgement */"),
        ("removed-overflow-baseline-acknowledgement",
         "check_terminal(&completion, 1, 989,",
         "check_terminal(&completion, 0, 989,"),
        ("weakened-overflow-exact-output-count",
         "await_atomic_exact(&vmem.status_count, baseline + 2, 5000)",
         "await_atomic_at_least(&vmem.status_count, baseline + 2, 5000)"),
        ("removed-disabled-input-opening-boundary",
         "if (!play_through_opening(player)",
         "if (libvlc_media_player_play(player) != 0"),
        ("removed-vmem-baseline-acknowledgement",
         "check_terminal(&completion, 1, request_id + 2000, expected_status)",
         "false /* no output boundary before baseline */"),
        ("weakened-vmem-exact-output-count",
         "await_atomic_exact(submission_counter, before_strict + 4, 5000)",
         "await_atomic_at_least(submission_counter, before_strict + 4, 5000)"),
        ("weakened-nine-picture-burst",
         "player, mixed_submission_baseline + 9, 5000)",
         "player, mixed_submission_baseline + 8, 5000)"),
        ("removed-static-quiescence-equality",
         "frame_next_submission_count(player) != expected_submissions",
         "false /* weakened exact submission equality */"),
        ("widened-cadence",
         "first_delta != 200000 || second_delta != 200000",
         "first_delta < 150000 || second_delta > 250000"),
        ("tail-enqueued-before-strict-ack",
         "/* The strict observer has now received its completion acknowledgement\n"
         "         * while no legacy member is yet present in the vout aggregate. */\n"
         "        libvlc_media_player_next_frame(player);",
         "libvlc_media_player_next_frame(player);\n"
         "        /* weakened: tail is no longer proven to follow ack */"),
        ("removed-standalone-legacy-order-proof",
         "check_core_legacy_order(&core_order, before_core, 1,",
         "true /* weakened standalone legacy callback proof */ || ("),
        ("removed-terminal-in-flight-eof-contender",
         "await_frame_next_empty_while_terminal_count(\n"
         "                player, before_empty_attempts + 1, 5000)",
         "true /* weakened: EOF contender never reached */"),
    )
    for name, original, replacement in mutations:
        if original not in native_probe:
            raise AssertionError(f"cannot construct probe mutation: {name}")
        candidate = native_probe.replace(original, replacement, 1)
        try:
            validate_runtime_probe_fidelity(candidate)
        except AssertionError:
            continue
        raise AssertionError(f"{name} mutation escaped qualification gate")


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} <patched-vlc-source>")
    root = Path(sys.argv[1])
    decoder = (root / "src/input/decoder.c").read_text()
    player = (root / "src/player/player.c").read_text()
    player_input = (root / "src/player/input.c").read_text()
    input_source = (root / "src/input/input.c").read_text()
    input_internal = (root / "src/input/input_internal.h").read_text()
    input_event = (root / "src/input/event.h").read_text()
    clock = (root / "src/clock/clock.c").read_text()
    clock_header = (root / "src/clock/clock.h").read_text()
    timer = (root / "src/player/timer.c").read_text()
    es_out = (root / "src/input/es_out.c").read_text()
    es_out_timeshift = (root / "src/input/es_out_timeshift.c").read_text()
    vout = (root / "src/video_output/video_output.c").read_text()
    vout_header = (root / "include/vlc_vout_display.h").read_text()
    vmem = (root / "modules/video_output/vmem.c").read_text()
    vmem_configuration = (
        root / "include/vlc_vmem_configuration.h"
    ).read_text()
    apple = (root / "modules/video_output/apple/VLCSampleBufferDisplay.m").read_text()
    media_player = (root / "lib/media_player.c").read_text()
    media_player_header = (
        root / "include/vlc/libvlc_media_player.h"
    ).read_text()
    events_header = (root / "include/vlc/libvlc_events.h").read_text()
    libvlc_symbols = (root / "lib/libvlc.sym").read_text()
    libvlccore_symbols = (root / "src/libvlccore.sym").read_text()
    native_probe = Path(__file__).with_name(
        "strict-frame-step-probe.c"
    ).read_text()

    validate_frame_next_submission_probe(vout)
    mutation_rejects_forced_submission_count(vout)
    validate_eof_observer_lifetime(vout, decoder, input_source)
    mutation_rejects_eof_observer_regressions(vout, decoder, input_source)
    validate_runtime_probe_fidelity(native_probe)
    mutation_rejects_weakened_runtime_probe(native_probe)

    # Qualification-only counters are internal source-linked hooks, not a
    # public LibVLC/libvlccore ABI and not enabled by any production caller.
    probe_symbols = (
        "vout_EnableFrameNextSubmissionProbe",
        "vout_GetFrameNextSubmissionCount",
        "vout_IsFrameNextTerminalInFlight",
        "vout_GetFrameNextEmptyWhileTerminalCount",
    )
    for symbol in probe_symbols:
        if symbol in libvlc_symbols or symbol in libvlccore_symbols \
           or symbol in media_player_header:
            raise AssertionError(
                f"qualification-only counter leaked into public ABI: {symbol}")
    production_c = "\n".join(
        path.read_text(errors="ignore")
        for path in root.rglob("*.c")
    )
    if production_c.count("vout_EnableFrameNextSubmissionProbe(") != 1:
        raise AssertionError(
            "qualification NEXT counter has a production enable call")
    require(native_probe,
            "vout_EnableFrameNextSubmissionProbe(vout);",
            "vout_GetFrameNextSubmissionCount(vout);",
            "vout_IsFrameNextTerminalInFlight(vout);",
            "vout_GetFrameNextEmptyWhileTerminalCount(vout);")

    decoder_loop = function_body(decoder, "static void *DecoderThread(")
    require(decoder_loop,
            "p_owner->paused && p_owner->frames_countdown == 0",
            "&& !p_owner->b_draining")
    draining_mutation = decoder.replace("&& !p_owner->b_draining", "", 1)
    try:
        mutated_loop = function_body(draining_mutation,
                                     "static void *DecoderThread(")
        require(mutated_loop, "&& !p_owner->b_draining")
    except AssertionError:
        pass
    else:
        raise AssertionError("paused-drain mutation escaped qualification gate")

    # A concrete final output consumes exactly one aggregate member.
    # PreparePicture(NULL) returns before that decrement and publishes a
    # versioned no-output observation. Static-filter input count is never
    # treated as final-output count.
    display_next = function_body(vout, "static int DisplayNextFrame(")
    ordered(
        display_next,
        "PreparePicture(sys, !sys->displayed.current, true)",
        "++sys->strict_frame.next_observation",
        "sys->strict_frame.no_output_observation = next == NULL",
        "if (!next)",
        "sys->strict_frame.needs_pictures(",
        "sys->strict_frame.no_output_observation",
        "frame_next_terminal_in_flight, true",
        "--sys->frame_next_count;",
        "RenderPicture(sys, RENDER_PICTURE_NEXT)",
        "frame_next_terminal_in_flight, false",
    )
    require(display_next, "sys->frame_next_count")
    forbid(display_next, "picture_fifo_GetCount")
    update_current = function_body(vout, "static bool UpdateCurrentPicture(")
    forbid(update_current, "--sys->frame_next_count")
    consume = function_body(vout, "vout_ConsumeStrictFrameAttempt(")
    require(consume,
            "sys->strict_frame.observer_request_id",
            "sys->strict_frame.target_request_id",
            "sys->strict_frame.committed_generation",
            "sys->strict_frame.standard_skip_count",
            "terminal->standard_callback = sys->strict_frame.standard;",
            "--sys->strict_frame.countdown",
            "terminal->callback = sys->strict_frame.displayed;",
            "terminal->wake_callback = sys->strict_frame.needs_pictures;",
            "sys->frame_next_count == 0")
    send_terminal = function_body(vout, "vout_SendStrictFrameTerminal(")
    ordered(send_terminal,
            "terminal->standard_callback(",
            "terminal->callback(",
            "terminal->wake_callback(")
    strict_admission = function_body(vout, "int vout_NextPictureStrict(")
    ordered(strict_admission, "request_frame_count >= SIZE_MAX - prior_count",
            "sys->strict_frame.countdown =",
            "*needed_count = 0;", "vout_control_ReleaseAndWake(")
    require(strict_admission,
            "sys->strict_frame.observer_request_id == 0",
            "*observer_request_id = sys->strict_frame.observer_request_id",
            "*observer_generation = sys->strict_frame.observer_generation")
    forbid(strict_admission, "picture_fifo_GetCount")
    legacy_admission = function_body(vout, "size_t vout_NextPicture(")
    ordered(legacy_admission,
            "request_frame_count >= SIZE_MAX - sys->frame_next_count",
            "sys->frame_next_count += request_frame_count")
    require(legacy_admission, "return VOUT_NEXT_PICTURE_ERROR;")
    reconcile_vout = function_body(vout,
                                   "int vout_ReconcileNextPictureStrict(")
    ordered(reconcile_vout,
            "sys->strict_frame.no_output_observation != observation",
            "picture_fifo_IsEmpty(sys->decoder_fifo)",
            "*needed_count = sys->frame_next_count;",
            "*strict_ordinal = sys->strict_frame.countdown;",
            "*standard_skip_count = sys->strict_frame.standard_skip_count;",
            "sys->strict_frame.no_output_observation = 0;",
            "vout_control_Release(&sys->control);")
    forbid(reconcile_vout,
           "sys->frame_next_count - pics_count",
           "sys->strict_frame.countdown - pics_count")
    success_tail = reconcile_vout[reconcile_vout.find(
        "*needed_count = sys->frame_next_count;"):]
    ordered(success_tail,
            "sys->strict_frame.no_output_observation = 0;",
            "vout_control_Release(&sys->control);")
    forbid(success_tail, "vout_control_ReleaseAndWake(&sys->control);")
    scoped_cancel = function_body(vout, "bool vout_CancelNextPictureStrict(")
    require(scoped_cancel,
            "sys->strict_frame.target_request_id",
            "sys->strict_frame.committed_request_id",
            "--sys->frame_next_count;",
            "*observer_remains = sys->strict_frame.observer_request_id != 0")
    forbid(scoped_cancel, "sys->frame_next_count = 0;")
    reset_observer = function_body(vout,
                                   "void vout_CancelNextPictureObserver(")
    require(reset_observer,
            "standard_skip_count",
            "result->standard_before",
            "result->standard_after",
            "sys->frame_next_count = 0;",
            "vout_ClearStrictFrame(sys);")

    # Strict success is possible only after output submission was proven and
    # the exact picture's synchronous video-clock update completed. Callback
    # delivery happens after the display lock is released. Legacy void vmem is
    # explicitly unproven: normal playback remains compatible, strict fails.
    render = function_body(vout, "static int RenderPicture(")
    ordered(
        render,
        "vout_IsStrictFrameTarget(sys)",
        "sys->strict_frame.claim_commit(",
        "vout_display_PurgePictureSubmissions(vd, false);",
        "vout_DropCanceledStrictFrameTarget(sys);",
        "vd->ops->prepare(vd, todisplay, subpic, system_pts);",
        "vout_display_Display(vd, todisplay);",
        "vout_display_GetPictureSubmissionStatus(vd, todisplay);",
        "vlc_clock_UpdateVideoFrameStep(",
        "vout_ConsumeStrictFrameAttempt(sys,",
        "capture.valid",
        "capture.time, capture.position",
        "vlc_queuedmutex_unlock(&sys->display_lock);",
        "vout_SendStrictFrameTerminal(&strict_terminal);",
    )
    require(
        render,
        "submission_unproven ? -ENOTSUP",
        "capture_strict_timing && !capture.valid ? -EIO : VLC_SUCCESS",
        "vout_statistic_AddLost(&sys->statistic, 1);",
    )
    strict_target = function_body(vout, "vout_IsStrictFrameTarget(")
    require(strict_target, "sys->strict_frame.countdown == 1")

    # The one-shot capture callback runs after the target's ordinary clock
    # update while the shared clock remains locked. The player snapshots its
    # timer synchronously there; the later terminal path only carries values.
    clock_update = function_body(clock, "static inline void vlc_clock_on_update(")
    ordered(clock_update, "clock->frame_step_capture->clock_ts = ts;",
            "clock->cbs->on_update(",
            "clock->cbs->on_frame_step_capture(")
    clock_capture = function_body(clock, "vlc_clock_UpdateVideoFrameStep(")
    ordered(clock_capture, "clock->frame_step_capture = capture;",
            "vlc_clock_UpdateVideo(",
            "clock->frame_step_capture = NULL;")
    require(clock_capture, ".clock_ts = VLC_TICK_INVALID")
    require(clock_header, "struct vlc_clock_frame_step_capture",
            "on_frame_step_capture")
    player_clock_capture = function_body(player_input, "input_thread_Events(")
    ordered(player_clock_capture,
            "event->type == INPUT_EVENT_FRAME_STEP_CLOCK_CAPTURE",
            "vlc_player_NormalizeOutputClockPoint(",
            "vlc_mutex_lock(&player->lock);")
    normalize = function_body(timer, "vlc_player_NormalizeOutputClockPoint(")
    require(normalize, "clock_ts",
            "player->timer.input_normal_time",
            "player->timer.start_offset",
            "player->timer.input_length",
            "position = -1.0;",
            "if (time < VLC_TICK_0)")
    forbid(normalize, "if (time < VLC_TICK_0 || position")
    complete_strict = function_body(
        player_input, "vlc_player_CompleteStrictNextVideoFrame(")
    require(complete_strict, "time == VLC_TICK_INVALID",
            "position < 0.0", "position > 1.0", "position = -1.0;")
    forbid(complete_strict, "vlc_player_GetTimerPoint(")
    require(
        vout_header,
        "VOUT_DISPLAY_PICTURE_SUBMISSION_UNPROVEN",
        "get_picture_submission_status",
    )

    # A display saved for reuse cannot retain aggregate work or a raw decoder
    # opaque. Replacement/reconfiguration cancels while the old pointer is
    # still valid, before detaching it from the decoder owner.
    ordered(
        function_body(vout, "static void vout_ReleaseDisplay("),
        "sys->frame_next_count = 0;",
        "vout_ClearStrictFrame(sys);",
    )
    ordered(
        function_body(decoder, "static int CreateVoutIfNeeded("),
        "Decoder_CancelStrictFrameLocked(p_owner, 0, 0, true);",
        "vout_thread_t *p_vout = p_owner->video.vout;",
        "p_owner->video.vout = NULL;",
        "input_resource_RequestVout(",
    )
    update_format = function_body(decoder, "static int ModuleThread_UpdateVideoFormat(")
    ordered(
        update_format,
        "Decoder_CancelStrictFrameLocked(p_owner, 0, 0, true);",
        "vout_configuration_t cfg",
        "p_owner->video.started = false;",
        "vlc_fifo_Unlock(p_owner->p_fifo);",
        "input_resource_RequestVout(",
        "p_owner->video.started = true;",
    )
    require(update_format, "Decoder_FailStrictFrameLocked(p_owner, -EIO);")

    # Every strict vout hold is guarded by a live render thread. Previous-frame
    # also cancels before overwriting countdown/flush state.
    started = function_body(decoder, "static bool Decoder_HasStartedVoutLocked(")
    require(started, "owner->video.vout != NULL && owner->video.started")
    settle = function_body(
        decoder,
        "static enum decoder_strict_cancel_result\nDecoder_SettleFrameNextLocked(",
    )
    require(settle,
            "owner->strict_frame_request_id != request_id",
            "owner->strict_frame_generation != generation",
            "Decoder_HasStartedVoutLocked(owner)",
            "strict_frame_committed_generation",
            "memory_order_acquire",
            "preserve_legacy",
            "vout_CancelNextPictureObserver(",
            "canceled.standard_before",
            "canceled.standard_after",
            "DECODER_STRICT_CANCEL_COMMITTED")
    ordered(
        settle,
        "vout_CancelNextPictureStrict(",
        "atomic_load_explicit(",
        "Decoder_ClearStrictFrameLocked(owner);",
        "Decoder_ClearFrameNextObserverLocked(owner);",
    )
    cancel = function_body(
        decoder,
        "static enum decoder_strict_cancel_result\nDecoder_CancelStrictFrameLocked(",
    )
    require(cancel, "Decoder_SettleFrameNextLocked(", "-ECANCELED")
    displayed = function_body(decoder,
                              "static void Decoder_StrictFrameDisplayed(")
    ordered(displayed, "atomic_store_explicit(",
            "decoder_Notify(owner, frame_next_displayed")
    fail_strict = function_body(decoder,
                                "static void Decoder_FailStrictFrameLocked(")
    require(fail_strict, "Decoder_SettleFrameNextLocked(",
            "request_id != 0, false")
    paused_batch = function_body(decoder, "static void Decoder_PausedForNextFrame(")
    ordered(
        paused_batch,
        "if (!Decoder_HasStartedVoutLocked(owner))",
        "Decoder_FailStrictFrameLocked(owner, -EBUSY);",
        "vout_NextPictureStrict(",
    )
    require(paused_batch,
            "ret == -EOVERFLOW",
            "? -EOVERFLOW : -EBUSY",
            "Decoder_InstallLegacyFrameNextObserverLocked(")
    frame_next = function_body(decoder, "void vlc_input_decoder_FrameNext(")
    ordered(frame_next,
            "!p_owner->video.started",
            "const bool output_observer_active =",
            "request_id == 0 && !output_observer_active",
            "Decoder_InstallLegacyFrameNextObserverLocked(",
            "vout_NextPictureStrict(")
    require(frame_next,
            "output_observer_active",
            "assert(output_observer_active);")
    forbid(frame_next,
           "p_owner->video.drained\n     && vout_IsEmpty",
           "needed_count == previous_needed_count",
           "frame_next_status, VLC_SUCCESS, 0, 0")
    require(frame_next, "ret == -EOVERFLOW ? -EOVERFLOW : -EBUSY")
    ordered(frame_next,
            "p_owner->frames_countdown == INT_MAX",
            "frame_next_status, -EOVERFLOW, request_id",
            "vlc_fifo_Unlock( p_owner->p_fifo );",
            "return;")
    replacement = function_body(
        decoder, "void vlc_input_decoder_RequestFrameNextPictures(")
    require(replacement,
            "owner->frame_next_observer_request_id == request_id",
            "owner->frame_next_observer_generation == generation",
            "observation == 0",
            "vout_CompleteNextPictureObserver(",
            "vout_ReconcileNextPictureStrict(",
            "ret == -EAGAIN",
            "owner->video.drained",
            "vout_DiscardDrainedNextPictures(",
            "owner->frames_countdown = 1;",
            "owner->strict_frame_decode_countdown = 1;",
            "frame_next_need_data, true")
    forbid(replacement,
           "owner->frames_countdown = (int)needed_count;",
           "owner->strict_frame_decode_countdown = strict_ordinal;")
    ordered(replacement,
            "vout_ReconcileNextPictureStrict(",
            "owner->frames_countdown = 1;",
            "frame_next_need_data, true")
    require(replacement,
            "decoder_Notify(owner, frame_next_displayed,",
            "unreported_before",
            "standard_after",
            "standard_skip_count")
    previous_decoder = function_body(decoder, "void vlc_input_decoder_FramePrevious(")
    ordered(
        previous_decoder,
        "Decoder_CancelStrictFrameLocked(owner, 0, 0, true);",
        "owner->frames_countdown = -1;",
        "vout_FlushAll(owner->video.vout);",
    )

    # Decoder error transitions which can occur after acceptance settle the
    # active generation. Sout sets error without the FIFO lock, and its caller
    # settles immediately after reacquiring that lock.
    reload_decoder = function_body(decoder, "static int DecoderThread_Reload(")
    if reload_decoder.count("p_owner->error = true;") != 2 or \
       reload_decoder.count("Decoder_FailStrictFrameLocked(p_owner, -EIO);") != 2:
        raise AssertionError("decoder reload errors do not settle strict work")
    decode_block = function_body(decoder, "static void DecoderThread_DecodeBlock(")
    ordered(decode_block, "case VLCDEC_ECRITICAL:",
            "p_owner->error = true;",
            "Decoder_FailStrictFrameLocked(p_owner, -EIO);")
    process_input = function_body(decoder, "static void DecoderThread_ProcessInput(")
    ordered(
        process_input,
        "DecoderThread_ProcessSout( p_owner, frame );",
        "vlc_fifo_Lock(p_owner->p_fifo);",
        "if (p_owner->error)",
        "Decoder_FailStrictFrameLocked(p_owner, -EIO);",
    )

    # Decoder EOF is not final-output EOF. An armed strict batch is woken and
    # settled only after vout proves that raw plus filter-pending output is
    # exhausted. This avoids false NO_FRAME for 1->N static filters.
    drained = function_body(decoder, "static void Decoder_VideoDrained(")
    ordered(drained,
            "if (Decoder_HasFrameNextObserverLocked(owner))",
            "frame_next_need_data, false",
            "vout_WakeNextPictureStrict(",
            "return;")
    strict_drained_prefix = drained[:drained.find(
        "if (owner->frames_countdown > 0)")]
    forbid(strict_drained_prefix,
           "vout_DiscardDrainedNextPictures(",
           "VLC_INPUT_FRAME_STEP_NO_FRAME")
    discard_drained = function_body(vout,
                                    "vout_DiscardDrainedNextPictures(")
    ordered(discard_drained,
            "missing_count <= sys->frame_next_count",
            "sys->strict_frame.countdown > retained_count",
            "sys->frame_next_count = retained_count;")
    require(discard_drained,
            "sys->strict_frame.countdown <= retained_count",
            "sys->frame_next_count = 0;",
            "vout_ClearStrictFrame(sys);")

    # Need-data is level-triggered/coalesced and never traverses the lossy
    # ordinary FIFO. Cancellation/drain/error clears it when aggregate demand
    # reaches zero.
    stop_need = function_body(decoder, "Decoder_StopFrameNeedDataIfIdleLocked(")
    ordered(stop_need, "owner->frames_countdown == 0",
            "frame_next_need_data, false")
    play_video = function_body(decoder, "static int ModuleThread_PlayVideo(")
    ordered(play_video, "const bool strict_batch =",
            "p_owner->frames_countdown--;",
            "Decoder_StopFrameNeedDataIfIdleLocked(p_owner);")
    require(play_video, "if (!strict_batch)")
    require(play_video, "Decoder_HasFrameNextObserverLocked(p_owner)")
    forbid(play_video, "strict_picture")
    need_callback = function_body(es_out, "decoder_frame_next_need_data(")
    require(need_callback, "input_ControlSetFrameNextNeedData(")
    forbid(need_callback, "input_ControlPush(")
    need_lane = function_body(input_source, "void input_ControlSetFrameNextNeedData(")
    require(need_lane, "frame_next_need_data_value", "frame_next_need_data_pending")
    replacement_lane = function_body(
        input_source, "void input_ControlRequestFrameNextPictures(")
    require(replacement_lane,
            "frame_next_replacement_pending",
            "frame_next_replacement.observation =",
            "two strict replacement generations pending")

    # The sole post-vout handoff uses a nonblocking dynamically grown terminal
    # queue with a dedicated allocation-free overflow slot for the one accepted
    # strict generation. RLE arithmetic and queue growth are checked. An OOM
    # never calls a listener under vout/decoder locks and never stops input
    # before the strict EOVERFLOW terminal is delivered.
    ensure_capacity = function_body(
        input_source, "static bool FrameNextTerminalEnsureCapacityLocked(")
    require(ensure_capacity,
            "sys->frame_next_force_terminal_allocation_failure",
            "additional > SIZE_MAX - sys->frame_next_displayed_count",
            "capacity > SIZE_MAX / 2",
            "capacity > SIZE_MAX / sizeof(*sys->frame_next_displayed)",
            "malloc(", "realloc(", "return false;")
    overflow_terminal = function_body(
        input_source, "static void FrameNextTerminalQueueOverflowLocked(")
    require(overflow_terminal,
            "request_id = sys->strict_frame_active_request_id",
            "FrameNextTerminalContainsStrictLocked(",
            "pending->i_type != INPUT_CONTROL_SET_FRAME_NEXT",
            "--sys->strict_frame_control_count;",
            "assert(!sys->frame_next_overflow_pending)",
            ".status = -EOVERFLOW",
            ".repeat_count = 1",
            "sys->frame_next_overflow_pending = true")
    forbid(overflow_terminal, "input_SendEvent(", "sys->is_stopped = true",
           "vlc_cond_wait")
    commit_claim = function_body(
        input_source, "bool input_ControlClaimFrameNextCommit(")
    ordered(commit_claim,
            "vlc_mutex_lock(&sys->lock_control);",
            "sys->frame_next_force_commit_barrier",
            "vlc_cond_wait(&sys->wait_control, &sys->lock_control);",
            "FrameNextClaimCommitLocked(sys, request_id,",
            "vlc_mutex_unlock(&sys->lock_control);")
    strict_control = function_body(
        input_source, "int input_ControlPushStrictFrame(")
    ordered(strict_control,
            "sys->strict_frame_commit_claimed",
            "return -EALREADY;",
            "sys->strict_frame_active_request_id = 0;",
            "sys->strict_frame_commit_claimed = false;",
            "vlc_cond_broadcast(&sys->wait_control);")
    forbid(strict_control,
           "--sys->frame_next_displayed_count",
           "sys->frame_next_overflow_pending = false")
    direct_status = function_body(es_out, "decoder_frame_next_status(")
    ordered(direct_status,
            "if (request_id != 0)",
            "input_ControlPushFrameNextDisplayed(",
            "return;",
            "input_SendEvent(")
    queue_or_send = function_body(
        input_source, "static void input_QueueOrSendFrameNextStatus(")
    ordered(queue_or_send,
            "if (request_id != 0)",
            "input_ControlPushFrameNextDisplayed(",
            "return;",
            "input_SendEvent(")
    esout_frame_next = function_body(es_out, "static void EsOutFrameNext(")
    no_video = esout_frame_next[
        esout_frame_next.find("if( p_sys->p_next_frame_es == NULL )"):
        esout_frame_next.find("if( previous )")]
    require(no_video, "input_ControlPushFrameNextDisplayed(")
    forbid(no_video, "input_SendEvent(")
    claim_bridge = function_body(es_out,
                                 "decoder_frame_next_claim_commit(")
    require(claim_bridge, "input_ControlClaimFrameNextCommit(")
    decoder_claim = function_body(decoder,
                                  "Decoder_StrictFrameClaimCommit(")
    ordered(decoder_claim,
            "owner->cbs->frame_next_claim_commit(",
            "atomic_store_explicit(",
            "strict_frame_committed_generation")
    decoder_complete = function_body(
        decoder, "bool vlc_input_decoder_CompleteFrameNext(")
    ordered(decoder_complete,
            "if (status == -EOVERFLOW)",
            "vout_CancelNextPictureStrict(",
            "Decoder_ClearStrictFrameLocked(owner);",
            "Decoder_ClearFrameNextObserverLocked(owner);")
    terminal_lane = function_body(input_source,
                                  "void input_ControlPushFrameNextDisplayed(")
    require(
        terminal_lane,
        "request_id != 0",
        "FrameNextClaimCommitLocked(sys, request_id, generation)",
        "FrameNextTerminalContainsStrictLocked(",
        "last->frame_next.repeat_count",
        "repeat_count <= SIZE_MAX",
        "last->frame_next.repeat_count += repeat_count",
        "FrameNextTerminalEnsureCapacityLocked(sys, 1)",
        "FrameNextTerminalQueueOverflowLocked(sys, request_id, generation)",
    )
    ordered(terminal_lane, "request_id != 0",
            "FrameNextClaimCommitLocked(sys, request_id, generation)",
            "FrameNextTerminalContainsStrictLocked(")
    forbid(terminal_lane, "vlc_cond_wait", "input_ControlPush(",
           "input_SendEvent(")
    control_dispatch = function_body(
        input_source, "static bool Control( input_thread_t *p_input,")
    terminal_start = control_dispatch.find(
        "case INPUT_CONTROL_FRAME_NEXT_DISPLAYED:")
    terminal_end = control_dispatch.find(
        "case INPUT_CONTROL_SET_FRAME_PREVIOUS:", terminal_start)
    if terminal_start < 0 or terminal_end < 0:
        raise AssertionError("missing strict terminal dispatch")
    terminal_dispatch = control_dispatch[terminal_start:terminal_end]
    ordered(terminal_dispatch, "es_out_CompleteFrameNext(",
            "input_SendEvent(")
    forbid(terminal_dispatch, "== VLC_SUCCESS")
    pop = function_body(input_source, "static inline int ControlPop(")
    ordered(
        pop,
        "p_sys->frame_next_force_terminal_pop_barrier",
        "FrameNextTerminalPopLocked(p_sys, p_param)",
        "if (p_sys->frame_next_replacement_pending)",
        "if (p_sys->frame_next_need_data_pending)",
        "const bool strict_first",
        "*pi_type = p_sys->control[0].i_type;",
    )
    ordered(pop,
            "const bool strict_first",
            "p_sys->frame_next_force_strict_set_pop_barrier",
            "INPUT_CONTROL_SET_FRAME_NEXT",
            "p_sys->frame_next_strict_set_pop_waiting = true;",
            "vlc_cond_wait(&p_sys->wait_control, &p_sys->lock_control);",
            "goto restart_locked;")
    set_pop_barrier = function_body(
        input_source, "void input_ControlForceFrameNextStrictSetPopBarrier(")
    ordered(set_pop_barrier,
            "vlc_mutex_lock(&sys->lock_control);",
            "sys->frame_next_force_strict_set_pop_barrier = enabled;",
            "vlc_cond_broadcast(&sys->wait_control);",
            "vlc_mutex_unlock(&sys->lock_control);")
    terminal_pop = function_body(input_source,
                                 "FrameNextTerminalPopLocked(")
    require(terminal_pop,
            "sys->frame_next_displayed[0].frame_next.repeat_count > 1",
            "--sys->frame_next_displayed[0].frame_next.repeat_count",
            "strict_frame_terminal_in_transit_request_id",
            "strict_frame_terminal_in_transit_generation")
    peek = function_body(input_source, "ControlPeekOrderedLocked(")
    require(peek, "strict_frame_control[0].sequence < sys->control[0].sequence")
    stop_input = function_body(input_source, "void input_Stop(")
    require(
        stop_input,
        "FrameNextHasCommittedStrictLocked(sys)",
        "if (!preserve_strict_commit)",
        "frame_next_displayed_count = 0;",
        "frame_next_overflow_pending = false;",
        "strict_frame_control_count = 0;",
        "frame_next_need_data_pending = false;",
        "frame_next_replacement_pending = false;",
        "vlc_cond_broadcast( &sys->wait_control );",
    )
    ordered(stop_input,
            "FrameNextHasCommittedStrictLocked(sys)",
            "if (!preserve_strict_commit)",
            "sys->is_stopped = true;",
            "vlc_cond_broadcast( &sys->wait_control );")
    run_input = function_body(input_source, "static void *Run(")
    ordered(run_input, "End( p_input );",
            "DrainFrameNextTerminals( p_input );",
            "input_SendEventDead( p_input );")
    drain = function_body(input_source, "static void DrainFrameNextTerminals(")
    ordered(drain,
            "vlc_mutex_lock(&sys->lock_control);",
            "FrameNextTerminalPopLocked(sys, &param);",
            "vlc_mutex_unlock(&sys->lock_control);",
            "input_SendEvent(input,")
    event_send = function_body(input_event, "static inline bool input_SendEvent(")
    ordered(event_send,
            "input_ControlAcknowledgeFrameNext(",
            "priv->cbs->on_event(",
            "input_ControlFinishFrameNextDelivery(")
    acknowledge = function_body(
        input_source, "void input_ControlAcknowledgeFrameNext(")
    require(acknowledge,
            "strict_frame_terminal_in_transit_request_id = request_id",
            "strict_frame_terminal_in_transit_generation = generation")
    finish_delivery = function_body(
        input_source, "void input_ControlFinishFrameNextDelivery(")
    require(finish_delivery,
            "strict_frame_terminal_in_transit_request_id = 0",
            "strict_frame_terminal_in_transit_generation = 0")

    # Timeshift handles replacement observations synchronously like the other
    # strict private controls; it must never fall into its unreachable default
    # or the delayed command format without preserving all three arguments.
    timeshift_control = function_body(es_out_timeshift,
                                      "static int PrivControlLocked(")
    replacement_case = timeshift_control[
        timeshift_control.find("case ES_OUT_PRIV_REQUEST_FRAME_NEXT_PICTURES:"):
        timeshift_control.find("case ES_OUT_PRIV_COMPLETE_FRAME_NEXT:")]
    require(replacement_case,
            "uint64_t request_id = va_arg(args, uint64_t);",
            "uint64_t generation = va_arg(args, uint64_t);",
            "uint64_t observation = va_arg(args, uint64_t);",
            "es_out_in_PrivControl(")

    # Strict SET/CANCEL and active-request causal resets have reserved capacity
    # but share one global sequence with ordinary controls. A new SET cannot
    # overtake a pending seek/resume/previous reset. Explicit cancel remains
    # immediately reusable because no reset-depth gate is used.
    strict_lane = function_body(input_source, "int input_ControlPushStrictFrame(")
    ordered(
        strict_lane,
        "type == INPUT_CONTROL_SET_FRAME_NEXT",
        "StrictFrameControlIsReset(",
        "return -EBUSY;",
    )
    ordered(strict_lane,
            "pending->i_type != INPUT_CONTROL_SET_FRAME_NEXT",
            "pending->param.frame_next.request_id")
    require(strict_lane, "pending->i_type == INPUT_CONTROL_SET_FRAME_NEXT")
    require(strict_lane,
            "sys->strict_frame_commit_claimed",
            "FrameNextTerminalContainsStrictLocked(",
            "return -EALREADY;")
    forbid(strict_lane,
           "--sys->frame_next_displayed_count",
           "frame_next_overflow_pending = false")
    forbid(strict_lane, "vlc_cond_wait")
    reset_lane = function_body(input_source, "int input_ControlPushStrictReset(")
    require(
        reset_lane,
        "StrictFrameControlIsReset(type)",
        "sys->is_stopped = true;",
        "vlc_interrupt_kill(&sys->interrupt);",
    )
    require(input_internal,
            "#define INPUT_STRICT_CONTROL_FIFO_SIZE 2",
            "#define INPUT_FRAME_NEXT_EVENT_INLINE_SIZE",
            "strict_frame_control[INPUT_STRICT_CONTROL_FIFO_SIZE]",
            "input_control_param_t *frame_next_displayed;",
            "frame_next_displayed_inline[",
            "frame_next_overflow_pending",
            "frame_next_force_terminal_allocation_failure",
            "strict_frame_active_request_id",
            "strict_frame_commit_claimed",
            "frame_next_force_commit_barrier",
            "frame_next_commit_waiting",
            "frame_next_force_terminal_pop_barrier",
            "strict_frame_terminal_in_transit_request_id",
            "uint64_t    sequence;",
            "uint64_t next_control_sequence;")
    reducer = function_body(input_source, "ControlGetReducedIndexLocked(")
    require(reducer,
            "prev_control->sequence == sys->next_control_sequence")
    require(reset_lane,
            "previous->sequence == sys->next_control_sequence")

    request = function_body(player, "int\nvlc_player_RequestNextVideoFrame(")
    require(
        request,
        "request_id == 0",
        "player->strict_frame_reset_depth != 0",
        "!input->started || !player->started",
        "input_ControlPushStrictFrame(",
        "push_ret == -EBUSY",
    )
    explicit_cancel = function_body(player, "bool\nvlc_player_CancelNextVideoFrame(")
    ordered(explicit_cancel,
            "player->strict_frame_request_commit_owned",
            "input_ControlPushStrictFrame(",
            "cancel_ret == -EALREADY",
            "player->strict_frame_request_commit_owned = true;",
            "return false;",
            "vlc_player_CompleteStrictNextVideoFrame(")
    forbid(explicit_cancel, "strict_frame_reset_depth")
    reset_cancel = function_body(
        player, "vlc_player_CancelNextVideoFrameOnInputReset(")
    ordered(
        reset_cancel,
        "player->strict_frame_reset_depth++;",
        "if (prior_reset_depth != 0)",
        "player->strict_frame_request_commit_owned",
        "input_ControlPushStrictFrame(",
        "cancel_ret == -EALREADY",
        "player->strict_frame_request_commit_owned = true;",
        "player->strict_frame_reset_preserves_commit = true;",
    )
    forbid(reset_cancel, "vlc_player_CompleteStrictNextVideoFrame(")
    reset_complete = function_body(
        player, "vlc_player_CompleteNextVideoFrameReset(")
    ordered(reset_complete,
            "!player->strict_frame_reset_preserves_commit",
            "vlc_player_CompleteStrictNextVideoFrame(",
            "--player->strict_frame_reset_depth;",
            "player->strict_frame_reset_preserves_commit = false;")
    stopping = function_body(player_input,
                             "vlc_player_input_HandleState(")
    stopping_case = stopping[stopping.find("case VLC_PLAYER_STATE_STOPPING:"):
                             stopping.find("case VLC_PLAYER_STATE_PLAYING:")]
    require(stopping_case,
            "vlc_player_CancelNextVideoFrameOnInputReset(",
            "player, input->thread",
            "player->input = NULL;",
            "vlc_player_CompleteNextVideoFrameReset(player);")
    previous_player = function_body(player, "vlc_player_PreviousVideoFrame(")
    ordered(
        previous_player,
        "vlc_player_CancelNextVideoFrameOnReset(player);",
        "input_ControlPushStrictReset(",
        "vlc_player_CompleteNextVideoFrameReset(player);",
    )
    require(previous_player, "input_ControlPushHelper(")
    resume = function_body(player, "static void\nvlc_player_SetPause(")
    ordered(resume, "vlc_player_CancelNextVideoFrameOnReset(player);",
            "input_ControlPushStrictReset(",
            "vlc_player_CompleteNextVideoFrameReset(player);")
    for signature in ("vlc_player_SeekByPos(", "vlc_player_SeekByTime("):
        seek = function_body(player, signature)
        ordered(seek, "vlc_player_CancelNextVideoFrameOnReset(player);",
                "strict_reset, true);")
    for signature in ("vlc_player_input_SeekByPos(",
                      "vlc_player_input_SeekByTime("):
        seek_input = function_body(player_input, signature)
        require(seek_input, "strict_reset_ordering",
                "complete_reset_scope",
                "input_ControlPushStrictReset(")
        ordered(seek_input, "input_ControlPushStrictReset(",
                "vlc_player_UpdateTimerSeekState(",
                "vlc_player_CompleteNextVideoFrameReset(player);")

    # The source checker proves lock/order structure only. Exact callback
    # order, cardinality, timestamp cadence, cancel/rebind, and quiescence are
    # behavioral requirements of the source-linked native probe; do not replace
    # them with a disconnected Python model.
    lifecycle_probe = function_body(
        native_probe, "run_committed_terminal_lifecycle_case(")
    require(
        lifecycle_probe,
        "await_exact_committed_submission(&stopped, 1200)",
        "libvlc_media_player_stop_async(stopped.player)",
        "const bool stopped_exact = lifecycle_exact_after_stop(&stopped, 1200)",
        "!stopped_exact",
        "libvlc_media_player_set_media(replace_claim.player, claim_replacement)",
        "!lifecycle_exact_after_stop(&replace_claim, 1205)",
        "set_terminal_pop_barrier(queued_stop_handle, true)",
        "libvlc_media_player_stop_async(queued_stop.player)",
        "!lifecycle_exact_after_stop(&queued_stop, 1206)",
        "set_terminal_pop_barrier(replacement_handle, true)",
        "libvlc_media_player_set_media(replaced.player, replacement)",
        "await_terminal_in_transit(transit_handle, 1220, 5000)",
        "libvlc_media_player_stop_async(transit.player)",
        "lifecycle_fixture_open_raw(&eof)",
        "input_ControlSetFrameNextNeedData(eof_handle.input, true)",
        "await_natural_eof_quiescing(eof_handle, 5000)",
        "wait_for_state(eof.player, libvlc_Stopped, 5000)",
        "check_committed_terminal(&eof.completion, 1, 1230)",
    )

    # Request-id zero remains on VLC's original public next-frame path and
    # keeps the historical playing -> -EAGAIN behavior.
    legacy = function_body(player, "void\nvlc_player_NextVideoFrame(")
    require(legacy, "input_ControlPush(")
    forbid(legacy, "input_ControlPushStrictFrame(")
    require(input_source, "param.frame_next.request_id == 0",
            "? -EAGAIN")

    # Built-in Apple output records only this Prepare's exact postflight-
    # validated helper submission. A rejected sample is never retained for
    # layer install or a later RenderPicture. The helper/cache/clock ordering
    # is mutation-tested above instead of accepting direct and helper strings
    # as interchangeable submission evidence.
    validate_apple_submission_contract(apple, vout)
    mutation_rejects_apple_submission_bypass_or_reordering(apple, vout)
    apple_init = function_body(apple, "- (instancetype)initWithVoutDisplay:")
    require(apple_init, "lastPictureSubmissionStatus = -EIO;")
    apple_prepare = function_body(apple, "static void Prepare (")
    require(apple_prepare,
            "sys->lastPictureSubmissionStatus = pic != NULL",
            ": -EIO;")
    apple_render = function_body(apple, "static int RenderPicture(")
    forbid(apple_render, "lastPictureSubmissionStatus")
    forbid(apple, "pendingSampleBuffer")
    require(apple_render,
            "return -EAGAIN;",
            "if (!renderer.isReadyForMoreMediaData)")
    apple_purge = function_body(apple, "static void PurgePictureSubmissions(")
    require(apple_purge,
            "@synchronized(sys.displayLayerLock)",
            "sys->lastPictureSubmissionStatus = -ECANCELED;",
            "atomic_fetch_add_explicit(&sys->overlayRefreshGeneration",
            "++sys->latestFrameSequence;",
            "sys->latestUncompositedPixelBuffer = NULL;",
            "if (discontinuity)",
            "[renderer flush];")
    require(apple,
            ".get_picture_submission_status = GetPictureSubmissionStatus",
            ".purge_picture_submissions = PurgePictureSubmissions")
    require(render,
            "vout_display_PurgePictureSubmissions(vd, false)")
    scoped_cancel = function_body(vout, "bool vout_CancelNextPictureStrict(")
    ordered(scoped_cancel,
            "--sys->frame_next_count;",
            "vlc_queuedmutex_lock(&sys->display_lock);",
            "vout_display_PurgePictureSubmissions(sys->display, false);",
            "vlc_queuedmutex_unlock(&sys->display_lock);")
    flush = function_body(vout, "static void vout_FlushUnlocked(")
    ordered(flush,
            "vlc_queuedmutex_lock(&sys->display_lock);",
            "vout_display_PurgePictureSubmissions(sys->display, true);",
            "vout_FilterFlush(sys->display);",
            "vlc_queuedmutex_unlock(&sys->display_lock);")
    require(vout_header,
            "purge_picture_submissions",
            "A false @a discontinuity",
            "queued module and renderer submissions",
            "vout_display_PurgePictureSubmissions")

    # vmem Open retains one immutable callback/setup/cleanup/opaque generation.
    # Combined publication allocates before swapping, so OOM and invalid
    # partial tuples leave the old generation live; clear publishes one fully
    # disabled tuple. Legacy setters also publish coherent generations.
    vmem_open = function_body(vmem, "static int Open(")
    require(vmem_open,
            'var_InheritAddress(vd, "vmem-configuration")',
            "swiftvlc_vmem_configuration_registry_Acquire(registry)",
            "sys->configuration->lock",
            "sys->configuration->unlock",
            "sys->configuration->display",
            "sys->configuration->display_status",
            "sys->configuration->setup_ex",
            "sys->configuration->cleanup",
            "sys->configuration->opaque")
    close_vmem = function_body(vmem, "static void Close(")
    ordered(close_vmem,
            "sys->cleanup(sys->opaque);",
            "swiftvlc_vmem_configuration_Release(sys->configuration);")
    vmem_prepare = function_body(vmem, "static void Prepare(")
    ordered(vmem_prepare, "sys->picture_ready = false;",
            "sys->submission_status = -EIO;",
            "sys->picture_ready = true;")
    vmem_display = function_body(vmem, "static void Display(")
    require(
        vmem_display,
        "sys->display_status(sys->opaque, sys->pic_opaque)",
        "VOUT_DISPLAY_PICTURE_SUBMISSION_UNPROVEN",
    )
    if vmem_display.count("VOUT_DISPLAY_PICTURE_SUBMISSION_UNPROVEN") != 2:
        raise AssertionError(
            "legacy vmem void and NULL-display paths must both be unproven")
    forbid(vmem_display, "var_InheritAddress", "submission_status = VLC_SUCCESS")

    publish_complete = function_body(
        vmem_configuration,
        "swiftvlc_vmem_configuration_registry_PublishComplete(")
    ordered(publish_complete,
            "atomic_load_explicit(&registry->force_allocation_failure",
            "return false;",
            "swiftvlc_vmem_configuration_NewEmpty();",
            "if (next == NULL)",
            "next->lock = lock;",
            "next->display_status = display_status;",
            "next->setup_ex = setup_ex;",
            "next->cleanup = cleanup;",
            "next->opaque = opaque;",
            "vlc_mutex_lock(&registry->lock);",
            "registry->current = next;",
            "vlc_mutex_unlock(&registry->lock);",
            "swiftvlc_vmem_configuration_Release(previous);")
    require(vmem_configuration,
            "atomic_bool force_allocation_failure;",
            "swiftvlc_vmem_configuration_registry_ForceAllocationFailure(",
            "atomic_store_explicit(&registry->force_allocation_failure")
    acquire_configuration = function_body(
        vmem_configuration,
        "swiftvlc_vmem_configuration_registry_Acquire(")
    ordered(acquire_configuration,
            "vlc_mutex_lock(&registry->lock);",
            "vlc_atomic_rc_inc(&configuration->rc);",
            "vlc_mutex_unlock(&registry->lock);")
    atomic_setter = function_body(
        media_player, "int swiftvlc_libvlc_video_set_callbacks_atomic(")
    ordered(atomic_setter,
            "if (!clearing && !enabling)",
            "return -EINVAL;",
            "swiftvlc_vmem_configuration_registry_PublishComplete(",
            "return -ENOMEM;",
            'var_SetAddress(mp, "vmem-lock", lock_cb);')
    require(atomic_setter,
            "lock_cb != NULL && display_status_cb != NULL &&",
            "setup_cb != NULL",
            "opaque == NULL")

    # Patch 0027's setters remain additive ABI v4. Later patches own their own
    # semantics, while this composition gate binds the exact shared extension
    # version selected by their complete, monotonically nested public markers.
    extension_sources = read_source_root(root)
    extension_resolution = resolve_extension_version(extension_sources)
    extension_mutations = run_extension_version_mutations(
        extension_sources, extension_resolution.version,
        extension_resolution.same_version_groups)
    if (extension_resolution.version >= 8
            and "apple-audio-session-leases"
            in extension_resolution.same_version_groups):
        vendored_include = (
            Path(__file__).resolve().parents[3]
            / "Sources/CLibVLC/include/vlc"
        )
        vendored_public_header = (
            vendored_include / "libvlc_media_player.h"
        ).read_text(encoding="utf-8")
        vendored_events_header = (
            vendored_include / "libvlc_events.h"
        ).read_text(encoding="utf-8")
        validate_vendored_headers(
            extension_sources, vendored_public_header,
            vendored_events_header, extension_resolution.version,
            extension_resolution.same_version_groups)
    require(media_player,
            "swiftvlc_libvlc_video_set_callbacks_atomic(",
            "sizeof(libvlc_event_t) == 40",
            "u.media_player_frame_step_completed.position) == 36")
    require(media_player_header,
            "Atomically install SwiftVLC's complete strict-capable vmem generation",
            "complete old tuple or the",
            "complete new tuple",
            "rejected without",
            "-EINVAL",
            "-ENOMEM",
            "swiftvlc_libvlc_video_set_callbacks_atomic")

    print("PASS strict frame-step source invariants "
          f"(integrated extension version {extension_resolution.version}; "
          f"version mutations {extension_mutations})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
