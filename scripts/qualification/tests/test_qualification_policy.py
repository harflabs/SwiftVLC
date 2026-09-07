from __future__ import annotations

import base64
import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock
from pathlib import Path

QUALIFICATION = Path(__file__).resolve().parents[1]


def load_script(name: str):
    path = QUALIFICATION / name
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


policy = load_script("qualification_policy.py")
verify_fixtures = load_script("verify-fixtures.py")
materialize = load_script("materialize-evidence.py")
assemble_record = load_script("assemble-record.py")


class QualificationPolicyTests(unittest.TestCase):
    def test_release_report_rejects_noncanonical_qualification_evidence_path(self):
        harness_path = QUALIFICATION / "tests" / "test_qualification_harness.py"
        harness_spec = importlib.util.spec_from_file_location(
            "qualification_harness_release_evidence_fixture", harness_path
        )
        harness = importlib.util.module_from_spec(harness_spec)
        assert harness_spec.loader is not None
        harness_spec.loader.exec_module(harness)

        fixture = harness.QualificationRecordAssemblyTests(
            methodName="test_report_result_must_reconcile_with_runner_results"
        )
        fixture.setUp()
        try:
            report_path = fixture.make_report("iphone", validate_receipt=False)
            matrix = json.loads(fixture.matrix.read_text())
            matrix["releasePolicyIdentity"] = policy.RELEASE_MATRIX_POLICY_IDENTITY

            with mock.patch.object(
                harness.assemble_record.policy,
                "validate_release_matrix_contract",
            ):
                with self.assertRaisesRegex(
                    harness.assemble_record.policy.QualificationPolicyError,
                    "release qualification row 0 evidence path must be "
                    "'evidence/seek-iphone.json'",
                ):
                    harness.assemble_record.policy.validate_report(
                        report_path,
                        matrix,
                        candidate=json.loads(fixture.candidate.read_text()),
                        stable_required=True,
                        strict_provenance=True,
                    )
        finally:
            fixture.tearDown()

    def test_ordinary_report_rejects_release_gate_contract_tampering(self):
        harness_path = QUALIFICATION / "tests" / "test_qualification_harness.py"
        harness_spec = importlib.util.spec_from_file_location(
            "qualification_harness_fixture", harness_path
        )
        harness = importlib.util.module_from_spec(harness_spec)
        assert harness_spec.loader is not None
        harness_spec.loader.exec_module(harness)

        fixture = harness.QualificationRecordAssemblyTests(
            methodName="test_report_result_must_reconcile_with_runner_results"
        )
        fixture.setUp()
        try:
            report_path = fixture.make_report("iphone")
            canonical = json.loads(report_path.read_text())
            canonical["releaseGateReason"] = policy.ORDINARY_RELEASE_GATE_REASON
            report_path.write_text(json.dumps(canonical))

            harness.assemble_record.policy.validate_report(
                report_path,
                json.loads(fixture.matrix.read_text()),
                candidate=json.loads(fixture.candidate.read_text()),
                stable_required=True,
                strict_provenance=True,
            )

            mutations = {
                "report-only": {"reportOnly": True},
                "release-gate-satisfied": {"releaseGateSatisfied": True},
                "release-gate-reason": {"releaseGateReason": "complete release gate"},
            }
            for label, mutation in mutations.items():
                with self.subTest(label=label):
                    tampered = self.clone(canonical)
                    tampered.update(mutation)
                    report_path.write_text(json.dumps(tampered))
                    with self.assertRaisesRegex(
                        harness.assemble_record.policy.QualificationPolicyError,
                        "ordinary device report release-gate contract failed",
                    ):
                        harness.assemble_record.policy.validate_report(
                            report_path,
                            json.loads(fixture.matrix.read_text()),
                            candidate=json.loads(fixture.candidate.read_text()),
                            stable_required=True,
                            strict_provenance=True,
                        )
        finally:
            fixture.tearDown()

    def test_ordinary_report_binds_runner_exit_code_to_final_attempt(self):
        harness_path = QUALIFICATION / "tests" / "test_qualification_harness.py"
        harness_spec = importlib.util.spec_from_file_location(
            "qualification_harness_exit_fixture", harness_path
        )
        harness = importlib.util.module_from_spec(harness_spec)
        assert harness_spec.loader is not None
        harness_spec.loader.exec_module(harness)

        def validate(fixture, report_path):
            return harness.assemble_record.policy.validate_report(
                report_path,
                json.loads(fixture.matrix.read_text()),
                candidate=json.loads(fixture.candidate.read_text()),
                stable_required=True,
                strict_provenance=True,
            )

        passing_fixture = harness.QualificationRecordAssemblyTests(
            methodName="test_report_result_must_reconcile_with_runner_results"
        )
        passing_fixture.setUp()
        try:
            passing_report = passing_fixture.make_report("iphone")
            canonical_pass = json.loads(passing_report.read_text())
            validate(passing_fixture, passing_report)
            pass_mutations = {
                "top-level-type": lambda payload: payload["scenarios"][0].update(
                    {"xcodebuildExitCode": False}
                ),
                "top-level-nonzero": lambda payload: payload["scenarios"][0].update(
                    {"xcodebuildExitCode": 65}
                ),
                "final-attempt-type": lambda payload: payload["scenarios"][0][
                    "attempts"
                ][-1].update({"xcodebuildExitCode": False}),
            }
            for label, mutate in pass_mutations.items():
                with self.subTest(result="pass", label=label):
                    tampered = self.clone(canonical_pass)
                    mutate(tampered)
                    passing_report.write_text(json.dumps(tampered))
                    with self.assertRaises(
                        harness.assemble_record.policy.QualificationPolicyError
                    ):
                        validate(passing_fixture, passing_report)
        finally:
            passing_fixture.tearDown()

        failed_fixture = harness.QualificationRecordAssemblyTests(
            methodName="test_failed_output_runner_validates_without_a_qualification_row"
        )
        failed_fixture.setUp()
        try:
            failed_report = failed_fixture.make_report("iphone")
            failed_payload = json.loads(failed_report.read_text())
            runner = failed_payload["scenarios"][0]
            attempt_root = failed_report.parent / runner["attemptArtifactRoot"]
            attempt_log = attempt_root / "attempt-1.log"
            attempt_bundle = attempt_root / "attempt-1.xcresult"
            attempt_log.write_text(
                "** TEST EXECUTE FAILED **\n"
                "Test Case '-[iOSUITests.FixtureQualificationTests test_fixture]' failed.\n"
            )
            failed_document = {
                "testNodes": [
                    {
                        "nodeType": "Test Case",
                        "nodeIdentifier": failed_fixture.catalog[0],
                        "result": "Failed",
                    },
                    {
                        "nodeType": "Failure Message",
                        "name": "XCTAssertTrue failed",
                    },
                ]
            }
            with mock.patch.object(
                harness.assemble_record.policy,
                "xcresult_test_document",
                return_value=failed_document,
            ):
                classification = harness.assemble_record.policy.classify_retry(
                    attempt_bundle,
                    attempt_log.read_text(),
                    runner["expectedTestCatalog"],
                )
                runner.update(
                    {
                        "result": "fail",
                        "xcodebuildExitCode": 65,
                        "qualificationEvidence": "missing",
                        "testExecution": None,
                        "attempts": harness.assemble_record.policy.bind_attempt_artifacts(
                            [
                                {
                                    **classification,
                                    "attempt": 1,
                                    "xcodebuildExitCode": 65,
                                    "terminalReason": "XCTest failed",
                                    "logArtifact": attempt_log.relative_to(
                                        failed_report.parent
                                    ).as_posix(),
                                    "xcresultArtifact": attempt_bundle.relative_to(
                                        failed_report.parent
                                    ).as_posix(),
                                }
                            ],
                            failed_report.parent,
                        ),
                    }
                )
                failed_payload["result"] = "fail"
                failed_payload["qualificationRows"] = []
                failed_report.write_text(json.dumps(failed_payload))
                validate(failed_fixture, failed_report)

                fail_mutations = {
                    "top-level-type": lambda payload: payload["scenarios"][0].update(
                        {"xcodebuildExitCode": "65"}
                    ),
                    "final-attempt-mismatch": lambda payload: payload["scenarios"][0].update(
                        {"xcodebuildExitCode": 0}
                    ),
                    "final-attempt-type": lambda payload: payload["scenarios"][0][
                        "attempts"
                    ][-1].update({"xcodebuildExitCode": True}),
                }
                for label, mutate in fail_mutations.items():
                    with self.subTest(result="fail", label=label):
                        tampered = self.clone(failed_payload)
                        mutate(tampered)
                        failed_report.write_text(json.dumps(tampered))
                        with self.assertRaises(
                            harness.assemble_record.policy.QualificationPolicyError
                        ):
                            validate(failed_fixture, failed_report)
        finally:
            failed_fixture.tearDown()

    def test_report_timing_enforces_exact_duration_and_stable_freshness(self):
        now = datetime(2026, 9, 2, 12, 0, tzinfo=timezone.utc)
        completed = now - timedelta(
            seconds=policy.MAXIMUM_STABLE_REPORT_AGE_SECONDS
        )
        started = completed - timedelta(seconds=75)
        report = {
            "startedAtUTC": started.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "completedAtUTC": completed.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "wallDurationSeconds": 75,
        }
        policy.validate_report_timing(report, stable=True, now_utc=now)

        stale = self.clone(report)
        stale_completed = completed - timedelta(seconds=1)
        stale_started = stale_completed - timedelta(seconds=75)
        stale["startedAtUTC"] = stale_started.strftime("%Y-%m-%dT%H:%M:%SZ")
        stale["completedAtUTC"] = stale_completed.strftime("%Y-%m-%dT%H:%M:%SZ")
        with self.assertRaisesRegex(policy.QualificationPolicyError, "is stale"):
            policy.validate_report_timing(stale, stable=True, now_utc=now)

        mismatched = self.clone(report)
        mismatched["wallDurationSeconds"] = 74
        with self.assertRaisesRegex(
            policy.QualificationPolicyError, "does not match its UTC interval"
        ):
            policy.validate_report_timing(mismatched, stable=True, now_utc=now)

    def test_report_timing_rejects_excessive_future_clock_skew(self):
        now = datetime(2026, 9, 2, 12, 0, tzinfo=timezone.utc)
        completed = now + timedelta(
            seconds=policy.MAXIMUM_REPORT_CLOCK_SKEW_SECONDS + 1
        )
        report = {
            "startedAtUTC": completed.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "completedAtUTC": completed.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "wallDurationSeconds": 0,
        }
        with self.assertRaisesRegex(policy.QualificationPolicyError, "in the future"):
            policy.validate_report_timing(report, stable=False, now_utc=now)

    @staticmethod
    def seek_frame_evidence() -> dict:
        return {
            "seekResults": {
                "precise": "pass",
                "fastKeyframe": "pass",
                "overlap": "pass",
            },
            "seekOracle": {
                "preciseTimelineSeconds": 23.5,
                "fastTimelineSeconds": 40.0,
                "overlapTimelineSeconds": 52.5,
                "contentSource": "xcui-video-surface-screenshot",
            },
            "seekClock": {
                "preciseMilliseconds": 23500,
                "fastMilliseconds": 40000,
                "overlapMilliseconds": 52500,
            },
            "seekOutcomes": {
                "precise": "settled",
                "fast": "settled",
                "overlap": [
                    "superseded",
                    "superseded",
                    "superseded",
                    "settled",
                ],
            },
            "frameResults": {
                "single": "pass",
                "burst": "pass",
                "resumeClock": "pass",
                "eof": "pass",
                "replacement": "pass",
            },
            "frameOracle": {
                "baselineIndex": 10,
                "singleIndex": 11,
                "burstBaselineIndex": 11,
                "burstFinalIndex": 31,
                "resumeBaselineIndex": 31,
                "resumeFinalIndex": 40,
                "eofIndex": 119,
                "baselineClockMilliseconds": 1000,
                "resumeClockMilliseconds": 4000,
                "singleSubmittedTimeMilliseconds": 1100,
                "burstSubmittedTimesMilliseconds": list(range(1200, 3200, 100)),
                "eofSubmittedTimesMilliseconds": [11600, 11700, 11800, 11900],
                "contentSource": "xcui-video-surface-screenshot",
            },
            "frameTerminals": {
                "single": "submitted",
                "burst": ["submitted"] * 20,
                "eof": ["submitted"] * 4 + ["noFrame"],
                "replacement": ["superseded"] * 12,
            },
            "libraryErrorCount": 0,
        }

    @staticmethod
    def clone(value):
        return json.loads(json.dumps(value))

    @staticmethod
    def native_hls_seek_identity_evidence() -> dict:
        identity = {
            "nativeHandleIdentity": 101,
            "playbackGeneration": 7,
            "outputIdentity": 303,
        }
        return {
            "nativeOutputIdentityStable": True,
            "commandEvidence": {
                command: {
                    "mediaGeneration": 7,
                    "baselinePiPOutputIdentity": dict(identity),
                    "landingPiPOutputIdentity": dict(identity),
                }
                for command in ("forward", "backward", "absolute")
            },
        }

    @staticmethod
    def catalog_bound_terminal_log_fixture(root: Path) -> dict:
        scenario = "terminal-outcomes"
        identifier = "iOSUITests/FixtureTests/test_terminalOutcomes"
        invocation = "00000000-0000-4000-8000-000000000001"
        health = {
            "ts": "2026-08-31T12:00:00Z",
            "level": "debug",
            "module": policy.LOG_MIRROR_HEALTH_MODULE,
            "message": policy.LOG_MIRROR_HEALTH_MESSAGE,
        }
        attributed_errors = {
            "source": {
                "level": "error",
                "module": "http stream",
                "message": "HTTP access connection closed",
            },
            "demux": {
                "level": "error",
                "module": "mp4 demux",
                "message": "demux invalid format",
            },
            "decoder": {
                "level": "error",
                "module": "avcodec decoder",
                "message": "decoder codec failed",
            },
            "renderer": {
                "level": "error",
                "module": "main video output",
                "message": "renderer failed",
            },
            "output": {
                "level": "error",
                "module": "main audio output",
                "message": "video output failed",
            },
        }

        def write_jsonl(path: Path, records: list[dict]) -> None:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(
                "".join(json.dumps(record, sort_keys=True) + "\n" for record in records)
            )

        base = root / policy.test_log_filename("run", identifier, invocation)
        write_jsonl(base, [health])
        children = {}
        cases = {}
        for action, (cause, classification) in policy.TERMINAL_ERROR_ACTIONS.items():
            error = (
                None
                if classification is None
                else attributed_errors[classification]
            )
            child = f"terminal-outcomes-{action}"
            child_path = root / policy.test_log_filename(
                "run", identifier, invocation, child=child
            )
            write_jsonl(child_path, [health, *([] if error is None else [error])])
            children[child] = child_path
            cases[action] = {
                "action": action,
                "outcome": {
                    "cause": cause,
                    "failureClassification": classification,
                },
                "libraryErrors": (
                    []
                    if error is None
                    else [{"module": error["module"], "message": error["message"]}]
                ),
            }
        return {
            "scenario": scenario,
            "catalog": policy.catalog_record([identifier]),
            "identifier": identifier,
            "invocation": invocation,
            "health": health,
            "base": base,
            "children": children,
            "cases": cases,
        }

    @staticmethod
    def local_playback_evidence(root: Path, scenario_id: str) -> dict:
        kind = "video" if scenario_id == "local-file-matrix" else "audio"
        files = {}
        results = []
        frames = [
            bytes([component]) * policy._VISUAL_FRAME_BYTE_COUNT
            for component in (0, 64, 128)
        ]
        hashes = [policy._canonical_visual_frame_hash(frame) for frame in frames]
        ratios = [
            policy._canonical_visual_changed_pixel_ratio(first, second)
            for first, second in zip(frames, frames[1:])
        ]
        for contract_kind in ("video", "audio"):
            for fixture in policy.LOCAL_PLAYBACK_FIXTURE_CONTRACT[contract_kind]:
                payload = f"fixture-{fixture['id']}".encode()
                files[fixture["path"]] = {
                    "bytes": len(payload),
                    "sha256": hashlib.sha256(payload).hexdigest(),
                }
        for index, fixture in enumerate(policy.LOCAL_PLAYBACK_FIXTURE_CONTRACT[kind]):
            payload = f"fixture-{fixture['id']}".encode()
            digest = hashlib.sha256(payload).hexdigest()
            start = {
                "timeMilliseconds": 500,
                "readBytes": 100,
                "demuxReadBytes": 100,
                "decodedVideo": 10 if kind == "video" else 0,
                "decodedAudio": 10,
                "displayedPictures": 10 if kind == "video" else 0,
                "lostPictures": 0,
                "playedAudioBuffers": 10,
                "lostAudioBuffers": 0,
            }
            end = {
                **start,
                "timeMilliseconds": 3_700,
                "readBytes": 200,
                "demuxReadBytes": 200,
                "decodedVideo": 100 if kind == "video" else 0,
                "decodedAudio": 100,
                "displayedPictures": 100 if kind == "video" else 0,
                "playedAudioBuffers": 100,
            }
            result = {
                "fixture": policy._local_playback_raw_fixture(fixture, kind),
                "sourceScheme": "file",
                "localFileName": fixture["path"].replace("/", "-"),
                "downloadedSHA256": digest,
                "downloadedBytes": len(payload),
                "generationBefore": f"generation {index}",
                "generationAfter": f"generation {index + 1}",
                "stateSequence": ["opening", "buffering", "playing"],
                "durationMilliseconds": 12_000,
                "measurementDurationMilliseconds": 3_500,
                "measurementStartSystemUptime": 1000.0 + index * 10,
                "measurementEndSystemUptime": 1003.5 + index * 10,
                "start": start,
                "end": end,
            }
            if kind == "video":
                result["visualCapture"] = {
                    "formatVersion": 1,
                    "method": policy.VISUAL_OBSERVATION_METHOD,
                    "encoding": "base64-rgb8-row-major",
                    "frameWidthPixels": policy._VISUAL_FRAME_WIDTH,
                    "frameHeightPixels": policy._VISUAL_FRAME_HEIGHT,
                    "channelCount": policy._VISUAL_FRAME_CHANNELS,
                    "bytesPerFrame": policy._VISUAL_FRAME_BYTE_COUNT,
                    "frameCount": 3,
                    "captureSystemUptimeSeconds": [
                        1000.1 + index * 10,
                        1000.45 + index * 10,
                        1000.8 + index * 10,
                    ],
                    "canonicalRGB8Base64": [
                        base64.b64encode(frame).decode() for frame in frames
                    ],
                    "frameHashes": hashes,
                    "adjacentChangedPixelRatios": ratios,
                    "changedPixelScore": min(ratios),
                    "distinctFrameHashes": 3,
                }
            results.append(result)
        manifest = {
            "formatVersion": 1,
            "localPlayback": policy.LOCAL_PLAYBACK_FIXTURE_CONTRACT,
            "files": files,
        }
        manifest_path = root / "fixture-manifest.json"
        manifest_path.write_text(json.dumps(manifest, sort_keys=True) + "\n")
        return {
            "formatVersion": 1,
            "scenario": scenario_id,
            "durationSeconds": 60,
            "matrixOutcome": "pass",
            "fixtureResults": results,
            "libraryErrorCount": 0,
            "fixtureManifestChecksum": policy.sha256_file(manifest_path),
        }

    @staticmethod
    def progressive_http_range_evidence(root: Path) -> tuple[dict, Path, dict]:
        root.mkdir(parents=True, exist_ok=True)
        fixture_bytes = 50_000_123
        fixture_sha256 = "4" * 64
        manifest = {
            "formatVersion": 1,
            "oracles": {
                "progressiveHTTPRange": policy.PROGRESSIVE_HTTP_RANGE_FIXTURE_CONTRACT
            },
            "files": {
                policy.PROGRESSIVE_HTTP_RANGE_FIXTURE_CONTRACT["path"]: {
                    "bytes": fixture_bytes,
                    "sha256": fixture_sha256,
                }
            },
        }
        manifest_path = root / "fixture-manifest.json"
        manifest_path.write_text(json.dumps(manifest, sort_keys=True) + "\n")

        def visual(
            background: tuple[int, int, int],
            marker_positions: tuple[int, int, int],
            capture_centers: tuple[float, float, float],
            *,
            cycle: int = 0,
        ) -> dict:
            frames = []
            for marker_x in marker_positions:
                frame = bytearray(background * (64 * 36))
                for y in range(10, 26):
                    for x in range(marker_x, marker_x + 2):
                        offset = (y * 64 + x) * 3
                        frame[offset : offset + 3] = b"\xff\xff\xff"
                if cycle == 1:
                    for y in range(30, 34):
                        for x in range(48, 60):
                            offset = (y * 64 + x) * 3
                            frame[offset : offset + 3] = b"\xff\xff\xff"
                frames.append(bytes(frame))
            hashes = [policy._canonical_visual_frame_hash(frame) for frame in frames]
            ratios = [
                policy._canonical_visual_changed_pixel_ratio(first, second)
                for first, second in zip(frames, frames[1:])
            ]
            value = {
                "formatVersion": 1,
                "method": policy.VISUAL_OBSERVATION_METHOD,
                "encoding": "base64-rgb8-row-major",
                "frameWidthPixels": 64,
                "frameHeightPixels": 36,
                "channelCount": 3,
                "bytesPerFrame": 6912,
                "frameCount": 3,
                "captureSystemUptimeIntervals": [
                    {
                        "startSystemUptimeSeconds": center - 0.025,
                        "endSystemUptimeSeconds": center + 0.025,
                    }
                    for center in capture_centers
                ],
                "canonicalRGB8Base64": [
                    base64.b64encode(frame).decode() for frame in frames
                ],
                "frameHashes": hashes,
                "adjacentChangedPixelRatios": ratios,
                "changedPixelScore": min(ratios),
                "distinctFrameHashes": 3,
            }
            observations = [
                policy._progressive_frame_band_and_time(frame) for frame in frames
            ]
            value["decodedBandIndices"] = [item[0] for item in observations]
            value["decodedTimelineSeconds"] = [item[1] for item in observations]
            return value

        def snapshot(
            uptime: float,
            time_ms: int,
            seekable: bool,
            read_bytes: int,
            decoded: int,
            displayed: int,
        ) -> dict:
            return {
                "systemUptimeSeconds": uptime,
                "playbackGeneration": "generation 1",
                "state": "playing",
                "currentTimeMilliseconds": time_ms,
                "durationMilliseconds": 120_000,
                "isSeekable": seekable,
                "readBytes": read_bytes,
                "demuxReadBytes": read_bytes,
                "decodedVideo": decoded,
                "displayedPictures": displayed,
                "lostPictures": 0,
            }

        token = "release-progressive-http-range-seek-attempt1"
        range_pre_started = "2026-09-01T00:00:00+00:00"
        range_marked = "2026-09-01T00:00:01+00:00"
        range_post_started = "2026-09-01T00:00:02+00:00"
        range_post_completed = "2026-09-01T00:00:03+00:00"
        range_pre_completed = "2026-09-01T00:00:04+00:00"
        no_range_pre_started = "2026-09-01T00:00:05+00:00"
        no_range_marked = "2026-09-01T00:00:06+00:00"
        no_range_pre_completed = "2026-09-01T00:00:07+00:00"
        transcript = {
            "formatVersion": 1,
            "token": token,
            "fixtureRelativePath": policy.PROGRESSIVE_HTTP_RANGE_FIXTURE_CONTRACT[
                "path"
            ],
            "fixtureBytes": fixture_bytes,
            "events": [
                {
                    "kind": "media-request",
                    "sequence": 1,
                    "token": token,
                    "mode": "range",
                    "phase": "pre-command",
                    "method": "GET",
                    "path": f"/progressive/{token}/range/media.mp4",
                    "fixtureRelativePath": policy.PROGRESSIVE_HTTP_RANGE_FIXTURE_CONTRACT[
                        "path"
                    ],
                    "requestRange": "bytes=0-",
                    "responseStatus": 206,
                    "responseContentRange": f"bytes 0-{fixture_bytes - 1}/{fixture_bytes}",
                    "acceptRanges": "bytes",
                    "responseContentLength": fixture_bytes,
                    "transferredBytes": 100_000,
                    "transferredBytesAtCommand": 100_000,
                    "completed": False,
                    "startedAtUTC": range_pre_started,
                    "completedAtUTC": range_pre_completed,
                },
                {
                    "kind": "command-marker",
                    "sequence": 2,
                    "token": token,
                    "mode": "range",
                    "phase": "post-command",
                    "origin": policy.PROGRESSIVE_HTTP_COMMAND_ORIGIN,
                    "precommandRequestCount": 1,
                    "precommandTransferredBytes": 100_000,
                    "markedAtUTC": range_marked,
                },
                {
                    "kind": "media-request",
                    "sequence": 3,
                    "token": token,
                    "mode": "range",
                    "phase": "post-command",
                    "method": "GET",
                    "path": f"/progressive/{token}/range/media.mp4",
                    "fixtureRelativePath": policy.PROGRESSIVE_HTTP_RANGE_FIXTURE_CONTRACT[
                        "path"
                    ],
                    "requestRange": "bytes=10000000-10999999",
                    "responseStatus": 206,
                    "responseContentRange": f"bytes 10000000-10999999/{fixture_bytes}",
                    "acceptRanges": "bytes",
                    "responseContentLength": 1_000_000,
                    "transferredBytes": 300_000,
                    "transferredBytesAtCommand": None,
                    "completed": False,
                    "startedAtUTC": range_post_started,
                    "completedAtUTC": range_post_completed,
                },
                {
                    "kind": "media-request",
                    "sequence": 4,
                    "token": token,
                    "mode": "no-range",
                    "phase": "pre-command",
                    "method": "GET",
                    "path": f"/progressive/{token}/no-range/media.mp4",
                    "fixtureRelativePath": policy.PROGRESSIVE_HTTP_RANGE_FIXTURE_CONTRACT[
                        "path"
                    ],
                    "requestRange": "bytes=0-",
                    "responseStatus": 200,
                    "responseContentRange": None,
                    "acceptRanges": None,
                    "responseContentLength": fixture_bytes,
                    "transferredBytes": 120_000,
                    "transferredBytesAtCommand": 120_000,
                    "completed": False,
                    "startedAtUTC": no_range_pre_started,
                    "completedAtUTC": no_range_pre_completed,
                },
                {
                    "kind": "command-marker",
                    "sequence": 5,
                    "token": token,
                    "mode": "no-range",
                    "phase": "post-command",
                    "origin": policy.PROGRESSIVE_HTTP_COMMAND_ORIGIN,
                    "precommandRequestCount": 1,
                    "precommandTransferredBytes": 120_000,
                    "markedAtUTC": no_range_marked,
                },
            ],
        }
        transcript_root = (
            root
            / "progressive-http-range-seek-server-transcripts"
            / "release-progressive-http-range-seek"
        )
        transcript_root.mkdir(parents=True)
        transcript_path = transcript_root / "attempt-1.json"
        transcript_path.write_text(json.dumps(transcript, sort_keys=True) + "\n")
        evidence = {
            "formatVersion": 1,
            "scenario": "progressive-http-range-seek",
            "fixture": {
                "id": "progressive-http-range-mp4",
                "relativePath": policy.PROGRESSIVE_HTTP_RANGE_FIXTURE_CONTRACT["path"],
                "sha256": fixture_sha256,
                "bytes": fixture_bytes,
                "durationMilliseconds": 120_000,
                "targetMilliseconds": 43_500,
                "landingBoundaryMilliseconds": 40_000,
            },
            "attemptToken": token,
            "rangeCase": {
                "mode": "range",
                "attemptToken": token,
                "sourcePath": f"/progressive/{token}/range/media.mp4",
                "targetMilliseconds": 43_500,
                "landingBoundaryMilliseconds": 40_000,
                "typedSeek": {
                    "commandAttemptToken": token,
                    "playbackGeneration": "generation 1",
                    "targetMilliseconds": 43_500,
                    "fast": False,
                    "initialOutcome": "pending",
                    "terminalOutcome": "settled",
                },
                "start": snapshot(100, 1_500, True, 100, 10, 10),
                "landing": snapshot(101, 43_500, True, 200, 20, 20),
                "end": snapshot(102, 44_500, True, 300, 30, 30),
                "visualCapture": visual(
                    (0xA0, 0x20, 0xA0),
                    (23, 24, 25),
                    (101.1, 101.4, 101.7),
                ),
            },
            "noRangeCase": {
                "mode": "no-range",
                "attemptToken": token,
                "sourcePath": f"/progressive/{token}/no-range/media.mp4",
                "targetMilliseconds": 43_500,
                "seekableAtCommand": False,
                "typedRejection": {
                    "commandAttemptToken": token,
                    "playbackGeneration": "generation 1",
                    "errorDomain": "SwiftVLC.VLCError",
                    "errorCase": "invalidState",
                    "message": "current media is not seekable",
                    "commandDispatched": False,
                },
                "start": snapshot(200, 1_000, False, 100, 10, 10),
                "end": snapshot(202, 3_000, False, 300, 30, 30),
                "visualCapture": visual(
                    (0xC0, 0x20, 0x20),
                    (12, 13, 14),
                    (200.5, 201, 201.5),
                ),
            },
            "libraryErrorCount": 0,
            "fixtureManifestChecksum": policy.sha256_file(manifest_path),
            "hostErrorInventory": {"logPrefix": token},
            "qualificationProducer": {"sourceAttempt": 1},
            "progressiveServerTranscripts": [
                {
                    "sourceAttempt": 1,
                    "attemptToken": token,
                    "relativePath": (
                        "progressive-http-range-seek-server-transcripts/"
                        "release-progressive-http-range-seek/attempt-1.json"
                    ),
                    "digestAlgorithm": "sha256",
                    "digest": policy.sha256_file(transcript_path),
                    "sizeBytes": transcript_path.stat().st_size,
                    "eventCount": len(transcript["events"]),
                }
            ],
        }
        return evidence, transcript_path, transcript

    @staticmethod
    def endurance_evidence(scenario_id: str) -> dict:
        duration = policy.STABLE_MINIMUM_DURATION_SECONDS[scenario_id]
        evidence = {
            "durationSeconds": duration,
            "deviceObservedDurationSeconds": duration,
            "hostAttemptDurationSeconds": duration,
        }
        if scenario_id in {"timebase-vod-soak", "timebase-live-soak"}:
            evidence["rawCapture"] = {
                "timelineStartSeconds": 0,
                "timelineEndSeconds": duration,
                "maximumSampleGapSeconds": 1,
                "sampleCount": duration,
                "driftSampleCount": duration,
                "missingTimelineSeconds": 0,
            }
        else:
            elapsed_values = list(
                range(0, duration, policy.ENDURANCE_SERIES_MAXIMUM_GAP_SECONDS)
            )
            if not elapsed_values or elapsed_values[-1] != duration:
                elapsed_values.append(duration)
            series = [{"elapsedSeconds": elapsed} for elapsed in elapsed_values]
            path = policy.ENDURANCE_SERIES_PATHS[scenario_id]
            if path == "metrics.samples":
                evidence["metrics"] = {"samples": series}
            else:
                evidence[path] = series
        return evidence

    @staticmethod
    def adaptive_oracle_evidence(duration: int = 7200) -> dict:
        windows = []
        checkpoints = []
        memory_series = []
        modes = sorted(policy.ADAPTIVE_MODES)
        for start in range(0, duration, policy.ADAPTIVE_PROGRESS_WINDOW_SECONDS):
            mode = modes[
                (start // policy.ADAPTIVE_PROGRESS_WINDOW_SECONDS) % len(modes)
            ]
            end = min(
                duration,
                start + policy.ADAPTIVE_PROGRESS_WINDOW_SECONDS - 1,
            )
            if duration - end <= policy.ENDURANCE_HOST_EARLY_TOLERANCE_SECONDS:
                end = duration
            base = start * 100 + 1
            for elapsed, offset in ((start, 0), (end, 1)):
                memory_series.append(
                    {
                        "elapsedSeconds": elapsed,
                        "mode": mode,
                        "residentBytes": 100_000_000,
                        "mallocBytesInUse": 50_000_000,
                        "mallocBytesAllocated": 60_000_000,
                        "playerState": "playing",
                        "readBytes": base + offset * 1024,
                        "decodedVideoFrames": base + offset * 60,
                        "displayedPictures": base + offset * 60,
                        "demuxDiscontinuities": 0,
                    }
                )
            windows.append(
                {
                    "mode": mode,
                    "startElapsedSeconds": start,
                    "endElapsedSeconds": end,
                    "readBytesDelta": 1024,
                    "decodedVideoFramesDelta": 60,
                    "displayedPicturesDelta": 60,
                }
            )
            checkpoints.append(
                {
                    "elapsedSeconds": start,
                    "mode": mode,
                    "motionScore": 0.5,
                    "distinctFrameHashes": 3,
                }
            )
        return {
            "deviceObservedDurationSeconds": duration,
            "memorySeries": memory_series,
            "visualObservations": {
                "formatVersion": 1,
                "method": policy.VISUAL_OBSERVATION_METHOD,
                "records": [
                    {
                        "elapsedSeconds": checkpoint["elapsedSeconds"],
                        "mode": checkpoint["mode"],
                        "frameHashes": ["a" * 64, "b" * 64, "c" * 64],
                        "adjacentChangedPixelRatios": [
                            checkpoint["motionScore"],
                            checkpoint["motionScore"],
                        ],
                        "changedPixelScore": checkpoint["motionScore"],
                    }
                    for checkpoint in checkpoints
                ],
            },
            "playbackProgress": {
                "formatVersion": 1,
                "windowSeconds": policy.ADAPTIVE_PROGRESS_WINDOW_SECONDS,
                "modes": modes,
                "windows": windows,
            },
            "visualOracle": {
                "formatVersion": 1,
                "method": policy.VISUAL_OBSERVATION_METHOD,
                "maximumMotionGapSeconds": policy.ADAPTIVE_PROGRESS_WINDOW_SECONDS,
                "checkpoints": checkpoints,
            },
        }

    @staticmethod
    def cadence_oracle_evidence() -> dict:
        def histogram_from_deltas(deltas: list[int]) -> dict[int, int]:
            result: dict[int, int] = {}
            for delta in deltas:
                result[delta] = result.get(delta, 0) + 1
            return dict(sorted(result.items()))

        def cfr_deltas(profile: str, requested_rate: float) -> list[int]:
            numerator, denominator = policy.CADENCE_CFR_SOURCE_RATE_RATIONALS[profile]
            source_frames = round(
                (numerator / denominator)
                * requested_rate
                * policy.CADENCE_WINDOW_SECONDS
            )
            timestamps = [
                frame * 1_000_000 * denominator // numerator
                for frame in range(source_frames + 1)
            ]
            return [
                current - previous
                for previous, current in zip(timestamps, timestamps[1:])
            ]

        def vfr_deltas(requested_rate: float) -> list[int]:
            target = round(requested_rate * policy.CADENCE_WINDOW_SECONDS * 1_000_000)
            timestamps = {0, target}
            segment = 0
            while segment * 2_000_000 <= target:
                start = segment * 2_000_000
                fps = 24 if segment % 2 == 0 else 60
                for frame in range(fps * 2):
                    timestamp = start + frame * 1_000_000 // fps
                    if timestamp <= target:
                        timestamps.add(timestamp)
                segment += 1
            ordered = sorted(timestamps)
            return [
                current - previous for previous, current in zip(ordered, ordered[1:])
            ]

        windows = []
        samples = []
        elapsed = 0
        generation = 1
        visual_records = []
        visual_capture_bindings = []
        profiles = [*policy.CADENCE_CFR_SOURCE_RATES, "vfr-24-60"]
        metric_totals = {profile: 0 for profile in profiles}
        for profile in profiles:
            for requested_rate in (0.5, 1, 2):
                duration = policy.CADENCE_WINDOW_SECONDS
                deltas = (
                    vfr_deltas(float(requested_rate))
                    if profile == "vfr-24-60"
                    else cfr_deltas(profile, float(requested_rate))
                )
                histogram = histogram_from_deltas(deltas)
                callback_count = len(deltas)
                native_span_us = sum(deltas)
                metric_totals[profile] += callback_count
                zero_counts = {key: 0 for key in policy.CADENCE_INTERVAL_COUNT_KEYS}
                base_sample = {
                    "profile": profile,
                    "sourceIntervalCounts": zero_counts,
                    "systemUptime": 1000.0 + elapsed,
                    "elapsedSeconds": elapsed,
                    "playbackGeneration": generation,
                    "requestedRate": requested_rate,
                    "effectivePlayerRate": requested_rate,
                    "lastPTSSeconds": 10.0,
                    "deliveredFrames": 1,
                    "droppedFrames": 0,
                    "backpressureEvents": 0,
                    "vmemOutputTimestampProvenance": (
                        policy.CADENCE_VMEM_OUTPUT_TIMESTAMP_PROVENANCE
                    ),
                    "vmemOutputPlaybackGeneration": generation,
                    "vmemOutputVoutGeneration": generation,
                    "vmemOutputCallbackCount": 1,
                    "vmemOutputValidPTSCount": 1,
                    "vmemOutputInvalidPTSCount": 0,
                    "vmemOutputDuplicatePTSCount": 0,
                    "vmemOutputBackwardPTSCount": 0,
                    "vmemOutputDeltaOverflowCount": 0,
                    "vmemOutputSubmittedCount": 1,
                    "vmemOutputSwiftRejectedCount": 0,
                    "vmemOutputInFlightCount": 0,
                    "vmemOutputFirstPTSUS": 0,
                    "vmemOutputLastPTSUS": 0,
                    "vmemOutputFirstValidPTSUS": 0,
                    "vmemOutputLastValidPTSUS": 0,
                    "vmemOutputDeltaHistogram": [],
                    "vmemOutputIntervalCounts": zero_counts,
                    "libVLCDecodedVideoCount": 1,
                    "libVLCDisplayedPictureCount": 1,
                    "libVLCLostPictureCount": 0,
                    "libVLCLatePictureCount": 0,
                }
                final_sample = {
                    **base_sample,
                    "systemUptime": 1000.0 + elapsed + duration,
                    "elapsedSeconds": elapsed + duration,
                    "lastPTSSeconds": 10.0 + requested_rate * duration,
                    "deliveredFrames": 1 + callback_count,
                    "vmemOutputCallbackCount": 1 + callback_count,
                    "vmemOutputValidPTSCount": 1 + callback_count,
                    "vmemOutputSubmittedCount": 1 + callback_count,
                    "vmemOutputLastPTSUS": native_span_us,
                    "vmemOutputLastValidPTSUS": native_span_us,
                    "vmemOutputDeltaHistogram": [
                        {"deltaMicroseconds": delta, "count": count}
                        for delta, count in histogram.items()
                    ],
                    "libVLCDecodedVideoCount": 1 + callback_count,
                    "libVLCDisplayedPictureCount": 1 + callback_count,
                }
                samples.extend([base_sample, final_sample])

                frames = [
                    bytes([channel]) * policy._VISUAL_FRAME_BYTE_COUNT
                    for channel in (0, 64, 128)
                ]
                frame_hashes = [
                    policy._canonical_visual_frame_hash(frame) for frame in frames
                ]
                ratios = [
                    policy._canonical_visual_changed_pixel_ratio(first, second)
                    for first, second in zip(frames, frames[1:])
                ]
                motion_score = min(ratios)
                classification = policy._classify_cadence_window_histogram(
                    profile, histogram
                )
                minimum_fps = policy._cadence_minimum_submission_fps(
                    profile=profile,
                    applied_rate=float(requested_rate),
                    window_duration=float(duration),
                    start_pts_us=0,
                    end_pts_us=native_span_us,
                )
                windows.append(
                    {
                        "profile": profile,
                        "requestedRate": requested_rate,
                        "startElapsedSeconds": elapsed,
                        "durationSeconds": duration,
                        "windowStartSystemUptime": 1000.0 + elapsed,
                        "windowEndSystemUptime": 1000.0 + elapsed + duration,
                        "windowDurationSeconds": float(duration),
                        "appliedRate": requested_rate,
                        "nativePTSDeltaSeconds": native_span_us / 1_000_000,
                        **classification,
                        "nativePTSDeltaOverflowCount": 0,
                        "nativePTSDeltaHistogram": [
                            {"deltaMicroseconds": delta, "count": count}
                            for delta, count in histogram.items()
                        ],
                        "outputCallbackCount": callback_count,
                        "submittedFrames": callback_count,
                        "swiftRejectedFrames": 0,
                        "observedSubmissionFPS": callback_count / duration,
                        "minimumSubmissionFPS": minimum_fps,
                        "libVLCDecodedVideoDelta": callback_count,
                        "libVLCDisplayedPictureDelta": callback_count,
                        "libVLCLostPictureDelta": 0,
                        "libVLCLatePictureDelta": 0,
                        "deliveredFrames": callback_count,
                        "visualMotionScore": motion_score,
                        "distinctFrameHashes": 3,
                    }
                )
                visual_records.append(
                    {
                        "startElapsedSeconds": elapsed,
                        "durationSeconds": duration,
                        "profile": profile,
                        "requestedRate": requested_rate,
                        "frameHashes": frame_hashes,
                        "adjacentChangedPixelRatios": ratios,
                        "changedPixelScore": motion_score,
                    }
                )
                visual_capture_bindings.append(
                    {
                        "profile": profile,
                        "requestedRate": requested_rate,
                        "startElapsedSeconds": elapsed,
                        "durationSeconds": duration,
                        "windowStartSystemUptime": 1000.0 + elapsed,
                        "windowEndSystemUptime": 1000.0 + elapsed + duration,
                        "captureElapsedSeconds": [
                            elapsed + 1.25,
                            elapsed + 2.5,
                            elapsed + 3.75,
                        ],
                        "captureSystemUptimes": [
                            1000.0 + elapsed + 1.25,
                            1000.0 + elapsed + 2.5,
                            1000.0 + elapsed + 3.75,
                        ],
                        "canonicalRGB8Base64": [
                            base64.b64encode(frame).decode("ascii") for frame in frames
                        ],
                    }
                )
                elapsed += duration + 1
                generation += 1
        return {
            "durationSeconds": 600,
            "startedSystemUptime": 1000.0,
            "rates": [23.976, 24, 25, 29.97, 30, 50, 59.94, 60],
            "vfr": True,
            "sourceTimestampProvenance": policy.CADENCE_SOURCE_TIMESTAMP_PROVENANCE,
            "vmemOutputTimestampProvenance": (
                policy.CADENCE_VMEM_OUTPUT_TIMESTAMP_PROVENANCE
            ),
            "samples": samples,
            "visualObservations": {
                "formatVersion": 1,
                "method": policy.VISUAL_OBSERVATION_METHOD,
                "records": visual_records,
            },
            "visualCaptureBindings": {
                "formatVersion": 1,
                "method": policy.VISUAL_OBSERVATION_METHOD,
                "records": visual_capture_bindings,
            },
            "cadenceOracle": {
                "formatVersion": 1,
                "windowSeconds": policy.CADENCE_WINDOW_SECONDS,
                "rateToleranceFraction": policy.CADENCE_RATE_TOLERANCE_FRACTION,
                "minimumVisualMotionScore": (
                    policy.CADENCE_VISUAL_MOTION_MINIMUM_SCORE
                ),
                "vfrObservedRegimesFPS": [24.0, 60.0],
                "windows": windows,
            },
            "presentationMetrics": [
                {
                    "profile": profile,
                    "deliveredFrames": metric_totals[profile],
                    "droppedFrames": 0,
                    "dropRate": 0.0,
                    "elapsedSeconds": 30.0,
                    "presentationRate": metric_totals[profile] / 30.0,
                    "backpressureEvents": 0,
                    "presentationCopyFailures": 0,
                    "displayConsumeFailures": 0,
                }
                for profile in policy.CADENCE_PROFILE_ORDER
            ],
            "transitionResults": {
                "rateChanges": len(policy.CADENCE_PROFILE_ORDER) * 4,
                "pauseResumeCycles": len(policy.CADENCE_PROFILE_ORDER),
                "replacements": len(policy.CADENCE_PROFILE_ORDER) - 1,
                "resizeCycles": 1,
                "resizeTargets": ["640x360", "960x540"],
                "monotonicityViolations": 0,
            },
            "springboardResizeGestures": 6,
            "fabricatedDurationCount": 0,
        }

    @staticmethod
    def cadence_semantics_probe_payload() -> dict:
        def histogram_from_deltas(deltas: list[int]) -> dict[int, int]:
            result: dict[int, int] = {}
            for delta in deltas:
                result[delta] = result.get(delta, 0) + 1
            return dict(sorted(result.items()))

        def deltas_for(profile: str, requested_rate: float) -> list[int]:
            target = round(
                requested_rate * policy.CADENCE_WINDOW_SECONDS * 1_000_000
            )
            if profile == "vfr-24-60":
                timestamps = {0, target}
                segment = 0
                while segment * 2_000_000 <= target:
                    start = segment * 2_000_000
                    fps = 24 if segment % 2 == 0 else 60
                    for frame in range(fps * 2):
                        timestamp = start + frame * 1_000_000 // fps
                        if timestamp <= target:
                            timestamps.add(timestamp)
                    segment += 1
                ordered = sorted(timestamps)
            else:
                numerator, denominator = (
                    policy.CADENCE_CFR_SOURCE_RATE_RATIONALS[profile]
                )
                source_frames = round(
                    (numerator / denominator)
                    * requested_rate
                    * policy.CADENCE_WINDOW_SECONDS
                )
                ordered = [
                    frame * 1_000_000 * denominator // numerator
                    for frame in range(source_frames + 1)
                ]
            return [
                current - previous
                for previous, current in zip(ordered, ordered[1:])
            ]

        renderer_fields = policy.CADENCE_SEMANTICS_PROBE_RENDERER_COUNTERS
        renderer_progress = {
            "vmemLockAttempts",
            "vmemLockSuccesses",
            "vmemUnlockCallbacks",
            "vmemDisplayCallbacks",
            "enqueuedFrames",
            "deliveredFrames",
            "presentationCopyFrames",
        }
        windows = []
        visual_records = []
        first_start = 1005.0
        for index, (profile, requested_rate) in enumerate(
            policy.CADENCE_SEMANTICS_PROBE_EXPECTED_WINDOWS
        ):
            duration = float(policy.CADENCE_WINDOW_SECONDS)
            window_start = first_start + index * (duration + 3)
            window_end = window_start + duration
            deltas = deltas_for(profile, requested_rate)
            histogram = histogram_from_deltas(deltas)
            callbacks = len(deltas)
            native_span = sum(deltas)
            generation = index + 1

            before = {
                "systemUptime": window_start,
                "playbackGeneration": generation,
                "isPlaybackActive": True,
                "isPictureInPictureActive": True,
                "requestedRate": requested_rate,
                "effectivePlayerRate": requested_rate,
                "mediaTimeSeconds": 10.0,
                "controlTimebaseSeconds": 20.0,
                "controlTimebaseRate": requested_rate,
                "vmemOutputTimestampProvenance": (
                    policy.CADENCE_VMEM_OUTPUT_TIMESTAMP_PROVENANCE
                ),
                "vmemOutputPlaybackGeneration": generation,
                "vmemOutputVoutGeneration": generation,
                "vmemOutputLastValidPTSUS": 0,
                "vmemOutputDeltaHistogram": [],
                "vmemOutputCallbackCount": 1,
                "vmemOutputValidPTSCount": 1,
                "vmemOutputInvalidPTSCount": 0,
                "vmemOutputDuplicatePTSCount": 0,
                "vmemOutputBackwardPTSCount": 0,
                "vmemOutputDeltaOverflowCount": 0,
                "vmemOutputSubmittedCount": 1,
                "vmemOutputSwiftRejectedCount": 0,
                "vmemOutputInFlightCount": 0,
                "libVLCDecodedVideoCount": 1,
                "libVLCDisplayedPictureCount": 1,
                "libVLCLostPictureCount": 0,
                "libVLCLatePictureCount": 0,
            }
            renderer_deltas = {}
            for output, snapshot_field in renderer_fields.items():
                progressing = output in renderer_progress
                before[snapshot_field] = 1 if progressing else 0
                renderer_deltas[output] = callbacks if progressing else 0
            after = {
                **before,
                "systemUptime": window_end,
                "mediaTimeSeconds": 10.0 + requested_rate * duration,
                "controlTimebaseSeconds": 20.0 + requested_rate * duration,
                "vmemOutputLastValidPTSUS": native_span,
                "vmemOutputDeltaHistogram": [
                    {"deltaMicroseconds": delta, "count": count}
                    for delta, count in histogram.items()
                ],
                "vmemOutputCallbackCount": 1 + callbacks,
                "vmemOutputValidPTSCount": 1 + callbacks,
                "vmemOutputSubmittedCount": 1 + callbacks,
                "libVLCDecodedVideoCount": 1 + callbacks,
                "libVLCDisplayedPictureCount": 1 + callbacks,
            }
            for output, snapshot_field in renderer_fields.items():
                after[snapshot_field] = before[snapshot_field] + renderer_deltas[output]
            classified = policy._classify_cadence_window_histogram(
                profile, histogram
            )
            classification = {
                "exactIntervalCount": classified["nativePTSExactIntervalCount"],
                "multipleIntervalCount": classified[
                    "nativePTSMultipleIntervalCount"
                ],
                "estimatedSkippedPictureCount": classified[
                    "nativePTSEstimatedSkippedPictureCount"
                ],
                "redisplayCount": classified["nativePTSRedisplayCount"],
                "backwardCount": classified["nativePTSBackwardCount"],
                "unclassifiedIntervalCount": classified[
                    "nativePTSUnclassifiedIntervalCount"
                ],
                "deltaOverflowCount": 0,
            }
            histogram_items = [
                {"deltaMicroseconds": delta, "count": count}
                for delta, count in histogram.items()
            ]
            windows.append(
                {
                    "profile": profile,
                    "requestedRate": requested_rate,
                    "windowStartSystemUptime": window_start,
                    "windowEndSystemUptime": window_end,
                    "windowDurationSeconds": duration,
                    "effectivePlayerRateStart": requested_rate,
                    "effectivePlayerRateEnd": requested_rate,
                    "controlTimebaseRateStart": requested_rate,
                    "controlTimebaseRateEnd": requested_rate,
                    "controlTimebaseDeltaSeconds": requested_rate * duration,
                    "mediaTimeDeltaSeconds": requested_rate * duration,
                    "nativePTSDeltaSeconds": native_span / 1_000_000,
                    "nativePTSDeltaMatchesHistogram": True,
                    "nativePTSDeltaHistogram": histogram_items,
                    "nativePTSClassification": classification,
                    "outputCallbackCount": callbacks,
                    "validPTSCount": callbacks,
                    "invalidPTSCount": 0,
                    "submittedFrames": callbacks,
                    "swiftRejectedFrames": 0,
                    "inFlightStart": 0,
                    "inFlightEnd": 0,
                    "callbackConservationAtStart": True,
                    "callbackConservationAtEnd": True,
                    "callbackDeltaConservation": True,
                    "observedSubmissionFPS": callbacks / duration,
                    "renderer": renderer_deltas,
                    "libVLC": {
                        "decodedVideo": callbacks,
                        "displayedPictures": callbacks,
                        "lostPictures": 0,
                        "latePictures": 0,
                    },
                    "before": before,
                    "after": after,
                }
            )
            frames = [
                bytes([channel]) * policy._VISUAL_FRAME_BYTE_COUNT
                for channel in (0, 64, 128)
            ]
            hashes = [
                policy._canonical_visual_frame_hash(frame) for frame in frames
            ]
            ratios = [
                policy._canonical_visual_changed_pixel_ratio(first, second)
                for first, second in zip(frames, frames[1:])
            ]
            visual_records.append(
                {
                    "profile": profile,
                    "requestedRate": requested_rate,
                    "windowStartSystemUptime": window_start,
                    "windowEndSystemUptime": window_end,
                    "captureStartSystemUptimes": [
                        window_start + 0.95,
                        window_start + 2.45,
                        window_start + 3.95,
                    ],
                    "captureEndSystemUptimes": [
                        window_start + 1.05,
                        window_start + 2.55,
                        window_start + 4.05,
                    ],
                    "captureSystemUptimes": [
                        window_start + 1,
                        window_start + 2.5,
                        window_start + 4,
                    ],
                    "canonicalRGB8Base64": [
                        base64.b64encode(frame).decode("ascii") for frame in frames
                    ],
                    "frameHashes": hashes,
                    "adjacentChangedPixelRatios": ratios,
                    "changedPixelScore": min(ratios),
                }
            )
        return {
            "formatVersion": 1,
            "purpose": "exploratory-vmem-output-attempt-cadence-semantics",
            "releaseCreditEligible": False,
            "vmemOutputTimestampProvenance": (
                policy.CADENCE_VMEM_OUTPUT_TIMESTAMP_PROVENANCE
            ),
            "targetWindowSeconds": policy.CADENCE_WINDOW_SECONDS,
            "settlingSeconds": 2.0,
            "startedSystemUptime": 1000.0,
            "endedSystemUptime": windows[-1]["windowEndSystemUptime"] + 1,
            "windows": windows,
            "springBoardFrames": {
                "formatVersion": 1,
                "method": policy.VISUAL_OBSERVATION_METHOD,
                "framesPerWindow": 3,
                "captureBoundaryGuardSeconds": (
                    policy.CADENCE_SEMANTICS_PROBE_CAPTURE_BOUNDARY_GUARD_SECONDS
                ),
                "records": visual_records,
            },
        }

    @staticmethod
    def native_renderer_recovery_evidence() -> dict:
        counter_fields = policy.NATIVE_RENDERER_RECOVERY_COUNTER_KEYS
        baseline_counters = {field: 0 for field in counter_fields}
        baseline_counters["successfulSubmissionCount"] = 10
        post_counters = dict(baseline_counters)
        for field in (
            "recoveryEpisodeCount",
            "recoveredEpisodeCount",
            "requirementNotificationCount",
            "revocationNotificationCount",
            "foregroundCheckCount",
            "recoveryFlushCount",
            "revocationFlushCount",
            "recoverySubmissionCount",
        ):
            post_counters[field] += 1
        post_counters["successfulSubmissionCount"] += 2

        def snapshot(counters: dict[str, int]) -> dict:
            return {
                "abiVersion": 1,
                "rawFlags": 17,
                "displayGeneration": 7,
                **counters,
                "isCurrent": True,
                "requiresFlush": False,
                "isFailed": False,
                "isRecoveryInProgress": False,
                "hasRecoverySample": True,
            }

        deltas = {
            field: post_counters[field] - baseline_counters[field]
            for field in counter_fields
        }
        frames = [
            bytes([channel]) * policy._VISUAL_FRAME_BYTE_COUNT
            for channel in (0, 64, 128)
        ]
        hashes = [policy._canonical_visual_frame_hash(frame) for frame in frames]
        ratios = [
            policy._canonical_visual_changed_pixel_ratio(first, second)
            for first, second in zip(frames, frames[1:])
        ]
        return {
            "formatVersion": 1,
            "scenario": "playback-foreground-displaylayer-recovery",
            "renderingPath": "native",
            "trigger": "real-os-home-background-foreground-v1",
            "syntheticNotificationsPosted": False,
            "playbackStateAtBaseline": "paused",
            "playbackStateAtEvaluation": "paused",
            "backgroundForegroundCycles": 1,
            "status": "pass",
            "reason": "native-mechanics-and-system-pip-motion-proved",
            "mechanics": {
                "formatVersion": 1,
                "outcome": "pass",
                "reason": "renderer-recovered-after-real-os-revocation",
                "baseline": snapshot(baseline_counters),
                "postForeground": snapshot(post_counters),
                "deltas": deltas,
                "checks": {
                    field: True for field in policy.NATIVE_RENDERER_RECOVERY_CHECK_KEYS
                },
            },
            "postRecoveryVisualOracle": {
                "formatVersion": 1,
                "status": "pass",
                "reason": "moving-system-pip-pixels-observed",
                "surface": "system-picture-in-picture",
                "captureBinding": {
                    "formatVersion": 1,
                    "method": policy.VISUAL_OBSERVATION_METHOD,
                    "encoding": "base64-rgb8-row-major",
                    "frameWidthPixels": 64,
                    "frameHeightPixels": 36,
                    "channelCount": 3,
                    "bytesPerFrame": policy._VISUAL_FRAME_BYTE_COUNT,
                    "frameCount": 3,
                    "captureSystemUptimeSeconds": [100.0, 100.35, 100.7],
                    "canonicalRGB8Base64": [
                        base64.b64encode(frame).decode("ascii") for frame in frames
                    ],
                },
                "frameHashes": hashes,
                "adjacentChangedPixelRatios": ratios,
                "changedPixelScore": min(ratios),
                "distinctFrameHashes": 3,
                "minimumChangedPixelScore": 0.01,
            },
        }

    @staticmethod
    def vod_controls_evidence() -> dict:
        controls = {
            "play": "pass",
            "pause": "pass",
            "scrub": "pass",
            "skipForward": "pass",
            "skipBackward": "pass",
            "skipPastZero": "pass",
            "postBoundaryForward": "pass",
            "pauseObservationDurationMilliseconds": 1000,
            "maximumPausedClockDeltaMilliseconds": 250,
            "pausedBeforeMilliseconds": 1000,
            "pausedAfterMilliseconds": 1100,
            "scrubTargetMilliseconds": 15000,
            "scrubLandedTimeMilliseconds": 15500,
            "presentedBeforeScrub": 10,
            "presentedAfterScrub": 11,
            "forwardBeforeMilliseconds": 15500,
            "forwardAfterMilliseconds": 25500,
            "backwardBeforeMilliseconds": 25500,
            "backwardAfterMilliseconds": 15500,
            "zeroBoundaryBeforeMilliseconds": 15500,
            "zeroBoundaryOffsetMilliseconds": -25500,
            "zeroBoundaryAfterMilliseconds": 500,
            "presentedBeforeZeroBoundary": 20,
            "presentedAfterZeroBoundary": 21,
            "postBoundaryForwardBeforeMilliseconds": 600,
            "postBoundaryForwardAfterMilliseconds": 3600,
        }

        def backend(name: str, command_path: str) -> dict:
            return {
                "formatVersion": 1,
                "scenario": "vod-controls",
                "backend": name,
                "commandPath": command_path,
                "orderedEvents": [
                    "possibleDidChange",
                    "willStart",
                    "didStart",
                    "willStop:programmatic",
                    "didStop:programmatic",
                ],
                "events": {
                    "started": True,
                    "unexpectedStopCount": 0,
                    "order": "pass",
                },
                "controls": dict(controls),
            }

        statuses = {
            key: "pass"
            for key in (
                "play",
                "pause",
                "scrub",
                "skipForward",
                "skipBackward",
                "skipPastZero",
                "postBoundaryForward",
            )
        }
        return {
            "formatVersion": 1,
            "scenario": "vod-controls",
            "events": {
                "started": True,
                "unexpectedStopCount": 0,
                "order": "pass",
            },
            "controls": statuses,
            "backendResults": {
                "native": backend("native", "nativeMediaController"),
                "direct": backend("direct", "sampleBufferPlaybackDelegate"),
            },
            "systemPiPMotion": {"native": "pass", "direct": "pass"},
        }

    @staticmethod
    def performance_evidence(scenario_id: str) -> dict:
        profile = "1080p60" if scenario_id.endswith("1080p60") else "4k60"
        width, height = (1920, 1080) if profile == "1080p60" else (3840, 2160)
        cpu_rate = 2 if profile == "1080p60" else 4
        duration = 900
        samples = [
            {
                "elapsedSeconds": elapsed,
                "residentBytes": 100_000_000,
                "cpuSeconds": elapsed * cpu_rate,
                "thermalState": "nominal",
                "sourceWidth": width,
                "sourceHeight": height,
                "targetWidth": 640,
                "targetHeight": 360,
                "presentationCopyFrames": elapsed * 60 + 1,
                "presentationCopyFailures": 0,
                "measuredConversionCount": elapsed * 60 + 1,
                "decodedContentChanges": elapsed * 60 + 1,
                "displayConsumeFailures": 0,
                "renderPoolAllocationFailureCount": 0,
                "lastRenderPoolAllocationStatus": None,
                "deliveredFrameCount": elapsed * 60 + 1,
                "droppedFrameCount": 0,
            }
            for elapsed in range(0, duration + 1, 5)
        ]
        return {
            "profile": profile,
            "deviceObservedDurationSeconds": duration,
            "samples": samples,
            "metrics": {
                "cpu": {
                    "value": duration * cpu_rate,
                    "unit": "cpu-seconds",
                    "source": "Mach task thread times",
                },
                "gpu": {"status": "required-host-augmentation"},
                "rss": {
                    "baselineBytes": 100_000_000,
                    "peakBytes": 100_000_000,
                    "finalBytes": 100_000_000,
                    "growthBytes": 0,
                    "limitBytes": 160 * 1_048_576,
                    "peakGrowthBytes": 0,
                    "peakLimitBytes": 256 * 1_048_576,
                },
                "energy": {"status": "required-host-augmentation"},
                "thermal": {"states": ["nominal"]},
                "conversionCost": {
                    "measuredConversions": 54_001,
                    "averageMilliseconds": 1.0,
                    "maximumMilliseconds": 2.0,
                },
                "frameDrops": {
                    "libVLCDropRate": 0.0,
                    "rendererDropRate": 0.0,
                },
                "presentationRate": {
                    "value": 60.0,
                    "unit": "frames-per-second",
                },
            },
            "systemPiPMotionSeries": [
                {
                    "elapsedSeconds": elapsed,
                    "motionScore": 0.5,
                    "distinctFrameHashes": 3,
                }
                for elapsed in range(0, duration + 1, 60)
            ],
            "visualObservations": {
                "formatVersion": 1,
                "method": policy.VISUAL_OBSERVATION_METHOD,
                "records": [
                    {
                        "elapsedSeconds": elapsed,
                        "frameHashes": ["a" * 64, "b" * 64, "c" * 64],
                        "adjacentChangedPixelRatios": [0.5, 0.5],
                        "changedPixelScore": 0.5,
                    }
                    for elapsed in range(0, duration + 1, 60)
                ],
            },
        }

    def test_duplicate_keys_are_rejected_by_the_shared_loader(self):
        with self.assertRaises(policy.QualificationPolicyError):
            policy.loads_json('{"result":"fail","result":"pass"}', "report")

    def test_shared_loader_rejects_non_finite_numbers_at_any_depth(self):
        payloads = {
            "nan": '{"value":NaN}',
            "positive-infinity": '{"value":Infinity}',
            "negative-infinity": '{"value":-Infinity}',
            "positive-overflow": '{"nested":[{"value":1e999}]}',
            "negative-overflow": '{"nested":[{"value":-1e999}]}',
        }
        for name, payload in payloads.items():
            with self.subTest(name=name), self.assertRaisesRegex(
                policy.QualificationPolicyError,
                "non-finite JSON number",
            ):
                policy.loads_json(payload, "qualification evidence")

    def test_shared_loader_normalizes_invalid_unicode(self):
        with self.assertRaisesRegex(
            policy.QualificationPolicyError,
            "cannot read qualification evidence: invalid Unicode string",
        ):
            policy.loads_json('{"value":"\\ud800"}', "qualification evidence")

    def test_canonical_json_rejects_non_finite_values(self):
        self.assertEqual(
            policy.canonical_json_bytes({"b": 2, "a": [1.0]}),
            b'{"a":[1.0],"b":2}',
        )
        for value in (float("nan"), float("inf"), float("-inf")):
            with self.subTest(value=value), self.assertRaisesRegex(
                policy.QualificationPolicyError,
                "cannot canonicalize JSON",
            ):
                policy.canonical_json_bytes({"nested": [value]})

    def test_generic_background_audio_evidence_rejects_non_finite_counters(self):
        scenario = {
            "id": "background-audio",
            "requiredEvidenceFields": [
                "measurements.playedAudioBuffersAfterBackground"
            ],
        }
        policy.validate_evidence_semantics(
            {"measurements": {"playedAudioBuffersAfterBackground": 1}},
            scenario,
        )
        for value in (float("nan"), float("inf"), float("-inf")):
            with self.subTest(value=value), self.assertRaisesRegex(
                policy.QualificationPolicyError,
                "background-audio evidence is not valid finite JSON",
            ):
                policy.validate_evidence_semantics(
                    {
                        "measurements": {
                            "playedAudioBuffersAfterBackground": value
                        }
                    },
                    scenario,
                )

    def test_cli_rejects_non_finite_duplicate_and_invalid_unicode_json(self):
        prefix = (
            b'{"errors":[],"values":[{"identifier":'
            b'"iOSUITests/FixtureTests/test_releaseIntegrity"}],'
        )
        payloads = {
            "nan": prefix + b'"probe":NaN}',
            "positive-infinity": prefix + b'"probe":Infinity}',
            "negative-infinity": prefix + b'"probe":-Infinity}',
            "positive-overflow": prefix + b'"probe":1e999}',
            "negative-overflow": prefix + b'"probe":-1e999}',
            "duplicate-key": prefix + b'"probe":0,"probe":0}',
            "invalid-unicode": prefix + b'"probe":"\\ud800"}',
            "invalid-utf8": prefix + b'"probe":"\xff"}',
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, payload in payloads.items():
                with self.subTest(name=name):
                    source = root / f"{name}.json"
                    output = root / f"{name}-catalog.json"
                    source.write_bytes(payload)
                    result = subprocess.run(
                        [
                            sys.executable,
                            str(QUALIFICATION / "qualification_policy.py"),
                            "normalize-catalog",
                            "--input",
                            str(source),
                            "--output",
                            str(output),
                        ],
                        text=True,
                        capture_output=True,
                    )
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertIn("Error:", result.stderr)
                    self.assertNotIn("Traceback", result.stderr)
                    self.assertFalse(output.exists())

    def test_local_playback_evidence_replays_manifest_native_counters_and_pixels(self):
        for scenario_id in ("local-file-matrix", "audio-only-playback"):
            with self.subTest(
                scenario=scenario_id
            ), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                evidence = self.local_playback_evidence(root, scenario_id)
                policy.validate_local_playback_evidence(
                    evidence,
                    scenario_id,
                    retained_base=root,
                    require_retained=True,
                )

    def test_local_playback_rejects_manifest_counter_and_visual_forgeries(self):
        for scenario_id in ("local-file-matrix", "audio-only-playback"):
            with self.subTest(
                scenario=scenario_id
            ), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                evidence = self.local_playback_evidence(root, scenario_id)
                mutations = {}

                missing_fixture = self.clone(evidence)
                missing_fixture["fixtureResults"].pop()
                mutations["missing-canonical-fixture"] = missing_fixture

                reordered = self.clone(evidence)
                reordered["fixtureResults"][:2] = reversed(
                    reordered["fixtureResults"][:2]
                )
                mutations["reordered-fixture-contract"] = reordered

                wrong_metadata = self.clone(evidence)
                wrong_metadata["fixtureResults"][0]["fixture"]["audioCodec"] = "fake"
                mutations["fixture-metadata-claim"] = wrong_metadata

                network_source = self.clone(evidence)
                network_source["fixtureResults"][0]["sourceScheme"] = "http"
                mutations["not-a-local-source"] = network_source

                generation = self.clone(evidence)
                generation["fixtureResults"][0]["generationAfter"] = generation[
                    "fixtureResults"
                ][0]["generationBefore"]
                mutations["generation-did-not-advance"] = generation

                frozen_clock = self.clone(evidence)
                frozen_clock["fixtureResults"][0]["end"]["timeMilliseconds"] = 500
                mutations["frozen-native-clock"] = frozen_clock

                dead_input = self.clone(evidence)
                dead_input["fixtureResults"][0]["start"]["readBytes"] = 0
                dead_input["fixtureResults"][0]["end"]["readBytes"] = 0
                mutations["zero-native-input"] = dead_input

                silent = self.clone(evidence)
                silent["fixtureResults"][0]["end"]["playedAudioBuffers"] = silent[
                    "fixtureResults"
                ][0]["start"]["playedAudioBuffers"]
                mutations["no-real-audio-output"] = silent

                wrong_digest = self.clone(evidence)
                wrong_digest["fixtureResults"][0]["downloadedSHA256"] = "f" * 64
                mutations["download-differs-from-manifest"] = wrong_digest

                extra_claim = self.clone(evidence)
                extra_claim["trustedUILabel"] = "pass"
                mutations["raw-schema-extra"] = extra_claim

                if scenario_id == "local-file-matrix":
                    frozen_display = self.clone(evidence)
                    frozen_display["fixtureResults"][0]["end"]["displayedPictures"] = (
                        frozen_display["fixtureResults"][0]["start"][
                            "displayedPictures"
                        ]
                    )
                    mutations["no-native-video-output"] = frozen_display

                    changed_pixels = self.clone(evidence)
                    encoded = changed_pixels["fixtureResults"][0]["visualCapture"][
                        "canonicalRGB8Base64"
                    ][0]
                    frame = bytearray(base64.b64decode(encoded))
                    frame[0] ^= 0xFF
                    changed_pixels["fixtureResults"][0]["visualCapture"][
                        "canonicalRGB8Base64"
                    ][0] = base64.b64encode(frame).decode()
                    mutations["raw-pixel-hash-mismatch"] = changed_pixels

                    replayed_window = self.clone(evidence)
                    replayed_window["fixtureResults"][1]["visualCapture"][
                        "captureSystemUptimeSeconds"
                    ] = replayed_window["fixtureResults"][0]["visualCapture"][
                        "captureSystemUptimeSeconds"
                    ]
                    mutations["pixels-replayed-from-another-fixture"] = replayed_window

                    boundary_capture = self.clone(evidence)
                    boundary_capture["fixtureResults"][0]["visualCapture"][
                        "captureSystemUptimeSeconds"
                    ][0] = boundary_capture["fixtureResults"][0][
                        "measurementStartSystemUptime"
                    ]
                    mutations["pixels-at-native-window-boundary"] = boundary_capture

                    repeated_pixels = self.clone(evidence)
                    visual = repeated_pixels["fixtureResults"][0]["visualCapture"]
                    repeated = visual["canonicalRGB8Base64"][0]
                    repeated_frame = base64.b64decode(repeated)
                    repeated_hash = policy._canonical_visual_frame_hash(repeated_frame)
                    visual["canonicalRGB8Base64"] = [repeated] * 3
                    visual["frameHashes"] = [repeated_hash] * 3
                    visual["adjacentChangedPixelRatios"] = [0.0, 0.0]
                    visual["changedPixelScore"] = 0.0
                    visual["distinctFrameHashes"] = 1
                    mutations["self-consistent-frozen-pixels"] = repeated_pixels
                else:
                    hidden_video = self.clone(evidence)
                    hidden_video["fixtureResults"][0]["end"]["decodedVideo"] = 1
                    mutations["audio-only-has-video"] = hidden_video

                for name, mutated in mutations.items():
                    with self.subTest(scenario=scenario_id, mutation=name):
                        with self.assertRaises(policy.QualificationPolicyError):
                            policy.validate_local_playback_evidence(
                                mutated,
                                scenario_id,
                                retained_base=root,
                                require_retained=True,
                            )

                with self.assertRaises(policy.QualificationPolicyError):
                    policy.validate_local_playback_evidence(
                        evidence,
                        scenario_id,
                        retained_base=root / "missing",
                        require_retained=True,
                    )

                manifest_path = root / "fixture-manifest.json"
                manifest = json.loads(manifest_path.read_text())
                manifest["localPlayback"]["video"][0]["videoCodec"] = "hevc"
                manifest_path.write_text(json.dumps(manifest, sort_keys=True) + "\n")
                evidence["fixtureManifestChecksum"] = policy.sha256_file(manifest_path)
                with self.assertRaises(policy.QualificationPolicyError):
                    policy.validate_local_playback_evidence(
                        evidence,
                        scenario_id,
                        retained_base=root,
                        require_retained=True,
                    )

    def test_progressive_http_range_replays_candidate_pixels_and_host_transcript(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence, _, _ = self.progressive_http_range_evidence(root)
            fingerprints = policy.validate_progressive_http_range_evidence(
                evidence,
                retained_base=root,
                require_retained=True,
                require_host_artifacts=True,
            )
            self.assertEqual(len(fingerprints), 1)
            record_fingerprints = policy.validate_progressive_http_range_evidence(
                evidence,
                retained_base=None,
                artifact_base=root,
                require_retained=False,
                require_host_artifacts=True,
            )
            self.assertEqual(record_fingerprints, fingerprints)

    def test_progressive_http_range_rejects_candidate_and_network_forgeries(self):
        def mutate_legacy_point_capture(evidence: dict) -> None:
            visual = evidence["rangeCase"]["visualCapture"]
            intervals = visual.pop("captureSystemUptimeIntervals")
            visual["captureSystemUptimeSeconds"] = [
                interval["endSystemUptimeSeconds"] for interval in intervals
            ]

        def mutate_unbounded_capture_interval(evidence: dict) -> None:
            interval = evidence["rangeCase"]["visualCapture"][
                "captureSystemUptimeIntervals"
            ][0]
            interval["endSystemUptimeSeconds"] = (
                interval["startSystemUptimeSeconds"]
                + policy.PROGRESSIVE_HTTP_MAXIMUM_CAPTURE_INTERVAL_SECONDS
                + 0.001
            )

        def mutate_forged_capture_interval(evidence: dict) -> None:
            interval = evidence["rangeCase"]["visualCapture"][
                "captureSystemUptimeIntervals"
            ][0]
            interval["startSystemUptimeSeconds"] = 99.8
            interval["endSystemUptimeSeconds"] = 99.9

        def mutate_second_half_pixels(evidence: dict) -> None:
            visual = evidence["rangeCase"]["visualCapture"]
            frames = []
            for encoded in visual["canonicalRGB8Base64"]:
                frame = bytearray(base64.b64decode(encoded))
                for y in range(30, 34):
                    for x in range(48, 60):
                        offset = (y * 64 + x) * 3
                        frame[offset : offset + 3] = b"\xff\xff\xff"
                frames.append(bytes(frame))
            hashes = [policy._canonical_visual_frame_hash(frame) for frame in frames]
            ratios = [
                policy._canonical_visual_changed_pixel_ratio(first, second)
                for first, second in zip(frames, frames[1:])
            ]
            observations = [
                policy._progressive_frame_band_and_time(frame) for frame in frames
            ]
            visual.update(
                {
                    "canonicalRGB8Base64": [
                        base64.b64encode(frame).decode() for frame in frames
                    ],
                    "frameHashes": hashes,
                    "adjacentChangedPixelRatios": ratios,
                    "changedPixelScore": min(ratios),
                    "decodedBandIndices": [item[0] for item in observations],
                    "decodedTimelineSeconds": [item[1] for item in observations],
                }
            )

        candidate_mutations = {
            "unbound-generation": lambda evidence: evidence["rangeCase"][
                "landing"
            ].__setitem__("playbackGeneration", "generation 2"),
            "unbound-command-token": lambda evidence: evidence["rangeCase"][
                "typedSeek"
            ].__setitem__("commandAttemptToken", "stale-attempt"),
            "typed-settlement-not-settled": lambda evidence: evidence["rangeCase"][
                "typedSeek"
            ].__setitem__("terminalOutcome", "rejected"),
            "native-output-did-not-advance": lambda evidence: evidence["rangeCase"][
                "landing"
            ].__setitem__(
                "displayedPictures", evidence["rangeCase"]["start"]["displayedPictures"]
            ),
            "native-clock-slope-diverged": lambda evidence: evidence["rangeCase"][
                "end"
            ].__setitem__(
                "currentTimeMilliseconds",
                evidence["rangeCase"]["landing"]["currentTimeMilliseconds"] + 1,
            ),
            "no-range-clock-slope-diverged": lambda evidence: evidence["noRangeCase"][
                "end"
            ].__setitem__(
                "currentTimeMilliseconds",
                evidence["noRangeCase"]["start"]["currentTimeMilliseconds"] + 701,
            ),
            "no-range-broad-alternative": lambda evidence: evidence["noRangeCase"][
                "typedRejection"
            ].__setitem__("message", "seek unavailable"),
            "no-range-eventually-landed": lambda evidence: evidence["noRangeCase"][
                "end"
            ].__setitem__("currentTimeMilliseconds", 43_500),
            "legacy-point-capture-time": mutate_legacy_point_capture,
            "unbounded-capture-interval": mutate_unbounded_capture_interval,
            "forged-capture-interval": mutate_forged_capture_interval,
            "second-half-plus-60-pixels": mutate_second_half_pixels,
            "app-network-summary": lambda evidence: evidence.__setitem__(
                "networkSummary", {"postCommand206": True}
            ),
        }
        for name, mutate in candidate_mutations.items():
            with self.subTest(
                mutation=name
            ), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                evidence, _, _ = self.progressive_http_range_evidence(root)
                mutate(evidence)
                with self.assertRaises(policy.QualificationPolicyError):
                    policy.validate_progressive_http_range_evidence(
                        evidence,
                        retained_base=root,
                        require_retained=True,
                        require_host_artifacts=True,
                    )

        def insert_nonqualifying_first_post_marker_request(transcript: dict) -> None:
            events = transcript["events"]
            later = events[2]
            first = {
                **later,
                "sequence": 3,
                "requestRange": "bytes=5000000-5999999",
                "responseContentRange": (
                    f"bytes 5000000-5999999/{transcript['fixtureBytes']}"
                ),
                "startedAtUTC": "2026-09-01T00:00:01.100000+00:00",
                "completedAtUTC": "2026-09-01T00:00:01.900000+00:00",
            }
            for event in events[2:]:
                event["sequence"] += 1
            events.insert(2, first)

        transcript_mutations = {
            "full-prefetch": lambda transcript: transcript["events"][0].update(
                {
                    "transferredBytes": transcript["fixtureBytes"],
                    "transferredBytesAtCommand": transcript["fixtureBytes"],
                    "completed": True,
                }
            )
            or transcript["events"][1].__setitem__(
                "precommandTransferredBytes", transcript["fixtureBytes"]
            ),
            "seek-range-stamped-pre-command": lambda transcript: transcript["events"][
                2
            ].__setitem__("phase", "pre-command"),
            "post-command-not-206": lambda transcript: transcript["events"][2].update(
                {
                    "requestRange": None,
                    "responseStatus": 200,
                    "responseContentRange": None,
                    "responseContentLength": transcript["fixtureBytes"],
                }
            ),
            "post-command-range-from-start": lambda transcript: transcript["events"][
                2
            ].update(
                {
                    "requestRange": "bytes=0-999999",
                    "responseContentRange": (
                        f"bytes 0-999999/{transcript['fixtureBytes']}"
                    ),
                }
            ),
            "post-command-range-end-mismatch": lambda transcript: transcript["events"][
                2
            ].__setitem__("requestRange", "bytes=10000000-10000000"),
            "post-command-zero-transfer": lambda transcript: transcript["events"][
                2
            ].__setitem__("transferredBytes", 0),
            "wrong-candidate-command-origin": lambda transcript: transcript["events"][
                1
            ].__setitem__("origin", "xcui-test-process"),
            "post-request-started-before-marker": lambda transcript: transcript[
                "events"
            ][2].__setitem__("startedAtUTC", "2026-09-01T00:00:00.500000+00:00"),
            "later-qualifying-request-cannot-hide-first": (
                insert_nonqualifying_first_post_marker_request
            ),
            "cross-attempt-token": lambda transcript: transcript.__setitem__(
                "token", "another-progressive-attempt"
            ),
            "no-range-native-command-dispatched": lambda transcript: transcript[
                "events"
            ].append(
                {
                    **transcript["events"][3],
                    "sequence": 6,
                    "phase": "post-command",
                    "transferredBytesAtCommand": None,
                }
            ),
        }
        for name, mutate in transcript_mutations.items():
            with self.subTest(
                mutation=name
            ), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                evidence, transcript_path, transcript = (
                    self.progressive_http_range_evidence(root)
                )
                mutate(transcript)
                transcript_path.write_text(
                    json.dumps(transcript, sort_keys=True) + "\n"
                )
                binding = evidence["progressiveServerTranscripts"][0]
                binding["digest"] = policy.sha256_file(transcript_path)
                binding["sizeBytes"] = transcript_path.stat().st_size
                binding["eventCount"] = len(transcript["events"])
                with self.assertRaises(policy.QualificationPolicyError):
                    policy.validate_progressive_http_range_evidence(
                        evidence,
                        retained_base=root,
                        require_retained=True,
                        require_host_artifacts=True,
                    )

    def test_progressive_http_range_rejects_stale_pixels_and_missing_transcript(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence, transcript_path, _ = self.progressive_http_range_evidence(root)
            visual = evidence["rangeCase"]["visualCapture"]
            visual["canonicalRGB8Base64"][0] = base64.b64encode(
                b"\0" * policy._VISUAL_FRAME_BYTE_COUNT
            ).decode()
            with self.assertRaises(policy.QualificationPolicyError):
                policy.validate_progressive_http_range_evidence(
                    evidence,
                    retained_base=root,
                    require_retained=True,
                    require_host_artifacts=True,
                )

            evidence, transcript_path, _ = self.progressive_http_range_evidence(
                root / "fresh"
            )
            transcript_path.unlink()
            with self.assertRaises(policy.QualificationPolicyError):
                policy.validate_progressive_http_range_evidence(
                    evidence,
                    retained_base=root / "fresh",
                    require_retained=True,
                    require_host_artifacts=True,
                )

    def test_progressive_http_range_reopens_exact_transcript_inventory_and_counts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence, transcript_path, _ = self.progressive_http_range_evidence(root)
            bindings = materialize.bind_progressive_transcripts(
                transcript_path.parent, [{"attempt": 1}], root
            )
            self.assertEqual(bindings, evidence["progressiveServerTranscripts"])

        for name, mutate in {
            "digest": lambda evidence, _path: evidence["progressiveServerTranscripts"][
                0
            ].__setitem__("digest", "f" * 64),
            "event-count": lambda evidence, _path: evidence[
                "progressiveServerTranscripts"
            ][0].__setitem__("eventCount", 99),
            "path-escape": lambda evidence, _path: evidence[
                "progressiveServerTranscripts"
            ][0].__setitem__("relativePath", "../stale.json"),
            "extra-file": lambda _evidence, path: (
                path.parent / "attempt-2.json"
            ).write_text("{}\n"),
        }.items():
            with self.subTest(
                mutation=name
            ), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                evidence, transcript_path, _ = self.progressive_http_range_evidence(
                    root
                )
                mutate(evidence, transcript_path)
                with self.assertRaises(policy.QualificationPolicyError):
                    policy.validate_progressive_http_range_evidence(
                        evidence,
                        retained_base=root,
                        require_retained=True,
                        require_host_artifacts=True,
                    )

    def test_progressive_http_range_assembler_reopens_bound_transcripts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence, transcript_path, _ = self.progressive_http_range_evidence(root)
            artifacts = assemble_record.retained_progressive_transcript_artifacts(
                root,
                root / "evidence" / "qualification-progressive-http-range-seek.json",
                evidence["progressiveServerTranscripts"],
            )
            self.assertEqual(
                artifacts,
                [
                    (
                        transcript_path.resolve(),
                        Path(
                            evidence["progressiveServerTranscripts"][0]["relativePath"]
                        ),
                        False,
                    )
                ],
            )

            evidence["progressiveServerTranscripts"][0]["digest"] = "0" * 64
            with self.assertRaises(assemble_record.AssemblyError):
                assemble_record.retained_progressive_transcript_artifacts(
                    root,
                    root
                    / "evidence"
                    / "qualification-progressive-http-range-seek.json",
                    evidence["progressiveServerTranscripts"],
                )

    def test_stable_duration_contract_cannot_be_removed_or_shortened(self):
        matrix = {
            "hardware": [{"id": "iphone", "deviceFamily": "iPhone", "osMajor": 26}],
            "scenarios": [
                {
                    "id": "adaptive-hls-soak",
                    "hardware": ["iphone"],
                    "minimumDurationSeconds": 7200,
                }
            ],
        }
        policy.validate_matrix(matrix)
        for weakened in (None, 60, 7199):
            mutated = json.loads(json.dumps(matrix))
            if weakened is None:
                mutated["scenarios"][0].pop("minimumDurationSeconds")
            else:
                mutated["scenarios"][0]["minimumDurationSeconds"] = weakened
            with self.subTest(weakened=weakened):
                with self.assertRaises(policy.QualificationPolicyError):
                    policy.validate_matrix(mutated)
        with self.assertRaises(policy.QualificationPolicyError):
            policy.validate_duration("adaptive-hls-soak", 60, stable=True)
        self.assertEqual(
            policy.validate_duration("adaptive-hls-soak", 60, stable=False), 60
        )

    def test_every_endurance_lane_uses_device_time_and_full_series_coverage(self):
        for scenario_id, minimum in policy.STABLE_MINIMUM_DURATION_SECONDS.items():
            with self.subTest(scenario=scenario_id, mutation="valid"):
                evidence = self.endurance_evidence(scenario_id)
                policy.validate_endurance_evidence(evidence, scenario_id, stable=True)

            with self.subTest(scenario=scenario_id, mutation="device-one-second"):
                evidence = self.endurance_evidence(scenario_id)
                evidence["durationSeconds"] = 1
                evidence["deviceObservedDurationSeconds"] = 1
                evidence["hostAttemptDurationSeconds"] = minimum
                with self.assertRaises(policy.QualificationPolicyError):
                    policy.validate_endurance_evidence(
                        evidence, scenario_id, stable=True
                    )

            with self.subTest(scenario=scenario_id, mutation="host-device-mismatch"):
                evidence = self.endurance_evidence(scenario_id)
                evidence["hostAttemptDurationSeconds"] = (
                    minimum + policy.ENDURANCE_HOST_MAXIMUM_OVERHEAD_SECONDS + 1
                )
                with self.assertRaises(policy.QualificationPolicyError):
                    policy.validate_endurance_evidence(
                        evidence, scenario_id, stable=True
                    )

            with self.subTest(scenario=scenario_id, mutation="short-series"):
                evidence = self.endurance_evidence(scenario_id)
                if scenario_id in {"timebase-vod-soak", "timebase-live-soak"}:
                    evidence["rawCapture"]["timelineEndSeconds"] = 1
                    evidence["rawCapture"]["sampleCount"] = 2
                    evidence["rawCapture"]["driftSampleCount"] = 2
                else:
                    path = policy.ENDURANCE_SERIES_PATHS[scenario_id]
                    target = evidence
                    parts = path.split(".")
                    for part in parts[:-1]:
                        target = target[part]
                    target[parts[-1]][-1]["elapsedSeconds"] = 1
                with self.assertRaises(policy.QualificationPolicyError):
                    policy.validate_endurance_evidence(
                        evidence, scenario_id, stable=True
                    )

    def test_release_matrix_cannot_drop_hardware_rows_or_reassign_producers(self):
        matrix = policy.load_json(QUALIFICATION / "matrix.json", "matrix")
        policy.validate_release_matrix_contract(matrix)
        mutations = {}

        missing_ipad = self.clone(matrix)
        missing_ipad["hardware"] = [
            row for row in missing_ipad["hardware"] if row["id"] != "ipad-current"
        ]
        for scenario in missing_ipad["scenarios"]:
            if isinstance(scenario.get("hardware"), list):
                scenario["hardware"] = [
                    value for value in scenario["hardware"] if value != "ipad-current"
                ]
        mutations["delete-ipad-current"] = missing_ipad

        missing_row = self.clone(matrix)
        live = next(
            row for row in missing_row["scenarios"] if row["id"] == "live-media"
        )
        live["hardware"] = [
            hardware
            for hardware in policy.REQUIRED_HARDWARE
            if hardware != "ipad-minimum"
        ]
        mutations["delete-one-row"] = missing_row

        orphaned_adaptive = self.clone(matrix)
        orphaned_adaptive["scenarios"] = [
            row
            for row in orphaned_adaptive["scenarios"]
            if row["id"] != "adaptive-hls-soak"
        ]
        adaptive_runner = next(
            row
            for row in orphaned_adaptive["runnerContracts"]
            if row["id"] == "adaptive-hls-soak"
        )
        adaptive_runner["outputs"] = []
        adaptive_runner["selection"] = {
            "kind": "exact",
            "testIdentifiers": ["iOSUITests/PiPMotionRegionAnalyzerTests/test_fixture"],
        }
        mutations["orphan-adaptive-as-support"] = orphaned_adaptive

        wrong_owner = self.clone(matrix)
        seek_runner = next(
            row
            for row in wrong_owner["runnerContracts"]
            if row["id"] == "seek-frame-oracles"
        )
        seek_runner["outputs"][0]["testIdentifiers"] = [
            "iOSUITests/VideoOracleAnalyzerTests/test_fixture"
        ]
        mutations["wrong-xctest-owner"] = wrong_owner

        for label, mutated in mutations.items():
            with self.subTest(label=label):
                with self.assertRaises(policy.QualificationPolicyError):
                    policy.validate_release_matrix_contract(mutated)

    def test_release_catalog_partition_owns_both_pip_overlay_leaves(self):
        matrix = policy.load_json(QUALIFICATION / "matrix.json", "matrix")
        catalog = set(policy.RELEASE_CATALOG_EXCEPTIONS)
        for contract in matrix["runnerContracts"]:
            selection = contract.get("selection", {})
            if selection.get("kind") == "exact":
                catalog.update(selection["testIdentifiers"])
            elif selection.get("kind") == "candidatePrefix":
                catalog.add(selection["prefix"] + "test_fixture")
            elif selection.get("kind") == "candidatePrefixes":
                catalog.update(
                    prefix + "test_fixture" for prefix in selection["prefixes"]
                )
            for output in contract.get("outputs", []):
                catalog.update(output["testIdentifiers"])
        policy.validate_release_catalog_partition(matrix, sorted(catalog))

        mutated = self.clone(matrix)
        hls = next(row for row in mutated["runnerContracts"] if row["id"] == "hls-seek")
        hls["selection"]["testIdentifiers"] = [
            "iOSUITests/PiPOverlayDeviceUITests/test_nativePiPHLSSeeksRemainActive"
        ]
        with self.assertRaises(policy.QualificationPolicyError):
            policy.validate_release_catalog_partition(mutated, sorted(catalog))

    def test_native_hls_seek_requires_one_exact_ready_output_identity(self):
        scenario = {
            "id": "native-hls-seek-continuity",
            "requiredEvidenceFields": [],
        }
        evidence = self.native_hls_seek_identity_evidence()
        policy.validate_evidence_semantics(evidence, scenario)

        mutations = {
            "unproven-stability": lambda value: value.__setitem__(
                "nativeOutputIdentityStable", False
            ),
            "missing-command": lambda value: value["commandEvidence"].pop(
                "backward"
            ),
            "extra-command": lambda value: value["commandEvidence"].__setitem__(
                "reload", dict(value["commandEvidence"]["forward"])
            ),
            "zero-output": lambda value: value["commandEvidence"]["forward"][
                "landingPiPOutputIdentity"
            ].__setitem__("outputIdentity", 0),
            "boolean-handle": lambda value: value["commandEvidence"]["forward"][
                "baselinePiPOutputIdentity"
            ].__setitem__("nativeHandleIdentity", True),
            "oversized-generation": lambda value: value["commandEvidence"][
                "forward"
            ]["landingPiPOutputIdentity"].__setitem__(
                "playbackGeneration", 1 << 64
            ),
            "relabelled-landing": lambda value: value["commandEvidence"][
                "backward"
            ]["landingPiPOutputIdentity"].__setitem__("nativeHandleIdentity", 102),
            "wrong-media-generation": lambda value: value["commandEvidence"][
                "absolute"
            ].__setitem__("mediaGeneration", 8),
            "cross-command-rebuild": lambda value: [
                value["commandEvidence"]["backward"][phase].__setitem__(
                    "outputIdentity", 304
                )
                for phase in (
                    "baselinePiPOutputIdentity",
                    "landingPiPOutputIdentity",
                )
            ],
            "extended-identity-schema": lambda value: value["commandEvidence"][
                "absolute"
            ]["baselinePiPOutputIdentity"].__setitem__("dynamicGeneration", 7),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                invalid = self.clone(evidence)
                mutate(invalid)
                with self.assertRaises(policy.QualificationPolicyError):
                    policy.validate_evidence_semantics(invalid, scenario)

    def test_adaptive_oracle_rejects_frozen_counters_and_visual_gaps(self):
        evidence = self.adaptive_oracle_evidence()
        policy.validate_adaptive_playback_oracle(evidence)
        mutations = {}
        frozen = self.clone(evidence)
        frozen["playbackProgress"]["windows"][1]["decodedVideoFramesDelta"] = 0
        mutations["frozen-decoder"] = frozen
        no_display = self.clone(evidence)
        no_display["playbackProgress"]["windows"][2]["displayedPicturesDelta"] = 0
        mutations["frozen-display"] = no_display
        no_read = self.clone(evidence)
        no_read["playbackProgress"]["windows"][3]["readBytesDelta"] = 0
        mutations["frozen-network"] = no_read
        forged_summary = self.clone(evidence)
        forged_summary["memorySeries"][3]["decodedVideoFrames"] = forged_summary[
            "memorySeries"
        ][2]["decodedVideoFrames"]
        mutations["positive-summary-beside-flat-raw-counter"] = forged_summary
        visual_gap = self.clone(evidence)
        del visual_gap["visualOracle"]["checkpoints"][4]
        mutations["visual-gap"] = visual_gap
        repeated_frame = self.clone(evidence)
        repeated_frame["visualOracle"]["checkpoints"][0]["distinctFrameHashes"] = 1
        mutations["repeated-frame"] = repeated_frame
        later_freeze = self.clone(evidence)
        later_freeze["visualObservations"]["records"][0]["adjacentChangedPixelRatios"][
            1
        ] = 0
        mutations["raw-later-freeze"] = later_freeze
        for label, mutated in mutations.items():
            with self.subTest(label=label):
                with self.assertRaises(policy.QualificationPolicyError):
                    policy.validate_adaptive_playback_oracle(mutated)

    def test_cadence_oracle_rejects_wrong_rates_vfr_and_repeated_frames(self):
        evidence = self.cadence_oracle_evidence()
        policy.validate_cadence_oracle(evidence)
        mutations = {}
        wrong_rate = self.clone(evidence)
        wrong_rate["cadenceOracle"]["windows"][0]["observedSubmissionFPS"] = 1
        mutations["wrong-positive-rate"] = wrong_rate
        wrong_pts = self.clone(evidence)
        wrong_pts["cadenceOracle"]["windows"][1]["nativePTSDeltaSeconds"] = 0.1
        mutations["wrong-pts-delta"] = wrong_pts
        repeated = self.clone(evidence)
        repeated["cadenceOracle"]["windows"][2]["distinctFrameHashes"] = 1
        mutations["repeated-frame"] = repeated
        forged_summary = self.clone(evidence)
        forged_summary["samples"][1]["deliveredFrames"] = forged_summary["samples"][0][
            "deliveredFrames"
        ]
        mutations["positive-summary-beside-flat-samples"] = forged_summary
        forged_visual = self.clone(evidence)
        forged_visual["visualObservations"]["records"][0]["changedPixelScore"] = 0.9
        mutations["oracle-disagrees-with-raw-ui-observation"] = forged_visual
        wrong_provenance = self.clone(evidence)
        wrong_provenance["vmemOutputTimestampProvenance"] = "decoded-source-pts"
        mutations["false-decoded-source-provenance"] = wrong_provenance
        unknown_interval = self.clone(evidence)
        unknown_interval["samples"][1]["vmemOutputDeltaHistogram"][0][
            "deltaMicroseconds"
        ] = 12345
        mutations["unclassified-output-attempt-interval"] = unknown_interval
        wrong_playback_generation = self.clone(evidence)
        for sample in wrong_playback_generation["samples"][:2]:
            sample["vmemOutputPlaybackGeneration"] += 10
        mutations["vmem-playback-generation-not-bound-to-snapshot"] = (
            wrong_playback_generation
        )
        zero_vout_generation = self.clone(evidence)
        for sample in zero_vout_generation["samples"][:2]:
            sample["vmemOutputVoutGeneration"] = 0
        mutations["zero-vmem-vout-generation"] = zero_vout_generation
        understated_renderer_delivery = self.clone(evidence)
        metric = understated_renderer_delivery["presentationMetrics"][0]
        metric["deliveredFrames"] -= 1
        metric["presentationRate"] = (
            metric["deliveredFrames"] / metric["elapsedSeconds"]
        )
        mutations["summary-understates-retained-renderer-delivery"] = (
            understated_renderer_delivery
        )
        top_level_extra = self.clone(evidence)
        top_level_extra["claimedSourceCadence"] = True
        mutations["top-level-schema-extra"] = top_level_extra
        for label, mutated in mutations.items():
            with self.subTest(label=label):
                with self.assertRaises(policy.QualificationPolicyError):
                    policy.validate_cadence_oracle(mutated)

    def test_cadence_semantics_probe_replays_raw_native_and_visual_semantics(self):
        payload = self.cadence_semantics_probe_payload()
        policy.validate_cadence_semantics_probe_payload(payload)

        mutations = {}
        callback_drift = self.clone(payload)
        callback_drift["windows"][0]["outputCallbackCount"] += 1
        mutations["callback-summary"] = callback_drift

        rate_drift = self.clone(payload)
        rate_drift["windows"][1]["controlTimebaseRateEnd"] = 0.5
        mutations["rate-summary"] = rate_drift

        classification_drift = self.clone(payload)
        classification_drift["windows"][2]["nativePTSClassification"][
            "exactIntervalCount"
        ] += 1
        mutations["pts-classification"] = classification_drift

        renderer_drift = self.clone(payload)
        renderer_drift["windows"][3]["renderer"]["deliveredFrames"] -= 1
        mutations["renderer-summary"] = renderer_drift

        libvlc_drift = self.clone(payload)
        libvlc_drift["windows"][4]["libVLC"]["displayedPictures"] = 0
        mutations["libvlc-summary"] = libvlc_drift

        owner_window_drift = self.clone(payload)
        owner_window_drift["springBoardFrames"]["records"][5]["profile"] = "24"
        mutations["springboard-window-binding"] = owner_window_drift

        raw_motion_drift = self.clone(payload)
        raw_motion_drift["springBoardFrames"]["records"][6][
            "canonicalRGB8Base64"
        ][1] = base64.b64encode(
            bytes([255]) * policy._VISUAL_FRAME_BYTE_COUNT
        ).decode("ascii")
        mutations["springboard-raw-frame"] = raw_motion_drift

        motion_summary_drift = self.clone(payload)
        motion_summary_drift["springBoardFrames"]["records"][7][
            "changedPixelScore"
        ] = 0.99
        mutations["springboard-motion-summary"] = motion_summary_drift

        boundary_overlap = self.clone(payload)
        boundary_record = boundary_overlap["springBoardFrames"]["records"][0]
        boundary_start = boundary_record["windowStartSystemUptime"] + 0.05
        boundary_end = boundary_record["windowStartSystemUptime"] + 0.20
        boundary_record["captureStartSystemUptimes"][0] = boundary_start
        boundary_record["captureEndSystemUptimes"][0] = boundary_end
        boundary_record["captureSystemUptimes"][0] = (
            boundary_start + boundary_end
        ) / 2
        mutations["springboard-capture-overlaps-guarded-start"] = boundary_overlap

        midpoint_drift = self.clone(payload)
        midpoint_drift["springBoardFrames"]["records"][1][
            "captureSystemUptimes"
        ][1] += 0.01
        mutations["springboard-capture-midpoint-not-derived"] = midpoint_drift

        unrecognized_guard = self.clone(payload)
        unrecognized_guard["springBoardFrames"]["captureBoundaryGuardSeconds"] = 0
        mutations["springboard-unrecognized-boundary-guard"] = unrecognized_guard

        for label, mutated in mutations.items():
            with self.subTest(label=label):
                with self.assertRaises(policy.QualificationPolicyError):
                    policy.validate_cadence_semantics_probe_payload(mutated)

    def test_cadence_semantics_probe_requires_both_vfr_regime_footprints(self):
        def replace_histogram(
            payload: dict, index: int, histogram: dict[int, int]
        ) -> None:
            window = payload["windows"][index]
            duration = float(window["windowDurationSeconds"])
            histogram_items = [
                {"deltaMicroseconds": delta, "count": count}
                for delta, count in sorted(histogram.items())
            ]
            before = window["before"]
            after = window["after"]
            callbacks = sum(histogram.values())
            native_span = sum(
                delta * count for delta, count in histogram.items()
            )
            after["vmemOutputLastValidPTSUS"] = (
                before["vmemOutputLastValidPTSUS"] + native_span
            )
            after["vmemOutputDeltaHistogram"] = histogram_items
            for field in (
                "vmemOutputCallbackCount",
                "vmemOutputValidPTSCount",
                "vmemOutputSubmittedCount",
            ):
                after[field] = before[field] + callbacks

            renderer_progress = {
                "vmemLockAttempts",
                "vmemLockSuccesses",
                "vmemUnlockCallbacks",
                "vmemDisplayCallbacks",
                "enqueuedFrames",
                "deliveredFrames",
                "presentationCopyFrames",
            }
            for output, snapshot_field in (
                policy.CADENCE_SEMANTICS_PROBE_RENDERER_COUNTERS.items()
            ):
                delta = callbacks if output in renderer_progress else 0
                window["renderer"][output] = delta
                after[snapshot_field] = before[snapshot_field] + delta
            for output, snapshot_field in (
                policy.CADENCE_SEMANTICS_PROBE_LIBVLC_COUNTERS.items()
            ):
                delta = callbacks if output in {"decodedVideo", "displayedPictures"} else 0
                window["libVLC"][output] = delta
                after[snapshot_field] = before[snapshot_field] + delta

            classified = policy._classify_cadence_window_histogram(
                "vfr-24-60", histogram
            )
            window["nativePTSClassification"] = {
                "exactIntervalCount": classified["nativePTSExactIntervalCount"],
                "multipleIntervalCount": classified[
                    "nativePTSMultipleIntervalCount"
                ],
                "estimatedSkippedPictureCount": classified[
                    "nativePTSEstimatedSkippedPictureCount"
                ],
                "redisplayCount": classified["nativePTSRedisplayCount"],
                "backwardCount": classified["nativePTSBackwardCount"],
                "unclassifiedIntervalCount": classified[
                    "nativePTSUnclassifiedIntervalCount"
                ],
                "deltaOverflowCount": 0,
            }
            window["nativePTSDeltaHistogram"] = histogram_items
            window["nativePTSDeltaSeconds"] = native_span / 1_000_000
            window["outputCallbackCount"] = callbacks
            window["validPTSCount"] = callbacks
            window["submittedFrames"] = callbacks
            window["observedSubmissionFPS"] = callbacks / duration

        def replace_with_cfr(payload: dict, index: int, fps: int) -> None:
            window = payload["windows"][index]
            target_us = round(
                float(window["requestedRate"])
                * float(window["windowDurationSeconds"])
                * 1_000_000
            )
            frame_count = round(target_us * fps / 1_000_000)
            timestamps = [
                frame * 1_000_000 // fps for frame in range(frame_count + 1)
            ]
            histogram: dict[int, int] = {}
            for previous, current in zip(timestamps, timestamps[1:]):
                delta = current - previous
                histogram[delta] = histogram.get(delta, 0) + 1
            replace_histogram(payload, index, histogram)

        realistic_two_x = self.cadence_semantics_probe_payload()
        replace_histogram(
            realistic_two_x,
            8,
            {41666: 48, 41667: 96, 33333: 80, 33334: 40},
        )
        policy.validate_cadence_semantics_probe_payload(realistic_two_x)

        for fps in (24, 60):
            for index in range(6, 9):
                with self.subTest(fps=fps, window=index):
                    payload = self.cadence_semantics_probe_payload()
                    replace_with_cfr(payload, index, fps)
                    with self.assertRaisesRegex(
                        policy.QualificationPolicyError,
                        "does not prove both material 24fps and 60fps VFR regimes",
                    ):
                        policy.validate_cadence_semantics_probe_payload(payload)

    def test_cadence_semantics_probe_binds_exact_xcresult_owner_and_export(self):
        expected_catalog = policy.catalog_record(
            [policy.CADENCE_SEMANTICS_PROBE_TEST_IDENTIFIER]
        )
        execution = {
            "expected": expected_catalog,
            "executed": expected_catalog,
            "identityAndCountMatch": True,
            "allPassed": True,
        }
        xctest_document = {
            "testNodes": [
                {
                    "nodeType": "Test Case",
                    "nodeIdentifier": (
                        policy.CADENCE_SEMANTICS_PROBE_TEST_IDENTIFIER
                    ),
                    "result": "Passed",
                }
            ]
        }

        def fixture(root: Path) -> tuple[dict, dict, Path, Path, Path]:
            attempt_root = root / "cadence-semantics-probe-attempt-artifacts"
            attempt_root.mkdir()
            (attempt_root / "attempt-1.log").write_text("** TEST SUCCEEDED **\n")
            attempt_xcresult = attempt_root / "attempt-1.xcresult"
            attempt_xcresult.mkdir()
            (attempt_xcresult / "result.bin").write_bytes(b"exact-result")
            retained_xcresult = root / "cadence-semantics-probe.xcresult"
            retained_xcresult.mkdir()
            (retained_xcresult / "result.bin").write_bytes(b"exact-result")
            attempts = policy.bind_attempt_artifacts(
                [
                    {
                        "attempt": 1,
                        "classification": "passed",
                        "retryable": False,
                        "intendedTestBegan": True,
                        "xcodebuildExitCode": 0,
                        "logArtifact": (
                            "cadence-semantics-probe-attempt-artifacts/attempt-1.log"
                        ),
                        "xcresultArtifact": (
                            "cadence-semantics-probe-attempt-artifacts/"
                            "attempt-1.xcresult"
                        ),
                        "testExecution": execution,
                    }
                ],
                root,
            )
            attachment_root = root / "cadence-semantics-probe-attachments"
            attachment_root.mkdir()
            attachment_path = attachment_root / "probe.json"
            attachment_path.write_text(
                json.dumps(self.cadence_semantics_probe_payload(), sort_keys=True)
            )
            manifest_path = attachment_root / "manifest.json"
            manifest_path.write_text(
                json.dumps(
                    [
                        {
                            "testIdentifier": (
                                policy.CADENCE_SEMANTICS_PROBE_TEST_IDENTIFIER
                            ),
                            "testIdentifierURL": (
                                policy.CADENCE_SEMANTICS_PROBE_TEST_IDENTIFIER
                            ),
                            "attachments": [
                                {
                                    "suggestedHumanReadableName": (
                                        "exploratory-pip-cadence-semantics-probe_0_"
                                        "00000000-0000-4000-8000-000000000001.json"
                                    ),
                                    "exportedFileName": attachment_path.name,
                                }
                            ],
                        }
                    ],
                    sort_keys=True,
                )
            )
            inspector = {
                "payload": json.loads(attachment_path.read_text()),
                "sha256": policy.sha256_file(attachment_path),
                "sizeBytes": attachment_path.stat().st_size,
                "testIdentifier": policy.CADENCE_SEMANTICS_PROBE_TEST_IDENTIFIER,
            }
            raw_log_root = root / "cadence-semantics-probe-raw-jsonl"
            raw_log_root.mkdir()
            raw_log_name = policy.test_log_filename(
                "run",
                policy.CADENCE_SEMANTICS_PROBE_TEST_IDENTIFIER,
                "00000000-0000-4000-8000-000000000001",
            )
            (raw_log_root / raw_log_name).write_text(
                json.dumps(
                    {
                        "ts": "2026-09-03T12:00:00Z",
                        "level": "debug",
                        "module": policy.LOG_MIRROR_HEALTH_MODULE,
                        "message": policy.LOG_MIRROR_HEALTH_MESSAGE,
                    }
                )
                + "\n"
            )
            inventory = policy.build_error_inventory(
                raw_log_root,
                "run",
                policy.CADENCE_SEMANTICS_PROBE_SCENARIO,
                retained_root=raw_log_root.name,
                expected_test_catalog=expected_catalog,
            )
            runner = {
                "scenario": policy.CADENCE_SEMANTICS_PROBE_SCENARIO,
                "result": "pass",
                "xcodebuildExitCode": 0,
                "libraryErrorCount": 0,
                "appLog": "captured",
                "qualificationEvidence": "report-only",
                "durationSeconds": 90,
                "expectedTestCatalog": expected_catalog,
                "testExecution": execution,
                "attempts": attempts,
                "attemptArtifactRoot": (
                    "cadence-semantics-probe-attempt-artifacts"
                ),
                "hostErrorInventory": inventory,
            }
            return runner, inspector, manifest_path, attachment_path, retained_xcresult

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runner, inspector, _, _, _ = fixture(root)
            with mock.patch.object(
                policy, "xcresult_test_document", return_value=xctest_document
            ), mock.patch.object(
                policy,
                "inspect_xcresult_cadence_semantics_probe_attachment",
                return_value=inspector,
            ):
                proof = policy.validate_cadence_semantics_probe_artifacts(
                    root,
                    runner,
                    expected_version="1.1.0-beta.9",
                    require_proof=False,
                )
                runner["reportOnlyEvidence"] = proof
                policy.validate_cadence_semantics_probe_artifacts(
                    root,
                    runner,
                    expected_version="1.1.0-beta.9",
                    require_proof=True,
                )
                completed = datetime.now(timezone.utc).replace(microsecond=0)
                started = completed - timedelta(seconds=90)
                policy.validate_report_only_cadence_report(
                    root / "report.json",
                    {
                        "formatVersion": 2,
                        "version": "1.1.0-beta.9",
                        "mode": "exploratory",
                        "reportOnly": True,
                        "releaseGateSatisfied": False,
                        "releaseGateReason": (
                            "exploratory cadence semantics probe cannot produce "
                            "release credit"
                        ),
                        "result": "pass",
                        "qualificationRows": [],
                        "startedAtUTC": started.strftime("%Y-%m-%dT%H:%M:%SZ"),
                        "completedAtUTC": completed.strftime("%Y-%m-%dT%H:%M:%SZ"),
                        "wallDurationSeconds": 90,
                        "scenarios": [runner],
                    },
                )

        def mutate_owner(
            _runner: dict, manifest: Path, _payload: Path, _xcresult: Path
        ) -> None:
            value = json.loads(manifest.read_text())
            value[0]["testIdentifier"] = (
                "iOSUITests/OtherTests/test_fabricatedProbe"
            )
            value[0]["testIdentifierURL"] = value[0]["testIdentifier"]
            manifest.write_text(json.dumps(value))

        def mutate_malformed_suffix(
            _runner: dict, manifest: Path, _payload: Path, _xcresult: Path
        ) -> None:
            value = json.loads(manifest.read_text())
            value[0]["attachments"][0]["suggestedHumanReadableName"] = (
                "exploratory-pip-cadence-semantics-probe_0_not-a-uuid.json"
            )
            manifest.write_text(json.dumps(value))

        def mutate_extension(
            _runner: dict, manifest: Path, _payload: Path, _xcresult: Path
        ) -> None:
            value = json.loads(manifest.read_text())
            value[0]["attachments"][0]["suggestedHumanReadableName"] = (
                "exploratory-pip-cadence-semantics-probe_0_"
                "00000000-0000-4000-8000-000000000001.txt"
            )
            manifest.write_text(json.dumps(value))

        def mutate_count(
            _runner: dict, manifest: Path, _payload: Path, _xcresult: Path
        ) -> None:
            value = json.loads(manifest.read_text())
            value[0]["attachments"].append(dict(value[0]["attachments"][0]))
            manifest.write_text(json.dumps(value))

        def mutate_payload(
            _runner: dict, _manifest: Path, payload: Path, _xcresult: Path
        ) -> None:
            value = json.loads(payload.read_text())
            value["windows"][0]["outputCallbackCount"] += 1
            payload.write_text(json.dumps(value))

        def mutate_final_xcresult(
            _runner: dict, _manifest: Path, _payload: Path, xcresult: Path
        ) -> None:
            (xcresult / "result.bin").write_bytes(b"different-result")

        def mutate_proof(
            runner: dict, _manifest: Path, _payload: Path, _xcresult: Path
        ) -> None:
            runner["reportOnlyEvidence"]["attachmentDigest"] = "0" * 64

        def mutate_proof_version(
            runner: dict, _manifest: Path, _payload: Path, _xcresult: Path
        ) -> None:
            runner["reportOnlyEvidence"]["version"] = "1.1.0"

        mutations = {
            "attachment-owner": mutate_owner,
            "attachment-malformed-suffix": mutate_malformed_suffix,
            "attachment-wrong-extension": mutate_extension,
            "attachment-count": mutate_count,
            "attachment-payload": mutate_payload,
            "retained-final-xcresult": mutate_final_xcresult,
            "reported-proof": mutate_proof,
            "reported-proof-version": mutate_proof_version,
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                runner, inspector, manifest, payload, retained_xcresult = fixture(root)
                with mock.patch.object(
                    policy, "xcresult_test_document", return_value=xctest_document
                ), mock.patch.object(
                    policy,
                    "inspect_xcresult_cadence_semantics_probe_attachment",
                    return_value=inspector,
                ):
                    runner["reportOnlyEvidence"] = (
                        policy.validate_cadence_semantics_probe_artifacts(
                            root,
                            runner,
                            expected_version="1.1.0-beta.9",
                            require_proof=False,
                        )
                    )
                    mutate(runner, manifest, payload, retained_xcresult)
                    with self.assertRaises(policy.QualificationPolicyError):
                        policy.validate_cadence_semantics_probe_artifacts(
                            root,
                            runner,
                            expected_version="1.1.0-beta.9",
                            require_proof=True,
                        )

    def test_cadence_high_rate_output_uses_callback_conservation_not_a_false_cap(self):
        evidence = self.cadence_oracle_evidence()
        policy.validate_cadence_oracle(evidence)

        high_rate_indexes = [
            index
            for index, window in enumerate(evidence["cadenceOracle"]["windows"])
            if window["profile"] in {"50", "59.94", "60"}
            and window["requestedRate"] == 2
        ]
        self.assertEqual(len(high_rate_indexes), 3)
        self.assertTrue(
            all(
                evidence["cadenceOracle"]["windows"][index]["observedSubmissionFPS"]
                > 60
                for index in high_rate_indexes
            )
        )

        # The old model claimed a 60 fps delivery cap while retaining every
        # >60 fps native callback and reporting no explicit Swift rejection.
        # That is impossible at the callback seam and must not qualify.
        for window_index in high_rate_indexes:
            forged = self.clone(evidence)
            window = forged["cadenceOracle"]["windows"][window_index]
            before = forged["samples"][window_index * 2]
            after = forged["samples"][window_index * 2 + 1]
            capped = round(60 * window["windowDurationSeconds"])
            after["vmemOutputSubmittedCount"] = (
                before["vmemOutputSubmittedCount"] + capped
            )
            after["deliveredFrames"] = before["deliveredFrames"] + capped
            window["submittedFrames"] = capped
            window["deliveredFrames"] = capped
            window["observedSubmissionFPS"] = capped / window["windowDurationSeconds"]
            with self.subTest(profile=window["profile"], mutation="false-cap"):
                with self.assertRaises(policy.QualificationPolicyError):
                    policy.validate_cadence_oracle(forged)

        # A real cap is truthful only when every callback is consumed by
        # either submission or an explicit Swift rejection.  Renderer drop
        # accounting is a separate stage and may legitimately exceed 10%.
        capped = self.clone(evidence)
        window_index = next(
            index
            for index, window in enumerate(capped["cadenceOracle"]["windows"])
            if window["profile"] == "60" and window["requestedRate"] == 2
        )
        window = capped["cadenceOracle"]["windows"][window_index]
        before = capped["samples"][window_index * 2]
        after = capped["samples"][window_index * 2 + 1]
        submitted = round(60 * window["windowDurationSeconds"])
        callbacks = window["outputCallbackCount"]
        rejected = callbacks - submitted
        after["vmemOutputSubmittedCount"] = (
            before["vmemOutputSubmittedCount"] + submitted
        )
        after["vmemOutputSwiftRejectedCount"] = (
            before["vmemOutputSwiftRejectedCount"] + rejected
        )
        after["deliveredFrames"] = before["deliveredFrames"] + submitted
        after["droppedFrames"] = before["droppedFrames"] + rejected
        after["backpressureEvents"] = before["backpressureEvents"] + rejected
        window["submittedFrames"] = submitted
        window["swiftRejectedFrames"] = rejected
        window["observedSubmissionFPS"] = submitted / window["windowDurationSeconds"]
        window["deliveredFrames"] = submitted
        metric = next(
            item for item in capped["presentationMetrics"] if item["profile"] == "60"
        )
        metric["deliveredFrames"] -= rejected
        metric["droppedFrames"] = rejected
        metric["backpressureEvents"] = rejected
        metric["dropRate"] = rejected / (
            metric["deliveredFrames"] + metric["droppedFrames"]
        )
        metric["presentationRate"] = (
            metric["deliveredFrames"] / metric["elapsedSeconds"]
        )
        policy.validate_cadence_oracle(capped)

    def test_cadence_native_pts_rate_tolerance_is_relative_to_applied_rate(self):
        def replace_24fps_native_span(
            evidence: dict, requested_rate: float, positive_intervals: int
        ) -> None:
            window_index = next(
                index
                for index, window in enumerate(evidence["cadenceOracle"]["windows"])
                if window["profile"] == "24"
                and window["requestedRate"] == requested_rate
            )
            window = evidence["cadenceOracle"]["windows"][window_index]
            before = evidence["samples"][window_index * 2]
            after = evidence["samples"][window_index * 2 + 1]
            callback_count = (
                after["vmemOutputCallbackCount"] - before["vmemOutputCallbackCount"]
            )
            timestamps = [
                frame * 1_000_000 // 24 for frame in range(positive_intervals + 1)
            ]
            deltas = [
                current - previous
                for previous, current in zip(timestamps, timestamps[1:])
            ]
            deltas += [0] * (callback_count - positive_intervals)
            histogram: dict[int, int] = {}
            for delta in deltas:
                histogram[delta] = histogram.get(delta, 0) + 1
            histogram_items = [
                {"deltaMicroseconds": delta, "count": count}
                for delta, count in sorted(histogram.items())
            ]
            native_span_us = sum(deltas)
            after["vmemOutputDuplicatePTSCount"] = histogram.get(0, 0)
            after["vmemOutputLastPTSUS"] = native_span_us
            after["vmemOutputLastValidPTSUS"] = native_span_us
            after["vmemOutputDeltaHistogram"] = histogram_items
            classification = policy._classify_cadence_window_histogram("24", histogram)
            window.update(classification)
            window["nativePTSDeltaSeconds"] = native_span_us / 1_000_000
            window["nativePTSDeltaHistogram"] = histogram_items

        too_slow_half_rate = self.cadence_oracle_evidence()
        # 48 source intervals over five seconds prove about 0.4x.  The old
        # absolute-error comparison incorrectly accepted this at requested 0.5x.
        replace_24fps_native_span(too_slow_half_rate, 0.5, 48)
        with self.assertRaises(policy.QualificationPolicyError):
            policy.validate_cadence_oracle(too_slow_half_rate)

        honest_tolerance_at_double_rate = self.cadence_oracle_evidence()
        # 210 source intervals over five seconds prove 1.75x.  Its 12.5%
        # relative error is inside the 15% policy even though the absolute
        # difference (0.25x) exceeds 0.15.
        replace_24fps_native_span(honest_tolerance_at_double_rate, 2, 210)
        policy.validate_cadence_oracle(honest_tolerance_at_double_rate)

    def test_cadence_visual_capture_bindings_are_host_replayed(self):
        evidence = self.cadence_oracle_evidence()
        policy.validate_cadence_oracle(evidence)
        mutations = {}

        missing = self.clone(evidence)
        missing.pop("visualCaptureBindings")
        mutations["missing-container"] = missing

        extra = self.clone(evidence)
        extra["visualCaptureBindings"]["records"].append(
            self.clone(extra["visualCaptureBindings"]["records"][-1])
        )
        mutations["extra-record"] = extra

        reordered = self.clone(evidence)
        records = reordered["visualCaptureBindings"]["records"]
        records[0], records[1] = records[1], records[0]
        mutations["wrong-window-order"] = reordered

        boundary = self.clone(evidence)
        record = boundary["visualCaptureBindings"]["records"][0]
        record["captureElapsedSeconds"][0] = record["startElapsedSeconds"] + 1
        mutations["capture-on-conservative-boundary"] = boundary

        exact_boundary = self.clone(evidence)
        record = exact_boundary["visualCaptureBindings"]["records"][0]
        record["captureSystemUptimes"][0] = record["windowStartSystemUptime"]
        mutations["capture-on-exact-uptime-boundary"] = exact_boundary

        shifted_window = self.clone(evidence)
        shifted_window["visualCaptureBindings"]["records"][0][
            "windowStartSystemUptime"
        ] += 0.01
        mutations["binding-window-differs-from-native-samples"] = shifted_window

        shifted_origin = self.clone(evidence)
        shifted_origin["startedSystemUptime"] += 1
        mutations["elapsed-and-absolute-capture-origins-diverge"] = shifted_origin

        malformed = self.clone(evidence)
        malformed["visualCaptureBindings"]["records"][0]["canonicalRGB8Base64"][
            0
        ] = "not base64"
        mutations["malformed-frame-base64"] = malformed

        short = self.clone(evidence)
        short["visualCaptureBindings"]["records"][0]["canonicalRGB8Base64"][0] = (
            base64.b64encode(b"short").decode("ascii")
        )
        mutations["wrong-frame-size"] = short

        changed_frame = self.clone(evidence)
        changed_frame["visualCaptureBindings"]["records"][0]["canonicalRGB8Base64"][
            0
        ] = base64.b64encode(bytes([255]) * policy._VISUAL_FRAME_BYTE_COUNT).decode(
            "ascii"
        )
        mutations["frame-bytes-disagree-with-hash-and-ratios"] = changed_frame

        extra_key = self.clone(evidence)
        extra_key["visualCaptureBindings"]["records"][0]["claimedMotion"] = True
        mutations["binding-schema-extra"] = extra_key

        for label, mutated in mutations.items():
            with self.subTest(label=label):
                with self.assertRaises(policy.QualificationPolicyError):
                    policy.validate_cadence_oracle(mutated)

    def test_cadence_metrics_transitions_drop_and_backpressure_are_fail_closed(self):
        evidence = self.cadence_oracle_evidence()
        policy.validate_cadence_oracle(evidence)
        mutations = {}

        failure = self.clone(evidence)
        failure["presentationMetrics"][0]["presentationCopyFailures"] = 1
        mutations["presentation-copy-failure"] = failure

        duration = self.clone(evidence)
        duration["presentationMetrics"][0]["observedDurationValue"] = None
        mutations["fabricated-duration-field"] = duration

        rate = self.clone(evidence)
        rate["presentationMetrics"][0]["presentationRate"] += 1
        mutations["presentation-rate-not-derived"] = rate

        metric_drop = self.clone(evidence)
        metric_drop["presentationMetrics"][0]["droppedFrames"] = 1
        mutations["profile-drop-rate-not-derived"] = metric_drop

        window_drop = self.clone(evidence)
        window_drop["samples"][1]["droppedFrames"] = 100
        mutations["window-drop-budget"] = window_drop

        backpressure = self.clone(evidence)
        backpressure["samples"][1]["backpressureEvents"] = 100
        mutations["profile-underreports-window-backpressure"] = backpressure

        profile_order = self.clone(evidence)
        (
            profile_order["presentationMetrics"][0],
            profile_order["presentationMetrics"][1],
        ) = (
            profile_order["presentationMetrics"][1],
            profile_order["presentationMetrics"][0],
        )
        mutations["metric-profile-order"] = profile_order

        transition = self.clone(evidence)
        transition["transitionResults"]["rateChanges"] -= 1
        mutations["missing-rate-transition"] = transition

        resize = self.clone(evidence)
        resize["transitionResults"]["resizeTargets"] = ["640x360"]
        resize["transitionResults"]["resizeCycles"] = 0
        mutations["one-render-target"] = resize

        gesture = self.clone(evidence)
        gesture["springboardResizeGestures"] = 5
        mutations["insufficient-springboard-gestures"] = gesture

        for label, mutated in mutations.items():
            with self.subTest(label=label):
                with self.assertRaises(policy.QualificationPolicyError):
                    policy.validate_cadence_oracle(mutated)

    def test_native_renderer_recovery_replays_mechanics_and_system_pip_pixels(self):
        evidence = self.native_renderer_recovery_evidence()
        policy.validate_native_renderer_recovery_evidence(evidence)
        mutations = {}

        fabricated_delta = self.clone(evidence)
        fabricated_delta["mechanics"]["deltas"]["recoveryFlushCount"] += 1
        mutations["fabricated-counter-delta"] = fabricated_delta

        generation_change = self.clone(evidence)
        generation_change["mechanics"]["postForeground"]["displayGeneration"] += 1
        generation_change["mechanics"]["checks"]["sameDisplayGeneration"] = False
        mutations["display-generation-change"] = generation_change

        raw_flags = self.clone(evidence)
        raw_flags["mechanics"]["postForeground"]["rawFlags"] = 1
        mutations["raw-flags-disagree-with-recovery-sample"] = raw_flags

        impossible_notifications = self.clone(evidence)
        impossible_notifications["mechanics"]["postForeground"][
            "revocationNotificationCount"
        ] = 2
        impossible_notifications["mechanics"]["deltas"][
            "revocationNotificationCount"
        ] = 2
        mutations["revocation-count-exceeds-requirement-count"] = (
            impossible_notifications
        )

        impossible_flush_sources = self.clone(evidence)
        impossible_flush_sources["mechanics"]["postForeground"]["failureFlushCount"] = 1
        impossible_flush_sources["mechanics"]["deltas"]["failureFlushCount"] = 1
        mutations["recovery-flush-does-not-equal-source-flushes"] = (
            impossible_flush_sources
        )

        impossible_recovery_submission = self.clone(evidence)
        impossible_recovery_submission["mechanics"]["postForeground"][
            "recoverySubmissionCount"
        ] = 2
        impossible_recovery_submission["mechanics"]["deltas"][
            "recoverySubmissionCount"
        ] = 2
        mutations["recovery-submissions-exceed-recovered-episodes"] = (
            impossible_recovery_submission
        )

        raw_frame = self.clone(evidence)
        raw_frame["postRecoveryVisualOracle"]["captureBinding"]["canonicalRGB8Base64"][
            0
        ] = base64.b64encode(bytes([255]) * policy._VISUAL_FRAME_BYTE_COUNT).decode(
            "ascii"
        )
        mutations["raw-frame-hash-mismatch"] = raw_frame

        not_exercised = self.clone(evidence)
        not_exercised["status"] = "not-exercised"
        not_exercised["mechanics"]["outcome"] = "not-exercised"
        mutations["not-exercised"] = not_exercised

        empty_visual = self.clone(evidence)
        empty_visual["postRecoveryVisualOracle"]["status"] = "not-run"
        empty_visual["postRecoveryVisualOracle"]["captureBinding"]["frameCount"] = 0
        mutations["empty-visual-oracle"] = empty_visual

        synthetic = self.clone(evidence)
        synthetic["syntheticNotificationsPosted"] = True
        mutations["synthetic-notification-trigger"] = synthetic

        missing = self.clone(evidence)
        missing["mechanics"]["checks"].pop("actualResourceRevocationObserved")
        mutations["missing-check"] = missing

        extra = self.clone(evidence)
        extra["postRecoveryVisualOracle"]["captureBinding"]["claimedVisible"] = True
        mutations["visual-schema-extra"] = extra

        top_level_extra = self.clone(evidence)
        top_level_extra["claimedRecovered"] = True
        mutations["top-level-schema-extra"] = top_level_extra

        frozen_pixels = self.clone(evidence)
        encoded = frozen_pixels["postRecoveryVisualOracle"]["captureBinding"][
            "canonicalRGB8Base64"
        ][0]
        frozen_pixels["postRecoveryVisualOracle"]["captureBinding"][
            "canonicalRGB8Base64"
        ] = [encoded, encoded, encoded]
        mutations["repeated-system-pip-frame"] = frozen_pixels

        for label, mutated in mutations.items():
            with self.subTest(label=label):
                with self.assertRaises(policy.QualificationPolicyError):
                    policy.validate_native_renderer_recovery_evidence(mutated)

    def test_vod_controls_derives_every_pass_from_both_backend_raw_records(self):
        evidence = self.vod_controls_evidence()
        policy.validate_vod_controls_evidence(evidence)
        mutations = {}

        self_claim_only = self.clone(evidence)
        self_claim_only["backendResults"]["native"]["controls"][
            "zeroBoundaryAfterMilliseconds"
        ] = 120000
        mutations["native-wraparound-despite-pass-claim"] = self_claim_only

        direct_offset = self.clone(evidence)
        direct_offset["backendResults"]["direct"]["controls"][
            "zeroBoundaryOffsetMilliseconds"
        ] = -100
        mutations["direct-offset-does-not-overshoot"] = direct_offset

        boolean_zero = self.clone(evidence)
        boolean_zero["events"]["unexpectedStopCount"] = False
        mutations["boolean-is-not-a-numeric-zero"] = boolean_zero

        top_level_extra = self.clone(evidence)
        top_level_extra["claimedAllControlsPassed"] = True
        mutations["top-level-schema-extra"] = top_level_extra

        no_zero_presentation = self.clone(evidence)
        controls = no_zero_presentation["backendResults"]["native"]["controls"]
        controls["presentedAfterZeroBoundary"] = controls["presentedBeforeZeroBoundary"]
        mutations["zero-boundary-no-presentation"] = no_zero_presentation

        poisoned_lane = self.clone(evidence)
        poisoned_lane["backendResults"]["direct"]["controls"][
            "postBoundaryForwardAfterMilliseconds"
        ] = 700
        mutations["post-boundary-plus-three-fails"] = poisoned_lane

        advancing_pause = self.clone(evidence)
        advancing_pause["backendResults"]["native"]["controls"][
            "pausedAfterMilliseconds"
        ] = 2000
        mutations["pause-clock-advanced"] = advancing_pause

        scrub_no_presentation = self.clone(evidence)
        controls = scrub_no_presentation["backendResults"]["direct"]["controls"]
        controls["presentedAfterScrub"] = controls["presentedBeforeScrub"]
        mutations["scrub-no-presentation"] = scrub_no_presentation

        forged_top_level = self.clone(evidence)
        forged_top_level["controls"]["skipPastZero"] = "failed"
        mutations["top-level-summary-diverges"] = forged_top_level

        missing_backend = self.clone(evidence)
        missing_backend["backendResults"].pop("direct")
        mutations["one-backend-only"] = missing_backend

        for label, mutated in mutations.items():
            with self.subTest(label=label):
                with self.assertRaises(policy.QualificationPolicyError):
                    policy.validate_vod_controls_evidence(mutated)

    def test_performance_oracle_enforces_resources_and_sustained_content(self):
        for scenario_id in policy.PERFORMANCE_RESOURCE_BUDGETS:
            evidence = self.performance_evidence(scenario_id)
            with self.subTest(scenario=scenario_id, mutation="valid"):
                policy.validate_performance_evidence(evidence, scenario_id)
            mutations = {}
            frozen = self.clone(evidence)
            for field in (
                "presentationCopyFrames",
                "decodedContentChanges",
                "deliveredFrameCount",
            ):
                frozen["samples"][10][field] = frozen["samples"][9][field]
            mutations["flat-content-window"] = frozen
            thermal = self.clone(evidence)
            thermal["samples"][5]["thermalState"] = "serious"
            mutations["thermal-ceiling"] = thermal
            conversion = self.clone(evidence)
            conversion["metrics"]["conversionCost"]["maximumMilliseconds"] = 100
            mutations["conversion-ceiling"] = conversion
            motion = self.clone(evidence)
            del motion["systemPiPMotionSeries"][4]
            del motion["systemPiPMotionSeries"][4]
            mutations["periodic-motion-gap"] = motion
            cpu = self.clone(evidence)
            cpu["metrics"]["cpu"]["value"] = 9_000
            mutations["cpu-ceiling"] = cpu
            for label, mutated in mutations.items():
                with self.subTest(scenario=scenario_id, mutation=label):
                    with self.assertRaises(policy.QualificationPolicyError):
                        policy.validate_performance_evidence(mutated, scenario_id)

    def test_timebase_raw_rejects_audio_video_freeze_loss_and_wrong_clock_slope(self):
        def rows(count: int = 120):
            values = []
            media_time = 0.0
            prior_rate = 0.5
            for elapsed in range(count):
                rate = 0.5 if elapsed < 40 else 1.0 if elapsed < 80 else 2.0
                if elapsed:
                    media_time += prior_rate
                prior_rate = rate
                values.append(
                    {
                        "kind": "sample",
                        "clock": {
                            "elapsedSeconds": elapsed,
                            "mediaTimeSeconds": media_time,
                            "playbackGeneration": 1,
                            "requestedRate": rate,
                            "driftSeconds": 0.01,
                        },
                        "audio": {
                            "elapsedSeconds": elapsed,
                            "mediaTimeSeconds": media_time,
                            "estimatedPresentationSeconds": media_time - 0.01,
                            "outputLatencySeconds": 0.005,
                            "ioBufferDurationSeconds": 0.005,
                            "playedBuffers": elapsed + 1,
                            "lostBuffers": 0,
                        },
                        "frame": {
                            "elapsedSeconds": elapsed,
                            "playbackGeneration": 1,
                            "deliveredFrames": elapsed + 1,
                            "droppedFrames": 0,
                            "decodedFrames": elapsed + 1,
                            "presentedSeconds": media_time,
                            "decodedFrameMediaTimeSeconds": media_time,
                        },
                    }
                )
            return values

        def inspect(values):
            with tempfile.TemporaryDirectory() as temporary:
                path = Path(temporary) / "capture.jsonl"
                path.write_text("".join(json.dumps(row) + "\n" for row in values))
                return policy.inspect_timebase_raw_capture(path, 1)

        valid = rows()
        rebuilt = inspect(valid)
        self.assertEqual(rebuilt["audioProgressWindowViolationCount"], 0)
        self.assertEqual(rebuilt["videoProgressWindowViolationCount"], 0)
        self.assertEqual(rebuilt["clockSlopeViolationCount"], 0)

        frozen_audio = self.clone(valid)
        for row in frozen_audio[2:]:
            row["audio"]["playedBuffers"] = 2
        frozen_video = self.clone(valid)
        for row in frozen_video[2:]:
            for field in (
                "deliveredFrames",
                "decodedFrames",
                "presentedSeconds",
                "decodedFrameMediaTimeSeconds",
            ):
                frozen_video_value = frozen_video[1]["frame"][field]
                row["frame"][field] = frozen_video_value
        excessive_loss = self.clone(valid)
        for index, row in enumerate(excessive_loss):
            row["audio"]["lostBuffers"] = index
        wrong_slope = self.clone(valid)
        for index, row in enumerate(wrong_slope):
            row["frame"]["presentedSeconds"] = index
            row["frame"]["decodedFrameMediaTimeSeconds"] = index
        mismatched_nested_clock = self.clone(valid)
        mismatched_nested_clock[10]["audio"]["elapsedSeconds"] = 11
        extra_nested_field = self.clone(valid)
        extra_nested_field[10]["clock"]["forged"] = True
        dead_recovery_generation = self.clone(valid)
        for row in dead_recovery_generation[-10:]:
            row["clock"]["playbackGeneration"] = 2
            row["frame"]["playbackGeneration"] = 2
            row["audio"]["playedBuffers"] = 1
            row["frame"]["deliveredFrames"] = 1
            row["frame"]["decodedFrames"] = 1
        for label, mutated in {
            "freeze-after-one-audio": frozen_audio,
            "long-flat-video": frozen_video,
            "lost-buffer-budget": excessive_loss,
            "wrong-rate-clock-slope": wrong_slope,
            "mismatched-nested-clock": mismatched_nested_clock,
            "extra-nested-field": extra_nested_field,
            "post-interruption-generation-never-progressed": (dead_recovery_generation),
        }.items():
            with self.subTest(label=label):
                with self.assertRaises(policy.QualificationPolicyError):
                    inspect(mutated)

    def test_xctrace_export_summary_binds_target_numeric_timeline(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            trace = root / "fixture.trace"
            trace.mkdir()
            (trace / "store.bin").write_bytes(b"trace-store")
            toc = root / "fixture-toc.xml"
            toc.write_text(
                '<trace-toc><run number="1"><template>Game Performance</template>'
                "<target>iOS fixture-device</target><duration>900</duration>"
                '<data><table schema="gpu-samples"/></data></run></trace-toc>'
            )
            exported = (
                "<trace-query-result>"
                '<row><process>iOS</process><timestamp unit="seconds">0</timestamp>'
                '<gpu-utilization unit="percent">50</gpu-utilization></row>'
                '<row><process>iOS</process><timestamp unit="seconds">900</timestamp>'
                '<gpu-utilization unit="percent">60</gpu-utilization></row>'
                "</trace-query-result>"
            )
            completed = subprocess.CompletedProcess([], 0, stdout=exported, stderr="")
            with mock.patch.object(policy.subprocess, "run", return_value=completed):
                summary = policy.capture_xctrace_export_summary(
                    trace,
                    toc,
                    scenario_id="pip-render-performance-4k60",
                    role="gpu",
                    template="Game Performance",
                    target_device_identifier="fixture-device",
                    producer_fields={
                        "producerRunnerScenario": "pip-render-performance-4k60",
                        "producerSourceAttempt": 1,
                        "producerXcresultDigest": "9" * 64,
                        "evidenceStem": "fixture",
                    },
                )
            self.assertEqual(summary["measurement"]["targetProcessRowCount"], 2)
            self.assertEqual(summary["measurement"]["averageValue"], 55)
            self.assertEqual(summary["measurement"]["timelineEndSeconds"], 900)

            wrong_process = exported.replace(
                "<process>iOS</process>", "<process>Other</process>"
            )
            completed = subprocess.CompletedProcess(
                [], 0, stdout=wrong_process, stderr=""
            )
            with mock.patch.object(policy.subprocess, "run", return_value=completed):
                with self.assertRaises(policy.QualificationPolicyError):
                    policy.capture_xctrace_export_summary(
                        trace,
                        toc,
                        scenario_id="pip-render-performance-4k60",
                        role="gpu",
                        template="Game Performance",
                        target_device_identifier="fixture-device",
                        producer_fields={
                            "producerRunnerScenario": "pip-render-performance-4k60",
                            "producerSourceAttempt": 1,
                            "producerXcresultDigest": "9" * 64,
                            "evidenceStem": "fixture",
                        },
                    )

            incidental_platform = wrong_process.replace(
                "<process>Other</process>",
                "<process>Other</process><platform>iOS</platform>",
            )
            completed = subprocess.CompletedProcess(
                [], 0, stdout=incidental_platform, stderr=""
            )
            with mock.patch.object(policy.subprocess, "run", return_value=completed):
                with self.assertRaises(policy.QualificationPolicyError):
                    policy.capture_xctrace_export_summary(
                        trace,
                        toc,
                        scenario_id="pip-render-performance-4k60",
                        role="gpu",
                        template="Game Performance",
                        target_device_identifier="fixture-device",
                        producer_fields={
                            "producerRunnerScenario": "pip-render-performance-4k60",
                            "producerSourceAttempt": 1,
                            "producerXcresultDigest": "9" * 64,
                            "evidenceStem": "fixture",
                        },
                    )

    def test_xctrace_audio_timeline_uses_only_audio_render_rows(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            trace = root / "audio.trace"
            trace.mkdir()
            (trace / "store.bin").write_bytes(b"trace-store")
            toc = root / "audio-toc.xml"
            toc.write_text(
                '<trace-toc><run number="1"><template>Audio System Trace</template>'
                "<target>iOS fixture-device</target><duration>7200</duration>"
                '<data><table schema="audio-samples"/></data></run></trace-toc>'
            )
            exported = (
                "<trace-query-result>"
                '<row><process>iOS</process><timestamp unit="seconds">0</timestamp>'
                "<audio-render-buffer>1</audio-render-buffer></row>"
                '<row><process>iOS</process><timestamp unit="seconds">3600</timestamp>'
                '<cpu-utilization unit="percent">10</cpu-utilization></row>'
                '<row><process>iOS</process><timestamp unit="seconds">7200</timestamp>'
                '<cpu-utilization unit="percent">10</cpu-utilization></row>'
                "</trace-query-result>"
            )
            completed = subprocess.CompletedProcess([], 0, stdout=exported, stderr="")
            with mock.patch.object(policy.subprocess, "run", return_value=completed):
                with self.assertRaises(policy.QualificationPolicyError):
                    policy.capture_xctrace_export_summary(
                        trace,
                        toc,
                        scenario_id="timebase-vod-soak",
                        role="audioPresentationSeries",
                        template="Audio System Trace",
                        target_device_identifier="fixture-device",
                        producer_fields={
                            "producerRunnerScenario": "timebase-vod-soak",
                            "producerSourceAttempt": 1,
                            "producerXcresultDigest": "9" * 64,
                            "evidenceStem": "fixture",
                        },
                    )

    def test_every_augmented_trace_lane_reopens_exact_retained_summary(self):
        cases = [
            (scenario, role, template, token, extra)
            for scenario, requirements in policy.HOST_TRACE_REQUIREMENTS.items()
            for _, role, template, token, extra in requirements
        ]
        for case_index, (scenario, role, template, token, extra) in enumerate(cases):
            with self.subTest(scenario=scenario, role=role):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    stem = f"fixture-{case_index}"
                    producer = {
                        "producerRunnerScenario": scenario,
                        "producerSourceAttempt": 1,
                        "producerXcresultDigest": "9" * 64,
                        "evidenceStem": stem,
                    }
                    directory = root / "artifacts" / stem
                    directory.mkdir(parents=True)
                    trace = directory / f"{scenario}-{token}-attempt1.trace"
                    trace.mkdir()
                    (trace / "store.bin").write_bytes(b"retained-instruments-store")
                    toc = directory / f"{scenario}-{token}-attempt1-toc.xml"
                    marker = (
                        "allocation"
                        if template == "Allocations"
                        else "audio" if template == "Audio System Trace" else "samples"
                    )
                    toc.write_text(f'<trace-toc><table schema="{marker}"/></trace-toc>')
                    summary_path = (
                        directory / f"{scenario}-{token}-attempt1-summary.json"
                    )
                    duration = policy.trace_minimum_capture_duration(
                        scenario,
                        role,
                        policy.STABLE_MINIMUM_DURATION_SECONDS[scenario],
                    )
                    metric, unit = policy.TRACE_MEASUREMENT_SPECS[role]
                    summary = {
                        "formatVersion": 1,
                        "status": "captured",
                        "source": "xctrace-export-v1",
                        "runNumber": 1,
                        "scenario": scenario,
                        "artifactRole": role,
                        "template": template,
                        "targetProcess": "iOS",
                        "targetDeviceIdentifier": "fixture-device",
                        "captureDurationSeconds": duration,
                        "tables": [
                            {
                                "schema": f"{role}-samples",
                                "rowCount": 10,
                                "targetProcessRowCount": 10,
                            }
                        ],
                        "totalRowCount": 10,
                        "measurement": {
                            "metric": metric,
                            "unit": unit,
                            "sampleCount": 10,
                            "targetProcessRowCount": 10,
                            "minimumValue": 1.0,
                            "averageValue": 1.0,
                            "maximumValue": 1.0,
                            "timelineStartSeconds": 0.0,
                            "timelineEndSeconds": duration,
                            "maximumSampleGapSeconds": 1.0,
                            "sourceFields": [f"{role}-fixture"],
                        },
                        "traceTreeDigestAlgorithm": "swiftvlc-tree-v1",
                        "traceTreeDigest": policy.tree_digest(trace),
                        "tableOfContentsDigestAlgorithm": "sha256",
                        "tableOfContentsDigest": policy.sha256_file(toc),
                        **producer,
                    }
                    summary_path.write_text(json.dumps(summary, sort_keys=True))
                    record = {
                        "status": "captured",
                        "artifactRole": role,
                        "template": template,
                        "format": "com.apple.instruments.trace",
                        "runArtifact": trace.relative_to(root).as_posix(),
                        "tableOfContents": toc.relative_to(root).as_posix(),
                        "treeDigestAlgorithm": "swiftvlc-tree-v1",
                        "treeDigest": policy.tree_digest(trace),
                        "treeSizeBytes": policy.tree_size_bytes(trace),
                        "treeEntryCount": policy.tree_entry_count(trace),
                        "tableOfContentsDigestAlgorithm": "sha256",
                        "tableOfContentsDigest": policy.sha256_file(toc),
                        "tableOfContentsSizeBytes": toc.stat().st_size,
                        "targetProcess": "iOS",
                        "exportSummary": summary_path.relative_to(root).as_posix(),
                        "exportSummaryDigestAlgorithm": "sha256",
                        "exportSummaryDigest": policy.sha256_file(summary_path),
                        "exportSummarySizeBytes": summary_path.stat().st_size,
                        **producer,
                        **extra,
                    }
                    policy.validate_host_trace_record(
                        record,
                        root,
                        role=role,
                        template=template,
                        scenario_id=scenario,
                        target_device_identifier="fixture-device",
                        minimum_duration=duration,
                        description=f"{scenario} {role}",
                        artifact_token=token,
                        producer_fields=producer,
                        extra=extra,
                    )
                    for label, mutate in {
                        "zero-row": lambda value: (
                            value["tables"][0].update(
                                {"rowCount": 0, "targetProcessRowCount": 0}
                            ),
                            value.update({"totalRowCount": 0}),
                            value["measurement"].update(
                                {"sampleCount": 0, "targetProcessRowCount": 0}
                            ),
                        ),
                        "wrong-target": lambda value: value.update(
                            {"targetDeviceIdentifier": "other-device"}
                        ),
                        "truncated-duration": lambda value: (
                            value.update({"captureDurationSeconds": 1}),
                            value["measurement"].update({"timelineEndSeconds": 1}),
                        ),
                        "wrong-metric-schema": lambda value: value[
                            "measurement"
                        ].update({"metric": "forged"}),
                        "cross-scenario-swap": lambda value: value.update(
                            {"scenario": "other-scenario"}
                        ),
                        "prior-attempt-swap": lambda value: value.update(
                            {"producerSourceAttempt": 2}
                        ),
                    }.items():
                        mutated = self.clone(summary)
                        mutate(mutated)
                        summary_path.write_text(json.dumps(mutated, sort_keys=True))
                        candidate = dict(record)
                        candidate["exportSummaryDigest"] = policy.sha256_file(
                            summary_path
                        )
                        candidate["exportSummarySizeBytes"] = (
                            summary_path.stat().st_size
                        )
                        with self.subTest(mutation=label):
                            with self.assertRaises(policy.QualificationPolicyError):
                                policy.validate_host_trace_record(
                                    candidate,
                                    root,
                                    role=role,
                                    template=template,
                                    scenario_id=scenario,
                                    target_device_identifier="fixture-device",
                                    minimum_duration=duration,
                                    description=f"{scenario} {role}",
                                    artifact_token=token,
                                    producer_fields=producer,
                                    extra=extra,
                                )
                    if role in {"gpu", "energy"} and scenario in (
                        policy.PERFORMANCE_RESOURCE_BUDGETS
                    ):
                        over_budget = self.clone(summary)
                        limit_key = (
                            "gpuMaximumPercent"
                            if role == "gpu"
                            else "energyMaximumScore"
                        )
                        value = (
                            policy.PERFORMANCE_RESOURCE_BUDGETS[scenario][limit_key] + 1
                        )
                        over_budget["measurement"].update(
                            {"averageValue": value, "maximumValue": value}
                        )
                        summary_path.write_text(json.dumps(over_budget, sort_keys=True))
                        candidate = dict(record)
                        candidate["exportSummaryDigest"] = policy.sha256_file(
                            summary_path
                        )
                        candidate["exportSummarySizeBytes"] = (
                            summary_path.stat().st_size
                        )
                        with self.assertRaises(policy.QualificationPolicyError):
                            policy.validate_host_trace_record(
                                candidate,
                                root,
                                role=role,
                                template=template,
                                scenario_id=scenario,
                                target_device_identifier="fixture-device",
                                minimum_duration=duration,
                                description=f"{scenario} {role}",
                                artifact_token=token,
                                producer_fields=producer,
                                extra=extra,
                            )
                    summary_path.write_text(json.dumps(summary, sort_keys=True))
                    stale_digest = dict(record)
                    stale_digest["exportSummaryDigest"] = "0" * 64
                    with self.assertRaises(policy.QualificationPolicyError):
                        policy.validate_host_trace_record(
                            stale_digest,
                            root,
                            role=role,
                            template=template,
                            scenario_id=scenario,
                            target_device_identifier="fixture-device",
                            minimum_duration=duration,
                            description=f"{scenario} {role}",
                            artifact_token=token,
                            producer_fields=producer,
                            extra=extra,
                        )
                    saved_trace = trace.with_name(trace.name + ".saved")
                    trace.rename(saved_trace)
                    trace.write_text("not-a-trace-directory")
                    with self.assertRaises(policy.QualificationPolicyError):
                        policy.validate_host_trace_record(
                            record,
                            root,
                            role=role,
                            template=template,
                            scenario_id=scenario,
                            target_device_identifier="fixture-device",
                            minimum_duration=duration,
                            description=f"{scenario} {role}",
                            artifact_token=token,
                            producer_fields=producer,
                            extra=extra,
                        )
                    trace.unlink()
                    saved_trace.rename(trace)
                    missing = dict(record)
                    missing["exportSummary"] = (
                        (directory / "missing-summary.json")
                        .relative_to(root)
                        .as_posix()
                    )
                    with self.assertRaises(policy.QualificationPolicyError):
                        policy.validate_host_trace_record(
                            missing,
                            root,
                            role=role,
                            template=template,
                            scenario_id=scenario,
                            target_device_identifier="fixture-device",
                            minimum_duration=duration,
                            description=f"{scenario} {role}",
                            artifact_token=token,
                            producer_fields=producer,
                            extra=extra,
                        )
                    escaped = dict(record)
                    escaped["runArtifact"] = "../outside.trace"
                    with self.assertRaises(policy.QualificationPolicyError):
                        policy.validate_host_trace_record(
                            escaped,
                            root,
                            role=role,
                            template=template,
                            scenario_id=scenario,
                            target_device_identifier="fixture-device",
                            minimum_duration=duration,
                            description=f"{scenario} {role}",
                            artifact_token=token,
                            producer_fields=producer,
                            extra=extra,
                        )
                    trace.rename(saved_trace)
                    trace.symlink_to(saved_trace, target_is_directory=True)
                    with self.assertRaises(policy.QualificationPolicyError):
                        policy.validate_host_trace_record(
                            record,
                            root,
                            role=role,
                            template=template,
                            scenario_id=scenario,
                            target_device_identifier="fixture-device",
                            minimum_duration=duration,
                            description=f"{scenario} {role}",
                            artifact_token=token,
                            producer_fields=producer,
                            extra=extra,
                        )

    def test_enumeration_requires_nonzero_concrete_leaf_tests(self):
        with self.assertRaises(policy.QualificationPolicyError):
            policy.catalog_from_enumeration(
                {
                    "errors": [],
                    "values": [{"enabledTests": [{"identifier": "iOSUITests"}]}],
                }
            )
        catalog = policy.catalog_from_enumeration(
            {
                "errors": [],
                "values": [
                    {
                        "enabledTests": [
                            {"identifier": "iOSUITests/AnalyzerTests/test_pixels()"}
                        ]
                    }
                ],
            }
        )
        self.assertEqual(catalog, ["iOSUITests/AnalyzerTests/test_pixels"])

    def test_enumeration_excludes_disabled_tests(self):
        document = {
            "errors": [],
            "values": [{
                "enabledTests": [{"identifier": "iOSUITests/AnalyzerTests/test_pixels()"}],
                "disabledTests": [{"identifier": "iOSUITests/PlayerTests/test_play()"}],
            }],
        }
        self.assertEqual(
            policy.catalog_from_enumeration(document),
            ["iOSUITests/AnalyzerTests/test_pixels"],
        )
        document["values"][0]["enabledTests"] = []
        with self.assertRaisesRegex(policy.QualificationPolicyError, "zero leaf tests"):
            policy.catalog_from_enumeration(document)

    def test_ui_suite_contract_excludes_only_matrix_owned_device_prefixes(self):
        matrix = policy.load_json(QUALIFICATION / "matrix.json", "qualification matrix")
        contracts, _ = policy.validate_runner_contracts(matrix)
        ui_suite = contracts["ui-suite"]
        candidate_catalog = sorted(
            [
                "iOSUITests/GeneralUITests/test_firstKeptLeaf",
                "iOSUITests/GeneralUITests/test_secondKeptLeaf",
                "iOSUITests/PiPLiveDeviceUITests/test_excludedLiveLeaf",
                "iOSUITests/SeekFrameOracleDeviceUITests/test_excludedSeekLeaf",
                "iOSUITests/LocalPlaybackMatrixDeviceUITests/test_excludedLocalLeaf",
                "iOSUITests/AudioOnlyPlaybackDeviceUITests/test_excludedAudioLeaf",
            ]
        )
        selected = policy.authorized_runner_catalog(ui_suite, set(), candidate_catalog)
        self.assertEqual(
            selected,
            policy.catalog_record(
                [
                    "iOSUITests/GeneralUITests/test_firstKeptLeaf",
                    "iOSUITests/GeneralUITests/test_secondKeptLeaf",
                ]
            ),
        )

    def test_xcresult_identity_and_count_are_exact(self):
        expected = policy.catalog_record(["iOSUITests/AnalyzerTests/test_pixels"])
        document = {
            "testNodes": [
                {
                    "nodeType": "Test Case",
                    "nodeIdentifier": "iOSUITests/AnalyzerTests/test_pixels()",
                    "name": "test_pixels()",
                    "result": "Passed",
                }
            ]
        }
        identifiers, results, failure = policy.executed_catalog_from_xcresult(document)
        self.assertEqual(identifiers, expected["testIdentifiers"])
        self.assertEqual(results, ["Passed"])
        self.assertFalse(failure)

        document["testNodes"].append(
            {
                "nodeType": "Test Case",
                "nodeIdentifier": "iOSUITests/AnalyzerTests/test_other()",
                "name": "test_other()",
                "result": "Passed",
            }
        )
        identifiers, _, _ = policy.executed_catalog_from_xcresult(document)
        self.assertNotEqual(identifiers, expected["testIdentifiers"])

    def test_xcode26_xcresult_short_node_identifier_reconciles_with_url(self):
        # Captured from the archived 2026-08-31 physical vod-controls xcresult.
        document = {
            "testNodes": [
                {
                    "name": "test_vodControlsAcrossNativeAndDirectBackends()",
                    "nodeIdentifier": (
                        "PiPVODControlsDeviceUITests/"
                        "test_vodControlsAcrossNativeAndDirectBackends()"
                    ),
                    "nodeIdentifierURL": (
                        "test://com.apple.xcode/SwiftVLCShowcase/iOSUITests/"
                        "PiPVODControlsDeviceUITests/"
                        "test_vodControlsAcrossNativeAndDirectBackends"
                    ),
                    "nodeType": "Test Case",
                    "result": "Passed",
                }
            ]
        }
        identifiers, results, failure = policy.executed_catalog_from_xcresult(
            document
        )
        self.assertEqual(
            identifiers,
            [
                "iOSUITests/PiPVODControlsDeviceUITests/"
                "test_vodControlsAcrossNativeAndDirectBackends"
            ],
        )
        self.assertEqual(results, ["Passed"])
        self.assertFalse(failure)

        mismatched = self.clone(document)
        mismatched["testNodes"][0]["nodeIdentifier"] = (
            "PiPVODControlsDeviceUITests/test_anotherMethod()"
        )
        with self.assertRaisesRegex(
            policy.QualificationPolicyError, "owner fields disagree"
        ):
            policy.executed_catalog_from_xcresult(mismatched)

    def test_busy_phrase_never_retries_an_xctest_failure(self):
        expected = policy.catalog_record(["iOSUITests/PlayerTests/test_product"])
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / "failed.xcresult"
            bundle.mkdir()
            original = policy.xcresult_test_document
            policy.xcresult_test_document = lambda _: {
                "testNodes": [
                    {
                        "nodeType": "Test Case",
                        "nodeIdentifier": "iOSUITests/PlayerTests/test_product()",
                        "result": "Failed",
                        "name": "test_product()",
                    },
                    {"nodeType": "Failure Message", "name": "XCTAssertEqual failed"},
                ]
            }
            try:
                classification = policy.classify_retry(
                    bundle,
                    "device reason: Busy while test assertion failed",
                    expected,
                )
            finally:
                policy.xcresult_test_document = original
        self.assertFalse(classification["retryable"])
        self.assertEqual(classification["classification"], "productFailure")

    def test_busy_phrase_never_retries_any_nonpassing_test_outcome(self):
        expected = policy.catalog_record(["iOSUITests/PlayerTests/test_product"])
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / "skipped.xcresult"
            bundle.mkdir()
            original = policy.xcresult_test_document
            policy.xcresult_test_document = lambda _: {
                "testNodes": [
                    {
                        "nodeType": "Test Case",
                        "nodeIdentifier": "iOSUITests/PlayerTests/test_product()",
                        "result": "Skipped",
                        "name": "test_product()",
                    }
                ]
            }
            try:
                classification = policy.classify_retry(
                    bundle, "device reason: Busy", expected
                )
            finally:
                policy.xcresult_test_document = original
        self.assertFalse(classification["retryable"])
        self.assertEqual(classification["classification"], "productFailure")

    def test_xcresult_verifier_rejects_a_skipped_selected_test(self):
        expected = policy.catalog_record(["iOSUITests/PlayerTests/test_product"])
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / "skipped.xcresult"
            bundle.mkdir()
            original = policy.xcresult_test_document
            policy.xcresult_test_document = lambda _: {
                "testNodes": [
                    {
                        "nodeType": "Test Case",
                        "nodeIdentifier": "iOSUITests/PlayerTests/test_product()",
                        "result": "Skipped",
                        "name": "test_product()",
                    }
                ]
            }
            try:
                with self.assertRaisesRegex(
                    policy.QualificationPolicyError,
                    "did not all pass",
                ):
                    policy.verify_xcresult_execution(bundle, expected)
            finally:
                policy.xcresult_test_document = original

    def test_fatal_product_signal_with_busy_and_no_readable_xcresult_is_terminal(self):
        expected = policy.catalog_record(["iOSUITests/PlayerTests/test_product"])
        classification = policy.classify_retry(
            None,
            "Fatal decoder heap corruption while starting playback\nreason: Busy",
            expected,
        )
        self.assertFalse(classification["retryable"])
        self.assertFalse(classification["structuredResultReadable"])
        self.assertTrue(classification["productFailureObserved"])

    def test_retry_requires_structured_zero_test_lifecycle_proof(self):
        expected = policy.catalog_record(["iOSUITests/PlayerTests/test_product"])
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / "launch.xcresult"
            bundle.mkdir()
            original = policy.xcresult_test_document
            policy.xcresult_test_document = lambda _: {"testNodes": []}
            try:
                classification = policy.classify_retry(bundle, "reason: Busy", expected)
            finally:
                policy.xcresult_test_document = original
        self.assertTrue(classification["retryable"])
        self.assertTrue(classification["lifecycleProvesNoIntendedTestBegan"])

    def test_later_pass_cannot_erase_an_earlier_product_failure(self):
        catalog = policy.catalog_record(["iOSUITests/PlayerTests/test_product"])
        execution = {
            "expected": catalog,
            "executed": catalog,
            "identityAndCountMatch": True,
            "allPassed": True,
        }
        attempts = [
            {
                "attempt": 1,
                "classification": "productFailure",
                "retryable": False,
                "structuredResultReadable": False,
                "lifecycleProvesNoIntendedTestBegan": False,
                "intendedTestBegan": False,
                "productFailureObserved": True,
                "logArtifact": "attempt1.log",
                "xcresultArtifact": "attempt1.xcresult",
            },
            {
                "attempt": 2,
                "classification": "passed",
                "retryable": False,
                "intendedTestBegan": True,
                "xcodebuildExitCode": 0,
                "logArtifact": "attempt2.log",
                "xcresultArtifact": "attempt2.xcresult",
                "testExecution": execution,
            },
        ]
        with self.assertRaises(policy.QualificationPolicyError):
            policy.validate_attempt_history(
                attempts, runner_result="pass", final_execution=execution
            )

    def test_passed_xcresult_cannot_override_retained_fatal_attempt_log(self):
        catalog = policy.catalog_record(["iOSUITests/PlayerTests/test_product"])
        execution = {
            "expected": catalog,
            "executed": catalog,
            "identityAndCountMatch": True,
            "allPassed": True,
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scope = root / "player-attempt-artifacts"
            scope.mkdir()
            log = scope / "attempt-1.log"
            bundle = scope / "attempt-1.xcresult"
            bundle.mkdir()
            (bundle / "Info.plist").write_text("fixture")
            original = policy.xcresult_test_document
            policy.xcresult_test_document = lambda _: {
                "testNodes": [
                    {
                        "nodeType": "Test Case",
                        "nodeIdentifier": catalog["testIdentifiers"][0],
                        "result": "Passed",
                    }
                ]
            }
            try:
                log.write_text("Recovered after a transient connection; reason: Busy\n")
                attempts = policy.bind_attempt_artifacts(
                    [
                        {
                            "attempt": 1,
                            "classification": "passed",
                            "retryable": False,
                            "intendedTestBegan": True,
                            "xcodebuildExitCode": 0,
                            "logArtifact": log.relative_to(root).as_posix(),
                            "xcresultArtifact": bundle.relative_to(root).as_posix(),
                            "testExecution": execution,
                        }
                    ],
                    root,
                )
                policy.validate_attempt_history(
                    attempts,
                    runner_result="pass",
                    final_execution=execution,
                    expected_catalog=catalog,
                    artifact_root=root,
                    artifact_scope=scope.name,
                    require_artifacts=True,
                )

                log.write_text(
                    "Fatal decoder heap corruption while starting playback\nreason: Busy\n"
                )
                attempts = policy.bind_attempt_artifacts(attempts, root)
                with self.assertRaises(policy.QualificationPolicyError):
                    policy.validate_attempt_history(
                        attempts,
                        runner_result="pass",
                        final_execution=execution,
                        expected_catalog=catalog,
                        artifact_root=root,
                        artifact_scope=scope.name,
                        require_artifacts=True,
                    )

                log.write_bytes(b"invalid-utf8:\xff\n")
                attempts = policy.bind_attempt_artifacts(attempts, root)
                with self.assertRaises(policy.QualificationPolicyError):
                    policy.validate_attempt_history(
                        attempts,
                        runner_result="pass",
                        final_execution=execution,
                        expected_catalog=catalog,
                        artifact_root=root,
                        artifact_scope=scope.name,
                        require_artifacts=True,
                    )

                log.write_text("Recovered after a transient connection\n")
                (root / "outside.dat").write_text("not bound as xcresult content")
                (bundle / "escaped").symlink_to(root / "outside.dat")
                with self.assertRaises(policy.QualificationPolicyError):
                    policy.bind_attempt_artifacts(attempts, root)
            finally:
                policy.xcresult_test_document = original

    def test_passed_xcresult_rejects_fatal_sibling_diagnostic(self):
        catalog = policy.catalog_record(["iOSUITests/PlayerTests/test_product"])
        execution = {
            "expected": catalog,
            "executed": catalog,
            "identityAndCountMatch": True,
            "allPassed": True,
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scope = root / "player-attempt-artifacts"
            scope.mkdir()
            log = scope / "attempt-1.log"
            log.write_text("** TEST EXECUTE SUCCEEDED **\n")
            bundle = scope / "attempt-1.xcresult"
            bundle.mkdir()
            (bundle / "Info.plist").write_text("fixture")
            attempts = policy.bind_attempt_artifacts(
                [
                    {
                        "attempt": 1,
                        "classification": "passed",
                        "retryable": False,
                        "intendedTestBegan": True,
                        "xcodebuildExitCode": 0,
                        "logArtifact": log.relative_to(root).as_posix(),
                        "xcresultArtifact": bundle.relative_to(root).as_posix(),
                        "testExecution": execution,
                    }
                ],
                root,
            )
            document = {
                "testNodes": [
                    {
                        "nodeType": "Test Case",
                        "nodeIdentifier": catalog["testIdentifiers"][0],
                        "result": "Passed",
                    }
                ],
                "diagnostics": [
                    {
                        "nodeType": "Diagnostic",
                        "name": "Recovered after an attributed HTTP retry",
                    }
                ],
            }
            original = policy.xcresult_test_document
            policy.xcresult_test_document = lambda _: document
            try:
                policy.validate_attempt_history(
                    attempts,
                    runner_result="pass",
                    final_execution=execution,
                    expected_catalog=catalog,
                    artifact_root=root,
                    artifact_scope=scope.name,
                    require_artifacts=True,
                )
                document["diagnostics"][0]["name"] = "Fatal decoder heap corruption"
                with self.assertRaises(policy.QualificationPolicyError):
                    policy.validate_attempt_history(
                        attempts,
                        runner_result="pass",
                        final_execution=execution,
                        expected_catalog=catalog,
                        artifact_root=root,
                        artifact_scope=scope.name,
                        require_artifacts=True,
                    )
            finally:
                policy.xcresult_test_document = original

    def test_global_product_failure_signatures_cover_structured_raw_fields(self):
        signatures = (
            "LeakSanitizer detected a leak",
            "UndefinedBehaviorSanitizer report",
            "EXC_BAD_ACCESS",
            "Swift runtime failure",
            "stack-buffer-overflow",
            "double free",
            "data race",
        )
        for signature in signatures:
            with self.subTest(signature=signature):
                self.assertTrue(policy.product_failure_signals(signature))
        self.assertFalse(
            policy.product_failure_signals(
                "Recovered after a transient HTTP retry; no errors remain"
            )
        )

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "run-seek.jsonl"
            path.write_text(
                json.dumps({"level": "fatal", "message": "otherwise benign"}) + "\n"
            )
            with self.assertRaises(policy.QualificationPolicyError):
                policy.build_error_inventory(root, "run", "seek")
            path.write_text(
                json.dumps(
                    {
                        "level": "debug",
                        "module": "EXC_BAD_ACCESS",
                        "message": "otherwise benign",
                    }
                )
                + "\n"
            )
            with self.assertRaises(policy.QualificationPolicyError):
                policy.build_error_inventory(root, "run", "seek")

    def test_multitest_device_logs_bind_every_leaf_and_require_health(self):
        identifiers = [
            "iOSUITests/FirstUITests/test_first",
            "iOSUITests/SecondUITests/test_second",
        ]
        catalog = policy.catalog_record(identifiers)
        health = (
            json.dumps(
                {
                    "ts": "2026-08-31T12:00:00Z",
                    "level": "debug",
                    "module": policy.LOG_MIRROR_HEALTH_MODULE,
                    "message": policy.LOG_MIRROR_HEALTH_MESSAGE,
                }
            )
            + "\n"
        )
        for scenario in ("ui-suite", "harness-regressions"):
            with self.subTest(
                scenario=scenario
            ), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary)
                root = base / "logs"
                root.mkdir()
                paths = []
                for index, identifier in enumerate(identifiers, 1):
                    path = root / policy.test_log_filename(
                        "run",
                        identifier,
                        f"00000000-0000-4000-8000-{index:012d}",
                    )
                    path.write_text(health)
                    paths.append(path)
                inventory = policy.build_error_inventory(
                    root,
                    "run",
                    scenario,
                    retained_root="logs",
                    expected_test_catalog=catalog,
                )
                policy.validate_error_inventory(
                    inventory,
                    retained_base=base,
                    require_retained=True,
                    expected_test_catalog=catalog,
                )

                paths[1].unlink()
                with self.assertRaisesRegex(
                    policy.QualificationPolicyError, "has no retained device JSONL"
                ):
                    policy.build_error_inventory(
                        root,
                        "run",
                        scenario,
                        expected_test_catalog=catalog,
                    )
                paths[1].write_text(health)

                for label, payload in (
                    ("empty", ""),
                    ("truncated", '{"level":"debug"'),
                    (
                        "no health",
                        json.dumps(
                            {
                                "ts": "2026-08-31T12:00:00Z",
                                "level": "debug",
                                "module": "fixture",
                                "message": "launch",
                            }
                        )
                        + "\n",
                    ),
                ):
                    with self.subTest(scenario=scenario, mutation=label):
                        paths[0].write_text(payload)
                        with self.assertRaises(policy.QualificationPolicyError):
                            policy.build_error_inventory(
                                root,
                                "run",
                                scenario,
                                expected_test_catalog=catalog,
                            )
                        paths[0].write_text(health)

                unknown = root / policy.test_log_filename(
                    "run",
                    "iOSUITests/UnknownUITests/test_unknown",
                    "00000000-0000-4000-8000-000000000003",
                )
                unknown.write_text(health)
                with self.assertRaisesRegex(
                    policy.QualificationPolicyError, "exactly one expected XCTest"
                ):
                    policy.build_error_inventory(
                        root,
                        "run",
                        scenario,
                        expected_test_catalog=catalog,
                    )

    def test_declared_child_log_family_requires_its_base_log(self):
        scenario = "audio-media-services-reset"
        identifier = (
            "iOSUITests/MediaServicesResetDeviceUITests/"
            "test_realMediaServicesResetQuarantinesAndRebuildsBothAppleOutputs"
        )
        invocation = "00000000-0000-4000-8000-000000000001"
        health = (
            json.dumps(
                {
                    "ts": "2026-08-31T12:00:00Z",
                    "level": "debug",
                    "module": policy.LOG_MIRROR_HEALTH_MODULE,
                    "message": policy.LOG_MIRROR_HEALTH_MESSAGE,
                }
            )
            + "\n"
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            base = root / policy.test_log_filename("run", identifier, invocation)
            base.write_text(health)
            for child in policy.DECLARED_TEST_CHILD_LOGS[scenario]:
                path = root / policy.test_log_filename(
                    "run", identifier, invocation, child=child
                )
                path.write_text(health)
            catalog = policy.catalog_record([identifier])
            policy.build_error_inventory(
                root,
                "run",
                scenario,
                expected_test_catalog=catalog,
            )

            base.unlink()
            with self.assertRaisesRegex(
                policy.QualificationPolicyError, "exactly one base device log"
            ):
                policy.build_error_inventory(
                    root,
                    "run",
                    scenario,
                    expected_test_catalog=catalog,
                )

    def test_catalog_bound_terminal_family_requires_base_and_exact_children(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = self.catalog_bound_terminal_log_fixture(root)
            inventory = policy.build_error_inventory(
                root,
                "run",
                fixture["scenario"],
                expected_test_catalog=fixture["catalog"],
            )
            policy.validate_expected_error_evidence(
                {
                    "cases": fixture["cases"],
                    "hostErrorInventory": inventory,
                },
                fixture["scenario"],
            )

            fixture["base"].unlink()
            with self.assertRaisesRegex(
                policy.QualificationPolicyError, "exactly one base device log"
            ):
                policy.build_error_inventory(
                    root,
                    "run",
                    fixture["scenario"],
                    expected_test_catalog=fixture["catalog"],
                )

    def test_catalog_bound_terminal_family_rejects_child_set_mutations(self):
        for mutation in ("unknown", "duplicate", "missing"):
            with self.subTest(mutation=mutation):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    fixture = self.catalog_bound_terminal_log_fixture(root)
                    if mutation == "unknown":
                        unknown = root / policy.test_log_filename(
                            "run",
                            fixture["identifier"],
                            fixture["invocation"],
                            child="terminal-outcomes-unknown",
                        )
                        unknown.write_text(
                            json.dumps(fixture["health"], sort_keys=True) + "\n"
                        )
                    elif mutation == "duplicate":
                        original = fixture["children"][
                            sorted(fixture["children"])[0]
                        ]
                        duplicate = root / "duplicate" / original.name
                        duplicate.parent.mkdir()
                        duplicate.write_text(original.read_text())
                    else:
                        fixture["children"][
                            sorted(fixture["children"])[0]
                        ].unlink()

                    with self.assertRaisesRegex(
                        policy.QualificationPolicyError,
                        "child device log set mismatch",
                    ):
                        policy.build_error_inventory(
                            root,
                            "run",
                            fixture["scenario"],
                            expected_test_catalog=fixture["catalog"],
                        )

    def test_direct_v2_inventory_requires_exact_terminal_log_family(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = self.catalog_bound_terminal_log_fixture(root)
            inventory = policy.build_error_inventory(
                root,
                "run",
                fixture["scenario"],
                expected_test_catalog=fixture["catalog"],
            )
            policy.validate_error_inventory(
                inventory,
                expected_test_catalog=fixture["catalog"],
            )

            base_record = next(
                record
                for record in inventory["rawFiles"]
                if record["logRole"] == "base"
            )
            child_record = next(
                record
                for record in inventory["rawFiles"]
                if record["logRole"] == "child"
            )

            missing_base = self.clone(inventory)
            missing_base["rawFiles"].remove(
                next(
                    record
                    for record in missing_base["rawFiles"]
                    if record["logRole"] == "base"
                )
            )

            duplicate_base = self.clone(inventory)
            extra_base = self.clone(base_record)
            extra_base["path"] = f"duplicate/{extra_base['path']}"
            duplicate_base["rawFiles"].append(extra_base)

            unknown_child = self.clone(inventory)
            next(
                record
                for record in unknown_child["rawFiles"]
                if record["logRole"] == "child"
            )["childName"] = "terminal-outcomes-unknown"

            duplicate_child = self.clone(inventory)
            extra_child = self.clone(child_record)
            extra_child["path"] = f"duplicate/{extra_child['path']}"
            duplicate_child["rawFiles"].append(extra_child)

            missing_child = self.clone(inventory)
            missing_child["rawFiles"].remove(
                next(
                    record
                    for record in missing_child["rawFiles"]
                    if record["logRole"] == "child"
                )
            )

            split_invocation = self.clone(inventory)
            next(
                record
                for record in split_invocation["rawFiles"]
                if record["logRole"] == "child"
            )["invocationID"] = "00000000-0000-4000-8000-000000000002"

            mutations = {
                "missing base": (missing_base, "exactly one base log"),
                "duplicate base": (duplicate_base, "exactly one base log"),
                "unknown child": (unknown_child, "child log set mismatch"),
                "duplicate child": (duplicate_child, "child log set mismatch"),
                "missing child": (missing_child, "child log set mismatch"),
                "split invocation": (split_invocation, "exactly one invocation"),
            }
            for name, (mutated, error) in mutations.items():
                with self.subTest(name=name):
                    mutated["inventoryDigest"] = policy._inventory_digest(mutated)
                    with self.assertRaisesRegex(
                        policy.QualificationPolicyError,
                        error,
                    ):
                        policy.validate_error_inventory(
                            mutated,
                            expected_test_catalog=fixture["catalog"],
                        )

    def test_catalog_bound_terminal_base_errors_remain_enforced(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = self.catalog_bound_terminal_log_fixture(root)
            base_error = {
                "level": "error",
                "module": "http stream",
                "message": "HTTP access connection closed",
            }
            with fixture["base"].open("a", encoding="utf-8") as output:
                output.write(json.dumps(base_error, sort_keys=True) + "\n")

            inventory = policy.build_error_inventory(
                root,
                "run",
                fixture["scenario"],
                expected_test_catalog=fixture["catalog"],
            )
            base_errors = [
                record
                for record in inventory["errors"]
                if record["sourceFile"] == fixture["base"].name
            ]
            self.assertEqual(len(base_errors), 1)
            self.assertEqual(base_errors[0]["phase"], "unattributed")
            policy.validate_error_inventory(
                inventory,
                expected_test_catalog=fixture["catalog"],
            )
            with self.assertRaisesRegex(
                policy.QualificationPolicyError,
                "raw/evidence error inventory mismatch",
            ):
                policy.validate_expected_error_evidence(
                    {
                        "cases": fixture["cases"],
                        "hostErrorInventory": inventory,
                    },
                    fixture["scenario"],
                )

    def test_seek_frame_oracle_semantics_are_bound_to_absolute_fixture_contract(self):
        scenario = {
            "id": "seek-frame-oracles",
            "oracleContract": policy.SEEK_FRAME_ORACLE_CONTRACT,
        }
        policy.validate_seek_frame_oracle_evidence(self.seek_frame_evidence(), scenario)

        mutations = {}
        outside_tolerance = self.seek_frame_evidence()
        outside_tolerance["seekOracle"]["preciseTimelineSeconds"] = 24.251
        mutations["seek outside immutable tolerance"] = outside_tolerance

        self_consistent_shift = self.seek_frame_evidence()
        self_consistent_shift["frameOracle"].update(
            {
                "baselineIndex": 50,
                "singleIndex": 51,
                "burstBaselineIndex": 51,
                "burstFinalIndex": 71,
                "resumeBaselineIndex": 71,
                "resumeFinalIndex": 80,
            }
        )
        mutations["self-consistent forged frame sequence"] = self_consistent_shift

        wrong_single = self.seek_frame_evidence()
        wrong_single["frameOracle"]["singleIndex"] = 12
        mutations["single advances two"] = wrong_single

        wrong_burst = self.seek_frame_evidence()
        wrong_burst["frameOracle"]["burstFinalIndex"] = 30
        mutations["burst advances nineteen"] = wrong_burst

        wrong_eof = self.seek_frame_evidence()
        wrong_eof["frameOracle"]["eofIndex"] = 118
        mutations["not final EOF frame"] = wrong_eof

        wrong_replacement = self.seek_frame_evidence()
        wrong_replacement["frameTerminals"]["replacement"][-1] = "submitted"
        mutations["replacement retains request"] = wrong_replacement

        contradictory_seek_clock = self.seek_frame_evidence()
        contradictory_seek_clock["seekClock"]["preciseMilliseconds"] = 26000
        mutations["seek clock contradicts pixels"] = contradictory_seek_clock

        contradictory_single_time = self.seek_frame_evidence()
        contradictory_single_time["frameOracle"][
            "singleSubmittedTimeMilliseconds"
        ] = 1200
        mutations["single timestamp contradicts frame"] = contradictory_single_time

        contradictory_baseline_clock = self.seek_frame_evidence()
        contradictory_baseline_clock["frameOracle"]["baselineClockMilliseconds"] = 1500
        mutations["baseline clock contradicts frame"] = contradictory_baseline_clock

        contradictory_resume_clock = self.seek_frame_evidence()
        contradictory_resume_clock["frameOracle"]["resumeClockMilliseconds"] = 5000
        mutations["resume clock contradicts frame"] = contradictory_resume_clock

        contradictory_burst_times = self.seek_frame_evidence()
        contradictory_burst_times["frameOracle"]["burstSubmittedTimesMilliseconds"][
            7
        ] = 9999
        mutations["burst timestamp contradicts frame sequence"] = (
            contradictory_burst_times
        )

        contradictory_eof_time = self.seek_frame_evidence()
        contradictory_eof_time["frameOracle"]["eofSubmittedTimesMilliseconds"][
            -1
        ] = 11800
        mutations["EOF timestamp contradicts terminal frame"] = contradictory_eof_time

        skipped_eof_time = self.seek_frame_evidence()
        skipped_eof_time["frameOracle"]["eofSubmittedTimesMilliseconds"] = [
            11600,
            11800,
            11900,
        ]
        skipped_eof_time["frameTerminals"]["eof"] = ["submitted"] * 3 + ["noFrame"]
        mutations["EOF skips an intermediate submitted frame"] = skipped_eof_time

        library_error = self.seek_frame_evidence()
        library_error["libraryErrorCount"] = 1
        mutations["library error"] = library_error

        weakened_matrix = self.seek_frame_evidence()
        mutations["weakened matrix contract"] = weakened_matrix

        for name, evidence in mutations.items():
            mutated_scenario = scenario
            if name == "weakened matrix contract":
                mutated_scenario = {
                    "id": "seek-frame-oracles",
                    "oracleContract": {
                        **policy.SEEK_FRAME_ORACLE_CONTRACT,
                        "seekToleranceSeconds": 30,
                    },
                }
            with self.subTest(name=name):
                with self.assertRaises(policy.QualificationPolicyError):
                    policy.validate_seek_frame_oracle_evidence(
                        evidence, mutated_scenario
                    )

    def test_expected_error_lane_rejects_unrelated_diagnostic(self):
        actions = {
            "clean-eof": ("naturalEnd", None, None, None),
            "explicit-stop": ("requestedStop", None, None, None),
            "replacement": ("replacement", None, None, None),
            "server-close": (
                "failure:source",
                "source",
                "http stream",
                "HTTP access connection closed",
            ),
            "malformed": (
                "failure:demux",
                "demux",
                "mp4 demux",
                "demux invalid format",
            ),
            "decode-failure": (
                "failure:decoder",
                "decoder",
                "avcodec decoder",
                "decoder codec failed",
            ),
            "renderer-failure": (
                "failure:renderer",
                "renderer",
                "main video output",
                "renderer failed",
            ),
            "output-failure": (
                "failure:output",
                "output",
                "main audio output",
                "video output failed",
            ),
            "network-loss": (
                "failure:source",
                "source",
                "http stream",
                "network source lost",
            ),
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for action, (_, _, module, message) in actions.items():
                record = {
                    "level": "debug" if message is None else "error",
                    "module": module,
                    "message": message or "launch",
                }
                (root / f"run-terminal-outcomes-{action}.jsonl").write_text(
                    json.dumps(record) + "\n"
                )
            evidence = {
                "cases": {
                    action: {
                        "action": action,
                        "outcome": {
                            "cause": cause,
                            "failureClassification": classification,
                        },
                        "libraryErrors": (
                            []
                            if message is None
                            else [{"module": module, "message": message}]
                        ),
                    }
                    for action, (
                        cause,
                        classification,
                        module,
                        message,
                    ) in actions.items()
                },
                "hostErrorInventory": policy.build_error_inventory(
                    root, "run", "terminal-outcomes"
                ),
            }
            policy.validate_expected_error_evidence(evidence, "terminal-outcomes")

            fatal_allowed_message = (
                "fatal renderer memory corruption while input clock remains active"
            )
            evidence["cases"]["server-close"]["libraryErrors"] = [
                {"module": "http stream", "message": fatal_allowed_message}
            ]
            (root / "run-terminal-outcomes-server-close.jsonl").write_text(
                json.dumps(
                    {
                        "level": "error",
                        "module": "http stream",
                        "message": fatal_allowed_message,
                    }
                )
                + "\n"
            )
            with self.assertRaises(policy.QualificationPolicyError):
                policy.build_error_inventory(root, "run", "terminal-outcomes")
            with self.assertRaises(policy.QualificationPolicyError):
                policy.validate_expected_error_evidence(evidence, "terminal-outcomes")

            message = (
                "fatal renderer memory corruption while input clock remains active"
            )
            evidence["cases"]["server-close"]["libraryErrors"] = [
                {"module": "unrelated-renderer", "message": message}
            ]
            (root / "run-terminal-outcomes-server-close.jsonl").write_text(
                json.dumps(
                    {
                        "level": "error",
                        "module": "unrelated-renderer",
                        "message": message,
                    }
                )
                + "\n"
            )
            with self.assertRaises(policy.QualificationPolicyError):
                policy.build_error_inventory(root, "run", "terminal-outcomes")
            with self.assertRaises(policy.QualificationPolicyError):
                policy.validate_expected_error_evidence(evidence, "terminal-outcomes")
            evidence_path = root / "terminal-evidence.json"
            evidence_path.write_text(json.dumps(evidence))
            cli = subprocess.run(
                [
                    sys.executable,
                    str(QUALIFICATION / "qualification_policy.py"),
                    "validate-error-evidence",
                    "--evidence",
                    str(evidence_path),
                    "--scenario",
                    "terminal-outcomes",
                ],
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(cli.returncode, 0)

    def test_adaptive_error_inventory_rejects_exact_unrelated_decoder_payload(self):
        message = "fatal decoder heap corruption observed after HLS phase"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "run-adaptive.jsonl").write_text(
                json.dumps(
                    {
                        "level": "error",
                        "module": "unrelated-decoder",
                        "message": message,
                    }
                )
                + "\n"
            )
            with self.assertRaises(policy.QualificationPolicyError):
                policy.build_error_inventory(root, "run", "adaptive-hls-soak")
            (root / "run-adaptive.jsonl").write_text(
                json.dumps(
                    {
                        "level": "error",
                        "module": "http stream",
                        "message": "HTTP retry was attributed and recovered",
                    }
                )
                + "\n"
            )
            benign_inventory = policy.build_error_inventory(
                root, "run", "adaptive-hls-soak"
            )
            policy.validate_expected_error_evidence(
                {
                    "libraryErrorCount": 1,
                    "libraryErrors": [
                        {
                            "module": "http stream",
                            "message": "HTTP retry was attributed and recovered",
                        }
                    ],
                    "hostErrorInventory": benign_inventory,
                },
                "adaptive-hls-soak",
            )
            (root / "run-adaptive.jsonl").write_text(
                json.dumps(
                    {
                        "level": "error",
                        "module": "unrelated-decoder",
                        "message": message,
                    }
                )
                + "\n"
            )
            evidence = {
                "libraryErrorCount": 1,
                "libraryErrors": [{"module": "unrelated-decoder", "message": message}],
                "hostErrorInventory": benign_inventory,
            }
            with self.assertRaises(policy.QualificationPolicyError):
                policy.validate_expected_error_evidence(evidence, "adaptive-hls-soak")
            evidence_path = root / "adaptive-evidence.json"
            evidence_path.write_text(json.dumps(evidence))
            cli = subprocess.run(
                [
                    sys.executable,
                    str(QUALIFICATION / "qualification_policy.py"),
                    "validate-error-evidence",
                    "--evidence",
                    str(evidence_path),
                    "--scenario",
                    "adaptive-hls-soak",
                ],
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(cli.returncode, 0)

            allowed_message = "fatal decoder heap corruption observed after HLS retry"
            (root / "run-adaptive.jsonl").write_text(
                json.dumps(
                    {
                        "level": "error",
                        "module": "http stream",
                        "message": allowed_message,
                    }
                )
                + "\n"
            )
            with self.assertRaises(policy.QualificationPolicyError):
                policy.build_error_inventory(root, "run", "adaptive-hls-soak")

    def test_retained_raw_inventory_rejects_swap_extra_delete_and_rename(self):
        actions = {
            "clean-eof": ("naturalEnd", None, None, None),
            "explicit-stop": ("requestedStop", None, None, None),
            "replacement": ("replacement", None, None, None),
            "server-close": (
                "failure:source",
                "source",
                "http stream",
                "HTTP access connection closed",
            ),
            "malformed": (
                "failure:demux",
                "demux",
                "mp4 demux",
                "demux invalid format",
            ),
            "decode-failure": (
                "failure:decoder",
                "decoder",
                "avcodec decoder",
                "decoder codec failed",
            ),
            "renderer-failure": (
                "failure:renderer",
                "renderer",
                "main video output",
                "renderer failed",
            ),
            "output-failure": (
                "failure:output",
                "output",
                "main audio output",
                "video output failed",
            ),
            "network-loss": (
                "failure:source",
                "source",
                "http stream",
                "network source lost",
            ),
        }
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            raw = base / "retained-raw"
            raw.mkdir()
            originals = {}
            for action, (_, _, module, message) in actions.items():
                record = {
                    "level": "debug" if message is None else "error",
                    "module": module,
                    "message": message or "launch",
                }
                path = raw / f"run-terminal-outcomes-{action}.jsonl"
                originals[action] = json.dumps(record) + "\n"
                path.write_text(originals[action])
            evidence = {
                "cases": {
                    action: {
                        "action": action,
                        "outcome": {
                            "cause": cause,
                            "failureClassification": classification,
                        },
                        "libraryErrors": (
                            []
                            if message is None
                            else [{"module": module, "message": message}]
                        ),
                    }
                    for action, (
                        cause,
                        classification,
                        module,
                        message,
                    ) in actions.items()
                },
                "hostErrorInventory": policy.build_error_inventory(
                    raw,
                    "run",
                    "terminal-outcomes",
                    retained_root=raw.name,
                ),
            }
            policy.validate_expected_error_evidence(
                evidence,
                "terminal-outcomes",
                retained_base=base,
                require_retained=True,
            )

            server_close = raw / "run-terminal-outcomes-server-close.jsonl"
            server_close.write_text(
                json.dumps(
                    {
                        "level": "error",
                        "module": "unrelated-renderer",
                        "message": "fatal renderer memory corruption while input clock remains active",
                    }
                )
                + "\n"
            )
            with self.assertRaises(policy.QualificationPolicyError):
                policy.validate_expected_error_evidence(
                    evidence,
                    "terminal-outcomes",
                    retained_base=base,
                    require_retained=True,
                )
            server_close.write_text(originals["server-close"])

            extra = raw / "run-terminal-outcomes-extra.jsonl"
            extra.write_text('{"level":"debug","message":"extra"}\n')
            with self.assertRaises(policy.QualificationPolicyError):
                policy.validate_expected_error_evidence(
                    evidence,
                    "terminal-outcomes",
                    retained_base=base,
                    require_retained=True,
                )
            extra.unlink()

            unprefixed_extra = raw / "uninventoryed.jsonl"
            unprefixed_extra.write_text('{"level":"debug","message":"uninventoryed"}\n')
            with self.assertRaises(policy.QualificationPolicyError):
                policy.validate_expected_error_evidence(
                    evidence,
                    "terminal-outcomes",
                    retained_base=base,
                    require_retained=True,
                )
            unprefixed_extra.unlink()

            malformed = raw / "run-terminal-outcomes-malformed.jsonl"
            malformed.unlink()
            with self.assertRaises(policy.QualificationPolicyError):
                policy.validate_expected_error_evidence(
                    evidence,
                    "terminal-outcomes",
                    retained_base=base,
                    require_retained=True,
                )
            malformed.write_text(originals["malformed"])

            renamed = raw / "run-terminal-outcomes-malformed-renamed.jsonl"
            malformed.rename(renamed)
            with self.assertRaises(policy.QualificationPolicyError):
                policy.validate_expected_error_evidence(
                    evidence,
                    "terminal-outcomes",
                    retained_base=base,
                    require_retained=True,
                )

    def test_attachment_export_path_cannot_escape_or_follow_symlink_outside(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            outside = root.parent / f"{root.name}-outside.json"
            outside.write_text("{}")
            try:
                (root / "escape.json").symlink_to(outside)
                manifest = [
                    {
                        "testIdentifier": "iOSUITests/FixtureTests/test_attachment",
                        "attachments": [
                            {
                                "suggestedHumanReadableName": (
                                    "qualification-fixture.json"
                                ),
                                "exportedFileName": "escape.json",
                            }
                        ],
                    }
                ]
                (root / "manifest.json").write_text(json.dumps(manifest))
                with self.assertRaises(materialize.EvidenceError):
                    materialize.find_attachment(
                        root,
                        "qualification-fixture.json",
                        ["iOSUITests/FixtureTests/test_attachment"],
                    )
            finally:
                outside.unlink(missing_ok=True)

    def test_attachment_export_binds_each_payload_to_its_xctest_owner(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            owners = {
                "qualification-first.json": ["iOSUITests/FirstTests/test_first"],
                "qualification-second.json": ["iOSUITests/SecondTests/test_second"],
            }
            manifest = []
            for index, (name, authorized) in enumerate(owners.items()):
                payload = root / f"payload-{index}.json"
                payload.write_text(json.dumps({"scenario": name}))
                canonical = authorized[0]
                short = "/".join(canonical.split("/")[-2:]) + "()"
                manifest.append(
                    {
                        "testIdentifier": short,
                        "testIdentifierURL": (
                            "test://com.apple.xcode/SwiftVLCShowcase/" + canonical
                        ),
                        "attachments": [
                            {
                                "suggestedHumanReadableName": name,
                                "exportedFileName": payload.name,
                            }
                        ],
                    }
                )
            manifest_path = root / "manifest.json"
            manifest_path.write_text(json.dumps(manifest))

            exported = policy.exported_qualification_attachments(root, owners)
            self.assertEqual(
                {name: value[2] for name, value in exported.items()},
                {name: value[0] for name, value in owners.items()},
            )

            mutations = {
                "missing owner": lambda value: (
                    value[0].pop("testIdentifier"),
                    value[0].pop("testIdentifierURL"),
                ),
                "wrong owner": lambda value: value[0].update(
                    {
                        "testIdentifier": "OtherTests/test_other()",
                        "testIdentifierURL": (
                            "test://com.apple.xcode/SwiftVLCShowcase/"
                            "iOSUITests/OtherTests/test_other"
                        ),
                    }
                ),
                "cross-output owner": lambda value: (
                    value[0].update(
                        {
                            "testIdentifier": "SecondTests/test_second()",
                            "testIdentifierURL": (
                                "test://com.apple.xcode/SwiftVLCShowcase/"
                                "iOSUITests/SecondTests/test_second"
                            ),
                        }
                    ),
                    value[1].update(
                        {
                            "testIdentifier": "FirstTests/test_first()",
                            "testIdentifierURL": (
                                "test://com.apple.xcode/SwiftVLCShowcase/"
                                "iOSUITests/FirstTests/test_first"
                            ),
                        }
                    ),
                ),
            }
            for label, mutate in mutations.items():
                with self.subTest(label=label):
                    candidate = json.loads(json.dumps(manifest))
                    mutate(candidate)
                    manifest_path.write_text(json.dumps(candidate))
                    with self.assertRaises(policy.QualificationPolicyError):
                        policy.exported_qualification_attachments(root, owners)
            manifest_path.write_text(json.dumps(manifest))

            conflicting = json.loads(json.dumps(manifest))
            conflicting[0]["testIdentifier"] = "SecondTests/test_second()"
            manifest_path.write_text(json.dumps(conflicting))
            with self.assertRaisesRegex(
                policy.QualificationPolicyError, "owner fields disagree"
            ):
                policy.exported_qualification_attachments(root, owners)

    def test_4k_claim_backed_by_640x360_at_10fps_is_rejected(self):
        fake_probe = {
            "streams": [
                {
                    "codec_type": "video",
                    "codec_name": "h264",
                    "width": 640,
                    "height": 360,
                    "avg_frame_rate": "10/1",
                    "pix_fmt": "yuv420p",
                },
                {"codec_type": "audio", "codec_name": "aac"},
            ],
            "format": {"format_name": "mov,mp4", "duration": "6.0"},
        }
        original_probe = verify_fixtures._probe_media
        original_decode = verify_fixtures._decode_fixture
        verify_fixtures._probe_media = lambda _: fake_probe
        verify_fixtures._decode_fixture = lambda *_args, **_kwargs: None
        try:
            with self.assertRaises(verify_fixtures.FixtureVerificationError):
                verify_fixtures._validate_av_contract(
                    Path("/fixture"),
                    "performance/4k60.mp4",
                    width=3840,
                    height=2160,
                    fps=60,
                    duration=6,
                    container="mov",
                )
        finally:
            verify_fixtures._probe_media = original_probe
            verify_fixtures._decode_fixture = original_decode

    def test_cfr_contract_rejects_periodic_loop_boundary_gap(self):
        intervals = [round(1 / 24, 6)] * 95 + [0.062989]
        with self.assertRaises(verify_fixtures.FixtureVerificationError):
            verify_fixtures._validate_cfr_intervals("cadence/24.mp4", 24, intervals)

        verify_fixtures._validate_cfr_intervals(
            "cadence/24.mp4", 24, [0.041666, 0.041667] * 100
        )
        verify_fixtures._validate_vfr_intervals(
            [0.016666, 0.016667] * 100 + [0.041666, 0.041667] * 40
        )

    def test_vfr_contract_locks_absolute_origin_and_ordered_repeated_phases(self):
        timestamps = []
        for cycle in range(3):
            origin = cycle * 4.0
            timestamps += [origin + frame / 24 for frame in range(48)]
            timestamps += [origin + 2.0 + frame / 60 for frame in range(120)]
        timestamps.append(12.0)
        verify_fixtures._validate_vfr_timeline(timestamps)

        shifted = [timestamp + 0.25 for timestamp in timestamps]
        with self.assertRaisesRegex(
            verify_fixtures.FixtureVerificationError,
            "absolute presentation timestamp zero",
        ):
            verify_fixtures._validate_vfr_timeline(shifted)

        wrong_order = []
        for cycle in range(3):
            origin = cycle * 4.0
            wrong_order += [origin + frame / 60 for frame in range(120)]
            wrong_order += [origin + 2.0 + frame / 24 for frame in range(48)]
        wrong_order.append(12.0)
        with self.assertRaisesRegex(
            verify_fixtures.FixtureVerificationError,
            "2s@24 then 2s@60",
        ):
            verify_fixtures._validate_vfr_timeline(wrong_order)

    def test_repository_fixture_cache_satisfies_all_hardcoded_media_contracts(self):
        root = QUALIFICATION.parents[1] / ".qualification-fixtures"
        if not root.is_dir():
            self.skipTest("generated fixture cache is not present")
        manifest = verify_fixtures.verify(root)
        verify_fixtures.verify_release_oracles(manifest)
        verify_fixtures.verify_release_fixture_metadata(manifest)
        verify_fixtures.verify_release_oracle_media(root)
        observations = verify_fixtures.verify_release_fixture_media(root)
        self.assertIn("performance/4k60", observations)
        self.assertIn("hls", observations)


if __name__ == "__main__":
    unittest.main()
