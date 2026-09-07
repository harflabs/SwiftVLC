from __future__ import annotations

import copy
import importlib.util
import json
import math
import tempfile
import unittest
from pathlib import Path
from typing import Callable, Union

QUALIFICATION = Path(__file__).resolve().parents[1]


def load_script(name: str):
    path = QUALIFICATION / name
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


policy = load_script("qualification_policy.py")
MATRIX = json.loads((QUALIFICATION / "matrix.json").read_text(encoding="utf-8"))
SCENARIOS = {scenario["id"]: scenario for scenario in MATRIX["scenarios"]}


# Keep the policy suite runnable with the Python 3.9 runtime bundled with
# current Xcode installations.  Unlike annotations (which are postponed by
# the future import above), a type-alias expression is evaluated immediately.
PathComponent = Union[str, int]
Mutation = tuple[str, Callable[[dict], None]]


def set_path(value: dict, path: tuple[PathComponent, ...], replacement: object) -> None:
    cursor: object = value
    for component in path[:-1]:
        cursor = cursor[component]  # type: ignore[index]
    cursor[path[-1]] = replacement  # type: ignore[index]


def set_mutation(
    name: str, path: tuple[PathComponent, ...], replacement: object
) -> Mutation:
    return name, lambda value: set_path(value, path, replacement)


def sets_mutation(
    name: str,
    replacements: list[tuple[tuple[PathComponent, ...], object]],
) -> Mutation:
    def mutate(value: dict) -> None:
        for path, replacement in replacements:
            set_path(value, path, replacement)

    return name, mutate


def delete_mutation(name: str, path: tuple[PathComponent, ...]) -> Mutation:
    def mutate(value: dict) -> None:
        cursor: object = value
        for component in path[:-1]:
            cursor = cursor[component]  # type: ignore[index]
        del cursor[path[-1]]  # type: ignore[index]

    return name, mutate


def native_snapshot(**changes: object) -> dict:
    value = {
        "version": 1,
        "brokerPhase": "ready",
        "commandOrigin": "explicitResume",
        "brokerEpoch": 1,
        "brokerResetEpoch": 0,
        "commandGeneration": 7,
        "commandResetEpoch": 0,
        "acknowledgedResetEpoch": 0,
        "outputIncarnationCount": 10,
        "successfulRebuildCount": 4,
        "explicitResumeAttemptCount": 4,
        "explicitResumeFailureCount": 0,
        "commandWasDispatched": True,
        "liveOutputCount": 0,
        "brokerActiveOwnerCount": 0,
        "brokerLiveLeaseCount": 0,
        "brokerSuccessfulDeactivationCount": 2,
        "brokerFailedDeactivationCount": 0,
    }
    value.update(changes)
    return value


def playback(
    *,
    media_time: int = 1_000,
    audio: int = 100,
    played: int = 100,
    decoded_video: int = 0,
    displayed: int = 0,
) -> dict:
    return {
        "mediaTimeMilliseconds": media_time,
        "decodedAudio": audio,
        "playedAudioBuffers": played,
        "lostAudioBuffers": 0,
        "decodedVideo": decoded_video,
        "displayedPictures": displayed,
        "lostPictures": 0,
    }


def checkpoint(
    uptime: float,
    state: str,
    intent: bool,
    native: dict,
    counters: dict | None = None,
) -> dict:
    return {
        "systemUptime": uptime,
        "playerState": state,
        "playbackRequestedActive": intent,
        "native": native,
        "playback": playback() if counters is None else counters,
    }


def source_request_proof(token: str, successful_segments: int) -> dict:
    token_kind = "reset" if "-audio-reset-" in token else "ownership"
    source_attempt = int(token.rsplit("-", 1)[1])
    run_id = token.removesuffix(f"-audio-{token_kind}-{source_attempt}")
    runner_scenario = (
        "audio-media-services-reset"
        if token_kind == "reset"
        else "audio-session-ownership"
    )
    return {
        "formatVersion": 2,
        "method": "host-fixture-server-token-metrics-v2",
        "sourceAttempt": source_attempt,
        "attemptToken": token,
        "masterRequests": 2,
        "mediaPlaylistRequests": 2,
        "segmentRequests": successful_segments,
        "successfulSegments": successful_segments,
        "playlistTypes": ["vod"],
        "containers": ["ts"],
        "variants": ["high"],
        "modes": ["timebase-vod-ts"],
        "metricsRelativePath": (
            f"apple-audio-source-metrics/{run_id}-{runner_scenario}/"
            f"attempt-{source_attempt}.json"
        ),
        "metricsDigestAlgorithm": "sha256",
        "metricsDigest": "0" * 64,
        "metricsSizeBytes": 1,
    }


def source_metrics(proof: dict) -> dict:
    successful = proof["successfulSegments"]
    playlists = proof["mediaPlaylistRequests"]
    return {
        "formatVersion": 1,
        "token": proof["attemptToken"],
        "masterRequests": proof["masterRequests"],
        "mediaPlaylistRequests": playlists,
        "segmentRequests": successful,
        "successfulSegments": successful,
        "successfulSegmentsByVariant": {"low": 0, "high": successful},
        "retryFailures": 0,
        "retryRecoveries": 0,
        "expiredWindows": 0,
        "discontinuityManifests": playlists,
        "variantTransitions": 0,
        "clientCompleted": False,
        "playlistTypes": ["vod"],
        "containers": ["ts"],
        "variants": ["high"],
        "modes": ["timebase-vod-ts"],
        "maxMediaSequenceByMode": {"timebase-vod-ts": 0},
    }


def reset_evidence() -> dict:
    baseline_native = native_snapshot(
        liveOutputCount=1,
        brokerActiveOwnerCount=3,
        brokerLiveLeaseCount=1,
    )
    quarantine_native = native_snapshot(
        brokerEpoch=3,
        brokerResetEpoch=3,
        commandGeneration=8,
        commandResetEpoch=3,
        commandOrigin="invalidating",
        commandWasDispatched=False,
    )
    recovered_native = native_snapshot(
        brokerEpoch=3,
        brokerResetEpoch=3,
        commandGeneration=9,
        commandResetEpoch=3,
        acknowledgedResetEpoch=3,
        outputIncarnationCount=11,
        successfulRebuildCount=5,
        explicitResumeAttemptCount=5,
        liveOutputCount=1,
        brokerActiveOwnerCount=3,
        brokerLiveLeaseCount=1,
    )

    def player(role: str, module: str, *, video: bool) -> dict:
        readiness_playback = playback(
            media_time=1_000,
            audio=100,
            played=100,
            decoded_video=60 if video else 0,
            displayed=50 if video else 0,
        )
        baseline_playback = playback(
            media_time=2_000,
            audio=150,
            played=150,
            decoded_video=80 if video else 0,
            displayed=70 if video else 0,
        )
        quarantine_playback = copy.deepcopy(baseline_playback)
        recovered_playback = playback(
            media_time=5_000,
            audio=220,
            played=210,
            decoded_video=140 if video else 0,
            displayed=130 if video else 0,
        )
        return {
            "role": role,
            "forcedAudioOutputModule": module,
            "readinessStart": checkpoint(
                97.0,
                "playing",
                True,
                copy.deepcopy(baseline_native),
                readiness_playback,
            ),
            "baseline": checkpoint(
                98.0,
                "playing",
                True,
                copy.deepcopy(baseline_native),
                baseline_playback,
            ),
            "quarantineStart": checkpoint(
                100.0,
                "paused",
                False,
                copy.deepcopy(quarantine_native),
                copy.deepcopy(quarantine_playback),
            ),
            "quarantineEnd": checkpoint(
                103.0,
                "paused",
                False,
                copy.deepcopy(quarantine_native),
                copy.deepcopy(quarantine_playback),
            ),
            "recovered": checkpoint(
                108.0,
                "playing",
                True,
                copy.deepcopy(recovered_native),
                recovered_playback,
            ),
        }

    return {
        "formatVersion": 1,
        "scenario": "audio-media-services-reset",
        "trigger": "settings-developer-media-services-reset-v1",
        "syntheticNotificationsPosted": False,
        "mediaServicesLostNotificationCount": 1,
        "mediaServicesResetNotificationCount": 1,
        "mediaServicesNotificationSequence": [
            {"kind": "lost", "systemUptime": 99.0},
            {"kind": "reset", "systemUptime": 99.5},
        ],
        "quarantineObservationMilliseconds": 3_000,
        "pictureInPictureActiveBeforeReset": True,
        "pictureInPictureActiveAfterRecovery": True,
        "players": [
            player("audio-only", "audiounit_ios", video=False),
            player("native-pip-video", "avsamplebuffer", video=True),
        ],
        "resetEpochProof": "pass",
        "preIntentQuarantine": "pass",
        "explicitResumeRecovery": "pass",
        "forcedOutputModules": ["audiounit_ios", "avsamplebuffer"],
        "systemPiPMotionBeforeReset": "pass",
        "systemPiPMotionAfterRecovery": "pass",
        "sourceRequestProof": source_request_proof(
            "run-audio-reset-1", successful_segments=2
        ),
        "libraryErrorCount": 0,
    }


def session_configuration(
    category: str = "AVAudioSessionCategorySoloAmbient",
    mode: str = "AVAudioSessionModeDefault",
    options: int = 0,
    policy_value: int = 0,
    sample_rate: float = 48_000.0,
    io_buffer_duration: float = 0.005,
    input_channels: int = 0,
    output_channels: int = 2,
) -> dict:
    return {
        "category": category,
        "mode": mode,
        "categoryOptionsRawValue": options,
        "routeSharingPolicyRawValue": policy_value,
        "preferredSampleRate": sample_rate,
        "preferredIOBufferDuration": io_buffer_duration,
        "preferredInputNumberOfChannels": input_channels,
        "preferredOutputNumberOfChannels": output_channels,
    }


def focus_probe(
    phase: str,
    before: int,
    delta: int,
    outcome: str,
    **extra: object,
) -> dict:
    window_start = {
        "idle-constructed-awaiting-focus-probe": 10.0,
        "library-order1-released-awaiting-focus-probe": 20.0,
        "library-order2-released-awaiting-focus-probe": 30.0,
        "application-audiounit-released-awaiting-focus-probe": 40.0,
        "application-avsamplebuffer-released-awaiting-focus-probe": 50.0,
        "complete-awaiting-host-release-focus-probe": 60.0,
    }[phase]
    return {
        "phase": phase,
        "source": "foreground-XCTest-runner-audio-session",
        "activationSucceeded": True,
        "probeApplicationBundleIdentifier": (
            "com.swiftvlc.showcase.ios.uitests.xctrunner"
        ),
        "probeApplicationStateAtActivation": "runningForeground",
        "candidateApplicationStateBeforeProbe": "runningForeground",
        "candidateApplicationStateDuringActivation": "runningBackground",
        "candidateApplicationStateAfterProbe": "runningForeground",
        "activationBeganSystemUptime": window_start,
        "activationCompletedSystemUptime": window_start + 0.2,
        "deactivationBeganSystemUptime": window_start + 1.0,
        "deactivationCompletedSystemUptime": window_start + 1.2,
        "observationSystemUptime": window_start + 1.6,
        "candidateInterruptionBeganBefore": before,
        "candidateInterruptionEndedBefore": before,
        "candidateInterruptionBeganAfterProbe": before + delta,
        "candidateInterruptionEndedAfterProbe": before + delta,
        "candidateInterruptionBeganDelta": delta,
        "candidateInterruptionEndedDelta": delta,
        "outcome": outcome,
        **extra,
    }


def ownership_evidence() -> dict:
    idle = native_snapshot()
    idle_session = session_configuration()
    application_session = session_configuration(
        "AVAudioSessionCategoryPlayback",
        "AVAudioSessionModeSpokenAudio",
        policy_value=1,
    )

    def library_cycle(
        order: list[str],
        uptime: float,
        deactivation_count: int,
    ) -> dict:
        first = native_snapshot(
            liveOutputCount=1,
            brokerActiveOwnerCount=1,
            brokerSuccessfulDeactivationCount=deactivation_count,
        )
        both = native_snapshot(
            liveOutputCount=1,
            brokerActiveOwnerCount=2,
            brokerSuccessfulDeactivationCount=deactivation_count,
        )
        after_first = native_snapshot(
            liveOutputCount=1,
            brokerActiveOwnerCount=1,
            brokerSuccessfulDeactivationCount=deactivation_count,
        )
        after_final = native_snapshot(
            brokerSuccessfulDeactivationCount=deactivation_count + 1,
        )
        return {
            "forcedModuleOrder": order,
            "firstOutputActive": checkpoint(uptime, "playing", True, first),
            "bothOutputsActive": checkpoint(uptime + 5, "playing", True, both),
            "afterFirstOutputRelease": checkpoint(
                uptime + 10, "playing", True, after_first
            ),
            "afterFinalOutputRelease": checkpoint(
                uptime + 15, "idle", False, after_final
            ),
            "firstOutputPlaybackStart": playback(media_time=1_000, played=120),
            "firstOutputPlaybackEnd": playback(media_time=2_000, played=180),
            "secondOutputPlaybackStart": playback(media_time=1_500, played=80),
            "secondOutputPlaybackEnd": playback(media_time=2_500, played=140),
        }

    def application_cycle(module: str) -> dict:
        application_idle = native_snapshot(brokerSuccessfulDeactivationCount=4)
        application_during = native_snapshot(
            liveOutputCount=1,
            brokerSuccessfulDeactivationCount=4,
        )
        return {
            "forcedAudioOutputModule": module,
            "sessionBeforePlayback": copy.deepcopy(application_session),
            "sessionDuringPlayback": copy.deepcopy(application_session),
            "sessionAfterPlayback": copy.deepcopy(application_session),
            "brokerBeforePlayback": copy.deepcopy(application_idle),
            "brokerDuringPlayback": application_during,
            "brokerAfterPlayback": copy.deepcopy(application_idle),
            "playbackStart": playback(media_time=3_000, played=40),
            "playbackEnd": playback(media_time=4_000, played=100),
        }

    return {
        "formatVersion": 3,
        "scenario": "audio-session-ownership",
        "libraryManagedForcedModules": ["audiounit_ios", "avsamplebuffer"],
        "applicationManagedForcedModules": ["audiounit_ios", "avsamplebuffer"],
        "idleSessionBeforePlayerConstruction": copy.deepcopy(idle_session),
        "idleSessionAfterPlayerConstruction": copy.deepcopy(idle_session),
        "idleBrokerBeforePlayerConstruction": copy.deepcopy(idle),
        "idleBrokerAfterPlayerConstruction": copy.deepcopy(idle),
        "libraryManagedCycles": [
            library_cycle(["audiounit_ios", "avsamplebuffer"], 20.0, 2),
            library_cycle(["avsamplebuffer", "audiounit_ios"], 40.0, 3),
        ],
        "applicationManagedCycles": [
            application_cycle("audiounit_ios"),
            application_cycle("avsamplebuffer"),
        ],
        "idleConstruction": "pass",
        "multiOwnerRelease": "pass",
        "survivingOutputContinuity": "pass",
        "finalDeactivation": "pass",
        "applicationManagedNonMutation": "pass",
        "idleConstructionFocusProbe": focus_probe(
            "idle-constructed-awaiting-focus-probe",
            0,
            0,
            "candidate-session-released",
        ),
        "libraryReleaseFocusProbes": [
            focus_probe(
                "library-order1-released-awaiting-focus-probe",
                0,
                0,
                "candidate-session-released",
                forcedModuleOrder=["audiounit_ios", "avsamplebuffer"],
            ),
            focus_probe(
                "library-order2-released-awaiting-focus-probe",
                0,
                0,
                "candidate-session-released",
                forcedModuleOrder=["avsamplebuffer", "audiounit_ios"],
            ),
        ],
        "interruptionNotificationSequence": [
            {"kind": "began", "systemUptime": 40.4, "reasonRawValue": 0},
            {"kind": "ended", "systemUptime": 41.4, "reasonRawValue": 0},
            {"kind": "began", "systemUptime": 50.4, "reasonRawValue": 0},
            {"kind": "ended", "systemUptime": 51.4, "reasonRawValue": 0},
        ],
        "applicationManagedReleaseFocusProbes": [
            focus_probe(
                "application-audiounit-released-awaiting-focus-probe",
                0,
                1,
                "candidate-session-active-after-output-teardown",
                forcedAudioOutputModule="audiounit_ios",
            ),
            focus_probe(
                "application-avsamplebuffer-released-awaiting-focus-probe",
                1,
                1,
                "candidate-session-active-after-output-teardown",
                forcedAudioOutputModule="avsamplebuffer",
            ),
        ],
        "hostReleaseFocusProbe": focus_probe(
            "complete-awaiting-host-release-focus-probe",
            2,
            0,
            "candidate-session-released",
        ),
        "sourceRequestProof": source_request_proof(
            "run-audio-ownership-1", successful_segments=6
        ),
        "libraryErrorCount": 0,
    }


class AppleAudioQualificationPolicyTests(unittest.TestCase):
    def assert_rejected(
        self,
        evidence: dict,
        validator: Callable[[dict], None],
        mutations: list[Mutation],
    ) -> None:
        # A mutation suite is meaningful only when its unmodified fixture is
        # accepted by the same validation path. This prevents a newly required
        # field from making every adversarial case pass for the wrong reason.
        validator(copy.deepcopy(evidence))
        for name, mutate in mutations:
            with self.subTest(mutation=name):
                candidate = copy.deepcopy(evidence)
                mutate(candidate)
                with self.assertRaises(policy.QualificationPolicyError):
                    validator(candidate)

    @staticmethod
    def validate_reset(value: dict) -> None:
        policy.validate_evidence_semantics(
            value,
            SCENARIOS["audio-media-services-reset"],
        )

    @staticmethod
    def validate_ownership(value: dict) -> None:
        policy.validate_evidence_semantics(
            value,
            SCENARIOS["audio-session-ownership"],
        )

    def test_media_services_reset_canonical_evidence_passes(self):
        evidence = reset_evidence()
        policy.validate_audio_media_services_reset_evidence(
            evidence,
            retained_base=None,
            require_retained=False,
        )
        self.validate_reset(evidence)

        # Apple documents reset as the recovery signal; the preceding lost
        # notification is not guaranteed for the Settings reset action.
        reset_only = copy.deepcopy(evidence)
        reset_only["mediaServicesLostNotificationCount"] = 0
        reset_only["mediaServicesNotificationSequence"] = [
            {"kind": "reset", "systemUptime": 99.5}
        ]
        for player in reset_only["players"]:
            for phase in ("quarantineStart", "quarantineEnd"):
                player[phase]["native"].update(
                    {
                        "brokerEpoch": 2,
                        "brokerResetEpoch": 2,
                        "commandResetEpoch": 2,
                    }
                )
            player["recovered"]["native"].update(
                {
                    "brokerEpoch": 2,
                    "brokerResetEpoch": 2,
                    "commandResetEpoch": 2,
                    "acknowledgedResetEpoch": 2,
                }
            )
        self.validate_reset(reset_only)

    def test_host_source_metrics_binding_is_exact_and_attempt_scoped(self):
        proof = source_request_proof("run-audio-reset-1", successful_segments=2)
        canonical = source_metrics(proof)
        mutations: list[tuple[str, Callable[[dict], None] | None]] = [
            ("canonical", None),
            ("boolean-format", lambda value: value.__setitem__("formatVersion", True)),
            ("missing-token", lambda value: value.pop("token")),
            ("extra-field", lambda value: value.__setitem__("trusted", True)),
            (
                "cross-attempt-token",
                lambda value: value.__setitem__("token", "run-audio-reset-2"),
            ),
            (
                "failed-segment",
                lambda value: value.__setitem__("segmentRequests", 3),
            ),
            (
                "low-variant-segment",
                lambda value: value["successfulSegmentsByVariant"].__setitem__(
                    "low", 1
                ),
            ),
            (
                "retry-failure",
                lambda value: value.__setitem__("retryFailures", 1),
            ),
            (
                "playlist-counter-mismatch",
                lambda value: value.__setitem__("discontinuityManifests", 1),
            ),
            (
                "client-completed-forgery",
                lambda value: value.__setitem__("clientCompleted", True),
            ),
            (
                "wrong-media-sequence",
                lambda value: value["maxMediaSequenceByMode"].__setitem__(
                    "timebase-vod-ts", 1
                ),
            ),
        ]
        for name, mutate in mutations:
            with self.subTest(
                mutation=name
            ), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                path = root / proof["metricsRelativePath"]
                path.parent.mkdir(parents=True)
                metrics = copy.deepcopy(canonical)
                if mutate is not None:
                    mutate(metrics)
                path.write_text(
                    json.dumps(metrics, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
                if mutate is None:
                    bound = policy.bind_apple_audio_source_request_proof(
                        path,
                        retained_base=root,
                        scenario="audio-media-services-reset",
                        runner_scenario="audio-media-services-reset",
                        source_attempt=1,
                    )
                    self.assertEqual(bound["attemptToken"], "run-audio-reset-1")
                    self.assertEqual(bound["sourceAttempt"], 1)
                    self.assertEqual(bound["metricsDigest"], policy.sha256_file(path))
                    self.assertEqual(bound["metricsSizeBytes"], path.stat().st_size)
                else:
                    with self.assertRaises(policy.QualificationPolicyError):
                        policy.bind_apple_audio_source_request_proof(
                            path,
                            retained_base=root,
                            scenario="audio-media-services-reset",
                            runner_scenario="audio-media-services-reset",
                            source_attempt=1,
                        )

    def test_host_source_metrics_rejects_symlink_and_post_binding_tamper(self):
        proof = source_request_proof("run-audio-reset-1", successful_segments=2)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            outside = root / "outside.json"
            outside.write_text(json.dumps(source_metrics(proof)), encoding="utf-8")
            symlink = root / proof["metricsRelativePath"]
            symlink.parent.mkdir(parents=True)
            symlink.symlink_to(outside)
            with self.assertRaises(policy.QualificationPolicyError):
                policy.bind_apple_audio_source_request_proof(
                    symlink,
                    retained_base=root,
                    scenario="audio-media-services-reset",
                    runner_scenario="audio-media-services-reset",
                    source_attempt=1,
                )

        expected_logs = {
            "audiounit": (
                "audiounit_ios",
                "analog AudioUnit output successfully opened for f32l Mono",
            ),
            "avsamplebuffer": (
                "avsamplebuffer",
                "AVSampleBufferAudioRenderer output opened as the priority-100 default",
            ),
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = self._install_logs(reset_evidence(), root, expected_logs)
            path = root / evidence["sourceRequestProof"]["metricsRelativePath"]
            path.write_text(path.read_text() + " ", encoding="utf-8")
            with self.assertRaisesRegex(
                policy.QualificationPolicyError,
                "retained metrics binding mismatch",
            ):
                policy.validate_audio_media_services_reset_evidence(
                    evidence,
                    retained_base=root,
                    require_retained=True,
                )

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = self._install_logs(reset_evidence(), root, expected_logs)
            path = root / evidence["sourceRequestProof"]["metricsRelativePath"]
            (path.parent / "attempt-2.json").write_text("{}\n", encoding="utf-8")
            with self.assertRaisesRegex(
                policy.QualificationPolicyError,
                "retained metrics inventory is not exact",
            ):
                policy.validate_audio_media_services_reset_evidence(
                    evidence,
                    retained_base=root,
                    require_retained=True,
                )

    def test_media_services_reset_rejects_exact_shape_and_type_forgeries(self):
        evidence = reset_evidence()
        mutations = [
            set_mutation("raw-extra-field", ("trustedUILabel",), "pass"),
            delete_mutation("raw-missing-field", ("players",)),
            delete_mutation("source-proof-missing", ("sourceRequestProof",)),
            set_mutation("format-version-boolean", ("formatVersion",), True),
            set_mutation("format-version-number", ("formatVersion",), 2),
            set_mutation(
                "notification-count-boolean",
                ("mediaServicesLostNotificationCount",),
                True,
            ),
            set_mutation(
                "quarantine-duration-float",
                ("quarantineObservationMilliseconds",),
                3_000.0,
            ),
            set_mutation(
                "notification-sequence-not-a-list",
                ("mediaServicesNotificationSequence",),
                {},
            ),
            set_mutation(
                "notification-record-extra-field",
                ("mediaServicesNotificationSequence", 0, "forged"),
                True,
            ),
            delete_mutation(
                "notification-record-missing-field",
                ("mediaServicesNotificationSequence", 0, "kind"),
            ),
            set_mutation(
                "notification-uptime-boolean",
                ("mediaServicesNotificationSequence", 0, "systemUptime"),
                True,
            ),
            set_mutation(
                "notification-uptime-nonfinite",
                ("mediaServicesNotificationSequence", 0, "systemUptime"),
                math.inf,
            ),
            set_mutation(
                "notification-uptime-nonpositive",
                ("mediaServicesNotificationSequence", 0, "systemUptime"),
                0,
            ),
            set_mutation(
                "native-extra-field",
                ("players", 0, "baseline", "native", "forged"),
                1,
            ),
            delete_mutation(
                "player-readiness-missing",
                ("players", 0, "readinessStart"),
            ),
            delete_mutation(
                "native-missing-field",
                ("players", 0, "baseline", "native", "brokerEpoch"),
            ),
            set_mutation(
                "native-version-boolean",
                ("players", 0, "baseline", "native", "version"),
                True,
            ),
            set_mutation(
                "native-version-unsupported",
                ("players", 0, "baseline", "native", "version"),
                2,
            ),
            set_mutation(
                "native-counter-boolean",
                (
                    "players",
                    0,
                    "baseline",
                    "native",
                    "successfulRebuildCount",
                ),
                False,
            ),
            set_mutation(
                "native-counter-negative",
                (
                    "players",
                    0,
                    "baseline",
                    "native",
                    "outputIncarnationCount",
                ),
                -1,
            ),
            set_mutation(
                "native-zero-epoch",
                ("players", 0, "baseline", "native", "brokerEpoch"),
                0,
            ),
            set_mutation(
                "native-invalid-phase",
                ("players", 0, "baseline", "native", "brokerPhase"),
                "recovering",
            ),
            set_mutation(
                "native-invalid-command-origin",
                ("players", 0, "baseline", "native", "commandOrigin"),
                "automatic",
            ),
            set_mutation(
                "native-dispatch-not-boolean",
                (
                    "players",
                    0,
                    "baseline",
                    "native",
                    "commandWasDispatched",
                ),
                1,
            ),
            set_mutation(
                "native-leases-exceed-owners",
                (
                    "players",
                    0,
                    "baseline",
                    "native",
                    "brokerLiveLeaseCount",
                ),
                4,
            ),
            set_mutation(
                "checkpoint-extra-field",
                ("players", 0, "baseline", "forged"),
                1,
            ),
            set_mutation(
                "checkpoint-uptime-boolean",
                ("players", 0, "baseline", "systemUptime"),
                True,
            ),
            set_mutation(
                "checkpoint-uptime-nonfinite",
                ("players", 0, "baseline", "systemUptime"),
                math.inf,
            ),
            set_mutation(
                "checkpoint-uptime-nonpositive",
                ("players", 0, "baseline", "systemUptime"),
                0,
            ),
            set_mutation(
                "checkpoint-invalid-state",
                ("players", 0, "baseline", "playerState"),
                "started",
            ),
            set_mutation(
                "checkpoint-intent-not-boolean",
                ("players", 0, "baseline", "playbackRequestedActive"),
                1,
            ),
            set_mutation(
                "playback-extra-field",
                ("players", 0, "baseline", "playback", "forged"),
                1,
            ),
            set_mutation(
                "playback-counter-boolean",
                (
                    "players",
                    0,
                    "baseline",
                    "playback",
                    "playedAudioBuffers",
                ),
                True,
            ),
            set_mutation(
                "playback-counter-negative",
                (
                    "players",
                    0,
                    "baseline",
                    "playback",
                    "lostAudioBuffers",
                ),
                -1,
            ),
        ]
        self.assert_rejected(evidence, self.validate_reset, mutations)

    def test_media_services_reset_rejects_header_role_and_pip_forgeries(self):
        evidence = reset_evidence()
        mutations = [
            set_mutation("wrong-scenario", ("scenario",), "interruptions"),
            set_mutation("synthetic-trigger", ("syntheticNotificationsPosted",), True),
            set_mutation("wrong-trigger", ("trigger",), "notification-center-post-v1"),
            set_mutation(
                "declared-lost-count-does-not-match-sequence",
                ("mediaServicesLostNotificationCount",),
                0,
            ),
            set_mutation(
                "missing-reset-notification",
                ("mediaServicesResetNotificationCount",),
                0,
            ),
            set_mutation(
                "empty-notification-sequence",
                ("mediaServicesNotificationSequence",),
                [],
            ),
            set_mutation(
                "unknown-notification-kind",
                ("mediaServicesNotificationSequence", 0, "kind"),
                "interruption",
            ),
            set_mutation(
                "declared-reset-count-does-not-match-sequence",
                ("mediaServicesResetNotificationCount",),
                2,
            ),
            sets_mutation(
                "sequence-has-no-reset",
                [
                    (("mediaServicesResetNotificationCount",), 0),
                    (
                        ("mediaServicesNotificationSequence",),
                        [{"kind": "lost", "systemUptime": 99.0}],
                    ),
                ],
            ),
            set_mutation(
                "notification-uptimes-go-backward",
                ("mediaServicesNotificationSequence", 1, "systemUptime"),
                98.5,
            ),
            sets_mutation(
                "lost-notification-follows-reset",
                [
                    (("mediaServicesNotificationSequence", 0, "kind"), "reset"),
                    (("mediaServicesNotificationSequence", 1, "kind"), "lost"),
                ],
            ),
            set_mutation(
                "pip-was-not-active", ("pictureInPictureActiveBeforeReset",), False
            ),
            set_mutation(
                "pip-not-active-after-recovery",
                ("pictureInPictureActiveAfterRecovery",),
                False,
            ),
            set_mutation("reset-epoch-oracle-forged", ("resetEpochProof",), "pass-ish"),
            set_mutation(
                "quarantine-oracle-forged", ("preIntentQuarantine",), "pass-ish"
            ),
            set_mutation(
                "recovery-oracle-forged", ("explicitResumeRecovery",), "pass-ish"
            ),
            set_mutation(
                "pip-motion-forged", ("systemPiPMotionAfterRecovery",), "not-observed"
            ),
            set_mutation(
                "pre-reset-pip-motion-forged",
                ("systemPiPMotionBeforeReset",),
                "not-observed",
            ),
            set_mutation(
                "source-token-forged",
                ("sourceRequestProof", "attemptToken"),
                "run-audio-ownership-1",
            ),
            set_mutation(
                "source-segments-insufficient",
                ("sourceRequestProof", "successfulSegments"),
                1,
            ),
            set_mutation(
                "source-mode-forged",
                ("sourceRequestProof", "modes"),
                ["vod-ts"],
            ),
            set_mutation(
                "forced-module-list-reordered",
                ("forcedOutputModules",),
                ["avsamplebuffer", "audiounit_ios"],
            ),
            set_mutation("library-error", ("libraryErrorCount",), 1),
            set_mutation("players-not-a-list", ("players",), {}),
            set_mutation("players-missing-role", ("players",), evidence["players"][:1]),
            set_mutation(
                "duplicate-player-role",
                ("players", 1, "role"),
                "audio-only",
            ),
            set_mutation(
                "role-module-mismatch",
                ("players", 0, "forcedAudioOutputModule"),
                "avsamplebuffer",
            ),
            set_mutation("player-extra-field", ("players", 0, "trusted"), "pass"),
        ]
        self.assert_rejected(evidence, self.validate_reset, mutations)

    def test_media_services_reset_rejects_quarantine_and_recovery_forgeries(self):
        evidence = reset_evidence()
        mutations = [
            set_mutation(
                "readiness-not-playing",
                ("players", 0, "readinessStart", "playerState"),
                "paused",
            ),
            set_mutation(
                "readiness-no-intent",
                ("players", 0, "readinessStart", "playbackRequestedActive"),
                False,
            ),
            set_mutation(
                "readiness-window-too-short",
                ("players", 0, "readinessStart", "systemUptime"),
                97.6,
            ),
            set_mutation(
                "readiness-window-too-long",
                ("players", 0, "readinessStart", "systemUptime"),
                95.0,
            ),
            set_mutation(
                "notification-precedes-latest-readiness",
                ("mediaServicesNotificationSequence", 0, "systemUptime"),
                97.5,
            ),
            set_mutation(
                "notification-too-far-after-latest-readiness",
                ("players", 0, "baseline", "systemUptime"),
                96.0,
            ),
            set_mutation(
                "readiness-broker-epoch-changed",
                ("players", 0, "readinessStart", "native", "brokerEpoch"),
                2,
            ),
            set_mutation(
                "readiness-owner-count-changed",
                (
                    "players",
                    0,
                    "readinessStart",
                    "native",
                    "brokerActiveOwnerCount",
                ),
                2,
            ),
            set_mutation(
                "readiness-media-time-did-not-progress",
                (
                    "players",
                    0,
                    "readinessStart",
                    "playback",
                    "mediaTimeMilliseconds",
                ),
                2_000,
            ),
            set_mutation(
                "readiness-audio-did-not-progress",
                (
                    "players",
                    0,
                    "readinessStart",
                    "playback",
                    "playedAudioBuffers",
                ),
                150,
            ),
            set_mutation(
                "readiness-video-did-not-progress",
                (
                    "players",
                    1,
                    "readinessStart",
                    "playback",
                    "displayedPictures",
                ),
                70,
            ),
            set_mutation(
                "baseline-not-playing",
                ("players", 0, "baseline", "playerState"),
                "paused",
            ),
            set_mutation(
                "baseline-no-intent",
                ("players", 0, "baseline", "playbackRequestedActive"),
                False,
            ),
            set_mutation(
                "baseline-output-not-live",
                ("players", 0, "baseline", "native", "liveOutputCount"),
                0,
            ),
            set_mutation(
                "baseline-no-audio-output",
                ("players", 0, "baseline", "playback", "playedAudioBuffers"),
                0,
            ),
            set_mutation(
                "baseline-process-owner-mismatch",
                (
                    "players",
                    1,
                    "baseline",
                    "native",
                    "brokerActiveOwnerCount",
                ),
                4,
            ),
            sets_mutation(
                "baseline-too-few-owners",
                [
                    (
                        (
                            "players",
                            index,
                            "baseline",
                            "native",
                            "brokerActiveOwnerCount",
                        ),
                        2,
                    )
                    for index in range(2)
                ],
            ),
            sets_mutation(
                "baseline-no-swift-lease",
                [
                    (
                        (
                            "players",
                            index,
                            "baseline",
                            "native",
                            "brokerLiveLeaseCount",
                        ),
                        0,
                    )
                    for index in range(2)
                ],
            ),
            set_mutation(
                "quarantine-start-not-paused",
                ("players", 0, "quarantineStart", "playerState"),
                "playing",
            ),
            set_mutation(
                "quarantine-end-intent-still-active",
                ("players", 0, "quarantineEnd", "playbackRequestedActive"),
                True,
            ),
            set_mutation(
                "quarantine-phase-lost",
                ("players", 0, "quarantineStart", "native", "brokerPhase"),
                "lost",
            ),
            set_mutation(
                "reset-epoch-did-not-advance",
                ("players", 0, "quarantineStart", "native", "brokerResetEpoch"),
                0,
            ),
            set_mutation(
                "reset-epoch-not-current-epoch",
                ("players", 0, "quarantineStart", "native", "brokerEpoch"),
                4,
            ),
            set_mutation(
                "quarantine-end-reset-epoch-changed",
                ("players", 0, "quarantineEnd", "native", "brokerResetEpoch"),
                4,
            ),
            set_mutation(
                "quarantine-owner-retained",
                (
                    "players",
                    0,
                    "quarantineStart",
                    "native",
                    "brokerActiveOwnerCount",
                ),
                1,
            ),
            set_mutation(
                "quarantine-lease-retained",
                (
                    "players",
                    0,
                    "quarantineEnd",
                    "native",
                    "brokerLiveLeaseCount",
                ),
                1,
            ),
            set_mutation(
                "quarantine-command-not-invalidating",
                ("players", 0, "quarantineStart", "native", "commandOrigin"),
                "explicitResume",
            ),
            set_mutation(
                "quarantine-command-dispatched",
                (
                    "players",
                    0,
                    "quarantineEnd",
                    "native",
                    "commandWasDispatched",
                ),
                True,
            ),
            sets_mutation(
                "quarantine-reset-already-acknowledged",
                [
                    (
                        (
                            "players",
                            0,
                            phase,
                            "native",
                            "acknowledgedResetEpoch",
                        ),
                        3,
                    )
                    for phase in ("quarantineStart", "quarantineEnd")
                ],
            ),
            set_mutation(
                "audio-advanced-during-quarantine",
                (
                    "players",
                    0,
                    "quarantineEnd",
                    "playback",
                    "playedAudioBuffers",
                ),
                151,
            ),
            set_mutation(
                "media-time-advanced-during-quarantine",
                (
                    "players",
                    0,
                    "quarantineEnd",
                    "playback",
                    "mediaTimeMilliseconds",
                ),
                2_001,
            ),
            set_mutation(
                "video-advanced-during-quarantine",
                (
                    "players",
                    1,
                    "quarantineEnd",
                    "playback",
                    "displayedPictures",
                ),
                71,
            ),
            set_mutation(
                "quarantine-shorter-than-three-seconds",
                ("players", 0, "quarantineEnd", "systemUptime"),
                102.999,
            ),
            set_mutation(
                "reported-quarantine-does-not-match-clock",
                ("quarantineObservationMilliseconds",),
                3_501,
            ),
            set_mutation(
                "recovered-not-playing",
                ("players", 0, "recovered", "playerState"),
                "paused",
            ),
            set_mutation(
                "recovered-has-no-fresh-intent",
                ("players", 0, "recovered", "playbackRequestedActive"),
                False,
            ),
            set_mutation(
                "recovery-not-explicit",
                ("players", 0, "recovered", "native", "commandOrigin"),
                "invalidating",
            ),
            set_mutation(
                "resume-command-not-dispatched",
                (
                    "players",
                    0,
                    "recovered",
                    "native",
                    "commandWasDispatched",
                ),
                False,
            ),
            set_mutation(
                "resume-command-bound-to-wrong-reset",
                ("players", 0, "recovered", "native", "commandResetEpoch"),
                1,
            ),
            set_mutation(
                "resume-command-not-acknowledged",
                (
                    "players",
                    0,
                    "recovered",
                    "native",
                    "acknowledgedResetEpoch",
                ),
                1,
            ),
            set_mutation(
                "command-generation-did-not-advance",
                ("players", 0, "recovered", "native", "commandGeneration"),
                8,
            ),
            set_mutation(
                "output-incarnation-did-not-advance",
                (
                    "players",
                    0,
                    "recovered",
                    "native",
                    "outputIncarnationCount",
                ),
                10,
            ),
            set_mutation(
                "successful-rebuild-did-not-advance",
                (
                    "players",
                    0,
                    "recovered",
                    "native",
                    "successfulRebuildCount",
                ),
                4,
            ),
            set_mutation(
                "resume-attempt-did-not-advance",
                (
                    "players",
                    0,
                    "recovered",
                    "native",
                    "explicitResumeAttemptCount",
                ),
                4,
            ),
            set_mutation(
                "resume-failure-recorded",
                (
                    "players",
                    0,
                    "recovered",
                    "native",
                    "explicitResumeFailureCount",
                ),
                1,
            ),
            set_mutation(
                "recovered-output-not-live",
                ("players", 0, "recovered", "native", "liveOutputCount"),
                0,
            ),
            set_mutation(
                "audio-did-not-resume",
                ("players", 0, "recovered", "playback", "playedAudioBuffers"),
                150,
            ),
            set_mutation(
                "media-time-did-not-resume",
                (
                    "players",
                    0,
                    "recovered",
                    "playback",
                    "mediaTimeMilliseconds",
                ),
                2_000,
            ),
            set_mutation(
                "video-did-not-resume",
                ("players", 1, "recovered", "playback", "displayedPictures"),
                70,
            ),
            sets_mutation(
                "players-recovered-different-reset-epochs",
                [
                    (
                        ("players", 1, phase, "native", field),
                        4,
                    )
                    for phase, fields in (
                        (
                            "quarantineStart",
                            ("brokerEpoch", "brokerResetEpoch", "commandResetEpoch"),
                        ),
                        (
                            "quarantineEnd",
                            ("brokerEpoch", "brokerResetEpoch", "commandResetEpoch"),
                        ),
                        (
                            "recovered",
                            (
                                "brokerEpoch",
                                "brokerResetEpoch",
                                "commandResetEpoch",
                                "acknowledgedResetEpoch",
                            ),
                        ),
                    )
                    for field in fields
                ],
            ),
            set_mutation(
                "recovered-process-owner-mismatch",
                (
                    "players",
                    1,
                    "recovered",
                    "native",
                    "brokerActiveOwnerCount",
                ),
                4,
            ),
            sets_mutation(
                "recovered-too-few-owners",
                [
                    (
                        (
                            "players",
                            index,
                            "recovered",
                            "native",
                            "brokerActiveOwnerCount",
                        ),
                        2,
                    )
                    for index in range(2)
                ],
            ),
            sets_mutation(
                "recovered-no-swift-lease",
                [
                    (
                        (
                            "players",
                            index,
                            "recovered",
                            "native",
                            "brokerLiveLeaseCount",
                        ),
                        0,
                    )
                    for index in range(2)
                ],
            ),
        ]
        self.assert_rejected(evidence, self.validate_reset, mutations)

    def test_media_services_reset_rejects_native_quarantine_or_epoch_forgery(self):
        evidence = reset_evidence()
        mutations = [
            set_mutation(
                "quarantine-end-epoch-is-not-reset-epoch",
                ("players", 0, "quarantineEnd", "native", "brokerEpoch"),
                4,
            ),
            set_mutation(
                "quarantine-end-phase-lost",
                ("players", 0, "quarantineEnd", "native", "brokerPhase"),
                "lost",
            ),
            set_mutation(
                "command-generation-changed-without-intent",
                (
                    "players",
                    0,
                    "quarantineEnd",
                    "native",
                    "commandGeneration",
                ),
                9,
            ),
            set_mutation(
                "command-reset-epoch-changed-without-intent",
                (
                    "players",
                    0,
                    "quarantineEnd",
                    "native",
                    "commandResetEpoch",
                ),
                4,
            ),
            set_mutation(
                "acknowledgement-changed-without-intent",
                (
                    "players",
                    0,
                    "quarantineEnd",
                    "native",
                    "acknowledgedResetEpoch",
                ),
                1,
            ),
            set_mutation(
                "incarnation-changed-at-quarantine-entry",
                (
                    "players",
                    0,
                    "quarantineStart",
                    "native",
                    "outputIncarnationCount",
                ),
                11,
            ),
            set_mutation(
                "output-rebuilt-at-quarantine-entry",
                (
                    "players",
                    0,
                    "quarantineStart",
                    "native",
                    "successfulRebuildCount",
                ),
                5,
            ),
            set_mutation(
                "resume-attempted-at-quarantine-entry",
                (
                    "players",
                    0,
                    "quarantineStart",
                    "native",
                    "explicitResumeAttemptCount",
                ),
                5,
            ),
            set_mutation(
                "resume-failed-at-quarantine-entry",
                (
                    "players",
                    0,
                    "quarantineStart",
                    "native",
                    "explicitResumeFailureCount",
                ),
                1,
            ),
            set_mutation(
                "output-rebuilt-before-fresh-intent",
                (
                    "players",
                    0,
                    "quarantineEnd",
                    "native",
                    "successfulRebuildCount",
                ),
                5,
            ),
            set_mutation(
                "resume-failed-before-fresh-intent",
                (
                    "players",
                    0,
                    "quarantineEnd",
                    "native",
                    "explicitResumeFailureCount",
                ),
                1,
            ),
            set_mutation(
                "incarnation-changed-before-fresh-intent",
                (
                    "players",
                    0,
                    "quarantineEnd",
                    "native",
                    "outputIncarnationCount",
                ),
                11,
            ),
            set_mutation(
                "resume-attempted-during-quarantine",
                (
                    "players",
                    0,
                    "quarantineEnd",
                    "native",
                    "explicitResumeAttemptCount",
                ),
                5,
            ),
            set_mutation(
                "recovered-broker-still-lost",
                ("players", 0, "recovered", "native", "brokerPhase"),
                "lost",
            ),
            set_mutation(
                "recovered-broker-reports-another-reset",
                ("players", 0, "recovered", "native", "brokerResetEpoch"),
                4,
            ),
        ]
        self.assert_rejected(evidence, self.validate_reset, mutations)

    def test_media_services_reset_retained_logs_are_exact_and_prove_modules(self):
        expected = {
            "audiounit": (
                "audiounit_ios",
                "analog AudioUnit output successfully opened for f32l Mono",
            ),
            "avsamplebuffer": (
                "avsamplebuffer",
                "AVSampleBufferAudioRenderer output opened as the priority-100 default",
            ),
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = self._install_logs(reset_evidence(), root, expected)
            policy.validate_audio_media_services_reset_evidence(
                evidence,
                retained_base=root,
                require_retained=True,
            )

            mutations = [
                (
                    "missing-child",
                    lambda value: value["hostErrorInventory"]["rawFiles"].pop(),
                ),
                (
                    "extra-child",
                    lambda value: value["hostErrorInventory"]["rawFiles"].append(
                        {
                            "childName": "unexpected",
                            "logRole": "child",
                            "path": "audiounit.jsonl",
                        }
                    ),
                ),
                set_mutation(
                    "wrong-child-role",
                    ("hostErrorInventory", "rawFiles", 0, "logRole"),
                    "base",
                ),
                set_mutation(
                    "child-name-substitution",
                    ("hostErrorInventory", "rawFiles", 0, "childName"),
                    "avsamplebuffer-copy",
                ),
            ]
            self.assert_rejected(
                evidence,
                lambda value: policy.validate_audio_media_services_reset_evidence(
                    value,
                    retained_base=root,
                    require_retained=True,
                ),
                mutations,
            )

            (root / "logs" / "audiounit.jsonl").write_text(
                json.dumps({"message": 'using audio output module "avsamplebuffer"'})
                + "\n"
                + json.dumps(
                    {
                        "message": "AVSampleBufferAudioRenderer output opened as the priority-100 default"
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                policy.QualificationPolicyError,
                "does not prove its forced output module",
            ):
                policy.validate_audio_media_services_reset_evidence(
                    evidence,
                    retained_base=root,
                    require_retained=True,
                )

        with self.assertRaisesRegex(
            policy.QualificationPolicyError, "no retained (?:artifact|log) base"
        ):
            policy.validate_audio_media_services_reset_evidence(
                reset_evidence(),
                retained_base=None,
                require_retained=True,
            )

    def test_audio_session_ownership_canonical_evidence_passes(self):
        evidence = ownership_evidence()
        policy.validate_audio_session_ownership_evidence(
            evidence,
            retained_base=None,
            require_retained=False,
        )
        self.validate_ownership(evidence)

    def test_audio_ownership_allows_registered_idle_module_objects(self):
        evidence = ownership_evidence()
        evidence["idleBrokerBeforePlayerConstruction"]["liveOutputCount"] = 1
        evidence["idleBrokerAfterPlayerConstruction"]["liveOutputCount"] = 1
        for cycle in evidence["libraryManagedCycles"]:
            cycle["afterFinalOutputRelease"]["native"]["liveOutputCount"] = 1
        for cycle in evidence["applicationManagedCycles"]:
            cycle["brokerBeforePlayback"]["liveOutputCount"] = 1
            cycle["brokerAfterPlayback"]["liveOutputCount"] = 1
        self.validate_ownership(evidence)
        # Registered objects never excuse a real owner or lease.
        for field in ("brokerActiveOwnerCount", "brokerLiveLeaseCount"):
            with self.subTest(field=field):
                acquired = copy.deepcopy(evidence)
                acquired["idleBrokerAfterPlayerConstruction"][field] = 1
                with self.assertRaises(policy.QualificationPolicyError):
                    self.validate_ownership(acquired)

    def test_audio_session_focus_probe_is_bound_to_the_signed_runner_identity(self):
        evidence = ownership_evidence()
        dynamic_identifier = "com.swiftvlc.validation.abcde12345.uitests.xctrunner"

        def rewrite_probe_identifiers(value: object) -> None:
            if isinstance(value, dict):
                if "probeApplicationBundleIdentifier" in value:
                    value["probeApplicationBundleIdentifier"] = dynamic_identifier
                for child in value.values():
                    rewrite_probe_identifiers(child)
            elif isinstance(value, list):
                for child in value:
                    rewrite_probe_identifiers(child)

        rewrite_probe_identifiers(evidence)
        policy.validate_audio_session_ownership_evidence(
            evidence,
            retained_base=None,
            require_retained=False,
            expected_probe_bundle_identifier=dynamic_identifier,
        )
        policy.validate_evidence_semantics(
            evidence,
            SCENARIOS["audio-session-ownership"],
            expected_probe_bundle_identifier=dynamic_identifier,
        )
        for mismatched_identifier in (
            policy.CANONICAL_TEST_RUNNER_BUNDLE_IDENTIFIER,
            "com.swiftvlc.validation.other.uitests.xctrunner",
        ):
            with self.subTest(identifier=mismatched_identifier):
                with self.assertRaises(policy.QualificationPolicyError):
                    policy.validate_audio_session_ownership_evidence(
                        evidence,
                        retained_base=None,
                        require_retained=False,
                        expected_probe_bundle_identifier=mismatched_identifier,
                    )

    def test_audio_session_ownership_v3_rejects_every_schema_boundary(self):
        evidence = ownership_evidence()
        mutations: list[Mutation] = [
            delete_mutation(f"missing-top-level-{key}", (key,))
            for key in sorted(policy.APPLE_AUDIO_OWNERSHIP_RAW_KEYS)
        ]
        mutations.extend(
            delete_mutation(
                f"missing-interruption-notification-{key}",
                ("interruptionNotificationSequence", 0, key),
            )
            for key in sorted(policy.APPLE_AUDIO_INTERRUPTION_NOTIFICATION_KEYS)
        )
        mutations.extend(
            delete_mutation(
                f"missing-session-{key}", ("idleSessionBeforePlayerConstruction", key)
            )
            for key in sorted(policy.APPLE_AUDIO_SESSION_CONFIGURATION_KEYS)
        )
        mutations.extend(
            delete_mutation(
                f"missing-library-cycle-{key}", ("libraryManagedCycles", 0, key)
            )
            for key in sorted(policy.APPLE_AUDIO_LIBRARY_OWNERSHIP_CYCLE_KEYS)
        )
        mutations.extend(
            delete_mutation(
                f"missing-application-cycle-{key}",
                ("applicationManagedCycles", 0, key),
            )
            for key in sorted(policy.APPLE_AUDIO_APPLICATION_OWNERSHIP_CYCLE_KEYS)
        )
        mutations.extend(
            delete_mutation(
                f"missing-focus-{key}",
                ("idleConstructionFocusProbe", key),
            )
            for key in sorted(policy.APPLE_AUDIO_FOCUS_PROBE_KEYS)
        )
        mutations.extend(
            delete_mutation(
                f"missing-source-proof-{key}",
                ("sourceRequestProof", key),
            )
            for key in sorted(policy.APPLE_AUDIO_SOURCE_REQUEST_PROOF_KEYS)
        )
        mutations.extend(
            [
                set_mutation("raw-extra-field", ("trustedUILabel",), "pass"),
                set_mutation(
                    "session-extra-field",
                    ("idleSessionBeforePlayerConstruction", "forged"),
                    1,
                ),
                set_mutation(
                    "library-cycle-extra-field",
                    ("libraryManagedCycles", 0, "forged"),
                    1,
                ),
                set_mutation(
                    "application-cycle-extra-field",
                    ("applicationManagedCycles", 0, "forged"),
                    1,
                ),
                set_mutation(
                    "focus-extra-field",
                    ("idleConstructionFocusProbe", "forged"),
                    1,
                ),
                set_mutation("format-version-boolean", ("formatVersion",), True),
                set_mutation("format-version-wrong", ("formatVersion",), 1),
                set_mutation("library-cycles-not-list", ("libraryManagedCycles",), {}),
                set_mutation(
                    "application-cycles-not-list",
                    ("applicationManagedCycles",),
                    {},
                ),
                set_mutation(
                    "session-sample-rate-boolean",
                    ("idleSessionBeforePlayerConstruction", "preferredSampleRate"),
                    True,
                ),
                set_mutation(
                    "session-buffer-nonfinite",
                    (
                        "idleSessionBeforePlayerConstruction",
                        "preferredIOBufferDuration",
                    ),
                    math.inf,
                ),
                set_mutation(
                    "session-input-channels-boolean",
                    (
                        "idleSessionBeforePlayerConstruction",
                        "preferredInputNumberOfChannels",
                    ),
                    False,
                ),
                set_mutation(
                    "session-output-channels-negative",
                    (
                        "idleSessionBeforePlayerConstruction",
                        "preferredOutputNumberOfChannels",
                    ),
                    -1,
                ),
                set_mutation(
                    "native-counter-boolean",
                    (
                        "libraryManagedCycles",
                        0,
                        "firstOutputActive",
                        "native",
                        "brokerActiveOwnerCount",
                    ),
                    True,
                ),
                set_mutation(
                    "checkpoint-uptime-nonfinite",
                    (
                        "libraryManagedCycles",
                        0,
                        "firstOutputActive",
                        "systemUptime",
                    ),
                    math.nan,
                ),
                set_mutation(
                    "playback-counter-boolean",
                    (
                        "libraryManagedCycles",
                        0,
                        "firstOutputPlaybackStart",
                        "playedAudioBuffers",
                    ),
                    True,
                ),
                set_mutation(
                    "focus-count-boolean",
                    (
                        "idleConstructionFocusProbe",
                        "candidateInterruptionBeganBefore",
                    ),
                    False,
                ),
                set_mutation(
                    "library-focus-missing-order",
                    ("libraryReleaseFocusProbes", 0, "forcedModuleOrder"),
                    None,
                ),
                set_mutation(
                    "application-focus-missing-module",
                    (
                        "applicationManagedReleaseFocusProbes",
                        0,
                        "forcedAudioOutputModule",
                    ),
                    None,
                ),
            ]
        )
        self.assert_rejected(evidence, self.validate_ownership, mutations)

    def test_audio_session_ownership_v3_rejects_causal_forgeries(self):
        evidence = ownership_evidence()
        mutations = [
            set_mutation("wrong-scenario", ("scenario",), "background-audio"),
            set_mutation(
                "library-module-header-reordered",
                ("libraryManagedForcedModules",),
                ["avsamplebuffer", "audiounit_ios"],
            ),
            set_mutation(
                "application-module-header-reordered",
                ("applicationManagedForcedModules",),
                ["avsamplebuffer", "audiounit_ios"],
            ),
            set_mutation(
                "library-cycle-missing",
                ("libraryManagedCycles",),
                evidence["libraryManagedCycles"][:1],
            ),
            set_mutation(
                "application-cycle-missing",
                ("applicationManagedCycles",),
                evidence["applicationManagedCycles"][:1],
            ),
            set_mutation(
                "direct-order-forged",
                ("libraryManagedCycles", 0, "forcedModuleOrder"),
                ["avsamplebuffer", "audiounit_ios"],
            ),
            set_mutation(
                "inverse-order-forged",
                ("libraryManagedCycles", 1, "forcedModuleOrder"),
                ["audiounit_ios", "avsamplebuffer"],
            ),
            set_mutation("idle-summary-forged", ("idleConstruction",), "pass-ish"),
            set_mutation("release-summary-forged", ("multiOwnerRelease",), "pass-ish"),
            set_mutation(
                "continuity-summary-forged",
                ("survivingOutputContinuity",),
                "pass-ish",
            ),
            set_mutation("final-summary-forged", ("finalDeactivation",), "pass-ish"),
            set_mutation(
                "application-summary-forged",
                ("applicationManagedNonMutation",),
                "pass-ish",
            ),
            set_mutation("library-error", ("libraryErrorCount",), 1),
            set_mutation(
                "idle-session-mutated",
                ("idleSessionAfterPlayerConstruction", "preferredSampleRate"),
                44_100.0,
            ),
            set_mutation(
                "idle-owner-acquired",
                ("idleBrokerAfterPlayerConstruction", "brokerActiveOwnerCount"),
                1,
            ),
            set_mutation(
                "idle-deactivated-session",
                (
                    "idleBrokerAfterPlayerConstruction",
                    "brokerSuccessfulDeactivationCount",
                ),
                3,
            ),
            set_mutation(
                "first-output-not-playing",
                ("libraryManagedCycles", 0, "firstOutputActive", "playerState"),
                "paused",
            ),
            set_mutation(
                "survivor-not-playing",
                (
                    "libraryManagedCycles",
                    0,
                    "afterFirstOutputRelease",
                    "playerState",
                ),
                "paused",
            ),
            set_mutation(
                "survivor-no-active-intent",
                (
                    "libraryManagedCycles",
                    0,
                    "afterFirstOutputRelease",
                    "playbackRequestedActive",
                ),
                False,
            ),
            set_mutation(
                "survivor-output-dead",
                (
                    "libraryManagedCycles",
                    0,
                    "afterFirstOutputRelease",
                    "native",
                    "liveOutputCount",
                ),
                0,
            ),
            set_mutation(
                "non-final-release-deactivated",
                (
                    "libraryManagedCycles",
                    0,
                    "afterFirstOutputRelease",
                    "native",
                    "brokerSuccessfulDeactivationCount",
                ),
                3,
            ),
            set_mutation(
                "survivor-media-time-frozen",
                (
                    "libraryManagedCycles",
                    0,
                    "secondOutputPlaybackEnd",
                    "mediaTimeMilliseconds",
                ),
                1_500,
            ),
            set_mutation(
                "survivor-audio-frozen",
                (
                    "libraryManagedCycles",
                    0,
                    "secondOutputPlaybackEnd",
                    "playedAudioBuffers",
                ),
                80,
            ),
            set_mutation(
                "direct-final-release-did-not-deactivate",
                (
                    "libraryManagedCycles",
                    0,
                    "afterFinalOutputRelease",
                    "native",
                    "brokerSuccessfulDeactivationCount",
                ),
                2,
            ),
            set_mutation(
                "inverse-final-release-did-not-deactivate",
                (
                    "libraryManagedCycles",
                    1,
                    "afterFinalOutputRelease",
                    "native",
                    "brokerSuccessfulDeactivationCount",
                ),
                3,
            ),
            set_mutation(
                "inverse-owner-sequence-forged",
                (
                    "libraryManagedCycles",
                    1,
                    "bothOutputsActive",
                    "native",
                    "brokerActiveOwnerCount",
                ),
                1,
            ),
            set_mutation(
                "checkpoint-order-forged",
                (
                    "libraryManagedCycles",
                    1,
                    "afterFirstOutputRelease",
                    "systemUptime",
                ),
                44.0,
            ),
            set_mutation(
                "application-module-forged",
                ("applicationManagedCycles", 0, "forcedAudioOutputModule"),
                "avsamplebuffer",
            ),
            set_mutation(
                "application-session-mutated",
                (
                    "applicationManagedCycles",
                    0,
                    "sessionAfterPlayback",
                    "preferredIOBufferDuration",
                ),
                0.01,
            ),
            set_mutation(
                "application-wrong-category",
                (
                    "applicationManagedCycles",
                    0,
                    "sessionBeforePlayback",
                    "category",
                ),
                "AVAudioSessionCategoryPlayAndRecord",
            ),
            set_mutation(
                "application-mutated-broker-owner",
                (
                    "applicationManagedCycles",
                    0,
                    "brokerDuringPlayback",
                    "brokerActiveOwnerCount",
                ),
                1,
            ),
            set_mutation(
                "application-output-not-live",
                (
                    "applicationManagedCycles",
                    1,
                    "brokerDuringPlayback",
                    "liveOutputCount",
                ),
                0,
            ),
            set_mutation(
                "application-lease-retained-after-shutdown",
                (
                    "applicationManagedCycles",
                    1,
                    "brokerAfterPlayback",
                    "brokerLiveLeaseCount",
                ),
                1,
            ),
            set_mutation(
                "application-media-time-frozen",
                ("applicationManagedCycles", 0, "playbackEnd", "mediaTimeMilliseconds"),
                3_000,
            ),
            set_mutation(
                "application-audio-frozen",
                ("applicationManagedCycles", 1, "playbackEnd", "playedAudioBuffers"),
                40,
            ),
            set_mutation(
                "mixed-broker-epoch",
                (
                    "applicationManagedCycles",
                    1,
                    "brokerDuringPlayback",
                    "brokerEpoch",
                ),
                2,
            ),
            set_mutation(
                "lost-broker-phase",
                (
                    "libraryManagedCycles",
                    1,
                    "bothOutputsActive",
                    "native",
                    "brokerPhase",
                ),
                "lost",
            ),
            set_mutation(
                "ownership-source-token-forged",
                ("sourceRequestProof", "attemptToken"),
                "run-audio-reset-1",
            ),
            set_mutation(
                "ownership-source-segments-insufficient",
                ("sourceRequestProof", "successfulSegments"),
                5,
            ),
        ]
        self.assert_rejected(evidence, self.validate_ownership, mutations)

    def test_audio_session_ownership_v3_rejects_focus_probe_forgeries(self):
        evidence = ownership_evidence()
        mutations = [
            set_mutation(
                "idle-probe-source-forged",
                ("idleConstructionFocusProbe", "source"),
                "showcase-app",
            ),
            set_mutation(
                "idle-probe-runner-bundle-forged",
                (
                    "idleConstructionFocusProbe",
                    "probeApplicationBundleIdentifier",
                ),
                "com.swiftvlc.showcase.ios",
            ),
            set_mutation(
                "idle-probe-runner-not-foreground",
                (
                    "idleConstructionFocusProbe",
                    "probeApplicationStateAtActivation",
                ),
                "runningBackground",
            ),
            set_mutation(
                "idle-probe-candidate-not-initially-foreground",
                (
                    "idleConstructionFocusProbe",
                    "candidateApplicationStateBeforeProbe",
                ),
                "runningBackground",
            ),
            set_mutation(
                "idle-probe-candidate-still-foreground",
                (
                    "idleConstructionFocusProbe",
                    "candidateApplicationStateDuringActivation",
                ),
                "runningForeground",
            ),
            set_mutation(
                "idle-probe-candidate-not-restored",
                (
                    "idleConstructionFocusProbe",
                    "candidateApplicationStateAfterProbe",
                ),
                "runningBackground",
            ),
            set_mutation(
                "idle-probe-interrupted",
                (
                    "idleConstructionFocusProbe",
                    "candidateInterruptionBeganDelta",
                ),
                1,
            ),
            set_mutation(
                "library-probe-order-forged",
                ("libraryReleaseFocusProbes", 0, "forcedModuleOrder"),
                ["avsamplebuffer", "audiounit_ios"],
            ),
            set_mutation(
                "library-probe-interrupted-after-probe",
                (
                    "libraryReleaseFocusProbes",
                    1,
                    "candidateInterruptionBeganAfterProbe",
                ),
                1,
            ),
            set_mutation(
                "application-probe-no-began",
                (
                    "applicationManagedReleaseFocusProbes",
                    0,
                    "candidateInterruptionBeganAfterProbe",
                ),
                0,
            ),
            set_mutation(
                "application-probe-ended-before-runner-deactivated",
                ("interruptionNotificationSequence", 1, "systemUptime"),
                40.9,
            ),
            set_mutation(
                "application-probe-no-ended",
                (
                    "applicationManagedReleaseFocusProbes",
                    1,
                    "candidateInterruptionEndedAfterProbe",
                ),
                1,
            ),
            set_mutation(
                "application-probe-began-before-activation",
                ("interruptionNotificationSequence", 0, "systemUptime"),
                39.9,
            ),
            set_mutation(
                "application-probe-interruption-reason-forged",
                ("interruptionNotificationSequence", 0, "reasonRawValue"),
                1,
            ),
            set_mutation(
                "application-probe-interruption-kind-forged",
                ("interruptionNotificationSequence", 0, "kind"),
                "ended",
            ),
            set_mutation(
                "application-probe-began-after-deactivation-started",
                ("interruptionNotificationSequence", 0, "systemUptime"),
                41.1,
            ),
            set_mutation(
                "application-probe-ended-after-observation",
                ("interruptionNotificationSequence", 3, "systemUptime"),
                51.7,
            ),
            set_mutation(
                "focus-probe-windows-overlap",
                (
                    "applicationManagedReleaseFocusProbes",
                    0,
                    "activationBeganSystemUptime",
                ),
                31.5,
            ),
            set_mutation(
                "application-probe-cumulative-count-forged",
                (
                    "applicationManagedReleaseFocusProbes",
                    1,
                    "candidateInterruptionBeganBefore",
                ),
                0,
            ),
            set_mutation(
                "application-probe-module-forged",
                (
                    "applicationManagedReleaseFocusProbes",
                    1,
                    "forcedAudioOutputModule",
                ),
                "audiounit_ios",
            ),
            set_mutation(
                "application-probe-phase-forged",
                ("applicationManagedReleaseFocusProbes", 0, "phase"),
                "application-active",
            ),
            set_mutation(
                "host-release-probe-interrupted",
                (
                    "hostReleaseFocusProbe",
                    "candidateInterruptionEndedAfterProbe",
                ),
                3,
            ),
            set_mutation(
                "host-release-probe-outcome-forged",
                ("hostReleaseFocusProbe", "outcome"),
                "candidate-session-active-after-output-teardown",
            ),
        ]
        self.assert_rejected(evidence, self.validate_ownership, mutations)

    def test_audio_session_ownership_v3_retained_logs_bind_exact_modules(self):
        expected = {
            "library-order1-audiounit": (
                "audiounit_ios",
                "analog AudioUnit output successfully opened for f32l Mono",
            ),
            "library-order1-avsamplebuffer": (
                "avsamplebuffer",
                "AVSampleBufferAudioRenderer output opened as the priority-100 default",
            ),
            "library-order2-avsamplebuffer": (
                "avsamplebuffer",
                "AVSampleBufferAudioRenderer output opened as the priority-100 default",
            ),
            "library-order2-audiounit": (
                "audiounit_ios",
                "analog AudioUnit output successfully opened for f32l Mono",
            ),
            "application-audiounit": (
                "audiounit_ios",
                "analog AudioUnit output successfully opened for f32l Mono",
            ),
            "application-avsamplebuffer": (
                "avsamplebuffer",
                "AVSampleBufferAudioRenderer output opened as the priority-100 default",
            ),
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = self._install_logs(ownership_evidence(), root, expected)
            policy.validate_audio_session_ownership_evidence(
                evidence,
                retained_base=root,
                require_retained=True,
            )

            mutations = [
                (
                    "missing-child",
                    lambda value: value["hostErrorInventory"]["rawFiles"].pop(),
                ),
                (
                    "extra-child",
                    lambda value: value["hostErrorInventory"]["rawFiles"].append(
                        {
                            "childName": "unexpected",
                            "logRole": "child",
                            "path": "library-order1-audiounit.jsonl",
                        }
                    ),
                ),
                set_mutation(
                    "wrong-child-role",
                    ("hostErrorInventory", "rawFiles", 0, "logRole"),
                    "base",
                ),
            ]
            self.assert_rejected(
                evidence,
                lambda value: policy.validate_audio_session_ownership_evidence(
                    value,
                    retained_base=root,
                    require_retained=True,
                ),
                mutations,
            )

            audio_unit_log = root / "logs" / "library-order1-audiounit.jsonl"
            audio_unit_log.write_text(
                "\n".join(
                    json.dumps({"message": message})
                    for message in (
                        'using audio output module "audiounit_ios"',
                        'using audio output module "avsamplebuffer"',
                        "analog AudioUnit output successfully opened for f32l Mono",
                    )
                )
                + "\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                policy.QualificationPolicyError,
                "does not prove its forced output module",
            ):
                policy.validate_audio_session_ownership_evidence(
                    evidence,
                    retained_base=root,
                    require_retained=True,
                )

            audio_unit_log.write_text(
                json.dumps({"message": 'using audio output module "audiounit_ios"'})
                + "\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                policy.QualificationPolicyError,
                "does not prove its forced output module",
            ):
                policy.validate_audio_session_ownership_evidence(
                    evidence,
                    retained_base=root,
                    require_retained=True,
                )

            audio_unit_log.write_text(
                json.dumps({"message": 'using audio output module "audiounit_ios"'})
                + "\n"
                + json.dumps({"message": "analog AudioUnit output successfully opened"})
                + "\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                policy.QualificationPolicyError,
                "does not prove its forced output module",
            ):
                policy.validate_audio_session_ownership_evidence(
                    evidence,
                    retained_base=root,
                    require_retained=True,
                )

            audio_unit_log.write_text(
                json.dumps({"message": 'using audio output module "audiounit_ios"'})
                + "\n"
                + json.dumps(
                    {
                        "message": "analog AudioUnit output successfully opened for f32l Mono eventually"
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                policy.QualificationPolicyError,
                "does not prove its forced output module",
            ):
                policy.validate_audio_session_ownership_evidence(
                    evidence,
                    retained_base=root,
                    require_retained=True,
                )

    @staticmethod
    def _install_logs(
        evidence: dict,
        root: Path,
        messages: dict[str, tuple[str, str]],
    ) -> dict:
        candidate = copy.deepcopy(evidence)
        retained = root / "logs"
        retained.mkdir()
        records = []
        for child, (module, message) in messages.items():
            name = f"{child}.jsonl"
            (retained / name).write_text(
                json.dumps({"message": f'using audio output module "{module}"'})
                + "\n"
                + json.dumps({"message": message})
                + "\n",
                encoding="utf-8",
            )
            records.append(
                {
                    "childName": child,
                    "logRole": "child",
                    "path": name,
                }
            )
        candidate["hostErrorInventory"] = {
            "retainedRoot": "logs",
            "rawFiles": records,
        }
        proof = candidate["sourceRequestProof"]
        metrics_path = root / proof["metricsRelativePath"]
        metrics_path.parent.mkdir(parents=True)
        metrics_path.write_text(
            json.dumps(source_metrics(proof), sort_keys=True) + "\n",
            encoding="utf-8",
        )
        proof["metricsDigest"] = policy.sha256_file(metrics_path)
        proof["metricsSizeBytes"] = metrics_path.stat().st_size
        return candidate


if __name__ == "__main__":
    unittest.main()
