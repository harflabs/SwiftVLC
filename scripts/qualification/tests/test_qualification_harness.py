from __future__ import annotations

import contextlib
import http.client
import hashlib
import importlib.util
import io
import json
import plistlib
import tempfile
import threading
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def load_script(name: str):
    path = ROOT / "qualification" / name
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


device_info = load_script("device-info.py")
fixture_server = load_script("fixture-server.py")
prepare_xctestrun = load_script("prepare-xctestrun.py")
verify_fixtures = load_script("verify-fixtures.py")
candidate_metadata = load_script("candidate-metadata.py")
materialize_evidence = load_script("materialize-evidence.py")
augment_allocation_trace = load_script("augment-allocation-trace.py")
augment_performance_traces = load_script("augment-performance-traces.py")
assemble_record = load_script("assemble-record.py")


class DeviceInfoTests(unittest.TestCase):
    def test_release_classification_is_fail_closed(self):
        self.assertEqual(device_info.release_type({"releaseType": "Beta"}), "beta")
        self.assertEqual(device_info.release_type({"osBuildUpdate": "24A5390f"}), "beta")
        self.assertEqual(device_info.release_type({"osBuildUpdate": "20E772520a"}), "stable")
        self.assertEqual(device_info.release_type({"osBuildUpdate": "23G80"}), "stable")
        self.assertEqual(device_info.release_type({"osBuildUpdate": "unexpected"}), "unknown")

    def test_only_connected_stable_matching_device_qualifies(self):
        device = {
            "identifier": "core-id",
            "connectionProperties": {"tunnelState": "connected", "transportType": "wired"},
            "deviceProperties": {
                "name": "Fixture iPhone",
                "ddiServicesAvailable": True,
                "developerModeStatus": "enabled",
                "osVersionNumber": "26.6",
                "osBuildUpdate": "23G80",
            },
            "hardwareProperties": {
                "reality": "physical",
                "platform": "iOS",
                "deviceType": "iPhone",
                "ecid": 42,
                "udid": "fixture-udid",
                "productType": "iPhone99,1",
            },
        }
        normalized = device_info.normalize(
            device, [{"id": "iphone-current", "deviceFamily": "iPhone", "osMajor": 26}]
        )
        self.assertTrue(normalized["connected"])
        self.assertTrue(normalized["qualificationEligible"])
        self.assertEqual(normalized["matchingHardwareRows"], ["iphone-current"])


class XCTestrunTests(unittest.TestCase):
    @staticmethod
    def ui_test_plan():
        return {
            "TestConfigurations": [
                {
                    "TestTargets": [
                        {
                            "IsUITestBundle": True,
                            "TestBundlePath": "/tmp/test.xctest",
                            "TestHostPath": "/tmp/Runner.app",
                            "UITargetAppPath": "/tmp/iOS.app",
                            "DependentProductPaths": ["/tmp/iOS.app"],
                        }
                    ]
                }
            ]
        }

    def test_destination_artifact_transform_removes_local_paths(self):
        original = self.ui_test_plan()
        transformed = prepare_xctestrun.transform(original, {"ATTACH": "YES"})
        target = transformed["TestConfigurations"][0]["TestTargets"][0]
        for key in prepare_xctestrun.REMOVED_PATH_KEYS:
            self.assertNotIn(key, target)
        self.assertTrue(target["UseDestinationArtifacts"])
        self.assertEqual(target["TestingEnvironmentVariables"]["ATTACH"], "YES")

    def test_build_product_transform_preserves_paths_and_injects_environment(self):
        original = self.ui_test_plan()
        transformed = prepare_xctestrun.transform(
            original,
            {"FIXTURE": "http://127.0.0.1/media.mp4"},
            use_destination_artifacts=False,
        )
        target = transformed["TestConfigurations"][0]["TestTargets"][0]
        self.assertEqual(target["TestBundlePath"], "/tmp/test.xctest")
        self.assertEqual(target["TestHostPath"], "/tmp/Runner.app")
        self.assertNotIn("UseDestinationArtifacts", target)
        self.assertEqual(
            target["TestingEnvironmentVariables"]["FIXTURE"],
            "http://127.0.0.1/media.mp4",
        )


class CandidateMetadataTests(unittest.TestCase):
    def test_metadata_is_bound_to_the_exact_candidate_digest(self):
        app_digest = "a" * 64
        metadata = {
            "formatVersion": 1,
            "version": "1.1.0",
            "sourceCommit": "b" * 40,
            "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
            "releaseSourceDigest": "c" * 64,
            "candidateAppDigestAlgorithm": "swiftvlc-tree-v1",
            "candidateAppDigest": app_digest,
            "artifactDigestAlgorithm": "swiftvlc-tree-v1",
            "artifactDigest": "d" * 64,
        }
        self.assertEqual(
            candidate_metadata.validate(metadata, "1.1.0", app_digest, "d" * 64),
            metadata,
        )
        with self.assertRaises(candidate_metadata.CandidateMetadataError):
            candidate_metadata.validate(metadata, "1.1.0", "e" * 64, "d" * 64)

    def test_metadata_reads_source_identity_from_the_signed_app_payload(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "iOS.app"
            app.mkdir()
            xcframework = root / "libvlc.xcframework"
            xcframework.mkdir()
            with (app / "Info.plist").open("wb") as output:
                plistlib.dump(
                    {
                        "SwiftVLCSourceCommit": "b" * 40,
                        "SwiftVLCReleaseSourceDigest": "c" * 64,
                        "SwiftVLCArtifactDigest": "a" * 64,
                    },
                    output,
                )
            digest_script = root / "digest.py"
            digest_script.write_text(f'print("{"a" * 64}")\n')

            metadata = candidate_metadata.create(
                app, xcframework, "1.1.0", digest_script
            )
            self.assertEqual(metadata["sourceCommit"], "b" * 40)
            self.assertEqual(metadata["releaseSourceDigest"], "c" * 64)
            self.assertEqual(metadata["candidateAppDigest"], "a" * 64)
            self.assertEqual(metadata["artifactDigest"], "a" * 64)

            forged = dict(metadata, sourceCommit="d" * 40)
            with self.assertRaises(candidate_metadata.CandidateMetadataError):
                candidate_metadata.verify(
                    forged, app, xcframework, "1.1.0", digest_script
                )


class FixtureManifestTests(unittest.TestCase):
    def test_cached_fixture_bytes_must_match_the_manifest_exactly(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sample = root / "sample.bin"
            sample.write_bytes(b"candidate-bound fixture")
            manifest = {
                "formatVersion": 1,
                "files": {
                    "sample.bin": {
                        "bytes": sample.stat().st_size,
                        "sha256": hashlib.sha256(sample.read_bytes()).hexdigest(),
                    }
                },
            }
            (root / "manifest.json").write_text(json.dumps(manifest))
            self.assertEqual(verify_fixtures.verify(root), manifest)

            sample.write_bytes(b"corrupted")
            with self.assertRaises(verify_fixtures.FixtureVerificationError):
                verify_fixtures.verify(root)


class QualificationEvidenceTests(unittest.TestCase):
    def make_export(
        self,
        root: Path,
        payload: dict,
        attachment_count: int = 1,
        attachment_name: str = "qualification-native-hls-seek-continuity.json",
        test_identifier: str = "PiPOverlayDeviceUITests/test_nativePiPHLSSeekAndReloadRemainActive",
    ):
        exported = root / "attachment.json"
        exported.write_text(json.dumps(payload))
        attachment = {
            "exportedFileName": exported.name,
            "suggestedHumanReadableName": attachment_name,
        }
        manifest = [
            {
                "testIdentifier": test_identifier,
                "attachments": [attachment] * attachment_count,
            }
        ]
        (root / "manifest.json").write_text(json.dumps(manifest))

    def test_materializes_test_payload_with_host_owned_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "native-hls-seek-continuity",
                    "seekResults": {"forward": "pass"},
                },
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-native-hls-seek-continuity.json",
                "native-hls-seek-continuity",
                "iphone-current",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["artifactDigest"], "a" * 64)
            self.assertEqual(evidence["releaseSourceDigest"], "b" * 64)
            self.assertEqual(evidence["hardware"], "iphone-current")
            self.assertEqual(evidence["seekResults"]["forward"], "pass")

    def test_materializes_combined_live_media_backend_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "live-media",
                    "events": {
                        "started": True,
                        "unexpectedStopCount": 0,
                        "order": "pass",
                    },
                    "playbackRange": "unbounded",
                    "linearPlayback": True,
                    "backendResults": {"native": "pass", "direct": "pass"},
                },
                attachment_name="qualification-live-media.json",
                test_identifier="PiPLiveDeviceUITests/test_liveMediaQualificationAcrossNativeAndDirectBackends",
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-live-media.json",
                "live-media",
                "ipad-current",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["scenario"], "live-media")
            self.assertEqual(evidence["hardware"], "ipad-current")
            self.assertEqual(
                evidence["backendResults"], {"native": "pass", "direct": "pass"}
            )

    def test_materializes_background_audio_counter_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "background-audio",
                    "events": {
                        "started": True,
                        "unexpectedStopCount": 0,
                        "order": "pass",
                    },
                    "audioContinuity": "pass",
                    "backgroundApplicationState": True,
                    "measurementMethod": "libvlc-played-audio-buffers",
                    "measurements": {
                        "playedAudioBuffersBeforeBackground": 100,
                        "playedAudioBuffersAfterBackground": 180,
                    },
                },
                attachment_name="qualification-background-audio.json",
                test_identifier="PiPLiveDeviceUITests/test_backgroundAudioQualificationWhileAppIsBackgrounded",
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-background-audio.json",
                "background-audio",
                "iphone-minimum",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["scenario"], "background-audio")
            self.assertEqual(evidence["hardware"], "iphone-minimum")
            self.assertTrue(evidence["backgroundApplicationState"])
            self.assertEqual(
                evidence["measurementMethod"], "libvlc-played-audio-buffers"
            )
            self.assertGreater(
                evidence["measurements"]["playedAudioBuffersAfterBackground"],
                evidence["measurements"]["playedAudioBuffersBeforeBackground"],
            )

    def test_materializes_replacement_continuity_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "replacement-continuity",
                    "combinations": {
                        "vodToLive": "pass",
                        "liveToVOD": "pass",
                    },
                    "snapshotCoherence": "pass",
                    "measurements": {
                        "audioGapMilliseconds": 325,
                        "videoGapMilliseconds": 210,
                    },
                    "audioContinuityWithinBudget": True,
                    "videoContinuityWithinBudget": True,
                    "controls": "pass",
                    "recoveryOutcome": "preserved",
                    "staleSuccessorMutations": 0,
                },
                attachment_name="qualification-replacement-continuity.json",
                test_identifier="PiPContinuityDeviceUITests/test_nativePiPReplacementContinuityAcrossVODAndLive",
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-replacement-continuity.json",
                "replacement-continuity",
                "iphone-current",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["combinations"]["vodToLive"], "pass")
            self.assertEqual(evidence["combinations"]["liveToVOD"], "pass")
            self.assertEqual(evidence["staleSuccessorMutations"], 0)
            self.assertGreater(evidence["measurements"]["audioGapMilliseconds"], 0)
            self.assertTrue(evidence["audioContinuityWithinBudget"])
            self.assertTrue(evidence["videoContinuityWithinBudget"])

    def test_materializes_capability_convergence_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "capability-convergence",
                    "backendResults": {"native": "pass", "direct": "pass"},
                    "transitions": "pass",
                    "skipControls": "pass",
                    "faultInjection": {"rawEventsSuppressed": True},
                },
                attachment_name="qualification-capability-convergence.json",
                test_identifier="PiPCapabilityDeviceUITests/test_capabilityConvergenceAcrossNativeAndDirectBackends",
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-capability-convergence.json",
                "capability-convergence",
                "iphone-current",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(
                evidence["backendResults"], {"native": "pass", "direct": "pass"}
            )
            self.assertEqual(evidence["transitions"], "pass")
            self.assertEqual(evidence["skipControls"], "pass")
            self.assertTrue(evidence["faultInjection"]["rawEventsSuppressed"])

    def test_materializes_deferred_pause_rejection_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "deferred-pause-rejection",
                    "permanentCase": {
                        "outcome": "rejected",
                        "forcedRejectionCount": 40,
                        "nativePauseCommandCount": 0,
                        "taskStayedSettled": True,
                        "truthfulControls": True,
                    },
                    "transientCase": {
                        "outcome": "issued",
                        "forcedRejectionCount": 3,
                        "nativePauseCommandCount": 1,
                        "taskStayedSettled": True,
                        "truthfulControls": True,
                    },
                    "cancellationCases": "pass",
                    "cancellationResults": {
                        "newerCommand": "cancelled",
                        "replacement": "cancelled",
                        "stop": "cancelled",
                    },
                    "endlessTaskCount": 0,
                    "duplicatePauseCount": 0,
                    "truthfulControls": True,
                },
                attachment_name="qualification-deferred-pause-rejection.json",
                test_identifier="PiPDeferredPauseDeviceUITests/test_deferredPauseRejectionAndCancellationStayTruthful",
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-deferred-pause-rejection.json",
                "deferred-pause-rejection",
                "iphone-current",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["permanentCase"]["outcome"], "rejected")
            self.assertEqual(evidence["transientCase"]["outcome"], "issued")
            self.assertEqual(evidence["cancellationCases"], "pass")
            self.assertEqual(evidence["endlessTaskCount"], 0)
            self.assertEqual(evidence["duplicatePauseCount"], 0)
            self.assertTrue(evidence["truthfulControls"])

    def test_materializes_vod_controls_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "vod-controls",
                    "events": {
                        "started": True,
                        "unexpectedStopCount": 0,
                        "order": "pass",
                    },
                    "controls": {
                        "play": "pass",
                        "pause": "pass",
                        "scrub": "pass",
                        "skipForward": "pass",
                        "skipBackward": "pass",
                    },
                    "backendResults": {"native": {}, "direct": {}},
                    "systemPiPMotion": {"native": "pass", "direct": "pass"},
                },
                attachment_name="qualification-vod-controls.json",
                test_identifier="PiPVODControlsDeviceUITests/test_vodControlsAcrossNativeAndDirectBackends",
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-vod-controls.json",
                "vod-controls",
                "ipad-minimum",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["hardware"], "ipad-minimum")
            self.assertEqual(evidence["events"]["unexpectedStopCount"], 0)
            self.assertEqual(evidence["controls"]["scrub"], "pass")
            self.assertEqual(evidence["systemPiPMotion"]["native"], "pass")

    def test_materializes_long_stall_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "long-stall",
                    "events": {
                        "started": True,
                        "unexpectedStopCount": 0,
                        "order": "pass",
                    },
                    "recoveryOutcome": "recovered",
                    "boundedMemory": True,
                    "backendResults": {
                        "native": {"memory": {"growthBytes": 1024}},
                        "direct": {"memory": {"growthBytes": 2048}},
                    },
                    "systemPiPMotionAfterRecovery": {
                        "native": "pass",
                        "direct": "pass",
                    },
                },
                attachment_name="qualification-long-stall.json",
                test_identifier="PiPLongStallDeviceUITests/test_longStallRecoversAcrossNativeAndDirectBackends",
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-long-stall.json",
                "long-stall",
                "iphone-minimum",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["hardware"], "iphone-minimum")
            self.assertEqual(evidence["recoveryOutcome"], "recovered")
            self.assertTrue(evidence["boundedMemory"])
            self.assertEqual(evidence["backendResults"]["direct"]["memory"]["growthBytes"], 2048)

    def test_materializes_restore_and_close_evidence(self):
        for scenario, restore_count, reason in (
            ("restore", 1, "restoreRequested"),
            ("close", 0, "userClosed"),
        ):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self.make_export(
                    root,
                    {
                        "formatVersion": 1,
                        "scenario": scenario,
                        "events": {
                            "didStartCount": 1,
                            "willStopReason": reason,
                            "didStopReason": reason,
                            "order": "pass",
                        },
                        "backends": {
                            "native": {
                                "reason": reason,
                                "restoreCallbackCount": restore_count,
                                "systemPiPMotion": "pass",
                            },
                            "direct": {
                                "reason": reason,
                                "restoreCallbackCount": restore_count,
                                "systemPiPMotion": "pass",
                            },
                        },
                        **(
                            {"restoreResult": "pass", "completionCount": 1}
                            if scenario == "restore"
                            else {"stopReason": "userClosed"}
                        ),
                        "aggregationBasis": "per-backend invariant",
                        "systemAffordance": "pass",
                    },
                    attachment_name=f"qualification-{scenario}.json",
                    test_identifier="PiPDismissalDeviceUITests/test_systemRestoreAndCloseAcrossNativeAndDirectBackends",
                )
                evidence = materialize_evidence.materialize(
                    root,
                    f"qualification-{scenario}.json",
                    scenario,
                    "ipad-current",
                    "a" * 64,
                    "b" * 64,
                )
                self.assertEqual(evidence["hardware"], "ipad-current")
                self.assertEqual(evidence["events"]["didStartCount"], 1)
                self.assertEqual(evidence["events"]["willStopReason"], reason)
                self.assertEqual(evidence["events"]["didStopReason"], reason)
                self.assertEqual(evidence["backends"]["native"]["reason"], reason)
                self.assertEqual(evidence["systemAffordance"], "pass")
                if scenario == "restore":
                    self.assertEqual(evidence["restoreResult"], "pass")
                    self.assertEqual(evidence["completionCount"], 1)
                else:
                    self.assertEqual(evidence["stopReason"], "userClosed")

    def test_materializes_interruption_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "interruptions",
                    "events": {
                        "started": True,
                        "unexpectedStopCount": 0,
                        "order": "pass",
                    },
                    "interruptionRecovery": "pass",
                    "routeChangeRecovery": "pass",
                    "interruptionSource": "exclusive-XCTest-runner-audio-session",
                    "routeLossSource": "deterministic-oldDeviceUnavailable-notification",
                    "backends": {
                        "native": {
                            "interruptionBeganCount": 1,
                            "routeLossCount": 1,
                            "audioRecovered": True,
                        },
                        "direct": {
                            "interruptionBeganCount": 1,
                            "routeLossCount": 1,
                            "audioRecovered": True,
                        },
                    },
                    "recoveryOutcome": "preserved",
                    "systemPiPMotionAfterRecovery": "pass",
                },
                attachment_name="qualification-interruptions.json",
                test_identifier="PiPInterruptionDeviceUITests/test_audioInterruptionAndRouteLossAcrossNativeAndDirectBackends",
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-interruptions.json",
                "interruptions",
                "iphone-current",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["hardware"], "iphone-current")
            self.assertEqual(evidence["events"]["unexpectedStopCount"], 0)
            self.assertEqual(evidence["interruptionRecovery"], "pass")
            self.assertEqual(evidence["routeChangeRecovery"], "pass")
            self.assertEqual(evidence["backends"]["direct"]["routeLossCount"], 1)
            self.assertTrue(evidence["backends"]["native"]["audioRecovered"])
            self.assertEqual(evidence["recoveryOutcome"], "preserved")

    def test_materializes_native_lifecycle_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            cases = {
                "restore": {
                    "orderedEvents": [
                        "willStart",
                        "didStart",
                        "willStop:restoreRequested",
                        "didStop:restoreRequested",
                    ],
                    "restoreCallbackCount": 1,
                },
                "close": {
                    "orderedEvents": [
                        "willStart",
                        "didStart",
                        "willStop:userClosed",
                        "didStop:userClosed",
                    ],
                    "restoreCallbackCount": 0,
                },
                "failed-start": {
                    "orderedEvents": ["willStart", "failedToStart"]
                },
                "programmatic": {
                    "orderedEvents": [
                        "willStart",
                        "didStart",
                        "willStop:programmatic",
                        "didStop:programmatic",
                    ]
                },
                "media-end": {
                    "orderedEvents": [
                        "willStart",
                        "didStart",
                        "willStop:mediaEnded",
                        "didStop:mediaEnded",
                    ]
                },
                "failure": {
                    "orderedEvents": [
                        "willStart",
                        "didStart",
                        "willStop:failure",
                        "didStop:failure",
                    ]
                },
                "recast": {
                    "orderedEvents": [
                        "willStart",
                        "didStart",
                        "willStop:controllerReplaced",
                        "didStop:controllerReplaced",
                    ]
                },
                "replacement": {
                    "orderedEvents": [
                        "willStart",
                        "didStart",
                        "willStop:controllerReplaced",
                        "didStop:controllerReplaced",
                    ]
                },
            }
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "native-lifecycle",
                    "bridgeProbe": True,
                    "cases": cases,
                    "orderedEvents": {
                        name: value["orderedEvents"] for name, value in cases.items()
                    },
                    "authoritativeStopReasons": True,
                    "restoreExactlyOnce": True,
                    "unsupportedBridgeVisible": True,
                    "unsupportedBridgeVisibility": "typed-probe-required",
                    "unsupportedRevisionExercised": False,
                    "processIsolation": "one-launch-per-transition",
                },
                attachment_name="qualification-native-lifecycle.json",
                test_identifier="PiPNativeLifecycleDeviceUITests/test_nativeLifecyclePublishesAuthoritativeOrderedEvents",
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-native-lifecycle.json",
                "native-lifecycle",
                "iphone-current",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["hardware"], "iphone-current")
            self.assertTrue(evidence["bridgeProbe"])
            self.assertEqual(len(evidence["cases"]), 8)
            self.assertEqual(evidence["cases"]["restore"]["restoreCallbackCount"], 1)
            self.assertEqual(
                evidence["orderedEvents"]["failed-start"],
                ["willStart", "failedToStart"],
            )
            self.assertTrue(evidence["authoritativeStopReasons"])
            self.assertTrue(evidence["restoreExactlyOnce"])
            self.assertTrue(evidence["unsupportedBridgeVisible"])
            self.assertFalse(evidence["unsupportedRevisionExercised"])

    def test_materializes_terminal_outcome_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            failure_classifications = {
                "source": "source",
                "demux": "demux",
                "decoder": "decoder",
                "renderer": "renderer",
                "output": "output",
            }
            cases = {
                "clean-eof": {"cause": "naturalEnd"},
                "explicit-stop": {"cause": "requestedStop"},
                "replacement": {"cause": "replacement"},
                "server-close": {"cause": "failure:source"},
                "malformed": {"cause": "failure:demux"},
                "decode-failure": {"cause": "failure:decoder"},
                "renderer-failure": {"cause": "failure:renderer"},
                "output-failure": {"cause": "failure:output"},
                "network-loss": {"cause": "failure:source"},
            }
            final_timelines = {
                name: {
                    "timeMilliseconds": index * 100,
                    "durationMilliseconds": 60000,
                    "position": index / 10,
                    "bufferFill": 1,
                    "activeVideoOutputs": 1,
                }
                for index, name in enumerate(cases)
            }
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "terminal-outcomes",
                    "cases": cases,
                    "finalTimelines": final_timelines,
                    "generationIsolation": True,
                    "failureClassifications": failure_classifications,
                    "maximumTerminalOutcomesPerGeneration": 1,
                    "unattributedStopNaturalEndCount": 0,
                    "subscriberPayloadsIdentical": True,
                    "expectedFailureLogsPreserved": True,
                    "processIsolation": "one-launch-per-transition",
                },
                attachment_name="qualification-terminal-outcomes.json",
                test_identifier="TerminalOutcomesDeviceUITests/test_terminalOutcomeMatrixIsGenerationScopedAndPreReset",
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-terminal-outcomes.json",
                "terminal-outcomes",
                "iphone-current",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["hardware"], "iphone-current")
            self.assertEqual(len(evidence["cases"]), 9)
            self.assertEqual(len(evidence["finalTimelines"]), 9)
            self.assertTrue(evidence["generationIsolation"])
            self.assertEqual(evidence["failureClassifications"], failure_classifications)
            self.assertEqual(evidence["maximumTerminalOutcomesPerGeneration"], 1)
            self.assertEqual(evidence["unattributedStopNaturalEndCount"], 0)
            self.assertTrue(evidence["subscriberPayloadsIdentical"])

    def test_materializes_adaptive_hls_soak_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payload = {
                "formatVersion": 1,
                "scenario": "adaptive-hls-soak",
                "durationSeconds": 7200,
                "playlistCoverage": {
                    "playlistTypes": ["event", "live", "vod"],
                    "containers": ["fmp4", "ts"],
                    "variants": ["high", "low"],
                    "variantTransitions": 4,
                    "discontinuityManifests": 3,
                    "expiredWindows": 2,
                    "retryFailures": 1,
                    "retryRecoveries": 1,
                    "cancellations": 7,
                },
                "allocationProvenance": {
                    "allocator": "Darwin default malloc zone",
                    "sourceOwnershipRegression": "SegmentChunkOwnership_test",
                    "expectedSourceReleaseCount": 1,
                },
                "memorySeries": [
                    {"elapsedSeconds": 0, "residentBytes": 100},
                    {"elapsedSeconds": 7200, "residentBytes": 101},
                ],
                "sanitizerFindings": 0,
                "crashes": 0,
                "unboundedRecoveries": 0,
                "monotonicGrowth": False,
                "upstreamCrossLink": "https://code.videolan.org/videolan/vlc/-/work_items/29845",
            }
            self.make_export(
                root,
                payload,
                attachment_name="qualification-adaptive-hls-soak.json",
                test_identifier="AdaptiveHLSSoakDeviceUITests/test_adaptiveHLSMatrixSoakRemainsBounded",
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-adaptive-hls-soak.json",
                "adaptive-hls-soak",
                "iphone-current",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["hardware"], "iphone-current")
            self.assertEqual(evidence["sanitizerFindings"], 0)
            self.assertFalse(evidence["monotonicGrowth"])
            self.assertEqual(
                evidence["allocationProvenance"]["expectedSourceReleaseCount"], 1
            )

    def test_host_binds_allocation_trace_digest_to_adaptive_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = root / "evidence.json"
            evidence.write_text(
                json.dumps(
                    {
                        "scenario": "adaptive-hls-soak",
                        "allocationProvenance": {"allocator": "malloc"},
                    }
                )
            )
            trace = root / "adaptive.trace"
            trace.mkdir()
            (trace / "data.bin").write_bytes(b"candidate allocation stacks")
            toc = root / "toc.xml"
            toc.write_text('<table schema="allocations"/>')
            digest_script = Path(__file__).resolve().parents[2] / "artifact-tree-digest.py"

            augmented = augment_allocation_trace.augment(
                evidence, trace, toc, digest_script
            )
            record = augmented["allocationProvenance"]["instrumentsTrace"]
            self.assertRegex(record["treeDigest"], r"^[0-9a-f]{64}$")
            self.assertEqual(record["template"], "Allocations")
            self.assertEqual(
                record["runArtifact"], "artifacts/evidence/adaptive.trace"
            )
            self.assertTrue((evidence.parent / record["runArtifact"]).is_dir())
            self.assertTrue(
                (evidence.parent / record["tableOfContents"]).is_file()
            )

            toc.write_text("<trace-toc/>")
            with self.assertRaises(augment_allocation_trace.TraceEvidenceError):
                augment_allocation_trace.augment(evidence, trace, toc, digest_script)

    def test_host_binds_all_performance_trace_digests(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = root / "evidence.json"
            evidence.write_text(
                json.dumps(
                    {
                        "scenario": "pip-render-performance-4k60",
                        "metrics": {
                            "gpu": {"status": "required-host-augmentation"},
                            "energy": {"status": "required-host-augmentation"},
                            "conversionCost": {
                                "sourcePixels": 3840 * 2160,
                                "hostTraceStatus": "required-host-augmentation",
                            },
                        },
                        "hostTraceRequirements": {},
                    }
                )
            )
            traces = {}
            for key in ("game", "power", "time"):
                trace = root / f"{key}.trace"
                trace.mkdir()
                (trace / "data.bin").write_bytes(f"{key} instrument data".encode())
                toc = root / f"{key}-toc.xml"
                toc.write_text('<trace-toc><table schema="samples"/></trace-toc>')
                traces[key] = (trace, toc)
            digest_script = Path(__file__).resolve().parents[2] / "artifact-tree-digest.py"

            augmented = augment_performance_traces.augment(
                evidence, traces, digest_script
            )
            self.assertNotIn("hostTraceRequirements", augmented)
            self.assertEqual(augmented["metrics"]["gpu"]["status"], "captured")
            self.assertEqual(augmented["metrics"]["energy"]["template"], "Power Profiler")
            conversion_trace = augmented["metrics"]["conversionCost"]["hostTrace"]
            self.assertEqual(conversion_trace["template"], "Time Profiler")
            self.assertRegex(conversion_trace["treeDigest"], r"^[0-9a-f]{64}$")
            for record in (
                augmented["metrics"]["gpu"],
                augmented["metrics"]["energy"],
                conversion_trace,
            ):
                self.assertTrue((evidence.parent / record["runArtifact"]).is_dir())
                self.assertTrue(
                    (evidence.parent / record["tableOfContents"]).is_file()
                )

            (traces["game"][0] / "data.bin").unlink()
            with self.assertRaises(augment_performance_traces.PerformanceTraceError):
                augment_performance_traces.augment(evidence, traces, digest_script)

    def test_materializes_accepted_start_delayed_failure_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "accepted-start-delayed-failure",
                    "startResult": "accepted",
                    "orderedEvents": ["willStart", "failedToStart"],
                    "controllerGeneration": 3,
                    "mediaGeneration": 7,
                    "expectedControllerGeneration": 3,
                    "expectedMediaGeneration": 7,
                    "orderedAttribution": True,
                    "quiescenceMilliseconds": 3000,
                    "controllerActiveAfterCleanup": False,
                    "failureDomain": "SwiftVLC.Qualification.DelayedPiPStartFailure",
                    "failureCode": 1,
                },
                attachment_name="qualification-accepted-start-delayed-failure.json",
                test_identifier="PiPDelayedStartFailureDeviceUITests/test_acceptedStartRetainsAttributionThroughDelayedFailure",
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-accepted-start-delayed-failure.json",
                "accepted-start-delayed-failure",
                "iphone-current",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["startResult"], "accepted")
            self.assertEqual(evidence["orderedEvents"][-1], "failedToStart")
            self.assertEqual(evidence["controllerGeneration"], 3)
            self.assertEqual(evidence["mediaGeneration"], 7)
            self.assertTrue(evidence["orderedAttribution"])

    def test_materializes_failed_start_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "failed-start",
                    "events": {
                        "failedToStartCount": 1,
                        "didStartCount": 0,
                        "order": "pass",
                    },
                    "failureSurfaced": True,
                    "orderedEvents": ["willStart", "failedToStart"],
                    "failureDomain": "SwiftVLC.Qualification.DelayedPiPStartFailure",
                    "failureCode": 1,
                },
                attachment_name="qualification-failed-start.json",
                test_identifier="PiPDelayedStartFailureDeviceUITests/test_acceptedStartRetainsAttributionThroughDelayedFailure",
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-failed-start.json",
                "failed-start",
                "ipad-current",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["hardware"], "ipad-current")
            self.assertEqual(evidence["events"]["failedToStartCount"], 1)
            self.assertEqual(evidence["events"]["didStartCount"], 0)
            self.assertTrue(evidence["failureSurfaced"])

    def test_materializes_focused_replacement_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "replacement",
                    "events": {
                        "controllerReplacementCount": 1,
                        "unattributedStopCount": 0,
                        "order": "pass",
                    },
                    "controls": "pass",
                    "recoveryOutcome": "preserved",
                },
                attachment_name="qualification-replacement.json",
                test_identifier="PiPContinuityDeviceUITests/test_nativePiPSurvivesSamePlayerReplacement",
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-replacement.json",
                "replacement",
                "iphone-current",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["events"]["controllerReplacementCount"], 1)
            self.assertEqual(evidence["events"]["unattributedStopCount"], 0)
            self.assertEqual(evidence["recoveryOutcome"], "preserved")

    def test_rejects_duplicate_attachments_and_forged_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "scenario": "native-hls-seek-continuity",
                    "artifactDigest": "forged",
                },
                attachment_count=2,
            )
            with self.assertRaises(materialize_evidence.EvidenceError):
                materialize_evidence.materialize(
                    root,
                    "qualification-native-hls-seek-continuity.json",
                    "native-hls-seek-continuity",
                    "iphone-current",
                    "a" * 64,
                    "b" * 64,
                )

            self.make_export(
                root,
                {
                    "scenario": "native-hls-seek-continuity",
                    "artifactDigest": "forged",
                },
            )
            with self.assertRaises(materialize_evidence.EvidenceError):
                materialize_evidence.materialize(
                    root,
                    "qualification-native-hls-seek-continuity.json",
                    "native-hls-seek-continuity",
                    "iphone-current",
                    "a" * 64,
                    "b" * 64,
                )


class QualificationRecordAssemblyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.matrix = self.root / "matrix.json"
        self.matrix.write_text(
            json.dumps(
                {
                    "scenarios": [{"id": "seek"}],
                    "hardware": [
                        {"id": "iphone", "deviceFamily": "iPhone", "osMajor": 26},
                        {"id": "ipad", "deviceFamily": "iPad", "osMajor": 26},
                    ],
                }
            )
        )
        self.matrix_checksum = hashlib.sha256(self.matrix.read_bytes()).hexdigest()
        self.candidate = self.root / "candidate.json"
        self.candidate.write_text(
            json.dumps(
                {
                    "version": "1.1.0",
                    "artifactDigestAlgorithm": "swiftvlc-tree-v1",
                    "artifactDigest": "a" * 64,
                    "sourceCommit": "b" * 40,
                    "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
                    "releaseSourceDigest": "c" * 64,
                }
            )
        )

    def tearDown(self):
        self.temporary.cleanup()

    def make_report(self, hardware: str, release_type: str = "stable") -> Path:
        directory = self.root / f"report-{hardware}"
        evidence_directory = directory / "evidence"
        evidence_directory.mkdir(parents=True)
        evidence = evidence_directory / "seek.json"
        evidence.write_text(
            json.dumps(
                {
                    "artifactDigest": "a" * 64,
                    "releaseSourceDigest": "c" * 64,
                    "scenario": "seek",
                    "hardware": hardware,
                    "outcome": "pass",
                }
            )
        )
        report = directory / "report.json"
        report.write_text(
            json.dumps(
                {
                    "version": "1.1.0",
                    "artifactDigestAlgorithm": "swiftvlc-tree-v1",
                    "artifactDigest": "a" * 64,
                    "sourceCommit": "b" * 40,
                    "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
                    "releaseSourceDigest": "c" * 64,
                    "qualificationMatrixChecksum": self.matrix_checksum,
                    "qualificationEligibleEnvironment": release_type == "stable",
                    "mode": "qualification" if release_type == "stable" else "exploratory",
                    "result": "pass",
                    "qualificationRows": [
                        {
                            "scenario": "seek",
                            "hardware": hardware,
                            "device": f"Fixture {hardware}",
                            "deviceFamily": "iPhone" if hardware == "iphone" else "iPad",
                            "productType": "Fixture1,1",
                            "osVersion": "26.0",
                            "osBuild": "23A1",
                            "osReleaseType": release_type,
                            "fixture": "fixture:abc",
                            "duration": "10s",
                            "durationSeconds": 10,
                            "evidence": "evidence/seek.json",
                            "result": "pass",
                        }
                    ],
                }
            )
        )
        return report

    def test_assembles_rows_and_copies_candidate_bound_evidence(self):
        output = self.root / "qualification" / "1.1.0.json"
        record = assemble_record.assemble(
            "1.1.0",
            self.candidate,
            self.matrix,
            [self.make_report("iphone"), self.make_report("ipad")],
            output,
        )
        self.assertEqual(len(record["rows"]), 2)
        self.assertEqual(record["artifactDigest"], "a" * 64)
        for row in record["rows"]:
            self.assertTrue((output.parent / row["evidence"]).is_file())

    def test_assembles_digest_verified_allocation_trace_artifacts(self):
        iphone = self.make_report("iphone")
        ipad = self.make_report("ipad")
        evidence_path = iphone.parent / "evidence" / "seek.json"
        evidence = json.loads(evidence_path.read_text())
        artifact_directory = evidence_path.parent / "artifacts" / "seek"
        trace = artifact_directory / "allocations.trace"
        trace.mkdir(parents=True)
        (trace / "data.bin").write_bytes(b"allocation stacks")
        toc = artifact_directory / "allocations-toc.xml"
        toc.write_text('<table schema="allocations"/>')
        evidence["allocationProvenance"] = {
            "instrumentsTrace": {
                "runArtifact": "artifacts/seek/allocations.trace",
                "tableOfContents": "artifacts/seek/allocations-toc.xml",
                "treeDigest": assemble_record.tree_digest(trace),
            }
        }
        evidence_path.write_text(json.dumps(evidence))

        output = self.root / "qualification" / "1.1.0.json"
        assemble_record.assemble(
            "1.1.0", self.candidate, self.matrix, [iphone, ipad], output
        )

        retained = output.parent / "evidence" / "1.1.0" / "artifacts" / "seek"
        self.assertTrue((retained / "allocations.trace" / "data.bin").is_file())
        self.assertTrue((retained / "allocations-toc.xml").is_file())

    def test_assembles_digest_verified_performance_trace_artifacts(self):
        scenario = "pip-render-performance-4k60"
        self.matrix.write_text(
            json.dumps(
                {
                    "scenarios": [{"id": scenario, "hardware": ["iphone"]}],
                    "hardware": [
                        {"id": "iphone", "deviceFamily": "iPhone", "osMajor": 26},
                        {"id": "ipad", "deviceFamily": "iPad", "osMajor": 26},
                    ],
                }
            )
        )
        self.matrix_checksum = hashlib.sha256(self.matrix.read_bytes()).hexdigest()
        report_path = self.make_report("iphone")
        report = json.loads(report_path.read_text())
        report["qualificationRows"][0]["scenario"] = scenario
        report_path.write_text(json.dumps(report))

        evidence_path = report_path.parent / "evidence" / "seek.json"
        evidence = json.loads(evidence_path.read_text())
        evidence["scenario"] = scenario
        artifact_directory = evidence_path.parent / "artifacts" / "performance"
        trace_records = {}
        for name in ("game", "power", "time"):
            trace = artifact_directory / f"{name}.trace"
            trace.mkdir(parents=True)
            (trace / "data.bin").write_bytes(f"{name} samples".encode())
            toc = artifact_directory / f"{name}-toc.xml"
            toc.write_text('<trace-toc><table schema="samples"/></trace-toc>')
            trace_records[name] = {
                "runArtifact": f"artifacts/performance/{name}.trace",
                "tableOfContents": f"artifacts/performance/{name}-toc.xml",
                "treeDigest": assemble_record.tree_digest(trace),
            }
        evidence["metrics"] = {
            "gpu": trace_records["game"],
            "energy": trace_records["power"],
            "conversionCost": {"hostTrace": trace_records["time"]},
        }
        evidence_path.write_text(json.dumps(evidence))

        output = self.root / "qualification" / "1.1.0.json"
        assemble_record.assemble(
            "1.1.0", self.candidate, self.matrix, [report_path], output
        )

        retained = output.parent / "evidence" / "1.1.0" / "artifacts" / "performance"
        for name in ("game", "power", "time"):
            self.assertTrue((retained / f"{name}.trace" / "data.bin").is_file())
            self.assertTrue((retained / f"{name}-toc.xml").is_file())

        (retained / "game.trace" / "data.bin").write_bytes(b"tampered")
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0", self.candidate, self.matrix, [report_path], output
            )

    def test_rejects_exploratory_and_duplicate_rows(self):
        output = self.root / "qualification" / "1.1.0.json"
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0",
                self.candidate,
                self.matrix,
                [self.make_report("iphone", release_type="beta")],
                output,
            )

        report = self.make_report("ipad")
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0",
                self.candidate,
                self.matrix,
                [report, report],
                output,
            )

    def test_rejects_report_identity_mismatch(self):
        report = self.make_report("iphone")
        payload = json.loads(report.read_text())
        payload["releaseSourceDigest"] = "d" * 64
        report.write_text(json.dumps(payload))
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0",
                self.candidate,
                self.matrix,
                [report],
                self.root / "qualification" / "1.1.0.json",
            )

    def test_rejects_failed_report_even_when_it_contains_passing_rows(self):
        report = self.make_report("iphone")
        payload = json.loads(report.read_text())
        payload["result"] = "fail"
        report.write_text(json.dumps(payload))
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0",
                self.candidate,
                self.matrix,
                [report],
                self.root / "qualification" / "1.1.0.json",
            )

    def test_rejects_candidate_algorithm_mismatch(self):
        payload = json.loads(self.candidate.read_text())
        payload["artifactDigestAlgorithm"] = "sha256-file-only"
        self.candidate.write_text(json.dumps(payload))
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0",
                self.candidate,
                self.matrix,
                [self.make_report("iphone")],
                self.root / "qualification" / "1.1.0.json",
            )

    def test_rejects_evidence_that_escapes_report_directory(self):
        report = self.make_report("iphone")
        payload = json.loads(report.read_text())
        payload["qualificationRows"][0]["evidence"] = "../outside.json"
        report.write_text(json.dumps(payload))
        (report.parent.parent / "outside.json").write_text("{}")
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0",
                self.candidate,
                self.matrix,
                [report],
                self.root / "qualification" / "1.1.0.json",
            )


class FixtureServerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        (self.root / "sample.bin").write_bytes(bytes(range(256)) * 64)
        for container, suffix in (("ts", ".ts"), ("fmp4", ".m4s")):
            for variant in ("low", "high"):
                directory = self.root / "hls" / "soak" / container / variant
                directory.mkdir(parents=True)
                for index in range(4):
                    (directory / f"segment-{index:03d}{suffix}").write_bytes(
                        f"{container}-{variant}-{index}".encode()
                    )
                if container == "fmp4":
                    (directory / "init.mp4").write_bytes(b"fixture-init")
        self.log = self.root / "requests.jsonl"
        self.server = fixture_server.FixtureHTTPServer(
            ("127.0.0.1", 0), self.root, self.log, 512, 0, False
        )
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.temporary.cleanup()

    def request(self, path: str, headers: dict | None = None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        connection.request("GET", path, headers=headers or {})
        response = connection.getresponse()
        return connection, response

    def last_log_record(self) -> dict:
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            if self.log.exists() and (lines := self.log.read_text().splitlines()):
                return json.loads(lines[-1])
            time.sleep(0.01)
        self.fail("fixture server did not record the completed request")

    def test_static_file_supports_byte_ranges(self):
        connection, response = self.request("/files/sample.bin", {"Range": "bytes=10-19"})
        self.assertEqual(response.status, 206)
        self.assertEqual(response.read(), (self.root / "sample.bin").read_bytes()[10:20])
        connection.close()

        size = (self.root / "sample.bin").stat().st_size
        record = self.last_log_record()
        self.assertEqual(record["requestRange"], "bytes=10-19")
        self.assertEqual(record["responseContentRange"], f"bytes 10-19/{size}")

    def test_out_of_bounds_range_uses_rfc_status(self):
        size = (self.root / "sample.bin").stat().st_size
        connection, response = self.request(
            "/files/sample.bin", {"Range": f"bytes={size}-"}
        )
        self.assertEqual(response.status, 416)
        self.assertEqual(response.getheader("Content-Range"), f"bytes */{size}")
        self.assertEqual(response.read(), b"")
        connection.close()

        record = self.last_log_record()
        self.assertEqual(record["requestRange"], f"bytes={size}-")
        self.assertEqual(record["responseContentRange"], f"bytes */{size}")

    def test_client_reset_does_not_emit_server_traceback(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            try:
                raise ConnectionResetError("fixture client closed keep-alive")
            except ConnectionResetError:
                self.server.handle_error(object(), ("127.0.0.1", 1234))
        self.assertEqual(stderr.getvalue(), "")

    def test_stall_endpoint_delays_then_completes(self):
        started = time.monotonic()
        connection, response = self.request("/fault/stall/0.15/sample.bin")
        self.assertEqual(len(response.read()), (self.root / "sample.bin").stat().st_size)
        self.assertGreaterEqual(time.monotonic() - started, 0.14)
        connection.close()

    def test_live_endpoint_repeats_content(self):
        connection, response = self.request("/live/sample.bin")
        sample = (self.root / "sample.bin").read_bytes()
        self.assertEqual(response.read(len(sample) + 32), sample + sample[:32])
        connection.close()

    def test_gated_stall_waits_only_after_trigger(self):
        self.server.chunk_delay = 0.01
        connection, response = self.request("/fault/gated-stall/test/0.15/sample.bin")
        self.assertEqual(response.read(512), (self.root / "sample.bin").read_bytes()[:512])

        trigger_connection, trigger_response = self.request("/fault/trigger/test")
        self.assertEqual(trigger_response.status, 200)
        self.assertEqual(json.loads(trigger_response.read()), {"generation": 1})
        trigger_connection.close()

        started = time.monotonic()
        self.assertEqual(len(response.read(4096)), 4096)
        self.assertGreaterEqual(time.monotonic() - started, 0.14)
        connection.close()

    def test_gated_stall_also_holds_connections_opened_after_trigger(self):
        trigger_connection, trigger_response = self.request("/fault/trigger/new-client")
        self.assertEqual(json.loads(trigger_response.read()), {"generation": 1})
        trigger_connection.close()

        connection, response = self.request(
            "/fault/gated-stall/new-client/0.15/sample.bin"
        )
        started = time.monotonic()
        self.assertEqual(len(response.read(512)), 512)
        self.assertGreaterEqual(time.monotonic() - started, 0.13)
        connection.close()

    def test_gated_close_terminates_active_and_rejects_new_connections(self):
        self.server.chunk_delay = 0.01
        connection, response = self.request("/fault/gated-close/source-loss/sample.bin")
        self.assertEqual(response.status, 200)
        self.assertEqual(response.read(512), (self.root / "sample.bin").read_bytes()[:512])

        trigger_connection, trigger_response = self.request(
            "/fault/close-trigger/source-loss"
        )
        self.assertEqual(trigger_response.status, 200)
        self.assertEqual(json.loads(trigger_response.read()), {"generation": 1})
        trigger_connection.close()

        buffered_after_trigger = response.read()
        unread_remainder = (self.root / "sample.bin").stat().st_size - 512
        self.assertLess(
            len(buffered_after_trigger),
            unread_remainder,
        )
        connection.close()

        rejected_connection, rejected_response = self.request(
            "/fault/gated-close/source-loss/sample.bin"
        )
        self.assertEqual(rejected_response.status, 503)
        rejected_response.read()
        rejected_connection.close()

        retry_connection, retry_response = self.request(
            "/fault/gated-close/source-loss-retry/sample.bin"
        )
        self.assertEqual(retry_response.status, 200)
        self.assertEqual(
            retry_response.read(512),
            (self.root / "sample.bin").read_bytes()[:512],
        )
        retry_connection.close()

    def test_adaptive_origin_serves_master_event_and_sliding_live_telemetry(self):
        connection, response = self.request("/adaptive/run/vod-ts/master.m3u8")
        master = response.read().decode()
        connection.close()
        self.assertEqual(response.status, 200)
        self.assertIn("RESOLUTION=320x180", master)
        self.assertIn("RESOLUTION=640x360", master)

        connection, response = self.request("/adaptive/run/event-fmp4/low.m3u8")
        event = response.read().decode()
        connection.close()
        self.assertIn("#EXT-X-PLAYLIST-TYPE:EVENT", event)
        self.assertIn("#EXT-X-MAP", event)
        self.assertIn("#EXT-X-DISCONTINUITY", event)

        connection, response = self.request("/adaptive/run/live-ts/high.m3u8")
        first_live = response.read().decode()
        connection.close()
        self.server._adaptive_started_at[("run", "live-ts", "high")] -= 4
        connection, response = self.request("/adaptive/run/live-ts/high.m3u8")
        second_live = response.read().decode()
        connection.close()
        self.assertIn("#EXT-X-MEDIA-SEQUENCE:0", first_live)
        self.assertIn("#EXT-X-MEDIA-SEQUENCE:2", second_live)

        connection, response = self.request("/adaptive/run/metrics")
        metrics = json.loads(response.read())
        connection.close()
        self.assertEqual(metrics["playlistTypes"], ["event", "live", "vod"])
        self.assertEqual(metrics["containers"], ["fmp4", "ts"])
        self.assertGreater(metrics["expiredWindows"], 0)
        self.assertGreater(metrics["discontinuityManifests"], 0)

        connection, response = self.request("/adaptive/run/complete")
        self.assertEqual(json.loads(response.read()), {"clientCompleted": True})
        connection.close()
        connection, response = self.request("/adaptive/run/metrics")
        self.assertTrue(json.loads(response.read())["clientCompleted"])
        connection.close()

    def test_adaptive_retry_fails_once_then_recovers(self):
        path = "/adaptive/retry/retry-ts/low/segment-000.ts"
        connection, response = self.request(path)
        self.assertEqual(response.status, 503)
        response.read()
        connection.close()

        connection, response = self.request(path)
        self.assertEqual(response.status, 200)
        self.assertEqual(response.read(), b"ts-low-0")
        connection.close()

        connection, response = self.request("/adaptive/retry/metrics")
        metrics = json.loads(response.read())
        connection.close()
        self.assertEqual(metrics["retryFailures"], 1)
        self.assertEqual(metrics["retryRecoveries"], 1)

    def test_adaptive_variant_transitions_require_one_multivariant_master(self):
        for path in (
            "/adaptive/transitions/abr-low-ts/low/segment-000.ts",
            "/adaptive/transitions/abr-high-fmp4/high/segment-000.m4s",
        ):
            connection, response = self.request(path)
            self.assertEqual(response.status, 200)
            response.read()
            connection.close()

        connection, response = self.request("/adaptive/transitions/metrics")
        self.assertEqual(json.loads(response.read())["variantTransitions"], 0)
        connection.close()

        for variant in ("low", "high"):
            connection, response = self.request(
                f"/adaptive/transitions/abr-ts/{variant}/segment-000.ts"
            )
            self.assertEqual(response.status, 200)
            response.read()
            connection.close()

        connection, response = self.request("/adaptive/transitions/metrics")
        self.assertEqual(json.loads(response.read())["variantTransitions"], 1)
        connection.close()

    def test_fmp4_generator_places_each_init_beside_its_variant(self):
        script = (ROOT / "qualification" / "generate-fixtures.sh").read_text()
        self.assertIn(
            'cd "$fixture_tmp/hls/soak/fmp4/$variant"',
            script,
        )
        self.assertIn("-hls_fmp4_init_filename init.mp4", script)


if __name__ == "__main__":
    unittest.main()
