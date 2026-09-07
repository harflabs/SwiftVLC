from __future__ import annotations

import contextlib
import errno
import http.client
import hashlib
import importlib.util
import io
import json
import os
import plistlib
import re
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import zipfile
from datetime import datetime, timedelta, timezone
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RELEASE_SCENARIO_ORDER = tuple(
    json.loads((ROOT / "qualification" / "profiles-v1.json").read_text())["profiles"][
        "release"
    ]["scenarios"]
)
FIXTURE_SESSION_BINDING = "9" * 64


def load_script(name: str):
    path = ROOT / "qualification" / name
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


qualification_policy = load_script("qualification_policy.py")
device_info = load_script("device-info.py")
device_run_lock = load_script("device-run-lock.py")
exploratory_device_policy = load_script("exploratory-device-policy.py")
fixture_server = load_script("fixture-server.py")
prepare_xctestrun = load_script("prepare-xctestrun.py")
configure_signing = load_script("configure-signing.py")
package_volunteer_report = load_script("package-volunteer-report.py")
report_validation = load_script("report_validation.py")
validation_plan = load_script("validation-plan.py")
tunnel_host = load_script("tunnel-host.py")
verify_fixtures = load_script("verify-fixtures.py")
candidate_metadata = load_script("candidate-metadata.py")
materialize_evidence = load_script("materialize-evidence.py")
augment_allocation_trace = load_script("augment-allocation-trace.py")
augment_performance_traces = load_script("augment-performance-traces.py")
augment_native_subtitle_traces = load_script("augment-native-subtitle-traces.py")
augment_timebase_evidence = load_script("augment-timebase-evidence.py")
assemble_record = load_script("assemble-record.py")
run_with_watchdog = load_script("run-with-watchdog.py")


def load_repository_script(name: str):
    path = ROOT / name
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


release_source_digest = load_repository_script("release-source-digest.py")


def fixture_candidate_build_attestation_fields(
    *,
    source_commit: str,
    release_source_digest: str,
    artifact_digest: str,
    version: str = "1.1.0",
    catalog: list[str] | None = None,
    candidate_app_digest: str = "a" * 64,
    test_runner_digest: str = "e" * 64,
    test_bundle_digest: str = "f" * 64,
    base_xctestrun_digest: str = "1" * 64,
    base_xctestrun_name: str = "iOS_iphoneos.xctestrun",
) -> dict:
    catalog = catalog or ["iOSUITests/AnalyzerTests/test_pixels"]
    swift_source_files = [
        {
            "relativePath": "Fixture.swift",
            "mode": 0o644,
            "digestAlgorithm": "sha256",
            "digest": "6" * 64,
        }
    ]
    showcase_source_files = sorted([
        {
            "relativePath": "Shared/ValidationFixture.swift",
            "mode": 0o644,
            "digestAlgorithm": "sha256",
            "digest": "7" * 64,
        },
        {
            "relativePath": "iOS/AppFixture.swift",
            "mode": 0o644,
            "digestAlgorithm": "sha256",
            "digest": "8" * 64,
        },
        {
            "relativePath": "UITests/iOS/TestFixture.swift",
            "mode": 0o644,
            "digestAlgorithm": "sha256",
            "digest": "9" * 64,
        },
    ], key=lambda record: record["relativePath"])
    swift_sources = [record["relativePath"] for record in swift_source_files]
    showcase_sources = [
        record["relativePath"] for record in showcase_source_files
    ]
    authority_build_inputs = [
        {
            "relativePath": "Package.swift",
            "mode": 0o644,
            "digestAlgorithm": "sha256",
            "digest": "a" * 64,
        }
    ]
    effective_build_inputs = [dict(authority_build_inputs[0])]
    effective_build_settings = [
        {
            "target": target,
            "settings": {
                "ARCHS": "arm64",
                "CONFIGURATION": "Release",
                "OTHER_LDFLAGS": "",
                "OTHER_SWIFT_FLAGS": "",
                "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "",
                "SWIFT_OPTIMIZATION_LEVEL": "-O",
                "SWIFT_VERSION": "6.0",
            },
        }
        for target in ("iOS", "iOSUITests")
    ]
    attestation = {
        "formatVersion": 1,
        "authority": "swiftvlc-candidate-build-binding-v1",
        "version": version,
        "candidateRuntimeBinding": "e" * 64,
        "sourceCommit": source_commit,
        "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
        "releaseSourceDigest": release_source_digest,
        "artifactRelativePath": "Vendor/libvlc.xcframework",
        "artifactBindingMode": "direct",
        "artifactDigestAlgorithm": "swiftvlc-tree-v1",
        "artifactDigest": artifact_digest,
        "workspaceStateRelativePath": "SourcePackages/workspace-state.json",
        "workspaceStateDigestAlgorithm": "sha256",
        "workspaceStateDigest": "4" * 64,
        "workspaceBinding": qualification_policy.CANDIDATE_WORKSPACE_BINDING,
        "buildConfiguration": "Release",
        "buildPlatform": "iphoneos",
        "swiftSourceRoot": "Sources/SwiftVLC",
        "swiftSourceSetDigestAlgorithm": "swiftvlc-compiled-source-set-v2",
        "swiftSourceSetDigest": qualification_policy.compiled_source_set_digest(
            swift_source_files
        ),
        "swiftSourceCount": len(swift_sources),
        "swiftSourceRelativePaths": swift_sources,
        "swiftSourceFiles": swift_source_files,
        "showcaseSourceRoot": "Showcase",
        "showcaseSourceSetDigestAlgorithm": "swiftvlc-compiled-source-set-v2",
        "showcaseSourceSetDigest": qualification_policy.compiled_source_set_digest(
            showcase_source_files
        ),
        "showcaseSourceCount": len(showcase_sources),
        "showcaseSourceRelativePaths": showcase_sources,
        "showcaseSourceFiles": showcase_source_files,
        "sourceAuthorityBuildInputSetDigestAlgorithm": (
            "swiftvlc-build-input-set-v1"
        ),
        "sourceAuthorityBuildInputSetDigest": (
            qualification_policy.build_input_set_digest(authority_build_inputs)
        ),
        "sourceAuthorityBuildInputCount": len(authority_build_inputs),
        "sourceAuthorityBuildInputFiles": authority_build_inputs,
        "effectiveBuildInputSetDigestAlgorithm": "swiftvlc-build-input-set-v1",
        "effectiveBuildInputSetDigest": qualification_policy.build_input_set_digest(
            effective_build_inputs
        ),
        "effectiveBuildInputCount": len(effective_build_inputs),
        "effectiveBuildInputFiles": effective_build_inputs,
        "authorizedBuildInputTransforms": [],
        "developmentTeam": "ABCDEFGHIJ",
        "bundlePrefix": "com.swiftvlc.validation.fixture",
        "effectiveBuildSettingsDigestAlgorithm": (
            "swiftvlc-effective-build-settings-v1"
        ),
        "effectiveBuildSettingsDigest": (
            qualification_policy.effective_build_settings_digest(
                effective_build_settings
            )
        ),
        "effectiveBuildSettings": effective_build_settings,
        "swiftFileLists": [
            {
                "architecture": "arm64",
                "digestAlgorithm": "sha256",
                "digest": "5" * 64,
                "relativePath": (
                    "Build/Intermediates.noindex/SwiftVLC.build/Release-iphoneos/"
                    "SwiftVLC.build/Objects-normal/arm64/SwiftVLC.SwiftFileList"
                ),
                "sourceCount": len(swift_sources),
            }
        ],
        "showcaseTargetFileLists": [
            {
                "target": target,
                "architecture": "arm64",
                "digestAlgorithm": "sha256",
                "digest": digest * 64,
                "relativePath": (
                    "Build/Intermediates.noindex/SwiftVLCShowcase.build/"
                    f"Release-iphoneos/{target}.build/Objects-normal/arm64/"
                    f"{target}.SwiftFileList"
                ),
                "sourceCount": 2,
                "generatedSourceCount": 1,
                "generatedSourceDigestAlgorithm": "sha256",
                "generatedSourceDigest": generated_digest * 64,
            }
            for target, digest, generated_digest in (
                ("iOS", "a", "b"),
                ("iOSUITests", "c", "d"),
            )
        ],
        "candidateAppRelativePath": "Release-iphoneos/iOS.app",
        "candidateAppDigestAlgorithm": "swiftvlc-tree-v1",
        "candidateAppDigest": candidate_app_digest,
        "testRunnerRelativePath": "Release-iphoneos/iOSUITests-Runner.app",
        "testRunnerDigestAlgorithm": "swiftvlc-tree-v1",
        "testRunnerDigest": test_runner_digest,
        "testBundleRelativePath": "PlugIns/iOSUITests.xctest",
        "testBundleDigestAlgorithm": "swiftvlc-tree-v1",
        "testBundleDigest": test_bundle_digest,
        "baseXCTestRunName": base_xctestrun_name,
        "baseXCTestRunDigestAlgorithm": "sha256",
        "baseXCTestRunDigest": base_xctestrun_digest,
        "testCatalogDigestAlgorithm": "swiftvlc-test-catalog-v1",
        "testCatalogDigest": qualification_policy.catalog_digest(catalog),
        "testCatalogCount": len(catalog),
        "testCatalog": catalog,
    }
    return {
        "candidateRuntimeBinding": attestation["candidateRuntimeBinding"],
        "candidateBuildAttestation": attestation,
        "candidateBuildAttestationDigestAlgorithm": "sha256",
        "candidateBuildAttestationDigest": hashlib.sha256(
            qualification_policy.canonical_json_bytes(attestation)
        ).hexdigest(),
        "testCatalogAuthorityDigestAlgorithm": "sha256",
        "testCatalogAuthorityDigest": "0" * 64,
    }


def cadence_report_only_scenario() -> dict:
    expected_catalog = qualification_policy.catalog_record(
        [qualification_policy.CADENCE_SEMANTICS_PROBE_TEST_IDENTIFIER]
    )
    execution = {
        "expected": expected_catalog,
        "executed": expected_catalog,
        "identityAndCountMatch": True,
        "allPassed": True,
    }
    return {
        "scenario": qualification_policy.CADENCE_SEMANTICS_PROBE_SCENARIO,
        "result": "pass",
        "xcodebuildExitCode": 0,
        "libraryErrorCount": 0,
        "appLog": "captured",
        "qualificationEvidence": "report-only",
        "durationSeconds": 90,
        "expectedTestCatalog": expected_catalog,
        "testExecution": execution,
        "attempts": [{"attempt": 1}],
        "attemptArtifactRoot": "cadence-semantics-probe-attempt-artifacts",
        "hostErrorInventory": {
            "scenario": "cadence-semantics-probe",
            "errorCount": 0,
        },
        "reportOnlyEvidence": {
            "formatVersion": 1,
            "authority": "report-only-cadence-semantics-v1",
            "version": "1.1.0-beta.9",
            "releaseCreditEligible": False,
            "sourceAttempt": 1,
            "sourceXcresultArtifact": (
                "cadence-semantics-probe-attempt-artifacts/attempt-1.xcresult"
            ),
            "sourceXcresultDigestAlgorithm": "swiftvlc-tree-v1",
            "sourceXcresultDigest": "a" * 64,
            "sourceXcresultSizeBytes": 1,
            "retainedFinalXcresultArtifact": "cadence-semantics-probe.xcresult",
            "retainedFinalXcresultDigestAlgorithm": "swiftvlc-tree-v1",
            "retainedFinalXcresultDigest": "a" * 64,
            "retainedFinalXcresultSizeBytes": 1,
            "attachmentName": "exploratory-pip-cadence-semantics-probe.json",
            "attachmentTestIdentifier": (
                qualification_policy.CADENCE_SEMANTICS_PROBE_TEST_IDENTIFIER
            ),
            "retainedAttachmentRoot": "cadence-semantics-probe-attachments",
            "manifestRelativePath": (
                "cadence-semantics-probe-attachments/manifest.json"
            ),
            "manifestDigestAlgorithm": "sha256",
            "manifestDigest": "b" * 64,
            "manifestSizeBytes": 1,
            "attachmentRelativePath": (
                "cadence-semantics-probe-attachments/probe.json"
            ),
            "attachmentDigestAlgorithm": "sha256",
            "attachmentDigest": "c" * 64,
            "attachmentSizeBytes": 1,
        },
    }


def cadence_report_only_candidate(fixture_checksum: str) -> dict:
    catalog = [qualification_policy.CADENCE_SEMANTICS_PROBE_TEST_IDENTIFIER]
    source_commit = "a" * 40
    release_source_digest = "a" * 64
    artifact_digest = "b" * 64
    return {
        "formatVersion": 2,
        "version": "1.1.0-beta.9",
        "sourceCommit": source_commit,
        "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
        "releaseSourceDigest": release_source_digest,
        "artifactDigestAlgorithm": "swiftvlc-tree-v1",
        "artifactDigest": artifact_digest,
        **fixture_candidate_build_attestation_fields(
            source_commit=source_commit,
            release_source_digest=release_source_digest,
            artifact_digest=artifact_digest,
            version="1.1.0-beta.9",
            catalog=catalog,
            candidate_app_digest="c" * 64,
            test_runner_digest="d" * 64,
            test_bundle_digest="e" * 64,
            base_xctestrun_digest="f" * 64,
            base_xctestrun_name="fixture.xctestrun",
        ),
        "candidateAppBundleIdentifier": "com.swiftvlc.fixture.app",
        "candidateAppDigestAlgorithm": "swiftvlc-tree-v1",
        "candidateAppDigest": "c" * 64,
        "testRunnerBundleIdentifier": "com.swiftvlc.fixture.uitests.xctrunner",
        "testRunnerDigestAlgorithm": "swiftvlc-tree-v1",
        "testRunnerDigest": "d" * 64,
        "testBundleRelativePath": "PlugIns/iOSUITests.xctest",
        "testBundleDigestAlgorithm": "swiftvlc-tree-v1",
        "testBundleDigest": "e" * 64,
        "baseXCTestRunDigestAlgorithm": "sha256",
        "baseXCTestRunDigest": "f" * 64,
        "baseXCTestRunName": "fixture.xctestrun",
        "testCatalogDigestAlgorithm": "swiftvlc-test-catalog-v1",
        "testCatalogDigest": qualification_policy.catalog_digest(catalog),
        "testCatalogCount": len(catalog),
        "testCatalog": catalog,
        "qualificationMatrixChecksum": "1" * 64,
        "featureManifestChecksum": "2" * 64,
        "qualificationProfilesChecksum": "3" * 64,
        "fixtureManifestChecksum": fixture_checksum,
        "qualificationPolicyDigestAlgorithm": "swiftvlc-qualification-policy-v1",
        "qualificationPolicyDigest": qualification_policy.policy_digest(),
    }


def write_validated_report(
    run_dir: Path,
    value: dict,
    *,
    selection_scope: str = "partial",
    mode: str = "qualification",
    qualification_eligible: bool = True,
    report_only: bool = False,
    retained_files: dict[str, str] | None = None,
) -> None:
    device_path = run_dir / "device.json"
    if not device_path.exists():
        selected_device = {
            "id": "fixture-coredevice",
            "udid": "fixture-device",
            "ecid": 42,
            "ecidHex": "0x2A",
            "name": "Fixture iPhone",
            "marketingName": "iPhone",
            "productType": "iPhone17,1",
            "deviceFamily": "iPhone",
            "osVersion": "26.0",
            "osMajor": 26,
            "osBuild": "23A1" if qualification_eligible else "23A1a",
            "osReleaseType": "stable" if qualification_eligible else "beta",
            "transport": "wired",
            "tunnelIPAddress": "fd00::1",
            "connected": True,
            "matchingHardwareRows": ["iphone-current"],
            "qualificationEligible": qualification_eligible,
        }
        report_validation.atomic_write_json(
            device_path,
            {
                "selected": selected_device,
                "connected": [selected_device],
                "allPhysicalIOSDevices": [selected_device],
                "mode": mode,
            },
        )
    fixture_path = run_dir / "fixture-manifest.json"
    if not fixture_path.exists():
        report_validation.atomic_write_json(fixture_path, {"formatVersion": 1})
    selected_device = json.loads(device_path.read_text())["selected"]
    fixture_digest = hashlib.sha256(fixture_path.read_bytes()).hexdigest()
    candidate_path = run_dir / "candidate-metadata.json"
    if not candidate_path.exists():
        candidate = (
            cadence_report_only_candidate(fixture_digest)
            if report_only
            else {"formatVersion": 2}
        )
        report_validation.atomic_write_json(candidate_path, candidate)
    candidate = json.loads(candidate_path.read_text())
    candidate_identity = (
        {
            field: candidate[field]
            for field in qualification_policy.CORE_IDENTITY_FIELDS
        }
        if report_only
        else {}
    )
    completed_at = datetime.now(timezone.utc).replace(microsecond=0)
    started_at = completed_at - timedelta(seconds=1)
    report = {
        **candidate_identity,
        "formatVersion": 2,
        "startedAtUTC": started_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "completedAtUTC": completed_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "wallDurationSeconds": 1,
        "mode": mode,
        "qualificationEligibleEnvironment": qualification_eligible,
        "reportOnly": report_only,
        "orchestratorSessionBinding": FIXTURE_SESSION_BINDING,
        "orchestratorStartedAtUTC": started_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "releaseGateSatisfied": False,
        "releaseGateReason": (
            "exploratory cadence semantics probe cannot produce release credit"
            if report_only
            else qualification_policy.ORDINARY_RELEASE_GATE_REASON
        ),
        "qualificationRows": [],
        "device": selected_device,
        "deviceSnapshot": qualification_policy.device_snapshot_binding(run_dir),
        "fixtureManifestChecksum": fixture_digest,
        **value,
    }
    scenario_ids = [row["scenario"] for row in report.get("scenarios", [])]
    plan = {
        "formatVersion": 2,
        "startedAtUTC": report["startedAtUTC"],
        "mode": report["mode"],
        "qualificationEligibleEnvironment": report[
            "qualificationEligibleEnvironment"
        ],
        "reportOnly": report["reportOnly"],
        "selectionScope": selection_scope,
        "orchestratorSessionBinding": FIXTURE_SESSION_BINDING,
        "orchestratorStartedAtUTC": report["startedAtUTC"],
        "requestedScenarioDrivers": scenario_ids,
        "selectedScenarioDrivers": scenario_ids,
        "skippedScenarioDrivers": [],
        "matrixHardwareRows": ["iphone-current"],
        "matrixScenarioOutputsPlanned": [],
        "projectedHardwareRow": None,
    }
    report_validation.atomic_write_json(run_dir / "report.json", report)
    report_validation.atomic_write_json(run_dir / "validation-plan.json", plan)
    for relative, contents in (retained_files or {}).items():
        destination = run_dir / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(contents)
    report_bytes = (run_dir / "report.json").read_bytes()
    plan_bytes = (run_dir / "validation-plan.json").read_bytes()
    authority = (
        report_validation.REPORT_ONLY_AUTHORITY
        if report_only
        else report_validation.QUALIFICATION_AUTHORITY
    )
    report_validation.write_marker_for_bytes(
        run_dir,
        report_bytes,
        plan_bytes,
        authority,
        validated_evidence_manifest=report_validation.evidence_tree_manifest(
            run_dir
        ),
    )


def timebase_raw_sample(
    elapsed: int,
    rate: float,
    media_time: float,
    *,
    generation: int = 1,
) -> dict:
    return {
        "kind": "sample",
        "clock": {
            "elapsedSeconds": elapsed,
            "mediaTimeSeconds": media_time,
            "driftSeconds": 0.01,
            "playbackGeneration": generation,
            "requestedRate": rate,
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
            "playbackGeneration": generation,
            "deliveredFrames": elapsed + 1,
            "droppedFrames": 0,
            "presentedSeconds": media_time,
            "decodedFrames": elapsed + 1,
            "decodedFrameMediaTimeSeconds": media_time,
        },
    }


def timebase_raw_correction(
    sequence: int,
    reason: str = "steadyStateDrift",
    drift: float = 0.02,
) -> dict:
    return {
        "kind": "correction",
        "correction": {
            "sequence": sequence,
            "capturedAt": 1_700_000_000.0 + sequence,
            "systemUptime": 1_000.0 + sequence,
            "playbackGeneration": 1,
            "reason": reason,
            "mediaTimeSeconds": float(sequence),
            "previousTimebaseSeconds": float(sequence) - drift,
            "correctedTimebaseSeconds": float(sequence),
            "driftSeconds": drift,
        },
    }


class DeviceInfoTests(unittest.TestCase):
    def test_release_classification_is_fail_closed(self):
        self.assertEqual(device_info.release_type({"releaseType": "Beta"}), "beta")
        self.assertEqual(
            device_info.release_type({"osBuildUpdate": "24A5390f"}), "beta"
        )
        self.assertEqual(
            device_info.release_type({"osBuildUpdate": "20E772520a"}), "stable"
        )
        self.assertEqual(device_info.release_type({"osBuildUpdate": "23G80"}), "stable")
        self.assertEqual(
            device_info.release_type({"osBuildUpdate": "unexpected"}), "unknown"
        )
        self.assertEqual(
            device_info.release_type(
                {"releaseType": "stable", "osBuildUpdate": "24A5390f"}
            ),
            "unknown",
        )
        self.assertEqual(
            device_info.release_type({"releaseType": "beta", "osBuildUpdate": "23G80"}),
            "unknown",
        )

    def test_only_connected_stable_matching_device_qualifies(self):
        device = {
            "identifier": "core-id",
            "connectionProperties": {
                "tunnelState": "connected",
                "transportType": "wired",
            },
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

    def test_preserves_the_wired_coredevice_tunnel_address(self):
        device = {
            "identifier": "core-id",
            "connectionProperties": {
                "tunnelState": "connected",
                "transportType": "wired",
                "tunnelIPAddress": "fd7d:5ea1:e53f::1",
            },
            "deviceProperties": {
                "ddiServicesAvailable": True,
                "developerModeStatus": "enabled",
                "osVersionNumber": "26.6",
                "osBuildUpdate": "23G80",
            },
            "hardwareProperties": {
                "reality": "physical",
                "platform": "iOS",
                "deviceType": "iPhone",
            },
        }
        normalized = device_info.normalize(device, [])
        self.assertEqual(normalized["tunnelIPAddress"], "fd7d:5ea1:e53f::1")

    def test_live_details_replace_a_dormant_list_snapshot(self):
        dormant = {
            "identifier": "core-id",
            "connectionProperties": {"tunnelState": "disconnected"},
            "deviceProperties": {"ddiServicesAvailable": False},
            "hardwareProperties": {"reality": "physical", "platform": "iOS"},
        }
        details = {
            "identifier": "core-id",
            "connectionProperties": {"tunnelState": "connected"},
            "deviceProperties": {"ddiServicesAvailable": True},
            "hardwareProperties": {"reality": "physical", "platform": "iOS"},
        }

        self.assertEqual(
            device_info.replace_device_snapshot([dormant], details),
            [details],
        )

    def test_unlisted_live_details_are_retained(self):
        details = {"identifier": "new-core-id"}
        self.assertEqual(
            device_info.replace_device_snapshot([], details),
            [details],
        )

    def test_explicit_device_selector_must_resolve_uniquely(self):
        devices = [
            {
                "id": "core-id-a",
                "udid": "fixture-udid-a",
                "ecidHex": "0x2A",
                "name": "Fixture iPhone",
                "marketingName": "iPhone Fixture",
                "productType": "iPhone99,1",
            },
            {
                "id": "core-id-b",
                "udid": "fixture-udid-b",
                "ecidHex": "0x2B",
                "name": "Fixture iPhone",
                "marketingName": "iPhone Fixture",
                "productType": "iPhone99,2",
            },
        ]

        with self.assertRaisesRegex(
            device_info.DeviceSelectionError,
            r"matched 2 connected physical iOS devices.*core-id-a.*core-id-b",
        ):
            device_info.select_explicit_device(devices, "Fixture iPhone")
        self.assertIs(
            device_info.select_explicit_device(devices, "fixture-udid-b"),
            devices[1],
        )


class DeviceRunLockTests(unittest.TestCase):
    def _wait_for_ready(self, process: subprocess.Popen, ready: Path) -> dict:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if ready.is_file():
                return json.loads(ready.read_text())
            if process.poll() is not None:
                _, stderr = process.communicate()
                self.fail(
                    f"device lock exited before readiness ({process.returncode}): {stderr}"
                )
            time.sleep(0.02)
        process.terminate()
        process.wait(timeout=5)
        self.fail("device lock did not report readiness")

    def _start_lock(
        self,
        root: Path | None,
        ready: Path,
        device: str,
        *,
        environment: dict[str, str] | None = None,
    ) -> subprocess.Popen:
        arguments = [
                sys.executable,
                str(ROOT / "qualification" / "device-run-lock.py"),
                "--device-identifier",
                device,
                "--parent-pid",
                str(os.getpid()),
                "--ready-file",
                str(ready),
        ]
        if root is not None:
            arguments.extend(["--lock-root", str(root)])
        return subprocess.Popen(
            arguments,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
        )

    def _assert_lock(
        self,
        root: Path,
        device: str,
        owner_pid: int,
    ) -> subprocess.CompletedProcess:
        return subprocess.run(
            [
                sys.executable,
                str(ROOT / "qualification" / "device-run-lock.py"),
                "--assert-held",
                "--device-identifier",
                device,
                "--parent-pid",
                str(os.getpid()),
                "--owner-pid",
                str(owner_pid),
                "--lock-root",
                str(root),
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )

    def test_same_device_is_exclusive_and_released_with_owner(self):
        device = "00008110-001A2B3C4D5E601E"
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            lock_root = temporary / "locks"
            first = self._start_lock(lock_root, temporary / "first.json", device)
            try:
                owner = self._wait_for_ready(first, temporary / "first.json")
                self.assertEqual(owner["authority"], device_run_lock.LOCK_AUTHORITY)
                self.assertEqual(owner["ownerPID"], first.pid)
                self.assertEqual(owner["deviceIdentifierSuffix"], device[-6:])
                self.assertNotIn(device, (temporary / "first.json").read_text())
                self.assertNotIn(device, owner["deviceIdentifierDigest"])
                assertion = self._assert_lock(lock_root, device, first.pid)
                self.assertEqual(assertion.returncode, 0, assertion.stderr)

                wrong_owner = self._assert_lock(lock_root, device, first.pid + 1)
                self.assertEqual(wrong_owner.returncode, 75)
                self.assertIn("ownerPID mismatch", wrong_owner.stderr)

                contender = subprocess.run(
                    [
                        sys.executable,
                        str(ROOT / "qualification" / "device-run-lock.py"),
                        "--device-identifier",
                        device,
                        "--parent-pid",
                        str(os.getpid()),
                        "--ready-file",
                        str(temporary / "contender.json"),
                        "--lock-root",
                        str(lock_root),
                    ],
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
                self.assertEqual(contender.returncode, 75)
                self.assertIn(str(first.pid), contender.stderr)
                self.assertIn(device[-6:], contender.stderr)
                self.assertFalse((temporary / "contender.json").exists())
            finally:
                first.terminate()
                first.communicate(timeout=5)

            released_assertion = self._assert_lock(lock_root, device, first.pid)
            self.assertEqual(released_assertion.returncode, 75)
            self.assertIn("no longer reserved", released_assertion.stderr)

            replacement = self._start_lock(
                lock_root, temporary / "replacement.json", device
            )
            try:
                replacement_owner = self._wait_for_ready(
                    replacement, temporary / "replacement.json"
                )
                self.assertEqual(replacement_owner["ownerPID"], replacement.pid)
            finally:
                replacement.terminate()
                replacement.communicate(timeout=5)

    def test_different_inherited_tmpdirs_still_contend(self):
        device = f"test-device-{os.getpid()}-{time.time_ns()}"
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            first_tmp = temporary / "first-tmp"
            second_tmp = temporary / "second-tmp"
            first_tmp.mkdir()
            second_tmp.mkdir()
            first_environment = dict(os.environ, TMPDIR=str(first_tmp))
            second_environment = dict(os.environ, TMPDIR=str(second_tmp))
            first = self._start_lock(
                None,
                temporary / "first-default.json",
                device,
                environment=first_environment,
            )
            try:
                self._wait_for_ready(first, temporary / "first-default.json")
                contender = subprocess.run(
                    [
                        sys.executable,
                        str(ROOT / "qualification" / "device-run-lock.py"),
                        "--device-identifier",
                        device,
                        "--parent-pid",
                        str(os.getpid()),
                        "--ready-file",
                        str(temporary / "second-default.json"),
                    ],
                    capture_output=True,
                    text=True,
                    timeout=5,
                    env=second_environment,
                )
                self.assertEqual(contender.returncode, 75)
                self.assertFalse((temporary / "second-default.json").exists())
            finally:
                first.terminate()
                first.communicate(timeout=5)
                device_run_lock.device_lock_path(
                    device_run_lock.default_lock_root(), device
                ).unlink(missing_ok=True)

    def test_lock_path_is_an_identifier_digest_and_roots_reject_symlinks(self):
        device = "00008110-001A2B3C4D5E601E"
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            lock_path = device_run_lock.device_lock_path(temporary, device)
            self.assertEqual(lock_path.stem, hashlib.sha256(device.encode()).hexdigest())
            self.assertNotIn(device, str(lock_path))

            real_root = temporary / "real"
            real_root.mkdir()
            linked_root = temporary / "linked"
            linked_root.symlink_to(real_root, target_is_directory=True)
            with self.assertRaisesRegex(
                device_run_lock.DeviceRunLockError, "must be a real directory"
            ):
                device_run_lock._prepare_lock_root(linked_root)


class TunnelHostTests(unittest.TestCase):
    def test_finds_the_mac_peer_in_the_device_tunnel_prefix(self):
        value = tunnel_host.matching_host_address(
            "fd7d:5ea1:e53f::1",
            """
utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST>
    inet6 fe80::d211:e5ff:fe08:e097%utun4 prefixlen 64
    inet6 fd7d:5ea1:e53f::2 prefixlen 64
en0: flags=8863<UP,BROADCAST,RUNNING>
    inet6 fd00:dead:beef::2 prefixlen 64
""",
        )
        self.assertEqual(value, "fd7d:5ea1:e53f::2")

    def test_rejects_an_ambiguous_or_missing_peer(self):
        for ifconfig_output in (
            "",
            """
utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST>
    inet6 fd7d:5ea1:e53f::2 prefixlen 64
    inet6 fd7d:5ea1:e53f::3 prefixlen 64
""",
        ):
            with self.subTest(ifconfig_output=ifconfig_output):
                with self.assertRaisesRegex(ValueError, "expected one"):
                    tunnel_host.matching_host_address(
                        "fd7d:5ea1:e53f::1", ifconfig_output
                    )


class FixtureServerAddressTests(unittest.TestCase):
    def test_brackets_ipv6_hosts_in_fixture_urls(self):
        self.assertEqual(
            fixture_server.advertised_url("fd7d:5ea1:e53f::2", 8080),
            "http://[fd7d:5ea1:e53f::2]:8080",
        )

    def test_ipv6_listener_uses_an_ipv6_socket(self):
        with tempfile.TemporaryDirectory() as directory:
            server = fixture_server.FixtureHTTPServer(
                ("::1", 0), Path(directory), None, 512, 0, False
            )
            try:
                self.assertEqual(server.address_family, fixture_server.socket.AF_INET6)
                self.assertEqual(server.server_address[0], "::1")
            finally:
                server.server_close()


class ExploratoryDevicePolicyTests(unittest.TestCase):
    matrix = {
        "hardware": [{"id": "iphone-current", "deviceFamily": "iPhone", "osMajor": 26}]
    }

    def record(self, **selected):
        return {
            "mode": "exploratory",
            "selected": {"deviceFamily": "iPhone", "osMajor": 27, **selected},
        }

    def test_future_iphone_os_can_run_current_only_lanes_exploratorily(self):
        self.assertTrue(
            exploratory_device_policy.permits_current_only(
                self.record(osReleaseType="beta"), self.matrix
            )
        )
        self.assertEqual(
            exploratory_device_policy.evidence_hardware_id(
                self.record(osReleaseType="beta"), self.matrix
            ),
            "exploratory-future-ios",
        )

    def test_matching_or_older_os_cannot_bypass_matrix_selection(self):
        self.assertFalse(
            exploratory_device_policy.permits_current_only(
                self.record(osMajor=26), self.matrix
            )
        )

    def test_ipad_cannot_borrow_the_iphone_current_lanes(self):
        self.assertFalse(
            exploratory_device_policy.permits_current_only(
                self.record(deviceFamily="iPad"), self.matrix
            )
        )

    def test_qualification_mode_never_uses_the_exploratory_override(self):
        record = self.record()
        record["mode"] = "qualification"
        self.assertFalse(
            exploratory_device_policy.permits_current_only(record, self.matrix)
        )


class ValidationPlanTests(unittest.TestCase):
    matrix = json.loads((ROOT / "qualification" / "matrix.json").read_text())

    def build(
        self,
        selected,
        hardware,
        *,
        requested=None,
        projected=None,
        report_only=False,
        selection_scope="partial",
    ):
        hardware_by_id = {row["id"]: row for row in self.matrix["hardware"]}
        if hardware:
            row = hardware_by_id[hardware[0]]
            family = row["deviceFamily"]
            os_major = row["osMajor"]
            mode = "qualification"
            qualification_eligible = True
            release_type = "stable"
        else:
            family = "iPhone"
            os_major = hardware_by_id["iphone-current"]["osMajor"] + 1
            mode = "exploratory"
            qualification_eligible = False
            release_type = "beta"
        device_info_value = {
            "mode": mode,
            "selected": {
                "deviceFamily": family,
                "osMajor": os_major,
                "osReleaseType": release_type,
                "qualificationEligible": qualification_eligible,
                "matchingHardwareRows": hardware,
            },
        }
        return validation_plan.build_plan(
            device_info_value,
            self.matrix,
            list(selected if requested is None else requested),
            list(selected),
            started_at_utc="2026-09-02T00:00:00Z",
            orchestrator_session_binding=FIXTURE_SESSION_BINDING,
            orchestrator_started_at_utc="2026-09-02T00:00:00Z",
            projected_hardware_row=projected,
            report_only=report_only,
            selection_scope=selection_scope,
        )

    def test_planned_outputs_come_only_from_selected_driver_contracts(self):
        cases = (
            ("analyzer", ["analyzer"], ["iphone-current"], None, []),
            ("ui-suite", ["ui-suite"], ["iphone-current"], None, []),
            (
                "dismissal",
                ["dismissal"],
                ["iphone-minimum"],
                None,
                ["restore", "close"],
            ),
            (
                "continuity-minimum",
                ["continuity"],
                ["iphone-minimum"],
                None,
                ["replacement"],
            ),
            (
                "continuity-current",
                ["continuity"],
                ["iphone-current"],
                None,
                ["replacement", "replacement-continuity"],
            ),
            (
                "continuity-projected",
                ["continuity"],
                [],
                "iphone-current",
                ["replacement", "replacement-continuity"],
            ),
            (
                "failed-start-minimum",
                ["failed-start"],
                ["iphone-minimum"],
                None,
                ["failed-start"],
            ),
            (
                "failed-start-current",
                ["failed-start"],
                ["iphone-current"],
                None,
                ["failed-start", "accepted-start-delayed-failure"],
            ),
        )
        for name, selected, hardware, projected, expected in cases:
            with self.subTest(name=name):
                plan = self.build(selected, hardware, projected=projected)
                self.assertEqual(plan["matrixScenarioOutputsPlanned"], expected)
                self.assertNotIn("matrixRowsRepresented", plan)

    def test_report_only_plan_never_claims_matrix_outputs(self):
        plan = self.build(["continuity"], ["iphone-current"], report_only=True)
        self.assertEqual(plan["matrixScenarioOutputsPlanned"], [])
        self.assertEqual(plan["selectionScope"], "partial")

    def test_report_only_plan_cannot_claim_full_scope(self):
        with self.assertRaisesRegex(ValueError, "cannot claim full scope"):
            self.build(
                ["cadence-semantics-probe"],
                ["iphone-current"],
                report_only=True,
                selection_scope="full",
            )

    def test_full_plan_requires_the_complete_immutable_release_runner_set(self):
        with self.assertRaisesRegex(ValueError, "immutable release coverage"):
            self.build(
                ["analyzer"],
                ["iphone-current"],
                selection_scope="full",
            )

        plan = self.build(
            RELEASE_SCENARIO_ORDER,
            ["iphone-current"],
            selection_scope="full",
        )
        self.assertEqual(
            set(plan["requestedScenarioDrivers"]),
            qualification_policy.REQUIRED_RELEASE_RUNNER_SCENARIOS,
        )
        self.assertEqual(
            set(plan["selectedScenarioDrivers"]),
            qualification_policy.REQUIRED_RELEASE_RUNNER_SCENARIOS,
        )

    def test_full_plan_rejects_reordered_complete_release_runner_set(self):
        reordered = list(RELEASE_SCENARIO_ORDER)
        reordered[0], reordered[1] = reordered[1], reordered[0]
        with self.assertRaisesRegex(ValueError, "coverage or order"):
            self.build(
                reordered,
                ["iphone-current"],
                requested=reordered,
                selection_scope="full",
            )

        reset_early = list(RELEASE_SCENARIO_ORDER)
        reset_early.insert(0, reset_early.pop())
        with self.assertRaisesRegex(ValueError, "coverage or order"):
            self.build(
                reset_early,
                ["iphone-current"],
                requested=reset_early,
                selection_scope="full",
            )

    def test_full_plan_selects_exactly_the_device_applicable_release_set(self):
        selected = [
            scenario
            for scenario in RELEASE_SCENARIO_ORDER
            if scenario
            not in qualification_policy.IPHONE_CURRENT_ONLY_RUNNER_SCENARIOS
        ]
        plan = self.build(
            selected,
            ["ipad-minimum"],
            requested=RELEASE_SCENARIO_ORDER,
            selection_scope="full",
        )
        self.assertEqual(plan["selectedScenarioDrivers"], selected)
        self.assertEqual(
            {row["scenario"] for row in plan["skippedScenarioDrivers"]},
            qualification_policy.IPHONE_CURRENT_ONLY_RUNNER_SCENARIOS,
        )

        with self.assertRaisesRegex(ValueError, "device-applicable release coverage"):
            self.build(
                [*selected, "capability-convergence"],
                ["ipad-minimum"],
                requested=RELEASE_SCENARIO_ORDER,
                selection_scope="full",
            )

    def test_future_iphone_projection_controls_full_plan_applicability(self):
        projected = self.build(
            RELEASE_SCENARIO_ORDER,
            [],
            requested=RELEASE_SCENARIO_ORDER,
            projected="iphone-current",
            selection_scope="full",
        )
        self.assertEqual(projected["matrixHardwareRows"], [])
        self.assertEqual(projected["projectedHardwareRow"], "iphone-current")

        with self.assertRaisesRegex(ValueError, "projected hardware row"):
            self.build(
                RELEASE_SCENARIO_ORDER,
                ["iphone-current"],
                projected="iphone-current",
                selection_scope="full",
            )

    def test_duplicate_driver_plan_is_rejected_before_device_work(self):
        with self.assertRaisesRegex(ValueError, "non-empty unique"):
            self.build(["analyzer", "analyzer"], ["iphone-current"])


class ReportValidationReceiptTests(unittest.TestCase):
    def test_receipt_binds_the_exact_report_and_validation_plan(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "scenarios": [{"scenario": "analyzer", "result": "pass"}],
                },
            )
            report_bytes = (run / "report.json").read_bytes()
            plan_bytes = (run / "validation-plan.json").read_bytes()
            self.assertTrue(
                report_validation.is_valid(run, report_bytes, plan_bytes)
            )

            plan = json.loads(plan_bytes)
            plan["selectionScope"] = "full"
            report_validation.atomic_write_json(run / "validation-plan.json", plan)

            self.assertFalse(report_validation.is_valid(run))

    def test_receipt_binds_every_retained_evidence_entry(self):
        mutations = {
            "changed": lambda run: (run / "evidence" / "probe.json").write_text(
                '{"value":2}\n'
            ),
            "deleted": lambda run: (run / "evidence" / "probe.json").unlink(),
            "added": lambda run: (run / "evidence" / "extra.json").write_text(
                '{"value":3}\n'
            ),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                run = Path(directory)
                write_validated_report(
                    run,
                    {
                        "result": "pass",
                        "scenarios": [{"scenario": "analyzer", "result": "pass"}],
                    },
                    retained_files={"evidence/probe.json": '{"value":1}\n'},
                )
                self.assertTrue(report_validation.is_valid(run))

                mutate(run)

                self.assertFalse(report_validation.is_valid(run))

    def test_evidence_manifest_is_deterministic_and_excludes_only_derived_files(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "scenarios": [{"scenario": "analyzer", "result": "pass"}],
                },
                retained_files={"evidence/z.json": "{}\n", "a.log": "proof\n"},
            )
            first = (run / report_validation.EVIDENCE_MANIFEST_FILENAME).read_bytes()
            report_bytes = (run / "report.json").read_bytes()
            plan_bytes = (run / "validation-plan.json").read_bytes()
            (run / report_validation.MARKER_FILENAME).unlink()
            (run / report_validation.EVIDENCE_MANIFEST_FILENAME).unlink()

            report_validation.write_marker_for_bytes(
                run,
                report_bytes,
                plan_bytes,
                report_validation.QUALIFICATION_AUTHORITY,
                validated_evidence_manifest=(
                    report_validation.evidence_tree_manifest(run)
                ),
            )

            self.assertEqual(
                first,
                (run / report_validation.EVIDENCE_MANIFEST_FILENAME).read_bytes(),
            )
            for name in report_validation.POST_VALIDATION_ROOT_FILES:
                (run / name).write_text("derived\n")
            self.assertTrue(report_validation.is_valid(run))
            (run / "unexpected-post-validation.txt").write_text("unbound\n")
            self.assertFalse(report_validation.is_valid(run))

    def test_snapshot_prefix_collision_is_inventoried_and_cannot_be_replayed(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            collision_name = (
                report_validation.VALIDATION_SNAPSHOT_PREFIX + "release-evidence.json"
            )
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "scenarios": [{"scenario": "analyzer", "result": "pass"}],
                },
                retained_files={collision_name: '{"value":1}\n'},
            )
            manifest = json.loads(
                (run / report_validation.EVIDENCE_MANIFEST_FILENAME).read_text()
            )
            self.assertIn(
                collision_name,
                {entry["path"] for entry in manifest["files"]},
            )

            (run / collision_name).write_text('{"value":2}\n')

            self.assertFalse(report_validation.is_valid(run))

    def test_semantic_validation_rejects_preexisting_snapshot_prefix_collision(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "scenarios": [{"scenario": "analyzer", "result": "pass"}],
                },
            )
            collision = run / (
                report_validation.VALIDATION_SNAPSHOT_PREFIX + "preexisting.json"
            )
            collision.write_text("{}\n")

            with self.assertRaisesRegex(
                report_validation.ReportValidationError,
                "reserved validation snapshot paths",
            ):
                report_validation.validate_and_mark(
                    run,
                    matrix_path=None,
                    candidate_path=None,
                )

            self.assertFalse((run / report_validation.MARKER_FILENAME).exists())
            self.assertFalse(
                (run / report_validation.EVIDENCE_MANIFEST_FILENAME).exists()
            )

    def test_only_the_validator_owned_snapshot_inode_is_excluded(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "scenarios": [{"scenario": "analyzer", "result": "pass"}],
                },
            )
            snapshot = run / (
                report_validation.VALIDATION_SNAPSHOT_PREFIX + "owned.json"
            )
            snapshot.write_text("{}\n")
            metadata = snapshot.stat()
            identity = (snapshot, metadata.st_dev, metadata.st_ino)
            report_validation.evidence_tree_manifest(
                run, validation_snapshot=identity
            )
            replacement = run / "replacement.json"
            replacement.write_text("{}\n")
            os.replace(replacement, snapshot)

            with self.assertRaisesRegex(
                report_validation.ReportValidationError,
                "snapshot was replaced",
            ):
                report_validation.evidence_tree_manifest(
                    run, validation_snapshot=identity
                )

    def test_failed_revalidation_removes_the_previous_success_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "scenarios": [{"scenario": "analyzer", "result": "pass"}],
                },
            )
            with self.assertRaisesRegex(
                report_validation.ReportValidationError,
                "requires matrix and candidate",
            ):
                report_validation.validate_and_mark(
                    run,
                    matrix_path=None,
                    candidate_path=None,
                )

            self.assertFalse((run / report_validation.MARKER_FILENAME).exists())
            self.assertFalse(
                (run / report_validation.EVIDENCE_MANIFEST_FILENAME).exists()
            )

    def test_receipt_rejects_a_report_time_range_not_bound_to_the_plan(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "scenarios": [{"scenario": "analyzer", "result": "pass"}],
                },
            )
            report = json.loads((run / "report.json").read_text())
            report["startedAtUTC"] = "2026-09-01T00:00:00Z"

            with self.assertRaisesRegex(
                report_validation.ReportValidationError,
                "does not match the validation plan",
            ):
                report_validation.marker_payload(
                    json.dumps(report).encode(),
                    (run / "validation-plan.json").read_bytes(),
                    report_validation.QUALIFICATION_AUTHORITY,
                )

    def test_report_driver_mismatch_is_rejected_even_when_both_json_files_parse(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "scenarios": [{"scenario": "analyzer", "result": "pass"}],
                },
            )
            plan = json.loads((run / "validation-plan.json").read_text())
            plan["requestedScenarioDrivers"] = ["analyzer", "ui-suite"]
            plan["selectedScenarioDrivers"] = ["ui-suite"]
            plan["skippedScenarioDrivers"] = [
                {"scenario": "analyzer", "reason": "test mismatch"}
            ]

            with self.assertRaisesRegex(
                report_validation.ReportValidationError,
                "do not exactly match",
            ):
                report_validation.marker_payload(
                    (run / "report.json").read_bytes(),
                    json.dumps(plan).encode(),
                    report_validation.QUALIFICATION_AUTHORITY,
                )

    def test_plan_selection_must_reconcile_its_skipped_drivers(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "scenarios": [{"scenario": "analyzer", "result": "pass"}],
                },
            )
            plan = json.loads((run / "validation-plan.json").read_text())
            plan["requestedScenarioDrivers"] = ["analyzer", "ui-suite"]

            with self.assertRaisesRegex(
                report_validation.ReportValidationError,
                "do not reconcile",
            ):
                report_validation.marker_payload(
                    (run / "report.json").read_bytes(),
                    json.dumps(plan).encode(),
                    report_validation.QUALIFICATION_AUTHORITY,
                )

    def test_arbitrary_one_driver_report_cannot_forge_full_scope(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "scenarios": [{"scenario": "analyzer", "result": "pass"}],
                },
            )
            plan = json.loads((run / "validation-plan.json").read_text())
            plan["selectionScope"] = "full"

            with self.assertRaisesRegex(
                report_validation.ReportValidationError,
                "requested drivers differ from immutable release coverage",
            ):
                report_validation.marker_payload(
                    (run / "report.json").read_bytes(),
                    json.dumps(plan).encode(),
                    report_validation.QUALIFICATION_AUTHORITY,
                )

    def test_canonical_full_report_is_accepted_and_omission_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "scenarios": [
                        {"scenario": scenario, "result": "pass"}
                        for scenario in RELEASE_SCENARIO_ORDER
                    ],
                },
                selection_scope="full",
            )
            self.assertTrue(report_validation.is_valid(run))
            self.assertTrue(report_validation.is_release_scope_valid(run))

            report = json.loads((run / "report.json").read_text())
            plan = json.loads((run / "validation-plan.json").read_text())
            omitted = plan["selectedScenarioDrivers"].pop(0)
            report["scenarios"].pop(0)
            plan["skippedScenarioDrivers"] = [
                {"scenario": omitted, "reason": "forged omission"}
            ]

            with self.assertRaisesRegex(
                report_validation.ReportValidationError,
                "selected drivers differ from immutable device-applicable release coverage",
            ):
                report_validation.marker_payload(
                    json.dumps(report).encode(),
                    json.dumps(plan).encode(),
                    report_validation.QUALIFICATION_AUTHORITY,
                )

    def test_reordered_complete_full_report_cannot_receive_a_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "scenarios": [
                        {"scenario": scenario, "result": "pass"}
                        for scenario in RELEASE_SCENARIO_ORDER
                    ],
                },
                selection_scope="full",
            )
            report = json.loads((run / "report.json").read_text())
            plan = json.loads((run / "validation-plan.json").read_text())
            report["scenarios"][0], report["scenarios"][1] = (
                report["scenarios"][1],
                report["scenarios"][0],
            )
            plan["requestedScenarioDrivers"][0], plan["requestedScenarioDrivers"][1] = (
                plan["requestedScenarioDrivers"][1],
                plan["requestedScenarioDrivers"][0],
            )
            plan["selectedScenarioDrivers"][0], plan["selectedScenarioDrivers"][1] = (
                plan["selectedScenarioDrivers"][1],
                plan["selectedScenarioDrivers"][0],
            )
            with self.assertRaisesRegex(
                report_validation.ReportValidationError, "coverage or order"
            ):
                report_validation.marker_payload(
                    json.dumps(report).encode(),
                    json.dumps(plan).encode(),
                    report_validation.QUALIFICATION_AUTHORITY,
                )

    def test_partial_receipt_never_grants_release_scope(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "scenarios": [{"scenario": "analyzer", "result": "pass"}],
                },
            )
            self.assertTrue(report_validation.is_valid(run))
            self.assertFalse(report_validation.is_release_scope_valid(run))

    def test_receipt_rejects_cross_session_report_replay(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "scenarios": [{"scenario": "analyzer", "result": "pass"}],
                },
            )
            report = json.loads((run / "report.json").read_text())
            plan = json.loads((run / "validation-plan.json").read_text())
            plan["orchestratorSessionBinding"] = "8" * 64
            with self.assertRaisesRegex(
                report_validation.ReportValidationError, "orchestrator session"
            ):
                report_validation.marker_payload(
                    json.dumps(report).encode(),
                    json.dumps(plan).encode(),
                    report_validation.QUALIFICATION_AUTHORITY,
                )

    def test_receipt_rejects_report_started_outside_orchestrator_handoff(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "scenarios": [{"scenario": "analyzer", "result": "pass"}],
                },
            )
            report = json.loads((run / "report.json").read_text())
            plan = json.loads((run / "validation-plan.json").read_text())
            plan["orchestratorStartedAtUTC"] = "2020-01-01T00:00:00Z"
            report["orchestratorStartedAtUTC"] = "2020-01-01T00:00:00Z"
            with self.assertRaisesRegex(
                report_validation.ReportValidationError, "handoff window"
            ):
                report_validation.marker_payload(
                    json.dumps(report).encode(),
                    json.dumps(plan).encode(),
                    report_validation.QUALIFICATION_AUTHORITY,
                )

    def test_full_report_recomputes_device_applicable_and_projected_sets(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "scenarios": [
                        {"scenario": scenario, "result": "pass"}
                        for scenario in RELEASE_SCENARIO_ORDER
                    ],
                },
                selection_scope="full",
            )
            current_report = json.loads((run / "report.json").read_text())
            current_plan = json.loads((run / "validation-plan.json").read_text())

            minimum_report = json.loads(json.dumps(current_report))
            minimum_plan = json.loads(json.dumps(current_plan))
            applicable_order = [
                scenario
                for scenario in RELEASE_SCENARIO_ORDER
                if scenario
                not in qualification_policy.IPHONE_CURRENT_ONLY_RUNNER_SCENARIOS
            ]
            minimum_report["device"].update(
                {
                    "deviceFamily": "iPad",
                    "osVersion": "18.0",
                    "osMajor": 18,
                    "matchingHardwareRows": ["ipad-minimum"],
                }
            )
            minimum_report["scenarios"] = [
                {"scenario": scenario, "result": "pass"}
                for scenario in applicable_order
            ]
            minimum_plan["matrixHardwareRows"] = ["ipad-minimum"]
            minimum_plan["selectedScenarioDrivers"] = applicable_order
            minimum_plan["skippedScenarioDrivers"] = [
                {
                    "scenario": scenario,
                    "reason": "not applicable to the selected hardware row",
                }
                for scenario in RELEASE_SCENARIO_ORDER
                if scenario
                in qualification_policy.IPHONE_CURRENT_ONLY_RUNNER_SCENARIOS
            ]
            report_validation.marker_payload(
                json.dumps(minimum_report).encode(),
                json.dumps(minimum_plan).encode(),
                report_validation.QUALIFICATION_AUTHORITY,
            )

            projected_report = json.loads(json.dumps(current_report))
            projected_plan = json.loads(json.dumps(current_plan))
            projected_report["device"].update(
                {
                    "osVersion": "27.0",
                    "osMajor": 27,
                    "osBuild": "24A1a",
                    "osReleaseType": "beta",
                    "matchingHardwareRows": [],
                    "qualificationEligible": False,
                }
            )
            projected_report.update(
                mode="exploratory", qualificationEligibleEnvironment=False
            )
            projected_plan.update(
                mode="exploratory",
                qualificationEligibleEnvironment=False,
                matrixHardwareRows=[],
                projectedHardwareRow="iphone-current",
            )
            report_validation.marker_payload(
                json.dumps(projected_report).encode(),
                json.dumps(projected_plan).encode(),
                report_validation.QUALIFICATION_AUTHORITY,
            )

    def test_plan_hardware_context_cannot_drift_from_report_device(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "scenarios": [{"scenario": "analyzer", "result": "pass"}],
                },
            )
            report = json.loads((run / "report.json").read_text())
            baseline = json.loads((run / "validation-plan.json").read_text())
            mutations = {
                "plan-row-drift": lambda plan: plan.update(
                    matrixHardwareRows=["ipad-current"]
                ),
                "forged-projection": lambda plan: plan.update(
                    projectedHardwareRow="iphone-current"
                ),
                "missing-projection-field": lambda plan: plan.pop(
                    "projectedHardwareRow"
                ),
            }
            for name, mutate in mutations.items():
                with self.subTest(name=name):
                    plan = json.loads(json.dumps(baseline))
                    mutate(plan)
                    with self.assertRaisesRegex(
                        report_validation.ReportValidationError,
                        "do not match the report device|"
                        "does not reconcile with the report device|"
                        "projectedHardwareRow is missing",
                    ):
                        report_validation.marker_payload(
                            json.dumps(report).encode(),
                            json.dumps(plan).encode(),
                            report_validation.QUALIFICATION_AUTHORITY,
                        )

            forged_report = json.loads(json.dumps(report))
            forged_report["device"]["matchingHardwareRows"] = ["ipad-current"]
            forged_plan = json.loads(json.dumps(baseline))
            forged_plan["matrixHardwareRows"] = ["ipad-current"]
            forged_plan["selectionScope"] = "full"
            with self.assertRaisesRegex(
                report_validation.ReportValidationError,
                "do not reconcile with device identity",
            ):
                report_validation.marker_payload(
                    json.dumps(forged_report).encode(),
                    json.dumps(forged_plan).encode(),
                    report_validation.QUALIFICATION_AUTHORITY,
                )

    def test_marker_write_refuses_a_changed_retained_plan(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "scenarios": [{"scenario": "analyzer", "result": "pass"}],
                },
            )
            report_bytes = (run / "report.json").read_bytes()
            plan_bytes = (run / "validation-plan.json").read_bytes()
            (run / report_validation.MARKER_FILENAME).unlink()
            plan = json.loads(plan_bytes)
            plan["selectionScope"] = "full"
            report_validation.atomic_write_json(run / "validation-plan.json", plan)

            with self.assertRaisesRegex(
                report_validation.ReportValidationError,
                "plan changed after validation",
            ):
                report_validation.write_marker_for_bytes(
                    run,
                    report_bytes,
                    plan_bytes,
                    report_validation.QUALIFICATION_AUTHORITY,
                    validated_evidence_manifest=(
                        report_validation.evidence_tree_manifest(run)
                    ),
                )
            self.assertFalse((run / report_validation.MARKER_FILENAME).exists())

    def test_marker_write_failure_removes_partial_receipt_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "scenarios": [{"scenario": "analyzer", "result": "pass"}],
                },
            )
            report_bytes = (run / "report.json").read_bytes()
            plan_bytes = (run / "validation-plan.json").read_bytes()
            (run / report_validation.MARKER_FILENAME).unlink()
            (run / report_validation.EVIDENCE_MANIFEST_FILENAME).unlink()
            evidence_manifest = report_validation.evidence_tree_manifest(run)
            atomic_write_json = report_validation.atomic_write_json

            def fail_marker_write(path: Path, value: object) -> None:
                if path.name == report_validation.MARKER_FILENAME:
                    raise OSError("simulated receipt interruption")
                atomic_write_json(path, value)

            with mock.patch.object(
                report_validation,
                "atomic_write_json",
                side_effect=fail_marker_write,
            ):
                with self.assertRaisesRegex(
                    OSError, "simulated receipt interruption"
                ):
                    report_validation.write_marker_for_bytes(
                        run,
                        report_bytes,
                        plan_bytes,
                        report_validation.QUALIFICATION_AUTHORITY,
                        validated_evidence_manifest=evidence_manifest,
                    )

            self.assertFalse(
                (run / report_validation.MARKER_FILENAME).exists()
            )
            self.assertFalse(
                (run / report_validation.EVIDENCE_MANIFEST_FILENAME).exists()
            )

    def test_atomic_json_writer_preserves_the_previous_file_on_replace_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "owned.json"
            path.write_text('{"old":true}\n')
            with mock.patch.object(
                report_validation.os,
                "replace",
                side_effect=OSError("simulated interruption"),
            ):
                with self.assertRaises(OSError):
                    report_validation.atomic_write_json(path, {"new": True})

            self.assertEqual(path.read_text(), '{"old":true}\n')
            self.assertEqual(list(path.parent.glob(".owned.json.*.tmp")), [])

    def test_report_only_validation_marks_only_its_narrow_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "releaseGateReason": (
                        "exploratory cadence semantics probe cannot produce "
                        "release credit"
                    ),
                    "scenarios": [cadence_report_only_scenario()],
                },
                selection_scope="partial",
                report_only=True,
            )
            (run / report_validation.MARKER_FILENAME).unlink()

            runtime_policy = sys.modules["qualification_policy"]
            with mock.patch.object(
                runtime_policy, "validate_report_only_cadence_report"
            ) as validate_probe:
                report_validation.validate_and_mark(
                    run,
                    matrix_path=None,
                    candidate_path=run / "candidate-metadata.json",
                    report_only=True,
                )
            validate_probe.assert_called_once()

            self.assertTrue(report_validation.is_valid(run))

    def test_report_only_validation_rejects_device_snapshot_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "releaseGateReason": (
                        "exploratory cadence semantics probe cannot produce "
                        "release credit"
                    ),
                    "scenarios": [cadence_report_only_scenario()],
                },
                selection_scope="partial",
                report_only=True,
            )
            (run / report_validation.MARKER_FILENAME).unlink()
            (run / "device.json").write_bytes(
                (run / "device.json").read_bytes() + b" "
            )

            with self.assertRaisesRegex(
                report_validation.ReportValidationError,
                "snapshot binding mismatch",
            ):
                report_validation.validate_and_mark(
                    run,
                    matrix_path=None,
                    candidate_path=run / "candidate-metadata.json",
                    report_only=True,
                )

            self.assertFalse(
                (run / report_validation.MARKER_FILENAME).exists()
            )

    def test_report_only_validation_rejects_mode_eligibility_tampering(self):
        for mode, eligible, forged_eligible in (
            ("qualification", True, False),
            ("exploratory", False, True),
        ):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                run = Path(directory)
                write_validated_report(
                    run,
                    {
                        "result": "pass",
                        "releaseGateReason": (
                            "exploratory cadence semantics probe cannot produce "
                            "release credit"
                        ),
                        "scenarios": [cadence_report_only_scenario()],
                    },
                    selection_scope="partial",
                    mode=mode,
                    qualification_eligible=eligible,
                    report_only=True,
                )
                for name in ("report.json", "validation-plan.json"):
                    value = json.loads((run / name).read_text())
                    value["qualificationEligibleEnvironment"] = forged_eligible
                    report_validation.atomic_write_json(run / name, value)

                runtime_policy = sys.modules["qualification_policy"]
                with mock.patch.object(
                    runtime_policy, "validate_report_only_cadence_report"
                ):
                    with self.assertRaisesRegex(
                        report_validation.ReportValidationError,
                        "mode/eligibility differs from retained selected device",
                    ):
                        report_validation.validate_and_mark(
                            run,
                            matrix_path=None,
                            candidate_path=run / "candidate-metadata.json",
                            report_only=True,
                        )

                self.assertFalse(
                    (run / report_validation.MARKER_FILENAME).exists()
                )
                self.assertFalse(
                    (run / report_validation.EVIDENCE_MANIFEST_FILENAME).exists()
                )

    def test_report_only_validation_rejects_evidence_changed_after_semantic_read(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "releaseGateReason": (
                        "exploratory cadence semantics probe cannot produce "
                        "release credit"
                    ),
                    "scenarios": [cadence_report_only_scenario()],
                },
                selection_scope="partial",
                report_only=True,
            )

            runtime_policy = sys.modules["qualification_policy"]

            def mutate_after_snapshot_read(_snapshot: Path, _report: dict) -> None:
                device_path = run / "device.json"
                device_path.write_bytes(device_path.read_bytes() + b" ")

            with mock.patch.object(
                runtime_policy,
                "validate_report_only_cadence_report",
                side_effect=mutate_after_snapshot_read,
            ):
                with self.assertRaisesRegex(
                    report_validation.ReportValidationError,
                    "evidence tree changed during validation",
                ):
                    report_validation.validate_and_mark(
                        run,
                        matrix_path=None,
                        candidate_path=run / "candidate-metadata.json",
                        report_only=True,
                    )

            self.assertFalse(
                (run / report_validation.MARKER_FILENAME).exists()
            )
            self.assertFalse(
                (run / report_validation.EVIDENCE_MANIFEST_FILENAME).exists()
            )

    def test_report_only_validation_requires_strict_sibling_candidate(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "releaseGateReason": (
                        "exploratory cadence semantics probe cannot produce "
                        "release credit"
                    ),
                    "scenarios": [cadence_report_only_scenario()],
                },
                selection_scope="partial",
                report_only=True,
            )
            (run / report_validation.MARKER_FILENAME).unlink()

            for label, candidate_path, expected in (
                ("missing", None, "requires sibling candidate-metadata.json"),
                (
                    "not-sibling",
                    run.parent / "candidate-metadata.json",
                    "must be sibling candidate-metadata.json",
                ),
            ):
                with self.subTest(label=label):
                    with self.assertRaisesRegex(
                        report_validation.ReportValidationError, expected
                    ):
                        report_validation.validate_and_mark(
                            run,
                            matrix_path=None,
                            candidate_path=candidate_path,
                            report_only=True,
                        )

    def test_report_only_validation_rejects_malformed_candidate_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "releaseGateReason": (
                        "exploratory cadence semantics probe cannot produce "
                        "release credit"
                    ),
                    "scenarios": [cadence_report_only_scenario()],
                },
                selection_scope="partial",
                report_only=True,
            )
            (run / report_validation.MARKER_FILENAME).unlink()
            candidate_path = run / "candidate-metadata.json"
            baseline = json.loads(candidate_path.read_text())

            runtime_policy = sys.modules["qualification_policy"]
            mutations = {
                "missing-runner-digest": (
                    lambda value: value.pop("testRunnerDigest"),
                    "no valid testRunnerDigest",
                ),
                "wrong-policy-digest": (
                    lambda value: value.update(qualificationPolicyDigest="9" * 64),
                    "qualification policy digest mismatch",
                ),
            }
            for label, (mutate, expected) in mutations.items():
                with self.subTest(label=label):
                    candidate = json.loads(json.dumps(baseline))
                    mutate(candidate)
                    report_validation.atomic_write_json(candidate_path, candidate)
                    with mock.patch.object(
                        runtime_policy, "validate_report_only_cadence_report"
                    ):
                        with self.assertRaisesRegex(
                            report_validation.ReportValidationError, expected
                        ):
                            report_validation.validate_and_mark(
                                run,
                                matrix_path=None,
                                candidate_path=candidate_path,
                                report_only=True,
                            )

    def test_report_only_validation_rejects_candidate_identity_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "releaseGateReason": (
                        "exploratory cadence semantics probe cannot produce "
                        "release credit"
                    ),
                    "scenarios": [cadence_report_only_scenario()],
                },
                selection_scope="partial",
                report_only=True,
            )
            (run / report_validation.MARKER_FILENAME).unlink()
            candidate_path = run / "candidate-metadata.json"
            baseline = json.loads(candidate_path.read_text())

            runtime_policy = sys.modules["qualification_policy"]
            for field in (
                "candidateAppDigest",
                "qualificationMatrixChecksum",
                "fixtureManifestChecksum",
            ):
                with self.subTest(field=field):
                    candidate = json.loads(json.dumps(baseline))
                    candidate[field] = "9" * 64
                    report_validation.atomic_write_json(candidate_path, candidate)
                    with mock.patch.object(
                        runtime_policy, "validate_report_only_cadence_report"
                    ):
                        expected = (
                            "candidate build attestation candidateAppDigest does not "
                            "match candidate metadata"
                            if field == "candidateAppDigest"
                            else (
                                "report-only report/candidate identity "
                                f"{field} mismatch"
                            )
                        )
                        with self.assertRaisesRegex(
                            report_validation.ReportValidationError,
                            expected,
                        ):
                            report_validation.validate_and_mark(
                                run,
                                matrix_path=None,
                                candidate_path=candidate_path,
                                report_only=True,
                            )

    def test_report_only_receipt_rejects_fabricated_failed_report(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "releaseGateReason": (
                        "exploratory cadence semantics probe cannot produce "
                        "release credit"
                    ),
                    "scenarios": [cadence_report_only_scenario()],
                },
                selection_scope="partial",
                report_only=True,
            )
            baseline = json.loads((run / "report.json").read_text())
            plan_bytes = (run / "validation-plan.json").read_bytes()
            mutations = {
                "top-level-fail": lambda value: value.update(result="fail"),
                "runner-fail": lambda value: value["scenarios"][0].update(
                    result="fail", xcodebuildExitCode=65
                ),
                "skipped-test": lambda value: value["scenarios"][0][
                    "testExecution"
                ].update(allPassed=False),
                "release-gate": lambda value: value.update(
                    releaseGateSatisfied=True
                ),
                "qualification-row": lambda value: value.update(
                    qualificationRows=[{"scenario": "cadence-matrix"}]
                ),
                "payload-release-credit": lambda value: value["scenarios"][0][
                    "reportOnlyEvidence"
                ].update(releaseCreditEligible=True),
                "beta-to-stable-relabel": lambda value: value.update(
                    version="1.1.0"
                ),
            }
            for label, mutate in mutations.items():
                with self.subTest(label=label):
                    forged = json.loads(json.dumps(baseline))
                    mutate(forged)
                    with self.assertRaisesRegex(
                        report_validation.ReportValidationError,
                        "report-only contract failed",
                    ):
                        report_validation.marker_payload(
                            json.dumps(forged).encode(),
                            plan_bytes,
                            report_validation.REPORT_ONLY_AUTHORITY,
                        )

    def test_duplicate_keys_cannot_forge_a_validation_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "scenarios": [{"scenario": "analyzer", "result": "pass"}],
                },
            )
            marker_path = run / report_validation.MARKER_FILENAME
            marker = json.loads(marker_path.read_text())
            marker_path.write_text(
                "{"
                '"formatVersion":2,'
                '"formatVersion":2,'
                f'"reportSHA256":"{marker["reportSHA256"]}",'
                f'"validationAuthority":"{marker["validationAuthority"]}",'
                f'"validationPlanSHA256":"{marker["validationPlanSHA256"]}",'
                '"validationResult":"passed"'
                "}\n"
            )

            self.assertFalse(report_validation.is_valid(run))


class QualificationWatchdogTests(unittest.TestCase):
    def test_success_preserves_combined_output_and_child_exit_code(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "command.log"

            exit_code = run_with_watchdog.run(
                [
                    sys.executable,
                    "-c",
                    (
                        "import sys; "
                        "print('standard output', flush=True); "
                        "print('standard error', file=sys.stderr, flush=True); "
                        "raise SystemExit(7)"
                    ),
                ],
                wall_seconds=5,
                idle_seconds=2,
                grace_seconds=0.2,
                output_path=output,
            )

            self.assertEqual(exit_code, 7)
            self.assertEqual(
                output.read_text(), "standard output\nstandard error\n"
            )

    def test_idle_timeout_is_distinct_and_retained(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "command.log"

            exit_code = run_with_watchdog.run(
                [
                    sys.executable,
                    "-c",
                    "import time; print('ready', flush=True); time.sleep(30)",
                ],
                wall_seconds=5,
                idle_seconds=0.2,
                grace_seconds=0.2,
                output_path=output,
            )

            self.assertEqual(exit_code, run_with_watchdog.IDLE_TIMEOUT_EXIT)
            self.assertIn("output-idle timeout", output.read_text())

    def test_wall_timeout_wins_when_output_remains_active(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "command.log"
            program = (
                "import time\n"
                "while True:\n"
                " print('heartbeat', flush=True)\n"
                " time.sleep(0.05)\n"
            )

            exit_code = run_with_watchdog.run(
                [sys.executable, "-c", program],
                wall_seconds=0.3,
                idle_seconds=2,
                grace_seconds=0.2,
                output_path=output,
            )

            self.assertEqual(exit_code, run_with_watchdog.WALL_TIMEOUT_EXIT)
            self.assertIn("wall-clock timeout", output.read_text())

    def test_reusing_a_log_path_replaces_stale_output(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "command.log"
            for value in ("stale", "current"):
                self.assertEqual(
                    run_with_watchdog.run(
                        [sys.executable, "-c", f"print({value!r}, flush=True)"],
                        wall_seconds=5,
                        idle_seconds=2,
                        grace_seconds=0.2,
                        output_path=output,
                    ),
                    0,
                )

            self.assertEqual(output.read_text(), "current\n")

    def test_termination_signal_cancels_the_complete_child_process_group(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "command.log"
            child_pid_path = root / "child.pid"
            program = (
                "import os,time\n"
                f"open({str(child_pid_path)!r}, 'w').write(str(os.getpid()))\n"
                "print('ready', flush=True)\n"
                "time.sleep(30)\n"
            )
            wrapper = subprocess.Popen(
                [
                    sys.executable,
                    str(ROOT / "qualification" / "run-with-watchdog.py"),
                    "--wall-seconds",
                    "60",
                    "--idle-seconds",
                    "60",
                    "--grace-seconds",
                    "0.2",
                    "--output",
                    str(output),
                    "--",
                    sys.executable,
                    "-c",
                    program,
                ],
                stderr=subprocess.PIPE,
                text=True,
            )
            child_pid = None
            try:
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline and not child_pid_path.exists():
                    time.sleep(0.02)
                self.assertTrue(child_pid_path.exists())
                child_pid = int(child_pid_path.read_text())

                os.kill(wrapper.pid, signal.SIGTERM)

                self.assertEqual(wrapper.wait(timeout=3), 143)
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    try:
                        os.kill(child_pid, 0)
                    except ProcessLookupError:
                        break
                    time.sleep(0.02)
                else:
                    self.fail("watchdog cancellation left its child process alive")
                self.assertIn("received signal 15", output.read_text())
            finally:
                if wrapper.poll() is None:
                    wrapper.kill()
                    wrapper.wait(timeout=3)
                if wrapper.stderr is not None:
                    wrapper.stderr.close()
                if child_pid is not None:
                    try:
                        os.kill(child_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_normal_leader_exit_cannot_leave_a_background_helper_running(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "command.log"
            helper_pid_path = root / "helper.pid"
            program = (
                "import subprocess\n"
                f"path = {str(helper_pid_path)!r}\n"
                "helper = subprocess.Popen(['sleep', '30'])\n"
                "open(path, 'w').write(str(helper.pid))\n"
                "print('leader complete', flush=True)\n"
            )

            self.assertEqual(
                run_with_watchdog.run(
                    [sys.executable, "-c", program],
                    wall_seconds=5,
                    idle_seconds=2,
                    grace_seconds=0.2,
                    output_path=output,
                ),
                0,
            )
            helper_pid = int(helper_pid_path.read_text())
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                try:
                    os.kill(helper_pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.02)
            else:
                try:
                    os.kill(helper_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                self.fail("watchdog left a background helper running after leader exit")


class ReleaseSourceDigestQualificationOutputTests(unittest.TestCase):
    def test_generated_report_tree_is_outside_the_release_source_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(
                ["git", "-C", str(root), "config", "user.email", "fixture@example.com"],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(root), "config", "user.name", "Fixture"],
                check=True,
            )
            (root / "README.md").write_text("release source\n")
            subprocess.run(
                ["git", "-C", str(root), "add", "README.md"], check=True
            )
            subprocess.run(
                ["git", "-C", str(root), "commit", "-qm", "fixture"], check=True
            )
            before = release_source_digest.source_digest(root, "1.1.0")
            reports = root / "scripts" / "qualification" / "reports" / "1.1.0"
            reports.mkdir(parents=True)
            (reports / "assembled-device" / "report.json").parent.mkdir()
            (reports / "assembled-device" / "report.json").write_text("{}\n")

            after = release_source_digest.source_digest(root, "1.1.0")

            self.assertEqual(before, after)
            (root / "unreviewed.swift").write_text("fatalError()\n")
            with self.assertRaisesRegex(SystemExit, "untracked release source"):
                release_source_digest.source_digest(root, "1.1.0")


class QualificationRunnerStorageTests(unittest.TestCase):
    def test_runner_uses_one_private_exact_commit_source_authority(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()

        capture_index = script.index("SOURCE_AUTHORITY_COMMIT_START=$(jq")
        clone_index = script.index(
            'git clone --quiet --no-checkout --no-local "$ROOT_DIR" '
            '"$SOURCE_AUTHORITY_ROOT"'
        )
        checkout_index = script.index(
            'git -C "$SOURCE_AUTHORITY_ROOT" checkout --quiet --detach'
        )
        pinned_check_index = script.index("PINNED_SOURCE_AUTHORITY_IDENTITY=$(")
        self.assertLess(capture_index, clone_index)
        self.assertLess(clone_index, checkout_index)
        self.assertLess(checkout_index, pinned_check_index)
        self.assertNotIn("archive HEAD", script)
        self.assertEqual(
            script.count(
                'git -C "$SOURCE_AUTHORITY_ROOT" archive '
                '"$SOURCE_AUTHORITY_COMMIT_START"'
            ),
            1,
        )
        self.assertIn(
            '--source-authority "$SOURCE_AUTHORITY_ROOT"',
            script,
        )
        self.assertNotIn('--source-authority "$ROOT_DIR"', script)
        self.assertIn('chflags -R uchg "$SOURCE_AUTHORITY_ROOT"', script)

    def test_exact_commit_checkout_recipe_does_not_follow_a_moved_head(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            authority = root / "authority"
            subprocess.run(["git", "init", "-q", str(source)], check=True)
            subprocess.run(
                ["git", "-C", str(source), "config", "user.email", "fixture@example.com"],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(source), "config", "user.name", "Fixture"],
                check=True,
            )
            tracked = source / "tracked.txt"
            tracked.write_text("captured\n")
            subprocess.run(["git", "-C", str(source), "add", "tracked.txt"], check=True)
            subprocess.run(["git", "-C", str(source), "commit", "-qm", "captured"], check=True)
            captured = subprocess.run(
                ["git", "-C", str(source), "rev-parse", "HEAD"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()

            tracked.write_text("moved head\n")
            subprocess.run(["git", "-C", str(source), "commit", "-qam", "moved"], check=True)
            subprocess.run(
                [
                    "git",
                    "clone",
                    "--quiet",
                    "--no-checkout",
                    "--no-local",
                    str(source),
                    str(authority),
                ],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(authority), "checkout", "--quiet", "--detach", captured],
                check=True,
            )

            self.assertEqual((authority / "tracked.txt").read_text(), "captured\n")
            self.assertEqual(
                subprocess.run(
                    ["git", "-C", str(authority), "rev-parse", "HEAD"],
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout.strip(),
                captured,
            )

    def test_materialization_optional_arguments_work_with_system_bash_nounset(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        line = next(line.strip() for line in script.splitlines()
                    if "materialize_extra_args[@]" in line)
        expansion = line.removesuffix(" " + chr(92))
        for elements, expected in (("", ["start", "end"]),
                                   ('--sample "value with spaces"',
                                    ["start", "--sample", "value with spaces", "end"])):
            with self.subTest(elements=elements):
                program = f'materialize_extra_args=({elements}); values=(start {expansion} end); printf "%s\\n" "${{values[@]}}"'
                result = subprocess.run(["/bin/bash", "-uc", program],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), expected)

    def test_install_falls_back_only_after_configurator_failure(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        body = script[script.index("install_app() {"):script.index("install_candidate_with_fresh_permission_state()")]
        for config_status, device_status, expected in ((0, 0, 0), (1, 0, 0), (1, 7, 7)):
            with self.subTest(config_status=config_status, device_status=device_status), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                configurator = root / "cfgutil"
                configurator.write_text(f"#!/bin/bash\nexit {config_status}\n")
                configurator.chmod(0o755)
                program = body.replace("/Applications/Apple Configurator.app/Contents/MacOS/cfgutil", str(configurator))
                program += f"\nassert_device_lock_held() {{ :; }}\nxcrun() {{ echo FALLBACK; return {device_status}; }}\ninstall_app '/tmp/candidate with spaces.app'\n"
                result = subprocess.run(["bash", "-c", program], capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual("FALLBACK" in result.stdout, config_status != 0)

    def test_runner_proves_device_lock_ownership_at_mutation_and_seal_boundaries(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        assertion = script[
            script.index("assert_device_lock_held() {") : script.index(
                "assert_device_lock_held\n", script.index("assert_device_lock_held() {")
            )
        ]
        for argument in (
            "--assert-held",
            '--device-identifier "$DEVICE_UDID"',
            '--parent-pid "$$"',
            '--owner-pid "$DEVICE_LOCK_PID"',
        ):
            self.assertIn(argument, assertion)

        install_start = script.index("install_app() {")
        install_end = script.index("install_candidate_with_fresh_permission_state()")
        install_body = script[install_start:install_end]
        self.assertLess(
            install_body.index("assert_device_lock_held"),
            min(
                install_body.index('"$configurator" --ecid'),
                install_body.index("xcrun devicectl device install app"),
            ),
        )
        uninstall_index = script.index("xcrun devicectl device uninstall app")
        self.assertEqual(
            script.rfind("assert_device_lock_held", 0, uninstall_index),
            script.rfind("assert_device_lock_held", install_end, uninstall_index),
        )

        scenario_start = script.index("run_scenario() {")
        scenario_end = script.index(
            'for scenario in "${ONLY_SCENARIOS[@]}"; do\n  run_scenario "$scenario"',
            scenario_start,
        )
        scenario_body = script[scenario_start:scenario_end]
        self.assertLess(
            scenario_body.index("assert_device_lock_held"),
            scenario_body.index('case "$scenario" in'),
        )
        self.assertLess(
            scenario_body.rindex("assert_device_lock_held"),
            scenario_body.rindex('echo "$scenario: $result"'),
        )

        report_index = script.index(
            'python3 - \\\n  "$RESULTS_TSV" "$OUTPUT_DIR/report.json"'
        )
        validation_index = script.index(
            'python3 "$SCRIPT_DIR/report_validation.py"'
        )
        self.assertEqual(
            script[script.rfind("\n", 0, report_index - 1) + 1 : report_index],
            "assert_device_lock_held\n",
        )
        self.assertEqual(
            script[script.rfind("\n", 0, validation_index - 1) + 1 : validation_index],
            "assert_device_lock_held\n",
        )

    def test_runner_default_and_full_selection_use_canonical_release_order(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        assignments = re.findall(
            r"(?m)^DEFAULT_SCENARIOS(?:\+)?=\((?P<body>[^)]*)\)$",
            script,
        )
        runner_order = tuple(
            token.strip('"\'')
            for assignment in assignments
            for token in assignment.split()
        )
        self.assertEqual(runner_order, RELEASE_SCENARIO_ORDER)
        self.assertEqual(runner_order[-1], "audio-media-services-reset")

        full_selection = script[
            script.index('if [[ "$FULL_SUITE_SELECTION" == true ]]') : script.index(
                'requested_scenarios_file="$WORK_DIR/requested-scenarios.txt"'
            )
        ]
        self.assertNotIn("| sort", full_selection)
        self.assertIn(
            '<(printf \'%s\\n\' "${EXPECTED_FULL_SCENARIOS[@]}")',
            full_selection,
        )
        self.assertIn(
            '<(printf \'%s\\n\' "${ONLY_SCENARIOS[@]}")',
            full_selection,
        )

    def test_runner_current_only_filter_matches_release_policy(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        match = re.search(
            r"(?ms)^IPHONE_CURRENT_ONLY_SCENARIOS=\(\n(?P<body>.*?)^\)\n",
            script,
        )
        self.assertIsNotNone(match)
        shell_scenarios = {
            line.strip().strip('"\'')
            for line in match.group("body").splitlines()
            if line.strip()
        }

        self.assertEqual(
            shell_scenarios,
            set(qualification_policy.IPHONE_CURRENT_ONLY_RUNNER_SCENARIOS),
        )
        self.assertIn("playback-foreground-displaylayer-recovery", shell_scenarios)
        self.assertEqual(
            script.count('scenario_requires_iphone_current "$scenario"'),
            3,
            "rejection, filtering, and full-scope validation must share one helper",
        )

    def test_runner_requires_the_release_oracle_decoder_tools(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        self.assertIn(
            "for command in chflags curl ffmpeg ffprobe git jq plutil python3 shasum tar xcodebuild xcrun",
            script,
        )

    def test_runner_prefers_the_wired_coredevice_tunnel_for_fixture_delivery(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        self.assertIn(
            "DEVICE_TUNNEL_IP=$(jq -r '.selected.tunnelIPAddress // empty'",
            script,
        )
        self.assertIn('python3 "$SCRIPT_DIR/tunnel-host.py"', script)
        self.assertIn(
            'fixture_server_args+=(--host :: --advertise-host "$TUNNEL_HOST")',
            script,
        )
        self.assertIn(
            "CoreDevice tunnel discovery failed; falling back to the LAN fixture address.",
            script,
        )

    def test_runner_retains_interrupted_progress_outside_the_cleanup_root(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        self.assertIn('REQUESTED_SCENARIOS=("${ONLY_SCENARIOS[@]}")', script)
        self.assertIn('python3 "$SCRIPT_DIR/validation-plan.py"', script)
        self.assertIn('--output "$OUTPUT_DIR/validation-plan.json"', script)
        self.assertIn('--selection-scope "$VALIDATION_SELECTION_SCOPE"', script)
        self.assertIn(
            'report_validation_args=(\n  validate-and-mark\n  --run-dir "$OUTPUT_DIR"',
            script,
        )
        self.assertIn('--candidate "$CANDIDATE_IDENTITY"', script)
        self.assertNotIn('report_validation.py" mark', script)
        self.assertIn(
            'RESULTS_TSV="$OUTPUT_DIR/scenario-results.tsv"',
            script,
        )
        self.assertIn(
            'QUALIFICATION_ROWS="$OUTPUT_DIR/qualification-rows.jsonl"',
            script,
        )
        self.assertNotIn('RESULTS_TSV="$WORK_DIR/results.tsv"', script)
        self.assertNotIn(
            'QUALIFICATION_ROWS="$WORK_DIR/qualification-rows.jsonl"',
            script,
        )
        plan_index = script.index('python3 "$SCRIPT_DIR/validation-plan.py"')
        fixture_index = script.index('if [[ ! -f "$FIXTURES/manifest.json"')
        install_index = script.index('install_app "$RUNNER_APP"')
        self.assertLess(plan_index, fixture_index)
        self.assertLess(plan_index, install_index)
        self.assertEqual(script.count("DEFAULT_SCENARIOS=("), 1)

    def test_fixture_server_is_reaped_before_the_evidence_tree_is_sealed(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        final_scenario_loop = script.index(
            'for scenario in "${ONLY_SCENARIOS[@]}"; do\n  run_scenario "$scenario"'
        )
        stop_index = script.index("stop_fixture_server", final_scenario_loop)
        report_index = script.index('"$RESULTS_TSV" "$OUTPUT_DIR/report.json"', stop_index)
        receipt_index = script.index(
            'python3 "$SCRIPT_DIR/report_validation.py"', report_index
        )

        self.assertLess(stop_index, report_index)
        self.assertLess(stop_index, receipt_index)

    def test_runner_report_binds_the_retained_normalized_device_snapshot(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()

        self.assertIn(
            "device_snapshot = policy.device_snapshot_binding(Path(output_path).parent)",
            script,
        )
        self.assertIn('"deviceSnapshot": device_snapshot', script)

    def test_runner_primes_the_exact_installed_xctrunner_before_tests(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        install_index = script.index('install_app "$RUNNER_APP"')
        prime_index = script.index('"$SCRIPT_DIR/prime-xctrunner.sh"', install_index)
        test_index = script.index(
            'for scenario in "${ONLY_SCENARIOS[@]}"; do\n  run_scenario "$scenario"',
            prime_index,
        )

        self.assertLess(install_index, prime_index)
        self.assertLess(prime_index, test_index)
        prime_source = script[prime_index:test_index]
        self.assertIn('--device "$DEVICE_UDID"', prime_source)
        self.assertIn('"$TEST_RUNNER_BUNDLE_IDENTIFIER"', prime_source)
        self.assertNotIn('"$TEST_RUNNER_BUNDLE_IDENTIFIER.xctrunner"', prime_source)

    def test_every_xcode_test_invocation_uses_the_configured_derived_data(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        lines = script.splitlines()
        commands = []
        for index, line in enumerate(lines):
            if "xcodebuild test-without-building" not in line:
                continue
            command = [line]
            while command[-1].rstrip().endswith("\\"):
                index += 1
                command.append(lines[index])
            commands.append("\n".join(command))

        self.assertGreater(len(commands), 0)
        for command in commands:
            self.assertIn('-derivedDataPath "$DERIVED_DATA"', command)

    def test_every_xcode_test_invocation_disables_parallel_testing(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        lines = script.splitlines()
        commands = []
        for index, line in enumerate(lines):
            if "xcodebuild test-without-building" not in line:
                continue
            command = [line]
            while command[-1].rstrip().endswith("\\"):
                index += 1
                command.append(lines[index])
            commands.append("\n".join(command))

        self.assertGreater(len(commands), 0)
        for command in commands:
            self.assertEqual(command.count("-parallel-testing-enabled NO"), 1)
            self.assertNotIn("-parallel-testing-enabled YES", command)

    def test_physical_ui_tests_fail_closed_on_unrecognized_permission_alerts(self):
        support_path = (
            ROOT.parent
            / "Showcase"
            / "UITests"
            / "iOS"
            / "Support"
            / "ShowcaseIOSTestCase.swift"
        )
        support = support_path.read_text()
        permission_support = support_path.with_name(
            "QualificationLocalNetworkPermission.swift"
        ).read_text()
        permission_sources = support + permission_support
        info = plistlib.loads(
            (ROOT.parent / "Showcase" / "iOS" / "Info.plist").read_bytes()
        )
        purpose = info["NSLocalNetworkUsageDescription"]
        tests_root = ROOT.parent / "Showcase" / "UITests" / "iOS" / "Tests"
        test_sources = "\n".join(
            path.read_text() for path in tests_root.glob("*.swift")
        )

        self.assertEqual(permission_sources.count("addUIInterruptionMonitor"), 1)
        self.assertIn(f'"{purpose}"', permission_support)
        self.assertIn(
            "environment[Self.deviceLogPrefixEnvironment] != nil",
            permission_support,
        )
        for contract in (
            "alert.elementType == .alert",
            'format: "label == %@"',
            'affirmativeButtonLabel = "Allow"',
            "alert.buttons[affirmativeButtonLabel]",
            "grant.label == affirmativeButtonLabel",
            "grant.isHittable",
            "bundleIdentifier: contract.springBoardBundleIdentifier",
            "Refusing to interact with an unrecognized or unready SpringBoard alert",
            "initialAppearanceTimeout: TimeInterval = 10",
            "repeatedAppearanceTimeout: TimeInterval = 0.5",
            "controlReadinessTimeout: TimeInterval = 5",
            "while alert.exists",
            "alert.waitForNonExistence(timeout:",
            "ProcessInfo.processInfo.systemUptime",
        ):
            self.assertIn(contract, permission_support)
        self.assertNotIn("alert.waitForExistence(timeout:", permission_support)
        launch_helper = support[
            support.index("private func launchOrAttach()") : support.index(
                "// MARK: - Log assertions"
            )
        ]
        self.assertIn("handleQualificationLocalNetworkPermissionIfPresent()", launch_helper)
        self.assertNotIn("app.tap()", permission_sources)
        self.assertNotIn("buttons.element(boundBy:", permission_sources)
        self.assertNotIn("addUIInterruptionMonitor", test_sources)

    def test_every_direct_ui_test_launch_uses_the_permission_safe_wrapper(self):
        tests_root = ROOT.parent / "Showcase" / "UITests" / "iOS" / "Tests"
        ui_test_sources = {
            path.name: path.read_text()
            for path in tests_root.glob("*.swift")
        }
        all_test_sources = "\n".join(ui_test_sources.values())

        self.assertGreater(len(ui_test_sources), 0)
        wrapper_uses = 0
        for name, source in ui_test_sources.items():
            self.assertNotIn(
                "app.launch()",
                source,
                f"{name} bypasses the fail-closed permission-safe launch wrapper",
            )
            self.assertNotIn(
                "app.tap()",
                source,
                f"{name} contains a blind candidate tap",
            )
            wrapper_uses += source.count(
                "launchDirectlyHandlingQualificationPermissions()"
            )
        self.assertGreaterEqual(wrapper_uses, 55)

        direct_handler_calls = re.findall(
            r"handleQualificationLocalNetworkPermissionIfPresent\(([^)]*)\)",
            all_test_sources,
        )
        self.assertGreaterEqual(len(direct_handler_calls), 1)
        self.assertTrue(
            all(not arguments.strip() for arguments in direct_handler_calls),
            "Direct permission-handler calls must use the current no-argument contract",
        )

    def test_physical_pip_capability_waits_for_the_enabled_path(self):
        source = (
            ROOT.parent
            / "Showcase"
            / "UITests"
            / "iOS"
            / "Tests"
            / "PiPUITests.swift"
        ).read_text()
        test_start = source.index(
            "func test_deep_toggleButtonAvailabilityMatchesPiPPossibility()"
        )
        test_end = source.index("\n  // MARK: - Stress", test_start)
        body = source[test_start:test_end]
        physical = body[body.index("#else") : body.index("#endif")]

        self.assertIn("#if targetEnvironment(simulator)", body)
        self.assertIn(
            'waitForLabel(possibleLabel, equals: "yes", timeout: 30)',
            physical,
        )
        self.assertIn("assertEnabledPiPToggle()", physical)
        self.assertNotIn('case "no"', physical)

    def test_runner_resets_permission_state_only_for_disposable_candidate(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        reset_start = script.index(
            "install_candidate_with_fresh_permission_state()"
        )
        reset_end = script.index(
            "install_candidate_with_fresh_permission_state\n", reset_start
        )
        reset = script[reset_start:reset_end]

        self.assertIn(
            'if [[ "$CANDIDATE_BUNDLE_IDENTIFIER" == '
            "com.swiftvlc.validation.* ]]; then",
            reset,
        )
        self.assertEqual(reset.count("device uninstall app"), 1)
        self.assertIn('--device "$DEVICE_UDID" "$CANDIDATE_BUNDLE_IDENTIFIER"', reset)
        bootstrap = reset.index('install_app "$CANDIDATE_APP"')
        uninstall = reset.index("device uninstall app", bootstrap)
        final_install = reset.index('install_app "$CANDIDATE_APP"', uninstall)
        self.assertLess(bootstrap, uninstall)
        self.assertLess(uninstall, final_install)
        self.assertIn(
            "outside the disposable com.swiftvlc.validation.* namespace",
            reset,
        )
        self.assertIn(
            "enable Local Network access in Settings > Privacy & Security > Local Network",
            reset,
        )
        self.assertEqual(script.count("device uninstall app"), 1)

    def test_every_xcodebuild_invocation_has_wall_and_idle_watchdogs(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        command_count = len(
            re.findall(r"(?m)^\s*xcodebuild(?:\s|$)", script)
        )
        watchdog_call_count = len(
            re.findall(r"(?m)^\s*(?:if ! )?run_with_watchdog\s", script)
        )

        self.assertGreater(command_count, 0)
        self.assertEqual(watchdog_call_count, command_count)
        self.assertIn('python3 "$SCRIPT_DIR/run-with-watchdog.py"', script)

    def test_cadence_probe_shared_timing_contract_bounds_every_success_path(self):
        ui_test = (
            ROOT.parent
            / "Showcase"
            / "UITests"
            / "iOS"
            / "Tests"
            / "PiPCadenceSemanticsProbeDeviceUITests.swift"
        ).read_text()
        app_probe = (
            ROOT.parent
            / "Showcase"
            / "iOS"
            / "ValidationHarness"
            / "PiPCadenceSemanticsProbeValidationCase.swift"
        ).read_text()
        timing_contract = (
            ROOT.parent
            / "Showcase"
            / "Shared"
            / "PiPCadenceSemanticsProbeEvidence.swift"
        ).read_text()
        runner = (ROOT / "qualification" / "run-device-tests.sh").read_text()

        def swift_seconds(name: str) -> int:
            match = re.search(rf"static let {name}(?:: [^=]+)? = (\d+)", timing_contract)
            self.assertIsNotNone(match, name)
            return int(match.group(1))

        def shell_seconds(name: str) -> int:
            match = re.search(rf"(?m)^{name}=(\d+)$", runner)
            self.assertIsNotNone(match, name)
            return int(match.group(1))

        application = swift_seconds("applicationRunBudgetSeconds")
        capture = swift_seconds("springBoardCaptureBudgetSeconds")
        collection = swift_seconds("reportCollectionBudgetSeconds")
        xctest_allowance = swift_seconds("xctestExecutionAllowanceSeconds")
        idle_watchdog = swift_seconds("runnerIdleWatchdogSeconds")
        wall_watchdog = swift_seconds("runnerWallWatchdogSeconds")
        probe_command = re.search(
            r'elif \[\[ "\$scenario" == "cadence-semantics-probe" \]\]; then'
            r'(.*?)elif \[\[ "\$scenario" == "native-subtitle-matrix" \]\]; then',
            runner,
            re.DOTALL,
        ).group(1)

        self.assertLess(application, capture)
        self.assertGreaterEqual(capture - application, 15)
        self.assertGreaterEqual(capture, 240)
        self.assertGreaterEqual(xctest_allowance, capture + collection + 60)
        self.assertGreater(idle_watchdog, xctest_allowance)
        self.assertGreater(wall_watchdog, idle_watchdog)
        self.assertEqual(
            shell_seconds("CADENCE_SEMANTICS_PROBE_XCTEST_ALLOWANCE_SECONDS"),
            xctest_allowance,
        )
        self.assertEqual(
            shell_seconds("CADENCE_SEMANTICS_PROBE_IDLE_WATCHDOG_SECONDS"),
            idle_watchdog,
        )
        self.assertEqual(
            shell_seconds("CADENCE_SEMANTICS_PROBE_WALL_WATCHDOG_SECONDS"),
            wall_watchdog,
        )
        for token in (
            '"$CADENCE_SEMANTICS_PROBE_WALL_WATCHDOG_SECONDS"',
            '"$CADENCE_SEMANTICS_PROBE_IDLE_WATCHDOG_SECONDS"',
            "-default-test-execution-time-allowance",
            "-maximum-test-execution-time-allowance",
        ):
            self.assertIn(token, probe_command)
        self.assertEqual(
            probe_command.count(
                '"$CADENCE_SEMANTICS_PROBE_XCTEST_ALLOWANCE_SECONDS"'
            ),
            2,
        )

        self.assertIn(
            "PiPCadenceSemanticsProbeTiming.applicationRunBudgetSeconds",
            app_probe,
        )
        self.assertIn(
            "PiPCadenceSemanticsProbeTiming.springBoardCaptureBudgetSeconds",
            ui_test,
        )
        self.assertIn(
            "PiPCadenceSemanticsProbeTiming.reportCollectionBudgetSeconds",
            ui_test,
        )
        self.assertNotIn("Task.sleep", app_probe)
        wait_calls = re.findall(
            r"try await waitUntil\((.*?)\) \{", app_probe, re.DOTALL
        )
        self.assertEqual(len(wait_calls), 5)
        self.assertTrue(
            all("runDeadline: runDeadline" in call for call in wait_calls)
        )
        boundary_calls = re.findall(
            r"try await settledBoundary\((.*?)\)", app_probe, re.DOTALL
        )
        self.assertEqual(len(boundary_calls), 2)
        self.assertTrue(
            all("runDeadline: runDeadline" in call for call in boundary_calls)
        )
        self.assertIn("try requireRemainingRunBudget(runDeadline)", app_probe)
        self.assertIn("requestedEnd < runDeadline", app_probe)
        self.assertIn("app-side global run deadline", app_probe)
        background_capture = ui_test[
            ui_test.index("XCUIDevice.shared.press(.home)") : ui_test.index(
                "app.activate()"
            )
        ]
        for background_query in (
            "progress.label",
            "result.label",
            "error.exists",
        ):
            self.assertNotIn(background_query, background_capture)
        self.assertEqual(ui_test.count("app.activate()"), 1)
        self.assertIn(
            "$0.captureStartedSystemUptime >= start + guardSeconds",
            ui_test,
        )
        self.assertIn(
            "$0.captureEndedSystemUptime <= end - guardSeconds",
            ui_test,
        )
        self.assertIn('"captureStartSystemUptimes"', ui_test)
        self.assertIn('"captureEndSystemUptimes"', ui_test)
        self.assertIn('"captureBoundaryGuardSeconds"', ui_test)
        self.assertNotIn("runStartedSystemUptime + 95", ui_test)

    def test_volunteer_runner_pins_the_exact_preflight_device_identifier(self):
        volunteer = (ROOT / "qualification" / "volunteer-validation.sh").read_text()
        resolution = volunteer.index("RESOLVED_DEVICE_ID=$(jq -er")
        runner = volunteer.index("runner_args=(", resolution)
        runner_source = volunteer[runner:]

        self.assertIn('--device "$RESOLVED_DEVICE_ID"', runner_source)
        self.assertNotIn(
            'runner_args+=(--device "$DEVICE_SELECTOR")', runner_source
        )

    def test_pull_request_showcase_gate_compiles_ui_tests_without_booting(self):
        workflow = (ROOT.parent / ".github" / "workflows" / "test.yml").read_text()
        start = workflow.index("- name: Compile iOS Showcase and qualification UI tests")
        end = workflow.index("\n  # tvOS test-run gate", start)
        step = workflow[start:end]

        self.assertIn("xcodebuild build-for-testing", step)
        self.assertIn('-destination "generic/platform=iOS Simulator"', step)
        self.assertNotIn("xcodebuild test", step)

    def test_disposable_signing_identity_is_used_end_to_end(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        volunteer = (ROOT / "qualification" / "volunteer-validation.sh").read_text()
        self.assertIn('--development-team "$DEVELOPMENT_TEAM"', volunteer)
        self.assertIn('python3 "$SCRIPT_DIR/configure-signing.py"', script)
        self.assertIn('DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"', script)
        self.assertIn('-destination "platform=iOS,id=$DEVICE_UDID"', script)
        self.assertIn("-allowProvisioningUpdates", script)
        self.assertIn("-allowProvisioningDeviceRegistration", script)
        self.assertIn(
            "CANDIDATE_BUNDLE_IDENTIFIER=$(read_app_bundle_identifier", script
        )
        self.assertIn(
            "TEST_RUNNER_BUNDLE_IDENTIFIER=$(read_app_bundle_identifier", script
        )
        self.assertEqual(script.count('python3 "$SCRIPT_DIR/prepare-xctestrun.py"'), 1)
        self.assertEqual(
            script.count('--domain-identifier "$CANDIDATE_BUNDLE_IDENTIFIER"'),
            2,
        )
        self.assertNotIn("--domain-identifier com.swiftvlc.showcase.ios", script)
        ownership_test = (
            ROOT.parent
            / "Showcase"
            / "UITests"
            / "iOS"
            / "Tests"
            / "AudioSessionOwnershipDeviceUITests.swift"
        ).read_text()
        self.assertIn(
            "let focusProbeRunnerBundleIdentifier = Bundle.main.bundleIdentifier",
            ownership_test,
        )
        self.assertNotIn(
            '"com.swiftvlc.showcase.ios.uitests.xctrunner"', ownership_test
        )

    def test_runner_binds_retry_lifecycle_and_raw_error_attempt_evidence(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        self.assertIn('--expected-catalog "$scenario_expected_catalog"', script)
        self.assertIn("build-error-inventory", script)
        self.assertIn("bind-attempt-artifacts \\", script)
        self.assertIn('--artifact-root "$OUTPUT_DIR"', script)
        self.assertIn('--source-prefix "$run_id-$scenario"', script)
        self.assertIn('--retained-root "$scenario-raw-jsonl"', script)
        self.assertIn('--retained-base "$OUTPUT_DIR"', script)
        self.assertIn('--retained-root-base "$OUTPUT_DIR"', script)
        self.assertIn("--require-retained-artifacts", script)
        self.assertIn('--error-inventory "$error_inventory"', script)
        self.assertIn('"attempts": attempts', script)
        self.assertIn('"hostErrorInventory": error_inventory', script)

    def test_runner_wires_seek_frame_oracle_as_one_candidate_bound_lane(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        self.assertIn(
            '"iOSUITests/SeekFrameOracleDeviceUITests/test_seekAndFrameRequestsMatchDecodedContent"',
            script,
        )
        self.assertIn('route="SeekFrameOracleValidation"', script)
        self.assertIn("SWIFTVLC_SEEK_FRAME_ORACLE_DEVICE=YES", script)
        self.assertIn("SWIFTVLC_SEEK_FRAME_ORACLE_BASE_URL_BASE64", script)
        self.assertIn(
            'qualification_attachments=("qualification-seek-frame-oracles.json")',
            script,
        )
        self.assertIn('select(.kind == "candidateExcludingPrefixes")', script)
        self.assertIn(
            'test_selection_args+=("-skip-testing:${excluded_prefix%/}")', script
        )
        self.assertNotIn(
            "-skip-testing:iOSUITests/SeekFrameOracleDeviceUITests", script
        )

    def test_runner_wires_progressive_http_range_as_host_transcript_lane(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        test_identifier = (
            "iOSUITests/ProgressiveHTTPRangeSeekDeviceUITests/"
            "test_progressiveRangeSeekUsesFresh206AndNoRangeRejectsStrictly"
        )
        self.assertIn(f'"{test_identifier}"', script)
        self.assertIn('route="ProgressiveHTTPRangeSeekValidation"', script)
        for environment in (
            "SWIFTVLC_PROGRESSIVE_HTTP_RANGE_DEVICE=YES",
            "SWIFTVLC_PROGRESSIVE_HTTP_RANGE_BASE_URL_BASE64",
            "SWIFTVLC_PROGRESSIVE_HTTP_RANGE_FIXTURE_SHA256",
            "SWIFTVLC_PROGRESSIVE_HTTP_RANGE_FIXTURE_BYTES",
            "SWIFTVLC_PROGRESSIVE_HTTP_RANGE_ATTEMPT_TOKEN",
        ):
            self.assertIn(environment, script)
        self.assertIn('request_fixture_control "progressive/$attempt_token/transcript"', script)
        self.assertIn(
            '--progressive-transcripts "$progressive_transcript_root"', script
        )
        self.assertIn(
            'qualification_attachments=("qualification-progressive-http-range-seek.json")',
            script,
        )

        matrix = json.loads((ROOT / "qualification" / "matrix.json").read_text())
        contracts = {row["id"]: row for row in matrix["runnerContracts"]}
        self.assertEqual(
            contracts["progressive-http-range-seek"]["outputs"],
            [
                {
                    "scenario": "progressive-http-range-seek",
                    "attachmentName": "qualification-progressive-http-range-seek.json",
                    "testIdentifiers": [test_identifier],
                }
            ],
        )
        self.assertIn(
            "iOSUITests/ProgressiveHTTPRangeSeekDeviceUITests/",
            contracts["ui-suite"]["selection"]["prefixes"],
        )
        source = (
            ROOT.parent
            / "Showcase"
            / "UITests"
            / "iOS"
            / "Tests"
            / "ProgressiveHTTPRangeSeekDeviceUITests.swift"
        ).read_text()
        self.assertIn(f"func {test_identifier.rsplit('/', 1)[1]}() throws", source)
        self.assertEqual(source.count("attachQualificationEvidence("), 1)
        self.assertIn('scenario: "progressive-http-range-seek"', source)
        self.assertNotIn('"responseStatus"', source)
        self.assertNotIn('"postCommand206"', source)
        self.assertNotIn("if mode == .range {\n      visual", source)
        self.assertNotIn("markCommand(", source)
        self.assertNotIn("commandPath(token:", source)
        self.assertLess(source.index("reveal(command"), source.index("command.tap()"))

        validation_source = (
            ROOT.parent
            / "Showcase"
            / "iOS"
            / "ValidationHarness"
            / "ProgressiveHTTPRangeSeekValidationCase.swift"
        ).read_text()
        self.assertIn(".aspectRatio(16 / 9, contentMode: .fit)", validation_source)
        self.assertNotIn(".frame(height: 230)", validation_source)
        self.assertIn(
            "ProcessInfo.processInfo.systemUptime - start.systemUptimeSeconds >= 1",
            validation_source,
        )
        self.assertIn(
            "ProgressiveHTTPRangeSeekContract.commandOriginHeader",
            validation_source,
        )
        self.assertIn(
            "ProgressiveHTTPRangeSeekContract.commandOrigin",
            validation_source,
        )
        self.assertIn(
            "try await markCommand(token: attemptToken, mode: mode)\n"
            "        let request = try player.requestSeek(",
            validation_source,
        )
        self.assertIn(
            "try await markCommand(token: attemptToken, mode: mode)\n"
            "        do {\n"
            "          _ = try player.requestSeek(",
            validation_source,
        )
        self.assertIn('"captureSystemUptimeIntervals": captureIntervals', source)
        self.assertNotIn('"captureSystemUptimeSeconds"', source)

    def test_runner_wires_native_renderer_recovery_as_one_physical_lane(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        self.assertIn(
            '"iOSUITests/NativeRendererRecoveryDeviceUITests/'
            'test_pausedNativeRendererRecoversAfterRealOSRevocation"',
            script,
        )
        self.assertIn('route="NativeRendererRecoveryValidation"', script)
        self.assertIn("SWIFTVLC_NATIVE_RENDERER_RECOVERY_DEVICE=YES", script)
        self.assertIn("SWIFTVLC_NATIVE_RENDERER_RECOVERY_URL_BASE64", script)
        self.assertIn(
            "qualification_attachments=("
            '"qualification-playback-foreground-displaylayer-recovery.json")',
            script,
        )
        matrix = json.loads((ROOT / "qualification" / "matrix.json").read_text())
        contracts = {row["id"]: row for row in matrix["runnerContracts"]}
        contract = contracts["playback-foreground-displaylayer-recovery"]
        self.assertEqual(
            contract["outputs"],
            [
                {
                    "scenario": "playback-foreground-displaylayer-recovery",
                    "attachmentName": (
                        "qualification-playback-foreground-displaylayer-recovery.json"
                    ),
                    "testIdentifiers": [
                        "iOSUITests/NativeRendererRecoveryDeviceUITests/"
                        "test_pausedNativeRendererRecoversAfterRealOSRevocation"
                    ],
                }
            ],
        )
        excluded = set(contracts["ui-suite"]["selection"]["prefixes"])
        self.assertIn("iOSUITests/NativeRendererRecoveryDeviceUITests/", excluded)

    def test_runner_wires_exact_candidate_bound_local_playback_lanes(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        expected = {
            "local-file-matrix": {
                "test": (
                    "iOSUITests/LocalPlaybackMatrixDeviceUITests/"
                    "test_localFileContainerCodecMatrixProducesMovingVideo"
                ),
                "route": "LocalFileMatrixValidation",
                "attachment": "qualification-local-file-matrix.json",
            },
            "audio-only-playback": {
                "test": (
                    "iOSUITests/AudioOnlyPlaybackDeviceUITests/"
                    "test_audioOnlyCodecMatrixAdvancesNativeOutput"
                ),
                "route": "AudioOnlyPlaybackValidation",
                "attachment": "qualification-audio-only-playback.json",
            },
        }
        matrix = json.loads((ROOT / "qualification" / "matrix.json").read_text())
        contracts = {row["id"]: row for row in matrix["runnerContracts"]}
        excluded = set(contracts["ui-suite"]["selection"]["prefixes"])
        for scenario, contract in expected.items():
            with self.subTest(scenario=scenario):
                self.assertIn(f'"{contract["test"]}"', script)
                self.assertIn(f'route="{contract["route"]}"', script)
                self.assertIn(
                    f'qualification_attachments=("{contract["attachment"]}")',
                    script,
                )
                self.assertEqual(
                    contracts[scenario]["outputs"],
                    [
                        {
                            "scenario": scenario,
                            "attachmentName": contract["attachment"],
                            "testIdentifiers": [contract["test"]],
                        }
                    ],
                )
                class_name = contract["test"].split("/", 2)[1]
                self.assertIn(f"iOSUITests/{class_name}/", excluded)
                source = (
                    ROOT.parent
                    / "Showcase"
                    / "UITests"
                    / "iOS"
                    / "Tests"
                    / f"{class_name}.swift"
                ).read_text()
                method_name = contract["test"].rsplit("/", 1)[1]
                self.assertRegex(
                    source,
                    rf"func {re.escape(method_name)}\(\)(?: async)? throws",
                )
                self.assertEqual(source.count("attachQualificationEvidence("), 1)
                self.assertIn(f'scenario: "{scenario}"', source)
        self.assertIn("SWIFTVLC_LOCAL_PLAYBACK_DEVICE=YES", script)
        self.assertIn("SWIFTVLC_LOCAL_PLAYBACK_BASE_URL_BASE64", script)
        self.assertIn(
            'cp "$FIXTURES/manifest.json" "$OUTPUT_DIR/fixture-manifest.json"', script
        )
        video_source = (
            ROOT.parent
            / "Showcase"
            / "UITests"
            / "iOS"
            / "Tests"
            / "LocalPlaybackMatrixDeviceUITests.swift"
        ).read_text()
        app_source = (
            ROOT.parent
            / "Showcase"
            / "iOS"
            / "ValidationHarness"
            / "LocalPlaybackQualificationValidationCases.swift"
        ).read_text()
        self.assertIn('waitForLabel(result, equals: "measuring"', video_source)
        self.assertIn('result = "measuring"', app_source)

    def test_reset_lane_uses_a_per_attempt_four_hour_hls_timeline(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        self.assertIn(
            'attempt_token="$run_id-audio-reset-$attempt"',
            script,
        )
        self.assertIn(
            'reset_url="$BASE_URL/adaptive/$attempt_token/'
            'timebase-vod-ts/master.m3u8"',
            script,
        )
        self.assertIn(
            "SWIFTVLC_AUDIO_MEDIA_SERVICES_RESET_URL_BASE64",
            script,
        )
        self.assertNotIn(
            '"audio-media-services-reset" ]]; then\n'
            '        attempt_token="$run_id-audio-reset-$attempt"\n'
            '        local reset_url="$BASE_URL/live/',
            script,
        )

    def test_reset_operator_prompt_waits_for_candidate_readiness_marker(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        branch = re.search(
            r'elif \[\[ "\$scenario" == "audio-media-services-reset" \]\]; then\n'
            r"(?P<body>(?:(?!\n    (?:elif|else|fi)\b).)*)\n"
            r"    else\n",
            script,
            re.DOTALL,
        )
        self.assertIsNotNone(branch)
        body = branch.group("body")
        marker = "SWIFTVLC_AUDIO_RESET_READY_FOR_OPERATOR:$attempt_token"
        self.assertIn(marker, body)
        self.assertIn('run_with_watchdog 1200 660 "$attempt_log"', body)
        self.assertIn('-resultBundlePath "$attempt_bundle" &', body)
        self.assertIn('grep -Fq -- "$reset_readiness_marker" "$attempt_log"', body)
        self.assertLess(
            body.index("xcodebuild test-without-building"),
            body.index("ACTION REQUIRED"),
        )
        self.assertLess(
            body.index('grep -Fq -- "$reset_readiness_marker"'),
            body.index("ACTION REQUIRED"),
        )
        self.assertIn('if [[ "$reset_ready" != true ]]; then', body)
        self.assertIn("test_status=1", body)

    def test_ownership_lane_injects_a_per_attempt_four_hour_hls_timeline(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        self.assertIn(
            'attempt_token="$run_id-audio-ownership-$attempt"',
            script,
        )
        self.assertIn(
            'ownership_url="$BASE_URL/adaptive/$attempt_token/'
            'timebase-vod-ts/master.m3u8"',
            script,
        )
        self.assertIn(
            "ownership_url_base64=$(printf '%s' \"$ownership_url\" "
            "| base64 | tr -d '\\r\\n')",
            script,
        )
        self.assertIn(
            "--environment SWIFTVLC_AUDIO_SESSION_OWNERSHIP_URL_BASE64="
            '"$ownership_url_base64"',
            script,
        )
        self.assertNotIn(
            '"audio-session-ownership" ]]; then\n'
            '        attempt_token="$run_id-audio-ownership-$attempt"\n'
            '        local ownership_url="$BASE_URL/live/',
            script,
        )

    def test_ownership_lane_has_an_explicit_ten_minute_xctest_allowance(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        branch = re.search(
            r'elif \[\[ "\$scenario" == "audio-session-ownership" \]\]; then\n'
            r"(?P<body>(?:(?!\n    (?:elif|else|fi)\b).)*)\n"
            r'    elif \[\[ "\$scenario" == "audio-media-services-reset" \]\]; then',
            script,
            re.DOTALL,
        )
        self.assertIsNotNone(branch)
        body = branch.group("body")
        self.assertIn("xcodebuild test-without-building", body)
        self.assertIn("-test-timeouts-enabled YES", body)
        self.assertIn("-default-test-execution-time-allowance 600", body)
        self.assertIn("-maximum-test-execution-time-allowance 600", body)

    def test_apple_audio_source_proof_is_host_retained_and_quiescent(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        support = (
            ROOT.parent
            / "Showcase"
            / "UITests"
            / "iOS"
            / "Support"
            / "ShowcaseIOSTestCase.swift"
        ).read_text()
        reset_test = (
            ROOT.parent
            / "Showcase"
            / "UITests"
            / "iOS"
            / "Tests"
            / "MediaServicesResetDeviceUITests.swift"
        ).read_text()
        ownership_test = (
            ROOT.parent
            / "Showcase"
            / "UITests"
            / "iOS"
            / "Tests"
            / "AudioSessionOwnershipDeviceUITests.swift"
        ).read_text()
        materializer = (ROOT / "qualification" / "materialize-evidence.py").read_text()
        policy_source = (ROOT / "qualification" / "qualification_policy.py").read_text()

        self.assertNotIn("adaptiveSourceRequestProof", support)
        self.assertNotIn('payload["sourceRequestProof"]', reset_test)
        self.assertNotIn('payload["sourceRequestProof"]', ownership_test)
        self.assertIn("capture_apple_audio_source_metrics()", script)
        self.assertGreaterEqual(
            script.count('request_fixture_control "adaptive/$token/metrics"'),
            2,
        )
        self.assertIn('cmp -s "$first_snapshot" "$second_snapshot"', script)
        self.assertIn("snapshots across three seconds", script)
        self.assertIn("&& sleep 3", script)
        self.assertIn("apple-audio-source-metrics/$run_id-$scenario", script)
        self.assertIn(
            '--adaptive-source-metrics "$final_apple_audio_source_metrics"',
            script,
        )
        self.assertIn('"sourceRequestProof",', materializer)
        self.assertIn("bind_apple_audio_source_request_proof", materializer)
        self.assertIn(
            "sourceRequestProof", qualification_policy._ATTACHMENT_HOST_FIELDS
        )
        for scenario in (
            "audio-media-services-reset",
            "audio-session-ownership",
        ):
            self.assertEqual(
                qualification_policy._AUGMENTED_ATTACHMENT_PATHS[scenario],
                {"sourceRequestProof"},
            )
        self.assertIn(
            '{"sourceRequestProof": evidence.get("sourceRequestProof")}',
            policy_source,
        )

    def test_adaptive_ui_retains_sustained_visual_checkpoints(self):
        source = (
            ROOT.parent
            / "Showcase"
            / "UITests"
            / "iOS"
            / "Tests"
            / "AdaptiveHLSSoakDeviceUITests.swift"
        ).read_text()
        maximum = re.search(r"maximumVisualGapSeconds\s*=\s*(\d+)", source)
        period = re.search(r"visualCheckpointPeriodSeconds\s*=\s*(\d+)", source)
        self.assertIsNotNone(maximum)
        self.assertIsNotNone(period)
        self.assertGreater(int(maximum.group(1)), 0)
        self.assertLess(int(period.group(1)), int(maximum.group(1)))
        self.assertIn("observedElapsed >= nextVisualCheckpointElapsed", source)
        self.assertIn("deviceObservedDuration - maximumGapSeconds", source)
        self.assertIn("current.elapsedSeconds - previous.elapsedSeconds", source)
        self.assertIn("Set(observations.map(\\.mode))", source)

    def test_delayed_start_source_and_runner_share_one_exact_dual_output_contract(
        self,
    ):
        source = (
            ROOT.parent
            / "Showcase"
            / "UITests"
            / "iOS"
            / "Tests"
            / "PiPDelayedStartFailureDeviceUITests.swift"
        ).read_text()
        emitted_scenarios = set(
            re.findall(
                r'attachQualificationEvidence\([\s\S]*?scenario:\s*"([a-z0-9-]+)"\s*\)',
                source,
            )
        )
        self.assertEqual(
            emitted_scenarios,
            {"failed-start", "accepted-start-delayed-failure"},
        )

        matrix = json.loads((ROOT / "qualification" / "matrix.json").read_text())
        contracts = {item["id"]: item for item in matrix["runnerContracts"]}
        self.assertNotIn("accepted-start-delayed-failure", contracts)
        contract = contracts["failed-start"]
        self.assertEqual(contract["attachmentEmission"], "allOutputs")
        expected_test = (
            "iOSUITests/PiPDelayedStartFailureDeviceUITests/"
            "test_acceptedStartRetainsAttributionThroughDelayedFailure"
        )
        self.assertEqual(
            {
                output["scenario"]: (
                    output["attachmentName"],
                    output["testIdentifiers"],
                )
                for output in contract["outputs"]
            },
            {
                scenario: (f"qualification-{scenario}.json", [expected_test])
                for scenario in emitted_scenarios
            },
        )
        self.assertEqual(
            qualification_policy.runner_attachment_expectations(
                contract, {"failed-start"}
            ),
            {
                f"qualification-{scenario}.json": [expected_test]
                for scenario in emitted_scenarios
            },
        )

        runner = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        self.assertNotIn("accepted-start-delayed-failure)", runner)
        self.assertIn(
            'qualification_scenarios+=("accepted-start-delayed-failure")', runner
        )
        self.assertIn("if can_run_iphone_current_lanes; then", runner)

    def test_host_only_xctests_are_owned_by_analyzer_not_ui_suite(self):
        matrix = json.loads((ROOT / "qualification" / "matrix.json").read_text())
        contracts = {item["id"]: item for item in matrix["runnerContracts"]}
        expected = {
            "iOSUITests/DeferredPauseSettlementObservationTests/",
            "iOSUITests/HLSSeekLandingFrameGateTests/",
            "iOSUITests/NativeRendererRecoveryEvidenceTests/",
            "iOSUITests/NativeRendererRecoveryVisualEvidenceTests/",
            "iOSUITests/PiPMotionRegionAnalyzerTests/",
            "iOSUITests/VideoSurfaceMotionEvidenceTests/",
            "iOSUITests/VideoOracleAnalyzerTests/",
        }
        analyzer = contracts["analyzer"]["selection"]
        self.assertEqual(analyzer["kind"], "candidatePrefixes")
        self.assertEqual(set(analyzer["prefixes"]), expected)
        source_owned = set()
        tests_root = ROOT.parent / "Showcase" / "UITests" / "iOS" / "Tests"
        for source in tests_root.glob("*.swift"):
            for line in source.read_text().splitlines():
                stripped = line.strip()
                if stripped.startswith("final class ") and stripped.endswith(
                    ": XCTestCase {"
                ):
                    test_class = stripped.split()[2].removesuffix(":")
                    source_owned.add(f"iOSUITests/{test_class}/")
        self.assertEqual(source_owned, expected)
        ui_suite = contracts["ui-suite"]["selection"]
        self.assertTrue(expected <= set(ui_suite["prefixes"]))
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        for prefix in expected:
            self.assertIn(f'"{prefix.removesuffix("/")}"', script)
        visual_source = (
            ROOT.parent
            / "Showcase"
            / "UITests"
            / "iOS"
            / "Support"
            / "VideoSurfaceMotionEvidence.swift"
        ).read_text()
        for contract in (
            qualification_policy.VISUAL_OBSERVATION_METHOD,
            "static let width = 64",
            "static let height = 36",
            '"swiftvlc-rgb8-64x36-v1\\0"',
            "pixelDeltaThreshold = 12",
            "ratios.min()",
        ):
            self.assertIn(contract, visual_source)

    def test_ui_suite_excludes_every_skip_gated_test_class(self):
        matrix = json.loads((ROOT / "qualification" / "matrix.json").read_text())
        contracts = {item["id"]: item for item in matrix["runnerContracts"]}
        excluded = set(contracts["ui-suite"]["selection"]["prefixes"])
        tests_root = ROOT.parent / "Showcase" / "UITests" / "iOS" / "Tests"
        skip_gated = {
            f"iOSUITests/{source.stem}/"
            for source in tests_root.glob("*.swift")
            if "XCTSkip" in source.read_text()
        }

        self.assertTrue(skip_gated)
        self.assertEqual(skip_gated - excluded, set())
        probe = (
            "iOSUITests/PiPCadenceSemanticsProbeDeviceUITests/"
            "test_reportOnlyVmemCadenceSemanticsProbe"
        )
        self.assertIn(
            "iOSUITests/PiPCadenceSemanticsProbeDeviceUITests/", excluded
        )
        self.assertIn(probe, qualification_policy.RELEASE_CATALOG_EXCEPTIONS)

    def test_physical_harness_regression_has_no_capability_skip(self):
        matrix = json.loads((ROOT / "qualification" / "matrix.json").read_text())
        contracts = {item["id"]: item for item in matrix["runnerContracts"]}
        expected = (
            "iOSUITests/PiPUITests/"
            "test_deep_toggleButtonAvailabilityMatchesPiPPossibility"
        )
        selected = contracts["harness-regressions"]["selection"][
            "testIdentifiers"
        ]
        self.assertIn(expected, selected)
        self.assertNotIn(
            "iOSUITests/PiPUITests/test_deep_toggleButtonDisabledWhenNotPossible",
            selected,
        )
        runner = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        self.assertIn(f'"{expected}"', runner)
        source = (
            ROOT.parent / "Showcase" / "UITests" / "iOS" / "Tests" / "PiPUITests.swift"
        ).read_text()
        self.assertIn("func test_deep_toggleButtonAvailabilityMatchesPiPPossibility()", source)
        self.assertNotIn("XCTSkip", source)

    def test_require_stable_rejects_shortened_duration_before_device_discovery(self):
        script = ROOT / "qualification" / "run-device-tests.sh"
        environment = os.environ.copy()
        environment["SWIFTVLC_ADAPTIVE_SOAK_SECONDS"] = "60"
        completed = subprocess.run(
            [
                "bash",
                str(script),
                "--version",
                "1.1.0",
                "--require-stable",
                "--development-team",
                "ABCDE12345",
            ],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(completed.returncode, 2)
        self.assertIn("immutable minimum is 7200s", completed.stderr)

    def test_device_runner_requires_exact_candidate_version(self):
        script = ROOT / "qualification" / "run-device-tests.sh"
        completed = subprocess.run(
            ["bash", str(script), "--development-team", "ABCDE12345"],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(completed.returncode, 2)
        self.assertIn("--version is required", completed.stderr)

    def test_temporary_work_defaults_beside_the_repository(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        self.assertIn(
            'WORK_ROOT="${SWIFTVLC_DEVICE_WORK_ROOT:-$ROOT_DIR/.qualification-work}"',
            script,
        )
        self.assertIn(
            'WORK_DIR=$(mktemp -d "$WORK_ROOT/swiftvlc-device-tests.XXXXXX")',
            script,
        )
        self.assertNotIn("${TMPDIR:-/tmp}/swiftvlc-device-tests", script)
        self.assertIn('export TMPDIR="$WORK_DIR"', script)


class PrimeXCTRunnerScriptTests(unittest.TestCase):
    script = ROOT / "qualification" / "prime-xctrunner.sh"

    def invoke(
        self,
        root: Path,
        *,
        fail_first_terminate=False,
        fail_launch=False,
        fail_first_launch=False,
        signal_first_launch=False,
        process_identifier="4321",
    ):
        shim_directory = root / "bin"
        shim_directory.mkdir()
        call_log = root / "xcrun-calls.jsonl"
        terminate_state = root / "terminate-count"
        launch_state = root / "launch-count"
        shim = shim_directory / "xcrun"
        shim.write_text("""#!/usr/bin/env python3
import json
import os
import signal
import socket
from pathlib import Path
import sys
import time

arguments = sys.argv[1:]
with open(os.environ["FAKE_XCRUN_LOG"], "a") as output:
    output.write(json.dumps(arguments) + "\\n")

if "launch" in arguments:
    state = Path(os.environ["FAKE_XCRUN_LAUNCH_STATE"])
    count = int(state.read_text()) if state.exists() else 0
    count += 1
    state.write_text(str(count))
    output_path = Path(arguments[arguments.index("--json-output") + 1])
    if (os.environ.get("FAKE_XCRUN_SIGNAL_FIRST_LAUNCH") == "1"
            and count == 1):
        output_path.write_text('{"result":')
        os.kill(os.getppid(), signal.SIGTERM)
        time.sleep(0.05)
        raise SystemExit(143)
    if os.environ.get("FAKE_XCRUN_FAIL_LAUNCH") == "1":
        raise SystemExit(42)
    if (os.environ.get("FAKE_XCRUN_FAIL_FIRST_LAUNCH") == "1"
            and count == 1):
        output_path.write_text('{"result":')
        raise SystemExit(42)
    process_identifier = os.environ.get("FAKE_XCRUN_PROCESS_IDENTIFIER", "4321")
    output_path.write_text(json.dumps(
        {"result": {"process": {"processIdentifier": process_identifier}}}
    ))
    raise SystemExit(0)

if "terminate" in arguments:
    state = Path(os.environ["FAKE_XCRUN_TERMINATE_STATE"])
    count = int(state.read_text()) if state.exists() else 0
    count += 1
    state.write_text(str(count))
    if os.environ.get("FAKE_XCRUN_FAIL_FIRST_TERMINATE") == "1" and count == 1:
        raise SystemExit(23)
    raise SystemExit(0)

raise SystemExit(99)
""")
        shim.chmod(0o755)
        work = root / "work"
        work.mkdir()
        environment = dict(os.environ)
        environment.update(
            {
                "PATH": f"{shim_directory}:{environment['PATH']}",
                "FAKE_XCRUN_LOG": str(call_log),
                "FAKE_XCRUN_TERMINATE_STATE": str(terminate_state),
                "FAKE_XCRUN_LAUNCH_STATE": str(launch_state),
                "FAKE_XCRUN_FAIL_FIRST_TERMINATE": (
                    "1" if fail_first_terminate else "0"
                ),
                "FAKE_XCRUN_FAIL_LAUNCH": "1" if fail_launch else "0",
                "FAKE_XCRUN_FAIL_FIRST_LAUNCH": (
                    "1" if fail_first_launch else "0"
                ),
                "FAKE_XCRUN_SIGNAL_FIRST_LAUNCH": (
                    "1" if signal_first_launch else "0"
                ),
                "FAKE_XCRUN_PROCESS_IDENTIFIER": process_identifier,
            }
        )
        result = subprocess.run(
            [
                str(self.script),
                "--device",
                "physical-device",
                "--bundle-identifier",
                "com.swiftvlc.tests.xctrunner",
                "--work-root",
                str(work),
            ],
            capture_output=True,
            text=True,
            env=environment,
        )
        calls = [json.loads(line) for line in call_log.read_text().splitlines()]
        return result, calls, work

    def test_launches_suspended_runner_then_terminates_it_with_timeouts(self):
        with tempfile.TemporaryDirectory() as directory:
            result, calls, work = self.invoke(Path(directory))
            leftovers = list(work.glob("runner-prime*"))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 2)
        launch, terminate = calls
        for argument in ("--start-stopped", "--no-activate", "--terminate-existing"):
            self.assertIn(argument, launch)
        self.assertEqual(launch[launch.index("--timeout") + 1], "20")
        self.assertEqual(launch[-1], "com.swiftvlc.tests.xctrunner")
        self.assertEqual(terminate[terminate.index("--pid") + 1], "4321")
        self.assertEqual(terminate[terminate.index("--timeout") + 1], "20")
        self.assertEqual(leftovers, [])

    def test_failed_termination_is_retried_by_exit_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            result, calls, work = self.invoke(
                Path(directory), fail_first_terminate=True
            )
            leftovers = list(work.glob("runner-prime*"))

        self.assertEqual(result.returncode, 23)
        terminate_calls = [call for call in calls if "terminate" in call]
        self.assertEqual(len(terminate_calls), 2)
        self.assertEqual(
            terminate_calls[0][terminate_calls[0].index("--timeout") + 1], "20"
        )
        self.assertEqual(
            terminate_calls[1][terminate_calls[1].index("--timeout") + 1], "10"
        )
        self.assertIn("--kill", terminate_calls[1])
        self.assertEqual(leftovers, [])

    def test_launch_failure_attempts_bounded_exact_bundle_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            result, calls, work = self.invoke(Path(directory), fail_launch=True)
            leftovers = list(work.glob("runner-prime*"))

        self.assertEqual(result.returncode, 42)
        self.assertEqual(len(calls), 2)
        self.assertTrue(all("--terminate-existing" in call for call in calls))
        self.assertEqual(calls[0][calls[0].index("--timeout") + 1], "20")
        self.assertEqual(calls[1][calls[1].index("--timeout") + 1], "10")
        self.assertEqual(leftovers, [])

    def test_partial_launch_output_is_recovered_and_force_terminated(self):
        with tempfile.TemporaryDirectory() as directory:
            result, calls, work = self.invoke(
                Path(directory), fail_first_launch=True
            )
            leftovers = list(work.glob("runner-prime*"))

        self.assertEqual(result.returncode, 42)
        self.assertEqual(len(calls), 3)
        self.assertIn("launch", calls[0])
        self.assertIn("launch", calls[1])
        self.assertIn("--terminate-existing", calls[1])
        self.assertEqual(calls[1][calls[1].index("--timeout") + 1], "10")
        self.assertIn("terminate", calls[2])
        self.assertEqual(calls[2][calls[2].index("--pid") + 1], "4321")
        self.assertIn("--kill", calls[2])
        self.assertEqual(leftovers, [])

    def test_signal_during_partial_launch_recovers_and_force_terminates(self):
        with tempfile.TemporaryDirectory() as directory:
            result, calls, work = self.invoke(
                Path(directory), signal_first_launch=True
            )
            leftovers = list(work.glob("runner-prime*"))

        self.assertEqual(result.returncode, 143)
        self.assertEqual(len(calls), 3)
        self.assertIn("launch", calls[1])
        self.assertEqual(calls[1][calls[1].index("--timeout") + 1], "10")
        self.assertIn("terminate", calls[2])
        self.assertIn("--kill", calls[2])
        self.assertEqual(leftovers, [])

    def test_non_positive_or_non_numeric_process_identifier_is_rejected(self):
        for process_identifier in ("0", "not-a-pid"):
            with self.subTest(
                process_identifier=process_identifier
            ), tempfile.TemporaryDirectory() as directory:
                result, calls, work = self.invoke(
                    Path(directory), process_identifier=process_identifier
                )
                leftovers = list(work.glob("runner-prime*"))

                self.assertEqual(result.returncode, 1)
                self.assertEqual(len(calls), 2)
                self.assertIn("did not return a positive", result.stderr)
                self.assertEqual(leftovers, [])


class XCTestrunTests(unittest.TestCase):
    app_bundle_identifier = "com.swiftvlc.validation.team.app"
    runner_bundle_identifier = "com.swiftvlc.validation.team.uitests.xctrunner"

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
        transformed = prepare_xctestrun.transform(
            original,
            {"ATTACH": "YES"},
            test_host_bundle_identifier=self.runner_bundle_identifier,
            ui_target_app_bundle_identifier=self.app_bundle_identifier,
        )
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
            test_host_bundle_identifier=self.runner_bundle_identifier,
            ui_target_app_bundle_identifier=self.app_bundle_identifier,
        )
        target = transformed["TestConfigurations"][0]["TestTargets"][0]
        self.assertEqual(target["TestBundlePath"], "/tmp/test.xctest")
        self.assertEqual(target["TestHostPath"], "/tmp/Runner.app")
        self.assertNotIn("UseDestinationArtifacts", target)
        self.assertEqual(
            target["TestingEnvironmentVariables"]["FIXTURE"],
            "http://127.0.0.1/media.mp4",
        )

    def test_destination_artifact_transform_uses_explicit_signed_identifiers(self):
        transformed = prepare_xctestrun.transform(
            self.ui_test_plan(),
            {},
            test_host_bundle_identifier=self.runner_bundle_identifier,
            ui_target_app_bundle_identifier=self.app_bundle_identifier,
        )
        target = transformed["TestConfigurations"][0]["TestTargets"][0]
        self.assertEqual(
            target["TestHostBundleIdentifier"], self.runner_bundle_identifier
        )
        self.assertEqual(
            target["UITargetAppBundleIdentifier"], self.app_bundle_identifier
        )

    def test_destination_artifact_transform_rejects_malformed_identifiers(self):
        with self.assertRaisesRegex(ValueError, "invalid bundle identifier"):
            prepare_xctestrun.transform(
                self.ui_test_plan(),
                {},
                test_host_bundle_identifier="not a bundle",
                ui_target_app_bundle_identifier=self.app_bundle_identifier,
            )

    def test_cli_requires_both_signed_bundle_identifiers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.xctestrun"
            destination = root / "destination.xctestrun"
            with source.open("wb") as output:
                plistlib.dump(self.ui_test_plan(), output)
            result = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "qualification" / "prepare-xctestrun.py"),
                    str(source),
                    str(destination),
                ],
                text=True,
                capture_output=True,
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("--test-host-bundle-identifier", result.stderr)
            self.assertIn("--ui-target-app-bundle-identifier", result.stderr)
            self.assertFalse(destination.exists())


class ConfigureSigningTests(unittest.TestCase):
    project_text = """
DEVELOPMENT_TEAM = MTAQ5K5D6P;
DEVELOPMENT_TEAM = MTAQ5K5D6P;
PRODUCT_BUNDLE_IDENTIFIER = com.swiftvlc.showcase.ios;
PRODUCT_BUNDLE_IDENTIFIER = com.swiftvlc.showcase.ios;
PRODUCT_BUNDLE_IDENTIFIER = com.swiftvlc.showcase.ios.uitests;
PRODUCT_BUNDLE_IDENTIFIER = com.swiftvlc.showcase.ios.uitests;
PRODUCT_BUNDLE_IDENTIFIER = com.swiftvlc.showcase.macos;
"""

    def test_configures_only_the_disposable_ios_project(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory) / "project.pbxproj"
            project.write_text(self.project_text)
            app_id, tests_id = configure_signing.configure(
                project,
                "WNWACJNFDX",
                "com.swiftvlc.validation.wnwacjnfdx",
            )
            value = project.read_text()
            self.assertEqual(app_id, "com.swiftvlc.validation.wnwacjnfdx.app")
            self.assertEqual(tests_id, "com.swiftvlc.validation.wnwacjnfdx.uitests")
            self.assertEqual(value.count("DEVELOPMENT_TEAM = WNWACJNFDX;"), 2)
            self.assertIn(
                "PRODUCT_BUNDLE_IDENTIFIER = com.swiftvlc.showcase.macos;",
                value,
            )

    def test_preserves_project_permissions(self):
        for mode in (0o644, 0o640):
            with self.subTest(mode=oct(mode)), tempfile.TemporaryDirectory() as directory:
                project = Path(directory) / "project.pbxproj"
                project.write_text(self.project_text)
                project.chmod(mode)
                configure_signing.configure(
                    project, "WNWACJNFDX", "com.swiftvlc.validation.wnwacjnfdx"
                )
                self.assertEqual(project.stat().st_mode & 0o7777, mode)

    def test_refuses_an_unexpected_project_shape(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory) / "project.pbxproj"
            project.write_text(self.project_text.replace("DEVELOPMENT_TEAM", "", 1))
            with self.assertRaisesRegex(ValueError, "expected 2"):
                configure_signing.configure(
                    project,
                    "WNWACJNFDX",
                    "com.swiftvlc.validation.wnwacjnfdx",
                )


class VolunteerReportPrivacyTests(unittest.TestCase):
    def test_packages_incomplete_progress_and_scrubs_private_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / "run"
            run.mkdir()
            (run / "device.json").write_text(
                json.dumps(
                    {
                        "selected": {
                            "id": "private-core-id",
                            "udid": "private-udid",
                            "ecid": 42,
                            "name": "Person's iPhone",
                            "marketingName": "iPhone 15 Pro",
                            "productType": "iPhone16,1",
                            "deviceFamily": "iPhone",
                            "osVersion": "27.0",
                            "osBuild": "24A5390f",
                            "osReleaseType": "beta",
                            "transport": "wired",
                            "tunnelIPAddress": "fd7d:5ea1:e53f::1",
                        }
                    }
                )
            )
            (run / "scenario-results.tsv").write_text(
                "ui-suite\tpass\t0\t0\tcaptured\tnot-applicable\t30\n"
            )
            (run / "validation-plan.json").write_text(
                json.dumps(
                    {
                        "selectedScenarioDrivers": [
                            "ui-suite",
                            "live-media",
                            "hls-seek",
                        ]
                    }
                )
            )
            (run / "ui-suite-xcodebuild.log").write_text(
                "Person's iPhone /Users/alice/project "
                "http://192.168.1.4:8000/file "
                "http://[fd7d:5ea1:e53f::2]:9000/file "
                "com.swiftvlc.validation.wnwacjnfdx.app\n"
            )
            (run / "configure-signing.log").write_text(
                "appBundleIdentifier=com.swiftvlc.validation.wnwacjnfdx.app\n"
                "uiTestBundleIdentifier=com.swiftvlc.validation.wnwacjnfdx.uitests\n"
            )
            (run / "build.log").write_text(
                "DEVELOPMENT_TEAM = WNWACJNFDX\n"
                "bundle com.swiftvlc.validation.wnwacjnfdx.uitests.xctrunner\n"
            )
            evidence = run / "evidence"
            evidence.mkdir()
            (evidence / "probe.json").write_text(
                json.dumps({"id": "measurement-id", "name": "continuity probe"})
            )
            output = root / "share.zip"

            package_volunteer_report.package(run, output)

            with zipfile.ZipFile(output) as archive:
                summary = archive.read("SwiftVLC-Device-Report/SUMMARY.md").decode()
                device = json.loads(archive.read("SwiftVLC-Device-Report/device.json"))[
                    "selected"
                ]
                log = archive.read(
                    "SwiftVLC-Device-Report/logs/ui-suite-xcodebuild.log"
                ).decode()
                build_log = archive.read(
                    "SwiftVLC-Device-Report/logs/build.log"
                ).decode()
                signing_log = archive.read(
                    "SwiftVLC-Device-Report/logs/configure-signing.log"
                ).decode()
                saved_evidence = json.loads(
                    archive.read("SwiftVLC-Device-Report/evidence/probe.json")
                )
            self.assertIn("INCOMPLETE / INTERRUPTED", summary)
            self.assertIn("Unfinished scenario drivers: **2**", summary)
            self.assertEqual(device["name"], "<redacted>")
            self.assertEqual(device["id"], "<redacted>")
            self.assertNotIn("udid", device)
            self.assertNotIn("ecid", device)
            self.assertNotIn("tunnelIPAddress", device)
            self.assertNotIn("alice", log)
            self.assertNotIn("192.168.1.4", log)
            self.assertNotIn("fd7d:5ea1:e53f", log)
            self.assertNotIn("WNWACJNFDX", build_log)
            self.assertNotIn("wnwacjnfdx", log)
            self.assertNotIn("wnwacjnfdx", signing_log)
            self.assertEqual(saved_evidence["id"], "measurement-id")
            self.assertEqual(saved_evidence["name"], "continuity probe")

    def test_reads_current_eleven_field_interrupted_progress(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            fields = [
                "progressive-http-range-seek",
                "pass",
                "0",
                "0",
                "captured",
                "captured",
                "45",
                "/Users/alice/run/expected.json",
                "/Users/alice/run/execution.json",
                "/Users/alice/run/attempts.json",
                "/Users/alice/run/errors.json",
            ]
            (run / "scenario-results.tsv").write_text("\t".join(fields) + "\n")

            scenarios, complete = package_volunteer_report.read_scenarios(run)

            self.assertFalse(complete)
            self.assertEqual(len(scenarios), 1)
            self.assertEqual(
                scenarios[0],
                {
                    "scenario": "progressive-http-range-seek",
                    "result": "pass",
                    "xcodebuildExitCode": 0,
                    "libraryErrorCount": 0,
                    "appLog": "captured",
                    "qualificationEvidence": "captured",
                    "durationSeconds": 45,
                },
            )

    def test_incomplete_final_progress_line_preserves_completed_rows(self):
        base_fields = [
            "ui-suite",
            "pass",
            "0",
            "0",
            "captured",
            "not-applicable",
            "30",
        ]
        current_evidence_fields = [
            "/Users/alice/run/expected.json",
            "/Users/alice/run/execution.json",
            "/Users/alice/run/attempts.json",
            "/Users/alice/run/errors.json",
        ]
        cases = {
            "legacy-seven-field": (
                base_fields,
                "live-media\tfail\t1",
            ),
            "current-eleven-field": (
                base_fields + current_evidence_fields,
                "live-media\tfail\t1\t0\tmissing\tmissing\t",
            ),
        }
        for name, (completed_fields, incomplete_line) in cases.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                run = Path(directory)
                (run / "scenario-results.tsv").write_text(
                    "\t".join(completed_fields) + "\n" + incomplete_line
                )

                scenarios, complete = package_volunteer_report.read_scenarios(run)

                self.assertFalse(complete)
                self.assertEqual([row["scenario"] for row in scenarios], ["ui-suite"])
                self.assertEqual(scenarios[0]["durationSeconds"], 30)

    def test_complete_report_is_labelled_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / "run"
            run.mkdir()
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "scenarios": [
                        {"scenario": scenario, "result": "pass"}
                        for scenario in RELEASE_SCENARIO_ORDER
                    ],
                },
                selection_scope="full",
            )
            output = root / "share.zip"
            package_volunteer_report.package(run, output)
            with zipfile.ZipFile(output) as archive:
                summary = archive.read("SwiftVLC-Device-Report/SUMMARY.md").decode()
            self.assertIn("Report state: **COMPLETE**", summary)
            self.assertIn("Result: **PASS**", summary)
            self.assertIn("FULL APPLICABLE DEVICE SUITE", summary)
            self.assertIn("QUALIFYING DEVICE ENVIRONMENT", summary)

    def test_partial_and_exploratory_passes_are_never_presented_as_release_passes(self):
        cases = (
            (
                "partial",
                {
                    "selection_scope": "partial",
                    "mode": "qualification",
                    "qualification_eligible": True,
                },
                "PASS — PARTIAL SCOPE",
                "PARTIAL / TARGETED — NOT A COMPLETE RELEASE CHECKLIST",
            ),
            (
                "exploratory",
                {
                    "selection_scope": "partial",
                    "mode": "exploratory",
                    "qualification_eligible": False,
                },
                "PASS — NOT RELEASE-QUALIFYING",
                "EXPLORATORY — NOT RELEASE-QUALIFYING",
            ),
        )
        for name, options, expected_result, expected_label in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                run = root / "run"
                run.mkdir()
                write_validated_report(
                    run,
                    {
                        "result": "pass",
                        "scenarios": [
                            {"scenario": "analyzer", "result": "pass"}
                        ],
                    },
                    **options,
                )
                output = root / "share.zip"

                package_volunteer_report.package(run, output)

                with zipfile.ZipFile(output) as archive:
                    summary = archive.read(
                        "SwiftVLC-Device-Report/SUMMARY.md"
                    ).decode()
                self.assertIn(f"Result: **{expected_result}**", summary)
                self.assertIn(expected_label, summary)

    def test_failure_summary_extracts_a_concise_reason(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / "run"
            run.mkdir()
            write_validated_report(
                run,
                {
                    "result": "fail",
                    "scenarios": [
                        {
                            "scenario": "analyzer",
                            "result": "fail",
                            "durationSeconds": 60,
                            "libraryErrorCount": 0,
                            "qualificationEvidence": "not-applicable",
                        }
                    ],
                },
                retained_files={
                    "analyzer-xcodebuild.log": (
                        "Runner encountered an error "
                        "(Timed out while enabling automation mode.)\n"
                    )
                },
            )
            output = root / "share.zip"
            package_volunteer_report.package(run, output)
            with zipfile.ZipFile(output) as archive:
                summary = archive.read("SwiftVLC-Device-Report/SUMMARY.md").decode()
                reasons = json.loads(
                    archive.read("SwiftVLC-Device-Report/failure-reasons.json")
                )
            self.assertIn("Timed out while enabling automation mode", summary)
            self.assertIn("Report state: **COMPLETE**", summary)
            self.assertIn("Result: **FAIL — PARTIAL SCOPE**", summary)
            self.assertEqual(reasons[0]["scenario"], "analyzer")

    def test_unvalidated_or_changed_report_is_never_labelled_complete(self):
        report = {
            "result": "pass",
            "scenarios": [
                {
                    "scenario": "analyzer",
                    "result": "pass",
                    "durationSeconds": 1,
                    "libraryErrorCount": 0,
                    "qualificationEvidence": "not-applicable",
                }
            ],
        }
        for case in ("missing", "malformed", "digest-mismatch"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                run = root / "run"
                run.mkdir()
                (run / "report.json").write_text(json.dumps(report) + "\n")
                if case == "malformed":
                    write_validated_report(run, report)
                    (run / report_validation.MARKER_FILENAME).write_text("{")
                elif case == "digest-mismatch":
                    write_validated_report(run, report)
                    (run / "report.json").write_text(
                        json.dumps({**report, "postValidationMutation": True}) + "\n"
                    )
                output = root / "share.zip"

                package_volunteer_report.package(run, output)

                with zipfile.ZipFile(output) as archive:
                    summary = archive.read("SwiftVLC-Device-Report/SUMMARY.md").decode()
                self.assertIn("INCOMPLETE / INTERRUPTED", summary)
                self.assertIn("Result: **INCOMPLETE**", summary)

    def test_report_plan_mismatch_is_never_labelled_complete(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / "run"
            run.mkdir()
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "scenarios": [{"scenario": "analyzer", "result": "pass"}],
                },
            )
            plan = json.loads((run / "validation-plan.json").read_text())
            plan["selectedScenarioDrivers"] = ["ui-suite"]
            report_validation.atomic_write_json(run / "validation-plan.json", plan)
            output = root / "share.zip"

            package_volunteer_report.package(run, output)

            with zipfile.ZipFile(output) as archive:
                summary = archive.read("SwiftVLC-Device-Report/SUMMARY.md").decode()
            self.assertIn("Report state: **INCOMPLETE / INTERRUPTED**", summary)
            self.assertIn("report/plan contract mismatch", summary)

    def test_malformed_ancillary_json_is_omitted_and_makes_package_incomplete(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / "run"
            run.mkdir()
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "scenarios": [{"scenario": "analyzer", "result": "pass"}],
                },
            )
            (run / "candidate-metadata.json").write_text('{"candidate":')
            evidence = run / "evidence"
            evidence.mkdir()
            (evidence / "partial.json").write_text('{"sample":')
            output = root / "share.zip"

            package_volunteer_report.package(run, output)

            with zipfile.ZipFile(output) as archive:
                names = archive.namelist()
                summary = archive.read("SwiftVLC-Device-Report/SUMMARY.md").decode()
            self.assertIn("Result: **INCOMPLETE**", summary)
            self.assertIn("candidate-metadata.json is malformed", summary)
            self.assertIn("evidence/partial.json is malformed", summary)
            self.assertNotIn(
                "SwiftVLC-Device-Report/candidate-metadata.json", names
            )
            self.assertNotIn(
                "SwiftVLC-Device-Report/evidence/partial.json", names
            )

    def test_changed_identity_sidecars_make_a_validated_package_incomplete(self):
        cases = (
            (
                "candidate",
                "candidate-metadata.json",
                {"formatVersion": 2, "version": "different"},
                "candidate-metadata.json no longer matches",
            ),
            (
                "device",
                "device.json",
                {"selected": {"marketingName": "Replacement iPhone"}},
                "device.json no longer matches",
            ),
            (
                "fixture",
                "fixture-manifest.json",
                {"formatVersion": 1, "postValidationMutation": True},
                "fixture-manifest.json no longer matches",
            ),
        )
        for name, filename, replacement, warning in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                run = root / "run"
                run.mkdir()
                write_validated_report(
                    run,
                    {
                        "result": "pass",
                        "scenarios": [
                            {"scenario": "analyzer", "result": "pass"}
                        ],
                    },
                )
                report_validation.atomic_write_json(run / filename, replacement)
                output = root / "share.zip"

                package_volunteer_report.package(run, output)

                with zipfile.ZipFile(output) as archive:
                    summary = archive.read(
                        "SwiftVLC-Device-Report/SUMMARY.md"
                    ).decode()
                self.assertIn("Result: **INCOMPLETE**", summary)
                self.assertIn(warning, summary)

    def test_malformed_device_json_omits_untrusted_diagnostics(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / "run"
            run.mkdir()
            write_validated_report(
                run,
                {
                    "result": "pass",
                    "scenarios": [{"scenario": "analyzer", "result": "pass"}],
                },
            )
            (run / "device.json").write_text('{"selected":')
            (run / "analyzer-xcodebuild.log").write_text(
                "Secret Device Name 00008030-001C195E0A90802E\n"
            )
            output = root / "share.zip"

            package_volunteer_report.package(run, output)

            with zipfile.ZipFile(output) as archive:
                names = archive.namelist()
                summary = archive.read("SwiftVLC-Device-Report/SUMMARY.md").decode()
                contents = b"\n".join(archive.read(name) for name in names).decode(
                    errors="replace"
                )
            self.assertIn("Result: **INCOMPLETE**", summary)
            self.assertIn("diagnostic logs and evidence were omitted", summary)
            self.assertNotIn("analyzer-xcodebuild.log", "\n".join(names))
            self.assertNotIn("Secret Device Name", contents)

    def test_archive_uses_the_same_report_bytes_as_completion_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / "run"
            run.mkdir()
            validated_report = {
                "result": "pass",
                "scenarios": [
                    {
                        "scenario": "analyzer",
                        "result": "pass",
                        "durationSeconds": 1,
                        "libraryErrorCount": 0,
                        "qualificationEvidence": "not-applicable",
                    }
                ],
            }
            write_validated_report(
                run,
                validated_report,
                retained_files={
                    "analyzer-xcodebuild.log": "captured-before-packaging\n"
                },
            )
            original_collect = package_volunteer_report.collect_files

            def mutate_then_collect(
                run_dir,
                staging,
                secrets,
                structured_values,
                *,
                evidence_values,
                captured_logs,
            ):
                (run_dir / "report.json").write_text(
                    json.dumps(
                        {
                            "result": "fail",
                            "postValidationMutation": True,
                            "scenarios": [
                                {
                                    "scenario": "replacement",
                                    "result": "fail",
                                }
                            ],
                        }
                    )
                    + "\n"
                )
                (run_dir / "analyzer-xcodebuild.log").write_text(
                    "mutated-after-capture\n"
                )
                return original_collect(
                    run_dir,
                    staging,
                    secrets,
                    structured_values,
                    evidence_values=evidence_values,
                    captured_logs=captured_logs,
                )

            output = root / "share.zip"
            with mock.patch.object(
                package_volunteer_report,
                "collect_files",
                side_effect=mutate_then_collect,
            ):
                package_volunteer_report.package(run, output)

            with zipfile.ZipFile(output) as archive:
                summary = archive.read("SwiftVLC-Device-Report/SUMMARY.md").decode()
                archived_report = json.loads(
                    archive.read("SwiftVLC-Device-Report/report.json")
                )
                archived_log = archive.read(
                    "SwiftVLC-Device-Report/logs/analyzer-xcodebuild.log"
                ).decode()
            self.assertIn("Report state: **COMPLETE**", summary)
            self.assertEqual(
                archived_report["scenarios"], validated_report["scenarios"]
            )
            self.assertNotIn("postValidationMutation", archived_report)
            self.assertEqual(archived_log, "captured-before-packaging\n")

    def test_truncated_report_falls_back_to_completed_tsv_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / "run"
            run.mkdir()
            (run / "report.json").write_text('{"result":"pass","scenarios":[')
            (run / report_validation.MARKER_FILENAME).write_text("{")
            (run / "scenario-results.tsv").write_text(
                "ui-suite\tpass\t0\t0\tcaptured\tnot-applicable\t30\n"
            )
            output = root / "share.zip"

            package_volunteer_report.package(run, output)

            with zipfile.ZipFile(output) as archive:
                names = archive.namelist()
                summary = archive.read("SwiftVLC-Device-Report/SUMMARY.md").decode()
            self.assertIn("Completed scenarios: **1** (1 passed, 0 failed)", summary)
            self.assertIn("INCOMPLETE / INTERRUPTED", summary)
            self.assertNotIn("SwiftVLC-Device-Report/report.json", names)
            self.assertNotIn(
                f"SwiftVLC-Device-Report/{report_validation.MARKER_FILENAME}", names
            )

    def test_unterminated_but_well_formed_tsv_row_is_not_promoted(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            (run / "scenario-results.tsv").write_text(
                "ui-suite\tpass\t0\t0\tcaptured\tnot-applicable\t30"
            )

            scenarios, complete = package_volunteer_report.read_scenarios(run)

            self.assertFalse(complete)
            self.assertEqual(scenarios, [])

    def test_scrubs_real_ipv6_forms_without_destroying_colon_text(self):
        private_values = (
            "192.168.001.004",
            "fd00::2",
            "fe80::1%utun4",
            "http://[fe80::1%25utun4]:8080/fixture",
            "::ffff:192.0.2.1",
            "fd00::2:49152",
            "2001:db8:0:0:0:0:0:1:443",
        )
        mac_values = (
            "aa:bb:cc:dd:ee:ff",
            "00-11-22-33-44-55",
            "0011.2233.4455",
            "02:00:00:ff:fe:00:00:01",
        )
        public_text = (
            "12:34:56.789",
            "2026-09-01T12:34:56.789Z",
            "123e4567-e89b-12d3-a456-426614174000",
            "Player.swift:120:34",
            "ratio 16:9",
            "SHA256:abcdef0123456789",
        )
        scrubbed = package_volunteer_report.scrub_text(
            " | ".join((*private_values, *mac_values, *public_text))
            + " | fd00::3. | fd00::4:"
        )

        for private_value in private_values:
            self.assertNotIn(private_value, scrubbed)
        for mac_value in mac_values:
            self.assertNotIn(mac_value, scrubbed)
        for retained_value in public_text:
            self.assertIn(retained_value, scrubbed)
        self.assertNotIn("fd00::3", scrubbed)
        self.assertIn("<redacted-ip>.", scrubbed)
        self.assertNotIn("fd00::4", scrubbed)
        self.assertIn("<redacted-ip>:", scrubbed)
        self.assertGreaterEqual(scrubbed.count("<redacted-mac>"), len(mac_values))

    def test_team_scoped_app_test_and_runner_identifiers_are_scrubbed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / "run"
            run.mkdir()
            team = "ABCDE12345"
            app_identifier = "com.swiftvlc.validation.abcde12345.app"
            tests_identifier = "com.swiftvlc.validation.abcde12345.uitests"
            runner_identifier = f"{tests_identifier}.xctrunner"
            (run / "configure-signing.log").write_text(
                f"appBundleIdentifier={app_identifier}\n"
                f"uiTestBundleIdentifier={tests_identifier}\n"
            )
            (run / "build.log").write_text(
                f"DEVELOPMENT_TEAM = {team}\n" f"runner = {runner_identifier}\n"
            )
            (run / "candidate-metadata.json").write_text(
                json.dumps(
                    {
                        "candidateAppBundleIdentifier": app_identifier,
                        "testRunnerBundleIdentifier": runner_identifier,
                    }
                )
            )
            (run / "device.json").write_text(json.dumps({"selected": {}}))
            output = root / "report.zip"
            package_volunteer_report.package(run, output)
            with zipfile.ZipFile(output) as archive:
                contents = b"\n".join(
                    archive.read(name) for name in archive.namelist()
                ).decode(errors="replace")
            for secret in (
                team,
                app_identifier,
                tests_identifier,
                runner_identifier,
            ):
                self.assertNotIn(secret, contents)

    def test_metadata_bundle_identifiers_are_scrubbed_without_build_logs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / "run"
            run.mkdir()
            team = "ABCDE12345"
            app_identifier = "com.swiftvlc.validation.abcde12345.app"
            tests_identifier = "com.swiftvlc.validation.abcde12345.uitests"
            runner_identifier = f"{tests_identifier}.xctrunner"
            (run / "candidate-metadata.json").write_text(
                json.dumps(
                    {
                        "candidateAppBundleIdentifier": app_identifier,
                        "testRunnerBundleIdentifier": runner_identifier,
                    }
                )
            )
            (run / "device.json").write_text(json.dumps({"selected": {}}))
            (run / "partial.log").write_text(
                " ".join((team, app_identifier, tests_identifier, runner_identifier))
            )
            output = root / "report.zip"
            package_volunteer_report.package(run, output)
            with zipfile.ZipFile(output) as archive:
                contents = b"\n".join(
                    archive.read(name) for name in archive.namelist()
                ).decode(errors="replace")
            for secret in (
                team,
                team.lower(),
                app_identifier,
                tests_identifier,
                runner_identifier,
            ):
                self.assertNotIn(secret, contents)

    def test_evidence_only_bundle_identifiers_are_scrubbed_from_logs_and_json(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / "run"
            run.mkdir()
            secret_identifier = "com.example.private-team.device-runner"
            (run / "device.json").write_text(json.dumps({"selected": {}}))
            evidence = run / "evidence"
            evidence.mkdir()
            (evidence / "probe.json").write_text(
                json.dumps({"testRunnerBundleIdentifier": secret_identifier})
            )
            (run / "probe.log").write_text(f"runner={secret_identifier}\n")
            output = root / "report.zip"

            package_volunteer_report.package(run, output)

            with zipfile.ZipFile(output) as archive:
                contents = b"\n".join(
                    archive.read(name) for name in archive.namelist()
                ).decode(errors="replace")
            self.assertNotIn(secret_identifier, contents)


class CandidateMetadataTests(unittest.TestCase):
    def test_source_digest_is_scoped_to_the_selected_clean_checkout(self):
        source_root = Path("/tmp/SwiftVLC qualification snapshot")
        calls = []
        original = candidate_metadata.command_output

        def command_output(arguments):
            calls.append(arguments)
            if "status" in arguments:
                return ""
            if "rev-parse" in arguments:
                return "b" * 40
            return "c" * 64

        candidate_metadata.command_output = command_output
        try:
            identity = candidate_metadata.source_identity(source_root, "1.1.0")
        finally:
            candidate_metadata.command_output = original

        self.assertEqual(identity["sourceCommit"], "b" * 40)
        self.assertEqual(identity["releaseSourceDigest"], "c" * 64)
        self.assertEqual(
            calls[-1],
            [
                "python3",
                str(source_root / "scripts" / "release-source-digest.py"),
                "1.1.0",
                "--root",
                str(source_root),
            ],
        )

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

    def test_format_two_metadata_accepts_the_complete_runner_binding(self):
        catalog = ["iOSUITests/AnalyzerTests/test_pixels"]
        source_commit = "b" * 40
        release_source_digest = "c" * 64
        artifact_digest = "d" * 64
        metadata = {
            "formatVersion": 2,
            "version": "1.1.0",
            "candidateAppBundleIdentifier": "com.swiftvlc.validation.team.app",
            "sourceCommit": source_commit,
            "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
            "releaseSourceDigest": release_source_digest,
            "candidateAppDigestAlgorithm": "swiftvlc-tree-v1",
            "candidateAppDigest": "a" * 64,
            "artifactDigestAlgorithm": "swiftvlc-tree-v1",
            "artifactDigest": artifact_digest,
            **fixture_candidate_build_attestation_fields(
                source_commit=source_commit,
                release_source_digest=release_source_digest,
                artifact_digest=artifact_digest,
            ),
            "testRunnerBundleIdentifier": (
                "com.swiftvlc.validation.team.uitests.xctrunner"
            ),
            "testRunnerDigestAlgorithm": "swiftvlc-tree-v1",
            "testRunnerDigest": "e" * 64,
            "testBundleRelativePath": "PlugIns/iOSUITests.xctest",
            "testBundleDigestAlgorithm": "swiftvlc-tree-v1",
            "testBundleDigest": "f" * 64,
            "baseXCTestRunDigestAlgorithm": "sha256",
            "baseXCTestRunDigest": "1" * 64,
            "baseXCTestRunName": "iOS_iphoneos.xctestrun",
            "testCatalogDigestAlgorithm": "swiftvlc-test-catalog-v1",
            "testCatalogDigest": qualification_policy.catalog_digest(catalog),
            "testCatalogCount": 1,
            "testCatalog": catalog,
            "qualificationMatrixChecksum": "2" * 64,
            "featureManifestChecksum": "3" * 64,
            "qualificationProfilesChecksum": "4" * 64,
            "fixtureManifestChecksum": "5" * 64,
            "qualificationPolicyDigestAlgorithm": "swiftvlc-qualification-policy-v1",
            "qualificationPolicyDigest": qualification_policy.policy_digest(),
        }
        self.assertEqual(
            candidate_metadata.validate(
                metadata,
                "1.1.0",
                metadata["candidateAppDigest"],
                metadata["artifactDigest"],
            ),
            metadata,
        )
        for field, replacement in (
            ("candidateAppBundleIdentifier", "not a bundle"),
            ("testRunnerBundleIdentifier", "com.swiftvlc.validation.team.runner"),
        ):
            with self.subTest(field=field):
                malformed = dict(metadata, **{field: replacement})
                with self.assertRaises(candidate_metadata.CandidateMetadataError):
                    candidate_metadata.validate(
                        malformed,
                        "1.1.0",
                        malformed["candidateAppDigest"],
                        malformed["artifactDigest"],
                    )

    def test_runner_binding_reads_the_signed_runner_bundle_identifier(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runner = root / "iOSUITests-Runner.app"
            test_bundle = runner / "PlugIns" / "iOSUITests.xctest"
            test_bundle.mkdir(parents=True)
            runner_identifier = "com.swiftvlc.validation.team.uitests.xctrunner"
            candidate_app = root / "iOS.app"
            candidate_app.mkdir()
            with (candidate_app / "Info.plist").open("wb") as output:
                plistlib.dump(
                    {"CFBundleIdentifier": "com.swiftvlc.validation.team.app"},
                    output,
                )
            with (runner / "Info.plist").open("wb") as output:
                plistlib.dump({"CFBundleIdentifier": runner_identifier}, output)
            (test_bundle / "fixture").write_text("signed test fixture")
            xctestrun = root / "fixture.xctestrun"
            with xctestrun.open("wb") as output:
                plistlib.dump(
                    {
                        "TestConfigurations": [
                            {
                                "TestTargets": [
                                    {
                                        "IsUITestBundle": True,
                                        "CommandLineArguments": [],
                                        "UITargetAppCommandLineArguments": [],
                                        "TestHostPath": str(runner),
                                        "TestBundlePath": str(test_bundle),
                                        "UITargetAppPath": str(candidate_app),
                                        "DependentProductPaths": [
                                            str(candidate_app),
                                            str(runner),
                                            str(test_bundle),
                                        ],
                                        "TestHostBundleIdentifier": runner_identifier,
                                    }
                                ]
                            }
                        ]
                    },
                    output,
                )
            catalog = qualification_policy.catalog_record(
                ["iOSUITests/AnalyzerTests/test_pixels"]
            )
            catalog_path = root / "catalog.json"
            catalog_path.write_text(json.dumps(catalog))
            catalog_authority = root / "catalog-authority.json"
            catalog_authority.write_text(
                json.dumps(
                    {
                        "formatVersion": 1,
                        "authority": "swiftvlc-reviewed-ios-test-catalog-v1",
                        "testCatalogDigestAlgorithm": "swiftvlc-test-catalog-v1",
                        "testCatalogDigest": catalog["digest"],
                        "testCatalogCount": catalog["testCount"],
                        "testIdentifiers": catalog["testIdentifiers"],
                    }
                )
            )
            fixture_manifest = root / "fixture-manifest.json"
            fixture_manifest.write_text("{}")
            bindings = candidate_metadata.qualification_bindings(
                candidate_app=candidate_app,
                test_runner=runner,
                test_bundle=test_bundle,
                xctestrun=xctestrun,
                test_catalog=catalog_path,
                test_catalog_authority=catalog_authority,
                matrix=ROOT / "qualification" / "matrix.json",
                feature_manifest=(ROOT / "qualification" / "feature-manifest-v1.json"),
                profiles=ROOT / "qualification" / "profiles-v1.json",
                fixture_manifest=fixture_manifest,
                digest_script=ROOT / "artifact-tree-digest.py",
            )
            self.assertEqual(bindings["testRunnerBundleIdentifier"], runner_identifier)

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
                        "CFBundleIdentifier": "com.swiftvlc.validation.team.app",
                        "SwiftVLCCandidateVersion": "1.1.0",
                        "SwiftVLCCandidateRuntimeBinding": "e" * 64,
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
            self.assertEqual(
                metadata["candidateAppBundleIdentifier"],
                "com.swiftvlc.validation.team.app",
            )

            forged = dict(metadata, sourceCommit="d" * 40)
            with self.assertRaises(candidate_metadata.CandidateMetadataError):
                candidate_metadata.verify(
                    forged, app, xcframework, "1.1.0", digest_script
                )
            forged = dict(
                metadata,
                candidateAppBundleIdentifier="com.swiftvlc.validation.other.app",
            )
            with self.assertRaises(candidate_metadata.CandidateMetadataError):
                candidate_metadata.verify(
                    forged, app, xcframework, "1.1.0", digest_script
                )
            malformed = dict(metadata, candidateAppBundleIdentifier="not a bundle")
            with self.assertRaises(candidate_metadata.CandidateMetadataError):
                candidate_metadata.validate(
                    malformed,
                    "1.1.0",
                    malformed["candidateAppDigest"],
                    malformed["artifactDigest"],
                )

    def test_format_two_verification_rejects_valid_but_swapped_bundle_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "iOS.app"
            app.mkdir()
            xcframework = root / "libvlc.xcframework"
            xcframework.mkdir()
            with (app / "Info.plist").open("wb") as output:
                plistlib.dump(
                    {
                        "CFBundleIdentifier": "com.swiftvlc.validation.team.app",
                        "SwiftVLCCandidateVersion": "1.1.0",
                        "SwiftVLCCandidateRuntimeBinding": "e" * 64,
                        "SwiftVLCSourceCommit": "b" * 40,
                        "SwiftVLCReleaseSourceDigest": "c" * 64,
                        "SwiftVLCArtifactDigest": "a" * 64,
                    },
                    output,
                )
            digest_script = root / "digest.py"
            digest_script.write_text(f'print("{"a" * 64}")\n')
            catalog = ["iOSUITests/AnalyzerTests/test_pixels"]
            bindings = {
                "testRunnerBundleIdentifier": (
                    "com.swiftvlc.validation.team.uitests.xctrunner"
                ),
                "testRunnerDigestAlgorithm": "swiftvlc-tree-v1",
                "testRunnerDigest": "e" * 64,
                "testBundleRelativePath": "PlugIns/iOSUITests.xctest",
                "testBundleDigestAlgorithm": "swiftvlc-tree-v1",
                "testBundleDigest": "f" * 64,
                "baseXCTestRunDigestAlgorithm": "sha256",
                "baseXCTestRunDigest": "1" * 64,
                "baseXCTestRunName": "iOS_iphoneos.xctestrun",
                "testCatalogDigestAlgorithm": "swiftvlc-test-catalog-v1",
                "testCatalogDigest": qualification_policy.catalog_digest(catalog),
                "testCatalogCount": 1,
                "testCatalog": catalog,
                "testCatalogAuthorityDigestAlgorithm": "sha256",
                "testCatalogAuthorityDigest": "0" * 64,
                "qualificationMatrixChecksum": "2" * 64,
                "featureManifestChecksum": "3" * 64,
                "qualificationProfilesChecksum": "4" * 64,
                "fixtureManifestChecksum": "5" * 64,
                "qualificationPolicyDigestAlgorithm": (
                    "swiftvlc-qualification-policy-v1"
                ),
                "qualificationPolicyDigest": qualification_policy.policy_digest(),
            }
            build_attestation = fixture_candidate_build_attestation_fields(
                source_commit="b" * 40,
                release_source_digest="c" * 64,
                artifact_digest="a" * 64,
            )["candidateBuildAttestation"]
            metadata = candidate_metadata.create(
                app,
                xcframework,
                "1.1.0",
                digest_script,
                bindings,
                build_attestation,
            )
            for field, replacement in (
                (
                    "candidateAppBundleIdentifier",
                    "com.swiftvlc.validation.other.app",
                ),
                (
                    "testRunnerBundleIdentifier",
                    "com.swiftvlc.validation.other.uitests.xctrunner",
                ),
            ):
                with self.subTest(field=field):
                    forged = dict(metadata, **{field: replacement})
                    with self.assertRaises(candidate_metadata.CandidateMetadataError):
                        candidate_metadata.verify(
                            forged,
                            app,
                            xcframework,
                            "1.1.0",
                            digest_script,
                            bindings,
                        )


class FixtureManifestTests(unittest.TestCase):
    def test_local_playback_fixture_contract_is_shared_and_decode_verified(self):
        contract = qualification_policy.LOCAL_PLAYBACK_FIXTURE_CONTRACT
        self.assertEqual(
            verify_fixtures.EXPECTED_RELEASE_FIXTURE_METADATA["localPlayback"],
            contract,
        )
        self.assertEqual(len(contract["video"]), 5)
        self.assertEqual(len(contract["audio"]), 6)
        self.assertEqual(
            {row["container"] for row in contract["video"]},
            {"mp4", "matroska", "webm", "mpegts"},
        )
        self.assertEqual(
            {row["audioCodec"] for row in contract["audio"]},
            {"aac", "alac", "mp3", "flac", "opus", "pcm_s16le"},
        )
        generator = (ROOT / "qualification" / "generate-fixtures.sh").read_text()
        verifier = (ROOT / "qualification" / "verify-fixtures.py").read_text()
        swift_contract = (
            ROOT.parent
            / "Showcase"
            / "Shared"
            / "LocalPlaybackQualificationContract.swift"
        ).read_text()
        for kind in ("video", "audio"):
            for fixture in contract[kind]:
                with self.subTest(fixture=fixture["id"]):
                    self.assertIn(fixture["id"], generator)
                    self.assertIn(fixture["path"], generator)
                    self.assertIn(fixture["id"], swift_contract)
                    self.assertIn(fixture["path"], swift_contract)
        self.assertIn("+frag_keyframe+empty_moov+default_base_moof", generator)
        self.assertIn("_validate_local_video_motion(path)", verifier)
        self.assertIn("_validate_local_audio_signal(path)", verifier)
        self.assertIn('b"moof" not in payload', verifier)

    def test_progressive_range_fixture_is_large_content_coded_and_decode_verified(self):
        generator = (ROOT / "qualification" / "generate-fixtures.sh").read_text()
        verifier = (ROOT / "qualification" / "verify-fixtures.py").read_text()
        self.assertIn('"$fixture_tmp/oracles/progressive-range.mp4"', generator)
        self.assertIn("-b:v 4000k -minrate 4000k -maxrate 4000k", generator)
        self.assertIn("nal-hrd=cbr:filler=1", generator)
        self.assertIn("-g 300 -keyint_min 300 -sc_threshold 0", generator)
        self.assertIn("[0:v]split=2[first][second]", generator)
        self.assertIn("drawbox=x=480:y=300:w=120:h=40:color=white:t=fill", generator)
        self.assertIn("-frames:v 3600", generator)
        self.assertIn('"minimumBytes": 50000000', generator)
        self.assertIn("progressive_path.stat().st_size", verifier)
        self.assertIn("for seconds in (43.5, 103.5)", verifier)
        self.assertIn("cycle != expected_cycle", verifier)
        self.assertEqual(
            verify_fixtures.EXPECTED_RELEASE_ORACLES["progressiveHTTPRange"][
                "timelineCycleIndicator"
            ]["secondHalfStartSeconds"],
            60,
        )
        self.assertEqual(
            verify_fixtures.EXPECTED_RELEASE_ORACLES["progressiveHTTPRange"][
                "minimumBytes"
            ],
            50_000_000,
        )

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

    def test_release_oracle_contract_cannot_be_self_signed_away(self):
        manifest = {
            "formatVersion": 1,
            "oracles": verify_fixtures.EXPECTED_RELEASE_ORACLES,
            "files": {
                oracle["path"]: {"bytes": 1, "sha256": "0" * 64}
                for oracle in verify_fixtures.EXPECTED_RELEASE_ORACLES.values()
            },
        }
        verify_fixtures.verify_release_oracles(manifest)

        weakened = json.loads(json.dumps(manifest))
        weakened["oracles"]["frameAllIntra"]["allIntra"] = False
        with self.assertRaises(verify_fixtures.FixtureVerificationError):
            verify_fixtures.verify_release_oracles(weakened)

        weakened_progressive = json.loads(json.dumps(manifest))
        weakened_progressive["oracles"]["progressiveHTTPRange"]["minimumBytes"] = 1
        with self.assertRaises(verify_fixtures.FixtureVerificationError):
            verify_fixtures.verify_release_oracles(weakened_progressive)

        missing = json.loads(json.dumps(manifest))
        missing["files"].pop("oracles/seek-sparse-gop.mp4")
        with self.assertRaises(verify_fixtures.FixtureVerificationError):
            verify_fixtures.verify_release_oracles(missing)

        missing_progressive = json.loads(json.dumps(manifest))
        missing_progressive["files"].pop("oracles/progressive-range.mp4")
        with self.assertRaises(verify_fixtures.FixtureVerificationError):
            verify_fixtures.verify_release_oracles(missing_progressive)

    def test_release_seek_oracle_rejects_a_declared_band_without_a_marker(self):
        solid_band = bytes((0xC0, 0x20, 0x20)) * (640 * 360)

        with self.assertRaises(verify_fixtures.FixtureVerificationError):
            verify_fixtures._seek_pixel_observation(solid_band)

    def test_progressive_cycle_indicator_distinguishes_the_second_minute(self):
        frame = bytearray(bytes((0xA0, 0x20, 0xA0)) * (640 * 360))
        self.assertEqual(verify_fixtures._progressive_cycle_index(frame), 0)
        for y in range(300, 340):
            for x in range(480, 600):
                offset = (y * 640 + x) * 3
                frame[offset : offset + 3] = b"\xff\xff\xff"
        self.assertEqual(verify_fixtures._progressive_cycle_index(frame), 1)

    def test_release_seek_oracle_decodes_the_encoded_marker_contract(self):
        frame = bytearray(bytes((0x20, 0x40, 0xC0)) * (640 * 360))
        marker_x = 40 + 3 * 56
        for y in range(80, 280):
            for x in range(marker_x, marker_x + 24):
                offset = (y * 640 + x) * 3
                frame[offset : offset + 3] = b"\xff\xff\xff"

        band, observed_x, color_distance, marker_contrast = (
            verify_fixtures._seek_pixel_observation(bytes(frame))
        )

        self.assertEqual(band, 2)
        self.assertEqual(observed_x, marker_x)
        self.assertEqual(color_distance, 0)
        self.assertGreater(marker_contrast, 100)

    def test_release_all_intra_oracle_decodes_a_frame_code(self):
        color = tuple(int(component) for component in verify_fixtures._frame_color(73))
        frame = bytes(color) * (640 * 360)

        index, distance, margin = verify_fixtures._all_intra_pixel_observation(frame)

        self.assertEqual(index, 73)
        self.assertEqual(distance, 0)
        self.assertGreaterEqual(margin, 8)


class QualificationEvidenceTests(unittest.TestCase):
    qualification_session_binding = "d" * 64
    candidate_runtime_binding = "e" * 64

    def materialize(self, *args, **kwargs):
        kwargs.setdefault(
            "expected_qualification_session_binding",
            self.qualification_session_binding,
        )
        kwargs.setdefault(
            "expected_candidate_runtime_binding",
            self.candidate_runtime_binding,
        )
        return materialize_evidence.materialize(*args, **kwargs)

    def test_runtime_bindings_are_independently_required_matched_and_stripped(self):
        payload = {
            "scenario": "fixture",
            "qualificationSessionBinding": self.qualification_session_binding,
            "candidateRuntimeBinding": self.candidate_runtime_binding,
        }
        self.assertEqual(
            qualification_policy.validate_and_strip_qualification_runtime_bindings(
                payload,
                expected_session_binding=self.qualification_session_binding,
                expected_candidate_binding=self.candidate_runtime_binding,
            ),
            {"scenario": "fixture"},
        )
        mutations = (
            ({"qualificationSessionBinding": None}, "qualification session"),
            ({"qualificationSessionBinding": "D" * 64}, "qualification session"),
            ({"qualificationSessionBinding": "c" * 64}, "qualification session"),
            ({"candidateRuntimeBinding": None}, "candidate runtime"),
            ({"candidateRuntimeBinding": "E" * 64}, "candidate runtime"),
            ({"candidateRuntimeBinding": "f" * 64}, "candidate runtime"),
        )
        for mutation, description in mutations:
            with self.subTest(mutation=mutation):
                with self.assertRaisesRegex(
                    qualification_policy.QualificationPolicyError,
                    description,
                ):
                    qualification_policy.validate_and_strip_qualification_runtime_bindings(
                        {**payload, **mutation},
                        expected_session_binding=self.qualification_session_binding,
                        expected_candidate_binding=self.candidate_runtime_binding,
                    )

    def test_materializer_cannot_self_authenticate_raw_runtime_bindings(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "vod-controls",
                    "controls": "pass",
                },
                attachment_name="qualification-vod-controls.json",
                test_identifier=(
                    "PiPVODControlsDeviceUITests/"
                    "test_vodControlsAcrossNativeAndDirectBackends"
                ),
            )
            with self.assertRaisesRegex(
                materialize_evidence.EvidenceError,
                "expected qualification session binding",
            ):
                materialize_evidence.materialize(
                    root,
                    "qualification-vod-controls.json",
                    "vod-controls",
                    "iphone-current",
                    "a" * 64,
                    "b" * 64,
                )

    @staticmethod
    def artifact_producer(runner: str, attempt: int = 1) -> dict:
        return {
            "runnerScenario": runner,
            "sourceAttempt": attempt,
            "sourceXcresultDigest": "9" * 64,
        }

    @staticmethod
    def xctrace_summary(
        trace: Path,
        toc: Path,
        *,
        scenario_id: str,
        role: str,
        template: str,
        target_device_identifier: str,
        producer_fields: dict,
    ) -> dict:
        full_duration = qualification_policy.STABLE_MINIMUM_DURATION_SECONDS[
            scenario_id
        ]
        minimum_duration = qualification_policy.trace_minimum_capture_duration(
            scenario_id, role, full_duration
        )
        metric, unit = qualification_policy.TRACE_MEASUREMENT_SPECS[role]
        return {
            "formatVersion": 1,
            "status": "captured",
            "source": "xctrace-export-v1",
            "runNumber": 1,
            "scenario": scenario_id,
            "artifactRole": role,
            "template": template,
            "targetProcess": "iOS",
            "targetDeviceIdentifier": target_device_identifier,
            "captureDurationSeconds": minimum_duration,
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
                "timelineEndSeconds": minimum_duration,
                "maximumSampleGapSeconds": 1.0,
                "sourceFields": [f"{role}-fixture-value"],
            },
            "traceTreeDigestAlgorithm": "swiftvlc-tree-v1",
            "traceTreeDigest": qualification_policy.tree_digest(trace),
            "tableOfContentsDigestAlgorithm": "sha256",
            "tableOfContentsDigest": qualification_policy.sha256_file(toc),
            **producer_fields,
        }

    def make_export(
        self,
        root: Path,
        payload: dict,
        attachment_count: int = 1,
        attachment_name: str = "qualification-native-hls-seek-continuity.json",
        test_identifier: str = "iOSUITests/PiPOverlayDeviceUITests/test_nativePiPHLSSeeksRemainActive",
    ):
        payload = {
            **payload,
            "qualificationSessionBinding": self.qualification_session_binding,
            "candidateRuntimeBinding": self.candidate_runtime_binding,
        }
        exported = root / "attachment.json"
        exported.write_text(json.dumps(payload))
        attachment = {
            "exportedFileName": exported.name,
            "suggestedHumanReadableName": attachment_name,
        }
        canonical_identifier = (
            test_identifier
            if test_identifier.startswith("iOSUITests/")
            else f"iOSUITests/{test_identifier}"
        )
        short_identifier = "/".join(canonical_identifier.split("/")[-2:]) + "()"
        manifest = [
            {
                "testIdentifier": short_identifier,
                "testIdentifierURL": (
                    "test://com.apple.xcode/SwiftVLCShowcase/" f"{canonical_identifier}"
                ),
                "attachments": [attachment] * attachment_count,
            }
        ]
        (root / "manifest.json").write_text(json.dumps(manifest))

    def make_delayed_start_export(self, root: Path) -> None:
        owner = (
            "iOSUITests/PiPDelayedStartFailureDeviceUITests/"
            "test_acceptedStartRetainsAttributionThroughDelayedFailure"
        )
        payloads = {
            "qualification-failed-start.json": {
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
            "qualification-accepted-start-delayed-failure.json": {
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
        }
        attachments = []
        for index, (name, payload) in enumerate(payloads.items()):
            payload = {
                **payload,
                "qualificationSessionBinding": self.qualification_session_binding,
                "candidateRuntimeBinding": self.candidate_runtime_binding,
            }
            exported = root / f"delayed-start-{index}.json"
            exported.write_text(json.dumps(payload))
            attachments.append(
                {
                    "exportedFileName": exported.name,
                    "suggestedHumanReadableName": name,
                }
            )
        (root / "manifest.json").write_text(
            json.dumps(
                [
                    {
                        "testIdentifier": (
                            "PiPDelayedStartFailureDeviceUITests/"
                            "test_acceptedStartRetainsAttributionThroughDelayedFailure()"
                        ),
                        "testIdentifierURL": (
                            "test://com.apple.xcode/SwiftVLCShowcase/" + owner
                        ),
                        "attachments": attachments,
                    }
                ]
            )
        )

    def test_materializes_test_payload_with_host_owned_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "native-hls-seek-continuity",
                    "seekResults": {"forward": "pass"},
                    "commandEvidence": {
                        "forward": {
                            "command": "forward",
                            "outcome": "pass",
                            "accepted": True,
                            "durationMilliseconds": 60_000,
                            "baselineNativeTimeMilliseconds": 2_000,
                            "expectedTimeMilliseconds": 12_000,
                            "landingToleranceMilliseconds": 3_000,
                            "landingNativeTimeMilliseconds": 12_100,
                            "postCommandDisplayedPictures": 12,
                            "displayedPicturesAtLanding": 13,
                            "finalDisplayedPictures": 14,
                            "commandToRecoveryMilliseconds": 400,
                        }
                    },
                },
            )
            evidence = self.materialize(
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
            command = evidence["commandEvidence"]["forward"]
            self.assertEqual(command["command"], "forward")
            self.assertGreater(
                command["finalDisplayedPictures"],
                command["displayedPicturesAtLanding"],
            )

    def test_materializes_xcode_decorated_attachment_name(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "vod-controls",
                    "controls": "pass",
                },
                attachment_name=(
                    "qualification-vod-controls_0_"
                    "363D852A-C7EB-4013-A3F0-3C775E761E8D.json"
                ),
                test_identifier=(
                    "PiPVODControlsDeviceUITests/"
                    "test_vodControlsAcrossNativeAndDirectBackends"
                ),
            )
            evidence = self.materialize(
                root,
                "qualification-vod-controls.json",
                "vod-controls",
                "iphone-current",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["controls"], "pass")

    def test_rejects_names_that_only_resemble_xcode_decoration(self):
        uuid = "363D852A-C7EB-4013-A3F0-3C775E761E8D"
        invalid_names = [
            f"qualification-vod-controls-extra_0_{uuid}.json",
            f"qualification-vod-controls_00_{uuid}.json",
            "qualification-vod-controls_0_not-a-uuid.json",
            f"qualification-vod-controls_0_{uuid}.json.bak",
            f"qualification-vod-controls_0_{uuid}.JSON",
        ]
        for invalid_name in invalid_names:
            with self.subTest(invalid_name=invalid_name):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    self.make_export(
                        root,
                        {"scenario": "vod-controls"},
                        attachment_name=invalid_name,
                    )
                    with self.assertRaisesRegex(
                        materialize_evidence.EvidenceError,
                        "unauthorized qualification attachment",
                    ):
                        self.materialize(
                            root,
                            "qualification-vod-controls.json",
                            "vod-controls",
                            "iphone-current",
                            "a" * 64,
                            "b" * 64,
                        )

    def test_rejects_exact_and_decorated_logical_duplicates(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {"scenario": "vod-controls"},
                attachment_name="qualification-vod-controls.json",
                test_identifier=(
                    "PiPVODControlsDeviceUITests/"
                    "test_vodControlsAcrossNativeAndDirectBackends"
                ),
            )
            manifest = json.loads((root / "manifest.json").read_text())
            manifest[0]["attachments"].append(
                {
                    "exportedFileName": "attachment.json",
                    "suggestedHumanReadableName": (
                        "qualification-vod-controls_1_"
                        "363D852A-C7EB-4013-A3F0-3C775E761E8D.json"
                    ),
                }
            )
            (root / "manifest.json").write_text(json.dumps(manifest))
            with self.assertRaisesRegex(
                materialize_evidence.EvidenceError,
                "attachment counts mismatch",
            ):
                        self.materialize(
                    root,
                    "qualification-vod-controls.json",
                    "vod-controls",
                    "iphone-current",
                    "a" * 64,
                    "b" * 64,
                )

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
            evidence = self.materialize(
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
            evidence = self.materialize(
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
            evidence = self.materialize(
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
                    "faultInjection": {
                        "rawEventsSuppressed": True,
                        "nativePlayerObserverExercised": True,
                        "nativeControllerObserverExercised": True,
                        "directPlayerObserverExercised": True,
                        "directControllerObserverExercised": True,
                        "nativePlayerLengthEvents": 2,
                        "nativePlayerSeekableEvents": 1,
                        "nativeControllerLengthEvents": 2,
                        "nativeControllerSeekableEvents": 1,
                        "directPlayerLengthEvents": 2,
                        "directPlayerSeekableEvents": 1,
                        "directControllerLengthEvents": 2,
                        "directControllerSeekableEvents": 1,
                    },
                },
                attachment_name="qualification-capability-convergence.json",
                test_identifier="PiPCapabilityDeviceUITests/test_capabilityConvergenceAcrossNativeAndDirectBackends",
            )
            evidence = self.materialize(
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
            for field in (
                "nativePlayerLengthEvents",
                "nativePlayerSeekableEvents",
                "nativeControllerLengthEvents",
                "nativeControllerSeekableEvents",
                "directPlayerLengthEvents",
                "directPlayerSeekableEvents",
                "directControllerLengthEvents",
                "directControllerSeekableEvents",
            ):
                self.assertGreater(evidence["faultInjection"][field], 0)

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
            evidence = self.materialize(
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
            evidence = self.materialize(
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
            evidence = self.materialize(
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
            self.assertEqual(
                evidence["backendResults"]["direct"]["memory"]["growthBytes"], 2048
            )

    def test_materializes_restore_and_close_evidence(self):
        for scenario, restore_count, reason in (
            ("restore", 1, "restoreRequested"),
            ("close", 0, "userClosed"),
        ):
            with self.subTest(
                scenario=scenario
            ), tempfile.TemporaryDirectory() as temporary:
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
                evidence = self.materialize(
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
            evidence = self.materialize(
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
                "failed-start": {"orderedEvents": ["willStart", "failedToStart"]},
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
            evidence = self.materialize(
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
            evidence = self.materialize(
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
            self.assertEqual(
                evidence["failureClassifications"], failure_classifications
            )
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
            evidence = self.materialize(
                root,
                "qualification-adaptive-hls-soak.json",
                "adaptive-hls-soak",
                "iphone-current",
                "a" * 64,
                "b" * 64,
                duration_seconds=7200,
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
                        "deviceObservedDurationSeconds": 7200,
                        "deviceIdentifier": "fixture-device",
                        "allocationProvenance": {"allocator": "malloc"},
                        "qualificationProducer": self.artifact_producer(
                            "adaptive-hls-soak"
                        ),
                    }
                )
            )
            trace = root / "adaptive-hls-soak-allocations-attempt1.trace"
            trace.mkdir()
            (trace / "data.bin").write_bytes(b"candidate allocation stacks")
            toc = root / "adaptive-hls-soak-allocations-attempt1-toc.xml"
            toc.write_text('<table schema="allocations"/>')
            digest_script = (
                Path(__file__).resolve().parents[2] / "artifact-tree-digest.py"
            )

            with mock.patch.object(
                augment_allocation_trace.policy,
                "capture_xctrace_export_summary",
                side_effect=self.xctrace_summary,
            ):
                augmented = augment_allocation_trace.augment(
                    evidence, trace, toc, digest_script
                )
            record = augmented["allocationProvenance"]["instrumentsTrace"]
            self.assertRegex(record["treeDigest"], r"^[0-9a-f]{64}$")
            self.assertEqual(record["template"], "Allocations")
            self.assertEqual(
                record["runArtifact"],
                "artifacts/evidence/adaptive-hls-soak-allocations-attempt1.trace",
            )
            self.assertTrue((evidence.parent / record["runArtifact"]).is_dir())
            self.assertTrue((evidence.parent / record["tableOfContents"]).is_file())

            toc.write_text("<trace-toc/>")
            with self.assertRaises(augment_allocation_trace.TraceEvidenceError):
                augment_allocation_trace.augment(evidence, trace, toc, digest_script)

    def test_materializes_cadence_matrix_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            rates = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]
            payload = {
                "formatVersion": 1,
                "scenario": "cadence-matrix",
                "durationSeconds": 600,
                "samples": [
                    {"elapsedSeconds": 0},
                    {"elapsedSeconds": 600},
                ],
                "rates": rates,
                "vfr": True,
                "presentationMetrics": [
                    {"profile": str(rate), "deliveredFrames": 100, "dropRate": 0}
                    for rate in rates
                ]
                + [{"profile": "vfr-24-60", "deliveredFrames": 100, "dropRate": 0}],
                "transitionResults": {
                    "rateChanges": 36,
                    "pauseResumeCycles": 9,
                    "replacements": 8,
                    "resizeCycles": 4,
                    "resizeTargets": ["640x360", "320x180"],
                    "monotonicityViolations": 0,
                },
                "fabricatedDurationCount": 0,
            }
            self.make_export(
                root,
                payload,
                attachment_name="qualification-cadence-matrix.json",
                test_identifier="PiPCadenceDeviceUITests/test_directPiPCadenceMatrix",
            )
            evidence = self.materialize(
                root,
                "qualification-cadence-matrix.json",
                "cadence-matrix",
                "iphone-current",
                "a" * 64,
                "b" * 64,
                duration_seconds=600,
            )
            self.assertEqual(evidence["hardware"], "iphone-current")
            self.assertEqual(evidence["rates"], rates)
            self.assertTrue(evidence["vfr"])
            self.assertEqual(len(evidence["presentationMetrics"]), 9)
            self.assertEqual(evidence["fabricatedDurationCount"], 0)

    def test_host_binds_all_performance_trace_digests(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = root / "evidence.json"
            evidence.write_text(
                json.dumps(
                    {
                        "scenario": "pip-render-performance-4k60",
                        "deviceObservedDurationSeconds": 900,
                        "deviceIdentifier": "fixture-device",
                        "metrics": {
                            "gpu": {"status": "required-host-augmentation"},
                            "energy": {"status": "required-host-augmentation"},
                            "conversionCost": {
                                "sourcePixels": 3840 * 2160,
                                "averageMilliseconds": 1.0,
                                "maximumMilliseconds": 1.0,
                                "hostTraceStatus": "required-host-augmentation",
                            },
                        },
                        "hostTraceRequirements": {},
                        "qualificationProducer": self.artifact_producer(
                            "pip-render-performance-4k60"
                        ),
                    }
                )
            )
            traces = {}
            for key in ("game", "power", "time"):
                basename = f"pip-render-performance-4k60-{key}-attempt1"
                trace = root / f"{basename}.trace"
                trace.mkdir()
                (trace / "data.bin").write_bytes(f"{key} instrument data".encode())
                toc = root / f"{basename}-toc.xml"
                toc.write_text('<trace-toc><table schema="samples"/></trace-toc>')
                traces[key] = (trace, toc)
            digest_script = (
                Path(__file__).resolve().parents[2] / "artifact-tree-digest.py"
            )

            with mock.patch.object(
                augment_performance_traces.policy,
                "capture_xctrace_export_summary",
                side_effect=self.xctrace_summary,
            ):
                augmented = augment_performance_traces.augment(
                    evidence, traces, digest_script
                )
            self.assertNotIn("hostTraceRequirements", augmented)
            self.assertEqual(augmented["metrics"]["gpu"]["status"], "captured")
            self.assertEqual(
                augmented["metrics"]["energy"]["template"], "Power Profiler"
            )
            conversion_trace = augmented["metrics"]["conversionCost"]["hostTrace"]
            self.assertEqual(conversion_trace["template"], "Time Profiler")
            self.assertRegex(conversion_trace["treeDigest"], r"^[0-9a-f]{64}$")
            for record in (
                augmented["metrics"]["gpu"],
                augmented["metrics"]["energy"],
                conversion_trace,
            ):
                self.assertTrue((evidence.parent / record["runArtifact"]).is_dir())
                self.assertTrue((evidence.parent / record["tableOfContents"]).is_file())

            (traces["game"][0] / "data.bin").unlink()
            with self.assertRaises(augment_performance_traces.PerformanceTraceError):
                augment_performance_traces.augment(evidence, traces, digest_script)

    def test_materializes_and_augments_native_subtitle_matrix(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            support = {
                key: "supported"
                for key in ("text", "styled", "bitmap", "forced", "live", "osd")
            }
            payload = {
                "formatVersion": 1,
                "scenario": "native-subtitle-matrix",
                "durationSeconds": 900,
                "supportMatrix": support,
                "timingTransitions": [{"profile": "text", "pauseResume": "pass"}],
                "metrics": {
                    "cpu": {
                        "value": 10,
                        "hostTraceStatus": "required-host-augmentation",
                    },
                    "gpu": {"status": "required-host-augmentation"},
                    "colorHDRImpact": {
                        "sourcePixelFormat": "yuv420p10le",
                        "screenshotMeasurements": {
                            "baseline": {},
                            "hdrWithSubtitle": {},
                        },
                        "hostTraceStatus": "required-host-augmentation",
                    },
                    "samples": [
                        {"elapsedSeconds": 0},
                        {"elapsedSeconds": 900},
                    ],
                },
                "hostTraceRequirements": {},
            }
            self.make_export(
                root,
                payload,
                attachment_name="qualification-native-subtitle-matrix.json",
                test_identifier="NativeSubtitleMatrixDeviceUITests/test_nativeSubtitleMatrixIsVisibleAndBounded",
            )
            evidence = self.materialize(
                root,
                "qualification-native-subtitle-matrix.json",
                "native-subtitle-matrix",
                "iphone-current",
                "a" * 64,
                "b" * 64,
                duration_seconds=900,
            )
            evidence["qualificationProducer"] = self.artifact_producer(
                "native-subtitle-matrix"
            )
            evidence["deviceIdentifier"] = "fixture-device"
            evidence_path = root / "evidence.json"
            evidence_path.write_text(json.dumps(evidence))
            traces = {}
            for key in ("time", "game", "metal"):
                basename = f"native-subtitle-matrix-{key}-attempt1"
                trace = root / f"{basename}.trace"
                trace.mkdir()
                (trace / "data.bin").write_bytes(f"{key} trace".encode())
                toc = root / f"{basename}-toc.xml"
                toc.write_text('<trace-toc><table schema="samples"/></trace-toc>')
                traces[key] = (trace, toc)
            digest_script = (
                Path(__file__).resolve().parents[2] / "artifact-tree-digest.py"
            )
            with mock.patch.object(
                augment_native_subtitle_traces.policy,
                "capture_xctrace_export_summary",
                side_effect=self.xctrace_summary,
            ):
                augmented = augment_native_subtitle_traces.augment(
                    evidence_path, traces, digest_script
                )
            self.assertEqual(augmented["supportMatrix"], support)
            self.assertNotIn("hostTraceRequirements", augmented)
            self.assertEqual(
                augmented["metrics"]["cpu"]["hostTrace"]["template"],
                "Time Profiler",
            )
            self.assertEqual(
                augmented["metrics"]["gpu"]["template"], "Game Performance"
            )
            self.assertEqual(
                augmented["metrics"]["colorHDRImpact"]["hostTrace"]["template"],
                "Metal System Trace",
            )
            records = (
                augmented["metrics"]["cpu"]["hostTrace"],
                augmented["metrics"]["gpu"],
                augmented["metrics"]["colorHDRImpact"]["hostTrace"],
            )
            for record in records:
                self.assertEqual(record["treeDigestAlgorithm"], "swiftvlc-tree-v1")
                self.assertFalse(Path(record["runArtifact"]).is_absolute())
                self.assertFalse(Path(record["tableOfContents"]).is_absolute())
                staged_trace = evidence_path.parent / record["runArtifact"]
                staged_toc = evidence_path.parent / record["tableOfContents"]
                self.assertTrue(staged_trace.is_dir())
                self.assertTrue((staged_trace / "data.bin").is_file())
                self.assertTrue(staged_toc.is_file())

    def test_augments_timebase_raw_capture_and_audio_trace(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            raw = root / "swiftvlc-timebase-fixture-vod-1-vod.jsonl"
            with raw.open("w") as output:
                for index in range(7200):
                    rate = (0.5, 1.0, 2.0)[index // 2400]
                    media_time = (
                        index * 0.5
                        if index < 2400
                        else (
                            1200 + (index - 2400)
                            if index < 4800
                            else 3600 + (index - 4800) * 2
                        )
                    )
                    sample = timebase_raw_sample(index, rate, media_time)
                    output.write(json.dumps(sample) + "\n")
                output.write(json.dumps(timebase_raw_correction(8)) + "\n")
                output.write(
                    json.dumps(
                        timebase_raw_correction(
                            9, reason="playbackRateTransition", drift=0
                        )
                    )
                    + "\n"
                )
            evidence_path = root / "evidence.json"
            evidence_path.write_text(
                json.dumps(
                    {
                        "scenario": "timebase-vod-soak",
                        "durationSeconds": 7200,
                        "deviceObservedDurationSeconds": 7200,
                        "deviceIdentifier": "fixture-device",
                        "corrections": [{"sequence": 8}, {"sequence": 9}],
                        "driftBudget": {"maximumSeconds": 2.1},
                        "correctionBudget": {"maximumSeconds": 2.1},
                        "audioPresentationSeries": {
                            "hostTraceStatus": "required-host-augmentation"
                        },
                        "rawCapture": {
                            "fileName": raw.name,
                            "sampleIntervalSeconds": 1,
                        },
                        "hostTraceRequirements": {
                            "audioPresentationSeries": "Audio System Trace"
                        },
                        "qualificationProducer": self.artifact_producer(
                            "timebase-vod-soak"
                        ),
                    }
                )
            )
            trace = root / "timebase-vod-soak-audio-attempt1.trace"
            trace.mkdir()
            (trace / "data.bin").write_bytes(b"audio trace")
            toc = root / "timebase-vod-soak-audio-attempt1-toc.xml"
            toc.write_text('<trace-toc><table schema="audio-io"/></trace-toc>')
            digest_script = (
                Path(__file__).resolve().parents[2] / "artifact-tree-digest.py"
            )
            with mock.patch.object(
                augment_timebase_evidence.policy,
                "capture_xctrace_export_summary",
                side_effect=self.xctrace_summary,
            ):
                augmented = augment_timebase_evidence.augment(
                    evidence_path, root, trace, toc, digest_script
                )
            self.assertEqual(augmented["rawCapture"]["sampleCount"], 7200)
            self.assertEqual(augmented["rawCapture"]["firstCorrectionSequence"], 8)
            self.assertEqual(
                augmented["audioPresentationSeries"]["hostTrace"]["template"],
                "Audio System Trace",
            )
            raw_record = augmented["rawCapture"]
            trace_record = augmented["audioPresentationSeries"]["hostTrace"]
            self.assertEqual(raw_record["digestAlgorithm"], "sha256")
            self.assertTrue(
                (evidence_path.parent / raw_record["runArtifact"]).is_file()
            )
            self.assertTrue(
                (evidence_path.parent / trace_record["runArtifact"]).is_dir()
            )
            self.assertTrue(
                (evidence_path.parent / trace_record["tableOfContents"]).is_file()
            )
            self.assertNotIn("hostTraceRequirements", augmented)

    def test_timebase_route_enables_decoded_frame_clock_before_sampling(self):
        source = (
            ROOT.parent
            / "Showcase"
            / "iOS"
            / "ValidationHarness"
            / "TimebaseSoakValidationCase.swift"
        ).read_text()
        self.assertLess(
            source.index("controller.enableFrameContentDiagnostics()"),
            source.index("controller.timebaseDiagnosticSnapshot()"),
        )

    def test_rejects_gap_in_raw_timebase_corrections(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            raw = root / "capture.jsonl"
            lines = [
                timebase_raw_sample(0, 1, 0),
                timebase_raw_correction(4),
                timebase_raw_correction(6),
            ]
            raw.write_text("".join(json.dumps(line) + "\n" for line in lines))
            with self.assertRaises(augment_timebase_evidence.TimebaseEvidenceError):
                augment_timebase_evidence.raw_record(
                    root,
                    {"fileName": raw.name, "sampleIntervalSeconds": 1},
                    1,
                )

    def test_rejects_raw_timebase_capture_without_drift_samples(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            raw = root / "capture.jsonl"
            sample = timebase_raw_sample(0, 1, 0)
            sample["clock"].pop("driftSeconds")
            raw.write_text(json.dumps(sample) + "\n")
            with self.assertRaisesRegex(
                augment_timebase_evidence.TimebaseEvidenceError,
                "missing clock-drift samples",
            ):
                augment_timebase_evidence.raw_record(
                    root,
                    {"fileName": raw.name, "sampleIntervalSeconds": 1},
                    1,
                )

    def test_rejects_duplicate_raw_timebase_timeline_samples(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            raw = root / "capture.jsonl"
            sample = timebase_raw_sample(0, 1, 0)
            raw.write_text(json.dumps(sample) + "\n" + json.dumps(sample) + "\n")
            with self.assertRaisesRegex(
                augment_timebase_evidence.TimebaseEvidenceError,
                "timeline is not strictly increasing",
            ):
                augment_timebase_evidence.raw_record(
                    root,
                    {"fileName": raw.name, "sampleIntervalSeconds": 1},
                    2,
                )

    def test_rejects_mismatched_compact_timebase_correction_sequences(self):
        with self.assertRaisesRegex(
            augment_timebase_evidence.TimebaseEvidenceError,
            "compact and raw correction sequences differ",
        ):
            augment_timebase_evidence.require_matching_correction_sequences(
                [{"sequence": 8}, {"sequence": 10}],
                [8, 9],
            )

    def test_materializes_accepted_start_delayed_failure_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_delayed_start_export(root)
            evidence = self.materialize(
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
            self.make_delayed_start_export(root)
            evidence = self.materialize(
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

    def test_delayed_start_all_outputs_contract_is_exact(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_delayed_start_export(root)
            manifest_path = root / "manifest.json"
            manifest = json.loads(manifest_path.read_text())

            for label, mutation in {
                "missing sibling": lambda value: value[0]["attachments"].pop(),
                "unknown sibling": lambda value: value[0]["attachments"].append(
                    {
                        "exportedFileName": "delayed-start-0.json",
                        "suggestedHumanReadableName": "qualification-unknown.json",
                    }
                ),
            }.items():
                with self.subTest(label=label):
                    candidate = json.loads(json.dumps(manifest))
                    mutation(candidate)
                    manifest_path.write_text(json.dumps(candidate))
                    with self.assertRaises(materialize_evidence.EvidenceError):
                        self.materialize(
                            root,
                            "qualification-failed-start.json",
                            "failed-start",
                            "ipad-current",
                            "a" * 64,
                            "b" * 64,
                        )
            manifest_path.write_text(json.dumps(manifest))

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
            evidence = self.materialize(
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
                self.materialize(
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
                self.materialize(
                    root,
                    "qualification-native-hls-seek-continuity.json",
                    "native-hls-seek-continuity",
                    "iphone-current",
                    "a" * 64,
                    "b" * 64,
                )

    def test_apple_audio_attachment_cannot_forge_host_source_proof(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "scenario": "audio-media-services-reset",
                    "sourceRequestProof": {"method": "forged-in-xctest"},
                },
                attachment_name="qualification-audio-media-services-reset.json",
                test_identifier=(
                    "MediaServicesResetDeviceUITests/"
                    "test_realMediaServicesResetQuarantinesAndRebuildsBothAppleOutputs"
                ),
            )
            with self.assertRaisesRegex(
                materialize_evidence.EvidenceError,
                "test attachment may not supply host identity fields: sourceRequestProof",
            ):
                self.materialize(
                    root,
                    "qualification-audio-media-services-reset.json",
                    "audio-media-services-reset",
                    "iphone-current",
                    "a" * 64,
                    "b" * 64,
                )

    def test_materializer_binds_retained_host_source_metrics(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {"scenario": "audio-media-services-reset"},
                attachment_name="qualification-audio-media-services-reset.json",
                test_identifier=(
                    "MediaServicesResetDeviceUITests/"
                    "test_realMediaServicesResetQuarantinesAndRebuildsBothAppleOutputs"
                ),
            )
            metrics = root / (
                "apple-audio-source-metrics/"
                "run-audio-media-services-reset/attempt-1.json"
            )
            metrics.parent.mkdir(parents=True)
            metrics.write_text(
                json.dumps(
                    {
                        "formatVersion": 1,
                        "token": "run-audio-reset-1",
                        "masterRequests": 1,
                        "mediaPlaylistRequests": 1,
                        "segmentRequests": 2,
                        "successfulSegments": 2,
                        "successfulSegmentsByVariant": {"low": 0, "high": 2},
                        "retryFailures": 0,
                        "retryRecoveries": 0,
                        "expiredWindows": 0,
                        "discontinuityManifests": 1,
                        "variantTransitions": 0,
                        "clientCompleted": False,
                        "playlistTypes": ["vod"],
                        "containers": ["ts"],
                        "variants": ["high"],
                        "modes": ["timebase-vod-ts"],
                        "maxMediaSequenceByMode": {"timebase-vod-ts": 0},
                    },
                    sort_keys=True,
                )
                + "\n",
                encoding="utf-8",
            )
            execution = {"fixture": "same final execution object"}
            attempts = [
                {
                    "attempt": 1,
                    "classification": "passed",
                    "testExecution": execution,
                    "xcresultArtifact": "audio-media-services-reset.xcresult",
                    "xcresultDigestAlgorithm": "swiftvlc-tree-v1",
                    "xcresultDigest": "c" * 64,
                    "xcresultSizeBytes": 123,
                }
            ]
            evidence = self.materialize(
                root,
                "qualification-audio-media-services-reset.json",
                "audio-media-services-reset",
                "iphone-current",
                "a" * 64,
                "b" * 64,
                test_execution=execution,
                retained_root_base=root,
                runner_scenario="audio-media-services-reset",
                attempts=attempts,
                adaptive_source_metrics=metrics,
            )
            proof = evidence["sourceRequestProof"]
            self.assertEqual(proof["formatVersion"], 2)
            self.assertEqual(proof["sourceAttempt"], 1)
            self.assertEqual(proof["attemptToken"], "run-audio-reset-1")
            self.assertEqual(
                proof["metricsDigest"], qualification_policy.sha256_file(metrics)
            )
            self.assertEqual(proof["metricsSizeBytes"], metrics.stat().st_size)


class QualificationRecordAssemblyTests(unittest.TestCase):
    @staticmethod
    def trace_binding(
        trace: Path,
        toc: Path,
        *,
        run_artifact: str,
        toc_artifact: str,
        role: str,
        template: str,
        producer: dict,
        evidence_stem: str,
        scenario: str,
        target_device_identifier: str,
        device_duration: int,
        extra: dict | None = None,
    ) -> dict:
        producer_fields = qualification_policy.host_artifact_producer_fields(
            {"qualificationProducer": producer}, evidence_stem
        )
        summary_path = toc.with_name(f"{trace.stem}-summary.json")
        minimum_duration = qualification_policy.trace_minimum_capture_duration(
            scenario, role, device_duration
        )
        metric, unit = qualification_policy.TRACE_MEASUREMENT_SPECS[role]
        summary = {
            "formatVersion": 1,
            "status": "captured",
            "source": "xctrace-export-v1",
            "runNumber": 1,
            "scenario": scenario,
            "artifactRole": role,
            "template": template,
            "targetProcess": "iOS",
            "targetDeviceIdentifier": target_device_identifier,
            "captureDurationSeconds": minimum_duration,
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
                "timelineEndSeconds": minimum_duration,
                "maximumSampleGapSeconds": 1.0,
                "sourceFields": [f"{role}-fixture-value"],
            },
            "traceTreeDigestAlgorithm": "swiftvlc-tree-v1",
            "traceTreeDigest": qualification_policy.tree_digest(trace),
            "tableOfContentsDigestAlgorithm": "sha256",
            "tableOfContentsDigest": qualification_policy.sha256_file(toc),
            **producer_fields,
        }
        summary_path.write_text(json.dumps(summary, sort_keys=True))
        return {
            "status": "captured",
            "artifactRole": role,
            "template": template,
            "format": "com.apple.instruments.trace",
            "runArtifact": run_artifact,
            "tableOfContents": toc_artifact,
            "treeDigestAlgorithm": "swiftvlc-tree-v1",
            "treeDigest": qualification_policy.tree_digest(trace),
            "treeSizeBytes": qualification_policy.tree_size_bytes(trace),
            "treeEntryCount": qualification_policy.tree_entry_count(trace),
            "tableOfContentsDigestAlgorithm": "sha256",
            "tableOfContentsDigest": qualification_policy.sha256_file(toc),
            "tableOfContentsSizeBytes": toc.stat().st_size,
            "targetProcess": "iOS",
            "exportSummary": summary_path.relative_to(trace.parents[2]).as_posix(),
            "exportSummaryDigestAlgorithm": "sha256",
            "exportSummaryDigest": qualification_policy.sha256_file(summary_path),
            "exportSummarySizeBytes": summary_path.stat().st_size,
            **producer_fields,
            **(extra or {}),
        }

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
        catalog = ["iOSUITests/FixtureQualificationTests/test_fixture"]
        self.catalog = catalog
        self.original_xcresult_reader = assemble_record.policy.xcresult_test_document
        self.original_attachment_inspector = (
            assemble_record.policy.inspect_xcresult_qualification_attachments
        )
        assemble_record.policy.xcresult_test_document = lambda _path: {
            "testNodes": [
                {
                    "nodeType": "Test Case",
                    "nodeIdentifier": identifier,
                    "result": "Passed",
                }
                for identifier in self.catalog
            ]
        }

        def inspect_fixture_attachments(xcresult, expected_owners):
            runner = xcresult.parent.name.removesuffix("-attempt-artifacts")
            attachment_root = xcresult.parent.parent / f"{runner}-attachments"
            try:
                exported = qualification_policy.exported_qualification_attachments(
                    attachment_root, expected_owners
                )
            except qualification_policy.QualificationPolicyError as error:
                raise assemble_record.policy.QualificationPolicyError(
                    str(error)
                ) from error
            return {
                name: {
                    "payload": payload,
                    "sha256": qualification_policy.sha256_file(path),
                    "sizeBytes": path.stat().st_size,
                    "testIdentifier": owner,
                }
                for name, (path, payload, owner) in exported.items()
            }

        assemble_record.policy.inspect_xcresult_qualification_attachments = (
            inspect_fixture_attachments
        )
        source_commit = "b" * 40
        release_source_digest = "c" * 64
        artifact_digest = "a" * 64
        self.candidate.write_text(
            json.dumps(
                {
                    "formatVersion": 2,
                    "version": "1.1.0",
                    "candidateAppBundleIdentifier": (
                        "com.swiftvlc.validation.team.app"
                    ),
                    "artifactDigestAlgorithm": "swiftvlc-tree-v1",
                    "artifactDigest": artifact_digest,
                    "sourceCommit": source_commit,
                    "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
                    "releaseSourceDigest": release_source_digest,
                    **fixture_candidate_build_attestation_fields(
                        source_commit=source_commit,
                        release_source_digest=release_source_digest,
                        artifact_digest=artifact_digest,
                        catalog=catalog,
                        candidate_app_digest="d" * 64,
                        test_runner_digest="e" * 64,
                        test_bundle_digest="f" * 64,
                        base_xctestrun_digest="1" * 64,
                        base_xctestrun_name="fixture.xctestrun",
                    ),
                    "candidateAppDigestAlgorithm": "swiftvlc-tree-v1",
                    "candidateAppDigest": "d" * 64,
                    "testRunnerBundleIdentifier": (
                        "com.swiftvlc.validation.team.uitests.xctrunner"
                    ),
                    "testRunnerDigestAlgorithm": "swiftvlc-tree-v1",
                    "testRunnerDigest": "e" * 64,
                    "testBundleRelativePath": "PlugIns/iOSUITests.xctest",
                    "testBundleDigestAlgorithm": "swiftvlc-tree-v1",
                    "testBundleDigest": "f" * 64,
                    "baseXCTestRunDigestAlgorithm": "sha256",
                    "baseXCTestRunDigest": "1" * 64,
                    "baseXCTestRunName": "fixture.xctestrun",
                    "testCatalogDigestAlgorithm": "swiftvlc-test-catalog-v1",
                    "testCatalogDigest": qualification_policy.catalog_digest(catalog),
                    "testCatalogCount": 1,
                    "testCatalog": catalog,
                    "qualificationMatrixChecksum": self.matrix_checksum,
                    "featureManifestChecksum": "2" * 64,
                    "qualificationProfilesChecksum": "3" * 64,
                    "fixtureManifestChecksum": "4" * 64,
                    "qualificationPolicyDigestAlgorithm": "swiftvlc-qualification-policy-v1",
                    "qualificationPolicyDigest": qualification_policy.policy_digest(),
                }
            )
        )

    def tearDown(self):
        assemble_record.policy.xcresult_test_document = self.original_xcresult_reader
        assemble_record.policy.inspect_xcresult_qualification_attachments = (
            self.original_attachment_inspector
        )
        self.temporary.cleanup()

    def make_report(
        self,
        hardware: str,
        release_type: str = "stable",
        *,
        validate_receipt: bool = True,
    ) -> Path:
        stable = release_type == "stable"
        matrix = json.loads(self.matrix.read_text())
        scenario = matrix["scenarios"][0]["id"]
        output_contract = {
            "scenario": scenario,
            "attachmentName": f"qualification-{scenario}.json",
            "testIdentifiers": self.catalog,
        }
        matrix["runnerContracts"] = [
            {
                "id": runner,
                "selection": {"kind": "exact", "testIdentifiers": self.catalog},
                "outputs": [],
            }
            for runner in sorted(
                qualification_policy.REQUIRED_RELEASE_RUNNER_SCENARIOS - {scenario}
            )
        ] + [{"id": scenario, "outputs": [output_contract]}]
        self.matrix.write_text(json.dumps(matrix))
        duration = qualification_policy.STABLE_MINIMUM_DURATION_SECONDS.get(
            scenario, 10
        )
        self.matrix_checksum = hashlib.sha256(self.matrix.read_bytes()).hexdigest()
        candidate = json.loads(self.candidate.read_text())
        candidate["qualificationMatrixChecksum"] = self.matrix_checksum
        catalog_record = qualification_policy.catalog_record(self.catalog)
        candidate["testCatalog"] = self.catalog
        candidate["testCatalogCount"] = catalog_record["testCount"]
        candidate["testCatalogDigest"] = catalog_record["digest"]
        attestation = candidate["candidateBuildAttestation"]
        attestation["testCatalog"] = self.catalog
        attestation["testCatalogCount"] = catalog_record["testCount"]
        attestation["testCatalogDigest"] = catalog_record["digest"]
        candidate["candidateBuildAttestationDigest"] = hashlib.sha256(
            qualification_policy.canonical_json_bytes(attestation)
        ).hexdigest()
        self.candidate.write_text(json.dumps(candidate))
        catalog = qualification_policy.catalog_record(candidate["testCatalog"])
        execution = {
            "expected": catalog,
            "executed": catalog,
            "identityAndCountMatch": True,
            "allPassed": True,
        }
        directory = self.root / f"report-{hardware}"
        evidence_directory = directory / "evidence"
        evidence_directory.mkdir(parents=True)
        raw_log_root = directory / "raw-logs"
        raw_log_root.mkdir()
        declared_children = qualification_policy.DECLARED_TEST_CHILD_LOGS.get(scenario)
        for test_index, test_identifier in enumerate(self.catalog, 1):
            children = (
                [None, *sorted(declared_children)] if declared_children else [None]
            )
            for child in children:
                raw_log_name = qualification_policy.test_log_filename(
                    "run",
                    test_identifier,
                    f"00000000-0000-4000-8000-{test_index:012d}",
                    child=child,
                )
                (raw_log_root / raw_log_name).write_text(
                    json.dumps(
                        {
                            "ts": "2026-08-31T12:00:00Z",
                            "level": "debug",
                            "module": qualification_policy.LOG_MIRROR_HEALTH_MODULE,
                            "message": qualification_policy.LOG_MIRROR_HEALTH_MESSAGE,
                        }
                    )
                    + "\n"
                )
        error_inventory = qualification_policy.build_error_inventory(
            raw_log_root,
            "run",
            scenario,
            retained_root=raw_log_root.name,
            expected_test_catalog=catalog,
        )
        attachment_directory = directory / f"{scenario}-attachments"
        attachment_directory.mkdir()
        attachment_payload = attachment_directory / "payload.json"
        raw_attachment = {
            "scenario": scenario,
            "outcome": "pass",
            "durationSeconds": duration,
            "qualificationSessionBinding": FIXTURE_SESSION_BINDING,
            "candidateRuntimeBinding": candidate["candidateRuntimeBinding"],
        }
        if scenario in qualification_policy.RAW_HOST_TRACE_REQUIREMENTS:
            raw_attachment["hostTraceRequirements"] = (
                qualification_policy.RAW_HOST_TRACE_REQUIREMENTS[scenario]
            )
        if scenario in {"timebase-vod-soak", "timebase-live-soak"}:
            mode = "vod" if scenario == "timebase-vod-soak" else "live"
            raw_attachment["rawCapture"] = {
                "status": "required-host-augmentation",
                "fileName": (f"swiftvlc-timebase-fixture-{mode}-1-{mode}.jsonl"),
                "sampleIntervalSeconds": 1,
            }
        attachment_payload.write_text(json.dumps(raw_attachment))
        (attachment_directory / "manifest.json").write_text(
            json.dumps(
                [
                    {
                        "testIdentifier": self.catalog[0],
                        "attachments": [
                            {
                                "suggestedHumanReadableName": output_contract[
                                    "attachmentName"
                                ],
                                "exportedFileName": attachment_payload.name,
                            }
                        ],
                    }
                ]
            )
        )
        attempt_root = directory / f"{scenario}-attempt-artifacts"
        attempt_root.mkdir()
        attempt_log = attempt_root / "attempt-1.log"
        attempt_log.write_text("** TEST EXECUTE SUCCEEDED **\n")
        attempt_bundle = attempt_root / "attempt-1.xcresult"
        attempt_bundle.mkdir()
        (attempt_bundle / "Info.plist").write_text("fixture xcresult")
        attempts = qualification_policy.bind_attempt_artifacts(
            [
                {
                    "attempt": 1,
                    "classification": "passed",
                    "retryable": False,
                    "intendedTestBegan": True,
                    "xcodebuildExitCode": 0,
                    "logArtifact": attempt_log.relative_to(directory).as_posix(),
                    "xcresultArtifact": attempt_bundle.relative_to(
                        directory
                    ).as_posix(),
                    "testExecution": execution,
                }
            ],
            directory,
        )
        evidence_name = "seek.json" if stable else f"seek-{hardware}.json"
        evidence = evidence_directory / evidence_name
        evidence.write_text(
            json.dumps(
                {
                    **{
                        field: candidate[field]
                        for field in qualification_policy.CORE_IDENTITY_FIELDS
                    },
                    "scenario": scenario,
                    "hardware": hardware,
                    "deviceIdentifier": f"fixture-{hardware}",
                    "outcome": "pass",
                    "durationSeconds": duration,
                    "testExecution": execution,
                    "hostErrorInventory": error_inventory,
                    "qualificationProducer": {
                        "runnerScenario": scenario,
                        "sourceAttempt": 1,
                        "sourceXcresultArtifact": attempts[-1]["xcresultArtifact"],
                        "sourceXcresultDigestAlgorithm": attempts[-1][
                            "xcresultDigestAlgorithm"
                        ],
                        "sourceXcresultDigest": attempts[-1]["xcresultDigest"],
                        "sourceXcresultSizeBytes": attempts[-1]["xcresultSizeBytes"],
                        "attachmentName": output_contract["attachmentName"],
                        "attachmentTestIdentifier": output_contract["testIdentifiers"][
                            0
                        ],
                        "retainedAttachmentRoot": attachment_directory.name,
                        "manifestRelativePath": (attachment_directory / "manifest.json")
                        .relative_to(directory)
                        .as_posix(),
                        "manifestDigestAlgorithm": "sha256",
                        "manifestDigest": qualification_policy.sha256_file(
                            attachment_directory / "manifest.json"
                        ),
                        "manifestSizeBytes": (attachment_directory / "manifest.json")
                        .stat()
                        .st_size,
                        "attachmentRelativePath": attachment_payload.relative_to(
                            directory
                        ).as_posix(),
                        "attachmentDigestAlgorithm": "sha256",
                        "attachmentDigest": qualification_policy.sha256_file(
                            attachment_payload
                        ),
                        "attachmentSizeBytes": attachment_payload.stat().st_size,
                    },
                }
            )
        )
        completed_at = datetime.now(timezone.utc).replace(microsecond=0)
        started_at = completed_at - timedelta(seconds=duration)
        selected_device = {
            "id": f"coredevice-{hardware}",
            "udid": f"fixture-{hardware}",
            "ecid": 42,
            "ecidHex": "0x2A",
            "name": f"Fixture {hardware}",
            "marketingName": f"Fixture {hardware}",
            "productType": "Fixture1,1",
            "deviceFamily": "iPhone" if hardware == "iphone" else "iPad",
            "osVersion": "26.0",
            "osMajor": 26,
            "osBuild": "23A1",
            "osReleaseType": release_type,
            "transport": "wired",
            "tunnelIPAddress": "fd00::1",
            "connected": True,
            "matchingHardwareRows": [hardware],
            "qualificationEligible": stable,
        }
        mode = "qualification" if stable else "exploratory"
        report_validation.atomic_write_json(
            directory / qualification_policy.DEVICE_SNAPSHOT_RELATIVE_PATH,
            {
                "selected": selected_device,
                "connected": [selected_device],
                "allPhysicalIOSDevices": [selected_device],
                "mode": mode,
            },
        )
        report = directory / "report.json"
        report.write_text(
            json.dumps(
                {
                    **candidate,
                    "startedAtUTC": started_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "completedAtUTC": completed_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "wallDurationSeconds": duration,
                    "qualificationEligibleEnvironment": stable,
                    "device": selected_device,
                    "deviceSnapshot": qualification_policy.device_snapshot_binding(
                        directory
                    ),
                    "mode": mode,
                    "reportOnly": False,
                    "releaseGateSatisfied": False,
                    "releaseGateReason": (
                        qualification_policy.ORDINARY_RELEASE_GATE_REASON
                    ),
                    "result": "pass",
                    "scenarios": [
                        {
                            "scenario": scenario,
                            "result": "pass",
                            "xcodebuildExitCode": 0,
                            "libraryErrorCount": 0,
                            "appLog": "captured",
                            "expectedTestCatalog": catalog,
                            "testExecution": execution,
                            "hostErrorInventory": error_inventory,
                            "attempts": attempts,
                            "attemptArtifactRoot": attempt_root.name,
                            "durationSeconds": duration,
                            "qualificationEvidence": "captured",
                        }
                    ],
                    "qualificationRows": (
                        [
                            {
                                "scenario": scenario,
                                "runnerScenario": scenario,
                                "hardware": hardware,
                                "device": f"Fixture {hardware}",
                                "deviceFamily": (
                                    "iPhone" if hardware == "iphone" else "iPad"
                                ),
                                "productType": "Fixture1,1",
                                "osVersion": "26.0",
                                "osBuild": "23A1",
                                "osReleaseType": release_type,
                                "fixture": "qualification-fixtures:" + "4" * 64,
                                "duration": f"{duration}s",
                                "durationSeconds": duration,
                                "evidence": "evidence/seek.json",
                                "result": "pass",
                            }
                        ]
                        if stable
                        else []
                    ),
                }
            )
        )
        if validate_receipt:
            self.validate_report_receipt(report, stable_required=stable)
        return report

    def validate_report_receipt(
        self,
        report: Path,
        *,
        projected_hardware_row: str | None = None,
        stable_required: bool = False,
    ) -> Path:
        payload = json.loads(report.read_text())
        payload["orchestratorSessionBinding"] = FIXTURE_SESSION_BINDING
        payload["orchestratorStartedAtUTC"] = payload["startedAtUTC"]
        report_validation.atomic_write_json(report, payload)
        scenario_ids = [row["scenario"] for row in payload["scenarios"]]
        plan = validation_plan.build_plan(
            {"mode": payload["mode"], "selected": payload["device"]},
            json.loads(self.matrix.read_text()),
            scenario_ids,
            scenario_ids,
            started_at_utc=payload["startedAtUTC"],
            orchestrator_session_binding=FIXTURE_SESSION_BINDING,
            orchestrator_started_at_utc=payload["startedAtUTC"],
            projected_hardware_row=projected_hardware_row,
            selection_scope="partial",
        )
        report_validation.atomic_write_json(
            report.parent / report_validation.PLAN_FILENAME,
            plan,
        )
        return report_validation.validate_and_mark(
            report.parent,
            matrix_path=self.matrix,
            candidate_path=self.candidate,
            stable_required=stable_required,
        )

    def add_support_runner(
        self, report_path: Path, runner: str, *, capture_log: bool = True
    ) -> dict:
        report = json.loads(report_path.read_text())
        catalog = qualification_policy.catalog_record(report["testCatalog"])
        execution = {
            "expected": catalog,
            "executed": catalog,
            "identityAndCountMatch": True,
            "allPassed": True,
        }
        attempt_root = report_path.parent / f"{runner}-attempt-artifacts"
        attempt_root.mkdir()
        attempt_log = attempt_root / "attempt-1.log"
        attempt_log.write_text("** TEST EXECUTE SUCCEEDED **\n")
        attempt_bundle = attempt_root / "attempt-1.xcresult"
        attempt_bundle.mkdir()
        (attempt_bundle / "Info.plist").write_text("fixture xcresult")
        attempts = qualification_policy.bind_attempt_artifacts(
            [
                {
                    "attempt": 1,
                    "classification": "passed",
                    "retryable": False,
                    "intendedTestBegan": True,
                    "xcodebuildExitCode": 0,
                    "logArtifact": attempt_log.relative_to(
                        report_path.parent
                    ).as_posix(),
                    "xcresultArtifact": attempt_bundle.relative_to(
                        report_path.parent
                    ).as_posix(),
                    "testExecution": execution,
                }
            ],
            report_path.parent,
        )
        inventory = None
        if capture_log:
            raw_root = report_path.parent / f"{runner}-raw-jsonl"
            raw_root.mkdir(parents=True)
            declared_children = qualification_policy.DECLARED_TEST_CHILD_LOGS.get(
                runner
            )
            for test_index, test_identifier in enumerate(self.catalog, 1):
                children = (
                    [None, *sorted(declared_children)] if declared_children else [None]
                )
                for child in children:
                    raw_log_name = qualification_policy.test_log_filename(
                        "run",
                        test_identifier,
                        f"00000000-0000-4000-8000-{test_index:012d}",
                        child=child,
                    )
                    (raw_root / raw_log_name).write_text(
                        json.dumps(
                            {
                                "ts": "2026-08-31T12:00:00Z",
                                "level": "debug",
                                "module": qualification_policy.LOG_MIRROR_HEALTH_MODULE,
                                "message": qualification_policy.LOG_MIRROR_HEALTH_MESSAGE,
                            }
                        )
                        + "\n"
                    )
            inventory = qualification_policy.build_error_inventory(
                raw_root,
                "run",
                runner,
                retained_root=raw_root.relative_to(report_path.parent).as_posix(),
                expected_test_catalog=catalog,
            )
        runner_row = {
            "scenario": runner,
            "result": "pass",
            "xcodebuildExitCode": 0,
            "libraryErrorCount": 0,
            "appLog": "captured" if capture_log else "none",
            "expectedTestCatalog": catalog,
            "testExecution": execution,
            "hostErrorInventory": inventory,
            "attempts": attempts,
            "attemptArtifactRoot": attempt_root.name,
            "durationSeconds": 10,
            "qualificationEvidence": "not-applicable",
        }
        report["scenarios"].append(runner_row)
        report_path.write_text(json.dumps(report))
        return runner_row

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
        self.assertEqual(len(record["sourceReports"]), 2)
        self.assertEqual(record["artifactDigest"], "a" * 64)
        for row in record["rows"]:
            self.assertTrue((output.parent / row["evidence"]).is_file())

    def test_assembler_rejects_a_semantic_pass_without_validation_receipt(self):
        report = self.make_report("iphone")
        (report.parent / report_validation.MARKER_FILENAME).unlink()

        with self.assertRaisesRegex(
            assemble_record.AssemblyError,
            "no matching successful-validation receipt",
        ):
            assemble_record.assemble(
                "1.1.0",
                self.candidate,
                self.matrix,
                [report],
                self.root / "qualification" / "receiptless.json",
            )

    def test_record_reopens_validation_receipt_for_every_retained_source(self):
        report = self.make_report("iphone")
        output = self.root / "qualification" / "receipt-record.json"
        record = assemble_record.assemble(
            "1.1.0", self.candidate, self.matrix, [report], output
        )
        binding = record["sourceReports"][0]
        retained_root = output.parent / binding["path"]
        (retained_root / report_validation.MARKER_FILENAME).unlink()
        binding["treeDigest"] = qualification_policy.tree_digest(retained_root)
        binding["treeSizeBytes"] = qualification_policy.tree_size_bytes(retained_root)
        output.write_text(json.dumps(record))

        with self.assertRaisesRegex(
            assemble_record.policy.QualificationPolicyError,
            "no matching successful-validation receipt",
        ):
            assemble_record.policy.validate_record(
                output,
                json.loads(self.matrix.read_text()),
                expected_identity=json.loads(self.candidate.read_text()),
                strict_provenance=True,
                require_complete=False,
            )

    def test_current_os_beta_report_validates_evidence_without_release_rows(self):
        report = self.make_report("iphone", release_type="beta")
        matrix = json.loads(self.matrix.read_text())
        candidate = json.loads(self.candidate.read_text())

        validated = assemble_record.policy.validate_report(
            report,
            matrix,
            candidate=candidate,
            stable_required=False,
            strict_provenance=True,
        )

        self.assertEqual(validated["mode"], "exploratory")
        self.assertEqual(validated["qualificationRows"], [])
        self.assertEqual(
            validated["scenarios"][0]["qualificationEvidence"], "captured"
        )
        self.assertTrue((report.parent / "evidence" / "seek-iphone.json").is_file())
        self.validate_report_receipt(report)
        self.assertTrue(report_validation.is_valid(report.parent))
        (report.parent / "evidence" / "seek-iphone.json").unlink()
        with self.assertRaises(assemble_record.policy.QualificationPolicyError):
            assemble_record.policy.validate_report(
                report,
                matrix,
                candidate=candidate,
                stable_required=False,
                strict_provenance=True,
            )
        self.assertFalse(report_validation.is_valid(report.parent))

    def test_runner_assembles_and_validates_a_forced_product_failure_without_execution(self):
        report = self.make_report("iphone", validate_receipt=False)
        payload = json.loads(report.read_text())
        runner = payload["scenarios"][0]
        attempt_root = report.parent / runner["attemptArtifactRoot"]
        attempt_log = attempt_root / "attempt-1.log"
        attempt_bundle = attempt_root / "attempt-1.xcresult"
        attempt_log.write_text(
            "** TEST EXECUTE FAILED **\n"
            "Test Case '-[iOSUITests.FixtureQualificationTests test_fixture]' failed.\n"
        )

        passing_reader = assemble_record.policy.xcresult_test_document
        assemble_record.policy.xcresult_test_document = lambda _path: {
            "testNodes": [
                {
                    "nodeType": "Test Case",
                    "nodeIdentifier": self.catalog[0],
                    "result": "Failed",
                },
                {
                    "nodeType": "Failure Message",
                    "name": "XCTAssertTrue failed",
                },
            ]
        }
        try:
            classification = assemble_record.policy.classify_retry(
                attempt_bundle,
                attempt_log.read_text(),
                runner["expectedTestCatalog"],
            )
            attempts = assemble_record.policy.bind_attempt_artifacts(
                [
                    {
                        **classification,
                        "attempt": 1,
                        "xcodebuildExitCode": 65,
                        "terminalReason": "XCTest failed",
                        "logArtifact": attempt_log.relative_to(
                            report.parent
                        ).as_posix(),
                        "xcresultArtifact": attempt_bundle.relative_to(
                            report.parent
                        ).as_posix(),
                    }
                ],
                report.parent,
            )

            expected_catalog_path = report.parent / "seek-expected-test-catalog.json"
            expected_catalog_path.write_text(json.dumps(runner["expectedTestCatalog"]))
            attempts_path = report.parent / "seek-attempts.json"
            attempts_path.write_text(json.dumps(attempts))
            inventory_path = report.parent / "seek-error-inventory.json"
            inventory_path.write_text(json.dumps(runner["hostErrorInventory"]))
            qualification_rows_path = report.parent / "qualification-rows.jsonl"
            qualification_rows_path.write_text("")
            results_path = report.parent / "scenario-results.tsv"
            results_path.write_text(
                "\t".join(
                    [
                        runner["scenario"],
                        "fail",
                        "65",
                        "0",
                        runner["appLog"],
                        "missing",
                        str(runner["durationSeconds"]),
                        str(expected_catalog_path),
                        "",
                        str(attempts_path),
                        str(inventory_path),
                    ]
                )
                + "\n"
            )

            runner_script = (
                ROOT / "qualification" / "run-device-tests.sh"
            ).read_text()
            self.assertIn(
                'local test_execution=""\n'
                '  if [[ -n "$final_test_execution" && -f "$final_test_execution" ]]; then\n'
                '    test_execution="$OUTPUT_DIR/$scenario-test-execution.json"',
                runner_script,
            )
            assembly_invocation = (
                '"$ORCHESTRATOR_SESSION_BINDING" '
                '"$ORCHESTRATOR_STARTED_AT_UTC" <<\'PY\'\n'
            )
            assembly_start = runner_script.index(assembly_invocation) + len(
                assembly_invocation
            )
            assembly_end = runner_script.index(
                "\nPY\n\nreport_validation_args=", assembly_start
            )
            assembly_source = runner_script[assembly_start:assembly_end]
            candidate = json.loads(self.candidate.read_text())
            completed = subprocess.run(
                [
                    sys.executable,
                    "-",
                    str(results_path),
                    str(report),
                    str(report.parent / qualification_policy.DEVICE_SNAPSHOT_RELATIVE_PATH),
                    candidate["version"],
                    candidate["sourceCommit"],
                    candidate["releaseSourceDigest"],
                    candidate["qualificationMatrixChecksum"],
                    candidate["candidateAppDigest"],
                    candidate["artifactDigest"],
                    payload["mode"],
                    str(qualification_rows_path),
                    str(self.candidate),
                    "false",
                    payload["startedAtUTC"],
                    str(ROOT / "qualification"),
                    FIXTURE_SESSION_BINDING,
                    payload["startedAtUTC"],
                ],
                input=assembly_source,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)

            assembled = json.loads(report.read_text())
            self.assertEqual(assembled["result"], "fail")
            self.assertIsNone(assembled["scenarios"][0]["testExecution"])
            self.validate_report_receipt(report, stable_required=True)
            self.assertTrue(report_validation.is_valid(report.parent))
            # Early assertion failures may never create all declared child logs.
            # The failed report is still useful, but cannot be promoted to pass.
            assembled["scenarios"][0]["appLog"] = "missing"
            assembled["scenarios"][0]["hostErrorInventory"] = None
            report.write_text(json.dumps(assembled))
            self.validate_report_receipt(report, stable_required=True)
            self.assertTrue(report_validation.is_valid(report.parent))
            assembled["result"] = "pass"
            report.write_text(json.dumps(assembled))
            with self.assertRaises(report_validation.ReportValidationError):
                self.validate_report_receipt(report, stable_required=True)
        finally:
            assemble_record.policy.xcresult_test_document = passing_reader

    def test_future_os_beta_report_projects_tests_without_release_credit(self):
        report = self.make_report("iphone", release_type="beta")
        payload = json.loads(report.read_text())
        payload["device"].update(
            {
                "matchingHardwareRows": [],
                "osMajor": 27,
                "osVersion": "27.0",
                "osBuild": "24A1",
            }
        )
        device_snapshot = {
            "selected": payload["device"],
            "connected": [payload["device"]],
            "allPhysicalIOSDevices": [payload["device"]],
            "mode": payload["mode"],
        }
        report_validation.atomic_write_json(
            report.parent / qualification_policy.DEVICE_SNAPSHOT_RELATIVE_PATH,
            device_snapshot,
        )
        payload["deviceSnapshot"] = qualification_policy.device_snapshot_binding(
            report.parent
        )
        report.write_text(json.dumps(payload))
        old_evidence = report.parent / "evidence" / "seek-iphone.json"
        evidence = json.loads(old_evidence.read_text())
        evidence["hardware"] = (
            qualification_policy.EXPLORATORY_FUTURE_IOS_HARDWARE_ID
        )
        future_evidence = old_evidence.with_name(
            "seek-exploratory-future-ios.json"
        )
        future_evidence.write_text(json.dumps(evidence))
        old_evidence.unlink()

        validated = assemble_record.policy.validate_report(
            report,
            json.loads(self.matrix.read_text()),
            candidate=json.loads(self.candidate.read_text()),
            stable_required=False,
            strict_provenance=True,
        )

        self.assertEqual(validated["qualificationRows"], [])
        self.assertEqual(validated["device"]["matchingHardwareRows"], [])
        self.validate_report_receipt(
            report,
            projected_hardware_row="iphone",
        )
        self.assertTrue(report_validation.is_valid(report.parent))

    def test_strict_report_requires_exact_bound_device_snapshot(self):
        report = self.make_report("iphone")
        matrix = json.loads(self.matrix.read_text())
        candidate = json.loads(self.candidate.read_text())
        snapshot_path = (
            report.parent / qualification_policy.DEVICE_SNAPSHOT_RELATIVE_PATH
        )
        original_report = json.loads(report.read_text())
        original_snapshot = json.loads(snapshot_path.read_text())

        def raw_binding() -> dict:
            return {
                "relativePath": qualification_policy.DEVICE_SNAPSHOT_RELATIVE_PATH,
                "digestAlgorithm": "sha256",
                "digest": qualification_policy.sha256_file(snapshot_path),
                "sizeBytes": snapshot_path.stat().st_size,
            }

        def assert_rejected(
            expected_message: str, mutated_report: dict, mutated_snapshot: dict
        ) -> None:
            report_validation.atomic_write_json(snapshot_path, mutated_snapshot)
            report.write_text(json.dumps(mutated_report))
            with self.assertRaisesRegex(
                assemble_record.policy.QualificationPolicyError,
                expected_message,
            ):
                assemble_record.policy.validate_report(
                    report,
                    matrix,
                    candidate=candidate,
                    stable_required=True,
                    strict_provenance=True,
                )

        changed_bytes = json.loads(json.dumps(original_snapshot))
        changed_bytes["selected"]["name"] = "Relabelled phone"
        changed_bytes["connected"] = [changed_bytes["selected"]]
        changed_bytes["allPhysicalIOSDevices"] = [changed_bytes["selected"]]
        assert_rejected(
            "snapshot binding mismatch",
            json.loads(json.dumps(original_report)),
            changed_bytes,
        )

        changed_device = json.loads(json.dumps(original_snapshot))
        changed_device["selected"]["name"] = "Self-consistent relabel"
        changed_device["connected"] = [changed_device["selected"]]
        changed_device["allPhysicalIOSDevices"] = [changed_device["selected"]]
        report_validation.atomic_write_json(snapshot_path, changed_device)
        rebound_report = json.loads(json.dumps(original_report))
        rebound_report["deviceSnapshot"] = raw_binding()
        assert_rejected(
            "device differs from retained selected device",
            rebound_report,
            changed_device,
        )

        changed_mode = json.loads(json.dumps(original_snapshot))
        changed_mode["selected"]["osReleaseType"] = "beta"
        changed_mode["selected"]["qualificationEligible"] = False
        changed_mode["connected"] = [changed_mode["selected"]]
        changed_mode["allPhysicalIOSDevices"] = [changed_mode["selected"]]
        changed_mode["mode"] = "exploratory"
        report_validation.atomic_write_json(snapshot_path, changed_mode)
        rebound_report = json.loads(json.dumps(original_report))
        rebound_report["deviceSnapshot"] = raw_binding()
        assert_rejected(
            "mode differs from retained device snapshot",
            rebound_report,
            changed_mode,
        )

        noncanonical = json.loads(json.dumps(original_snapshot))
        noncanonical["selected"]["fabricatedField"] = "accepted-by-default"
        noncanonical["connected"] = [noncanonical["selected"]]
        noncanonical["allPhysicalIOSDevices"] = [noncanonical["selected"]]
        report_validation.atomic_write_json(snapshot_path, noncanonical)
        rebound_report = json.loads(json.dumps(original_report))
        rebound_report["device"] = noncanonical["selected"]
        rebound_report["deviceSnapshot"] = raw_binding()
        assert_rejected(
            "selected device fields are not canonical",
            rebound_report,
            noncanonical,
        )

    def test_exploratory_report_cannot_fabricate_a_qualification_row(self):
        report = self.make_report("iphone", release_type="beta")
        payload = json.loads(report.read_text())
        payload["qualificationRows"] = [
            {
                "scenario": "seek",
                "runnerScenario": "seek",
                "hardware": "iphone",
                "result": "pass",
            }
        ]
        report.write_text(json.dumps(payload))

        with self.assertRaises(assemble_record.policy.QualificationPolicyError):
            assemble_record.policy.validate_report(
                report,
                json.loads(self.matrix.read_text()),
                candidate=json.loads(self.candidate.read_text()),
                stable_required=False,
                strict_provenance=True,
            )

    def test_failed_output_runner_validates_without_a_qualification_row(self):
        report = self.make_report("iphone")
        payload = json.loads(report.read_text())
        runner = payload["scenarios"][0]
        attempt_root = report.parent / runner["attemptArtifactRoot"]
        attempt_log = attempt_root / "attempt-1.log"
        attempt_bundle = attempt_root / "attempt-1.xcresult"
        attempt_log.write_text(
            "** TEST EXECUTE FAILED **\n"
            "Test Case '-[iOSUITests.FixtureQualificationTests test_fixture]' failed.\n"
        )
        passing_reader = assemble_record.policy.xcresult_test_document
        assemble_record.policy.xcresult_test_document = lambda _path: {
            "testNodes": [
                {
                    "nodeType": "Test Case",
                    "nodeIdentifier": self.catalog[0],
                    "result": "Failed",
                },
                {
                    "nodeType": "Failure Message",
                    "name": "XCTAssertTrue failed",
                },
            ]
        }
        try:
            classification = assemble_record.policy.classify_retry(
                attempt_bundle,
                attempt_log.read_text(),
                runner["expectedTestCatalog"],
            )
            attempts = assemble_record.policy.bind_attempt_artifacts(
                [
                    {
                        **classification,
                        "attempt": 1,
                        "xcodebuildExitCode": 65,
                        "terminalReason": "XCTest failed",
                        "logArtifact": attempt_log.relative_to(
                            report.parent
                        ).as_posix(),
                        "xcresultArtifact": attempt_bundle.relative_to(
                            report.parent
                        ).as_posix(),
                    }
                ],
                report.parent,
            )
            runner.update(
                {
                    "result": "fail",
                    "xcodebuildExitCode": 65,
                    "qualificationEvidence": "missing",
                    "testExecution": None,
                    "attempts": attempts,
                }
            )
            payload["result"] = "fail"
            payload["qualificationRows"] = []
            report.write_text(json.dumps(payload))

            validated = assemble_record.policy.validate_report(
                report,
                json.loads(self.matrix.read_text()),
                candidate=json.loads(self.candidate.read_text()),
                stable_required=True,
                strict_provenance=True,
            )
            self.validate_report_receipt(report, stable_required=True)
            self.assertTrue(report_validation.is_valid(report.parent))
        finally:
            assemble_record.policy.xcresult_test_document = passing_reader

        self.assertEqual(validated["result"], "fail")
        self.assertEqual(validated["qualificationRows"], [])
        self.assertEqual(
            validated["scenarios"][0]["expectedTestCatalog"]["testIdentifiers"],
            self.catalog,
        )

    def test_report_result_must_reconcile_with_runner_results(self):
        report = self.make_report("iphone")
        payload = json.loads(report.read_text())
        payload["result"] = "fail"
        report.write_text(json.dumps(payload))

        with self.assertRaisesRegex(
            assemble_record.policy.QualificationPolicyError,
            "does not reconcile",
        ):
            assemble_record.policy.validate_report(
                report,
                json.loads(self.matrix.read_text()),
                candidate=json.loads(self.candidate.read_text()),
                stable_required=False,
                strict_provenance=True,
            )

    def test_qualification_row_must_belong_to_the_report_device(self):
        report = self.make_report("iphone")
        payload = json.loads(report.read_text())
        payload["qualificationRows"][0]["hardware"] = "ipad"
        report.write_text(json.dumps(payload))

        with self.assertRaisesRegex(
            assemble_record.policy.QualificationPolicyError,
            "does not belong to the report device",
        ):
            assemble_record.policy.validate_report(
                report,
                json.loads(self.matrix.read_text()),
                candidate=json.loads(self.candidate.read_text()),
                stable_required=True,
                strict_provenance=True,
            )

    def test_rejects_retained_raw_log_swap_extra_delete_and_rename(self):
        report = self.make_report("iphone")
        payload = json.loads(report.read_text())
        raw_record = payload["scenarios"][0]["hostErrorInventory"]["rawFiles"][0]
        raw = report.parent / "raw-logs" / raw_record["path"]
        original = raw.read_text()
        output = self.root / "qualification" / "1.1.0.json"

        raw.write_text('{"level":"debug","message":"swapped"}\n')
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0", self.candidate, self.matrix, [report], output
            )
        raw.write_text(original)

        extra = raw.parent / "run-seek-extra.jsonl"
        extra.write_text('{"level":"error","message":"uninventoryed fatal"}\n')
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0", self.candidate, self.matrix, [report], output
            )
        extra.unlink()

        deleted = raw.with_suffix(".saved")
        raw.rename(deleted)
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0", self.candidate, self.matrix, [report], output
            )
        deleted.rename(raw)

        renamed = raw.with_name("run-seek-renamed.jsonl")
        raw.rename(renamed)
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0", self.candidate, self.matrix, [report], output
            )

    def test_rejects_attempt_deletion_swap_rename_and_type_confusion(self):
        report = self.make_report("iphone")
        output = self.root / "qualification" / "1.1.0.json"
        attempt_log = report.parent / "seek-attempt-artifacts" / "attempt-1.log"
        attempt_bundle = report.parent / "seek-attempt-artifacts" / "attempt-1.xcresult"
        original_log = attempt_log.read_text()

        attempt_log.write_text("swapped product output\n")
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0", self.candidate, self.matrix, [report], output
            )
        attempt_log.write_text(original_log)

        saved_log = attempt_log.with_suffix(".saved")
        attempt_log.rename(saved_log)
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0", self.candidate, self.matrix, [report], output
            )
        saved_log.rename(attempt_log)

        saved_bundle = attempt_bundle.with_suffix(".saved")
        attempt_bundle.rename(saved_bundle)
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0", self.candidate, self.matrix, [report], output
            )
        saved_bundle.rename(attempt_bundle)

        attempt_bundle.rename(saved_bundle)
        attempt_bundle.write_text("not an xcresult directory")
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0", self.candidate, self.matrix, [report], output
            )
        attempt_bundle.unlink()
        saved_bundle.rename(attempt_bundle)

        attempt_bundle.rename(saved_bundle)
        attempt_bundle.symlink_to(saved_bundle, target_is_directory=True)
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0", self.candidate, self.matrix, [report], output
            )

    def test_rejects_unreferenced_attempt_artifacts(self):
        report = self.make_report("iphone")
        attempt_root = report.parent / "seek-attempt-artifacts"
        (attempt_root / "attempt-2.log").write_text(
            "Fatal decoder heap corruption in omitted prior attempt\n"
        )
        orphan_bundle = attempt_root / "attempt-2.xcresult"
        orphan_bundle.mkdir()
        (orphan_bundle / "Info.plist").write_text("orphaned xcresult")
        matrix = json.loads(self.matrix.read_text())
        candidate = json.loads(self.candidate.read_text())
        with self.assertRaises(assemble_record.policy.QualificationPolicyError):
            assemble_record.policy.validate_report(
                report,
                matrix,
                candidate=candidate,
                stable_required=True,
                strict_provenance=True,
            )
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0",
                self.candidate,
                self.matrix,
                [report],
                self.root / "qualification" / "orphan.json",
            )

    def test_rejects_unrelated_runner_substitution_for_qualification_row(self):
        report = self.make_report("iphone")
        analyzer = self.add_support_runner(report, "analyzer", capture_log=False)
        payload = json.loads(report.read_text())
        payload["scenarios"] = [analyzer]
        report.write_text(json.dumps(payload))
        matrix = json.loads(self.matrix.read_text())
        candidate = json.loads(self.candidate.read_text())
        with self.assertRaises(assemble_record.policy.QualificationPolicyError):
            assemble_record.policy.validate_report(
                report,
                matrix,
                candidate=candidate,
                stable_required=True,
                strict_provenance=True,
            )
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0",
                self.candidate,
                self.matrix,
                [report],
                self.root / "qualification" / "substituted-runner.json",
            )

    def test_rejects_runner_duration_that_does_not_underwrite_evidence(self):
        report = self.make_report("iphone")
        payload = json.loads(report.read_text())
        payload["scenarios"][0]["durationSeconds"] = 1
        report.write_text(json.dumps(payload))
        matrix = json.loads(self.matrix.read_text())
        candidate = json.loads(self.candidate.read_text())
        with self.assertRaises(assemble_record.policy.QualificationPolicyError):
            assemble_record.policy.validate_report(
                report,
                matrix,
                candidate=candidate,
                stable_required=True,
                strict_provenance=True,
            )
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0",
                self.candidate,
                self.matrix,
                [report],
                self.root / "qualification" / "short-runner.json",
            )

    def test_record_reopens_runner_duration_binding(self):
        report = self.make_report("iphone")
        output = self.root / "qualification" / "duration-record.json"
        record = assemble_record.assemble(
            "1.1.0", self.candidate, self.matrix, [report], output
        )
        binding = record["sourceReports"][0]
        retained_root = output.parent / binding["path"]
        retained_report = retained_root / binding["reportRelativePath"]
        retained_payload = json.loads(retained_report.read_text())
        retained_payload["scenarios"][0]["durationSeconds"] = 1
        retained_report.write_text(json.dumps(retained_payload))
        source_report_relative = (
            Path(binding["path"]) / binding["reportRelativePath"]
        ).as_posix()
        record["runnerScenarios"] = [
            assemble_record.policy.runner_record_summary(
                retained_payload["scenarios"][0], "iphone", source_report_relative
            )
        ]
        binding["reportDigest"] = assemble_record.policy.sha256_file(retained_report)
        binding["reportSizeBytes"] = retained_report.stat().st_size
        binding["treeDigest"] = assemble_record.policy.tree_digest(retained_root)
        binding["treeSizeBytes"] = assemble_record.policy.tree_size_bytes(retained_root)
        output.write_text(json.dumps(record))
        with self.assertRaises(assemble_record.policy.QualificationPolicyError):
            assemble_record.policy.validate_record(
                output,
                json.loads(self.matrix.read_text()),
                expected_identity=json.loads(self.candidate.read_text()),
                strict_provenance=True,
                require_complete=False,
            )

    def test_rejects_catalog_leaf_outside_candidate_and_runner_contract(self):
        report = self.make_report("iphone")
        unrelated = qualification_policy.catalog_record(
            ["iOSUITests/UnrelatedTests/test_alwaysPasses"]
        )
        execution = {
            "expected": unrelated,
            "executed": unrelated,
            "identityAndCountMatch": True,
            "allPassed": True,
        }
        payload = json.loads(report.read_text())
        payload["scenarios"][0]["expectedTestCatalog"] = unrelated
        payload["scenarios"][0]["testExecution"] = execution
        payload["scenarios"][0]["attempts"][-1]["testExecution"] = execution
        report.write_text(json.dumps(payload))
        original_reader = assemble_record.policy.xcresult_test_document
        assemble_record.policy.xcresult_test_document = lambda _path: {
            "testNodes": [
                {
                    "nodeType": "Test Case",
                    "nodeIdentifier": unrelated["testIdentifiers"][0],
                    "result": "Passed",
                }
            ]
        }
        try:
            with self.assertRaises(assemble_record.policy.QualificationPolicyError):
                assemble_record.policy.validate_report(
                    report,
                    json.loads(self.matrix.read_text()),
                    candidate=json.loads(self.candidate.read_text()),
                    stable_required=True,
                    strict_provenance=True,
                )
            with self.assertRaises(assemble_record.AssemblyError):
                assemble_record.assemble(
                    "1.1.0",
                    self.candidate,
                    self.matrix,
                    [report],
                    self.root / "qualification" / "unrelated-catalog.json",
                )
        finally:
            assemble_record.policy.xcresult_test_document = original_reader

    def test_semantic_evidence_must_exist_in_final_xcresult(self):
        report = self.make_report("iphone")
        original_inspector = (
            assemble_record.policy.inspect_xcresult_qualification_attachments
        )

        def missing_attachment(_xcresult, _expected_names):
            raise assemble_record.policy.QualificationPolicyError(
                "xcresult qualification attachment counts mismatch"
            )

        assemble_record.policy.inspect_xcresult_qualification_attachments = (
            missing_attachment
        )
        try:
            with self.assertRaises(assemble_record.policy.QualificationPolicyError):
                assemble_record.policy.validate_report(
                    report,
                    json.loads(self.matrix.read_text()),
                    candidate=json.loads(self.candidate.read_text()),
                    stable_required=True,
                    strict_provenance=True,
                )
            with self.assertRaises(assemble_record.AssemblyError):
                assemble_record.assemble(
                    "1.1.0",
                    self.candidate,
                    self.matrix,
                    [report],
                    self.root / "qualification" / "missing-attachment.json",
                )
        finally:
            assemble_record.policy.inspect_xcresult_qualification_attachments = (
                original_inspector
            )

        output = self.root / "qualification" / "attachment-record.json"
        assemble_record.assemble("1.1.0", self.candidate, self.matrix, [report], output)
        assemble_record.policy.inspect_xcresult_qualification_attachments = (
            missing_attachment
        )
        try:
            with self.assertRaises(assemble_record.policy.QualificationPolicyError):
                assemble_record.policy.validate_record(
                    output,
                    json.loads(self.matrix.read_text()),
                    expected_identity=json.loads(self.candidate.read_text()),
                    strict_provenance=True,
                    require_complete=False,
                )
        finally:
            assemble_record.policy.inspect_xcresult_qualification_attachments = (
                original_inspector
            )

    def test_attachment_xctest_owner_is_bound_at_report_assembly_and_record(self):
        report = self.make_report("iphone")
        matrix = json.loads(self.matrix.read_text())
        candidate = json.loads(self.candidate.read_text())
        wrong_owner = "iOSUITests/UnrelatedTests/test_siblingProducedEvidence"

        def forge_owner(root: Path) -> None:
            manifest_path = root / "seek-attachments" / "manifest.json"
            manifest = json.loads(manifest_path.read_text())
            manifest[0].pop("testIdentifierURL", None)
            manifest[0]["testIdentifier"] = wrong_owner
            manifest_path.write_text(json.dumps(manifest))
            evidence_path = root / "evidence" / "seek.json"
            evidence = json.loads(evidence_path.read_text())
            producer = evidence["qualificationProducer"]
            producer["attachmentTestIdentifier"] = wrong_owner
            producer["manifestDigest"] = qualification_policy.sha256_file(manifest_path)
            producer["manifestSizeBytes"] = manifest_path.stat().st_size
            evidence_path.write_text(json.dumps(evidence))

        forge_owner(report.parent)
        with self.assertRaises(assemble_record.policy.QualificationPolicyError):
            assemble_record.policy.validate_report(
                report,
                matrix,
                candidate=candidate,
                stable_required=True,
                strict_provenance=True,
            )
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0",
                self.candidate,
                self.matrix,
                [report],
                self.root / "qualification" / "wrong-owner.json",
            )

        report = self.make_report("ipad")
        output = self.root / "qualification" / "owner-record.json"
        record = assemble_record.assemble(
            "1.1.0", self.candidate, self.matrix, [report], output
        )
        binding = record["sourceReports"][0]
        retained_root = output.parent / binding["path"]
        forge_owner(retained_root)
        binding["treeDigest"] = qualification_policy.tree_digest(retained_root)
        binding["treeSizeBytes"] = qualification_policy.tree_size_bytes(retained_root)
        output.write_text(json.dumps(record))
        with self.assertRaises(assemble_record.policy.QualificationPolicyError):
            assemble_record.policy.validate_record(
                output,
                json.loads(self.matrix.read_text()),
                expected_identity=json.loads(self.candidate.read_text()),
                strict_provenance=True,
                require_complete=False,
            )

    def test_only_analyzer_may_omit_retained_device_logs(self):
        report = self.make_report("iphone")
        matrix = json.loads(self.matrix.read_text())
        candidate = json.loads(self.candidate.read_text())
        for runner in ("ui-suite", "harness-regressions"):
            with self.subTest(runner=runner):
                support = self.add_support_runner(report, runner, capture_log=False)
                with self.assertRaises(assemble_record.policy.QualificationPolicyError):
                    assemble_record.policy.validate_report(
                        report,
                        matrix,
                        candidate=candidate,
                        stable_required=True,
                        strict_provenance=True,
                    )
                with self.assertRaises(assemble_record.AssemblyError):
                    assemble_record.assemble(
                        "1.1.0",
                        self.candidate,
                        self.matrix,
                        [report],
                        self.root / "qualification" / f"logless-{runner}.json",
                    )
                payload = json.loads(report.read_text())
                payload["scenarios"] = [
                    row for row in payload["scenarios"] if row is not support
                ]
                payload["scenarios"] = [
                    row for row in payload["scenarios"] if row.get("scenario") != runner
                ]
                report.write_text(json.dumps(payload))

        self.add_support_runner(report, "analyzer", capture_log=False)
        assemble_record.policy.validate_report(
            report,
            matrix,
            candidate=candidate,
            stable_required=True,
            strict_provenance=True,
        )

    def test_multitest_support_runners_require_one_healthy_log_family_per_leaf(self):
        self.catalog = [
            "iOSUITests/FirstUITests/test_first",
            "iOSUITests/SecondUITests/test_second",
        ]
        candidate = json.loads(self.candidate.read_text())
        catalog = qualification_policy.catalog_record(self.catalog)
        candidate["testCatalog"] = self.catalog
        candidate["testCatalogCount"] = catalog["testCount"]
        candidate["testCatalogDigest"] = catalog["digest"]
        self.candidate.write_text(json.dumps(candidate))

        for hardware, runner in (
            ("iphone", "ui-suite"),
            ("ipad", "harness-regressions"),
        ):
            with self.subTest(runner=runner):
                report = self.make_report(hardware)
                support = self.add_support_runner(report, runner)
                matrix = json.loads(self.matrix.read_text())
                candidate = json.loads(self.candidate.read_text())
                assemble_record.policy.validate_report(
                    report,
                    matrix,
                    candidate=candidate,
                    stable_required=True,
                    strict_provenance=True,
                )
                inventory = support["hostErrorInventory"]
                missing_record = next(
                    record
                    for record in inventory["rawFiles"]
                    if record["testIdentifier"] == self.catalog[1]
                )
                missing = (
                    report.parent / inventory["retainedRoot"] / missing_record["path"]
                )
                original = missing.read_text()
                for mutation, replacement in (
                    ("deleted", None),
                    ("empty", ""),
                    ("truncated", '{"level":"debug"'),
                ):
                    with self.subTest(runner=runner, mutation=mutation):
                        if replacement is None:
                            missing.unlink()
                        else:
                            missing.write_text(replacement)
                        with self.assertRaises(
                            assemble_record.policy.QualificationPolicyError
                        ):
                            assemble_record.policy.validate_report(
                                report,
                                matrix,
                                candidate=candidate,
                                stable_required=True,
                                strict_provenance=True,
                            )
                        missing.write_text(original)
                missing.unlink()
                with self.assertRaises(assemble_record.AssemblyError):
                    assemble_record.assemble(
                        "1.1.0",
                        self.candidate,
                        self.matrix,
                        [report],
                        self.root / "qualification" / f"missing-{runner}-leaf-log.json",
                    )

    def test_release_runner_coverage_is_required_per_hardware(self):
        iphone = self.make_report("iphone")
        common_release_runners = sorted(
            qualification_policy.REQUIRED_RELEASE_RUNNER_SCENARIOS
            - qualification_policy.IPHONE_CURRENT_ONLY_RUNNER_SCENARIOS
        )
        for runner in common_release_runners:
            self.add_support_runner(iphone, runner, capture_log=runner != "analyzer")
        self.validate_report_receipt(iphone, stable_required=True)
        ipad = self.make_report("ipad")
        output = self.root / "qualification" / "per-hardware.json"
        record = assemble_record.assemble(
            "1.1.0", self.candidate, self.matrix, [iphone, ipad], output
        )
        self.assertTrue(
            set(common_release_runners)
            <= {row["scenario"] for row in record["runnerScenarios"]}
        )
        with self.assertRaisesRegex(
            assemble_record.policy.QualificationPolicyError,
            "missing release runner coverage",
        ):
            assemble_record.policy.validate_record(
                output,
                json.loads(self.matrix.read_text()),
                expected_identity=json.loads(self.candidate.read_text()),
                strict_provenance=True,
                require_complete=True,
            )

    def test_record_reopens_full_retained_attempt_history(self):
        report = self.make_report("iphone")
        output = self.root / "qualification" / "1.1.0.json"
        record = assemble_record.assemble(
            "1.1.0", self.candidate, self.matrix, [report], output
        )
        retained_root = output.parent / record["sourceReports"][0]["path"]
        retained_log = retained_root / "seek-attempt-artifacts" / "attempt-1.log"
        retained_log.write_text("tampered after assembly\n")
        with self.assertRaises(assemble_record.policy.QualificationPolicyError):
            assemble_record.policy.validate_record(
                output,
                json.loads(self.matrix.read_text()),
                expected_identity=json.loads(self.candidate.read_text()),
                strict_provenance=True,
                require_complete=False,
            )

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
        summary = artifact_directory / "allocations-summary.json"
        summary.write_text('{"fixture":"xctrace export"}')
        evidence["allocationProvenance"] = {
            "instrumentsTrace": {
                "runArtifact": "artifacts/seek/allocations.trace",
                "tableOfContents": "artifacts/seek/allocations-toc.xml",
                "treeDigestAlgorithm": "swiftvlc-tree-v1",
                "treeDigest": assemble_record.tree_digest(trace),
                "exportSummary": "artifacts/seek/allocations-summary.json",
                "exportSummaryDigestAlgorithm": "sha256",
                "exportSummaryDigest": qualification_policy.sha256_file(summary),
                "exportSummarySizeBytes": summary.stat().st_size,
            }
        }
        evidence_path.write_text(json.dumps(evidence))
        self.validate_report_receipt(iphone, stable_required=True)

        output = self.root / "qualification" / "1.1.0.json"
        assemble_record.assemble(
            "1.1.0", self.candidate, self.matrix, [iphone, ipad], output
        )

        retained = output.parent / "evidence" / "1.1.0" / "artifacts" / "seek"
        self.assertTrue((retained / "allocations.trace" / "data.bin").is_file())
        self.assertTrue((retained / "allocations-toc.xml").is_file())
        self.assertTrue((retained / "allocations-summary.json").is_file())

    def test_assembles_digest_verified_performance_trace_artifacts(self):
        scenario = "pip-render-performance-4k60"
        self.matrix.write_text(
            json.dumps(
                {
                    "scenarios": [
                        {
                            "id": scenario,
                            "hardware": ["iphone"],
                            "minimumDurationSeconds": 900,
                        }
                    ],
                    "hardware": [
                        {"id": "iphone", "deviceFamily": "iPhone", "osMajor": 26},
                        {"id": "ipad", "deviceFamily": "iPad", "osMajor": 26},
                    ],
                }
            )
        )
        self.matrix_checksum = hashlib.sha256(self.matrix.read_bytes()).hexdigest()
        report_path = self.make_report("iphone", validate_receipt=False)
        report = json.loads(report_path.read_text())
        report["qualificationRows"][0]["scenario"] = scenario
        report_path.write_text(json.dumps(report))

        evidence_path = report_path.parent / "evidence" / "seek.json"
        evidence = json.loads(evidence_path.read_text())
        evidence["scenario"] = scenario
        evidence["profile"] = "4k60"
        evidence["deviceObservedDurationSeconds"] = 900
        evidence["hostAttemptDurationSeconds"] = 900
        evidence["samples"] = [
            {
                "elapsedSeconds": elapsed,
                "residentBytes": 100_000_000,
                "cpuSeconds": elapsed * 2,
                "thermalState": "nominal",
                "sourceWidth": 3840,
                "sourceHeight": 2160,
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
            for elapsed in range(0, 901, 5)
        ]
        evidence["systemPiPMotionSeries"] = [
            {
                "elapsedSeconds": elapsed,
                "motionScore": 0.5,
                "distinctFrameHashes": 3,
            }
            for elapsed in range(0, 901, 60)
        ]
        evidence["visualObservations"] = {
            "formatVersion": 1,
            "method": qualification_policy.VISUAL_OBSERVATION_METHOD,
            "records": [
                {
                    "elapsedSeconds": elapsed,
                    "frameHashes": ["a" * 64, "b" * 64, "c" * 64],
                    "adjacentChangedPixelRatios": [0.5, 0.5],
                    "changedPixelScore": 0.5,
                }
                for elapsed in range(0, 901, 60)
            ],
        }
        artifact_directory = evidence_path.parent / "artifacts" / evidence_path.stem
        trace_records = {}
        roles = {
            "game": ("gpu", "Game Performance"),
            "power": ("energy", "Power Profiler"),
            "time": ("conversionCost", "Time Profiler"),
        }
        for name, (role, template) in roles.items():
            basename = f"{scenario}-{name}-attempt1"
            trace = artifact_directory / f"{basename}.trace"
            trace.mkdir(parents=True)
            (trace / "data.bin").write_bytes(f"{name} samples".encode())
            toc = artifact_directory / f"{basename}-toc.xml"
            toc.write_text('<trace-toc><table schema="samples"/></trace-toc>')
            trace_records[name] = self.trace_binding(
                trace,
                toc,
                run_artifact=f"artifacts/{evidence_path.stem}/{basename}.trace",
                toc_artifact=(f"artifacts/{evidence_path.stem}/{basename}-toc.xml"),
                role=role,
                template=template,
                producer=evidence["qualificationProducer"],
                evidence_stem=evidence_path.stem,
                scenario=scenario,
                target_device_identifier="fixture-iphone",
                device_duration=900,
            )
        evidence["metrics"] = {
            "cpu": {
                "value": 1800,
                "unit": "cpu-seconds",
                "source": "Mach task thread times",
            },
            "gpu": trace_records["game"],
            "rss": {
                "baselineBytes": 100_000_000,
                "peakBytes": 100_000_000,
                "finalBytes": 100_000_000,
                "growthBytes": 0,
                "limitBytes": 160 * 1_048_576,
                "peakGrowthBytes": 0,
                "peakLimitBytes": 256 * 1_048_576,
            },
            "energy": trace_records["power"],
            "thermal": {"states": ["nominal"]},
            "conversionCost": {
                "measuredConversions": 54_001,
                "averageMilliseconds": 1.0,
                "maximumMilliseconds": 1.0,
                "hostTrace": trace_records["time"],
            },
            "frameDrops": {"libVLCDropRate": 0.0, "rendererDropRate": 0.0},
            "presentationRate": {
                "value": 60.0,
                "unit": "frames-per-second",
            },
        }
        raw_payload = {
            "scenario": scenario,
            "outcome": "pass",
            "durationSeconds": 900,
            "qualificationSessionBinding": FIXTURE_SESSION_BINDING,
            "candidateRuntimeBinding": evidence["candidateRuntimeBinding"],
            "profile": evidence["profile"],
            "samples": evidence["samples"],
            "visualObservations": evidence["visualObservations"],
            "systemPiPMotionSeries": evidence["systemPiPMotionSeries"],
            "metrics": {
                **evidence["metrics"],
                "gpu": {"status": "required-host-augmentation"},
                "energy": {"status": "required-host-augmentation"},
                "conversionCost": {
                    key: value
                    for key, value in evidence["metrics"]["conversionCost"].items()
                    if key != "hostTrace"
                }
                | {"hostTraceStatus": "required-host-augmentation"},
            },
            "hostTraceRequirements": (
                qualification_policy.RAW_HOST_TRACE_REQUIREMENTS[scenario]
            ),
        }
        attachment_payload = (
            report_path.parent / f"{scenario}-attachments" / "payload.json"
        )
        attachment_payload.write_text(json.dumps(raw_payload))
        evidence["qualificationProducer"]["attachmentDigest"] = (
            qualification_policy.sha256_file(attachment_payload)
        )
        evidence["qualificationProducer"][
            "attachmentSizeBytes"
        ] = attachment_payload.stat().st_size
        evidence_path.write_text(json.dumps(evidence))
        self.validate_report_receipt(report_path, stable_required=True)

        output = self.root / "qualification" / "1.1.0.json"
        assemble_record.assemble(
            "1.1.0", self.candidate, self.matrix, [report_path], output
        )

        retained = (
            output.parent / "evidence" / "1.1.0" / "artifacts" / evidence_path.stem
        )
        for name in ("game", "power", "time"):
            basename = f"{scenario}-{name}-attempt1"
            self.assertTrue((retained / f"{basename}.trace" / "data.bin").is_file())
            self.assertTrue((retained / f"{basename}-toc.xml").is_file())

        (retained / f"{scenario}-game-attempt1.trace" / "data.bin").write_bytes(
            b"tampered"
        )
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0", self.candidate, self.matrix, [report_path], output
            )

    def test_assembles_digest_verified_native_subtitle_trace_artifacts(self):
        scenario = "native-subtitle-matrix"
        self.matrix.write_text(
            json.dumps(
                {
                    "scenarios": [
                        {
                            "id": scenario,
                            "hardware": ["iphone"],
                            "minimumDurationSeconds": 900,
                        }
                    ],
                    "hardware": [
                        {"id": "iphone", "deviceFamily": "iPhone", "osMajor": 26},
                        {"id": "ipad", "deviceFamily": "iPad", "osMajor": 26},
                    ],
                }
            )
        )
        self.matrix_checksum = hashlib.sha256(self.matrix.read_bytes()).hexdigest()
        report_path = self.make_report("iphone", validate_receipt=False)
        report = json.loads(report_path.read_text())
        report["qualificationRows"][0]["scenario"] = scenario
        report_path.write_text(json.dumps(report))

        evidence_path = report_path.parent / "evidence" / "seek.json"
        evidence = json.loads(evidence_path.read_text())
        evidence["scenario"] = scenario
        evidence["deviceObservedDurationSeconds"] = 900
        evidence["hostAttemptDurationSeconds"] = 900
        artifact_directory = evidence_path.parent / "artifacts" / evidence_path.stem
        trace_records = {}
        roles = {
            "time": ("cpu", "Time Profiler"),
            "game": ("gpu", "Game Performance"),
            "metal": ("colorHDRImpact", "Metal System Trace"),
        }
        for name, (role, template) in roles.items():
            basename = f"{scenario}-{name}-attempt1"
            trace = artifact_directory / f"{basename}.trace"
            trace.mkdir(parents=True)
            (trace / "data.bin").write_bytes(f"{name} samples".encode())
            toc = artifact_directory / f"{basename}-toc.xml"
            toc.write_text('<trace-toc><table schema="samples"/></trace-toc>')
            trace_records[name] = self.trace_binding(
                trace,
                toc,
                run_artifact=f"artifacts/{evidence_path.stem}/{basename}.trace",
                toc_artifact=(f"artifacts/{evidence_path.stem}/{basename}-toc.xml"),
                role=role,
                template=template,
                producer=evidence["qualificationProducer"],
                evidence_stem=evidence_path.stem,
                scenario=scenario,
                target_device_identifier="fixture-iphone",
                device_duration=900,
            )
        evidence["metrics"] = {
            "cpu": {"hostTrace": trace_records["time"]},
            "gpu": trace_records["game"],
            "colorHDRImpact": {"hostTrace": trace_records["metal"]},
            "samples": [{"elapsedSeconds": elapsed} for elapsed in range(0, 901, 100)],
        }
        evidence_path.write_text(json.dumps(evidence))
        self.validate_report_receipt(report_path, stable_required=True)

        output = self.root / "qualification" / "1.1.0.json"
        assemble_record.assemble(
            "1.1.0", self.candidate, self.matrix, [report_path], output
        )

        retained = (
            output.parent / "evidence" / "1.1.0" / "artifacts" / evidence_path.stem
        )
        for name in ("time", "game", "metal"):
            basename = f"{scenario}-{name}-attempt1"
            self.assertTrue((retained / f"{basename}.trace" / "data.bin").is_file())
            self.assertTrue((retained / f"{basename}-toc.xml").is_file())

        (retained / f"{scenario}-metal-attempt1.trace" / "data.bin").write_bytes(
            b"tampered"
        )
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0", self.candidate, self.matrix, [report_path], output
            )

    def test_assembles_digest_verified_timebase_trace_and_raw_capture(self):
        scenario = "timebase-vod-soak"
        self.matrix.write_text(
            json.dumps(
                {
                    "scenarios": [
                        {
                            "id": scenario,
                            "hardware": ["iphone"],
                            "minimumDurationSeconds": 7200,
                        }
                    ],
                    "hardware": [
                        {"id": "iphone", "deviceFamily": "iPhone", "osMajor": 26},
                        {"id": "ipad", "deviceFamily": "iPad", "osMajor": 26},
                    ],
                }
            )
        )
        self.matrix_checksum = hashlib.sha256(self.matrix.read_bytes()).hexdigest()
        report_path = self.make_report("iphone", validate_receipt=False)
        report = json.loads(report_path.read_text())
        report["qualificationRows"][0]["scenario"] = scenario
        report_path.write_text(json.dumps(report))

        evidence_path = report_path.parent / "evidence" / "seek.json"
        evidence = json.loads(evidence_path.read_text())
        evidence["scenario"] = scenario
        evidence["deviceObservedDurationSeconds"] = 7200
        evidence["hostAttemptDurationSeconds"] = 7200
        artifact_directory = evidence_path.parent / "artifacts" / evidence_path.stem
        trace_basename = f"{scenario}-audio-attempt1"
        trace = artifact_directory / f"{trace_basename}.trace"
        trace.mkdir(parents=True)
        (trace / "data.bin").write_bytes(b"audio samples")
        toc = artifact_directory / f"{trace_basename}-toc.xml"
        toc.write_text('<trace-toc><table schema="audio"/></trace-toc>')
        raw_name = "swiftvlc-timebase-fixture-vod-1-vod.jsonl"
        raw = artifact_directory / raw_name
        raw.write_text(
            "".join(
                json.dumps(
                    timebase_raw_sample(
                        elapsed,
                        (0.5, 1, 2)[elapsed // 2400],
                        (
                            elapsed * 0.5
                            if elapsed < 2400
                            else (
                                1200 + (elapsed - 2400)
                                if elapsed < 4800
                                else 3600 + (elapsed - 4800) * 2
                            )
                        ),
                    )
                )
                + "\n"
                for elapsed in range(7200)
            )
        )
        evidence["audioPresentationSeries"] = {
            "hostTrace": self.trace_binding(
                trace,
                toc,
                run_artifact=(f"artifacts/{evidence_path.stem}/{trace_basename}.trace"),
                toc_artifact=(
                    f"artifacts/{evidence_path.stem}/{trace_basename}-toc.xml"
                ),
                role="audioPresentationSeries",
                template="Audio System Trace",
                producer=evidence["qualificationProducer"],
                evidence_stem=evidence_path.stem,
                scenario=scenario,
                target_device_identifier="fixture-iphone",
                device_duration=7200,
            )
        }
        raw_binding = qualification_policy.inspect_timebase_raw_capture(raw, 1)
        raw_binding.pop("_correctionSequences")
        evidence["rawCapture"] = {
            **raw_binding,
            "runArtifact": f"artifacts/{evidence_path.stem}/{raw_name}",
            "digestAlgorithm": "sha256",
            **qualification_policy.host_artifact_producer_fields(
                evidence, evidence_path.stem
            ),
        }
        evidence["corrections"] = []
        evidence["driftBudget"] = {"maximumSeconds": 2.1}
        evidence["correctionBudget"] = {"maximumSeconds": 2.1}
        evidence_path.write_text(json.dumps(evidence))
        self.validate_report_receipt(report_path, stable_required=True)

        output = self.root / "qualification" / "1.1.0.json"
        assemble_record.assemble(
            "1.1.0", self.candidate, self.matrix, [report_path], output
        )

        retained = (
            output.parent / "evidence" / "1.1.0" / "artifacts" / evidence_path.stem
        )
        self.assertTrue((retained / f"{trace_basename}.trace" / "data.bin").is_file())
        self.assertTrue((retained / f"{trace_basename}-toc.xml").is_file())
        self.assertEqual((retained / raw_name).read_bytes(), raw.read_bytes())

        raw.write_text("tampered\n")
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

    def test_rejects_mixed_candidate_app_reports(self):
        report = self.make_report("iphone")
        payload = json.loads(report.read_text())
        payload["candidateAppDigest"] = "9" * 64
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
        report = self.make_report("iphone")
        payload = json.loads(self.candidate.read_text())
        payload["artifactDigestAlgorithm"] = "sha256-file-only"
        self.candidate.write_text(json.dumps(payload))
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0",
                self.candidate,
                self.matrix,
                [report],
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
        (self.root / "oracles").mkdir()
        (self.root / "oracles" / "progressive-range.mp4").write_bytes(
            bytes(range(256)) * 64
        )
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
        connection = http.client.HTTPConnection(
            "127.0.0.1", self.server.server_port, timeout=3
        )
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

    def wait_for_log_path(self, path: str) -> dict:
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            if self.log.exists():
                for line in reversed(self.log.read_text().splitlines()):
                    record = json.loads(line)
                    if record.get("path") == path:
                        return record
            time.sleep(0.01)
        self.fail(f"fixture server did not record completed request {path}")

    def test_static_file_supports_byte_ranges(self):
        connection, response = self.request(
            "/files/sample.bin", {"Range": "bytes=10-19"}
        )
        self.assertEqual(response.status, 206)
        self.assertEqual(
            response.read(), (self.root / "sample.bin").read_bytes()[10:20]
        )
        connection.close()

        size = (self.root / "sample.bin").stat().st_size
        record = self.last_log_record()
        self.assertEqual(record["requestRange"], "bytes=10-19")
        self.assertEqual(record["responseContentRange"], f"bytes 10-19/{size}")

    def test_progressive_range_transcript_is_command_phase_and_token_bound(self):
        token = "candidate-attempt1"
        connection, response = self.request(
            f"/progressive/{token}/range/media.mp4",
            {"Range": "bytes=0-1023"},
        )
        self.assertEqual(response.status, 206)
        self.assertEqual(len(response.read()), 1024)
        connection.close()

        connection, response = self.request(
            f"/progressive/{token}/range/command",
            {
                fixture_server.PROGRESSIVE_COMMAND_ORIGIN_HEADER: fixture_server.PROGRESSIVE_COMMAND_ORIGIN
            },
        )
        marker = json.loads(response.read())
        connection.close()
        self.assertEqual(marker["kind"], "command-marker")
        self.assertEqual(marker["phase"], "post-command")
        self.assertEqual(marker["origin"], fixture_server.PROGRESSIVE_COMMAND_ORIGIN)
        self.assertEqual(marker["precommandRequestCount"], 1)
        self.assertEqual(marker["precommandTransferredBytes"], 1024)

        connection, response = self.request(
            f"/progressive/{token}/range/media.mp4",
            {"Range": "bytes=4096-8191"},
        )
        self.assertEqual(response.status, 206)
        self.assertEqual(len(response.read()), 4096)
        connection.close()

        connection, response = self.request(f"/progressive/{token}/transcript")
        transcript = json.loads(response.read())
        connection.close()
        self.assertEqual(transcript["token"], token)
        self.assertEqual(
            [event["sequence"] for event in transcript["events"]], [1, 2, 3]
        )
        first, command, seek = transcript["events"]
        self.assertEqual(
            (first["kind"], first["phase"]), ("media-request", "pre-command")
        )
        self.assertEqual(
            (command["kind"], command["mode"]), ("command-marker", "range")
        )
        self.assertEqual(first["transferredBytesAtCommand"], 1024)
        self.assertIsNone(seek["transferredBytesAtCommand"])
        self.assertEqual(
            (seek["kind"], seek["phase"]), ("media-request", "post-command")
        )
        self.assertEqual(seek["requestRange"], "bytes=4096-8191")
        self.assertEqual(seek["responseStatus"], 206)
        self.assertEqual(
            seek["responseContentRange"],
            f"bytes 4096-8191/{transcript['fixtureBytes']}",
        )
        self.assertEqual(seek["acceptRanges"], "bytes")

    def test_progressive_no_range_ignores_range_and_omits_capability(self):
        token = "candidate-attempt1"
        connection, response = self.request(
            f"/progressive/{token}/no-range/media.mp4",
            {"Range": "bytes=4096-8191"},
        )
        self.assertEqual(response.status, 200)
        self.assertIsNone(response.getheader("Accept-Ranges"))
        self.assertIsNone(response.getheader("Content-Range"))
        self.assertEqual(
            response.read(),
            (self.root / "oracles" / "progressive-range.mp4").read_bytes(),
        )
        connection.close()

        connection, response = self.request(f"/progressive/{token}/transcript")
        transcript = json.loads(response.read())
        connection.close()
        event = transcript["events"][0]
        self.assertEqual(event["mode"], "no-range")
        self.assertEqual(event["requestRange"], "bytes=4096-8191")
        self.assertEqual(event["responseStatus"], 200)
        self.assertIsNone(event["responseContentRange"])
        self.assertIsNone(event["acceptRanges"])

    def test_progressive_request_phase_is_fixed_when_request_begins(self):
        token = "candidate-attempt1"
        self.server.chunk_delay = 0.05
        connection, response = self.request(
            f"/progressive/{token}/range/media.mp4",
            {"Range": "bytes=0-16383"},
        )
        self.assertEqual(len(response.read(512)), 512)
        marker_connection, marker_response = self.request(
            f"/progressive/{token}/range/command",
            {
                fixture_server.PROGRESSIVE_COMMAND_ORIGIN_HEADER: fixture_server.PROGRESSIVE_COMMAND_ORIGIN
            },
        )
        self.assertEqual(marker_response.status, 200)
        marker = json.loads(marker_response.read())
        marker_connection.close()
        response.read()
        connection.close()

        connection, response = self.request(f"/progressive/{token}/transcript")
        transcript = json.loads(response.read())
        connection.close()
        media = [
            event for event in transcript["events"] if event["kind"] == "media-request"
        ]
        self.assertEqual(len(media), 1)
        self.assertEqual(media[0]["phase"], "pre-command")
        self.assertLess(media[0]["sequence"], transcript["events"][1]["sequence"])
        self.assertEqual(
            media[0]["transferredBytesAtCommand"],
            marker["precommandTransferredBytes"],
        )
        self.assertGreater(marker["precommandTransferredBytes"], 0)
        self.assertLess(marker["precommandTransferredBytes"], 16_384)

    def test_progressive_command_marker_rejects_non_candidate_origin(self):
        token = "candidate-attempt1"
        for headers in (
            {},
            {fixture_server.PROGRESSIVE_COMMAND_ORIGIN_HEADER: "xcui-test-process"},
        ):
            with self.subTest(headers=headers):
                connection, response = self.request(
                    f"/progressive/{token}/range/command", headers
                )
                self.assertEqual(response.status, 400)
                response.read()
                connection.close()

        connection, response = self.request(f"/progressive/{token}/transcript")
        transcript = json.loads(response.read())
        connection.close()
        self.assertEqual(transcript["events"], [])

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

    def test_server_close_quiesces_request_log_before_owner_cleanup(self):
        log_directory = self.root / "closing-request-log"
        log_directory.mkdir()
        log_path = log_directory / "requests.jsonl"
        write_started = threading.Event()
        release_write = threading.Event()
        close_finished = threading.Event()
        failures: list[BaseException] = []

        class BlockingRequestLog:
            def __init__(self):
                self.open_count = 0

            def open(self, *args, **kwargs):
                self.open_count += 1
                write_started.set()
                if not release_write.wait(timeout=2):
                    raise TimeoutError("request-log write was never released")
                return log_path.open(*args, **kwargs)

        blocking_log = BlockingRequestLog()
        closing_server = fixture_server.FixtureHTTPServer(
            ("127.0.0.1", 0), self.root, blocking_log, 512, 0, False
        )

        def write_record():
            try:
                closing_server.record({"path": "/late"})
            except BaseException as error:
                failures.append(error)

        def close_server():
            try:
                closing_server.server_close()
            except BaseException as error:
                failures.append(error)
            finally:
                close_finished.set()

        writer = threading.Thread(target=write_record)
        closer = threading.Thread(target=close_server)
        try:
            writer.start()
            self.assertTrue(write_started.wait(timeout=1))
            closer.start()
            self.assertFalse(close_finished.wait(timeout=0.05))

            release_write.set()
            writer.join(timeout=1)
            closer.join(timeout=1)
            self.assertFalse(writer.is_alive())
            self.assertFalse(closer.is_alive())
            self.assertEqual(failures, [])
            self.assertEqual(blocking_log.open_count, 1)

            log_path.unlink()
            log_directory.rmdir()
            closing_server.record({"path": "/after-close"})
            self.assertEqual(blocking_log.open_count, 1)
            self.assertFalse(log_directory.exists())
        finally:
            release_write.set()
            writer.join(timeout=1)
            if closer.ident is not None:
                closer.join(timeout=1)
            closing_server.server_close()

    def test_bind_failure_preserves_original_socket_error(self):
        with self.assertRaises(OSError) as raised:
            fixture_server.FixtureHTTPServer(
                self.server.server_address,
                self.root,
                self.log,
                512,
                0,
                False,
            )

        self.assertEqual(raised.exception.errno, errno.EADDRINUSE)

    def test_stall_endpoint_delays_then_completes(self):
        started = time.monotonic()
        connection, response = self.request("/fault/stall/0.15/sample.bin")
        self.assertEqual(
            len(response.read()), (self.root / "sample.bin").stat().st_size
        )
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
        self.assertEqual(
            response.read(512), (self.root / "sample.bin").read_bytes()[:512]
        )

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
        self.assertEqual(response.getheader("Transfer-Encoding"), "chunked")
        self.assertIsNone(response.getheader("Content-Length"))
        self.assertEqual(
            response.read(512), (self.root / "sample.bin").read_bytes()[:512]
        )

        trigger_connection, trigger_response = self.request(
            "/fault/close-trigger/source-loss"
        )
        self.assertEqual(trigger_response.status, 200)
        self.assertEqual(json.loads(trigger_response.read()), {"generation": 1})
        trigger_connection.close()

        with self.assertRaises(http.client.IncompleteRead) as incomplete:
            response.read()
        buffered_after_trigger = incomplete.exception.partial
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
        cleanup_connection, cleanup_response = self.request(
            "/fault/close-trigger/source-loss-retry"
        )
        self.assertEqual(json.loads(cleanup_response.read()), {"generation": 1})
        cleanup_connection.close()
        with self.assertRaises(http.client.IncompleteRead):
            retry_response.read()
        retry_connection.close()
        self.wait_for_log_path("/fault/gated-close/source-loss-retry/sample.bin")

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

        connection, response = self.request("/adaptive/run/abr-low-ts/low.m3u8")
        subtitle_vod = response.read().decode()
        connection.close()
        self.assertEqual(subtitle_vod.count("#EXTINF:2.000,"), 60)
        self.assertIn("#EXT-X-PLAYLIST-TYPE:VOD", subtitle_vod)
        self.assertIn("#EXT-X-DISCONTINUITY", subtitle_vod)
        self.assertTrue(subtitle_vod.rstrip().endswith("#EXT-X-ENDLIST"))

        connection, response = self.request("/adaptive/run/metrics")
        metrics = json.loads(response.read())
        connection.close()
        self.assertEqual(metrics["formatVersion"], 1)
        self.assertEqual(metrics["token"], "run")
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

    def test_timebase_vod_is_four_hour_seekable_high_variant_timeline(self):
        connection, response = self.request(
            "/adaptive/timebase/timebase-vod-ts/master.m3u8"
        )
        master = response.read().decode()
        connection.close()
        self.assertEqual(master.count("#EXT-X-STREAM-INF:"), 1)
        self.assertIn("RESOLUTION=640x360", master)
        self.assertNotIn("RESOLUTION=320x180", master)

        connection, response = self.request(
            "/adaptive/timebase/timebase-vod-ts/high.m3u8"
        )
        playlist = response.read().decode()
        connection.close()
        segment_count = fixture_server.TIMEBASE_VOD_SECONDS // 2
        self.assertEqual(playlist.count("#EXTINF:2.000,"), segment_count)
        self.assertEqual(playlist.count("?sequence="), segment_count)
        self.assertEqual(
            playlist.count("#EXT-X-DISCONTINUITY\n"),
            segment_count // 4 - 1,
        )
        self.assertIn("#EXT-X-PLAYLIST-TYPE:VOD", playlist)
        self.assertIn("?sequence=7199", playlist)
        self.assertTrue(playlist.rstrip().endswith("#EXT-X-ENDLIST"))

    def test_host_control_request_times_out_when_server_never_replies(self):
        runner = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        start = runner.index("request_fixture_control() {")
        end = runner.index("\n}\n", start) + 2
        release = threading.Event()
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            listener.settimeout(8)

            def stall():
                with listener.accept()[0]:
                    release.wait(8)

            worker = threading.Thread(target=stall, daemon=True)
            worker.start()
            program = runner[start:end] + '\nCONTROL_BASE_URL="$1"\nrequest_fixture_control metrics\n'
            started = time.monotonic()
            try:
                result = subprocess.run(
                    ["bash", "-c", program, "control-probe",
                     f"http://127.0.0.1:{listener.getsockname()[1]}"],
                    capture_output=True, text=True, timeout=8,
                    env={**os.environ, "http_proxy": "http://127.0.0.1:1", "ALL_PROXY": "http://127.0.0.1:1"},
                )
                self.assertEqual(result.returncode, 28, result.stderr)
                self.assertLess(time.monotonic() - started, 7)
            finally:
                release.set()
                worker.join(timeout=2)

    def test_apple_audio_shell_capture_retains_exact_quiescent_metrics(self):
        token = "hostproof"
        for path in (
            f"/adaptive/{token}/timebase-vod-ts/master.m3u8",
            f"/adaptive/{token}/timebase-vod-ts/high.m3u8",
            f"/adaptive/{token}/timebase-vod-ts/high/segment-000.ts?sequence=0",
            f"/adaptive/{token}/timebase-vod-ts/high/segment-001.ts?sequence=1",
        ):
            connection, response = self.request(path)
            self.assertEqual(response.status, 200)
            response.read()
            connection.close()

        runner = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        start = runner.index("request_fixture_control() {")
        end = runner.index("\n}\n\nrun_scenario()", start) + 2
        function_source = runner[start:end]
        destination = self.root / "captured" / "attempt-1.json"
        program = (
            "set -euo pipefail\n"
            + function_source
            + '\nCONTROL_BASE_URL="$1"\n'
            + 'capture_apple_audio_source_metrics "$2" 2 "$3"\n'
        )
        subprocess.run(
            [
                "bash",
                "-c",
                program,
                "swiftvlc-source-proof",
                f"http://127.0.0.1:{self.server.server_port}",
                token,
                str(destination),
            ],
            check=True,
            timeout=15,
        )
        retained = json.loads(destination.read_text())
        self.assertEqual(retained["formatVersion"], 1)
        self.assertEqual(retained["token"], token)
        self.assertEqual(retained["segmentRequests"], 2)
        self.assertEqual(retained["successfulSegments"], 2)
        self.assertEqual(retained["successfulSegmentsByVariant"], {"low": 0, "high": 2})

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
        forced_metrics = json.loads(response.read())
        self.assertEqual(forced_metrics["variantTransitions"], 0)
        self.assertEqual(
            forced_metrics["successfulSegmentsByVariant"],
            {"low": 1, "high": 1},
        )
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
