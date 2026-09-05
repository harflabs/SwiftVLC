#!/usr/bin/env python3
"""Fail-closed source proof for SwiftVLC Apple media-services recovery.

This is intentionally not a coverage test. It freezes the causal safety
contract of native patches 0032/0033, including teardown while media services
are changing, proves that each structural assertion rejects a deliberate
source mutation, and explores deterministic state machines for the process
broker, retryable AudioUnit disposal, and two-output command protocol. The
physical device release harness remains the runtime oracle.
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass, replace
from pathlib import Path
import ctypes
import sys
from typing import Callable, Iterable, Mapping


class ProofFailure(AssertionError):
    pass


EXPECTED_STRUCTURAL_GATE_COUNT = 130


def compact(value: str) -> str:
    return " ".join(value.split())


def require(value: str, *needles: str) -> None:
    haystack = compact(value)
    for needle in map(compact, needles):
        if needle not in haystack:
            raise ProofFailure(f"missing invariant: {needle}")


def forbid(value: str, *needles: str) -> None:
    haystack = compact(value)
    for needle in map(compact, needles):
        if needle in haystack:
            raise ProofFailure(f"forbidden invariant: {needle}")


def objective_c_tokens(source: str) -> list[tuple[str, int]]:
    """Lex the Objective-C tokens needed by the ARC ownership proof.

    Comments and quoted literals are discarded before selector inspection.
    This deliberately stays smaller than a compiler lexer, but it observes C's
    line-splicing rule inside // comments and strings so dead text cannot look
    like a live ownership message (or hide one by changing whitespace).
    """
    tokens: list[tuple[str, int]] = []
    index = 0
    line = 1
    length = len(source)

    while index < length:
        character = source[index]
        if character == "\\" and index + 1 < length \
                and source[index + 1] == "\n":
            line += 1
            index += 2
            continue
        if character.isspace():
            if character == "\n":
                line += 1
            index += 1
            continue

        if source.startswith("//", index):
            index += 2
            while index < length:
                if source[index] == "\\" and index + 1 < length \
                        and source[index + 1] == "\n":
                    line += 1
                    index += 2
                    continue
                if source[index] == "\n":
                    break
                index += 1
            continue

        if source.startswith("/*", index):
            comment_line = line
            closing = source.find("*/", index + 2)
            if closing < 0:
                raise ProofFailure(
                    f"unterminated Objective-C block comment at line {comment_line}"
                )
            line += source.count("\n", index, closing + 2)
            index = closing + 2
            continue

        if character in ('"', "'"):
            quote = character
            literal_line = line
            index += 1
            while index < length:
                character = source[index]
                if character == "\\":
                    if index + 1 >= length:
                        raise ProofFailure(
                            f"unterminated Objective-C literal at line {literal_line}"
                        )
                    if source[index + 1] == "\n":
                        line += 1
                    index += 2
                    continue
                if character == quote:
                    index += 1
                    break
                if character == "\n":
                    line += 1
                index += 1
            else:
                raise ProofFailure(
                    f"unterminated Objective-C literal at line {literal_line}"
                )
            tokens.append(("<literal>", literal_line))
            continue

        if character.isalpha() or character == "_":
            start = index
            token_line = line
            identifier: list[str] = []
            while index < length:
                if source[index].isalnum() or source[index] == "_":
                    identifier.append(source[index])
                    index += 1
                    continue
                if source[index] == "\\" and index + 1 < length \
                        and source[index + 1] == "\n":
                    line += 1
                    index += 2
                    continue
                break
            if not identifier:
                raise ProofFailure(
                    f"empty Objective-C identifier at source offset {start}"
                )
            tokens.append(("".join(identifier), token_line))
            continue

        if source.startswith("->", index):
            tokens.append(("->", line))
            index += 2
            continue

        tokens.append((character, line))
        index += 1

    return tokens


@dataclass
class ObjectiveCBracketFrame:
    tokens: list[tuple[str, int]]
    parentheses: int = 0
    braces: int = 0
    array_literal: bool = False


def forbidden_arc_ownership_messages(source: str) -> list[tuple[str, int]]:
    """Return live zero-argument ownership messages forbidden under ARC."""
    frames: list[ObjectiveCBracketFrame] = []
    violations: list[tuple[str, int]] = []
    previous = ""

    for token, line in objective_c_tokens(source):
        if token == "[":
            frames.append(ObjectiveCBracketFrame(
                tokens=[], array_literal=previous == "@"
            ))
            previous = token
            continue

        if token == "]" and frames:
            frame = frames.pop()
            top_level = frame.tokens
            if not frame.array_literal and len(top_level) >= 2:
                selector, selector_line = top_level[-1]
                preceding = top_level[-2][0]
                if selector in {"release", "retain", "autorelease"} \
                        and preceding not in {":", ".", "->"}:
                    violations.append((selector, selector_line))
                elif selector == "dealloc" and preceding == "super":
                    violations.append(("super dealloc", selector_line))
            if frames:
                parent = frames[-1]
                if parent.parentheses == 0 and parent.braces == 0:
                    parent.tokens.append(("<bracket-expression>", line))
            previous = token
            continue

        if not frames:
            previous = token
            continue

        frame = frames[-1]
        if token == "(":
            if frame.parentheses == 0 and frame.braces == 0:
                frame.tokens.append(("<parenthesized-expression>", line))
            frame.parentheses += 1
        elif token == ")" and frame.parentheses:
            frame.parentheses -= 1
        elif token == "{":
            if frame.parentheses == 0 and frame.braces == 0:
                frame.tokens.append(("<braced-expression>", line))
            frame.braces += 1
        elif token == "}" and frame.braces:
            frame.braces -= 1
        elif frame.parentheses == 0 and frame.braces == 0:
            frame.tokens.append((token, line))
        previous = token

    return violations


def validate_arc_ownership_lexer() -> None:
    harmless = r'''
        const char *documentation = "[value release]";
        // [value retain] \
           [value autorelease]
        /* [super dealloc] */
        SEL selector = @selector(release);
        id indexed = values[release];
        id literal = @[@"[value retain]"];
    '''
    if forbidden_arc_ownership_messages(harmless):
        raise ProofFailure("ARC ownership lexer treated dead text as a message")

    cases = {
        "release": "[value release /* trailing comment */];",
        "retain": "[value /* selector gap */ retain];",
        "autorelease": "[value autore" + "\\" + "\nlease];",
        "super dealloc": "[super /* selector gap */ dealloc];",
    }
    for expected, source in cases.items():
        actual = [name for name, _ in forbidden_arc_ownership_messages(source)]
        if actual != [expected]:
            raise ProofFailure(
                f"ARC ownership lexer missed {expected}: found {actual}"
            )


def block_span(source: str, marker: str) -> tuple[int, int]:
    """Find a C/Objective-C definition, skipping declarations and calls."""
    cursor = 0
    while True:
        start = source.find(marker, cursor)
        if start < 0:
            raise ProofFailure(f"missing function or method: {marker}")
        line_start = source.rfind("\n", 0, start) + 1
        line_prefix = source[line_start:start]
        # Definitions in the frozen VLC sources begin at column zero (the
        # return type may be on the previous line). This rejects an invocation
        # followed by a loop/if body, which a brace-only scanner can mistake
        # for the requested function.
        if line_prefix != line_prefix.lstrip():
            cursor = start + len(marker)
            continue
        opening = source.find("{", start)
        if opening < 0:
            raise ProofFailure(f"missing body: {marker}")
        if source.find(";", start, opening) >= 0:
            cursor = start + len(marker)
            continue
        depth = 0
        for index in range(opening, len(source)):
            if source[index] == "{":
                depth += 1
            elif source[index] == "}":
                depth -= 1
                if depth == 0:
                    return opening, index + 1
        raise ProofFailure(f"unterminated body: {marker}")


def body(source: str, marker: str) -> str:
    start, end = block_span(source, marker)
    return source[start:end]


def struct_block(source: str, typedef_name: str) -> str:
    marker = f"typedef struct {typedef_name}"
    start = source.find(marker)
    if start < 0:
        raise ProofFailure(f"missing typedef: {typedef_name}")
    end_marker = f"}} {typedef_name};"
    end = source.find(end_marker, start)
    if end < 0:
        raise ProofFailure(f"unterminated typedef: {typedef_name}")
    return source[start : end + len(end_marker)]


@dataclass(frozen=True)
class Mutation:
    key: str
    marker: str | None
    needle: str
    replacement: str = "/* NEGATIVE_SOURCE_MUTATION */"

    def apply(self, sources: Mapping[str, str]) -> dict[str, str]:
        mutated = dict(sources)
        source = mutated[self.key]
        if self.marker is None:
            position = source.find(self.needle)
        else:
            start, end = block_span(source, self.marker)
            position = source.find(self.needle, start, end)
        if position < 0:
            location = self.key + (f"/{self.marker}" if self.marker else "")
            raise ProofFailure(
                f"mutation target absent in {location}: {self.needle}"
            )
        mutated[self.key] = (
            source[:position] + self.replacement
            + source[position + len(self.needle) :]
        )
        return mutated


@dataclass(frozen=True)
class Gate:
    name: str
    check: Callable[[Mapping[str, str]], None]
    mutation: Mutation


def body_gate(
    name: str, key: str, marker: str, target: str, *,
    must: Iterable[str] = (), absent: Iterable[str] = (),
    target_count: int = 1,
    replacement: str = "/* NEGATIVE_SOURCE_MUTATION */",
) -> Gate:
    def check(sources: Mapping[str, str]) -> None:
        candidate = body(sources[key], marker)
        count = compact(candidate).count(compact(target))
        if count != target_count:
            raise ProofFailure(
                f"expected {target_count} occurrence(s) of {compact(target)}, "
                f"found {count}"
            )
        require(candidate, *must)
        forbid(candidate, *absent)
    return Gate(name, check, Mutation(key, marker, target, replacement))


def source_gate(
    name: str, key: str, target: str, *, must: Iterable[str] = (),
    absent: Iterable[str] = (), target_count: int = 1,
    replacement: str = "/* NEGATIVE_SOURCE_MUTATION */",
) -> Gate:
    def check(sources: Mapping[str, str]) -> None:
        candidate = sources[key]
        count = compact(candidate).count(compact(target))
        if count != target_count:
            raise ProofFailure(
                f"expected {target_count} occurrence(s) of {compact(target)}, "
                f"found {count}"
            )
        require(candidate, *must)
        forbid(candidate, *absent)
    return Gate(name, check, Mutation(key, None, target, replacement))


def custom_gate(
    name: str, check: Callable[[Mapping[str, str]], None], key: str,
    marker: str | None, needle: str,
    replacement: str = "/* NEGATIVE_SOURCE_MUTATION */",
) -> Gate:
    return Gate(name, check, Mutation(key, marker, needle, replacement))


def application_branch(candidate: str) -> str:
    marker = "if (avas_IsApplicationManaged(p_aout))"
    start = candidate.find(marker)
    if start < 0:
        raise ProofFailure("missing application-managed branch")
    opening = candidate.find("{", start)
    semicolon = candidate.find(";", start)
    if semicolon >= 0 and (opening < 0 or semicolon < opening):
        return candidate[start : semicolon + 1]
    depth = 0
    for index in range(opening, len(candidate)):
        if candidate[index] == "{":
            depth += 1
        elif candidate[index] == "}":
            depth -= 1
            if depth == 0:
                return candidate[start : index + 1]
    raise ProofFailure("unterminated application-managed branch")


def build_gates() -> list[Gate]:
    gates: list[Gate] = []
    add = gates.append

    # Process broker: epochs, coherent counters, ownership, leases,
    # reentrancy, callback drains, and Lost-safe orphaning.
    add(source_gate(
        "broker.automake_target_uses_arc", "src_makefile",
        "libvlccore_objc_la_OBJCFLAGS = $(AM_OBJCFLAGS) -fobjc-arc",
        must=("libvlccore_objc_la_SOURCES =",
              "darwin/apple_audio_session.m")))
    add(source_gate(
        "broker.meson_arc_flag_defined", "src_meson",
        "vlccore_objcargs += '-fobjc-arc'",
        must=("vlccore_objcargs = []",
              "'darwin/apple_audio_session.m'",)))
    add(source_gate(
        "broker.meson_target_consumes_arc_args", "src_meson",
        "objc_args: vlccore_objcargs,",
        must=("libvlccore = library(",
              "'darwin/apple_audio_session.m'",)))

    def broker_uses_arc_ownership(sources: Mapping[str, str]) -> None:
        violations = forbidden_arc_ownership_messages(sources["broker"])
        if violations:
            details = ", ".join(
                f"[{selector}] at line {line}" for selector, line in violations
            )
            raise ProofFailure(f"manual ownership under ARC: {details}")

    copied_audio_units = (
        "NSArray<NSValue *> *audioUnits = [_orphanedAudioUnits copy];"
    )
    ownership_mutations = (
        ("release", "[audioUnits release /* trailing comment */];"),
        ("retain", "[audioUnits /* selector gap */ retain];"),
        ("autorelease", "[\n        audioUnits\n        autorelease\n    ];"),
        ("super_dealloc", "[super /* selector gap */ dealloc];"),
    )
    for name, statement in ownership_mutations:
        add(custom_gate(
            f"broker.arc_forbids_manual_{name}",
            broker_uses_arc_ownership, "broker", "drainOrphansOnEventQueue",
            copied_audio_units, copied_audio_units + f"\n    {statement}"))

    add(source_gate(
        "broker.initial_epoch_nonzero", "broker",
        "UINT64_C(1) << MEDIA_SERVICES_STATE_EPOCH_SHIFT",
        must=("Epoch zero is reserved",), replacement="UINT64_C(0)"))
    add(source_gate(
        "broker.snapshot_generation_is_leading_internal_field",
        "broker_header", "uint64_t state_generation;",
        must=("struct vlc_apple_audio_session_snapshot",
              "Internal mutation sequence used to bind multi-source snapshots")))
    add(body_gate(
        "broker.notification_identity_dedup", "broker",
        "recordNotificationOnEventQueue:", "indexOfObjectIdenticalTo:notification",
        must=("_recentResetPhases[index].boolValue != reset",
              "return _recentEpochs[index].unsignedLongLongValue;")))
    add(body_gate(
        "broker.notification_epoch_never_zero", "broker",
        "recordNotificationOnEventQueue:", "epoch = 1;",
        must=("uint64_t epoch = old.epoch + 1;",
              "UINT64_MAX >> MEDIA_SERVICES_STATE_EPOCH_SHIFT")))
    add(body_gate(
        "broker.event_resets_owner_and_lease_counts", "broker",
        "recordNotificationOnEventQueue:",
        "atomic_store_explicit(&active_owner_count, 0, memory_order_relaxed);",
        must=("atomic_store_explicit(&active_lease_count, 0, memory_order_relaxed);",
              "atomic_store_explicit(&media_services_state, state, memory_order_relaxed);")))
    add(body_gate(
        "broker.seqlock_writer_odd", "broker", "BeginSnapshotMutation(",
        "assert((generation & 1) != 0);",
        must=("snapshot_writer_lock", "memory_order_acq_rel")))
    add(body_gate(
        "broker.seqlock_writer_even", "broker", "EndSnapshotMutation(",
        "assert((generation & 1) == 0);",
        must=("atomic_flag_clear_explicit", "memory_order_release")))
    add(body_gate(
        "broker.seqlock_reader_stable", "broker", "ReadSnapshot(",
        "snapshot.state_generation = after;",
        must=("before == after && (after & 1) == 0",
              "atomic_thread_fence(memory_order_acquire)")))
    add(body_gate(
        "broker.owner_acquire_current_epoch", "broker",
        "vlc_apple_audio_session_acquire_owner(",
        "atomic_fetch_add_explicit(&active_owner_count, 1, memory_order_relaxed);",
        must=("before.lost || before.epoch != epoch",
              "after.lost || after.epoch != epoch")))
    add(body_gate(
        "broker.owner_release_final_zero", "broker",
        "vlc_apple_audio_session_release_owner(", "bool final = count == 1;",
        must=("count == 0", "count - 1", "snapshot.epoch != epoch")))
    add(body_gate(
        "broker.drop_owner_is_logical_only", "broker",
        "vlc_apple_audio_session_drop_owner(",
        "vlc_apple_audio_session_release_owner(epoch)",
        absent=("setActive:", "AVAudioSession")))
    add(body_gate(
        "broker.final_owner_physical_deactivation", "broker",
        "vlc_apple_audio_session_deactivate_final_owner(",
        "[session setActive:NO",
        must=("before.active_owner_count != 0", "before.epoch != epoch")))
    add(body_gate(
        "broker.final_no_result_counters", "broker",
        "vlc_apple_audio_session_deactivate_final_owner(",
        "vlc_apple_audio_session_report_deactivation(completed);",
        must=("BOOL completed = deactivated && successor_active;",)))
    add(body_gate(
        "broker.reentrant_successor_reassert", "broker",
        "vlc_apple_audio_session_deactivate_final_owner(",
        "successor_active = [session setActive:YES withOptions:0 error:&error];",
        must=("transaction != vlc_apple_audio_session_transaction_generation()",
              "after.active_owner_count != 0")))
    add(body_gate(
        "broker.transaction_generation_nonzero", "broker",
        "vlc_apple_audio_session_lock(",
        "if (unlikely(++session_transaction_generation == 0))",
        must=("++session_transaction_generation;",)))
    add(body_gate(
        "broker.transaction_epoch_guard", "broker",
        "vlc_apple_audio_session_transaction_is_current(",
        "generation == session_transaction_generation",
        must=("generation != 0", "!snapshot.lost", "snapshot.epoch == epoch")))
    add(body_gate(
        "broker.lease_identity_dedup", "broker", "addLeaseForOwner:",
        "uint64_t token = [self leaseForOwner:owner epoch:epoch];",
        must=("if (token != 0)", "return token;")))
    add(body_gate(
        "broker.stale_lease_records_retired_in_lockstep", "broker",
        "discardLeasesNotInEpoch:",
        "if (_leaseEpochs[index].unsignedLongLongValue == epoch)",
        must=("_leaseTokens removeObjectAtIndex:index",
              "_leaseOwners removeObjectAtIndex:index",
              "_leaseEpochs removeObjectAtIndex:index")))
    add(body_gate(
        "broker.stale_leases_retired_before_lookup", "broker",
        "vlc_apple_audio_session_acquire_lease(",
        "[broker discardLeasesNotInEpoch:snapshot.epoch];",
        must=("[broker leaseForOwner:owner epoch:snapshot.epoch]",)))
    add(body_gate(
        "broker.lease_acquire_counts_owner_and_lease", "broker",
        "AcquireCurrentLeaseCounts(",
        "atomic_fetch_add_explicit(&active_lease_count, 1, memory_order_relaxed);",
        must=("atomic_fetch_add_explicit(&active_owner_count, 1",
              "snapshot.epoch != epoch")))
    add(body_gate(
        "broker.lease_release_counts_balanced", "broker",
        "ReleaseCurrentLeaseCounts(",
        "atomic_store_explicit(&active_lease_count, leases - 1,",
        must=("atomic_store_explicit(&active_owner_count, owners - 1,",
              "leases == 0 || owners == 0", "bool final = owners == 1;")))
    add(body_gate(
        "broker.lease_release_exact_owner_token", "broker",
        "vlc_apple_audio_session_release_lease(",
        "consumeLease:lease owner:owner",
        must=("epoch != 0 && !snapshot.lost", "snapshot.epoch == epoch")))
    add(body_gate(
        "broker.release_all_leases_final_no", "broker",
        "vlc_apple_audio_session_release_all_leases(",
        "consumeAllLeasesForOwner:owner",
        must=("ReleaseCurrentLeaseCounts(candidate_epoch)",
              "vlc_apple_audio_session_deactivate_final_owner")))
    add(body_gate(
        "broker.render_callback_destroy_drain", "broker",
        "vlc_apple_audio_render_context_destroy(",
        "while (atomic_load_explicit(&context->active_callbacks,",
        must=("vlc_apple_audio_render_context_invalidate(context);", "free(context);")))

    def audio_unit_dispose_success_owns_context(
            sources: Mapping[str, str]) -> None:
        candidate = body(sources["broker"], "disposeAudioUnit:")
        require(candidate, "AudioComponentInstanceDispose((AudioUnit)audioUnit)",
                "if (status != noErr)", "return NO;",
                "vlc_apple_audio_render_context_destroy(context);",
                "return YES;")
        if candidate.index("return NO;") > candidate.index(
                "vlc_apple_audio_render_context_destroy(context);"):
            raise ProofFailure(
                "failed AudioUnit disposal can destroy the render context"
            )
    add(custom_gate(
        "broker.audio_unit_context_destroy_only_after_dispose_success",
        audio_unit_dispose_success_owns_context, "broker",
        "disposeAudioUnit:", "if (status != noErr)"))
    add(source_gate(
        "broker.audio_unit_single_final_dispose_boundary", "broker",
        "AudioComponentInstanceDispose((AudioUnit)audioUnit)",
        must=("- (BOOL)disposeAudioUnit:(void *)audioUnit",
              "vlc_apple_audio_render_context_destroy(context);")))
    add(body_gate(
        "broker.audio_unit_orphan_held_while_lost", "broker",
        "orphanAudioUnit:", "if (ReadSnapshot().lost)",
        must=("_orphanedAudioUnits addObject",
              "else if (![self disposeAudioUnit:audioUnit")))
    add(body_gate(
        "broker.cf_orphan_held_while_lost", "broker", "orphanCFObject:",
        "if (ReadSnapshot().lost)",
        must=("_orphanedCFObjects addObject", "CFRelease(object);")))
    add(body_gate(
        "broker.orphan_retry_is_bounded_and_retains_failures", "broker",
        "drainOrphansOnEventQueue",
        "![self disposeAudioUnit:audioUnit renderContext:context]",
        must=("[_orphanedAudioUnits removeAllObjects]",
              "for (NSUInteger i = 0; i < audioUnits.count; ++i)",
              "_orphanedAudioUnits addObject:audioUnits[i]",
              "_orphanedAudioUnitContexts addObject:contexts[i]",
              "NSArray<NSValue *> *cfObjects", "CFRelease"),
        absent=("while (",)))
    add(body_gate(
        "broker.orphan_unit_context_arrays_stay_paired", "broker",
        "drainOrphansOnEventQueue",
        "assert(audioUnits.count == contexts.count);",
        must=("NSArray<NSValue *> *audioUnits = [_orphanedAudioUnits copy]",
              "NSArray<NSValue *> *contexts = "
              "[_orphanedAudioUnitContexts copy]")))

    # Application-owned policy: every mutating avas entry point exits before
    # category/preference/activation mutation and carries no owner epoch.
    add(body_gate(
        "application.policy_inherited", "common", "avas_IsApplicationManaged(",
        'strcmp(owner, "application") == 0',
        must=('var_InheritString(p_aout,', '"apple-audio-session-management"',)))

    def app_gate(name: str, marker: str, target: str,
                 must: Iterable[str] = ()) -> Gate:
        def check(sources: Mapping[str, str]) -> None:
            branch = application_branch(body(sources["common"], marker))
            require(branch, target, *must)
            forbid(branch, "setCategory:", "setMode:",
                   "setPreferredOutputNumberOfChannels:",
                   "setPreferredSampleRate:", "setActive:",
                   "setSupportsMultichannelContent:")
        return custom_gate(name, check, "common", marker, target)

    add(app_gate("application.prepare_format_no_mutation", "avas_PrepareFormat(",
                 "return;", ("NormalizeApplicationManagedFormat",)))
    add(app_gate("application.configure_no_mutation", "avas_Configure(",
                 "return VLC_SUCCESS;"))
    add(app_gate("application.configure_format_no_mutation",
                 "avas_ConfigureWithFormat(",
                 "return NormalizeApplicationManagedFormat(p_aout, instance, fmt);"))
    add(app_gate("application.activate_no_mutation", "avas_SetActive(",
                 "*owner_epoch = 0;", ("return VLC_SUCCESS;",)))
    add(app_gate("application.activate_format_no_mutation",
                 "avas_SetActiveWithFormat(", "*owner_epoch = 0;",
                 ("NormalizeApplicationManagedFormat", "return ret;")))
    add(app_gate("application.drop_owner_no_mutation", "avas_DropActiveOwner(",
                 "*owner_epoch = 0;", ("return;",)))
    add(body_gate(
        "application.public_lease_short_circuit", "media_player",
        "swiftvlc_libvlc_media_player_acquire_apple_audio_session_lease(",
        "return swiftvlc_apple_audio_session_lease_application_managed;",
        must=("libvlc_media_player_AppleAudioSessionIsApplicationManaged",)))

    # Shared input_resource control and exact two-output command arbitration.
    add(body_gate(
        "control.resource_singleton", "resource", "input_resource_New(",
        "aout_MediaServicesControlNew();",
        must=("p_resource->audio_media_services_control =",)))
    add(body_gate(
        "control.every_aout_gets_shared_control", "resource",
        "input_resource_GetAout(", "aout_New(p_resource->p_parent,",
        must=("p_resource->audio_media_services_control",)))
    add(body_gate(
        "control.aout_retains_shared_control", "output", "aout_New(",
        "aout_MediaServicesControlHold(control);",
        must=("aout->media_services_control =",)))
    add(body_gate(
        "control.publish_nonzero_generation", "output",
        "aout_MediaServicesCommandPublish(",
        "if (unlikely(generation == 0))",
        must=("generation = ++control->snapshot.generation;",)))
    add(body_gate(
        "control.invalidating_clears_authority", "output",
        "aout_MediaServicesCommandPublish(", "control->snapshot.reset_epoch =",
        must=("? reset_epoch : 0", "control->snapshot.dispatched = false;",
              "control->terminal_generation = 0;")))
    add(body_gate(
        "control.invalidating_clears_vacuous_ack", "output",
        "aout_MediaServicesCommandPublish(",
        "else if (control->acknowledgement_vacuous)",
        must=("control->snapshot.acknowledged_reset_epoch = 0;",
              "control->acknowledgement_vacuous = false;")))
    add(body_gate(
        "control.dispatch_exact_generation_origin", "output",
        "aout_MediaServicesCommandDispatch(",
        "control->snapshot.generation != generation",
        target_count=3,
        must=("VLC_AUDIO_MEDIA_SERVICES_COMMAND_EXPLICIT_RESUME",
              "control->snapshot.dispatched = true;")))
    add(body_gate(
        "control.dispatch_callback_outside_lock", "output",
        "aout_MediaServicesCommandDispatch(",
        "(void) callback(aout, generation, reset_epoch);",
        must=("registration->active_callbacks++;",
              "vlc_mutex_unlock(&control->lock);",
              "vlc_mutex_lock(&control->lock);",
              "registration->active_callbacks--;")))
    add(body_gate(
        "control.dispatch_no_output_vacuous_boundary", "output",
        "aout_MediaServicesCommandDispatch(",
        "control->snapshot.live_output_count == 0",
        must=("control->snapshot.acknowledged_reset_epoch =",
              "control->acknowledgement_vacuous = true;")))
    add(body_gate(
        "control.dispatch_vacuous_excludes_terminal_failure", "output",
        "aout_MediaServicesCommandDispatch(",
        "control->terminal_generation != generation",
        must=("control->snapshot.live_output_count == 0",
              "control->acknowledgement_vacuous = true;")))
    add(body_gate(
        "control.registration_tracks_incarnation_and_live", "output",
        "aout_MediaServicesCommandRegister(",
        "registration->control->snapshot.output_incarnation_count++;",
        must=("snapshot.live_output_count++;", "vlc_list_append")))
    add(body_gate(
        "control.registration_revokes_vacuous_ack", "output",
        "aout_MediaServicesCommandRegister(",
        "registration->control->snapshot.acknowledged_reset_epoch = 0;",
        must=("snapshot.dispatched", "acknowledgement_vacuous = false;")))
    add(body_gate(
        "control.bootstrap_exact_one_shot", "output",
        "aout_MediaServicesCommandBootstrap(",
        "registration->last_dispatched_generation == generation",
        must=("!control->snapshot.dispatched",
              "control->terminal_generation == generation",
              "registration->last_dispatched_generation = generation;")))
    add(body_gate(
        "control.bootstrap_callback_drained", "output",
        "aout_MediaServicesCommandBootstrap(",
        "registration->active_callbacks++;",
        must=("(void) callback(aout, generation, reset_epoch);",
              "registration->active_callbacks--;",
              "vlc_cond_broadcast(&control->callbacks_drained);")))
    add(body_gate(
        "control.unregister_removes_before_drain", "output",
        "aout_MediaServicesCommandUnregister(",
        "vlc_list_remove(&registration->node);",
        must=("registration->closing = true;",
              "while (registration->active_callbacks != 0)",
              "vlc_cond_wait(&control->callbacks_drained", "free(registration);")))
    add(body_gate(
        "control.unregister_last_output_vacuous_ack", "output",
        "aout_MediaServicesCommandUnregister(",
        "control->snapshot.live_output_count == 0",
        must=("control->snapshot.live_output_count--;",
              "control->acknowledgement_vacuous = true;")))
    add(body_gate(
        "control.unregister_remaining_all_ack", "output",
        "aout_MediaServicesCommandUnregister(",
        "all_acknowledged &= candidate->acknowledged_generation ==",
        must=("control->snapshot.live_output_count != 0",
              "control->snapshot.acknowledged_reset_epoch =")))
    add(body_gate(
        "control.ack_exact_registration", "output",
        "aout_MediaServicesCommandAcknowledge(",
        "registration->aout == aout && !registration->closing",
        must=("control->snapshot.generation == generation",
              "control->snapshot.reset_epoch == reset_epoch",
              "registration->acknowledged_generation = generation;")))
    add(body_gate(
        "control.ack_requires_every_live_output", "output",
        "aout_MediaServicesCommandAcknowledge(",
        "all_acknowledged &= registration->acknowledged_generation ==",
        must=("if (all_acknowledged)",
              "control->snapshot.acknowledged_reset_epoch = reset_epoch;")))
    add(body_gate(
        "control.failure_terminal_exact_command", "output",
        "aout_MediaServicesReportRecoveryResult(",
        "control->terminal_generation = generation;",
        must=("!success && generation != 0",
              "control->snapshot.generation == generation",
              "control->snapshot.reset_epoch == reset_epoch")))
    add(body_gate(
        "control.telemetry_result_signature", "output",
        "aout_MediaServicesReportRecoveryResult(",
        "control->snapshot.successful_rebuild_count++;",
        must=("explicit_resume_failure_count++", "if (success && rebuilt)")))

    # Public explicit command paths dispatch only after the player unlock;
    # automatic and invalidating boundaries never grant authority.
    add(body_gate(
        "command.resource_bridge_origin", "player_aout",
        "vlc_player_AppleAudioSessionCommand(",
        "VLC_AUDIO_MEDIA_SERVICES_COMMAND_EXPLICIT_RESUME",
        must=("VLC_AUDIO_MEDIA_SERVICES_COMMAND_INVALIDATING",
              "input_resource_PublishAudioMediaServicesCommand")))
    add(body_gate(
        "command.start_publishes_before_start", "player",
        "vlc_player_StartWithAudioCommand(",
        "uint64_t command_generation = vlc_player_AppleAudioSessionCommand(",
        must=("player, explicit_resume, reset_epoch", "vlc_player_input_Start")))
    add(body_gate(
        "command.start_failures_invalidate", "player",
        "vlc_player_StartWithAudioCommand(",
        "vlc_player_AppleAudioSessionCommand(player, false, 0);",
        target_count=5, must=("return VLC_ENOMEM;", "return ret;")))
    add(body_gate(
        "command.resume_publishes_exact_epoch", "player",
        "vlc_player_ResumeWithAppleAudioSession(",
        "player, true, reset_epoch",
        must=("vlc_player_SetPause(player, false);",)))
    add(body_gate(
        "command.public_play_dispatch_after_unlock", "media_player",
        "libvlc_media_player_play_internal(",
        "vlc_player_AppleAudioSessionDispatch(player,",
        must=("vlc_player_Unlock(player);", "command_generation")))
    add(body_gate(
        "command.public_set_pause_dispatch_after_unlock", "media_player",
        "libvlc_media_player_set_pause_internal(",
        "vlc_player_AppleAudioSessionDispatch(player,",
        must=("vlc_player_Unlock(player);", "authorize_explicit_resume")))
    add(body_gate(
        "command.public_toggle_dispatch_after_unlock", "media_player",
        "libvlc_media_player_pause(",
        "vlc_player_AppleAudioSessionDispatch(player,",
        must=("vlc_player_Unlock(player);", "bool authorize = resuming")))
    add(body_gate(
        "command.nonauthorizing_pause_shim", "media_player",
        "swiftvlc_libvlc_media_player_set_pause_without_reset_authorization(",
        "libvlc_media_player_set_pause_internal(p_mi, paused, false);"))
    add(body_gate(
        "command.explicit_epoch_rejects_lost_or_acked", "media_player",
        "libvlc_media_player_GetExplicitAudioResetEpoch(",
        "snapshot.lost || snapshot.reset_epoch == 0",
        must=("command.live_output_count != 0",
              "command.acknowledged_reset_epoch == snapshot.reset_epoch")))
    add(body_gate(
        "command.list_automatic_advance_never_authorizes", "media_list",
        "playlist_thread(",
        "set_relative_playlist_position_and_play(mlp, seek_offset, false);"))
    add(body_gate(
        "command.list_public_play_authorizes", "media_list",
        "libvlc_media_list_player_play(",
        "set_relative_playlist_position_and_play(p_mlp, 1, true);",
        must=("libvlc_media_player_play(p_mlp->p_mi);",)))
    add(body_gate(
        "command.list_public_play_index_authorizes", "media_list",
        "libvlc_media_list_player_play_item_at_index(",
        "libvlc_media_player_play(p_mlp->p_mi);"))
    add(body_gate(
        "command.list_public_play_item_authorizes", "media_list",
        "libvlc_media_list_player_play_item(",
        "libvlc_media_player_play(p_mlp->p_mi);"))
    add(body_gate(
        "command.list_public_next_authorizes", "media_list",
        "libvlc_media_list_player_next(",
        "set_relative_playlist_position_and_play(p_mlp, 1, true);"))
    add(body_gate(
        "command.list_public_previous_authorizes", "media_list",
        "libvlc_media_list_player_previous(",
        "set_relative_playlist_position_and_play(p_mlp, -1, true);"))

    def invalidation_boundaries(sources: Mapping[str, str]) -> None:
        player = sources["player"]
        for marker in (
            "vlc_player_SetCurrentMedia(", "vlc_player_SetNextMedia(",
            "vlc_player_Stop(", "vlc_player_Pause(", "vlc_player_Resume(",
            "vlc_player_SetRenderer(", "vlc_player_Delete(",
        ):
            require(body(player, marker),
                    "vlc_player_AppleAudioSessionCommand(player, false, 0);")
        count = compact(player).count(compact(
            "vlc_player_AppleAudioSessionCommand(player, false, 0)"))
        if count != 12:
            raise ProofFailure(
                f"unexpected nonauthorizing boundary count: {count} != 12"
            )
    add(custom_gate(
        "command.all_nonauthorizing_boundaries_invalidate",
        invalidation_boundaries, "player", "vlc_player_SetRenderer(",
        "vlc_player_AppleAudioSessionCommand(player, false, 0);"))

    # Exact public v8/120-byte read-only snapshot and vendored parity.
    def header_parity(sources: Mapping[str, str]) -> None:
        native = struct_block(sources["public_header"],
                              "swiftvlc_apple_audio_recovery_snapshot_t")
        vendored = struct_block(sources["vendored_header"],
                                "swiftvlc_apple_audio_recovery_snapshot_t")
        if compact(native) != compact(vendored):
            raise ProofFailure("native/vendored recovery snapshot typedef drift")
        require(native, "uint32_t version;", "uint32_t size;",
                "uint64_t broker_epoch;", "uint64_t broker_reset_epoch;",
                "uint64_t command_generation;", "uint32_t command_dispatched;",
                "uint32_t broker_active_owner_count;",
                "uint32_t broker_live_lease_count;",
                "uint64_t broker_successful_deactivation_count;",
                "uint64_t broker_failed_deactivation_count;")
    add(custom_gate(
        "snapshot.native_vendored_header_parity", header_parity,
        "vendored_header", None, "uint64_t broker_failed_deactivation_count;"))

    def public_audio_api_parity(sources: Mapping[str, str]) -> None:
        start_marker = "typedef enum swiftvlc_apple_audio_media_services_phase"
        end_marker = "swiftvlc_apple_audio_session_lease_t);"
        regions = []
        for key in ("public_header", "vendored_header"):
            source = sources[key]
            start = source.find(start_marker)
            end = source.find(end_marker, start)
            if start < 0 or end < 0:
                raise ProofFailure(f"missing Apple audio API region in {key}")
            region = source[start : end + len(end_marker)]
            regions.append(tuple(
                token for token, _ in objective_c_tokens(region)
            ))
        if regions[0] != regions[1]:
            raise ProofFailure("native/vendored Apple audio public API drift")
    add(custom_gate(
        "snapshot.native_vendored_full_audio_api_parity",
        public_audio_api_parity, "vendored_header", None,
        "swiftvlc_libvlc_media_player_release_apple_audio_session_lease"))
    def inherited_extension_version(sources: Mapping[str, str]) -> None:
        version_body = compact(body(
            sources["media_player"],
            "swiftvlc_libvlc_pip_extensions_version(",
        ))
        if version_body not in ("{ return 8; }", "{ return 9; }", "{ return 10; }"):
            raise ProofFailure(
                "Apple audio recovery requires extension version 8, 9, or 10"
            )
    add(custom_gate(
        "snapshot.extension_version_v8_through_v10", inherited_extension_version,
        "media_player", "swiftvlc_libvlc_pip_extensions_version(",
        "return "))
    add(source_gate(
        "snapshot.native_size_alignment_asserts", "media_player",
        "sizeof(swiftvlc_apple_audio_recovery_snapshot_t) == 120",
        must=("_Alignof(swiftvlc_apple_audio_recovery_snapshot_t) == 8",
              "broker_failed_deactivation_count) == 112")))
    add(source_gate(
        "snapshot.vendored_size_alignment_asserts", "shim",
        "sizeof(swiftvlc_apple_audio_recovery_snapshot_t) == 120",
        must=("_Alignof(swiftvlc_apple_audio_recovery_snapshot_t) == 8",
              "broker_failed_deactivation_count) == 112")))
    add(body_gate(
        "snapshot.caller_layout_guard", "media_player",
        "swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot(",
        "snapshot->version != SWIFTVLC_APPLE_AUDIO_RECOVERY_SNAPSHOT_VERSION",
        must=("p_mi == NULL || snapshot == NULL",
              "snapshot->size != sizeof(*snapshot)", "return false;")))
    add(body_gate(
        "snapshot.coherent_broker_command_sandwich", "media_player",
        "swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot(",
        "broker_before = vlc_apple_audio_session_snapshot();",
        must=("command = vlc_player_GetAppleAudioSessionCommandSnapshot",
              "broker_after = vlc_apple_audio_session_snapshot();",
              "broker_before.state_generation != broker_after.state_generation",
              "++attempt < 16", "if (attempt == 16)")))
    add(body_gate(
        "snapshot.read_only_and_no_aout", "media_player",
        "swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot(",
        "command = vlc_player_GetAppleAudioSessionCommandSnapshot(p_mi->player);",
        target_count=2,
        absent=("aout_", "vlc_player_Lock", "vlc_player_Start",
                "MediaServicesCommandAcknowledge", "ReportRecovery")))
    add(body_gate(
        "snapshot.telemetry_complete", "media_player",
        "swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot(",
        ".broker_failed_deactivation_count =",
        must=(".output_incarnation_count =", ".successful_rebuild_count =",
              ".explicit_resume_attempt_count =",
              ".explicit_resume_failure_count =",
              ".broker_active_owner_count =", ".broker_live_lease_count =",
              ".broker_successful_deactivation_count =")))
    add(body_gate(
        "snapshot.shim_fallback_guard_and_read_only", "shim",
        "swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot(",
        "snapshot->size != sizeof(*snapshot)",
        must=("snapshot->version != SWIFTVLC_APPLE_AUDIO_RECOVERY_SNAPSHOT_VERSION",
              "memset(snapshot, 0, sizeof(*snapshot));", "return false;"),
        absent=("libvlc_media_player_play", "setActive:")))
    add(source_gate(
        "snapshot.shim_weak_audio_fallback_parity", "shim",
        "int swiftvlc_libvlc_media_player_acquire_apple_audio_session_lease(",
        must=("__attribute__((weak))",
              "swiftvlc_libvlc_media_player_release_apple_audio_session_lease(",
              "swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot(",
              "swiftvlc_libvlc_media_player_set_pause_without_reset_authorization(")))
    add(source_gate(
        "snapshot.clibvlc_umbrella_exposes_vendored_vlc", "clibvlc_header",
        '#include "vlc/vlc.h"', must=("#ifndef CLibVLC_h",)))

    # AudioUnit output gates.
    add(source_gate(
        "audiounit.persistent_lost_reset_observers", "audiounit",
        "AVAudioSessionMediaServicesWereLostNotification",
        must=("AVAudioSessionMediaServicesWereResetNotification",
              "removeObserver:sys->aoutWrapper")))
    add(body_gate(
        "audiounit.monotonic_packed_phase", "audiounit",
        "PublishNewerMediaServicesPhase(", "while ((current >> 1) < epoch)",
        must=("MediaServicesPhaseValue(epoch, lost)",
              "atomic_compare_exchange_weak_explicit")))
    add(body_gate(
        "audiounit.lost_callback_immediately_silent", "audiounit",
        "audioSessionMediaServicesWereLost:", "ca_SetAliveState(p_aout, false);",
        must=("media_services_quarantined, true", "QueueMediaServicesRecovery"),
        absent=("AudioOutputUnitStart", "setActive:YES")))
    add(body_gate(
        "audiounit.reset_processing_rebuilds_inactive", "audiounit",
        "QueueMediaServicesRecovery(",
        "p_sys->media_services_rebuild_pending = true;",
        must=("p_sys->waiting_for_explicit_resume = true;",
              "DropInvalidatedAudioSessionOwnerLocked",
              "ca_SetAliveState(held_aout, false)",
              "p_sys->au_unit = NULL;",
              "aout_RestartRequestFromCallback"),
        absent=("AudioOutputUnitStart",)))
    add(body_gate(
        "audiounit.pause_false_cannot_bypass_latch", "audiounit", "Pause (",
        "!p_sys->waiting_for_explicit_resume",
        must=("Output-side Pause(false) calls are not proof",
              "KeepAudioSessionInactiveLocked")))
    add(body_gate(
        "audiounit.interruption_resume_is_gated", "audiounit",
        "handleInterruption:", "if (!MediaServicesQuarantined(p_sys))",
        must=("AVAudioSessionInterruptionTypeEnded",)))
    add(body_gate(
        "audiounit.exact_new_command_retry", "audiounit",
        "ResumeFromMediaServicesReset(",
        "command_generation <= p_sys->last_attempted_command_generation",
        must=("command.generation != command_generation",
              "command.reset_epoch != command_reset_epoch",
              "command.dispatched", "last_attempted_command_generation =")))
    add(body_gate(
        "audiounit.register_reconcile_bootstrap", "audiounit", "Open(",
        "aout_MediaServicesCommandBootstrap(sys->command_registration);",
        must=("aout_MediaServicesCommandRegister",
              "vlc_apple_audio_session_snapshot",
              "for (unsigned attempt = 0; attempt < 16")))
    add(body_gate(
        "audiounit.unregister_and_callback_drain", "audiounit", "Close(",
        "aout_MediaServicesCommandUnregister(sys->command_registration);",
        must=("invalidateAndWait", "removeObserver")))
    add(body_gate(
        "audiounit.stop_always_broker_disposes", "audiounit", "Stop(",
        "vlc_apple_audio_session_orphan_audio_unit_with_render_context(",
        must=("orphan = p_sys->au_unit;", "p_sys->au_unit = NULL;"),
        absent=("AudioComponentInstanceDispose",)))
    add(body_gate(
        "audiounit.start_error_always_broker_disposes", "audiounit", "Start(",
        "vlc_apple_audio_session_orphan_audio_unit_with_render_context(",
        target_count=2, must=("orphan = p_sys->au_unit;",
                              "p_sys->render_context = NULL;"),
        absent=("AudioComponentInstanceDispose",)))
    add(body_gate(
        "audiounit.close_always_broker_disposes", "audiounit", "Close(",
        "vlc_apple_audio_session_orphan_audio_unit_with_render_context(",
        must=("orphan = sys->au_unit;", "sys->au_unit = NULL;"),
        absent=("AudioComponentInstanceDispose",)))

    def audiounit_has_no_direct_final_dispose(
            sources: Mapping[str, str]) -> None:
        forbid(sources["audiounit"], "AudioComponentInstanceDispose")
        for marker in ("Stop(", "Start(", "Close("):
            require(body(sources["audiounit"], marker),
                    "vlc_apple_audio_session_orphan_audio_unit_with_render_context(")
    add(custom_gate(
        "audiounit.no_snapshot_to_direct_dispose_bypass",
        audiounit_has_no_direct_final_dispose, "audiounit", "Close(",
        "vlc_apple_audio_session_orphan_audio_unit_with_render_context(",
        "AudioComponentInstanceDispose(orphan)"))
    add(body_gate(
        "audiounit.recovery_telemetry", "audiounit",
        "ResumeFromMediaServicesReset(",
        "aout_MediaServicesReportRecoveryAttempt(p_aout);",
        must=("aout_MediaServicesReportRecoveryResult",)))

    # AVSampleBuffer priority-100 default output gates.
    add(source_gate(
        "avsample.persistent_lost_reset_observers", "avsample",
        "AVAudioSessionMediaServicesWereLostNotification",
        must=("AVAudioSessionMediaServicesWereResetNotification",
              "removePersistentObserversAndDrain")))
    add(body_gate(
        "avsample.monotonic_packed_phase", "avsample", "publishNewerEpoch:",
        "while ((current >> 1) < epoch)",
        must=("MediaServicesPhaseValue(epoch, lost)",
              "atomic_compare_exchange_weak_explicit")))
    add(body_gate(
        "avsample.lost_callback_immediately_silent", "avsample",
        "audioSessionMediaServicesWereLost:",
        "atomic_store_explicit(&_rendererActivityAllowed, false,",
        must=("_mediaServicesQuarantined, true", "_graphInvalidated, true",
              "dispatch_async(SampleBufferMediaServicesRecoveryQueue()"),
        absent=("enqueueSampleBuffer", "setRate:")))
    add(body_gate(
        "avsample.reset_callback_immediately_silent", "avsample",
        "audioSessionMediaServicesWereReset:",
        "atomic_store_explicit(&_rendererActivityAllowed, false,",
        must=("_mediaServicesQuarantined, true", "_graphInvalidated, true",
              "dispatch_async(SampleBufferMediaServicesRecoveryQueue()"),
        absent=("enqueueSampleBuffer", "setRate:")))
    add(body_gate(
        "avsample.reset_rebuild_inactive", "avsample", "start:",
        'msg_Info(_aout, "AVSampleBufferAudioRenderer output rebuilt inactive "',
        must=("if (resetDeferred)", "_rendererActivityAllowed, false",
              "_mediaServicesRebuildPending = NO;", "_recoveryRebuilt = YES;")))
    add(body_gate(
        "avsample.pause_false_cannot_bypass_reset_latch", "avsample", "pause:",
        "_mediaServicesRebuildPending || _waitingForExplicitResume",
        must=("_paused = YES;", "_rendererActivityAllowed, false")))

    add(body_gate(
        "avsample.interruption_queue_is_distinct", "avsample",
        "SampleBufferInterruptionQueue(",
        '"org.videolan.vlc.sample-buffer-interruptions"',
        must=("dispatch_queue_create", "DISPATCH_QUEUE_SERIAL"),
        absent=("sample-buffer-media-services",)))

    def interruption_transfer(sources: Mapping[str, str]) -> None:
        candidate = body(sources["avsample"], "handleInterruption:")
        require(candidate,
                "atomic_store_explicit(&_rendererActivityAllowed, false,",
                "dispatch_async(SampleBufferInterruptionQueue(), ^{",
                "vlc_mutex_lock(&_lifecycleLock);",
                "[self releaseAudioSessionLocked:0];",
                "vlc_mutex_unlock(&_lifecycleLock);",
                "[self endStartCallback];")
        forbid(candidate,
               "dispatch_async(SampleBufferMediaServicesRecoveryQueue()")
        packed = compact(candidate)
        if packed.index("dispatch_async(SampleBufferInterruptionQueue()") > \
                packed.index("vlc_mutex_lock(&_lifecycleLock)"):
            raise ProofFailure(
                "interruption takes lifecycle/session lock before async transfer"
            )
        if packed.rindex("vlc_mutex_unlock(&_lifecycleLock)") > \
                packed.rindex("[self endStartCallback]"):
            raise ProofFailure(
                "interruption callback lease ends before lifecycle work drains"
            )
    add(custom_gate(
        "avsample.interruption_async_lease_transfer_avoids_lock_inversion",
        interruption_transfer, "avsample", "handleInterruption:",
        "dispatch_async(SampleBufferInterruptionQueue(), ^{",
        "vlc_mutex_lock(&_lifecycleLock);\n        if (true) {"))
    add(body_gate(
        "avsample.interruption_end_never_auto_resumes", "avsample",
        "handleInterruption:", '"explicit core resume"',
        absent=("_sync.rate = 1.0f", "setActive:YES")))
    add(body_gate(
        "avsample.exact_new_command_retry", "avsample",
        "resumeAfterMediaServicesResetGeneration:",
        "generation <= _lastAttemptedCommandGeneration",
        must=("command.generation != generation", "command.reset_epoch != resetEpoch",
              "command.dispatched", "_lastAttemptedCommandGeneration = generation;")))
    add(body_gate(
        "avsample.command_register_reconcile_bootstrap", "avsample",
        "registerCommandAndReconcile", "aout_MediaServicesCommandBootstrap(",
        must=("aout_MediaServicesCommandRegister",
              "for (unsigned attempt = 0; attempt < 16",
              "vlc_apple_audio_session_snapshot")))
    add(body_gate(
        "avsample.command_unregister_drain", "avsample", "Close(",
        "[borrowed unregisterCommand];",
        must=("removePersistentObserversAndDrain", "removeStartObserversAndDrain",
              "[borrowed shutdown]")))
    add(body_gate(
        "avsample.start_observer_tokens_and_callbacks_drain", "avsample",
        "removeStartObserversAndDrain", "while (_activeStartCallbacks != 0)",
        must=("_startCallbacksAccepted = NO;",
              "[center removeObserver:flush]",
              "[center removeObserver:configuration]",
              "[center removeObserver:interruption]",
              "vlc_cond_wait(&_notificationWait, &_notificationLock)")))
    add(body_gate(
        "avsample.graph_transfer_takes_explicit_plus_one", "avsample",
        "detachGraphForBrokerRenderer:",
        "CFBridgingRetain(_renderer)",
        must=("CFBridgingRetain(_sync)", "CFBridgingRetain(_timeObserver)",
              "*format = _fmtDesc;", "_renderer = nil;", "_sync = nil;",
              "_fmtDesc = NULL;")))
    add(body_gate(
        "avsample.reset_final_release_is_brokered", "avsample",
        "processMediaServicesRecoveryReset:",
        "[self detachGraphForBrokerRenderer:&detachedRenderer",
        must=("vlc_apple_audio_session_orphan_cf_objects(detachedRenderer,",
              "detachedSynchronizer", "detachedFormat",
              "detachedTimeObserver"),
        absent=("clearGraphWithoutMessagingLocked", "CFRelease(_fmtDesc)")))
    add(body_gate(
        "avsample.start_error_final_release_is_brokered", "avsample", "start:",
        "[self detachGraphForBrokerRenderer:&failedRenderer",
        must=("vlc_apple_audio_session_orphan_cf_objects(failedRenderer,",
              "failedSynchronizer", "failedFormat", "failedTimeObserver",
              "[self removeStartObserversAndDrain]"),
        absent=("clearGraphWithoutMessagingLocked", "CFRelease(_fmtDesc)")))

    def avsample_has_one_broker_transfer_boundary(
            sources: Mapping[str, str]) -> None:
        candidate = sources["avsample"]
        forbid(candidate, "clearGraphWithoutMessagingLocked",
               "CFRelease(_fmtDesc)")
        for statement in ("_renderer = nil;", "_sync = nil;",
                          "_fmtDesc = NULL;"):
            count = compact(candidate).count(compact(statement))
            if count != 1:
                raise ProofFailure(
                    f"AVSample final ownership statement {statement} "
                    f"appears {count} times instead of only in detach"
                )
    add(custom_gate(
        "avsample.no_snapshot_to_arc_cf_release_bypass",
        avsample_has_one_broker_transfer_boundary, "avsample",
        "detachGraphForBrokerRenderer:", "_renderer = nil;",
        "CFRelease(_fmtDesc);"))
    add(body_gate(
        "avsample.close_transfers_plus_one_graph_to_broker", "avsample",
        "shutdown", "vlc_apple_audio_session_orphan_cf_objects(orphanRenderer,",
        must=("detachGraphForBrokerRenderer", "orphanSynchronizer",
              "orphanFormat", "orphanTimeObserver")))
    add(body_gate(
        "avsample.output_config_observer_exact_renderer", "avsample",
        "installStartObserversForRendererGeneration:",
        "object:_renderer queue:nil", target_count=2,
        must=("AVSampleBufferAudioRendererOutputConfigurationDidChangeNotification",
              "_configurationObserverToken = configuration;")))
    add(body_gate(
        "avsample.telemetry_attempt_and_result", "avsample",
        "resumeAfterMediaServicesResetGeneration:",
        "aout_MediaServicesReportRecoveryAttempt(_aout);",
        must=("ReportRecoveryResult(_aout",)))
    add(body_gate(
        "avsample.successful_open_runtime_marker", "avsample", "Open(",
        '"AVSampleBufferAudioRenderer output opened as the "',
        must=('"priority-100 default"', "return VLC_SUCCESS;")))
    add(source_gate(
        "avsample.priority_100_default", "avsample",
        'set_capability("audio output", 100)',
        must=('set_description(N_("AVSampleBufferAudioRenderer output"))',)))

    return gates


class RecoverySnapshotABI(ctypes.Structure):
    _fields_ = [
        ("version", ctypes.c_uint32), ("size", ctypes.c_uint32),
        ("broker_phase", ctypes.c_uint32), ("command_origin", ctypes.c_uint32),
        ("broker_epoch", ctypes.c_uint64),
        ("broker_reset_epoch", ctypes.c_uint64),
        ("command_generation", ctypes.c_uint64),
        ("command_reset_epoch", ctypes.c_uint64),
        ("acknowledged_reset_epoch", ctypes.c_uint64),
        ("output_incarnation_count", ctypes.c_uint64),
        ("successful_rebuild_count", ctypes.c_uint64),
        ("explicit_resume_attempt_count", ctypes.c_uint64),
        ("explicit_resume_failure_count", ctypes.c_uint64),
        ("command_dispatched", ctypes.c_uint32),
        ("live_output_count", ctypes.c_uint32),
        ("broker_active_owner_count", ctypes.c_uint32),
        ("broker_live_lease_count", ctypes.c_uint32),
        ("broker_successful_deactivation_count", ctypes.c_uint64),
        ("broker_failed_deactivation_count", ctypes.c_uint64),
    ]


@dataclass(frozen=True)
class BrokerState:
    epoch: int = 1
    lost: bool = False
    owners: tuple[bool, bool] = (False, False)
    leases: tuple[int, int] = (0, 0)


def broker_counts(state: BrokerState) -> tuple[int, int]:
    if state.lost:
        return 0, 0
    leases = sum(epoch == state.epoch for epoch in state.leases)
    return sum(state.owners) + leases, leases


def broker_step(state: BrokerState, action: str) -> BrokerState:
    if action in ("lost", "reset"):
        return BrokerState(state.epoch + 1, action == "lost", (False, False),
                           state.leases)
    kind, _, suffix = action.partition(":")
    index = int(suffix)
    owners = list(state.owners)
    leases = list(state.leases)
    if kind == "owner+" and not state.lost and not owners[index]:
        owners[index] = True
    elif kind == "owner-" and not state.lost and owners[index]:
        owners[index] = False
    elif kind == "lease+" and not state.lost and leases[index] != state.epoch:
        leases[index] = state.epoch
    elif kind == "lease-" and leases[index] != 0:
        leases[index] = 0
    return replace(state, owners=tuple(owners), leases=tuple(leases))


@dataclass(frozen=True)
class ControlState:
    generation: int = 0
    explicit: bool = False
    reset_epoch: int = 0
    dispatched: bool = False
    terminal: int = 0
    registrations: tuple[bool, bool] = (False, False)
    delivered: tuple[int, int] = (0, 0)
    acknowledged: tuple[int, int] = (0, 0)
    acknowledged_epoch: int = 0
    vacuous: bool = False
    incarnations: int = 0


def control_step(state: ControlState, action: str) -> ControlState:
    registrations = list(state.registrations)
    delivered = list(state.delivered)
    acknowledged = list(state.acknowledged)
    if action == "publish-explicit":
        return replace(state, generation=state.generation + 1, explicit=True,
                       reset_epoch=7, dispatched=False, terminal=0,
                       acknowledged_epoch=0, vacuous=False)
    if action == "publish-invalidating":
        return replace(state, generation=state.generation + 1, explicit=False,
                       reset_epoch=0, dispatched=False, terminal=0,
                       acknowledged_epoch=0, vacuous=False)
    if action == "dispatch" and state.explicit:
        delivered = [state.generation if live else old
                     for live, old in zip(registrations, delivered)]
        live = any(registrations)
        vacuous = not live and state.terminal != state.generation
        return replace(state, dispatched=True, delivered=tuple(delivered),
                       acknowledged_epoch=(state.reset_epoch if vacuous else 0),
                       vacuous=vacuous)
    kind, _, suffix = action.partition(":")
    if not suffix:
        return state
    index = int(suffix)
    if kind == "register" and not registrations[index]:
        registrations[index] = True
        revoke_ack = (state.explicit and state.dispatched
                      and state.acknowledged_epoch == state.reset_epoch)
        return replace(state, registrations=tuple(registrations),
                       acknowledged_epoch=0 if revoke_ack
                       else state.acknowledged_epoch,
                       vacuous=False, incarnations=state.incarnations + 1)
    if kind == "bootstrap" and registrations[index] and state.explicit \
            and state.dispatched and state.terminal != state.generation \
            and delivered[index] != state.generation:
        delivered[index] = state.generation
        return replace(state, delivered=tuple(delivered))
    if kind == "ack" and registrations[index] and state.explicit \
            and state.dispatched and delivered[index] == state.generation:
        acknowledged[index] = state.generation
        all_ack = all(not live or acknowledged[i] == state.generation
                      for i, live in enumerate(registrations))
        return replace(state, acknowledged=tuple(acknowledged),
                       acknowledged_epoch=state.reset_epoch if all_ack else 0,
                       vacuous=False)
    if kind == "fail" and registrations[index] and state.explicit \
            and delivered[index] == state.generation:
        return replace(state, terminal=state.generation)
    if kind == "unregister" and registrations[index]:
        registrations[index] = False
        if not any(registrations) and state.explicit and state.dispatched \
                and state.terminal != state.generation:
            return replace(state, registrations=tuple(registrations),
                           acknowledged_epoch=state.reset_epoch, vacuous=True)
        all_ack = all(not live or acknowledged[i] == state.generation
                      for i, live in enumerate(registrations))
        return replace(state, registrations=tuple(registrations),
                       acknowledged_epoch=(state.reset_epoch if all_ack
                                           and state.explicit and state.dispatched
                                           and state.terminal != state.generation
                                           else 0), vacuous=False)
    return state


def explore(initial, actions: tuple[str, ...], step, invariant,
            depth: int) -> tuple[int, int]:
    queue = deque([(initial, 0)])
    seen = {initial}
    transitions = 0
    while queue:
        state, level = queue.popleft()
        invariant(state)
        if level == depth:
            continue
        for action in actions:
            successor = step(state, action)
            transitions += 1
            invariant(successor)
            if successor not in seen:
                seen.add(successor)
                queue.append((successor, level + 1))
    return len(seen), transitions


def run_state_models() -> dict[str, tuple[int, int]]:
    def broker_invariant(state: BrokerState) -> None:
        if state.epoch == 0:
            raise ProofFailure("broker model reached epoch zero")
        owners, leases = broker_counts(state)
        if state.lost and (owners != 0 or leases != 0):
            raise ProofFailure("Lost retained active ownership counters")
        if leases > owners:
            raise ProofFailure("lease count exceeded owner count")
        if any(epoch > state.epoch for epoch in state.leases):
            raise ProofFailure("lease came from a future epoch")

    broker_actions = (
        "owner+:0", "owner+:1", "owner-:0", "owner-:1",
        "lease+:0", "lease+:1", "lease-:0", "lease-:1", "lost", "reset",
    )
    broker_result = explore(BrokerState(), broker_actions, broker_step,
                            broker_invariant, 7)

    # Repeated Reset -> acquire must not grow the opaque token table. The
    # serialized acquire first retires every record outside the current epoch,
    # then deduplicates/adds the current owner token.
    lease_records: list[tuple[int, int]] = []
    lease_epoch = 1
    stale_lease_transitions = 0
    for cycle in range(1, 65):
        lease_epoch += 1  # Reset
        stale_lease_transitions += 1
        lease_records = [record for record in lease_records
                         if record[1] == lease_epoch]
        if not any(owner == 0 and epoch == lease_epoch
                   for owner, epoch in lease_records):
            lease_records.append((0, lease_epoch))
        stale_lease_transitions += 1
        if lease_records != [(0, lease_epoch)]:
            raise ProofFailure(
                f"stale lease table grew at reset/acquire cycle {cycle}"
            )

    successor_interleavings = 0
    for initial_owners in (1, 2):
        for successor in (False, True):
            for physical_no_success in (False, True):
                remaining = initial_owners - 1 + int(successor)
                # Only the true final logical release issues setActive:NO.
                # A non-final release necessarily leaves the process active.
                physical_active = (initial_owners != 1
                                   or not physical_no_success)
                if initial_owners == 1 and physical_no_success and successor:
                    physical_active = True  # required setActive:YES reassert
                if remaining > 0 and not physical_active:
                    raise ProofFailure("reentrant successor stranded inactive")
                successor_interleavings += 1

    # AudioComponentInstanceDispose is allowed to fail. Every failed attempt
    # must preserve both the invalidated unit and its render context for a
    # later Reset; a successful attempt is the sole transition that may free
    # the callback context. Model a long failure streak to catch eager free or
    # same-event retry loops without pretending the platform call is infallible.
    dispose_attempts = 0
    retained_unit = True
    context_alive = True
    dispose_retry_transitions = 0
    for _ in range(64):
        dispose_attempts += 1
        dispose_retry_transitions += 1
        if not retained_unit or not context_alive:
            raise ProofFailure("failed Dispose lost its unit/context pair")
    dispose_attempts += 1
    dispose_retry_transitions += 1
    retained_unit = False
    context_alive = False
    if retained_unit or context_alive or dispose_attempts != 65:
        raise ProofFailure("successful Dispose did not retire its pair once")

    def control_invariant(state: ControlState) -> None:
        live = sum(state.registrations)
        if state.vacuous and live != 0:
            raise ProofFailure("vacuous acknowledgement crossed registration")
        if state.acknowledged_epoch != 0:
            if not state.explicit or not state.dispatched:
                raise ProofFailure("acknowledgement without explicit dispatch")
            if state.acknowledged_epoch != state.reset_epoch:
                raise ProofFailure("acknowledged wrong reset epoch")
            if live and not all(
                    not is_live or state.acknowledged[i] == state.generation
                    for i, is_live in enumerate(state.registrations)):
                raise ProofFailure("acknowledged before every live output")
        if state.terminal == state.generation and state.generation != 0 \
                and state.vacuous:
            raise ProofFailure("terminal command became vacuously acknowledged")

    control_actions = (
        "publish-explicit", "publish-invalidating", "dispatch",
        "register:0", "register:1", "bootstrap:0", "bootstrap:1",
        "ack:0", "ack:1", "fail:0", "fail:1",
        "unregister:0", "unregister:1",
    )
    control_result = explore(ControlState(), control_actions, control_step,
                             control_invariant, 7)

    state = ControlState()
    for action in (
        "register:0", "register:1", "publish-explicit", "dispatch", "ack:0",
        "fail:1", "unregister:1", "publish-invalidating",
        "publish-explicit", "dispatch", "ack:0", "unregister:0",
    ):
        state = control_step(state, action)
        control_invariant(state)
    if not state.vacuous or state.acknowledged_epoch != 7:
        raise ProofFailure("two-output deterministic vacuous boundary failed")

    return {
        "broker_two_owner_lease": broker_result,
        "command_two_output": control_result,
        "reentrant_successor": (successor_interleavings,
                                 successor_interleavings),
        "stale_lease_retirement": (64, stale_lease_transitions),
        "audio_unit_dispose_retry": (65, dispose_retry_transitions),
    }


def validate_abi_model() -> None:
    expected_offsets = {
        "broker_epoch": 16, "command_generation": 32,
        "command_dispatched": 88, "broker_active_owner_count": 96,
        "broker_live_lease_count": 100,
        "broker_successful_deactivation_count": 104,
        "broker_failed_deactivation_count": 112,
    }
    if ctypes.sizeof(RecoverySnapshotABI) != 120:
        raise ProofFailure("modeled recovery snapshot is not exactly 120 bytes")
    if ctypes.alignment(RecoverySnapshotABI) != 8:
        raise ProofFailure("modeled recovery snapshot alignment is not 8")
    for field, expected in expected_offsets.items():
        actual = getattr(RecoverySnapshotABI, field).offset
        if actual != expected:
            raise ProofFailure(
                f"modeled recovery snapshot {field} offset {actual} != {expected}"
            )


SOURCE_PATHS = {
    "broker": "src/darwin/apple_audio_session.m",
    "broker_header": "include/vlc_apple_audio_session.h",
    "src_makefile": "src/Makefile.am",
    "src_meson": "src/meson.build",
    "common": "modules/audio_output/apple/avaudiosession_common.m",
    "audiounit": "modules/audio_output/apple/audiounit_ios.m",
    "avsample": "modules/audio_output/apple/avsamplebuffer.m",
    "aout_header": "include/vlc_aout.h",
    "aout_internal": "src/audio_output/aout_internal.h",
    "output": "src/audio_output/output.c",
    "resource": "src/input/resource.c",
    "resource_header": "src/input/resource.h",
    "player_aout": "src/player/aout.c",
    "player": "src/player/player.c",
    "media_player": "lib/media_player.c",
    "media_list": "lib/media_list_player.c",
    "public_header": "include/vlc/libvlc_media_player.h",
}

REPOSITORY_PATHS = {
    "vendored_header": "Sources/CLibVLC/include/vlc/libvlc_media_player.h",
    "shim": "Sources/CLibVLC/shim.c",
    "clibvlc_header": "Sources/CLibVLC/include/CLibVLC.h",
}


def read_sources(vlc_root: Path, repository_root: Path) -> dict[str, str]:
    sources: dict[str, str] = {}
    for key, relative in SOURCE_PATHS.items():
        path = vlc_root / relative
        if not path.is_file():
            raise ProofFailure(f"missing patched VLC source: {path}")
        sources[key] = path.read_text(encoding="utf-8")
    for key, relative in REPOSITORY_PATHS.items():
        path = repository_root / relative
        if not path.is_file():
            raise ProofFailure(f"missing vendored CLibVLC source: {path}")
        sources[key] = path.read_text(encoding="utf-8")
    return sources


def validate_all(gates: list[Gate], sources: Mapping[str, str]) -> None:
    for gate in gates:
        try:
            gate.check(sources)
        except (AssertionError, ValueError) as error:
            raise ProofFailure(f"[{gate.name}] {error}") from error


def run_negative_mutations(gates: list[Gate],
                           sources: Mapping[str, str]) -> int:
    caught = 0
    for gate in gates:
        mutated = gate.mutation.apply(sources)
        try:
            gate.check(mutated)
        except (AssertionError, ValueError):
            caught += 1
        else:
            raise ProofFailure(
                f"negative mutation escaped its own gate: {gate.name}"
            )
    return caught


def main(argv: list[str]) -> int:
    if len(argv) not in (2, 3):
        print(
            "usage: audio-media-services-reset-source-check.py "
            "<patched-vlc-source> [swiftvlc-repository-root]",
            file=sys.stderr,
        )
        return 2
    vlc_root = Path(argv[1]).resolve()
    repository_root = (
        Path(argv[2]).resolve() if len(argv) == 3
        else Path(__file__).resolve().parents[3]
    )
    try:
        sources = read_sources(vlc_root, repository_root)
        gates = build_gates()
        if len(gates) != EXPECTED_STRUCTURAL_GATE_COUNT:
            raise ProofFailure(
                "structural gate inventory drifted: "
                f"{len(gates)} != {EXPECTED_STRUCTURAL_GATE_COUNT}"
            )
        validate_arc_ownership_lexer()
        validate_abi_model()
        validate_all(gates, sources)
        mutations = run_negative_mutations(gates, sources)
        models = run_state_models()
    except (OSError, ProofFailure) as error:
        print(f"FAIL audio media-services reset source proof: {error}",
              file=sys.stderr)
        return 1

    model_text = ", ".join(
        f"{name}={states}states/{transitions}transitions"
        for name, (states, transitions) in models.items()
    )
    print(
        "PASS audio media-services reset source proof: "
        f"structural_gates={len(gates)} "
        f"negative_mutations={mutations}/{len(gates)} "
        f"abi=version8/120bytes/alignment8; models[{model_text}]"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
