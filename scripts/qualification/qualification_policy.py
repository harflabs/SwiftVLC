#!/usr/bin/env python3
"""One fail-closed policy for SwiftVLC physical qualification evidence.

Every producer and consumer imports this module.  Keeping identity, duration,
XCTest, fixture, and evidence semantics here prevents an early-stage check from
being stricter than the release gate (or, more dangerously, the reverse).
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import math
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unicodedata
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Mapping, Sequence
from urllib.parse import unquote, urlparse
from xml.etree import ElementTree


class QualificationPolicyError(ValueError):
    pass


MAXIMUM_STABLE_REPORT_AGE_SECONDS = 30 * 24 * 60 * 60
MAXIMUM_REPORT_CLOCK_SKEW_SECONDS = 5 * 60
ORDINARY_RELEASE_GATE_REASON = (
    "automated smoke coverage is not yet the complete required matrix"
)


SHA1 = re.compile(r"[0-9a-f]{40}")
SHA256 = re.compile(r"[0-9a-f]{64}")
ID = re.compile(r"[a-z0-9][a-z0-9-]*")
BUNDLE_IDENTIFIER = re.compile(
    r"[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+"
)
CANONICAL_TEST_RUNNER_BUNDLE_IDENTIFIER = "com.swiftvlc.showcase.ios.uitests.xctrunner"
EXPLORATORY_FUTURE_IOS_HARDWARE_ID = "exploratory-future-ios"
DEVICE_SNAPSHOT_RELATIVE_PATH = "device.json"
DEVICE_SNAPSHOT_BINDING_FIELDS = frozenset(
    {"relativePath", "digestAlgorithm", "digest", "sizeBytes"}
)
NORMALIZED_DEVICE_FIELDS = frozenset(
    {
        "id",
        "udid",
        "ecid",
        "ecidHex",
        "name",
        "marketingName",
        "deviceFamily",
        "productType",
        "osVersion",
        "osMajor",
        "osBuild",
        "osReleaseType",
        "transport",
        "tunnelIPAddress",
        "connected",
        "matchingHardwareRows",
        "qualificationEligible",
    }
)
DEVICE_SNAPSHOT_FIELDS = frozenset(
    {"selected", "connected", "allPhysicalIOSDevices", "mode"}
)

# These are release claims, not tuning knobs.  Exploratory runs may request a
# shorter duration, but a stable row is always measured against this table even
# if matrix.json or an environment variable is weakened.
STABLE_MINIMUM_DURATION_SECONDS = {
    "adaptive-hls-soak": 7200,
    "pip-render-performance-1080p60": 900,
    "pip-render-performance-4k60": 900,
    "cadence-matrix": 600,
    "native-subtitle-matrix": 900,
    "timebase-vod-soak": 7200,
    "timebase-live-soak": 7200,
}

# XCTest setup/teardown and artifact export occur outside the device-side
# monotonic clock.  Five seconds tolerates integer truncation at the lower
# boundary; five minutes is the maximum reviewed host-only overhead.  A larger
# delta is a hung/retried host run, not proof that the device exercised media.
ENDURANCE_HOST_EARLY_TOLERANCE_SECONDS = 5
ENDURANCE_HOST_MAXIMUM_OVERHEAD_SECONDS = 300
ENDURANCE_SERIES_MAXIMUM_UNCOVERED_SECONDS = 120
ENDURANCE_SERIES_MAXIMUM_GAP_SECONDS = 120
TIMEBASE_AUDIO_PROGRESS_MAXIMUM_GAP_SECONDS = 15
TIMEBASE_AUDIO_MAXIMUM_LOST_BUFFER_RATIO = 0.01
ADAPTIVE_PROGRESS_WINDOW_SECONDS = 60
ADAPTIVE_VISUAL_MOTION_MINIMUM_SCORE = 0.01
ADAPTIVE_MEMORY_SAMPLE_KEYS = {
    "elapsedSeconds",
    "mode",
    "residentBytes",
    "mallocBytesInUse",
    "mallocBytesAllocated",
    "playerState",
    "readBytes",
    "decodedVideoFrames",
    "displayedPictures",
    "demuxDiscontinuities",
}
ADAPTIVE_PROGRESS_WINDOW_KEYS = {
    "mode",
    "startElapsedSeconds",
    "endElapsedSeconds",
    "readBytesDelta",
    "decodedVideoFramesDelta",
    "displayedPicturesDelta",
}
CADENCE_WINDOW_SECONDS = 5
CADENCE_RATE_TOLERANCE_FRACTION = 0.15
CADENCE_VISUAL_MOTION_MINIMUM_SCORE = 0.01
CADENCE_MINIMUM_SUBMISSION_FRACTION = 0.90
CADENCE_VFR_REGIME_SECONDS = 2.0
CADENCE_VFR_MINIMUM_REGIME_SOURCE_FRAME_FRACTION = 0.50
CADENCE_PROFILE_ORDER = (
    "23.976",
    "24",
    "25",
    "29.97",
    "30",
    "50",
    "59.94",
    "60",
    "vfr-24-60",
)
CADENCE_CFR_SOURCE_RATES = {
    "23.976": 24000 / 1001,
    "24": 24.0,
    "25": 25.0,
    "29.97": 30000 / 1001,
    "30": 30.0,
    "50": 50.0,
    "59.94": 60000 / 1001,
    "60": 60.0,
}
CADENCE_CFR_SOURCE_RATE_RATIONALS = {
    "23.976": (24000, 1001),
    "24": (24, 1),
    "25": (25, 1),
    "29.97": (30000, 1001),
    "30": (30, 1),
    "50": (50, 1),
    "59.94": (60000, 1001),
    "60": (60, 1),
}
CADENCE_SAMPLE_REQUIRED_KEYS = {
    "profile",
    "sourceIntervalCounts",
    "systemUptime",
    "elapsedSeconds",
    "playbackGeneration",
    "requestedRate",
    "effectivePlayerRate",
    "lastPTSSeconds",
    "deliveredFrames",
    "droppedFrames",
    "backpressureEvents",
    "vmemOutputTimestampProvenance",
    "vmemOutputPlaybackGeneration",
    "vmemOutputVoutGeneration",
    "vmemOutputCallbackCount",
    "vmemOutputValidPTSCount",
    "vmemOutputInvalidPTSCount",
    "vmemOutputDuplicatePTSCount",
    "vmemOutputBackwardPTSCount",
    "vmemOutputDeltaOverflowCount",
    "vmemOutputSubmittedCount",
    "vmemOutputSwiftRejectedCount",
    "vmemOutputInFlightCount",
    "vmemOutputFirstPTSUS",
    "vmemOutputLastPTSUS",
    "vmemOutputFirstValidPTSUS",
    "vmemOutputLastValidPTSUS",
    "vmemOutputDeltaHistogram",
    "vmemOutputIntervalCounts",
    "libVLCDecodedVideoCount",
    "libVLCDisplayedPictureCount",
    "libVLCLostPictureCount",
    "libVLCLatePictureCount",
}
CADENCE_SAMPLE_OPTIONAL_KEYS = {
    "durationValue",
    "durationTimescale",
    "renderTarget",
}
CADENCE_ORACLE_WINDOW_KEYS = {
    "profile",
    "requestedRate",
    "startElapsedSeconds",
    "durationSeconds",
    "windowStartSystemUptime",
    "windowEndSystemUptime",
    "windowDurationSeconds",
    "appliedRate",
    "nativePTSDeltaSeconds",
    "nativePTSExactIntervalCount",
    "nativePTSMultipleIntervalCount",
    "nativePTSEstimatedSkippedPictureCount",
    "nativePTSRedisplayCount",
    "nativePTSUnclassifiedIntervalCount",
    "nativePTSBackwardCount",
    "nativePTSDeltaOverflowCount",
    "nativePTSDeltaHistogram",
    "outputCallbackCount",
    "submittedFrames",
    "swiftRejectedFrames",
    "observedSubmissionFPS",
    "minimumSubmissionFPS",
    "libVLCDecodedVideoDelta",
    "libVLCDisplayedPictureDelta",
    "libVLCLostPictureDelta",
    "libVLCLatePictureDelta",
    "deliveredFrames",
    "visualMotionScore",
    "distinctFrameHashes",
}
CADENCE_RAW_EVIDENCE_KEYS = {
    "startedSystemUptime",
    "durationSeconds",
    "rates",
    "vfr",
    "sourceTimestampProvenance",
    "vmemOutputTimestampProvenance",
    "presentationMetrics",
    "transitionResults",
    "fabricatedDurationCount",
    "samples",
    "springboardResizeGestures",
    "visualObservations",
    "visualCaptureBindings",
    "cadenceOracle",
}
CADENCE_VMEM_DELTA_HISTOGRAM_ENTRY_KEYS = {"deltaMicroseconds", "count"}
CADENCE_INTERVAL_COUNT_KEYS = {
    "fps23_976",
    "fps24",
    "fps25",
    "fps29_97",
    "fps30",
    "fps50",
    "fps59_94",
    "fps60",
    "other",
}
CADENCE_PRESENTATION_METRIC_REQUIRED_KEYS = {
    "profile",
    "deliveredFrames",
    "droppedFrames",
    "dropRate",
    "elapsedSeconds",
    "presentationRate",
    "backpressureEvents",
    "presentationCopyFailures",
    "displayConsumeFailures",
}
CADENCE_PRESENTATION_METRIC_OPTIONAL_KEYS = {
    "observedDurationValue",
    "observedDurationTimescale",
}
CADENCE_TRANSITION_RESULT_KEYS = {
    "rateChanges",
    "pauseResumeCycles",
    "replacements",
    "resizeCycles",
    "resizeTargets",
    "monotonicityViolations",
}
CADENCE_VISUAL_CAPTURE_BINDING_KEYS = {
    "profile",
    "requestedRate",
    "startElapsedSeconds",
    "durationSeconds",
    "windowStartSystemUptime",
    "windowEndSystemUptime",
    "captureElapsedSeconds",
    "captureSystemUptimes",
    "canonicalRGB8Base64",
}
VISUAL_OBSERVATION_METHOD = "xcui-video-surface-rgb8-64x36-delta12-v1"
CADENCE_SOURCE_TIMESTAMP_PROVENANCE = "libvlc-picture_t.date-native-callback-v1"
CADENCE_VMEM_OUTPUT_TIMESTAMP_PROVENANCE = (
    "libvlc-vmem-post-filter-vout-selected-output-attempt-pts-v1"
)
CADENCE_SEMANTICS_PROBE_SCENARIO = "cadence-semantics-probe"
CADENCE_SEMANTICS_PROBE_TEST_IDENTIFIER = (
    "iOSUITests/PiPCadenceSemanticsProbeDeviceUITests/"
    "test_reportOnlyVmemCadenceSemanticsProbe"
)
CADENCE_SEMANTICS_PROBE_ATTACHMENT_NAME = (
    "exploratory-pip-cadence-semantics-probe.json"
)
CADENCE_SEMANTICS_PROBE_CAPTURE_BOUNDARY_GUARD_SECONDS = 0.1
CADENCE_SEMANTICS_PROBE_EXPECTED_WINDOWS = (
    ("24", 0.5),
    ("60", 1.0),
    ("30", 2.0),
    ("50", 2.0),
    ("59.94", 2.0),
    ("60", 2.0),
    ("vfr-24-60", 0.5),
    ("vfr-24-60", 1.0),
    ("vfr-24-60", 2.0),
)
CADENCE_SEMANTICS_PROBE_REPORT_KEYS = {
    "formatVersion",
    "purpose",
    "releaseCreditEligible",
    "vmemOutputTimestampProvenance",
    "targetWindowSeconds",
    "settlingSeconds",
    "startedSystemUptime",
    "endedSystemUptime",
    "windows",
    "springBoardFrames",
}
CADENCE_SEMANTICS_PROBE_WINDOW_KEYS = {
    "profile",
    "requestedRate",
    "windowStartSystemUptime",
    "windowEndSystemUptime",
    "windowDurationSeconds",
    "effectivePlayerRateStart",
    "effectivePlayerRateEnd",
    "controlTimebaseRateStart",
    "controlTimebaseRateEnd",
    "controlTimebaseDeltaSeconds",
    "mediaTimeDeltaSeconds",
    "nativePTSDeltaSeconds",
    "nativePTSDeltaMatchesHistogram",
    "nativePTSDeltaHistogram",
    "nativePTSClassification",
    "outputCallbackCount",
    "validPTSCount",
    "invalidPTSCount",
    "submittedFrames",
    "swiftRejectedFrames",
    "inFlightStart",
    "inFlightEnd",
    "callbackConservationAtStart",
    "callbackConservationAtEnd",
    "callbackDeltaConservation",
    "observedSubmissionFPS",
    "renderer",
    "libVLC",
    "before",
    "after",
}
CADENCE_SEMANTICS_PROBE_CLASSIFICATION_KEYS = {
    "exactIntervalCount",
    "multipleIntervalCount",
    "estimatedSkippedPictureCount",
    "redisplayCount",
    "backwardCount",
    "unclassifiedIntervalCount",
    "deltaOverflowCount",
}
CADENCE_SEMANTICS_PROBE_RENDERER_COUNTERS = {
    "vmemLockAttempts": "vmemLockAttemptCount",
    "vmemLockSuccesses": "vmemLockSuccessCount",
    "vmemPoolUnavailable": "vmemPoolUnavailableCount",
    "vmemBaseAddressLockFailures": "vmemBaseAddressLockFailureCount",
    "vmemPendingInstallFailures": "vmemPendingInstallFailureCount",
    "vmemUnlockCallbacks": "vmemUnlockCallbackCount",
    "vmemDisplayCallbacks": "vmemDisplayCallbackCount",
    "vmemDisplayConsumeFailures": "vmemDisplayConsumeFailureCount",
    "enqueuedFrames": "enqueuedFrameCount",
    "deliveredFrames": "deliveredFrameCount",
    "droppedFrames": "droppedFrameCount",
    "presentationCopyFrames": "presentationCopyFrameCount",
    "presentationCopyFailures": "presentationCopyFailureCount",
    "decodePoolAllocationFailures": "decodePoolAllocationFailureCount",
    "renderPoolAllocationFailures": "renderPoolAllocationFailureCount",
}
CADENCE_SEMANTICS_PROBE_LIBVLC_COUNTERS = {
    "decodedVideo": "libVLCDecodedVideoCount",
    "displayedPictures": "libVLCDisplayedPictureCount",
    "lostPictures": "libVLCLostPictureCount",
    "latePictures": "libVLCLatePictureCount",
}
CADENCE_SEMANTICS_PROBE_SPRINGBOARD_RECORD_KEYS = {
    "profile",
    "requestedRate",
    "windowStartSystemUptime",
    "windowEndSystemUptime",
    "captureStartSystemUptimes",
    "captureEndSystemUptimes",
    "captureSystemUptimes",
    "canonicalRGB8Base64",
    "frameHashes",
    "adjacentChangedPixelRatios",
    "changedPixelScore",
}
CADENCE_SEMANTICS_PROBE_PROOF_FIELDS = {
    "formatVersion",
    "authority",
    "version",
    "releaseCreditEligible",
    "sourceAttempt",
    "sourceXcresultArtifact",
    "sourceXcresultDigestAlgorithm",
    "sourceXcresultDigest",
    "sourceXcresultSizeBytes",
    "retainedFinalXcresultArtifact",
    "retainedFinalXcresultDigestAlgorithm",
    "retainedFinalXcresultDigest",
    "retainedFinalXcresultSizeBytes",
    "attachmentName",
    "attachmentTestIdentifier",
    "retainedAttachmentRoot",
    "manifestRelativePath",
    "manifestDigestAlgorithm",
    "manifestDigest",
    "manifestSizeBytes",
    "attachmentRelativePath",
    "attachmentDigestAlgorithm",
    "attachmentDigest",
    "attachmentSizeBytes",
}
CADENCE_SEMANTICS_PROBE_RUNNER_FIELDS = {
    "scenario",
    "result",
    "xcodebuildExitCode",
    "libraryErrorCount",
    "appLog",
    "qualificationEvidence",
    "durationSeconds",
    "expectedTestCatalog",
    "testExecution",
    "attempts",
    "attemptArtifactRoot",
    "hostErrorInventory",
    "reportOnlyEvidence",
}
NATIVE_RENDERER_RECOVERY_SNAPSHOT_KEYS = {
    "abiVersion",
    "rawFlags",
    "displayGeneration",
    "recoveryEpisodeCount",
    "recoveredEpisodeCount",
    "requirementNotificationCount",
    "revocationNotificationCount",
    "decodeFailureNotificationCount",
    "foregroundCheckCount",
    "recoveryFlushCount",
    "revocationFlushCount",
    "failureFlushCount",
    "discontinuityFlushCount",
    "successfulSubmissionCount",
    "recoverySubmissionCount",
    "retryableSubmissionCount",
    "recoverySampleFailureCount",
    "permanentFailureCount",
    "isCurrent",
    "requiresFlush",
    "isFailed",
    "isRecoveryInProgress",
    "hasRecoverySample",
}
NATIVE_RENDERER_RECOVERY_COUNTER_KEYS = {
    "recoveryEpisodeCount",
    "recoveredEpisodeCount",
    "requirementNotificationCount",
    "revocationNotificationCount",
    "decodeFailureNotificationCount",
    "foregroundCheckCount",
    "recoveryFlushCount",
    "revocationFlushCount",
    "failureFlushCount",
    "discontinuityFlushCount",
    "successfulSubmissionCount",
    "recoverySubmissionCount",
    "retryableSubmissionCount",
    "recoverySampleFailureCount",
    "permanentFailureCount",
}
NATIVE_RENDERER_RECOVERY_CHECK_KEYS = {
    "sameDisplayGeneration",
    "countersMonotonic",
    "actualResourceRevocationObserved",
    "requirementNotificationAdvanced",
    "revocationNotificationAdvanced",
    "foregroundCheckAdvanced",
    "recoveryEpisodeAdvanced",
    "recoveredEpisodeAdvanced",
    "recoveryFlushAdvanced",
    "revocationFlushAdvanced",
    "successfulSubmissionAdvanced",
    "recoverySubmissionAdvanced",
    "permanentFailureUnchanged",
    "episodesBalanced",
    "currentRenderer",
    "requiresFlushCleared",
    "failedCleared",
    "recoveryInProgressCleared",
    "recoverySampleAvailable",
}
NATIVE_RENDERER_RECOVERY_VISUAL_BINDING_KEYS = {
    "formatVersion",
    "method",
    "encoding",
    "frameWidthPixels",
    "frameHeightPixels",
    "channelCount",
    "bytesPerFrame",
    "frameCount",
    "captureSystemUptimeSeconds",
    "canonicalRGB8Base64",
}
NATIVE_RENDERER_RECOVERY_VISUAL_KEYS = {
    "formatVersion",
    "status",
    "reason",
    "surface",
    "captureBinding",
    "frameHashes",
    "adjacentChangedPixelRatios",
    "changedPixelScore",
    "distinctFrameHashes",
    "minimumChangedPixelScore",
}
NATIVE_RENDERER_RECOVERY_RAW_EVIDENCE_KEYS = {
    "formatVersion",
    "scenario",
    "renderingPath",
    "trigger",
    "syntheticNotificationsPosted",
    "playbackStateAtBaseline",
    "playbackStateAtEvaluation",
    "backgroundForegroundCycles",
    "status",
    "reason",
    "mechanics",
    "postRecoveryVisualOracle",
}
VOD_CONTROLS_RAW_EVIDENCE_KEYS = {
    "formatVersion",
    "scenario",
    "events",
    "controls",
    "backendResults",
    "systemPiPMotion",
}
PERFORMANCE_VISUAL_MAXIMUM_GAP_SECONDS = 120
PERFORMANCE_RESOURCE_BUDGETS = {
    "pip-render-performance-1080p60": {
        "cpuAverageCores": 3.0,
        "gpuAveragePercent": 75.0,
        "gpuMaximumPercent": 95.0,
        "energyAverageScore": 15.0,
        "energyMaximumScore": 50.0,
        "conversionAverageMilliseconds": 8.0,
        "conversionMaximumMilliseconds": 25.0,
    },
    "pip-render-performance-4k60": {
        "cpuAverageCores": 5.0,
        "gpuAveragePercent": 90.0,
        "gpuMaximumPercent": 100.0,
        "energyAverageScore": 25.0,
        "energyMaximumScore": 80.0,
        "conversionAverageMilliseconds": 16.0,
        "conversionMaximumMilliseconds": 50.0,
    },
}
ADAPTIVE_MODES = frozenset(
    {
        "abr-low-ts",
        "abr-high-fmp4",
        "vod-ts",
        "event-fmp4",
        "live-ts",
        "live-fmp4",
        "retry-ts",
        "abr-ts",
    }
)

SEEK_FRAME_ORACLE_CONTRACT = {
    "seekToleranceSeconds": 0.75,
    "preciseTargetSeconds": 23.5,
    "fastTargetSeconds": 40.0,
    "overlapTargetSeconds": 52.5,
    "frameCount": 120,
    "baselineTargetIndex": 10,
    "baselineToleranceFrames": 2,
    "singleAdvanceFrames": 1,
    "burstAdvanceFrames": 20,
    "replacementRequestCount": 12,
}

LOCAL_PLAYBACK_FIXTURE_CONTRACT = {
    "durationSeconds": 12,
    "video": [
        {
            "id": "h264-aac-mp4",
            "path": "local-playback/video/h264-aac.mp4",
            "container": "mp4",
            "videoCodec": "h264",
            "audioCodec": "aac",
            "width": 640,
            "height": 360,
            "framesPerSecond": 30,
            "sampleRate": 48000,
            "channels": 1,
        },
        {
            "id": "h264-aac-matroska",
            "path": "local-playback/video/h264-aac.mkv",
            "container": "matroska",
            "videoCodec": "h264",
            "audioCodec": "aac",
            "width": 640,
            "height": 360,
            "framesPerSecond": 30,
            "sampleRate": 48000,
            "channels": 1,
        },
        {
            "id": "h264-aac-fragmented-mp4",
            "path": "local-playback/video/h264-aac-fragmented.mp4",
            "container": "mp4",
            "videoCodec": "h264",
            "audioCodec": "aac",
            "width": 640,
            "height": 360,
            "framesPerSecond": 30,
            "sampleRate": 48000,
            "channels": 1,
        },
        {
            "id": "vp9-opus-webm",
            "path": "local-playback/video/vp9-opus.webm",
            "container": "webm",
            "videoCodec": "vp9",
            "audioCodec": "opus",
            "width": 640,
            "height": 360,
            "framesPerSecond": 30,
            "sampleRate": 48000,
            "channels": 1,
        },
        {
            "id": "mpeg2-mp2-ts",
            "path": "local-playback/video/mpeg2-mp2.ts",
            "container": "mpegts",
            "videoCodec": "mpeg2video",
            "audioCodec": "mp2",
            "width": 640,
            "height": 360,
            "framesPerSecond": 30,
            "sampleRate": 48000,
            "channels": 1,
        },
    ],
    "audio": [
        {
            "id": "aac-m4a",
            "path": "local-playback/audio/aac.m4a",
            "container": "mp4",
            "audioCodec": "aac",
            "sampleRate": 48000,
            "channels": 1,
        },
        {
            "id": "alac-m4a",
            "path": "local-playback/audio/alac.m4a",
            "container": "mp4",
            "audioCodec": "alac",
            "sampleRate": 48000,
            "channels": 1,
        },
        {
            "id": "mp3",
            "path": "local-playback/audio/mp3.mp3",
            "container": "mp3",
            "audioCodec": "mp3",
            "sampleRate": 48000,
            "channels": 1,
        },
        {
            "id": "flac",
            "path": "local-playback/audio/flac.flac",
            "container": "flac",
            "audioCodec": "flac",
            "sampleRate": 48000,
            "channels": 1,
        },
        {
            "id": "opus-ogg",
            "path": "local-playback/audio/opus.ogg",
            "container": "ogg",
            "audioCodec": "opus",
            "sampleRate": 48000,
            "channels": 1,
        },
        {
            "id": "pcm-wav",
            "path": "local-playback/audio/pcm-s16le.wav",
            "container": "wav",
            "audioCodec": "pcm_s16le",
            "sampleRate": 48000,
            "channels": 1,
        },
    ],
}
LOCAL_PLAYBACK_RAW_EVIDENCE_KEYS = {
    "formatVersion",
    "scenario",
    "matrixOutcome",
    "fixtureResults",
    "libraryErrorCount",
}
LOCAL_PLAYBACK_RESULT_KEYS = {
    "fixture",
    "sourceScheme",
    "localFileName",
    "downloadedSHA256",
    "downloadedBytes",
    "generationBefore",
    "generationAfter",
    "stateSequence",
    "durationMilliseconds",
    "measurementDurationMilliseconds",
    "measurementStartSystemUptime",
    "measurementEndSystemUptime",
    "start",
    "end",
}
LOCAL_PLAYBACK_COUNTER_KEYS = {
    "timeMilliseconds",
    "readBytes",
    "demuxReadBytes",
    "decodedVideo",
    "decodedAudio",
    "displayedPictures",
    "lostPictures",
    "playedAudioBuffers",
    "lostAudioBuffers",
}
LOCAL_PLAYBACK_VISUAL_KEYS = {
    "formatVersion",
    "method",
    "encoding",
    "frameWidthPixels",
    "frameHeightPixels",
    "channelCount",
    "bytesPerFrame",
    "frameCount",
    "captureSystemUptimeSeconds",
    "canonicalRGB8Base64",
    "frameHashes",
    "adjacentChangedPixelRatios",
    "changedPixelScore",
    "distinctFrameHashes",
}

PROGRESSIVE_HTTP_RANGE_FIXTURE_CONTRACT = {
    "path": "oracles/progressive-range.mp4",
    "durationSeconds": 120,
    "minimumBytes": 50_000_000,
    "width": 640,
    "height": 360,
    "framesPerSecond": 30,
    "keyframeIntervalSeconds": 10,
    "seekTargetMilliseconds": 43_500,
    "landingBoundaryMilliseconds": 40_000,
    "seekToleranceMilliseconds": 750,
    "bandDurationSeconds": 10,
    "targetBandIndex": 4,
    "targetBandRGB": "A020A0",
    "timelineCycleIndicator": {
        "secondHalfStartSeconds": 60,
        "rgb": "FFFFFF",
        "x": 480,
        "y": 300,
        "width": 120,
        "height": 40,
    },
    "serverChunkBytes": 7_520,
    "serverChunkDelayMilliseconds": 20,
}
PROGRESSIVE_HTTP_RANGE_RAW_EVIDENCE_KEYS = {
    "formatVersion",
    "scenario",
    "fixture",
    "attemptToken",
    "rangeCase",
    "noRangeCase",
    "libraryErrorCount",
}
PROGRESSIVE_HTTP_RANGE_FIXTURE_KEYS = {
    "id",
    "relativePath",
    "sha256",
    "bytes",
    "durationMilliseconds",
    "targetMilliseconds",
    "landingBoundaryMilliseconds",
}
PROGRESSIVE_HTTP_RANGE_COUNTER_KEYS = {
    "systemUptimeSeconds",
    "playbackGeneration",
    "state",
    "currentTimeMilliseconds",
    "durationMilliseconds",
    "isSeekable",
    "readBytes",
    "demuxReadBytes",
    "decodedVideo",
    "displayedPictures",
    "lostPictures",
}
PROGRESSIVE_HTTP_RANGE_SUCCESS_KEYS = {
    "mode",
    "attemptToken",
    "sourcePath",
    "targetMilliseconds",
    "landingBoundaryMilliseconds",
    "typedSeek",
    "start",
    "landing",
    "end",
    "visualCapture",
}
PROGRESSIVE_HTTP_NO_RANGE_SUCCESS_KEYS = {
    "mode",
    "attemptToken",
    "sourcePath",
    "targetMilliseconds",
    "seekableAtCommand",
    "typedRejection",
    "start",
    "end",
    "visualCapture",
}
PROGRESSIVE_HTTP_RANGE_TYPED_SEEK_KEYS = {
    "commandAttemptToken",
    "playbackGeneration",
    "targetMilliseconds",
    "fast",
    "initialOutcome",
    "terminalOutcome",
}
PROGRESSIVE_HTTP_NO_RANGE_REJECTION_KEYS = {
    "commandAttemptToken",
    "playbackGeneration",
    "errorDomain",
    "errorCase",
    "message",
    "commandDispatched",
}
PROGRESSIVE_HTTP_VISUAL_BASE_KEYS = {
    "formatVersion",
    "method",
    "encoding",
    "frameWidthPixels",
    "frameHeightPixels",
    "channelCount",
    "bytesPerFrame",
    "frameCount",
    "captureSystemUptimeIntervals",
    "canonicalRGB8Base64",
    "frameHashes",
    "adjacentChangedPixelRatios",
    "changedPixelScore",
    "distinctFrameHashes",
    "decodedBandIndices",
    "decodedTimelineSeconds",
}
PROGRESSIVE_HTTP_RANGE_VISUAL_KEYS = PROGRESSIVE_HTTP_VISUAL_BASE_KEYS
PROGRESSIVE_HTTP_CAPTURE_INTERVAL_KEYS = {
    "startSystemUptimeSeconds",
    "endSystemUptimeSeconds",
}
PROGRESSIVE_HTTP_TRANSCRIPT_BINDING_KEYS = {
    "sourceAttempt",
    "attemptToken",
    "relativePath",
    "digestAlgorithm",
    "digest",
    "sizeBytes",
    "eventCount",
}
PROGRESSIVE_HTTP_TRANSCRIPT_KEYS = {
    "formatVersion",
    "token",
    "fixtureRelativePath",
    "fixtureBytes",
    "events",
}
PROGRESSIVE_HTTP_MEDIA_EVENT_KEYS = {
    "kind",
    "sequence",
    "token",
    "mode",
    "phase",
    "method",
    "path",
    "fixtureRelativePath",
    "requestRange",
    "responseStatus",
    "responseContentRange",
    "acceptRanges",
    "responseContentLength",
    "transferredBytes",
    "transferredBytesAtCommand",
    "completed",
    "startedAtUTC",
    "completedAtUTC",
}
PROGRESSIVE_HTTP_COMMAND_EVENT_KEYS = {
    "kind",
    "sequence",
    "token",
    "mode",
    "phase",
    "origin",
    "precommandRequestCount",
    "precommandTransferredBytes",
    "markedAtUTC",
}
PROGRESSIVE_HTTP_MAXIMUM_PRECOMMAND_BYTES = 5_000_000
PROGRESSIVE_HTTP_MINIMUM_SEEK_RANGE_START = 10_000_000
PROGRESSIVE_HTTP_MAXIMUM_CAPTURE_INTERVAL_SECONDS = 1.0
PROGRESSIVE_HTTP_COMMAND_ORIGIN = "candidate-app-before-strict-request-seek-v1"

# Changing a feature from required to advisory (or deleting it) must be an
# explicit policy change reviewed alongside this validator.  A manifest cannot
# silently self-authorize weaker release obligations.
REQUIRED_FEATURE_IDS = frozenset(
    {
        "playback-finite-vod",
        "playback-unbounded-live",
        "playback-media-replacement",
        "playback-terminal-outcomes",
        "playback-local-file-matrix",
        "playback-audio-only",
        "playback-foreground-displaylayer-recovery",
        "transport-play-pause",
        "seek-absolute-scrub",
        "seek-relative-forward-backward",
        "seek-relative-zero-boundary",
        "seek-native-hls-continuity",
        "seek-capability-convergence",
        "transport-unpausable-input",
        "transport-ab-loop-boundaries",
        "seek-local-sparse-gop",
        "seek-progressive-http-range",
        "seek-overlap-cancellation",
        "seek-hls-before-playback",
        "seek-streamed-ogg-opus-backward",
        "seek-degraded-network-recovery",
        "seek-network-ts-repeated",
        "frame-step-exact-presentation",
        "frame-step-burst",
        "frame-step-resume-clock",
        "frame-step-eof-transition-safety",
        "pip-live-native-direct",
        "pip-restore",
        "pip-close",
        "pip-start-failure",
        "pip-replacement-active",
        "pip-native-lifecycle",
        "pip-system-overlay-controls",
        "audio-background-continuity",
        "audio-system-interruption",
        "audio-physical-route-changes",
        "audio-media-services-reset",
        "audio-session-ownership",
        "network-long-stall-recovery",
        "network-adaptive-hls-soak",
        "tracks-native-subtitles",
        "render-cadence-matrix",
        "tracks-selection-restoration",
        "performance-direct-pip-1080p60",
        "performance-direct-pip-4k60",
        "performance-vod-timebase-soak",
        "performance-live-timebase-soak",
        "performance-decoder-teardown-stress",
        "cast-discovery-identity",
        "cast-receiver-playback",
        "cast-controls-seeking-tracks",
        "cast-recast-session-isolation",
        "cast-network-loss-recovery",
        "cast-hls-receiver-playback",
        "cast-end-of-stream-drain",
        "cast-ipv6-discovery-connectivity",
    }
)

# Stable release qualification is not only the matrix rows. These support lanes
# prove analyzer correctness and broad UI/harness integration even though they
# do not emit a standalone matrix attachment. Order is part of the immutable
# contract: destructive media-services reset must be last, and a reordered
# receipt must not be able to claim that it represents the canonical run.
REQUIRED_RELEASE_RUNNER_SCENARIO_ORDER = (
    "analyzer",
    "ui-suite",
    "harness-regressions",
    "live-media",
    "background-audio",
    "continuity",
    "capability-convergence",
    "vod-controls",
    "long-stall",
    "failed-start",
    "dismissal",
    "interruptions",
    "audio-session-ownership",
    "native-lifecycle",
    "playback-foreground-displaylayer-recovery",
    "terminal-outcomes",
    "adaptive-hls-soak",
    "deferred-pause-rejection",
    "hls-seek",
    "seek-frame-oracles",
    "progressive-http-range-seek",
    "local-file-matrix",
    "audio-only-playback",
    "pip-render-performance-1080p60",
    "pip-render-performance-4k60",
    "cadence-matrix",
    "native-subtitle-matrix",
    "timebase-vod-soak",
    "timebase-live-soak",
    "audio-media-services-reset",
)
REQUIRED_RELEASE_RUNNER_SCENARIOS = frozenset(
    REQUIRED_RELEASE_RUNNER_SCENARIO_ORDER
)

IPHONE_CURRENT_ONLY_RUNNER_SCENARIOS = frozenset(
    {
        "capability-convergence",
        "native-lifecycle",
        "playback-foreground-displaylayer-recovery",
        "terminal-outcomes",
        "adaptive-hls-soak",
        "pip-render-performance-1080p60",
        "pip-render-performance-4k60",
        "cadence-matrix",
        "native-subtitle-matrix",
        "timebase-vod-soak",
        "timebase-live-soak",
        "deferred-pause-rejection",
        "seek-frame-oracles",
    }
)

# Matrix applicability is release policy, not data supplied by matrix.json.
# Keeping the hardware identities and row partition here prevents deleting an
# iPad (or narrowing one difficult scenario to the convenient phone) from
# silently reducing the release obligation.
REQUIRED_HARDWARE = {
    "iphone-minimum": ("iPhone", 18),
    "iphone-current": ("iPhone", 26),
    "ipad-minimum": ("iPad", 18),
    "ipad-current": ("iPad", 26),
}
ALL_HARDWARE_SCENARIOS = frozenset(
    {
        "vod-controls",
        "live-media",
        "restore",
        "close",
        "failed-start",
        "replacement",
        "interruptions",
        "audio-media-services-reset",
        "audio-session-ownership",
        "background-audio",
        "long-stall",
        "native-hls-seek-continuity",
        "progressive-http-range-seek",
        "local-file-matrix",
        "audio-only-playback",
    }
)
IPHONE_CURRENT_ONLY_SCENARIOS = frozenset(
    {
        "capability-convergence",
        "replacement-continuity",
        "seek-frame-oracles",
        "native-lifecycle",
        "playback-foreground-displaylayer-recovery",
        "terminal-outcomes",
        "adaptive-hls-soak",
        "pip-render-performance-1080p60",
        "pip-render-performance-4k60",
        "native-subtitle-matrix",
        "timebase-vod-soak",
        "timebase-live-soak",
        "cadence-matrix",
        "deferred-pause-rejection",
        "accepted-start-delayed-failure",
    }
)
CANONICAL_REQUIRED_ROWS = frozenset(
    {
        (scenario, hardware)
        for scenario in ALL_HARDWARE_SCENARIOS
        for hardware in REQUIRED_HARDWARE
    }
    | {(scenario, "iphone-current") for scenario in IPHONE_CURRENT_ONLY_SCENARIOS}
)
CANONICAL_REQUIRED_RUNNER_RUNS = frozenset(
    {
        (runner, hardware)
        for runner in REQUIRED_RELEASE_RUNNER_SCENARIOS
        for hardware in REQUIRED_HARDWARE
        if runner not in IPHONE_CURRENT_ONLY_RUNNER_SCENARIOS
        or hardware == "iphone-current"
    }
)
CANONICAL_SCENARIO_CONTRACT_DIGEST = (
    "71a6db675e8b8bc3066060d22d1167aee38638cc1118fde33248e5d4f422d246"
)
CANONICAL_RUNNER_CONTRACT_DIGEST = (
    "0b66fdeadda254b382a165d47f9630d4c8e7b839e33424a98ff9c5afe85fd8fa"
)
RELEASE_MATRIX_POLICY_IDENTITY = "swiftvlc-1.1.0-physical-qualification-v1"

# These backend-specific or report-only diagnostic leaves remain in the
# candidate bundle for targeted diagnosis but are not release obligations.
# The cadence semantics probe has its own non-release validation authority and
# must never leak into an ordinary ui-suite or release runner partition.
RELEASE_CATALOG_EXCEPTIONS = frozenset(
    {
        "iOSUITests/PiPLiveDeviceUITests/test_nativeLiveMPEGTSRendersMovingFramesInSystemPiP",
        "iOSUITests/PiPLiveDeviceUITests/test_directLiveMPEGTSRendersMovingFramesInSystemPiP",
        "iOSUITests/PiPCadenceSemanticsProbeDeviceUITests/test_reportOnlyVmemCadenceSemanticsProbe",
    }
)

QUALIFICATION_POLICY_DOCUMENT = {
    "formatVersion": 1,
    "stableMinimumDurationSeconds": STABLE_MINIMUM_DURATION_SECONDS,
    "enduranceDurationReconciliation": {
        "hostEarlyToleranceSeconds": ENDURANCE_HOST_EARLY_TOLERANCE_SECONDS,
        "hostMaximumOverheadSeconds": ENDURANCE_HOST_MAXIMUM_OVERHEAD_SECONDS,
        "seriesMaximumUncoveredSeconds": (ENDURANCE_SERIES_MAXIMUM_UNCOVERED_SECONDS),
        "seriesMaximumGapSeconds": ENDURANCE_SERIES_MAXIMUM_GAP_SECONDS,
        "timebaseAudioProgressMaximumGapSeconds": (
            TIMEBASE_AUDIO_PROGRESS_MAXIMUM_GAP_SECONDS
        ),
        "timebaseAudioMaximumLostBufferRatio": (
            TIMEBASE_AUDIO_MAXIMUM_LOST_BUFFER_RATIO
        ),
    },
    "adaptivePlaybackOracle": {
        "maximumProgressWindowSeconds": ADAPTIVE_PROGRESS_WINDOW_SECONDS,
        "minimumVisualMotionScore": ADAPTIVE_VISUAL_MOTION_MINIMUM_SCORE,
        "requiredModes": sorted(ADAPTIVE_MODES),
        "memorySampleKeys": sorted(ADAPTIVE_MEMORY_SAMPLE_KEYS),
        "progressWindowKeys": sorted(ADAPTIVE_PROGRESS_WINDOW_KEYS),
    },
    "cadenceOracle": {
        "windowSeconds": CADENCE_WINDOW_SECONDS,
        "rateToleranceFraction": CADENCE_RATE_TOLERANCE_FRACTION,
        "rateToleranceSemantics": "abs(observed-applied)/applied",
        "minimumVisualMotionScore": CADENCE_VISUAL_MOTION_MINIMUM_SCORE,
        "cfrSourceRates": CADENCE_CFR_SOURCE_RATES,
        "vfrRegimesFPS": [24.0, 60.0],
        "sampleRequiredKeys": sorted(CADENCE_SAMPLE_REQUIRED_KEYS),
        "sampleOptionalKeys": sorted(CADENCE_SAMPLE_OPTIONAL_KEYS),
        "oracleWindowKeys": sorted(CADENCE_ORACLE_WINDOW_KEYS),
        "sourceIntervalCountKeys": sorted(CADENCE_INTERVAL_COUNT_KEYS),
        "legacyTimestampProvenance": CADENCE_SOURCE_TIMESTAMP_PROVENANCE,
        "vmemOutputTimestampProvenance": (CADENCE_VMEM_OUTPUT_TIMESTAMP_PROVENANCE),
        "timestampSemantics": (
            "post-filter, vout-selected vmem output-attempt PTS; not lossless "
            "decoded-source cadence"
        ),
        "minimumSubmissionFraction": CADENCE_MINIMUM_SUBMISSION_FRACTION,
        "vfrMinimumRegimeSourceFrameFraction": (
            CADENCE_VFR_MINIMUM_REGIME_SOURCE_FRAME_FRACTION
        ),
        "vfrFixtureTimeline": [
            {"durationSeconds": CADENCE_VFR_REGIME_SECONDS, "framesPerSecond": 24},
            {"durationSeconds": CADENCE_VFR_REGIME_SECONDS, "framesPerSecond": 60},
        ],
        "vfrFixtureOriginSeconds": 0,
        "vfrFixtureBoundaryToleranceSeconds": 0.000002,
        "cfrSourceRateRationals": {
            profile: {"numerator": numerator, "denominator": denominator}
            for profile, (numerator, denominator) in sorted(
                CADENCE_CFR_SOURCE_RATE_RATIONALS.items()
            )
        },
        "vmemDeltaHistogramEntryKeys": sorted(CADENCE_VMEM_DELTA_HISTOGRAM_ENTRY_KEYS),
        "callbackConservation": (
            "callback=submitted+swiftRejected+inFlight; stable window requires "
            "equal inFlight boundaries"
        ),
        "profileOrder": list(CADENCE_PROFILE_ORDER),
        "presentationMetricRequiredKeys": sorted(
            CADENCE_PRESENTATION_METRIC_REQUIRED_KEYS
        ),
        "presentationMetricOptionalKeys": sorted(
            CADENCE_PRESENTATION_METRIC_OPTIONAL_KEYS
        ),
        "transitionResultKeys": sorted(CADENCE_TRANSITION_RESULT_KEYS),
        "visualCaptureBindingKeys": sorted(CADENCE_VISUAL_CAPTURE_BINDING_KEYS),
        "visualCaptureFrameCount": 3,
        "visualCaptureBounds": (
            "windowStartSystemUptime < captureSystemUptimes < "
            "windowEndSystemUptime; compatibility elapsed values derive from "
            "startedSystemUptime"
        ),
        "minimumSpringboardResizeGestures": "max(4, deviceDurationSeconds//90)",
    },
    "performanceResourceBudgets": PERFORMANCE_RESOURCE_BUDGETS,
    "nativeRendererRecoveryOracle": {
        "scenario": "playback-foreground-displaylayer-recovery",
        "renderingPath": "native",
        "trigger": "real-os-home-background-foreground-v1",
        "syntheticNotificationsPosted": False,
        "snapshotKeys": sorted(NATIVE_RENDERER_RECOVERY_SNAPSHOT_KEYS),
        "counterKeys": sorted(NATIVE_RENDERER_RECOVERY_COUNTER_KEYS),
        "checkKeys": sorted(NATIVE_RENDERER_RECOVERY_CHECK_KEYS),
        "visualBindingKeys": sorted(NATIVE_RENDERER_RECOVERY_VISUAL_BINDING_KEYS),
        "visualKeys": sorted(NATIVE_RENDERER_RECOVERY_VISUAL_KEYS),
        "visualMethod": VISUAL_OBSERVATION_METHOD,
        "minimumVisualMotionScore": CADENCE_VISUAL_MOTION_MINIMUM_SCORE,
    },
    "performanceVisualMaximumGapSeconds": (PERFORMANCE_VISUAL_MAXIMUM_GAP_SECONDS),
    "visualObservationPolicy": {
        "method": VISUAL_OBSERVATION_METHOD,
        "width": 64,
        "height": 36,
        "channels": "row-major-srgb-rgb8-no-alpha",
        "hashPrefix": "swiftvlc-rgb8-64x36-v1\\0+uint16be-width-height",
        "digest": "sha256-lowercase",
        "changedChannelDelta": 12,
        "ratioDenominatorPixels": 2304,
        "minimumFrames": 3,
        "scoreReducer": "minimum-adjacent-changed-pixel-ratio",
    },
    "timebaseRawPolicy": "exact-nested-av-progress-and-generation-v2",
    "requiredFeatureIDs": sorted(REQUIRED_FEATURE_IDS),
    "requiredReleaseRunnerScenarioOrder": list(
        REQUIRED_RELEASE_RUNNER_SCENARIO_ORDER
    ),
    "requiredReleaseRunnerScenarios": sorted(REQUIRED_RELEASE_RUNNER_SCENARIOS),
    "iphoneCurrentOnlyRunnerScenarios": sorted(IPHONE_CURRENT_ONLY_RUNNER_SCENARIOS),
    "requiredHardware": {
        identifier: {"deviceFamily": family, "osMajor": os_major}
        for identifier, (family, os_major) in sorted(REQUIRED_HARDWARE.items())
    },
    "canonicalRequiredRows": sorted(CANONICAL_REQUIRED_ROWS),
    "canonicalRequiredRunnerRuns": sorted(CANONICAL_REQUIRED_RUNNER_RUNS),
    "releaseCatalogExceptions": sorted(RELEASE_CATALOG_EXCEPTIONS),
    "deviceReportPolicy": {
        "deviceSnapshotBinding": "exact-sibling-normalized-device-sha256-v1",
        "deviceSnapshotRelativePath": DEVICE_SNAPSHOT_RELATIVE_PATH,
        "deviceSnapshotFields": sorted(DEVICE_SNAPSHOT_FIELDS),
        "normalizedSelectedDeviceFields": sorted(NORMALIZED_DEVICE_FIELDS),
        "runnerCatalogAuthority": "matrix-applicable-outputs",
        "reportResultAuthority": "exact-runner-result-reconciliation",
        "failedOutputRunnerEvidence": "retained-without-qualification-row",
        "exploratoryQualificationRows": "forbidden",
        "exploratoryEvidencePath": "evidence/{scenario}-{evidenceHardware}.json",
        "futureIOSHardwareEvidenceID": EXPLORATORY_FUTURE_IOS_HARDWARE_ID,
        "qualificationRowDeviceBindingFields": [
            "device",
            "deviceFamily",
            "productType",
            "osVersion",
            "osBuild",
            "osReleaseType",
        ],
    },
    "reportOnlyCadenceSemanticsPolicy": {
        "scenario": CADENCE_SEMANTICS_PROBE_SCENARIO,
        "testIdentifier": CADENCE_SEMANTICS_PROBE_TEST_IDENTIFIER,
        "attachmentName": CADENCE_SEMANTICS_PROBE_ATTACHMENT_NAME,
        "expectedWindows": [list(item) for item in CADENCE_SEMANTICS_PROBE_EXPECTED_WINDOWS],
        "springBoardRecordKeys": sorted(
            CADENCE_SEMANTICS_PROBE_SPRINGBOARD_RECORD_KEYS
        ),
        "captureBoundaryGuardSeconds": (
            CADENCE_SEMANTICS_PROBE_CAPTURE_BOUNDARY_GUARD_SECONDS
        ),
        "captureIntervalBinding": "entire-screenshot-inside-native-window-v1",
        "releaseCreditEligible": False,
        "artifactAssociation": "final-attempt-xcresult-copy-and-attachment-v1",
        "semanticValidation": "native-pts-rate-conservation-libvlc-springboard-v2",
    },
    "canonicalScenarioContractDigest": CANONICAL_SCENARIO_CONTRACT_DIGEST,
    "canonicalRunnerContractDigest": CANONICAL_RUNNER_CONTRACT_DIGEST,
    "releaseMatrixPolicyIdentity": RELEASE_MATRIX_POLICY_IDENTITY,
    "seekFrameOracleContract": SEEK_FRAME_ORACLE_CONTRACT,
    "localPlaybackFixtureContract": LOCAL_PLAYBACK_FIXTURE_CONTRACT,
    "localPlaybackEvidencePolicy": {
        "rawEvidenceKeys": sorted(LOCAL_PLAYBACK_RAW_EVIDENCE_KEYS),
        "resultKeys": sorted(LOCAL_PLAYBACK_RESULT_KEYS),
        "counterKeys": sorted(LOCAL_PLAYBACK_COUNTER_KEYS),
        "visualKeys": sorted(LOCAL_PLAYBACK_VISUAL_KEYS),
        "minimumClockAdvanceMilliseconds": 2000,
        "minimumDisplayedPictureAdvance": 10,
        "minimumPlayedAudioBufferAdvance": 5,
        "minimumVisualMotionScore": 0.01,
    },
    "progressiveHTTPRangeSeekPolicy": {
        "fixtureContract": PROGRESSIVE_HTTP_RANGE_FIXTURE_CONTRACT,
        "rawEvidenceKeys": sorted(PROGRESSIVE_HTTP_RANGE_RAW_EVIDENCE_KEYS),
        "counterKeys": sorted(PROGRESSIVE_HTTP_RANGE_COUNTER_KEYS),
        "rangeResultKeys": sorted(PROGRESSIVE_HTTP_RANGE_SUCCESS_KEYS),
        "noRangeResultKeys": sorted(PROGRESSIVE_HTTP_NO_RANGE_SUCCESS_KEYS),
        "rangeVisualKeys": sorted(PROGRESSIVE_HTTP_RANGE_VISUAL_KEYS),
        "noRangeVisualKeys": sorted(PROGRESSIVE_HTTP_VISUAL_BASE_KEYS),
        "transcriptBindingKeys": sorted(PROGRESSIVE_HTTP_TRANSCRIPT_BINDING_KEYS),
        "mediaEventKeys": sorted(PROGRESSIVE_HTTP_MEDIA_EVENT_KEYS),
        "commandEventKeys": sorted(PROGRESSIVE_HTTP_COMMAND_EVENT_KEYS),
        "maximumPrecommandTransferredBytes": (
            PROGRESSIVE_HTTP_MAXIMUM_PRECOMMAND_BYTES
        ),
        "minimumSeekRangeStart": PROGRESSIVE_HTTP_MINIMUM_SEEK_RANGE_START,
        "maximumCaptureIntervalSeconds": (
            PROGRESSIVE_HTTP_MAXIMUM_CAPTURE_INTERVAL_SECONDS
        ),
        "commandMarkerOrigin": PROGRESSIVE_HTTP_COMMAND_ORIGIN,
        "noRangeBehavior": {
            "seekable": False,
            "errorDomain": "SwiftVLC.VLCError",
            "errorCase": "invalidState",
            "message": "current media is not seekable",
            "commandDispatched": False,
            "continuedPlaybackRequired": True,
        },
        "networkAuthority": "retained-server-transcript-only-v1",
    },
    "requiredCandidateBindings": [
        "candidateBuildAttestation",
        "candidateBuildAttestationDigest",
        "testCatalogAuthorityDigest",
        "candidateAppBundleIdentifier",
        "candidateAppDigest",
        "testRunnerBundleIdentifier",
        "testRunnerDigest",
        "testBundleDigest",
        "baseXCTestRunDigest",
        "testCatalogDigest",
        "qualificationMatrixChecksum",
        "featureManifestChecksum",
        "qualificationProfilesChecksum",
        "fixtureManifestChecksum",
    ],
    "xctestExecutionPolicy": "exact-selected-leaf-set-and-global-diagnostics-v2",
    "runnerContractPolicy": "matrix-owned-runner-output-catalog-v1",
    "xcresultAttachmentPolicy": ("final-attempt-owner-emission-set-reconciliation-v3"),
    "aggregateRunnerCoveragePolicy": "release-profile-per-hardware-v1",
    "retryPolicy": "retained-structured-no-test-began-v3",
    "expectedErrorPolicy": "retained-raw-bidirectional-reconciliation-v3",
    "attemptArtifactPolicy": "exact-scoped-bidirectional-history-v2",
    "deviceLogPolicy": "exact-xctest-family-and-health-v2",
    "rawProductFailurePolicy": "no-unreviewed-exceptions-v1",
}


def canonical_json_bytes(value: object) -> bytes:
    try:
        return json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    except (
        TypeError,
        ValueError,
        UnicodeError,
        OverflowError,
        RecursionError,
    ) as error:
        raise QualificationPolicyError(f"cannot canonicalize JSON: {error}") from error


def policy_digest() -> str:
    return hashlib.sha256(
        b"SwiftVLC qualification policy v1\0"
        + canonical_json_bytes(QUALIFICATION_POLICY_DOCUMENT)
    ).hexdigest()


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise QualificationPolicyError(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def _reject_non_finite_json_constant(value: str) -> object:
    raise QualificationPolicyError(f"non-finite JSON number {value!r}")


def _validate_finite_json_tree(value: object, path: str = "$") -> None:
    if isinstance(value, float) and not math.isfinite(value):
        raise QualificationPolicyError(f"non-finite JSON number at {path}")
    if isinstance(value, str):
        try:
            value.encode("utf-8")
        except UnicodeError as error:
            raise QualificationPolicyError(
                f"invalid Unicode string at {path}: {error}"
            ) from error
        return
    if isinstance(value, list):
        for index, item in enumerate(value):
            _validate_finite_json_tree(item, f"{path}[{index}]")
        return
    if isinstance(value, dict):
        for key, item in value.items():
            _validate_finite_json_tree(key, f"{path} object key")
            _validate_finite_json_tree(item, f"{path}[{key!r}]")


def loads_json(text: str, description: str = "JSON") -> object:
    try:
        value = json.loads(
            text,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_non_finite_json_constant,
        )
        _validate_finite_json_tree(value)
        return value
    except (
        TypeError,
        ValueError,
        UnicodeError,
        OverflowError,
        RecursionError,
    ) as error:
        raise QualificationPolicyError(f"cannot read {description}: {error}") from error


def load_json(path: Path, description: str, *, object_required: bool = True):
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise QualificationPolicyError(
            f"cannot read {description} {path}: {error}"
        ) from error
    value = loads_json(text, f"{description} {path}")
    if object_required and not isinstance(value, dict):
        raise QualificationPolicyError(f"{description} {path} must be a JSON object")
    return value


def _canonical_utc_timestamp(value: object, description: str) -> datetime:
    if not isinstance(value, str):
        raise QualificationPolicyError(f"{description} is not a UTC timestamp")
    try:
        parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError as error:
        raise QualificationPolicyError(
            f"{description} must use canonical YYYY-MM-DDTHH:MM:SSZ form"
        ) from error
    if parsed.strftime("%Y-%m-%dT%H:%M:%SZ") != value:
        raise QualificationPolicyError(
            f"{description} must use canonical YYYY-MM-DDTHH:MM:SSZ form"
        )
    return parsed


def validate_report_timing(
    report: dict,
    *,
    stable: bool,
    now_utc: datetime | None = None,
) -> None:
    started = _canonical_utc_timestamp(
        report.get("startedAtUTC"), "device report startedAtUTC"
    )
    completed = _canonical_utc_timestamp(
        report.get("completedAtUTC"), "device report completedAtUTC"
    )
    duration = report.get("wallDurationSeconds")
    if isinstance(duration, bool) or not isinstance(duration, int) or duration < 0:
        raise QualificationPolicyError(
            "device report wallDurationSeconds must be a non-negative integer"
        )
    if completed < started:
        raise QualificationPolicyError("device report completed before it started")
    if int((completed - started).total_seconds()) != duration:
        raise QualificationPolicyError(
            "device report wallDurationSeconds does not match its UTC interval"
        )
    now = now_utc or datetime.now(timezone.utc)
    if now.tzinfo is None:
        raise QualificationPolicyError("freshness reference time must be timezone-aware")
    now = now.astimezone(timezone.utc)
    age_seconds = (now - completed).total_seconds()
    if age_seconds < -MAXIMUM_REPORT_CLOCK_SKEW_SECONDS:
        raise QualificationPolicyError("device report completion time is in the future")
    if stable and age_seconds > MAXIMUM_STABLE_REPORT_AGE_SECONDS:
        raise QualificationPolicyError(
            "stable device report is stale: "
            f"{int(age_seconds)} seconds old, maximum "
            f"{MAXIMUM_STABLE_REPORT_AGE_SECONDS}"
        )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        raise QualificationPolicyError(f"cannot checksum {path}: {error}") from error
    return digest.hexdigest()


def tree_digest(root: Path) -> str:
    """The same path/mode/content digest used for signed candidate trees."""

    if not root.is_dir():
        raise QualificationPolicyError(f"tree is missing: {root}")
    digest = hashlib.sha256(b"SwiftVLC artifact tree digest v1\0")
    entries = sorted(
        root.rglob("*"), key=lambda path: path.relative_to(root).as_posix()
    )
    if not entries:
        raise QualificationPolicyError(f"tree is empty: {root}")

    def update(value: bytes) -> None:
        digest.update(len(value).to_bytes(8, "big"))
        digest.update(value)

    for path in entries:
        metadata = path.lstat()
        if stat.S_ISDIR(metadata.st_mode):
            kind, payload = b"directory", b""
        elif stat.S_ISREG(metadata.st_mode):
            kind, payload = b"file", bytes.fromhex(sha256_file(path))
        elif stat.S_ISLNK(metadata.st_mode):
            kind, payload = b"symlink", os.readlink(path).encode()
        else:
            raise QualificationPolicyError(f"unsupported tree entry: {path}")
        update(kind)
        update(path.relative_to(root).as_posix().encode())
        update(stat.S_IMODE(metadata.st_mode).to_bytes(4, "big"))
        update(payload)
    return digest.hexdigest()


def tree_size_bytes(root: Path) -> int:
    """Return the byte size of the regular files bound by ``tree_digest``."""

    if not root.is_dir():
        raise QualificationPolicyError(f"tree is missing: {root}")
    total = 0
    for path in root.rglob("*"):
        metadata = path.lstat()
        if stat.S_ISREG(metadata.st_mode):
            total += metadata.st_size
        elif not (stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode)):
            raise QualificationPolicyError(f"unsupported tree entry: {path}")
    return total


def tree_entry_count(root: Path) -> int:
    if not root.is_dir():
        raise QualificationPolicyError(f"tree is missing: {root}")
    entries = list(root.rglob("*"))
    if not entries:
        raise QualificationPolicyError(f"tree is empty: {root}")
    return len(entries)


def reject_tree_symlinks(root: Path, description: str) -> None:
    for path in root.rglob("*"):
        if stat.S_ISLNK(path.lstat().st_mode):
            raise QualificationPolicyError(
                f"{description} contains a symlink outside its regular tree model: {path}"
            )


def _safe_relative_artifact(
    root: Path, relative: object, description: str, *, directory: bool
) -> Path:
    """Resolve a retained artifact without accepting symlink/type confusion."""

    if not isinstance(relative, str) or not relative:
        raise QualificationPolicyError(f"{description} has no path")
    candidate = Path(relative)
    if candidate.is_absolute() or ".." in candidate.parts:
        raise QualificationPolicyError(f"{description} has unsafe path {relative!r}")
    try:
        root_metadata = root.lstat()
    except OSError as error:
        raise QualificationPolicyError(
            f"{description} root is missing: {root}"
        ) from error
    if not stat.S_ISDIR(root_metadata.st_mode) or stat.S_ISLNK(root_metadata.st_mode):
        raise QualificationPolicyError(f"{description} root is not a real directory")
    current = root
    for part in candidate.parts:
        current = current / part
        try:
            metadata = current.lstat()
        except OSError as error:
            raise QualificationPolicyError(
                f"{description} is missing: {relative}"
            ) from error
        if stat.S_ISLNK(metadata.st_mode):
            raise QualificationPolicyError(f"{description} may not be a symlink")
    root_resolved = root.resolve()
    resolved = current.resolve()
    try:
        resolved.relative_to(root_resolved)
    except ValueError as error:
        raise QualificationPolicyError(f"{description} escapes {root}") from error
    metadata = resolved.lstat()
    valid = (
        stat.S_ISDIR(metadata.st_mode) if directory else stat.S_ISREG(metadata.st_mode)
    )
    if not valid:
        kind = "directory" if directory else "regular file"
        raise QualificationPolicyError(f"{description} is not a {kind}")
    return resolved


def safe_relative_directory(root: Path, relative: object, description: str) -> Path:
    return _safe_relative_artifact(root, relative, description, directory=True)


def safe_relative_file(root: Path, relative: object, description: str) -> Path:
    return _safe_relative_artifact(root, relative, description, directory=False)


def _json_same(actual: object, expected: object) -> bool:
    # JSON booleans and numbers are different types even though bool subclasses
    # int in Python.
    if isinstance(expected, bool):
        return isinstance(actual, bool) and actual == expected
    if isinstance(expected, (int, float)):
        return (
            isinstance(actual, (int, float))
            and not isinstance(actual, bool)
            and actual == expected
        )
    if expected is None:
        return actual is None
    if isinstance(expected, str):
        return isinstance(actual, str) and actual == expected
    if isinstance(expected, list):
        return (
            isinstance(actual, list)
            and len(actual) == len(expected)
            and all(_json_same(a, e) for a, e in zip(actual, expected))
        )
    if isinstance(expected, dict):
        return (
            isinstance(actual, dict)
            and actual.keys() == expected.keys()
            and all(_json_same(actual[key], expected[key]) for key in expected)
        )
    return type(actual) is type(expected) and actual == expected


def validate_normalized_selected_device(device: object) -> dict:
    """Validate the exact selected-device shape emitted by ``device-info.py``.

    This is an internal-consistency check for the retained host snapshot. It is
    deliberately not described as independent hardware attestation: an actor
    able to replace the complete evidence tree can replace this JSON too.
    """

    if not isinstance(device, dict):
        raise QualificationPolicyError(
            "retained device snapshot has no normalized selected device"
        )
    actual_fields = set(device)
    if actual_fields != NORMALIZED_DEVICE_FIELDS:
        missing = sorted(NORMALIZED_DEVICE_FIELDS - actual_fields)
        extra = sorted(actual_fields - NORMALIZED_DEVICE_FIELDS)
        raise QualificationPolicyError(
            "retained selected device fields are not canonical: "
            f"missing={missing!r}, extra={extra!r}"
        )

    for field in (
        "id",
        "udid",
        "name",
        "marketingName",
        "deviceFamily",
        "productType",
        "osVersion",
        "osBuild",
    ):
        if not isinstance(device.get(field), str) or not device[field]:
            raise QualificationPolicyError(
                f"retained selected device has invalid {field}"
            )
    for field in ("transport", "tunnelIPAddress"):
        value = device.get(field)
        if value is not None and (not isinstance(value, str) or not value):
            raise QualificationPolicyError(
                f"retained selected device has invalid {field}"
            )

    family = device["deviceFamily"]
    if family not in {"iPhone", "iPad"}:
        raise QualificationPolicyError(
            "retained selected device is not an iPhone or iPad"
        )
    release_type = device.get("osReleaseType")
    if release_type not in {"stable", "beta", "unknown"}:
        raise QualificationPolicyError(
            "retained selected device has invalid OS release type"
        )
    os_major = device.get("osMajor")
    try:
        version_major = int(str(device["osVersion"]).split(".", 1)[0])
    except ValueError as error:
        raise QualificationPolicyError(
            "retained selected device has invalid OS version"
        ) from error
    if (
        isinstance(os_major, bool)
        or not isinstance(os_major, int)
        or os_major <= 0
        or os_major != version_major
    ):
        raise QualificationPolicyError(
            "retained selected device OS major contradicts its OS version"
        )

    ecid = device.get("ecid")
    ecid_hex = device.get("ecidHex")
    if ecid is None:
        if ecid_hex is not None:
            raise QualificationPolicyError(
                "retained selected device ECID fields disagree"
            )
    elif (
        isinstance(ecid, bool)
        or not isinstance(ecid, int)
        or ecid < 0
        or ecid_hex != f"0x{ecid:X}"
    ):
        raise QualificationPolicyError(
            "retained selected device ECID fields disagree"
        )

    matching = device.get("matchingHardwareRows")
    if (
        not isinstance(matching, list)
        or any(not isinstance(item, str) or not item for item in matching)
        or len(set(matching)) != len(matching)
    ):
        raise QualificationPolicyError(
            "retained selected device has invalid matching hardware rows"
        )
    if device.get("connected") is not True:
        raise QualificationPolicyError(
            "retained selected device is not connected"
        )
    eligible = device.get("qualificationEligible")
    expected_eligible = release_type == "stable" and bool(matching)
    if not isinstance(eligible, bool) or eligible != expected_eligible:
        raise QualificationPolicyError(
            "retained selected device eligibility is inconsistent"
        )
    return device


def _load_device_snapshot(report_root: Path) -> tuple[bytes, dict]:
    snapshot_path = safe_relative_file(
        report_root,
        DEVICE_SNAPSHOT_RELATIVE_PATH,
        "retained device snapshot",
    )
    try:
        raw_snapshot = snapshot_path.read_bytes()
        snapshot = loads_json(
            raw_snapshot.decode("utf-8"),
            f"retained device snapshot {snapshot_path}",
        )
    except (OSError, UnicodeError) as error:
        raise QualificationPolicyError(
            f"cannot read retained device snapshot {snapshot_path}: {error}"
        ) from error
    if not isinstance(snapshot, dict):
        raise QualificationPolicyError(
            f"retained device snapshot {snapshot_path} must be a JSON object"
        )
    actual_fields = set(snapshot)
    if actual_fields != DEVICE_SNAPSHOT_FIELDS:
        missing = sorted(DEVICE_SNAPSHOT_FIELDS - actual_fields)
        extra = sorted(actual_fields - DEVICE_SNAPSHOT_FIELDS)
        raise QualificationPolicyError(
            "retained device snapshot fields are not canonical: "
            f"missing={missing!r}, extra={extra!r}"
        )
    selected = validate_normalized_selected_device(snapshot.get("selected"))
    connected = snapshot.get("connected")
    all_devices = snapshot.get("allPhysicalIOSDevices")
    for value, description in (
        (connected, "connected devices"),
        (all_devices, "physical iOS devices"),
    ):
        if not isinstance(value, list) or any(
            not isinstance(item, dict) for item in value
        ):
            raise QualificationPolicyError(
                f"retained device snapshot has invalid {description}"
            )
        if sum(_json_same(item, selected) for item in value) != 1:
            raise QualificationPolicyError(
                f"retained device snapshot selected device is not unique in {description}"
            )
    assert isinstance(connected, list)
    assert isinstance(all_devices, list)
    for item in connected:
        if item.get("connected") is not True or not any(
            _json_same(item, candidate) for candidate in all_devices
        ):
            raise QualificationPolicyError(
                "retained connected-device inventory contradicts the physical inventory"
            )
    expected_mode = (
        "qualification" if selected["qualificationEligible"] else "exploratory"
    )
    if snapshot.get("mode") != expected_mode:
        raise QualificationPolicyError(
            "retained device snapshot mode contradicts its selected device"
        )
    return raw_snapshot, snapshot


def device_snapshot_binding(report_root: Path) -> dict:
    """Return the canonical binding for the sibling normalized device snapshot."""

    raw_snapshot, _ = _load_device_snapshot(report_root)
    return {
        "relativePath": DEVICE_SNAPSHOT_RELATIVE_PATH,
        "digestAlgorithm": "sha256",
        "digest": hashlib.sha256(raw_snapshot).hexdigest(),
        "sizeBytes": len(raw_snapshot),
    }


def validate_report_device_snapshot(report_path: Path, report: dict) -> dict:
    """Bind a strict report to its exact sibling ``device.json`` snapshot."""

    binding = report.get("deviceSnapshot")
    if not isinstance(binding, dict) or set(binding) != DEVICE_SNAPSHOT_BINDING_FIELDS:
        raise QualificationPolicyError(
            "device report has no canonical device snapshot binding"
        )
    raw_snapshot, snapshot = _load_device_snapshot(report_path.parent)
    expected_binding = {
        "relativePath": DEVICE_SNAPSHOT_RELATIVE_PATH,
        "digestAlgorithm": "sha256",
        "digest": hashlib.sha256(raw_snapshot).hexdigest(),
        "sizeBytes": len(raw_snapshot),
    }
    if not _json_same(binding, expected_binding):
        raise QualificationPolicyError(
            "device report retained device snapshot binding mismatch"
        )
    if snapshot.get("mode") != report.get("mode"):
        raise QualificationPolicyError(
            "device report mode differs from retained device snapshot"
        )
    if not _json_same(snapshot.get("selected"), report.get("device")):
        raise QualificationPolicyError(
            "device report device differs from retained selected device"
        )
    report_eligible = report.get("qualificationEligibleEnvironment")
    selected_eligible = snapshot["selected"]["qualificationEligible"]
    if (
        not isinstance(report_eligible, bool)
        or report_eligible is not selected_eligible
        or (report.get("mode") == "qualification") is not report_eligible
    ):
        raise QualificationPolicyError(
            "device report mode/eligibility differs from retained selected device"
        )
    return snapshot


_MISSING = object()


def nested_value(document: object, dotted_path: str) -> object:
    value = document
    for component in dotted_path.split("."):
        if not isinstance(value, dict) or component not in value:
            return _MISSING
        value = value[component]
    return value


def validate_matrix(matrix: dict) -> tuple[dict[str, dict], dict[str, dict]]:
    scenarios = matrix.get("scenarios")
    hardware = matrix.get("hardware")
    if not isinstance(scenarios, list) or not scenarios:
        raise QualificationPolicyError("qualification matrix needs scenarios")
    if not isinstance(hardware, list) or not hardware:
        raise QualificationPolicyError("qualification matrix needs hardware")

    hardware_by_id: dict[str, dict] = {}
    for index, row in enumerate(hardware):
        if not isinstance(row, dict) or not ID.fullmatch(str(row.get("id", ""))):
            raise QualificationPolicyError(f"hardware row {index} has an invalid id")
        identifier = row["id"]
        if identifier in hardware_by_id:
            raise QualificationPolicyError(f"duplicate hardware id {identifier!r}")
        if not isinstance(row.get("deviceFamily"), str) or not row["deviceFamily"]:
            raise QualificationPolicyError(f"hardware {identifier} has no deviceFamily")
        if isinstance(row.get("osMajor"), bool) or not isinstance(
            row.get("osMajor"), int
        ):
            raise QualificationPolicyError(
                f"hardware {identifier} has no integer osMajor"
            )
        hardware_by_id[identifier] = row

    scenario_by_id: dict[str, dict] = {}
    for index, scenario in enumerate(scenarios):
        if not isinstance(scenario, dict) or not ID.fullmatch(
            str(scenario.get("id", ""))
        ):
            raise QualificationPolicyError(f"scenario {index} has an invalid id")
        identifier = scenario["id"]
        if identifier in scenario_by_id:
            raise QualificationPolicyError(f"duplicate scenario id {identifier!r}")
        selected = scenario.get("hardware", list(hardware_by_id))
        if (
            not isinstance(selected, list)
            or not selected
            or any(not isinstance(item, str) for item in selected)
            or len(set(selected)) != len(selected)
        ):
            raise QualificationPolicyError(
                f"scenario {identifier} has an invalid hardware list"
            )
        unknown = sorted(set(selected) - set(hardware_by_id))
        if unknown:
            raise QualificationPolicyError(
                f"scenario {identifier} names unknown hardware: {', '.join(unknown)}"
            )
        required = scenario.get("requiredEvidenceFields", [])
        expected = scenario.get("expectedEvidenceValues", {})
        allowed = scenario.get("allowedEvidenceValues", {})
        if (
            not isinstance(required, list)
            or any(not isinstance(field, str) or not field for field in required)
            or len(set(required)) != len(required)
        ):
            raise QualificationPolicyError(
                f"scenario {identifier} has invalid requiredEvidenceFields"
            )
        if not isinstance(expected, dict) or any(
            not isinstance(field, str) or not field for field in expected
        ):
            raise QualificationPolicyError(
                f"scenario {identifier} has invalid expectedEvidenceValues"
            )
        if not isinstance(allowed, dict) or any(
            not isinstance(field, str)
            or not field
            or not isinstance(values, list)
            or not values
            for field, values in allowed.items()
        ):
            raise QualificationPolicyError(
                f"scenario {identifier} has invalid allowedEvidenceValues"
            )
        canonical_minimum = STABLE_MINIMUM_DURATION_SECONDS.get(identifier)
        if (
            canonical_minimum is not None
            and scenario.get("minimumDurationSeconds") != canonical_minimum
        ):
            raise QualificationPolicyError(
                f"scenario {identifier} minimumDurationSeconds is immutable at "
                f"{canonical_minimum}"
            )
        scenario_by_id[identifier] = scenario
    return scenario_by_id, hardware_by_id


def required_rows(matrix: dict) -> set[tuple[str, str]]:
    scenarios, hardware = validate_matrix(matrix)
    return {
        (scenario_id, hardware_id)
        for scenario_id, scenario in scenarios.items()
        for hardware_id in scenario.get("hardware", list(hardware))
    }


def report_hardware_context(
    report: dict, hardware: Mapping[str, dict]
) -> tuple[set[str], str]:
    """Return matrix applicability and the hardware id embedded in evidence.

    A beta build on a known OS row uses that row's id in its diagnostic
    evidence. A future iPhone has no matching row, so it is projected onto the
    latest same-family matrix row solely to select tests while retaining a
    sentinel evidence id that can never be mistaken for release credit.
    """

    mode = report.get("mode")
    eligible = report.get("qualificationEligibleEnvironment")
    if mode not in {"qualification", "exploratory"}:
        raise QualificationPolicyError("device report mode is invalid")
    if mode == "qualification" and eligible is not True:
        raise QualificationPolicyError("qualification mode report is not eligible")
    if mode == "exploratory" and eligible is not False:
        raise QualificationPolicyError(
            "exploratory mode report must be qualification-ineligible"
        )

    device = report.get("device")
    if not isinstance(device, dict):
        raise QualificationPolicyError("device report has no device object")
    if device.get("qualificationEligible") is not eligible:
        raise QualificationPolicyError(
            "device report eligibility contradicts its selected device"
        )
    if mode == "qualification" and device.get("osReleaseType") != "stable":
        raise QualificationPolicyError(
            "qualification mode report is not from a stable OS"
        )
    matching = device.get("matchingHardwareRows")
    if (
        not isinstance(matching, list)
        or any(not isinstance(item, str) or item not in hardware for item in matching)
        or len(set(matching)) != len(matching)
    ):
        raise QualificationPolicyError(
            "device report has invalid matchingHardwareRows"
        )
    if len(matching) > 1:
        raise QualificationPolicyError(
            "device report matches more than one qualification hardware row"
        )

    family = device.get("deviceFamily")
    os_major = device.get("osMajor")
    if (
        not isinstance(family, str)
        or not family
        or isinstance(os_major, bool)
        or not isinstance(os_major, int)
        or os_major <= 0
    ):
        raise QualificationPolicyError(
            "device report has invalid family or OS-major identity"
        )

    if matching:
        hardware_id = matching[0]
        row = hardware[hardware_id]
        if row.get("deviceFamily") != family or row.get("osMajor") != os_major:
            raise QualificationPolicyError(
                "device report matching hardware row contradicts device identity"
            )
        return {hardware_id}, hardware_id

    if mode != "exploratory" or family != "iPhone":
        raise QualificationPolicyError(
            "device report has no applicable qualification hardware row"
        )
    family_rows = [
        (hardware_id, row)
        for hardware_id, row in hardware.items()
        if row.get("deviceFamily") == family
    ]
    if not family_rows:
        raise QualificationPolicyError(
            "future iPhone report has no same-family qualification row"
        )
    latest_major = max(row["osMajor"] for _, row in family_rows)
    latest_rows = [
        hardware_id
        for hardware_id, row in family_rows
        if row["osMajor"] == latest_major
    ]
    if os_major <= latest_major or len(latest_rows) != 1:
        raise QualificationPolicyError(
            "exploratory iPhone is not an unambiguous future-OS projection"
        )
    return {latest_rows[0]}, EXPLORATORY_FUTURE_IOS_HARDWARE_ID


def applicable_runner_outputs(
    contract: dict,
    scenarios: Mapping[str, dict],
    effective_hardware: set[str],
) -> set[str]:
    """Return output ids selected by a runner for one device context."""

    selected: set[str] = set()
    for output in contract.get("outputs", []):
        scenario_id = output["scenario"]
        scenario_hardware = set(scenarios[scenario_id].get("hardware", []))
        if not scenario_hardware or scenario_hardware.intersection(effective_hardware):
            selected.add(scenario_id)
    return selected


def validate_release_matrix_contract(matrix: dict) -> None:
    """Reject a matrix that weakens the immutable release qualification map."""

    if matrix.get("releasePolicyIdentity") != RELEASE_MATRIX_POLICY_IDENTITY:
        raise QualificationPolicyError(
            "qualification matrix has no immutable release-policy identity"
        )
    scenarios, hardware = validate_matrix(matrix)
    actual_hardware = {
        identifier: (row.get("deviceFamily"), row.get("osMajor"))
        for identifier, row in hardware.items()
    }
    if actual_hardware != REQUIRED_HARDWARE:
        raise QualificationPolicyError(
            "qualification hardware differs from immutable release policy"
        )
    actual_rows = required_rows(matrix)
    if actual_rows != CANONICAL_REQUIRED_ROWS:
        raise QualificationPolicyError(
            "qualification scenario/hardware rows differ from immutable release "
            f"policy; missing={sorted(CANONICAL_REQUIRED_ROWS - actual_rows)!r}, "
            f"extra={sorted(actual_rows - CANONICAL_REQUIRED_ROWS)!r}"
        )
    scenario_contracts = sorted(
        (
            {key: value for key, value in row.items() if key != "summary"}
            for row in matrix.get("scenarios", [])
        ),
        key=lambda row: row["id"],
    )
    if hashlib.sha256(canonical_json_bytes(scenario_contracts)).hexdigest() != (
        CANONICAL_SCENARIO_CONTRACT_DIGEST
    ):
        raise QualificationPolicyError(
            "qualification scenario evidence contracts differ from immutable policy"
        )
    runner_contracts = matrix.get("runnerContracts")
    if not isinstance(runner_contracts, list):
        raise QualificationPolicyError("qualification matrix has no runner contracts")
    canonical_runners = sorted(runner_contracts, key=lambda row: row.get("id", ""))
    if hashlib.sha256(canonical_json_bytes(canonical_runners)).hexdigest() != (
        CANONICAL_RUNNER_CONTRACT_DIGEST
    ):
        raise QualificationPolicyError(
            "qualification runner selection/output/owner contracts differ from "
            "immutable policy"
        )
    validate_runner_contracts(matrix, scenarios)
    for scenario_id in STABLE_MINIMUM_DURATION_SECONDS:
        producer = next(
            (
                (contract, output)
                for contract in runner_contracts
                for output in contract.get("outputs", [])
                if output.get("scenario") == scenario_id
            ),
            None,
        )
        if producer is None or producer[0].get("id") != scenario_id:
            raise QualificationPolicyError(
                f"endurance scenario {scenario_id!r} has no exact qualifying producer"
            )


def is_release_matrix(matrix: dict) -> bool:
    """Distinguish the production contract from deliberately tiny test fixtures."""

    if matrix.get("releasePolicyIdentity") == RELEASE_MATRIX_POLICY_IDENTITY:
        return True
    scenario_ids = {
        row.get("id") for row in matrix.get("scenarios", []) if isinstance(row, dict)
    }
    hardware_ids = {
        row.get("id") for row in matrix.get("hardware", []) if isinstance(row, dict)
    }
    # A release-shaped document cannot evade the policy merely by deleting the
    # marker. Small synthetic matrices remain useful to unit-test primitives.
    return (
        len(scenario_ids & {row[0] for row in CANONICAL_REQUIRED_ROWS}) >= 10
        or len(hardware_ids & set(REQUIRED_HARDWARE)) >= 3
    )


def validate_release_qualification_row_evidence_path(
    row: dict, index: int
) -> str:
    """Require the one release-evidence location owned by a scenario/hardware row."""

    expected = f"evidence/{row.get('scenario')}-{row.get('hardware')}.json"
    if row.get("evidence") != expected:
        raise QualificationPolicyError(
            f"release qualification row {index} evidence path must be {expected!r}"
        )
    return expected


def validate_runner_contracts(
    matrix: dict, scenario_by_id: dict[str, dict] | None = None
) -> tuple[dict[str, dict], dict[str, tuple[dict, dict]]]:
    """Validate the matrix-owned runner, XCTest, and attachment authority map."""

    scenarios = scenario_by_id
    if scenarios is None:
        scenarios, _ = validate_matrix(matrix)
    contracts = matrix.get("runnerContracts")
    if not isinstance(contracts, list) or not contracts:
        raise QualificationPolicyError(
            "qualification matrix has no runnerContracts authority map"
        )
    by_runner: dict[str, dict] = {}
    by_scenario: dict[str, tuple[dict, dict]] = {}
    for index, contract in enumerate(contracts):
        if not isinstance(contract, dict) or not ID.fullmatch(
            str(contract.get("id", ""))
        ):
            raise QualificationPolicyError(f"runner contract {index} has invalid id")
        runner_id = contract["id"]
        if runner_id in by_runner:
            raise QualificationPolicyError(f"duplicate runner contract {runner_id!r}")
        outputs = contract.get("outputs")
        if not isinstance(outputs, list):
            raise QualificationPolicyError(
                f"runner contract {runner_id} has no outputs array"
            )
        attachment_emission = contract.get("attachmentEmission", "selectedOutputs")
        if attachment_emission not in {"selectedOutputs", "allOutputs"}:
            raise QualificationPolicyError(
                f"runner contract {runner_id} has invalid attachmentEmission"
            )
        if attachment_emission == "allOutputs" and len(outputs) < 2:
            raise QualificationPolicyError(
                f"runner contract {runner_id} allOutputs emission requires "
                "multiple outputs"
            )
        selection = contract.get("selection")
        if selection is not None:
            if not isinstance(selection, dict):
                raise QualificationPolicyError(
                    f"runner contract {runner_id} selection is malformed"
                )
            kind = selection.get("kind")
            if kind == "fullCandidateCatalog":
                if set(selection) != {"kind"}:
                    raise QualificationPolicyError(
                        f"runner contract {runner_id} full-catalog selection has extra fields"
                    )
            elif kind == "candidatePrefix":
                prefix = selection.get("prefix")
                if (
                    set(selection) != {"kind", "prefix"}
                    or not isinstance(prefix, str)
                    or not prefix.startswith("iOSUITests/")
                    or not prefix.endswith("/")
                ):
                    raise QualificationPolicyError(
                        f"runner contract {runner_id} prefix selection is invalid"
                    )
            elif kind == "candidatePrefixes":
                prefixes = selection.get("prefixes")
                if (
                    set(selection) != {"kind", "prefixes"}
                    or not isinstance(prefixes, list)
                    or not prefixes
                    or len(set(prefixes)) != len(prefixes)
                    or any(
                        not isinstance(prefix, str)
                        or not prefix.startswith("iOSUITests/")
                        or not prefix.endswith("/")
                        for prefix in prefixes
                    )
                ):
                    raise QualificationPolicyError(
                        f"runner contract {runner_id} prefix selections are invalid"
                    )
            elif kind == "candidateExcludingPrefixes":
                prefixes = selection.get("prefixes")
                if (
                    set(selection) != {"kind", "prefixes"}
                    or not isinstance(prefixes, list)
                    or not prefixes
                    or len(set(prefixes)) != len(prefixes)
                    or any(
                        not isinstance(prefix, str)
                        or not prefix.startswith("iOSUITests/")
                        or not prefix.endswith("/")
                        for prefix in prefixes
                    )
                ):
                    raise QualificationPolicyError(
                        f"runner contract {runner_id} exclusion prefixes are invalid"
                    )
            elif kind == "exact":
                identifiers = selection.get("testIdentifiers")
                if (
                    set(selection) != {"kind", "testIdentifiers"}
                    or not isinstance(identifiers, list)
                    or normalize_catalog_identifiers(identifiers) != identifiers
                    or not identifiers
                ):
                    raise QualificationPolicyError(
                        f"runner contract {runner_id} exact selection is invalid"
                    )
            else:
                raise QualificationPolicyError(
                    f"runner contract {runner_id} has unsupported selection kind"
                )
        elif not outputs:
            raise QualificationPolicyError(
                f"runner contract {runner_id} has neither selection nor outputs"
            )
        attachment_names: set[str] = set()
        for output_index, output in enumerate(outputs):
            if not isinstance(output, dict) or set(output) != {
                "scenario",
                "attachmentName",
                "testIdentifiers",
            }:
                raise QualificationPolicyError(
                    f"runner contract {runner_id} output {output_index} is malformed"
                )
            scenario_id = output.get("scenario")
            if scenario_id not in scenarios:
                raise QualificationPolicyError(
                    f"runner contract {runner_id} names unknown output {scenario_id!r}"
                )
            if scenario_id in by_scenario:
                raise QualificationPolicyError(
                    f"qualification scenario {scenario_id!r} has multiple producers"
                )
            attachment = output.get("attachmentName")
            if (
                not isinstance(attachment, str)
                or Path(attachment).name != attachment
                or not attachment.startswith("qualification-")
                or not attachment.endswith(".json")
            ):
                raise QualificationPolicyError(
                    f"runner contract {runner_id} output attachment is unsafe"
                )
            if attachment in attachment_names:
                raise QualificationPolicyError(
                    f"runner contract {runner_id} repeats output attachment "
                    f"{attachment!r}"
                )
            attachment_names.add(attachment)
            identifiers = output.get("testIdentifiers")
            if (
                not isinstance(identifiers, list)
                or not identifiers
                or normalize_catalog_identifiers(identifiers) != identifiers
            ):
                raise QualificationPolicyError(
                    f"runner contract {runner_id} output catalog is invalid"
                )
            by_scenario[str(scenario_id)] = (contract, output)
        by_runner[runner_id] = contract
    missing_outputs = sorted(set(scenarios) - set(by_scenario))
    if missing_outputs:
        raise QualificationPolicyError(
            f"qualification scenarios have no authorized producer: {missing_outputs!r}"
        )
    missing_release = sorted(REQUIRED_RELEASE_RUNNER_SCENARIOS - set(by_runner))
    if missing_release:
        raise QualificationPolicyError(
            f"release runner contracts are missing: {missing_release!r}"
        )
    return by_runner, by_scenario


def runner_attachment_expectations(
    contract: dict, output_scenarios: Iterable[str]
) -> dict[str, list[str]]:
    """Return the exact attachment set one retained runner result must contain."""

    selected = set(output_scenarios)
    outputs = contract["outputs"]
    if contract.get("attachmentEmission", "selectedOutputs") == "allOutputs":
        selected = {output["scenario"] for output in outputs}
    return {
        output["attachmentName"]: output["testIdentifiers"]
        for output in outputs
        if output["scenario"] in selected
    }


def authorized_runner_catalog(
    contract: dict,
    output_scenarios: Iterable[str],
    candidate_catalog: Sequence[str],
) -> dict:
    selection = contract.get("selection")
    if isinstance(selection, dict):
        kind = selection.get("kind")
        if kind == "fullCandidateCatalog":
            identifiers = list(candidate_catalog)
        elif kind == "candidatePrefix":
            prefix = selection["prefix"]
            identifiers = [
                item for item in candidate_catalog if item.startswith(prefix)
            ]
        elif kind == "candidatePrefixes":
            prefixes = selection["prefixes"]
            identifiers = [
                item
                for item in candidate_catalog
                if any(item.startswith(prefix) for prefix in prefixes)
            ]
        elif kind == "candidateExcludingPrefixes":
            prefixes = selection["prefixes"]
            identifiers = [
                item
                for item in candidate_catalog
                if not any(item.startswith(prefix) for prefix in prefixes)
            ]
        elif kind == "exact":
            identifiers = selection["testIdentifiers"]
        else:  # validate_runner_contracts owns the schema.
            raise QualificationPolicyError("runner contract selection is invalid")
    else:
        selected = set(output_scenarios)
        if contract.get("attachmentEmission", "selectedOutputs") == "allOutputs":
            selected = {output["scenario"] for output in contract["outputs"]}
        identifiers = sorted(
            {
                identifier
                for output in contract["outputs"]
                if output["scenario"] in selected
                for identifier in output["testIdentifiers"]
            }
        )
    result = catalog_record(identifiers)
    unknown = sorted(set(result["testIdentifiers"]) - set(candidate_catalog))
    if unknown:
        raise QualificationPolicyError(
            f"runner contract selects tests absent from candidate catalog: {unknown!r}"
        )
    return result


def validate_release_catalog_partition(
    matrix: dict, candidate_catalog: list[str]
) -> None:
    scenarios, hardware = validate_matrix(matrix)
    contracts, _ = validate_runner_contracts(matrix)
    covered: set[str] = set()
    for hardware_id in hardware:
        for runner_id in REQUIRED_RELEASE_RUNNER_SCENARIOS:
            if (
                runner_id in IPHONE_CURRENT_ONLY_RUNNER_SCENARIOS
                and hardware_id != "iphone-current"
            ):
                continue
            contract = contracts.get(runner_id)
            if contract is None:
                raise QualificationPolicyError(
                    f"required release runner {runner_id!r} has no contract"
                )
            produced = {
                output["scenario"]
                for output in contract.get("outputs", [])
                if hardware_id
                in scenarios[output["scenario"]].get("hardware", list(hardware))
            }
            covered.update(
                authorized_runner_catalog(contract, produced, candidate_catalog)[
                    "testIdentifiers"
                ]
            )
    missing = sorted(set(candidate_catalog) - covered - RELEASE_CATALOG_EXCEPTIONS)
    if missing:
        raise QualificationPolicyError(
            "candidate XCTest catalog has leaves outside the immutable release "
            f"runner partition: {missing!r}"
        )


def validate_evidence_semantics(
    evidence: dict,
    scenario: dict,
    *,
    retained_base: Path | None = None,
    require_retained: bool = False,
    artifact_base: Path | None = None,
    artifact_stem: str | None = None,
    require_host_artifacts: bool = False,
    expected_probe_bundle_identifier: str = (CANONICAL_TEST_RUNNER_BUNDLE_IDENTIFIER),
) -> set[tuple[str, ...]]:
    scenario_id = scenario["id"]
    try:
        _validate_finite_json_tree(evidence)
    except (QualificationPolicyError, RecursionError) as error:
        raise QualificationPolicyError(
            f"{scenario_id} evidence is not valid finite JSON: {error}"
        ) from error
    for field in scenario.get("requiredEvidenceFields", []):
        value = nested_value(evidence, field)
        if (
            value is _MISSING
            or value is None
            or value == ""
            or value == []
            or value == {}
        ):
            raise QualificationPolicyError(
                f"{scenario_id} evidence is missing non-empty field {field!r}"
            )
    for field, expected in scenario.get("expectedEvidenceValues", {}).items():
        value = nested_value(evidence, field)
        if value is _MISSING or not _json_same(value, expected):
            rendered = None if value is _MISSING else value
            raise QualificationPolicyError(
                f"{scenario_id} evidence field {field!r} is {rendered!r}, "
                f"expected {expected!r}"
            )
    for field, allowed in scenario.get("allowedEvidenceValues", {}).items():
        value = nested_value(evidence, field)
        if value is _MISSING or not any(
            _json_same(value, candidate) for candidate in allowed
        ):
            rendered = None if value is _MISSING else value
            raise QualificationPolicyError(
                f"{scenario_id} evidence field {field!r} is {rendered!r}, "
                f"expected one of {allowed!r}"
            )
    artifact_fingerprints: set[tuple[str, ...]] = set()
    if scenario_id == "seek-frame-oracles":
        validate_seek_frame_oracle_evidence(evidence, scenario)
    elif scenario_id == "vod-controls":
        validate_vod_controls_evidence(evidence)
    elif scenario_id == "adaptive-hls-soak":
        validate_adaptive_playback_oracle(evidence)
    elif scenario_id == "cadence-matrix":
        validate_cadence_oracle(evidence)
    elif scenario_id == "playback-foreground-displaylayer-recovery":
        validate_native_renderer_recovery_evidence(evidence)
    elif scenario_id in {"local-file-matrix", "audio-only-playback"}:
        validate_local_playback_evidence(
            evidence,
            scenario_id,
            retained_base=retained_base,
            require_retained=require_retained,
        )
    elif scenario_id == "audio-media-services-reset":
        validate_audio_media_services_reset_evidence(
            evidence,
            retained_base=retained_base,
            require_retained=require_retained,
        )
    elif scenario_id == "audio-session-ownership":
        if (
            not isinstance(expected_probe_bundle_identifier, str)
            or BUNDLE_IDENTIFIER.fullmatch(expected_probe_bundle_identifier) is None
        ):
            raise QualificationPolicyError(
                "candidate has no valid testRunnerBundleIdentifier"
            )
        validate_audio_session_ownership_evidence(
            evidence,
            retained_base=retained_base,
            require_retained=require_retained,
            expected_probe_bundle_identifier=expected_probe_bundle_identifier,
        )
    elif scenario_id == "progressive-http-range-seek":
        artifact_fingerprints.update(
            validate_progressive_http_range_evidence(
                evidence,
                retained_base=retained_base,
                artifact_base=artifact_base,
                require_retained=require_retained,
                require_host_artifacts=require_host_artifacts,
            )
        )
    elif scenario_id == "native-hls-seek-continuity":
        validate_native_hls_seek_continuity_evidence(evidence)
    elif scenario_id in PERFORMANCE_RESOURCE_BUDGETS:
        validate_performance_evidence(evidence, scenario_id)
    if require_host_artifacts and scenario_id in HOST_TRACE_REQUIREMENTS:
        if artifact_base is None:
            raise QualificationPolicyError(
                f"{scenario_id} has no retained host-artifact namespace"
            )
        artifact_fingerprints = validate_host_augmented_artifacts(
            evidence, scenario_id, artifact_base, artifact_stem
        )
    validate_expected_error_evidence(
        evidence,
        scenario_id,
        retained_base=retained_base,
        require_retained=require_retained,
    )
    return artifact_fingerprints


def _exact_object(value: object, keys: set[str], description: str) -> dict:
    if not isinstance(value, dict) or set(value) != keys:
        raise QualificationPolicyError(
            f"{description} must contain exactly {sorted(keys)!r}"
        )
    return value


def _validate_raw_evidence_shape(
    evidence: dict,
    raw_keys: set[str],
    description: str,
    *,
    duration_is_host_owned: bool,
) -> None:
    host_keys = set(_ATTACHMENT_HOST_FIELDS)
    if duration_is_host_owned:
        host_keys.add("durationSeconds")
    observed_raw_keys = set(evidence) - host_keys
    if observed_raw_keys != raw_keys:
        raise QualificationPolicyError(
            f"{description} raw attachment shape changed; expected exactly "
            f"{sorted(raw_keys)!r}, got {sorted(observed_raw_keys)!r}"
        )


def _finite_number(value: object, description: str) -> float:
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
    ):
        raise QualificationPolicyError(f"{description} must be a finite number")
    return float(value)


def _integer(value: object, description: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise QualificationPolicyError(f"{description} must be an integer")
    return value


NATIVE_HLS_SEEK_COMMANDS = ("forward", "backward", "absolute")
NATIVE_PIP_OUTPUT_IDENTITY_KEYS = {
    "nativeHandleIdentity",
    "playbackGeneration",
    "outputIdentity",
}


def _positive_identity_integer(value: object, description: str) -> int:
    result = _integer(value, description)
    if result <= 0 or result > (1 << 64) - 1:
        raise QualificationPolicyError(
            f"{description} must be a nonzero UInt64"
        )
    return result


def validate_native_hls_seek_continuity_evidence(evidence: dict) -> None:
    scenario_id = "native-hls-seek-continuity"
    if evidence.get("nativeOutputIdentityStable") is not True:
        raise QualificationPolicyError(
            f"{scenario_id} has no exact stable native-output identity proof"
        )
    commands = _exact_object(
        evidence.get("commandEvidence"),
        set(NATIVE_HLS_SEEK_COMMANDS),
        f"{scenario_id} commandEvidence",
    )
    row_identity: tuple[int, int, int] | None = None
    for command_name in NATIVE_HLS_SEEK_COMMANDS:
        command = commands[command_name]
        if not isinstance(command, dict):
            raise QualificationPolicyError(
                f"{scenario_id} {command_name} command evidence is malformed"
            )
        media_generation = _positive_identity_integer(
            command.get("mediaGeneration"),
            f"{scenario_id} {command_name} mediaGeneration",
        )
        snapshots: list[tuple[int, int, int]] = []
        for phase in ("baseline", "landing"):
            snapshot = _exact_object(
                command.get(f"{phase}PiPOutputIdentity"),
                NATIVE_PIP_OUTPUT_IDENTITY_KEYS,
                f"{scenario_id} {command_name} {phase} PiP output identity",
            )
            snapshots.append(
                (
                    _positive_identity_integer(
                        snapshot["nativeHandleIdentity"],
                        f"{scenario_id} {command_name} {phase} native handle",
                    ),
                    _positive_identity_integer(
                        snapshot["playbackGeneration"],
                        f"{scenario_id} {command_name} {phase} playback generation",
                    ),
                    _positive_identity_integer(
                        snapshot["outputIdentity"],
                        f"{scenario_id} {command_name} {phase} output identity",
                    ),
                )
            )
        baseline, landing = snapshots
        if baseline != landing:
            raise QualificationPolicyError(
                f"{scenario_id} {command_name} rebuilt or relabelled its native "
                "PiP output"
            )
        if baseline[1] != media_generation:
            raise QualificationPolicyError(
                f"{scenario_id} {command_name} PiP playback generation is not "
                "bound to the seek media generation"
            )
        if row_identity is None:
            row_identity = baseline
        elif baseline != row_identity:
            raise QualificationPolicyError(
                f"{scenario_id} changed native PiP output between ordinary "
                "same-media seek commands"
            )


APPLE_AUDIO_NATIVE_SNAPSHOT_KEYS = {
    "version",
    "brokerPhase",
    "commandOrigin",
    "brokerEpoch",
    "brokerResetEpoch",
    "commandGeneration",
    "commandResetEpoch",
    "acknowledgedResetEpoch",
    "outputIncarnationCount",
    "successfulRebuildCount",
    "explicitResumeAttemptCount",
    "explicitResumeFailureCount",
    "commandWasDispatched",
    "liveOutputCount",
    "brokerActiveOwnerCount",
    "brokerLiveLeaseCount",
    "brokerSuccessfulDeactivationCount",
    "brokerFailedDeactivationCount",
}
APPLE_AUDIO_PLAYBACK_COUNTER_KEYS = {
    "mediaTimeMilliseconds",
    "decodedAudio",
    "playedAudioBuffers",
    "lostAudioBuffers",
    "decodedVideo",
    "displayedPictures",
    "lostPictures",
}
APPLE_AUDIO_RECOVERY_CHECKPOINT_KEYS = {
    "systemUptime",
    "playerState",
    "playbackRequestedActive",
    "native",
    "playback",
}
APPLE_AUDIO_SESSION_CONFIGURATION_KEYS = {
    "category",
    "mode",
    "categoryOptionsRawValue",
    "routeSharingPolicyRawValue",
    "preferredSampleRate",
    "preferredIOBufferDuration",
    "preferredInputNumberOfChannels",
    "preferredOutputNumberOfChannels",
}
APPLE_AUDIO_NOTIFICATION_KEYS = {"kind", "systemUptime"}
APPLE_AUDIO_RESET_PLAYER_KEYS = {
    "role",
    "forcedAudioOutputModule",
    "readinessStart",
    "baseline",
    "quarantineStart",
    "quarantineEnd",
    "recovered",
}
APPLE_AUDIO_RESET_RAW_KEYS = {
    "formatVersion",
    "scenario",
    "trigger",
    "syntheticNotificationsPosted",
    "mediaServicesLostNotificationCount",
    "mediaServicesResetNotificationCount",
    "mediaServicesNotificationSequence",
    "quarantineObservationMilliseconds",
    "pictureInPictureActiveBeforeReset",
    "pictureInPictureActiveAfterRecovery",
    "players",
    "resetEpochProof",
    "preIntentQuarantine",
    "explicitResumeRecovery",
    "forcedOutputModules",
    "systemPiPMotionBeforeReset",
    "systemPiPMotionAfterRecovery",
    "libraryErrorCount",
}
APPLE_AUDIO_OWNERSHIP_RAW_KEYS = {
    "formatVersion",
    "scenario",
    "libraryManagedForcedModules",
    "applicationManagedForcedModules",
    "idleSessionBeforePlayerConstruction",
    "idleSessionAfterPlayerConstruction",
    "idleBrokerBeforePlayerConstruction",
    "idleBrokerAfterPlayerConstruction",
    "libraryManagedCycles",
    "applicationManagedCycles",
    "interruptionNotificationSequence",
    "idleConstruction",
    "multiOwnerRelease",
    "survivingOutputContinuity",
    "finalDeactivation",
    "applicationManagedNonMutation",
    "idleConstructionFocusProbe",
    "libraryReleaseFocusProbes",
    "applicationManagedReleaseFocusProbes",
    "hostReleaseFocusProbe",
    "libraryErrorCount",
}
APPLE_AUDIO_LIBRARY_OWNERSHIP_CYCLE_KEYS = {
    "forcedModuleOrder",
    "firstOutputActive",
    "bothOutputsActive",
    "afterFirstOutputRelease",
    "afterFinalOutputRelease",
    "firstOutputPlaybackStart",
    "firstOutputPlaybackEnd",
    "secondOutputPlaybackStart",
    "secondOutputPlaybackEnd",
}
APPLE_AUDIO_APPLICATION_OWNERSHIP_CYCLE_KEYS = {
    "forcedAudioOutputModule",
    "sessionBeforePlayback",
    "sessionDuringPlayback",
    "sessionAfterPlayback",
    "brokerBeforePlayback",
    "brokerDuringPlayback",
    "brokerAfterPlayback",
    "playbackStart",
    "playbackEnd",
}
APPLE_AUDIO_FOCUS_PROBE_KEYS = {
    "phase",
    "source",
    "activationSucceeded",
    "probeApplicationBundleIdentifier",
    "probeApplicationStateAtActivation",
    "candidateApplicationStateBeforeProbe",
    "candidateApplicationStateDuringActivation",
    "candidateApplicationStateAfterProbe",
    "activationBeganSystemUptime",
    "activationCompletedSystemUptime",
    "deactivationBeganSystemUptime",
    "deactivationCompletedSystemUptime",
    "observationSystemUptime",
    "candidateInterruptionBeganBefore",
    "candidateInterruptionEndedBefore",
    "candidateInterruptionBeganAfterProbe",
    "candidateInterruptionEndedAfterProbe",
    "candidateInterruptionBeganDelta",
    "candidateInterruptionEndedDelta",
    "outcome",
}
APPLE_AUDIO_SOURCE_REQUEST_PROOF_KEYS = {
    "formatVersion",
    "method",
    "sourceAttempt",
    "attemptToken",
    "masterRequests",
    "mediaPlaylistRequests",
    "segmentRequests",
    "successfulSegments",
    "playlistTypes",
    "containers",
    "variants",
    "modes",
    "metricsRelativePath",
    "metricsDigestAlgorithm",
    "metricsDigest",
    "metricsSizeBytes",
}
APPLE_AUDIO_ADAPTIVE_METRICS_KEYS = {
    "formatVersion",
    "token",
    "masterRequests",
    "mediaPlaylistRequests",
    "segmentRequests",
    "successfulSegments",
    "successfulSegmentsByVariant",
    "retryFailures",
    "retryRecoveries",
    "expiredWindows",
    "discontinuityManifests",
    "variantTransitions",
    "clientCompleted",
    "playlistTypes",
    "containers",
    "variants",
    "modes",
    "maxMediaSequenceByMode",
}
APPLE_AUDIO_INTERRUPTION_NOTIFICATION_KEYS = {
    "kind",
    "systemUptime",
    "reasonRawValue",
}


def _apple_audio_native_snapshot(value: object, description: str) -> dict:
    snapshot = _exact_object(value, APPLE_AUDIO_NATIVE_SNAPSHOT_KEYS, description)
    if snapshot["version"] != 1:
        raise QualificationPolicyError(f"{description} version is not 1")
    if snapshot["brokerPhase"] not in {"ready", "lost"}:
        raise QualificationPolicyError(f"{description} broker phase is invalid")
    if snapshot["commandOrigin"] not in {"invalidating", "explicitResume"}:
        raise QualificationPolicyError(f"{description} command origin is invalid")
    if not isinstance(snapshot["commandWasDispatched"], bool):
        raise QualificationPolicyError(f"{description} dispatch flag is not boolean")
    integer_keys = APPLE_AUDIO_NATIVE_SNAPSHOT_KEYS - {
        "brokerPhase",
        "commandOrigin",
        "commandWasDispatched",
    }
    for key in integer_keys:
        if _integer(snapshot[key], f"{description} {key}") < 0:
            raise QualificationPolicyError(f"{description} {key} cannot be negative")
    if snapshot["brokerEpoch"] <= 0:
        raise QualificationPolicyError(f"{description} broker epoch is invalid")
    if snapshot["brokerActiveOwnerCount"] < snapshot["brokerLiveLeaseCount"]:
        raise QualificationPolicyError(f"{description} lease count exceeds owners")
    return snapshot


def _apple_audio_playback(value: object, description: str) -> dict:
    playback = _exact_object(value, APPLE_AUDIO_PLAYBACK_COUNTER_KEYS, description)
    for key in APPLE_AUDIO_PLAYBACK_COUNTER_KEYS:
        if _integer(playback[key], f"{description} {key}") < 0:
            raise QualificationPolicyError(f"{description} {key} cannot be negative")
    return playback


def _apple_audio_checkpoint(value: object, description: str) -> dict:
    checkpoint = _exact_object(value, APPLE_AUDIO_RECOVERY_CHECKPOINT_KEYS, description)
    uptime = _finite_number(checkpoint["systemUptime"], f"{description} uptime")
    if uptime <= 0:
        raise QualificationPolicyError(f"{description} uptime is not positive")
    if checkpoint["playerState"] not in {
        "idle",
        "opening",
        "buffering",
        "playing",
        "paused",
        "stopping",
        "stopped",
        "error",
    }:
        raise QualificationPolicyError(f"{description} player state is invalid")
    if not isinstance(checkpoint["playbackRequestedActive"], bool):
        raise QualificationPolicyError(f"{description} intent is not boolean")
    _apple_audio_native_snapshot(checkpoint["native"], f"{description} native")
    _apple_audio_playback(checkpoint["playback"], f"{description} playback")
    return checkpoint


def _apple_audio_session_configuration(value: object, description: str) -> dict:
    configuration = _exact_object(
        value, APPLE_AUDIO_SESSION_CONFIGURATION_KEYS, description
    )
    if not isinstance(configuration["category"], str) or not configuration["category"]:
        raise QualificationPolicyError(f"{description} category is invalid")
    if not isinstance(configuration["mode"], str) or not configuration["mode"]:
        raise QualificationPolicyError(f"{description} mode is invalid")
    for key in (
        "categoryOptionsRawValue",
        "routeSharingPolicyRawValue",
        "preferredInputNumberOfChannels",
        "preferredOutputNumberOfChannels",
    ):
        if _integer(configuration[key], f"{description} {key}") < 0:
            raise QualificationPolicyError(f"{description} {key} cannot be negative")
    for key in ("preferredSampleRate", "preferredIOBufferDuration"):
        if _finite_number(configuration[key], f"{description} {key}") < 0:
            raise QualificationPolicyError(f"{description} {key} cannot be negative")
    return configuration


def _audio_ownership_tuple(snapshot: dict) -> tuple[int, int, int, int]:
    return (
        snapshot["brokerActiveOwnerCount"],
        snapshot["brokerLiveLeaseCount"],
        snapshot["brokerSuccessfulDeactivationCount"],
        snapshot["brokerFailedDeactivationCount"],
    )


def _validate_apple_audio_source_request_proof(
    value: object,
    *,
    description: str,
    token_kind: str,
    runner_scenario: str,
    minimum_successful_segments: int,
    retained_base: Path | None,
    require_retained: bool,
    expected_source_attempt: int | None = None,
) -> dict:
    proof = _exact_object(
        value,
        APPLE_AUDIO_SOURCE_REQUEST_PROOF_KEYS,
        description,
    )
    counters = {
        key: _integer(proof[key], f"{description} {key}")
        for key in (
            "masterRequests",
            "mediaPlaylistRequests",
            "segmentRequests",
            "successfulSegments",
        )
    }
    source_attempt = _integer(
        proof.get("sourceAttempt"), f"{description} sourceAttempt"
    )
    token = proof.get("attemptToken")
    relative_value = proof.get("metricsRelativePath")
    relative = Path(str(relative_value))
    namespace_suffix = f"-{runner_scenario}"
    namespace = relative.parts[1] if len(relative.parts) == 3 else ""
    run_id = (
        namespace[: -len(namespace_suffix)]
        if namespace.endswith(namespace_suffix)
        else ""
    )
    expected_token = f"{run_id}-audio-{token_kind}-{source_attempt}"
    if (
        _integer(proof.get("formatVersion"), f"{description} formatVersion") != 2
        or proof.get("method") != "host-fixture-server-token-metrics-v2"
        or source_attempt not in {1, 2, 3}
        or (
            expected_source_attempt is not None
            and source_attempt != expected_source_attempt
        )
        or not isinstance(token, str)
        or not isinstance(relative_value, str)
        or relative.is_absolute()
        or ".." in relative.parts
        or len(relative.parts) != 3
        or relative.parts[0] != "apple-audio-source-metrics"
        or relative.parts[2] != f"attempt-{source_attempt}.json"
        or re.fullmatch(r"[A-Za-z0-9._-]+", namespace) is None
        or not run_id
        or re.fullmatch(r"[A-Za-z0-9._-]+", run_id) is None
        or token != expected_token
        or counters["masterRequests"] <= 0
        or counters["mediaPlaylistRequests"] <= 0
        or counters["segmentRequests"] < minimum_successful_segments
        or counters["successfulSegments"] < minimum_successful_segments
        or counters["successfulSegments"] != counters["segmentRequests"]
        or proof.get("playlistTypes") != ["vod"]
        or proof.get("containers") != ["ts"]
        or proof.get("variants") != ["high"]
        or proof.get("modes") != ["timebase-vod-ts"]
        or proof.get("metricsDigestAlgorithm") != "sha256"
        or SHA256.fullmatch(str(proof.get("metricsDigest", ""))) is None
        or _integer(proof.get("metricsSizeBytes"), f"{description} metricsSizeBytes")
        <= 0
    ):
        raise QualificationPolicyError(f"{description} is invalid")
    if require_retained:
        if retained_base is None:
            raise QualificationPolicyError(
                f"{description} has no retained artifact base"
            )
        metrics_path = safe_relative_file(
            retained_base,
            relative_value,
            f"{description} retained metrics",
        )
        metrics_directory = metrics_path.parent
        reject_tree_symlinks(metrics_directory, f"{description} retained metrics")
        try:
            metrics_entries = list(metrics_directory.iterdir())
        except OSError as error:
            raise QualificationPolicyError(
                f"{description} retained metrics inventory is unreadable: {error}"
            ) from error
        if {path.name for path in metrics_entries} != {metrics_path.name} or any(
            not path.is_file() or path.is_symlink() for path in metrics_entries
        ):
            raise QualificationPolicyError(
                f"{description} retained metrics inventory is not exact"
            )
        if (
            proof["metricsDigest"] != sha256_file(metrics_path)
            or proof["metricsSizeBytes"] != metrics_path.stat().st_size
        ):
            raise QualificationPolicyError(
                f"{description} retained metrics binding mismatch"
            )
        metrics = load_json(metrics_path, f"{description} retained metrics")
        raw = _exact_object(
            metrics,
            APPLE_AUDIO_ADAPTIVE_METRICS_KEYS,
            f"{description} retained metrics",
        )
        raw_counters = {
            key: _integer(raw[key], f"{description} retained metrics {key}")
            for key in (
                "masterRequests",
                "mediaPlaylistRequests",
                "segmentRequests",
                "successfulSegments",
                "retryFailures",
                "retryRecoveries",
                "expiredWindows",
                "discontinuityManifests",
                "variantTransitions",
            )
        }
        variants = _exact_object(
            raw.get("successfulSegmentsByVariant"),
            {"low", "high"},
            f"{description} retained variant counters",
        )
        media_sequences = _exact_object(
            raw.get("maxMediaSequenceByMode"),
            {"timebase-vod-ts"},
            f"{description} retained media sequences",
        )
        if (
            _integer(
                raw.get("formatVersion"),
                f"{description} retained metrics formatVersion",
            )
            != 1
            or raw.get("token") != token
            or raw.get("clientCompleted") is not False
            or raw_counters["masterRequests"] != counters["masterRequests"]
            or raw_counters["mediaPlaylistRequests"]
            != counters["mediaPlaylistRequests"]
            or raw_counters["segmentRequests"] != counters["segmentRequests"]
            or raw_counters["successfulSegments"] != counters["successfulSegments"]
            or raw_counters["segmentRequests"] != raw_counters["successfulSegments"]
            or raw_counters["retryFailures"] != 0
            or raw_counters["retryRecoveries"] != 0
            or raw_counters["expiredWindows"] != 0
            or raw_counters["variantTransitions"] != 0
            or raw_counters["discontinuityManifests"]
            != raw_counters["mediaPlaylistRequests"]
            or _integer(variants.get("low"), f"{description} retained low segments")
            != 0
            or _integer(variants.get("high"), f"{description} retained high segments")
            != raw_counters["successfulSegments"]
            or _integer(
                media_sequences.get("timebase-vod-ts"),
                f"{description} retained media sequence",
            )
            != 0
            or raw.get("playlistTypes") != proof["playlistTypes"]
            or raw.get("containers") != proof["containers"]
            or raw.get("variants") != proof["variants"]
            or raw.get("modes") != proof["modes"]
        ):
            raise QualificationPolicyError(
                f"{description} retained metrics are invalid"
            )
    return proof


def bind_apple_audio_source_request_proof(
    metrics_path: Path,
    *,
    retained_base: Path,
    scenario: str,
    runner_scenario: str,
    source_attempt: int,
) -> dict:
    contracts = {
        "audio-media-services-reset": ("reset", 2),
        "audio-session-ownership": ("ownership", 6),
    }
    if scenario not in contracts or runner_scenario != scenario:
        raise QualificationPolicyError(
            "Apple audio source metrics do not match an authorized runner"
        )
    try:
        resolved_base = retained_base.resolve()
        resolved_metrics = metrics_path.resolve()
        relative = resolved_metrics.relative_to(resolved_base)
    except (OSError, ValueError) as error:
        raise QualificationPolicyError(
            f"Apple audio source metrics are outside the retained root: {error}"
        ) from error
    bound_metrics = safe_relative_file(
        retained_base,
        relative.as_posix(),
        "Apple audio source metrics",
    )
    if bound_metrics != resolved_metrics:
        raise QualificationPolicyError(
            "Apple audio source metrics path is not canonical"
        )
    raw = _exact_object(
        load_json(bound_metrics, "Apple audio source metrics"),
        APPLE_AUDIO_ADAPTIVE_METRICS_KEYS,
        "Apple audio source metrics",
    )
    token_kind, minimum_successful_segments = contracts[scenario]
    proof = {
        "formatVersion": 2,
        "method": "host-fixture-server-token-metrics-v2",
        "sourceAttempt": source_attempt,
        "attemptToken": raw.get("token"),
        "masterRequests": raw.get("masterRequests"),
        "mediaPlaylistRequests": raw.get("mediaPlaylistRequests"),
        "segmentRequests": raw.get("segmentRequests"),
        "successfulSegments": raw.get("successfulSegments"),
        "playlistTypes": raw.get("playlistTypes"),
        "containers": raw.get("containers"),
        "variants": raw.get("variants"),
        "modes": raw.get("modes"),
        "metricsRelativePath": relative.as_posix(),
        "metricsDigestAlgorithm": "sha256",
        "metricsDigest": sha256_file(bound_metrics),
        "metricsSizeBytes": bound_metrics.stat().st_size,
    }
    return _validate_apple_audio_source_request_proof(
        proof,
        description=f"{scenario} source request proof",
        token_kind=token_kind,
        runner_scenario=runner_scenario,
        minimum_successful_segments=minimum_successful_segments,
        retained_base=retained_base,
        require_retained=True,
        expected_source_attempt=source_attempt,
    )


def _validate_apple_audio_output_logs(
    evidence: dict,
    expected_children: Mapping[str, tuple[str, str]],
    *,
    retained_base: Path | None,
    require_retained: bool,
) -> None:
    if not require_retained:
        return
    if retained_base is None:
        raise QualificationPolicyError("Apple audio evidence has no retained log base")
    inventory = evidence.get("hostErrorInventory")
    if not isinstance(inventory, dict):
        raise QualificationPolicyError("Apple audio evidence has no host log inventory")
    retained_root = safe_relative_directory(
        retained_base,
        inventory.get("retainedRoot"),
        "Apple audio retained logs",
    )
    raw_files = inventory.get("rawFiles")
    if not isinstance(raw_files, list):
        raise QualificationPolicyError("Apple audio log inventory is malformed")
    child_records = [
        record
        for record in raw_files
        if isinstance(record, dict) and record.get("logRole") == "child"
    ]
    records = {record.get("childName"): record for record in child_records}
    child_paths = [record.get("path") for record in child_records]
    if (
        len(child_records) != len(expected_children)
        or set(records) != set(expected_children)
        or any(not isinstance(path, str) for path in child_paths)
        or len(set(child_paths)) != len(child_paths)
    ):
        raise QualificationPolicyError("Apple audio child log set is not exact")
    selection_pattern = re.compile(r'^using audio output module "([^"]+)"$', re.I)
    for child, (expected_module, required_message) in expected_children.items():
        record = records[child]
        path = safe_relative_file(
            retained_root,
            record.get("path"),
            f"Apple audio {child} log",
        )
        messages: list[str] = []
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeError) as error:
            raise QualificationPolicyError(
                f"cannot read Apple audio {child} log: {error}"
            ) from error
        for line_number, line in enumerate(lines, 1):
            record_value = loads_json(
                line, f"Apple audio {child} log line {line_number}"
            )
            if isinstance(record_value, dict) and isinstance(
                record_value.get("message"), str
            ):
                messages.append(_normalized_text(record_value["message"]))
        selected_modules = [
            match.group(1)
            for message in messages
            if (match := selection_pattern.fullmatch(message)) is not None
        ]
        if (
            expected_module not in selected_modules
            or any(module != expected_module for module in selected_modules)
            or required_message not in messages
        ):
            raise QualificationPolicyError(
                f"Apple audio {child} log does not prove its forced output module"
            )


def validate_audio_media_services_reset_evidence(
    evidence: dict,
    *,
    retained_base: Path | None,
    require_retained: bool,
) -> None:
    scenario_id = "audio-media-services-reset"
    _validate_raw_evidence_shape(
        evidence,
        APPLE_AUDIO_RESET_RAW_KEYS,
        scenario_id,
        duration_is_host_owned=True,
    )
    if (
        _integer(evidence.get("formatVersion"), "audio reset formatVersion") != 1
        or evidence.get("scenario") != scenario_id
        or evidence.get("trigger") != "settings-developer-media-services-reset-v1"
        or evidence.get("syntheticNotificationsPosted") is not False
        or _integer(evidence.get("libraryErrorCount"), "audio reset library errors")
        != 0
        or evidence.get("pictureInPictureActiveBeforeReset") is not True
        or evidence.get("pictureInPictureActiveAfterRecovery") is not True
        or evidence.get("resetEpochProof") != "pass"
        or evidence.get("preIntentQuarantine") != "pass"
        or evidence.get("explicitResumeRecovery") != "pass"
        or evidence.get("forcedOutputModules") != ["audiounit_ios", "avsamplebuffer"]
        or evidence.get("systemPiPMotionBeforeReset") != "pass"
        or evidence.get("systemPiPMotionAfterRecovery") != "pass"
    ):
        raise QualificationPolicyError("audio reset attachment header is invalid")
    lost_notification_count = _integer(
        evidence.get("mediaServicesLostNotificationCount"),
        "audio reset lost notification count",
    )
    reset_notification_count = _integer(
        evidence.get("mediaServicesResetNotificationCount"),
        "audio reset notification count",
    )
    if lost_notification_count < 0 or reset_notification_count < 1:
        raise QualificationPolicyError(
            "audio reset system notification counts are invalid"
        )
    notification_sequence = evidence.get("mediaServicesNotificationSequence")
    if not isinstance(notification_sequence, list) or not notification_sequence:
        raise QualificationPolicyError("audio reset notification sequence is empty")
    notification_kinds: list[str] = []
    notification_uptimes: list[float] = []
    previous_notification_uptime = 0.0
    for index, value in enumerate(notification_sequence):
        notification = _exact_object(
            value,
            APPLE_AUDIO_NOTIFICATION_KEYS,
            f"audio reset notification {index}",
        )
        kind = notification.get("kind")
        uptime = _finite_number(
            notification.get("systemUptime"),
            f"audio reset notification {index} uptime",
        )
        if kind not in {"lost", "reset"} or uptime <= 0:
            raise QualificationPolicyError("audio reset notification record is invalid")
        if uptime < previous_notification_uptime:
            raise QualificationPolicyError("audio reset notifications are out of order")
        notification_kinds.append(kind)
        notification_uptimes.append(uptime)
        previous_notification_uptime = uptime
    first_reset = (
        notification_kinds.index("reset") if "reset" in notification_kinds else -1
    )
    if (
        notification_kinds.count("lost") != lost_notification_count
        or notification_kinds.count("reset") != reset_notification_count
        or first_reset < 0
        or "lost" in notification_kinds[first_reset:]
    ):
        raise QualificationPolicyError(
            "audio reset notification sequence is incoherent"
        )
    first_notification_uptime = notification_uptimes[0]
    quarantine_milliseconds = _integer(
        evidence.get("quarantineObservationMilliseconds"),
        "audio reset quarantine duration",
    )
    if quarantine_milliseconds < 3000:
        raise QualificationPolicyError(
            "audio reset quarantine was shorter than 3 seconds"
        )
    players = evidence.get("players")
    if not isinstance(players, list) or len(players) != 2:
        raise QualificationPolicyError("audio reset must contain exactly two players")
    expected_modules = {
        "audio-only": "audiounit_ios",
        "native-pip-video": "avsamplebuffer",
    }
    observed: dict[str, dict] = {}
    for index, value in enumerate(players):
        player = _exact_object(
            value, APPLE_AUDIO_RESET_PLAYER_KEYS, f"audio reset player {index}"
        )
        role = player.get("role")
        if role not in expected_modules or role in observed:
            raise QualificationPolicyError("audio reset player roles are not exact")
        if player.get("forcedAudioOutputModule") != expected_modules[role]:
            raise QualificationPolicyError("audio reset forced module is invalid")
        for phase in (
            "readinessStart",
            "baseline",
            "quarantineStart",
            "quarantineEnd",
            "recovered",
        ):
            _apple_audio_checkpoint(player[phase], f"audio reset {role} {phase}")
        observed[role] = player
    if set(observed) != set(expected_modules):
        raise QualificationPolicyError("audio reset player matrix is incomplete")

    baseline_globals: set[tuple[int, int]] = set()
    recovered_globals: set[tuple[int, int]] = set()
    reset_epochs: set[int] = set()
    for role, player in observed.items():
        readiness = player["readinessStart"]
        baseline = player["baseline"]
        start = player["quarantineStart"]
        end = player["quarantineEnd"]
        recovered = player["recovered"]
        baseline_native = baseline["native"]
        start_native = start["native"]
        end_native = end["native"]
        recovered_native = recovered["native"]
        readiness_native = readiness["native"]
        if (
            readiness["playerState"] != "playing"
            or readiness["playbackRequestedActive"] is not True
            or readiness_native["brokerPhase"] != "ready"
            or readiness_native["liveOutputCount"] <= 0
            or readiness["playback"]["playedAudioBuffers"] <= 0
            or baseline["systemUptime"] - readiness["systemUptime"] < 0.5
            or baseline["systemUptime"] - readiness["systemUptime"] > 2.5
            or first_notification_uptime < baseline["systemUptime"]
            or first_notification_uptime - baseline["systemUptime"] > 2.5
            or start["systemUptime"] < first_notification_uptime
            or readiness_native["brokerEpoch"] != baseline_native["brokerEpoch"]
            or readiness_native["brokerResetEpoch"]
            != baseline_native["brokerResetEpoch"]
            or readiness_native["commandGeneration"]
            != baseline_native["commandGeneration"]
            or readiness_native["outputIncarnationCount"]
            != baseline_native["outputIncarnationCount"]
            or readiness_native["brokerActiveOwnerCount"]
            != baseline_native["brokerActiveOwnerCount"]
            or readiness_native["brokerLiveLeaseCount"]
            != baseline_native["brokerLiveLeaseCount"]
            or baseline["playback"]["mediaTimeMilliseconds"]
            <= readiness["playback"]["mediaTimeMilliseconds"]
            or baseline["playback"]["playedAudioBuffers"]
            <= readiness["playback"]["playedAudioBuffers"]
        ):
            raise QualificationPolicyError(
                f"audio reset {role} pre-reset readiness did not progress"
            )
        if role == "native-pip-video" and (
            baseline["playback"]["displayedPictures"]
            <= readiness["playback"]["displayedPictures"]
        ):
            raise QualificationPolicyError(
                "audio reset video did not progress before arming"
            )
        if (
            baseline["playerState"] != "playing"
            or baseline["playbackRequestedActive"] is not True
            or baseline_native["brokerPhase"] != "ready"
            or baseline_native["liveOutputCount"] <= 0
            or baseline["playback"]["playedAudioBuffers"] <= 0
        ):
            raise QualificationPolicyError(f"audio reset {role} baseline is inactive")
        baseline_globals.add(
            (
                baseline_native["brokerActiveOwnerCount"],
                baseline_native["brokerLiveLeaseCount"],
            )
        )
        if (
            start["playerState"] != "paused"
            or end["playerState"] != "paused"
            or start["playbackRequestedActive"] is not False
            or end["playbackRequestedActive"] is not False
            or start_native["brokerPhase"] != "ready"
            or end_native["brokerPhase"] != "ready"
            or start_native["brokerResetEpoch"] <= baseline_native["brokerResetEpoch"]
            or start_native["brokerEpoch"] - baseline_native["brokerEpoch"]
            != lost_notification_count + reset_notification_count
            or start_native["brokerResetEpoch"] != start_native["brokerEpoch"]
            or end_native["brokerResetEpoch"] != start_native["brokerResetEpoch"]
            or end_native["brokerResetEpoch"] != end_native["brokerEpoch"]
            or start_native["brokerActiveOwnerCount"] != 0
            or end_native["brokerActiveOwnerCount"] != 0
            or start_native["brokerLiveLeaseCount"] != 0
            or end_native["brokerLiveLeaseCount"] != 0
            or start_native["commandOrigin"] != "invalidating"
            or end_native["commandOrigin"] != "invalidating"
            or start_native["commandWasDispatched"] is not False
            or end_native["commandWasDispatched"] is not False
            or start_native["commandGeneration"] != end_native["commandGeneration"]
            or start_native["commandResetEpoch"] != end_native["commandResetEpoch"]
            or start_native["acknowledgedResetEpoch"]
            != end_native["acknowledgedResetEpoch"]
            or start_native["outputIncarnationCount"]
            != baseline_native["outputIncarnationCount"]
            or end_native["outputIncarnationCount"]
            != baseline_native["outputIncarnationCount"]
            or start_native["successfulRebuildCount"]
            != baseline_native["successfulRebuildCount"]
            or end_native["successfulRebuildCount"]
            != baseline_native["successfulRebuildCount"]
            or start_native["explicitResumeAttemptCount"]
            != baseline_native["explicitResumeAttemptCount"]
            or end_native["explicitResumeAttemptCount"]
            != baseline_native["explicitResumeAttemptCount"]
            or start_native["explicitResumeFailureCount"]
            != baseline_native["explicitResumeFailureCount"]
            or end_native["explicitResumeFailureCount"]
            != baseline_native["explicitResumeFailureCount"]
            or start_native["acknowledgedResetEpoch"]
            == start_native["brokerResetEpoch"]
            or end_native["acknowledgedResetEpoch"] == end_native["brokerResetEpoch"]
            or start["playback"]["mediaTimeMilliseconds"]
            != end["playback"]["mediaTimeMilliseconds"]
            or start["playback"]["playedAudioBuffers"]
            != end["playback"]["playedAudioBuffers"]
        ):
            raise QualificationPolicyError(f"audio reset {role} quarantine is invalid")
        if role == "native-pip-video" and (
            start["playback"]["displayedPictures"]
            != end["playback"]["displayedPictures"]
        ):
            raise QualificationPolicyError("audio reset video advanced in quarantine")
        measured_milliseconds = int(
            (end["systemUptime"] - start["systemUptime"]) * 1000
        )
        # Both players are sampled serially around one monotonic observation
        # window. Require each independently measured interval to cover the
        # quarantine while allowing bounded snapshot latency at either edge;
        # exact millisecond equality would make sampling order part of the
        # release contract.
        if (
            measured_milliseconds < 3000
            or abs(measured_milliseconds - quarantine_milliseconds) > 500
        ):
            raise QualificationPolicyError(
                "audio reset quarantine duration is inconsistent"
            )
        if (
            recovered["playerState"] != "playing"
            or recovered["playbackRequestedActive"] is not True
            or recovered_native["brokerPhase"] != "ready"
            or recovered_native["brokerEpoch"] != end_native["brokerResetEpoch"]
            or recovered_native["brokerResetEpoch"] != end_native["brokerResetEpoch"]
            or recovered_native["commandOrigin"] != "explicitResume"
            or recovered_native["commandWasDispatched"] is not True
            or recovered_native["commandResetEpoch"] != end_native["brokerResetEpoch"]
            or recovered_native["acknowledgedResetEpoch"]
            != recovered_native["commandResetEpoch"]
            or recovered_native["commandGeneration"] <= end_native["commandGeneration"]
            or recovered_native["outputIncarnationCount"]
            <= baseline_native["outputIncarnationCount"]
            or recovered_native["successfulRebuildCount"]
            <= baseline_native["successfulRebuildCount"]
            or recovered_native["explicitResumeAttemptCount"]
            <= baseline_native["explicitResumeAttemptCount"]
            or recovered_native["explicitResumeFailureCount"]
            != baseline_native["explicitResumeFailureCount"]
            or recovered_native["liveOutputCount"] <= 0
            or recovered["playback"]["mediaTimeMilliseconds"]
            <= end["playback"]["mediaTimeMilliseconds"]
            or recovered["playback"]["playedAudioBuffers"]
            <= end["playback"]["playedAudioBuffers"]
        ):
            raise QualificationPolicyError(f"audio reset {role} recovery is invalid")
        if role == "native-pip-video" and (
            recovered["playback"]["displayedPictures"]
            <= end["playback"]["displayedPictures"]
        ):
            raise QualificationPolicyError("audio reset video did not recover")
        reset_epochs.add(recovered_native["commandResetEpoch"])
        recovered_globals.add(
            (
                recovered_native["brokerActiveOwnerCount"],
                recovered_native["brokerLiveLeaseCount"],
            )
        )
    if (
        len(baseline_globals) != 1
        or next(iter(baseline_globals))[0] < 3
        or next(iter(baseline_globals))[1] < 1
        or len(recovered_globals) != 1
        or next(iter(recovered_globals))[0] < 3
        or next(iter(recovered_globals))[1] < 1
        or len(reset_epochs) != 1
    ):
        raise QualificationPolicyError(
            "audio reset process-wide broker state is incoherent"
        )
    producer = evidence.get("qualificationProducer")
    _validate_apple_audio_source_request_proof(
        evidence.get("sourceRequestProof"),
        description="audio reset source request proof",
        token_kind="reset",
        runner_scenario="audio-media-services-reset",
        minimum_successful_segments=2,
        retained_base=retained_base,
        require_retained=require_retained,
        expected_source_attempt=(
            producer.get("sourceAttempt") if isinstance(producer, dict) else None
        ),
    )
    _validate_apple_audio_output_logs(
        evidence,
        {
            "audiounit": (
                "audiounit_ios",
                "analog AudioUnit output successfully opened for f32l Mono",
            ),
            "avsamplebuffer": (
                "avsamplebuffer",
                "AVSampleBufferAudioRenderer output opened as the priority-100 default",
            ),
        },
        retained_base=retained_base,
        require_retained=require_retained,
    )


def _validate_apple_audio_focus_probe(
    value: object,
    *,
    description: str,
    expected_phase: str,
    expected_before: tuple[int, int],
    expected_delta: int,
    expected_outcome: str,
    expected_probe_bundle_identifier: str,
    extra_fields: Mapping[str, object] | None = None,
) -> dict:
    expected_extras = dict(extra_fields or {})
    probe = _exact_object(
        value,
        APPLE_AUDIO_FOCUS_PROBE_KEYS | set(expected_extras),
        description,
    )
    count_keys = (
        "candidateInterruptionBeganBefore",
        "candidateInterruptionEndedBefore",
        "candidateInterruptionBeganAfterProbe",
        "candidateInterruptionEndedAfterProbe",
        "candidateInterruptionBeganDelta",
        "candidateInterruptionEndedDelta",
    )
    counts = {key: _integer(probe[key], f"{description} {key}") for key in count_keys}
    if any(value < 0 for value in counts.values()):
        raise QualificationPolicyError(f"{description} count cannot be negative")
    time_keys = (
        "activationBeganSystemUptime",
        "activationCompletedSystemUptime",
        "deactivationBeganSystemUptime",
        "deactivationCompletedSystemUptime",
        "observationSystemUptime",
    )
    times = {
        key: _finite_number(probe[key], f"{description} {key}") for key in time_keys
    }
    if not (
        0
        < times["activationBeganSystemUptime"]
        <= times["activationCompletedSystemUptime"]
        <= times["deactivationBeganSystemUptime"]
        <= times["deactivationCompletedSystemUptime"]
        <= times["observationSystemUptime"]
    ):
        raise QualificationPolicyError(f"{description} timing window is invalid")
    began_before, ended_before = expected_before
    if (
        probe["phase"] != expected_phase
        or probe["source"] != "foreground-XCTest-runner-audio-session"
        or probe["activationSucceeded"] is not True
        or probe["probeApplicationBundleIdentifier"] != expected_probe_bundle_identifier
        or probe["probeApplicationStateAtActivation"] != "runningForeground"
        or probe["candidateApplicationStateBeforeProbe"] != "runningForeground"
        or probe["candidateApplicationStateDuringActivation"]
        not in {"runningBackground", "runningBackgroundSuspended"}
        or probe["candidateApplicationStateAfterProbe"] != "runningForeground"
        or counts["candidateInterruptionBeganBefore"] != began_before
        or counts["candidateInterruptionEndedBefore"] != ended_before
        or counts["candidateInterruptionBeganAfterProbe"]
        != began_before + expected_delta
        or counts["candidateInterruptionEndedAfterProbe"]
        != ended_before + expected_delta
        or counts["candidateInterruptionBeganDelta"] != expected_delta
        or counts["candidateInterruptionEndedDelta"] != expected_delta
        or probe["outcome"] != expected_outcome
        or any(probe[key] != expected for key, expected in expected_extras.items())
    ):
        raise QualificationPolicyError(f"{description} is invalid")
    return probe


def _validate_apple_audio_focus_probe_causality(
    probes: list[dict], notifications: list[dict]
) -> None:
    expected_kinds = ["began", "ended", "began", "ended"]
    if [notification["kind"] for notification in notifications] != expected_kinds:
        raise QualificationPolicyError(
            "audio ownership interruption notification sequence is invalid"
        )
    notification_uptimes = [
        notification["systemUptime"] for notification in notifications
    ]
    if any(
        current < previous
        for previous, current in zip(notification_uptimes, notification_uptimes[1:])
    ):
        raise QualificationPolicyError(
            "audio ownership interruption notification sequence is unordered"
        )
    if any(
        current["activationBeganSystemUptime"] <= previous["observationSystemUptime"]
        for previous, current in zip(probes, probes[1:])
    ):
        raise QualificationPolicyError("audio ownership focus probe windows overlap")

    began_notifications = [
        notification
        for notification in notifications
        if notification["kind"] == "began"
    ]
    ended_notifications = [
        notification
        for notification in notifications
        if notification["kind"] == "ended"
    ]
    for probe in probes:
        began_before = probe["candidateInterruptionBeganBefore"]
        ended_before = probe["candidateInterruptionEndedBefore"]
        delta = probe["candidateInterruptionBeganDelta"]
        window_start = probe["activationBeganSystemUptime"]
        deactivation_start = probe["deactivationBeganSystemUptime"]
        window_end = probe["observationSystemUptime"]
        events_in_window = [
            notification
            for notification in notifications
            if window_start <= notification["systemUptime"] <= window_end
        ]
        if delta == 0:
            if events_in_window:
                raise QualificationPolicyError(
                    "released audio ownership focus probe observed an interruption"
                )
            continue
        if (
            delta != 1
            or began_before >= len(began_notifications)
            or ended_before >= len(ended_notifications)
        ):
            raise QualificationPolicyError(
                "audio ownership focus probe notification indices are invalid"
            )
        began = began_notifications[began_before]["systemUptime"]
        ended = ended_notifications[ended_before]["systemUptime"]
        if not (
            window_start <= began <= deactivation_start <= ended <= window_end
            and events_in_window
            == [began_notifications[began_before], ended_notifications[ended_before]]
        ):
            raise QualificationPolicyError(
                "audio ownership interruption is outside its focus probe window"
            )


def _validate_apple_audio_library_ownership_cycle(
    value: object,
    *,
    description: str,
    expected_order: list[str],
    baseline: dict,
) -> tuple[dict, tuple[dict, ...]]:
    cycle = _exact_object(
        value,
        APPLE_AUDIO_LIBRARY_OWNERSHIP_CYCLE_KEYS,
        description,
    )
    if cycle["forcedModuleOrder"] != expected_order:
        raise QualificationPolicyError(f"{description} forced module order is invalid")
    checkpoint_names = (
        "firstOutputActive",
        "bothOutputsActive",
        "afterFirstOutputRelease",
        "afterFinalOutputRelease",
    )
    checkpoints = {
        name: _apple_audio_checkpoint(cycle[name], f"{description} {name}")
        for name in checkpoint_names
    }
    first = checkpoints["firstOutputActive"]
    both = checkpoints["bothOutputsActive"]
    after_first = checkpoints["afterFirstOutputRelease"]
    after_final = checkpoints["afterFinalOutputRelease"]
    if not (
        first["systemUptime"]
        <= both["systemUptime"]
        <= after_first["systemUptime"]
        <= after_final["systemUptime"]
    ):
        raise QualificationPolicyError(f"{description} checkpoints are unordered")
    active_checkpoints = (first, both, after_first)
    if (
        any(
            checkpoint["playerState"] != "playing"
            or checkpoint["playbackRequestedActive"] is not True
            or checkpoint["native"]["liveOutputCount"] <= 0
            for checkpoint in active_checkpoints
        )
        or after_final["playerState"] != "idle"
        or after_final["playbackRequestedActive"] is not False
    ):
        raise QualificationPolicyError(f"{description} player lifecycle is invalid")
    natives = tuple(checkpoint["native"] for checkpoint in checkpoints.values())
    first_native, both_native, after_first_native, after_final_native = natives
    if (
        [
            first_native["brokerActiveOwnerCount"],
            both_native["brokerActiveOwnerCount"],
            after_first_native["brokerActiveOwnerCount"],
            after_final_native["brokerActiveOwnerCount"],
        ]
        != [1, 2, 1, 0]
        or any(native["brokerLiveLeaseCount"] != 0 for native in natives)
        or any(
            (
                native["brokerSuccessfulDeactivationCount"],
                native["brokerFailedDeactivationCount"],
            )
            != (
                baseline["brokerSuccessfulDeactivationCount"],
                baseline["brokerFailedDeactivationCount"],
            )
            for native in (first_native, both_native, after_first_native)
        )
        or after_final_native["brokerSuccessfulDeactivationCount"]
        != baseline["brokerSuccessfulDeactivationCount"] + 1
        or after_final_native["brokerFailedDeactivationCount"]
        != baseline["brokerFailedDeactivationCount"]
    ):
        raise QualificationPolicyError(
            f"{description} broker release sequence is invalid"
        )
    for output in ("firstOutput", "secondOutput"):
        start = _apple_audio_playback(
            cycle[f"{output}PlaybackStart"], f"{description} {output} start"
        )
        end = _apple_audio_playback(
            cycle[f"{output}PlaybackEnd"], f"{description} {output} end"
        )
        if (
            end["mediaTimeMilliseconds"] <= start["mediaTimeMilliseconds"]
            or end["playedAudioBuffers"] <= start["playedAudioBuffers"]
        ):
            raise QualificationPolicyError(f"{description} {output} did not advance")
    return after_final_native, natives


def _validate_apple_audio_application_ownership_cycle(
    value: object,
    *,
    description: str,
    expected_module: str,
    expected_session: dict,
    expected_ownership: dict,
) -> tuple[dict, ...]:
    cycle = _exact_object(
        value,
        APPLE_AUDIO_APPLICATION_OWNERSHIP_CYCLE_KEYS,
        description,
    )
    if cycle["forcedAudioOutputModule"] != expected_module:
        raise QualificationPolicyError(f"{description} forced module is invalid")
    sessions = tuple(
        _apple_audio_session_configuration(cycle[key], f"{description} {key}")
        for key in (
            "sessionBeforePlayback",
            "sessionDuringPlayback",
            "sessionAfterPlayback",
        )
    )
    if any(session != expected_session for session in sessions):
        raise QualificationPolicyError(f"{description} mutated the host session")
    brokers = tuple(
        _apple_audio_native_snapshot(cycle[key], f"{description} {key}")
        for key in (
            "brokerBeforePlayback",
            "brokerDuringPlayback",
            "brokerAfterPlayback",
        )
    )
    _, during, _ = brokers
    if (
        any(
            _audio_ownership_tuple(broker) != _audio_ownership_tuple(expected_ownership)
            for broker in brokers
        )
        or during["liveOutputCount"] <= 0
    ):
        raise QualificationPolicyError(f"{description} touched broker ownership")
    start = _apple_audio_playback(cycle["playbackStart"], f"{description} start")
    end = _apple_audio_playback(cycle["playbackEnd"], f"{description} end")
    if (
        end["mediaTimeMilliseconds"] <= start["mediaTimeMilliseconds"]
        or end["playedAudioBuffers"] <= start["playedAudioBuffers"]
    ):
        raise QualificationPolicyError(f"{description} did not play")
    return brokers


def validate_audio_session_ownership_evidence(
    evidence: dict,
    *,
    retained_base: Path | None,
    require_retained: bool,
    expected_probe_bundle_identifier: str = CANONICAL_TEST_RUNNER_BUNDLE_IDENTIFIER,
) -> None:
    scenario_id = "audio-session-ownership"
    _validate_raw_evidence_shape(
        evidence,
        APPLE_AUDIO_OWNERSHIP_RAW_KEYS,
        scenario_id,
        duration_is_host_owned=True,
    )
    if (
        _integer(evidence.get("formatVersion"), "audio ownership formatVersion") != 3
        or evidence.get("scenario") != scenario_id
        or evidence.get("libraryManagedForcedModules")
        != ["audiounit_ios", "avsamplebuffer"]
        or evidence.get("applicationManagedForcedModules")
        != ["audiounit_ios", "avsamplebuffer"]
        or evidence.get("idleConstruction") != "pass"
        or evidence.get("multiOwnerRelease") != "pass"
        or evidence.get("survivingOutputContinuity") != "pass"
        or evidence.get("finalDeactivation") != "pass"
        or evidence.get("applicationManagedNonMutation") != "pass"
        or _integer(evidence.get("libraryErrorCount"), "audio ownership library errors")
        != 0
    ):
        raise QualificationPolicyError("audio ownership attachment header is invalid")

    interruption_value = evidence.get("interruptionNotificationSequence")
    if not isinstance(interruption_value, list) or len(interruption_value) != 4:
        raise QualificationPolicyError(
            "audio ownership interruption notification set is not exact"
        )
    interruption_notifications: list[dict] = []
    for index, value in enumerate(interruption_value):
        notification = _exact_object(
            value,
            APPLE_AUDIO_INTERRUPTION_NOTIFICATION_KEYS,
            f"audio ownership interruption notification {index}",
        )
        if (
            notification["kind"] not in {"began", "ended"}
            or _integer(
                notification["reasonRawValue"],
                f"audio ownership interruption notification {index} reason",
            )
            != 0
            or _finite_number(
                notification["systemUptime"],
                f"audio ownership interruption notification {index} uptime",
            )
            <= 0
        ):
            raise QualificationPolicyError(
                f"audio ownership interruption notification {index} is invalid"
            )
        interruption_notifications.append(notification)

    idle_session_before = _apple_audio_session_configuration(
        evidence.get("idleSessionBeforePlayerConstruction"),
        "idle session before player construction",
    )
    idle_session_after = _apple_audio_session_configuration(
        evidence.get("idleSessionAfterPlayerConstruction"),
        "idle session after player construction",
    )
    if idle_session_before != idle_session_after:
        raise QualificationPolicyError(
            "idle player construction mutated AVAudioSession"
        )
    idle_before = _apple_audio_native_snapshot(
        evidence.get("idleBrokerBeforePlayerConstruction"), "idle broker before"
    )
    idle_after = _apple_audio_native_snapshot(
        evidence.get("idleBrokerAfterPlayerConstruction"), "idle broker after"
    )
    # liveOutputCount belongs to the checkpoint player, which can retain an
    # idle module object (including the probe used after other players exit).
    # Focus is proven by global owners/leases and the external focus probe.
    if any(
        snapshot["brokerActiveOwnerCount"] != 0
        or snapshot["brokerLiveLeaseCount"] != 0
        for snapshot in (idle_before, idle_after)
    ) or _audio_ownership_tuple(idle_after) != _audio_ownership_tuple(idle_before):
        raise QualificationPolicyError("idle player construction acquired audio focus")

    library_cycles_value = evidence.get("libraryManagedCycles")
    expected_orders = (
        ["audiounit_ios", "avsamplebuffer"],
        ["avsamplebuffer", "audiounit_ios"],
    )
    if not isinstance(library_cycles_value, list) or len(library_cycles_value) != 2:
        raise QualificationPolicyError("audio ownership library cycle set is not exact")
    ownership_baseline = idle_after
    all_broker_snapshots: list[dict] = [idle_before, idle_after]
    # Each collection is checked for the exact expected length immediately
    # above, so plain zip retains fail-closed cardinality on Xcode's Python 3.9
    # as well as newer GitHub-hosted runtimes.
    for index, (cycle, expected_order) in enumerate(
        zip(library_cycles_value, expected_orders)
    ):
        ownership_baseline, snapshots = _validate_apple_audio_library_ownership_cycle(
            cycle,
            description=f"library-managed cycle {index}",
            expected_order=expected_order,
            baseline=ownership_baseline,
        )
        all_broker_snapshots.extend(snapshots)

    application_cycles_value = evidence.get("applicationManagedCycles")
    expected_application_modules = ("audiounit_ios", "avsamplebuffer")
    if (
        not isinstance(application_cycles_value, list)
        or len(application_cycles_value) != 2
    ):
        raise QualificationPolicyError(
            "audio ownership application-managed cycle set is not exact"
        )
    first_application = _exact_object(
        application_cycles_value[0],
        APPLE_AUDIO_APPLICATION_OWNERSHIP_CYCLE_KEYS,
        "application-managed cycle 0",
    )
    application_session = _apple_audio_session_configuration(
        first_application["sessionBeforePlayback"],
        "application-managed reference session",
    )
    if (
        application_session["category"] != "AVAudioSessionCategoryPlayback"
        or application_session["mode"] != "AVAudioSessionModeSpokenAudio"
        or application_session["categoryOptionsRawValue"] != 0
        or application_session["routeSharingPolicyRawValue"] != 1
    ):
        raise QualificationPolicyError(
            "application-managed AVAudioSession configuration is invalid"
        )
    for index, (cycle, expected_module) in enumerate(
        zip(application_cycles_value, expected_application_modules)
    ):
        all_broker_snapshots.extend(
            _validate_apple_audio_application_ownership_cycle(
                cycle,
                description=f"application-managed cycle {index}",
                expected_module=expected_module,
                expected_session=application_session,
                expected_ownership=ownership_baseline,
            )
        )

    broker_epochs = {
        (snapshot["brokerEpoch"], snapshot["brokerResetEpoch"])
        for snapshot in all_broker_snapshots
    }
    if (
        any(snapshot["brokerPhase"] != "ready" for snapshot in all_broker_snapshots)
        or len(broker_epochs) != 1
    ):
        raise QualificationPolicyError("audio ownership broker epoch is incoherent")

    focus_probes = [
        _validate_apple_audio_focus_probe(
            evidence.get("idleConstructionFocusProbe"),
            description="idle construction focus probe",
            expected_phase="idle-constructed-awaiting-focus-probe",
            expected_before=(0, 0),
            expected_delta=0,
            expected_outcome="candidate-session-released",
            expected_probe_bundle_identifier=expected_probe_bundle_identifier,
        )
    ]
    library_focus = evidence.get("libraryReleaseFocusProbes")
    if not isinstance(library_focus, list) or len(library_focus) != 2:
        raise QualificationPolicyError("library release focus probe set is not exact")
    for index, (probe, expected_order) in enumerate(
        zip(library_focus, expected_orders)
    ):
        focus_probes.append(
            _validate_apple_audio_focus_probe(
                probe,
                description=f"library release focus probe {index}",
                expected_phase=f"library-order{index + 1}-released-awaiting-focus-probe",
                expected_before=(0, 0),
                expected_delta=0,
                expected_outcome="candidate-session-released",
                expected_probe_bundle_identifier=expected_probe_bundle_identifier,
                extra_fields={"forcedModuleOrder": expected_order},
            )
        )
    application_focus = evidence.get("applicationManagedReleaseFocusProbes")
    if not isinstance(application_focus, list) or len(application_focus) != 2:
        raise QualificationPolicyError(
            "application-managed release focus probe set is not exact"
        )
    for index, (probe, module) in enumerate(
        zip(application_focus, expected_application_modules)
    ):
        phase_module = "audiounit" if module == "audiounit_ios" else "avsamplebuffer"
        focus_probes.append(
            _validate_apple_audio_focus_probe(
                probe,
                description=f"application-managed release focus probe {index}",
                expected_phase=(
                    f"application-{phase_module}-released-awaiting-focus-probe"
                ),
                expected_before=(index, index),
                expected_delta=1,
                expected_outcome="candidate-session-active-after-output-teardown",
                expected_probe_bundle_identifier=expected_probe_bundle_identifier,
                extra_fields={"forcedAudioOutputModule": module},
            )
        )
    focus_probes.append(
        _validate_apple_audio_focus_probe(
            evidence.get("hostReleaseFocusProbe"),
            description="host release focus probe",
            expected_phase="complete-awaiting-host-release-focus-probe",
            expected_before=(2, 2),
            expected_delta=0,
            expected_outcome="candidate-session-released",
            expected_probe_bundle_identifier=expected_probe_bundle_identifier,
        )
    )
    _validate_apple_audio_focus_probe_causality(
        focus_probes, interruption_notifications
    )
    producer = evidence.get("qualificationProducer")
    _validate_apple_audio_source_request_proof(
        evidence.get("sourceRequestProof"),
        description="audio ownership source request proof",
        token_kind="ownership",
        runner_scenario="audio-session-ownership",
        minimum_successful_segments=6,
        retained_base=retained_base,
        require_retained=require_retained,
        expected_source_attempt=(
            producer.get("sourceAttempt") if isinstance(producer, dict) else None
        ),
    )
    _validate_apple_audio_output_logs(
        evidence,
        {
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
        },
        retained_base=retained_base,
        require_retained=require_retained,
    )


def _visual_observations(
    evidence: dict,
    *,
    record_keys: set[str],
    description: str,
) -> list[dict]:
    container = _exact_object(
        evidence.get("visualObservations"),
        {"formatVersion", "method", "records"},
        f"{description} visualObservations",
    )
    if (
        container["formatVersion"] != 1
        or container["method"] != VISUAL_OBSERVATION_METHOD
        or not isinstance(container["records"], list)
        or not container["records"]
    ):
        raise QualificationPolicyError(
            f"{description} raw visual observation contract changed"
        )
    records: list[dict] = []
    for index, item in enumerate(container["records"]):
        record = _exact_object(
            item, record_keys, f"{description} visual observation {index}"
        )
        hashes = record.get("frameHashes")
        ratios = record.get("adjacentChangedPixelRatios")
        score = _finite_number(
            record.get("changedPixelScore"),
            f"{description} visual observation {index} changed-pixel score",
        )
        if (
            not isinstance(hashes, list)
            or len(hashes) < 3
            or any(
                not isinstance(value, str) or not SHA256.fullmatch(value)
                for value in hashes
            )
            or len(set(hashes)) != len(hashes)
            or not isinstance(ratios, list)
            or len(ratios) != len(hashes) - 1
            or any(
                isinstance(value, bool)
                or not isinstance(value, (int, float))
                or not math.isfinite(float(value))
                or float(value) < 0
                or float(value) > 1
                for value in ratios
            )
            or abs(score - min(float(value) for value in ratios)) > 0.000001
            or score < 0
            or score > 1
        ):
            raise QualificationPolicyError(
                f"{description} visual observation {index} has invalid raw frames"
            )
        records.append(record)
    return records


_VISUAL_FRAME_WIDTH = 64
_VISUAL_FRAME_HEIGHT = 36
_VISUAL_FRAME_CHANNELS = 3
_VISUAL_FRAME_BYTE_COUNT = (
    _VISUAL_FRAME_WIDTH * _VISUAL_FRAME_HEIGHT * _VISUAL_FRAME_CHANNELS
)
_VISUAL_HASH_DOMAIN = b"swiftvlc-rgb8-64x36-v1\0"
_VISUAL_CHANGED_CHANNEL_DELTA = 12


def _canonical_visual_frame_hash(frame: bytes) -> str:
    payload = (
        _VISUAL_HASH_DOMAIN
        + _VISUAL_FRAME_WIDTH.to_bytes(2, "big")
        + _VISUAL_FRAME_HEIGHT.to_bytes(2, "big")
        + frame
    )
    return hashlib.sha256(payload).hexdigest()


def _canonical_visual_changed_pixel_ratio(first: bytes, second: bytes) -> float:
    changed = 0
    for offset in range(0, _VISUAL_FRAME_BYTE_COUNT, _VISUAL_FRAME_CHANNELS):
        if (
            max(
                abs(first[offset + channel] - second[offset + channel])
                for channel in range(_VISUAL_FRAME_CHANNELS)
            )
            >= _VISUAL_CHANGED_CHANNEL_DELTA
        ):
            changed += 1
    return changed / (_VISUAL_FRAME_WIDTH * _VISUAL_FRAME_HEIGHT)


def _decode_canonical_visual_frame(value: object, description: str) -> bytes:
    if not isinstance(value, str) or not value:
        raise QualificationPolicyError(f"{description} must be nonempty base64")
    try:
        frame = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError) as error:
        raise QualificationPolicyError(
            f"{description} is not canonical base64"
        ) from error
    if (
        len(frame) != _VISUAL_FRAME_BYTE_COUNT
        or base64.b64encode(frame).decode("ascii") != value
    ):
        raise QualificationPolicyError(
            f"{description} is not one canonical 64x36 RGB8 frame"
        )
    return frame


def _local_playback_raw_fixture(expected: dict, kind: str) -> dict:
    return {
        "id": expected["id"],
        "kind": kind,
        "relativePath": expected["path"],
        "container": expected["container"],
        "videoCodec": expected.get("videoCodec"),
        "audioCodec": expected["audioCodec"],
        "width": expected.get("width"),
        "height": expected.get("height"),
        "framesPerSecond": expected.get("framesPerSecond"),
        "sampleRate": expected["sampleRate"],
        "channels": expected["channels"],
    }


def _local_playback_manifest_files(
    evidence: dict,
    retained_base: Path | None,
    *,
    require_retained: bool,
) -> dict[str, dict] | None:
    checksum = evidence.get("fixtureManifestChecksum")
    if not isinstance(checksum, str) or not SHA256.fullmatch(checksum):
        raise QualificationPolicyError(
            "local playback evidence has no candidate-bound fixture manifest checksum"
        )
    if retained_base is None:
        if require_retained:
            raise QualificationPolicyError(
                "local playback evidence has no retained fixture manifest root"
            )
        return None
    manifest_path = safe_relative_file(
        retained_base,
        "fixture-manifest.json",
        "local playback retained fixture manifest",
    )
    if sha256_file(manifest_path) != checksum:
        raise QualificationPolicyError(
            "local playback retained fixture manifest digest mismatch"
        )
    manifest = load_json(manifest_path, "local playback retained fixture manifest")
    if (
        manifest.get("formatVersion") != 1
        or not _json_same(
            manifest.get("localPlayback"), LOCAL_PLAYBACK_FIXTURE_CONTRACT
        )
        or not isinstance(manifest.get("files"), dict)
    ):
        raise QualificationPolicyError(
            "local playback retained fixture manifest contract changed"
        )
    expected_paths = {
        fixture["path"]
        for kind in ("video", "audio")
        for fixture in LOCAL_PLAYBACK_FIXTURE_CONTRACT[kind]
    }
    manifest_paths = {
        path
        for path in manifest["files"]
        if isinstance(path, str) and path.startswith("local-playback/")
    }
    if manifest_paths != expected_paths:
        raise QualificationPolicyError(
            "local playback retained fixture manifest file set changed"
        )
    for relative in sorted(expected_paths):
        record = _exact_object(
            manifest["files"].get(relative),
            {"bytes", "sha256"},
            f"local playback manifest file {relative}",
        )
        if (
            _integer(record["bytes"], f"local playback manifest file {relative} size")
            <= 0
            or not isinstance(record["sha256"], str)
            or not SHA256.fullmatch(record["sha256"])
        ):
            raise QualificationPolicyError(
                f"local playback manifest file {relative} binding is invalid"
            )
    return manifest["files"]


def _validate_local_playback_visual(
    value: object,
    description: str,
    *,
    measurement_start: float,
    measurement_end: float,
) -> None:
    visual = _exact_object(value, LOCAL_PLAYBACK_VISUAL_KEYS, description)
    encoded_frames = visual["canonicalRGB8Base64"]
    capture_times = visual["captureSystemUptimeSeconds"]
    if (
        visual["formatVersion"] != 1
        or visual["method"] != VISUAL_OBSERVATION_METHOD
        or visual["encoding"] != "base64-rgb8-row-major"
        or visual["frameWidthPixels"] != _VISUAL_FRAME_WIDTH
        or visual["frameHeightPixels"] != _VISUAL_FRAME_HEIGHT
        or visual["channelCount"] != _VISUAL_FRAME_CHANNELS
        or visual["bytesPerFrame"] != _VISUAL_FRAME_BYTE_COUNT
        or visual["frameCount"] != 3
        or not isinstance(encoded_frames, list)
        or len(encoded_frames) != 3
        or not isinstance(capture_times, list)
        or len(capture_times) != 3
    ):
        raise QualificationPolicyError(f"{description} contract changed")
    times = [
        _finite_number(value, f"{description} capture time {index}")
        for index, value in enumerate(capture_times)
    ]
    if any(
        current <= previous or current - previous < 0.1 or current - previous > 2
        for previous, current in zip(times, times[1:])
    ) or any(not (measurement_start < value < measurement_end) for value in times):
        raise QualificationPolicyError(
            f"{description} capture times are not inside the native counter window"
        )
    frames = [
        _decode_canonical_visual_frame(value, f"{description} frame {index}")
        for index, value in enumerate(encoded_frames)
    ]
    hashes = [_canonical_visual_frame_hash(frame) for frame in frames]
    ratios = [
        _canonical_visual_changed_pixel_ratio(first, second)
        for first, second in zip(frames, frames[1:])
    ]
    score = min(ratios)
    reported_hashes = visual["frameHashes"]
    reported_ratios = visual["adjacentChangedPixelRatios"]
    if (
        reported_hashes != hashes
        or len(set(hashes)) != 3
        or visual["distinctFrameHashes"] != 3
        or not isinstance(reported_ratios, list)
        or len(reported_ratios) != 2
        or any(
            isinstance(value, bool) or not isinstance(value, (int, float))
            for value in reported_ratios
        )
        or any(
            abs(float(observed) - expected) > 1e-12
            for observed, expected in zip(reported_ratios, ratios)
        )
        or abs(
            _finite_number(visual["changedPixelScore"], f"{description} score") - score
        )
        > 1e-12
        or score < 0.01
    ):
        raise QualificationPolicyError(
            f"{description} raw pixels do not replay sustained motion"
        )


def _validate_local_playback_snapshot(value: object, description: str) -> dict:
    snapshot = _exact_object(value, LOCAL_PLAYBACK_COUNTER_KEYS, description)
    for key in LOCAL_PLAYBACK_COUNTER_KEYS:
        if _integer(snapshot[key], f"{description} {key}") < 0:
            raise QualificationPolicyError(f"{description} {key} cannot be negative")
    return snapshot


def validate_local_playback_evidence(
    evidence: dict,
    scenario_id: str,
    *,
    retained_base: Path | None,
    require_retained: bool,
) -> None:
    kind = "video" if scenario_id == "local-file-matrix" else "audio"
    _validate_raw_evidence_shape(
        evidence,
        LOCAL_PLAYBACK_RAW_EVIDENCE_KEYS,
        scenario_id,
        duration_is_host_owned=True,
    )
    if (
        evidence.get("formatVersion") != 1
        or evidence.get("scenario") != scenario_id
        or evidence.get("matrixOutcome") != "pass"
        or evidence.get("libraryErrorCount") != 0
    ):
        raise QualificationPolicyError(
            f"{scenario_id} raw attachment header is invalid"
        )
    manifest_files = _local_playback_manifest_files(
        evidence, retained_base, require_retained=require_retained
    )
    expected_fixtures = LOCAL_PLAYBACK_FIXTURE_CONTRACT[kind]
    results = evidence.get("fixtureResults")
    if not isinstance(results, list) or len(results) != len(expected_fixtures):
        raise QualificationPolicyError(
            f"{scenario_id} must retain every canonical {kind} fixture exactly once"
        )
    prior_measurement_end: float | None = None
    for index, (value, expected_fixture) in enumerate(zip(results, expected_fixtures)):
        description = f"{scenario_id} fixture result {index}"
        expected_keys = set(LOCAL_PLAYBACK_RESULT_KEYS)
        if kind == "video":
            expected_keys.add("visualCapture")
        result = _exact_object(value, expected_keys, description)
        if not _json_same(
            result["fixture"], _local_playback_raw_fixture(expected_fixture, kind)
        ):
            raise QualificationPolicyError(
                f"{description} differs from the immutable fixture contract"
            )
        relative_path = expected_fixture["path"]
        if (
            result["sourceScheme"] != "file"
            or result["localFileName"] != relative_path.replace("/", "-")
            or not isinstance(result["downloadedSHA256"], str)
            or not SHA256.fullmatch(result["downloadedSHA256"])
            or _integer(result["downloadedBytes"], f"{description} downloaded bytes")
            <= 0
        ):
            raise QualificationPolicyError(
                f"{description} does not prove a canonical local file source"
            )
        if manifest_files is not None:
            binding = manifest_files[relative_path]
            if (
                result["downloadedSHA256"] != binding["sha256"]
                or result["downloadedBytes"] != binding["bytes"]
            ):
                raise QualificationPolicyError(
                    f"{description} downloaded bytes differ from the retained manifest"
                )
        before_match = re.fullmatch(
            r"generation ([0-9]+)", str(result["generationBefore"])
        )
        after_match = re.fullmatch(
            r"generation ([0-9]+)", str(result["generationAfter"])
        )
        if (
            before_match is None
            or after_match is None
            or int(after_match.group(1)) != int(before_match.group(1)) + 1
        ):
            raise QualificationPolicyError(
                f"{description} media generation did not advance exactly once"
            )
        states = result["stateSequence"]
        allowed_states = {
            "idle",
            "opening",
            "buffering",
            "playing",
            "paused",
            "stopping",
            "stopped",
            "error",
        }
        if (
            not isinstance(states, list)
            or not states
            or len(states) > 8
            or any(
                not isinstance(state, str) or state not in allowed_states
                for state in states
            )
            or "playing" not in states
            or "error" in states
        ):
            raise QualificationPolicyError(
                f"{description} has no healthy native player state sequence"
            )
        duration = _integer(
            result["durationMilliseconds"], f"{description} media duration"
        )
        measurement = _integer(
            result["measurementDurationMilliseconds"],
            f"{description} measurement duration",
        )
        measurement_start = _finite_number(
            result["measurementStartSystemUptime"],
            f"{description} measurement start uptime",
        )
        measurement_end = _finite_number(
            result["measurementEndSystemUptime"],
            f"{description} measurement end uptime",
        )
        if (
            duration < 10_000
            or duration > 13_500
            or measurement < 3_000
            or measurement > 6_000
            or measurement_end <= measurement_start
            or abs((measurement_end - measurement_start) * 1000 - measurement) > 250
            or (
                prior_measurement_end is not None
                and measurement_start <= prior_measurement_end
            )
        ):
            raise QualificationPolicyError(
                f"{description} duration/measurement contract is invalid"
            )
        prior_measurement_end = measurement_end
        start = _validate_local_playback_snapshot(
            result["start"], f"{description} start"
        )
        end = _validate_local_playback_snapshot(result["end"], f"{description} end")
        monotonic_keys = LOCAL_PLAYBACK_COUNTER_KEYS - {"timeMilliseconds"}
        if (
            any(end[key] < start[key] for key in monotonic_keys)
            or end["timeMilliseconds"] - start["timeMilliseconds"] < 2_000
            or end["timeMilliseconds"] - start["timeMilliseconds"] > measurement + 1_000
            or end["timeMilliseconds"] > duration + 500
            or end["readBytes"] <= 0
            or end["demuxReadBytes"] <= 0
        ):
            raise QualificationPolicyError(
                f"{description} native clock/input counters did not progress"
            )
        played = end["playedAudioBuffers"] - start["playedAudioBuffers"]
        lost_audio = end["lostAudioBuffers"] - start["lostAudioBuffers"]
        if end["decodedAudio"] <= 0 or played < 5 or lost_audio > max(1, played // 20):
            raise QualificationPolicyError(
                f"{description} native audio decode/output did not progress cleanly"
            )
        if kind == "video":
            displayed = end["displayedPictures"] - start["displayedPictures"]
            lost_pictures = end["lostPictures"] - start["lostPictures"]
            if (
                end["decodedVideo"] <= 0
                or displayed < 10
                or lost_pictures > max(3, displayed // 5)
            ):
                raise QualificationPolicyError(
                    f"{description} native video decode/display did not progress cleanly"
                )
            _validate_local_playback_visual(
                result["visualCapture"],
                f"{description} visual capture",
                measurement_start=measurement_start,
                measurement_end=measurement_end,
            )
        elif any(
            result_snapshot[key] != 0
            for result_snapshot in (start, end)
            for key in ("decodedVideo", "displayedPictures", "lostPictures")
        ):
            raise QualificationPolicyError(
                f"{description} audio-only fixture unexpectedly produced video"
            )


def _progressive_manifest_binding(
    evidence: dict,
    retained_base: Path | None,
    *,
    require_retained: bool,
) -> dict | None:
    checksum = evidence.get("fixtureManifestChecksum")
    if not isinstance(checksum, str) or not SHA256.fullmatch(checksum):
        raise QualificationPolicyError(
            "progressive HTTP evidence has no candidate-bound fixture manifest checksum"
        )
    if retained_base is None:
        if require_retained:
            raise QualificationPolicyError(
                "progressive HTTP evidence has no retained fixture manifest root"
            )
        return None
    manifest_path = safe_relative_file(
        retained_base,
        "fixture-manifest.json",
        "progressive HTTP retained fixture manifest",
    )
    if sha256_file(manifest_path) != checksum:
        raise QualificationPolicyError(
            "progressive HTTP retained fixture manifest digest mismatch"
        )
    manifest = load_json(manifest_path, "progressive HTTP retained fixture manifest")
    if (
        manifest.get("formatVersion") != 1
        or not isinstance(manifest.get("oracles"), dict)
        or not _json_same(
            manifest["oracles"].get("progressiveHTTPRange"),
            PROGRESSIVE_HTTP_RANGE_FIXTURE_CONTRACT,
        )
        or not isinstance(manifest.get("files"), dict)
    ):
        raise QualificationPolicyError(
            "progressive HTTP retained fixture contract changed"
        )
    path = PROGRESSIVE_HTTP_RANGE_FIXTURE_CONTRACT["path"]
    binding = _exact_object(
        manifest["files"].get(path),
        {"bytes", "sha256"},
        "progressive HTTP manifest file",
    )
    if (
        _integer(binding["bytes"], "progressive HTTP manifest file size")
        < PROGRESSIVE_HTTP_RANGE_FIXTURE_CONTRACT["minimumBytes"]
        or not isinstance(binding["sha256"], str)
        or not SHA256.fullmatch(binding["sha256"])
    ):
        raise QualificationPolicyError(
            "progressive HTTP manifest file binding is invalid"
        )
    return binding


def _validate_progressive_snapshot(value: object, description: str) -> dict:
    snapshot = _exact_object(value, PROGRESSIVE_HTTP_RANGE_COUNTER_KEYS, description)
    uptime = _finite_number(
        snapshot["systemUptimeSeconds"], f"{description} system uptime"
    )
    if uptime <= 0 or snapshot["state"] != "playing":
        raise QualificationPolicyError(f"{description} is not active playback")
    if (
        not isinstance(snapshot["playbackGeneration"], str)
        or re.fullmatch(r"generation [1-9][0-9]*", snapshot["playbackGeneration"])
        is None
    ):
        raise QualificationPolicyError(f"{description} playback generation is invalid")
    for key in PROGRESSIVE_HTTP_RANGE_COUNTER_KEYS - {
        "systemUptimeSeconds",
        "playbackGeneration",
        "state",
        "isSeekable",
    }:
        if _integer(snapshot[key], f"{description} {key}") < 0:
            raise QualificationPolicyError(f"{description} {key} cannot be negative")
    if not isinstance(snapshot["isSeekable"], bool):
        raise QualificationPolicyError(f"{description} seekability is not boolean")
    if not 119_500 <= snapshot["durationMilliseconds"] <= 120_500:
        raise QualificationPolicyError(f"{description} duration is not canonical")
    return snapshot


def _progressive_frame_band_and_time(frame: bytes) -> tuple[int, float]:
    colors = [
        (0xC0, 0x20, 0x20),
        (0x20, 0xA0, 0x40),
        (0x20, 0x40, 0xC0),
        (0xC0, 0xA0, 0x20),
        (0xA0, 0x20, 0xA0),
        (0x20, 0xA0, 0xA0),
    ]

    def pixel(x: int, y: int) -> tuple[int, int, int]:
        offset = (y * _VISUAL_FRAME_WIDTH + x) * _VISUAL_FRAME_CHANNELS
        return frame[offset], frame[offset + 1], frame[offset + 2]

    samples = [pixel(x, y) for y in range(2, 7) for x in range(3, 61)]
    background = tuple(
        sum(value[channel] for value in samples) / len(samples) for channel in range(3)
    )

    def distance(first: Sequence[float], second: Sequence[float]) -> float:
        return math.sqrt(sum((left - right) ** 2 for left, right in zip(first, second)))

    match_distance, band = min(
        (distance(background, color), index) for index, color in enumerate(colors)
    )
    if match_distance > 110:
        raise QualificationPolicyError(
            "progressive HTTP canonical pixels do not contain a declared seek band"
        )
    column_scores = [
        sum(distance(pixel(x, y), background) for y in range(10, 26)) / 16
        for x in range(_VISUAL_FRAME_WIDTH)
    ]
    marker_width = 2
    best_start = max(
        range(_VISUAL_FRAME_WIDTH - marker_width + 1),
        key=lambda start: sum(column_scores[start : start + marker_width]),
    )
    best_score = (
        sum(column_scores[best_start : best_start + marker_width]) / marker_width
    )
    if best_score < 45:
        raise QualificationPolicyError(
            "progressive HTTP canonical pixels contain no moving marker"
        )
    marker_x = best_start * 640 / _VISUAL_FRAME_WIDTH
    seconds_into_band = min(10.0, max(0.0, (marker_x - 40) / 56))
    indicator_samples = [pixel(x, y) for y in range(31, 33) for x in range(50, 58)]
    indicator = tuple(
        sum(value[channel] for value in indicator_samples) / len(indicator_samples)
        for channel in range(3)
    )
    white_distance = distance(indicator, (255, 255, 255))
    background_distance = distance(indicator, background)
    if white_distance <= 80 and background_distance > 80:
        cycle = 1
    elif background_distance <= 50 and white_distance > 80:
        cycle = 0
    else:
        raise QualificationPolicyError(
            "progressive HTTP canonical pixels have an ambiguous timeline cycle"
        )
    return (
        band,
        cycle
        * PROGRESSIVE_HTTP_RANGE_FIXTURE_CONTRACT["timelineCycleIndicator"][
            "secondHalfStartSeconds"
        ]
        + band * 10
        + seconds_into_band,
    )


def _validate_progressive_visual(
    value: object,
    description: str,
    *,
    range_mode: bool,
    measurement_start: float,
    measurement_start_media_seconds: float,
    measurement_end: float,
    measurement_end_media_seconds: float,
) -> None:
    visual = _exact_object(
        value,
        (
            PROGRESSIVE_HTTP_RANGE_VISUAL_KEYS
            if range_mode
            else PROGRESSIVE_HTTP_VISUAL_BASE_KEYS
        ),
        description,
    )
    encoded_frames = visual["canonicalRGB8Base64"]
    capture_intervals = visual["captureSystemUptimeIntervals"]
    if (
        visual["formatVersion"] != 1
        or visual["method"] != VISUAL_OBSERVATION_METHOD
        or visual["encoding"] != "base64-rgb8-row-major"
        or visual["frameWidthPixels"] != _VISUAL_FRAME_WIDTH
        or visual["frameHeightPixels"] != _VISUAL_FRAME_HEIGHT
        or visual["channelCount"] != _VISUAL_FRAME_CHANNELS
        or visual["bytesPerFrame"] != _VISUAL_FRAME_BYTE_COUNT
        or visual["frameCount"] != 3
        or not isinstance(encoded_frames, list)
        or len(encoded_frames) != 3
        or not isinstance(capture_intervals, list)
        or len(capture_intervals) != 3
    ):
        raise QualificationPolicyError(f"{description} contract changed")
    intervals: list[tuple[float, float]] = []
    for index, item in enumerate(capture_intervals):
        interval = _exact_object(
            item,
            PROGRESSIVE_HTTP_CAPTURE_INTERVAL_KEYS,
            f"{description} capture interval {index}",
        )
        start = _finite_number(
            interval["startSystemUptimeSeconds"],
            f"{description} capture interval {index} start",
        )
        end = _finite_number(
            interval["endSystemUptimeSeconds"],
            f"{description} capture interval {index} end",
        )
        if (
            not measurement_start < start < end < measurement_end
            or end - start > PROGRESSIVE_HTTP_MAXIMUM_CAPTURE_INTERVAL_SECONDS
        ):
            raise QualificationPolicyError(
                f"{description} capture interval {index} is unbounded"
            )
        intervals.append((start, end))
    if any(
        not 0.1 <= current_start - previous_end <= 2
        for (_, previous_end), (current_start, _) in zip(intervals, intervals[1:])
    ):
        raise QualificationPolicyError(
            f"{description} capture intervals are not ordered"
        )
    frames = [
        _decode_canonical_visual_frame(item, f"{description} frame {index}")
        for index, item in enumerate(encoded_frames)
    ]
    hashes = [_canonical_visual_frame_hash(frame) for frame in frames]
    ratios = [
        _canonical_visual_changed_pixel_ratio(first, second)
        for first, second in zip(frames, frames[1:])
    ]
    score = min(ratios)
    reported_ratios = visual["adjacentChangedPixelRatios"]
    if (
        visual["frameHashes"] != hashes
        or len(set(hashes)) != 3
        or visual["distinctFrameHashes"] != 3
        or not isinstance(reported_ratios, list)
        or len(reported_ratios) != 2
        or any(
            isinstance(item, bool) or not isinstance(item, (int, float))
            for item in reported_ratios
        )
        or any(
            abs(float(observed) - expected) > 1e-12
            for observed, expected in zip(reported_ratios, ratios)
        )
        or abs(
            _finite_number(visual["changedPixelScore"], f"{description} score") - score
        )
        > 1e-12
        or score < 0.01
    ):
        raise QualificationPolicyError(
            f"{description} raw pixels do not replay sustained motion"
        )
    observations = [_progressive_frame_band_and_time(frame) for frame in frames]
    bands = [band for band, _ in observations]
    timelines = [timeline for _, timeline in observations]
    reported_bands = visual["decodedBandIndices"]
    reported_timelines = visual["decodedTimelineSeconds"]
    if (
        not isinstance(reported_bands, list)
        or len(reported_bands) != 3
        or any(
            isinstance(item, bool) or not isinstance(item, int)
            for item in reported_bands
        )
        or not isinstance(reported_timelines, list)
        or len(reported_timelines) != 3
    ):
        raise QualificationPolicyError(f"{description} decoded timeline is malformed")
    reported_timeline_values = [
        _finite_number(item, f"{description} decoded timeline {index}")
        for index, item in enumerate(reported_timelines)
    ]
    expected_timeline_intervals = [
        (
            measurement_start_media_seconds + start - measurement_start,
            measurement_start_media_seconds + end - measurement_start,
        )
        for start, end in intervals
    ]
    tolerance = (
        PROGRESSIVE_HTTP_RANGE_FIXTURE_CONTRACT["seekToleranceMilliseconds"] / 1000
    )
    expected_end_media_seconds = measurement_start_media_seconds + (
        measurement_end - measurement_start
    )
    if (
        reported_bands != bands
        or any(
            abs(float(reported) - replayed) > 0.25
            for reported, replayed in zip(reported_timeline_values, timelines)
        )
        or range_mode
        and bands != [PROGRESSIVE_HTTP_RANGE_FIXTURE_CONTRACT["targetBandIndex"]] * 3
        or any(
            replayed < expected_start - tolerance or replayed > expected_end + tolerance
            for replayed, (expected_start, expected_end) in zip(
                timelines, expected_timeline_intervals
            )
        )
        or any(after <= before for before, after in zip(timelines, timelines[1:]))
        or abs(measurement_end_media_seconds - expected_end_media_seconds) > tolerance
        or measurement_end_media_seconds + tolerance < timelines[-1]
    ):
        raise QualificationPolicyError(
            f"{description} raw pixels and native clock do not share one timeline"
        )


def _validate_progressive_timestamp(value: object, description: str) -> datetime:
    if not isinstance(value, str):
        raise QualificationPolicyError(f"{description} is not an ISO-8601 timestamp")
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError as error:
        raise QualificationPolicyError(
            f"{description} is not an ISO-8601 timestamp"
        ) from error
    if parsed.tzinfo is None:
        raise QualificationPolicyError(f"{description} has no timezone")
    return parsed


def _validate_progressive_transcript(
    transcript: dict,
    *,
    token: str,
    fixture_bytes: int,
    final: bool,
) -> None:
    _exact_object(
        transcript, PROGRESSIVE_HTTP_TRANSCRIPT_KEYS, "progressive transcript"
    )
    events = transcript["events"]
    if (
        transcript["formatVersion"] != 1
        or transcript["token"] != token
        or transcript["fixtureRelativePath"]
        != PROGRESSIVE_HTTP_RANGE_FIXTURE_CONTRACT["path"]
        or transcript["fixtureBytes"] != fixture_bytes
        or not isinstance(events, list)
    ):
        raise QualificationPolicyError("progressive transcript header mismatch")
    prior_sequence = 0
    media_by_mode: dict[str, list[dict]] = {"range": [], "no-range": []}
    markers_by_mode: dict[str, list[dict]] = {"range": [], "no-range": []}
    media_started_at: dict[int, datetime] = {}
    marker_time_by_mode: dict[str, datetime] = {}
    for index, item in enumerate(events):
        if not isinstance(item, dict):
            raise QualificationPolicyError(
                f"progressive transcript event {index} is malformed"
            )
        kind = item.get("kind")
        keys = (
            PROGRESSIVE_HTTP_MEDIA_EVENT_KEYS
            if kind == "media-request"
            else (
                PROGRESSIVE_HTTP_COMMAND_EVENT_KEYS
                if kind == "command-marker"
                else set()
            )
        )
        event = _exact_object(item, keys, f"progressive transcript event {index}")
        sequence = _integer(event["sequence"], f"progressive event {index} sequence")
        mode = event["mode"]
        if (
            sequence != prior_sequence + 1
            or event["token"] != token
            or mode not in {"range", "no-range"}
        ):
            raise QualificationPolicyError(
                f"progressive transcript event {index} identity/order mismatch"
            )
        prior_sequence = sequence
        if kind == "command-marker":
            if (
                event["phase"] != "post-command"
                or event["origin"] != PROGRESSIVE_HTTP_COMMAND_ORIGIN
            ):
                raise QualificationPolicyError(
                    f"progressive command marker {index} has wrong origin/phase"
                )
            marker_time_by_mode[mode] = _validate_progressive_timestamp(
                event["markedAtUTC"], f"progressive command marker {index}"
            )
            if (
                _integer(
                    event["precommandRequestCount"],
                    f"progressive command marker {index} request count",
                )
                < 1
                or _integer(
                    event["precommandTransferredBytes"],
                    f"progressive command marker {index} byte count",
                )
                < 1
            ):
                raise QualificationPolicyError(
                    f"progressive command marker {index} has no pre-command transfer"
                )
            markers_by_mode[mode].append(event)
            continue
        if (
            event["phase"] not in {"pre-command", "post-command"}
            or event["method"] != "GET"
            or event["path"] != f"/progressive/{token}/{mode}/media.mp4"
            or event["fixtureRelativePath"]
            != PROGRESSIVE_HTTP_RANGE_FIXTURE_CONTRACT["path"]
            or event["requestRange"] is not None
            and (
                not isinstance(event["requestRange"], str)
                or re.fullmatch(r"bytes=\d*-\d*", event["requestRange"]) is None
            )
            or _integer(event["responseStatus"], f"progressive event {index} status")
            not in {200, 206, 416}
            or _integer(
                event["responseContentLength"],
                f"progressive event {index} content length",
            )
            < 0
            or _integer(
                event["transferredBytes"],
                f"progressive event {index} transferred bytes",
            )
            < 0
            or not isinstance(event["completed"], bool)
            or event["transferredBytesAtCommand"] is not None
            and (
                _integer(
                    event["transferredBytesAtCommand"],
                    f"progressive event {index} command byte snapshot",
                )
                < 0
                or event["transferredBytesAtCommand"] > event["transferredBytes"]
            )
        ):
            raise QualificationPolicyError(
                f"progressive transcript media event {index} is malformed"
            )
        started_at = _validate_progressive_timestamp(
            event["startedAtUTC"], f"progressive media event {index} start"
        )
        completed_at = _validate_progressive_timestamp(
            event["completedAtUTC"], f"progressive media event {index} completion"
        )
        if completed_at < started_at:
            raise QualificationPolicyError(
                f"progressive media event {index} completed before it started"
            )
        media_started_at[sequence] = started_at
        status = event["responseStatus"]
        if mode == "range":
            if event["acceptRanges"] != "bytes":
                raise QualificationPolicyError(
                    f"progressive Range event {index} omitted byte capability"
                )
            if status == 206:
                content_match = re.fullmatch(
                    rf"bytes (\d+)-(\d+)/{fixture_bytes}",
                    str(event["responseContentRange"]),
                )
                request_match = (
                    re.fullmatch(r"bytes=(\d+)-(\d*)", event["requestRange"])
                    if isinstance(event["requestRange"], str)
                    else None
                )
                if (
                    content_match is None
                    or request_match is None
                    or int(content_match.group(2)) < int(content_match.group(1))
                    or int(request_match.group(1)) != int(content_match.group(1))
                    or int(content_match.group(2))
                    != min(
                        (
                            int(request_match.group(2))
                            if request_match.group(2)
                            else fixture_bytes - 1
                        ),
                        fixture_bytes - 1,
                    )
                    or event["responseContentLength"]
                    != int(content_match.group(2)) - int(content_match.group(1)) + 1
                ):
                    raise QualificationPolicyError(
                        f"progressive Range event {index} has inconsistent 206"
                    )
            elif status == 200 and event["responseContentRange"] is not None:
                raise QualificationPolicyError(
                    f"progressive Range event {index} has unexpected content range"
                )
        elif (
            status != 200
            or event["acceptRanges"] is not None
            or event["responseContentRange"] is not None
            or event["responseContentLength"] != fixture_bytes
        ):
            raise QualificationPolicyError(
                f"progressive no-Range event {index} advertised range support"
            )
        if (
            event["completed"]
            and event["transferredBytes"] != event["responseContentLength"]
        ):
            raise QualificationPolicyError(
                f"progressive event {index} claims incomplete completed bytes"
            )
        if event["transferredBytes"] > event["responseContentLength"]:
            raise QualificationPolicyError(
                f"progressive event {index} transferred beyond response length"
            )
        media_by_mode[mode].append(event)

    if not final:
        return
    for mode in ("range", "no-range"):
        if len(markers_by_mode[mode]) != 1:
            raise QualificationPolicyError(
                f"final progressive transcript has no exact {mode} command marker"
            )
        marker_sequence = markers_by_mode[mode][0]["sequence"]
        precommand = [
            event for event in media_by_mode[mode] if event["phase"] == "pre-command"
        ]
        if (
            not precommand
            or any(event["sequence"] >= marker_sequence for event in precommand)
            or any(
                event["sequence"] <= marker_sequence
                for event in media_by_mode[mode]
                if event["phase"] == "post-command"
            )
            or any(event["transferredBytesAtCommand"] is None for event in precommand)
            or markers_by_mode[mode][0]["precommandRequestCount"] != len(precommand)
            or markers_by_mode[mode][0]["precommandTransferredBytes"]
            != sum(event["transferredBytesAtCommand"] for event in precommand)
            or markers_by_mode[mode][0]["precommandTransferredBytes"]
            >= PROGRESSIVE_HTTP_MAXIMUM_PRECOMMAND_BYTES
            or any(
                event["transferredBytesAtCommand"] >= fixture_bytes
                for event in precommand
            )
            or any(
                event["transferredBytesAtCommand"] is not None
                for event in media_by_mode[mode]
                if event["phase"] == "post-command"
            )
        ):
            raise QualificationPolicyError(
                f"final progressive {mode} traffic was prefetched or not phase-bound"
            )
    range_marker = markers_by_mode["range"][0]["sequence"]
    postcommand_ranges = sorted(
        (
            event
            for event in media_by_mode["range"]
            if event["phase"] == "post-command" and event["sequence"] > range_marker
        ),
        key=lambda event: event["sequence"],
    )
    first_range = postcommand_ranges[0] if postcommand_ranges else None
    match = (
        re.fullmatch(r"bytes=(\d+)-(\d*)", first_range["requestRange"])
        if first_range is not None and isinstance(first_range["requestRange"], str)
        else None
    )
    content = (
        re.fullmatch(
            rf"bytes (\d+)-(\d+)/{fixture_bytes}",
            str(first_range["responseContentRange"]),
        )
        if first_range is not None
        else None
    )
    if (
        first_range is None
        or first_range["responseStatus"] != 206
        or match is None
        or content is None
        or int(match.group(1)) != int(content.group(1))
        or int(match.group(1)) < PROGRESSIVE_HTTP_MINIMUM_SEEK_RANGE_START
        or first_range["transferredBytes"] <= 0
        or media_started_at[first_range["sequence"]] <= marker_time_by_mode["range"]
    ):
        raise QualificationPolicyError(
            "final progressive transcript first post-marker request is not the "
            "seek-caused 206"
        )
    if any(event["phase"] == "post-command" for event in media_by_mode["no-range"]):
        raise QualificationPolicyError(
            "final no-Range transcript shows a native media request after strict rejection"
        )


def _validate_progressive_server_transcripts(
    evidence: dict,
    retained_base: Path | None,
    *,
    require_retained: bool,
    fixture_bytes: int,
) -> set[tuple[str, ...]]:
    bindings = evidence.get("progressiveServerTranscripts")
    if not require_retained:
        if bindings is not None:
            raise QualificationPolicyError(
                "raw progressive attachment forged server transcript bindings"
            )
        return set()
    if retained_base is None:
        raise QualificationPolicyError(
            "progressive server transcripts have no retained root"
        )
    producer = evidence.get("qualificationProducer")
    final_attempt = (
        producer.get("sourceAttempt") if isinstance(producer, dict) else None
    )
    inventory = evidence.get("hostErrorInventory")
    final_token = inventory.get("logPrefix") if isinstance(inventory, dict) else None
    match = (
        re.fullmatch(r"(.+-attempt)(\d+)", final_token)
        if isinstance(final_token, str)
        else None
    )
    if (
        isinstance(final_attempt, bool)
        or not isinstance(final_attempt, int)
        or final_attempt < 1
        or match is None
        or int(match.group(2)) != final_attempt
        or evidence.get("attemptToken") != final_token
        or not isinstance(bindings, list)
        or len(bindings) != final_attempt
    ):
        raise QualificationPolicyError(
            "progressive transcript attempts are not bound to the final producer"
        )
    source_prefix = match.group(1).removesuffix("-attempt")
    transcript_namespace = (
        Path("progressive-http-range-seek-server-transcripts") / source_prefix
    )
    transcript_root = safe_relative_directory(
        retained_base,
        transcript_namespace.as_posix(),
        "progressive transcript inventory",
    )
    reject_tree_symlinks(transcript_root, "progressive transcript inventory")
    expected_names = {
        f"attempt-{attempt}.json" for attempt in range(1, final_attempt + 1)
    }
    entries = list(transcript_root.iterdir())
    if {entry.name for entry in entries} != expected_names or any(
        not entry.is_file() or entry.is_symlink() for entry in entries
    ):
        raise QualificationPolicyError(
            "progressive retained transcript file inventory is not exact"
        )
    fingerprints: set[tuple[str, ...]] = set()
    for expected_attempt, item in enumerate(bindings, 1):
        binding = _exact_object(
            item,
            PROGRESSIVE_HTTP_TRANSCRIPT_BINDING_KEYS,
            f"progressive transcript binding {expected_attempt}",
        )
        expected_token = f"{match.group(1)}{expected_attempt}"
        expected_relative = (
            f"{transcript_namespace.as_posix()}/attempt-{expected_attempt}.json"
        )
        if (
            binding["sourceAttempt"] != expected_attempt
            or binding["attemptToken"] != expected_token
            or binding["relativePath"] != expected_relative
            or binding["digestAlgorithm"] != "sha256"
            or not isinstance(binding["digest"], str)
            or not SHA256.fullmatch(binding["digest"])
            or _integer(binding["sizeBytes"], "progressive transcript size") <= 0
            or _integer(binding["eventCount"], "progressive transcript event count") < 0
        ):
            raise QualificationPolicyError(
                f"progressive transcript binding {expected_attempt} is malformed"
            )
        path = safe_relative_file(
            retained_base,
            expected_relative,
            f"progressive transcript attempt {expected_attempt}",
        )
        if (
            sha256_file(path) != binding["digest"]
            or path.stat().st_size != binding["sizeBytes"]
        ):
            raise QualificationPolicyError(
                f"progressive transcript attempt {expected_attempt} binding mismatch"
            )
        transcript = load_json(
            path, f"progressive transcript attempt {expected_attempt}"
        )
        if (
            not isinstance(transcript.get("events"), list)
            or len(transcript["events"]) != binding["eventCount"]
        ):
            raise QualificationPolicyError(
                f"progressive transcript attempt {expected_attempt} event count mismatch"
            )
        _validate_progressive_transcript(
            transcript,
            token=expected_token,
            fixture_bytes=fixture_bytes,
            final=expected_attempt == final_attempt,
        )
        fingerprint = ("progressive-server-transcript", binding["digest"])
        if fingerprint in fingerprints:
            raise QualificationPolicyError("progressive transcript bytes were reused")
        fingerprints.add(fingerprint)
    return fingerprints


def validate_progressive_http_range_evidence(
    evidence: dict,
    *,
    retained_base: Path | None,
    artifact_base: Path | None = None,
    require_retained: bool,
    require_host_artifacts: bool,
) -> set[tuple[str, ...]]:
    scenario_id = "progressive-http-range-seek"
    _validate_raw_evidence_shape(
        evidence,
        PROGRESSIVE_HTTP_RANGE_RAW_EVIDENCE_KEYS,
        scenario_id,
        duration_is_host_owned=True,
    )
    if (
        evidence.get("formatVersion") != 1
        or evidence.get("scenario") != scenario_id
        or evidence.get("libraryErrorCount") != 0
    ):
        raise QualificationPolicyError(
            "progressive HTTP raw attachment header is invalid"
        )
    token = evidence.get("attemptToken")
    if not isinstance(token, str) or re.fullmatch(r"[A-Za-z0-9._-]+", token) is None:
        raise QualificationPolicyError("progressive HTTP attempt token is invalid")
    manifest_binding = _progressive_manifest_binding(
        evidence, retained_base, require_retained=require_retained
    )
    fixture = _exact_object(
        evidence.get("fixture"),
        PROGRESSIVE_HTTP_RANGE_FIXTURE_KEYS,
        "progressive HTTP fixture",
    )
    if (
        fixture["id"] != "progressive-http-range-mp4"
        or fixture["relativePath"] != PROGRESSIVE_HTTP_RANGE_FIXTURE_CONTRACT["path"]
        or not isinstance(fixture["sha256"], str)
        or not SHA256.fullmatch(fixture["sha256"])
        or _integer(fixture["bytes"], "progressive HTTP fixture bytes")
        < PROGRESSIVE_HTTP_RANGE_FIXTURE_CONTRACT["minimumBytes"]
        or fixture["durationMilliseconds"] != 120_000
        or fixture["targetMilliseconds"]
        != PROGRESSIVE_HTTP_RANGE_FIXTURE_CONTRACT["seekTargetMilliseconds"]
        or fixture["landingBoundaryMilliseconds"]
        != PROGRESSIVE_HTTP_RANGE_FIXTURE_CONTRACT["landingBoundaryMilliseconds"]
        or manifest_binding is not None
        and (
            fixture["sha256"] != manifest_binding["sha256"]
            or fixture["bytes"] != manifest_binding["bytes"]
        )
    ):
        raise QualificationPolicyError(
            "progressive HTTP fixture differs from the retained manifest"
        )

    range_case = _exact_object(
        evidence.get("rangeCase"),
        PROGRESSIVE_HTTP_RANGE_SUCCESS_KEYS,
        "progressive HTTP Range case",
    )
    typed_seek = _exact_object(
        range_case["typedSeek"],
        PROGRESSIVE_HTTP_RANGE_TYPED_SEEK_KEYS,
        "progressive HTTP typed seek",
    )
    range_start = _validate_progressive_snapshot(
        range_case["start"], "progressive HTTP Range start"
    )
    range_landing = _validate_progressive_snapshot(
        range_case["landing"], "progressive HTTP Range landing"
    )
    range_end = _validate_progressive_snapshot(
        range_case["end"], "progressive HTTP Range end"
    )
    expected_range_path = f"/progressive/{token}/range/media.mp4"
    if (
        range_case["mode"] != "range"
        or range_case["attemptToken"] != token
        or range_case["sourcePath"] != expected_range_path
        or range_case["targetMilliseconds"] != fixture["targetMilliseconds"]
        or range_case["landingBoundaryMilliseconds"]
        != fixture["landingBoundaryMilliseconds"]
        or typed_seek
        != {
            "commandAttemptToken": token,
            "playbackGeneration": range_start["playbackGeneration"],
            "targetMilliseconds": fixture["targetMilliseconds"],
            "fast": False,
            "initialOutcome": "pending",
            "terminalOutcome": "settled",
        }
    ):
        raise QualificationPolicyError(
            "progressive HTTP Range typed seek contract changed"
        )
    monotonic = {
        "readBytes",
        "demuxReadBytes",
        "decodedVideo",
        "displayedPictures",
        "lostPictures",
    }
    if (
        not range_start["isSeekable"]
        or not range_landing["isSeekable"]
        or not range_end["isSeekable"]
        or range_start["currentTimeMilliseconds"]
        >= fixture["landingBoundaryMilliseconds"]
        or abs(range_landing["currentTimeMilliseconds"] - fixture["targetMilliseconds"])
        > PROGRESSIVE_HTTP_RANGE_FIXTURE_CONTRACT["seekToleranceMilliseconds"]
        or range_landing["currentTimeMilliseconds"]
        <= fixture["landingBoundaryMilliseconds"]
        or range_landing["displayedPictures"] <= range_start["displayedPictures"]
        or range_end["displayedPictures"] <= range_landing["displayedPictures"]
        or range_end["currentTimeMilliseconds"]
        <= range_landing["currentTimeMilliseconds"]
        or any(
            second[key] < first[key]
            for first, second in (
                (range_start, range_landing),
                (range_landing, range_end),
            )
            for key in monotonic
        )
        or not (
            range_start["systemUptimeSeconds"]
            < range_landing["systemUptimeSeconds"]
            < range_end["systemUptimeSeconds"]
        )
        or len(
            {
                range_start["playbackGeneration"],
                range_landing["playbackGeneration"],
                range_end["playbackGeneration"],
            }
        )
        != 1
    ):
        raise QualificationPolicyError(
            "progressive HTTP Range native clock/output did not settle"
        )
    _validate_progressive_visual(
        range_case["visualCapture"],
        "progressive HTTP Range visual capture",
        range_mode=True,
        measurement_start=range_landing["systemUptimeSeconds"],
        measurement_start_media_seconds=range_landing["currentTimeMilliseconds"] / 1000,
        measurement_end=range_end["systemUptimeSeconds"],
        measurement_end_media_seconds=range_end["currentTimeMilliseconds"] / 1000,
    )

    no_range_case = _exact_object(
        evidence.get("noRangeCase"),
        PROGRESSIVE_HTTP_NO_RANGE_SUCCESS_KEYS,
        "progressive HTTP no-Range case",
    )
    rejection = _exact_object(
        no_range_case["typedRejection"],
        PROGRESSIVE_HTTP_NO_RANGE_REJECTION_KEYS,
        "progressive HTTP no-Range rejection",
    )
    no_range_start = _validate_progressive_snapshot(
        no_range_case["start"], "progressive HTTP no-Range start"
    )
    no_range_end = _validate_progressive_snapshot(
        no_range_case["end"], "progressive HTTP no-Range end"
    )
    if (
        no_range_case["mode"] != "no-range"
        or no_range_case["attemptToken"] != token
        or no_range_case["sourcePath"] != f"/progressive/{token}/no-range/media.mp4"
        or no_range_case["targetMilliseconds"] != fixture["targetMilliseconds"]
        or no_range_case["seekableAtCommand"] is not False
        or rejection
        != {
            "commandAttemptToken": token,
            "playbackGeneration": no_range_start["playbackGeneration"],
            "errorDomain": "SwiftVLC.VLCError",
            "errorCase": "invalidState",
            "message": "current media is not seekable",
            "commandDispatched": False,
        }
    ):
        raise QualificationPolicyError(
            "progressive HTTP no-Range typed rejection contract changed"
        )
    if (
        no_range_start["isSeekable"]
        or no_range_end["isSeekable"]
        or no_range_end["currentTimeMilliseconds"]
        - no_range_start["currentTimeMilliseconds"]
        < 700
        or no_range_end["currentTimeMilliseconds"]
        >= fixture["landingBoundaryMilliseconds"]
        or no_range_end["displayedPictures"] - no_range_start["displayedPictures"] < 3
        or any(no_range_end[key] < no_range_start[key] for key in monotonic)
        or no_range_end["systemUptimeSeconds"] - no_range_start["systemUptimeSeconds"]
        < 0.7
        or no_range_end["playbackGeneration"] != no_range_start["playbackGeneration"]
    ):
        raise QualificationPolicyError(
            "progressive HTTP no-Range rejection did not preserve playback"
        )
    _validate_progressive_visual(
        no_range_case["visualCapture"],
        "progressive HTTP no-Range visual capture",
        range_mode=False,
        measurement_start=no_range_start["systemUptimeSeconds"],
        measurement_start_media_seconds=no_range_start["currentTimeMilliseconds"]
        / 1000,
        measurement_end=no_range_end["systemUptimeSeconds"],
        measurement_end_media_seconds=no_range_end["currentTimeMilliseconds"] / 1000,
    )
    return _validate_progressive_server_transcripts(
        evidence,
        retained_base if retained_base is not None else artifact_base,
        require_retained=require_host_artifacts,
        fixture_bytes=fixture["bytes"],
    )


def _validate_cadence_visual_capture_bindings(
    evidence: dict,
    expected_windows: list[dict],
    raw_visual: list[dict],
) -> None:
    started_system_uptime = _finite_number(
        evidence.get("startedSystemUptime"),
        "cadence-matrix started system uptime",
    )
    container = _exact_object(
        evidence.get("visualCaptureBindings"),
        {"formatVersion", "method", "records"},
        "cadence-matrix visualCaptureBindings",
    )
    records = container["records"]
    if (
        container["formatVersion"] != 1
        or container["method"] != VISUAL_OBSERVATION_METHOD
        or not isinstance(records, list)
        or len(records) != len(expected_windows)
        or len(raw_visual) != len(expected_windows)
    ):
        raise QualificationPolicyError(
            "cadence-matrix visual capture binding contract changed"
        )

    prior_capture: float | None = None
    for index, (item, retained, visual) in enumerate(
        zip(records, expected_windows, raw_visual)
    ):
        binding = _exact_object(
            item,
            CADENCE_VISUAL_CAPTURE_BINDING_KEYS,
            f"cadence-matrix visual capture binding {index}",
        )
        for field in (
            "profile",
            "requestedRate",
            "startElapsedSeconds",
            "durationSeconds",
        ):
            if not _json_same(binding[field], retained[field]) or not _json_same(
                binding[field], visual[field]
            ):
                raise QualificationPolicyError(
                    f"cadence-matrix visual capture binding {index} {field} "
                    "differs from its retained window"
                )

        capture_times = binding["captureElapsedSeconds"]
        capture_system_uptimes = binding["captureSystemUptimes"]
        encoded_frames = binding["canonicalRGB8Base64"]
        if (
            not isinstance(capture_times, list)
            or len(capture_times) != 3
            or not isinstance(capture_system_uptimes, list)
            or len(capture_system_uptimes) != 3
            or not isinstance(encoded_frames, list)
            or len(encoded_frames) != 3
        ):
            raise QualificationPolicyError(
                f"cadence-matrix visual capture binding {index} must retain "
                "exactly three times and frames"
            )
        start = _finite_number(
            binding["startElapsedSeconds"],
            f"cadence-matrix visual capture binding {index} start",
        )
        duration = _finite_number(
            binding["durationSeconds"],
            f"cadence-matrix visual capture binding {index} duration",
        )
        window_start = _finite_number(
            binding["windowStartSystemUptime"],
            f"cadence-matrix visual capture binding {index} window start",
        )
        window_end = _finite_number(
            binding["windowEndSystemUptime"],
            f"cadence-matrix visual capture binding {index} window end",
        )
        times = [
            _finite_number(
                value,
                f"cadence-matrix visual capture binding {index} time {frame_index}",
            )
            for frame_index, value in enumerate(capture_times)
        ]
        system_uptimes = [
            _finite_number(
                value,
                f"cadence-matrix visual capture binding {index} system uptime "
                f"{frame_index}",
            )
            for frame_index, value in enumerate(capture_system_uptimes)
        ]
        if (
            any(current <= previous for previous, current in zip(times, times[1:]))
            or any(
                current <= previous
                for previous, current in zip(system_uptimes, system_uptimes[1:])
            )
            or any(not (start + 1 < value < start + duration) for value in times)
            or abs(window_start - float(retained["windowStartSystemUptime"])) > 0.000001
            or abs(window_end - float(retained["windowEndSystemUptime"])) > 0.000001
            or any(not (window_start < value < window_end) for value in system_uptimes)
            or any(
                abs((system_uptime - started_system_uptime) - elapsed) > 0.000001
                for elapsed, system_uptime in zip(times, system_uptimes)
            )
            or (prior_capture is not None and system_uptimes[0] <= prior_capture)
        ):
            raise QualificationPolicyError(
                f"cadence-matrix visual capture binding {index} is outside its "
                "conservative native-counter window"
            )
        prior_capture = system_uptimes[-1]

        frames = [
            _decode_canonical_visual_frame(
                value,
                f"cadence-matrix visual capture binding {index} frame {frame_index}",
            )
            for frame_index, value in enumerate(encoded_frames)
        ]
        hashes = [_canonical_visual_frame_hash(frame) for frame in frames]
        ratios = [
            _canonical_visual_changed_pixel_ratio(first, second)
            for first, second in zip(frames, frames[1:])
        ]
        score = min(ratios)
        if (
            visual["frameHashes"] != hashes
            or len(visual["adjacentChangedPixelRatios"]) != len(ratios)
            or any(
                abs(float(observed) - expected) > 1e-12
                for observed, expected in zip(
                    visual["adjacentChangedPixelRatios"], ratios
                )
            )
            or abs(float(visual["changedPixelScore"]) - score) > 1e-12
        ):
            raise QualificationPolicyError(
                f"cadence-matrix visual capture binding {index} does not replay "
                "the retained visual observation"
            )


ENDURANCE_SERIES_PATHS = {
    "adaptive-hls-soak": "memorySeries",
    "pip-render-performance-1080p60": "samples",
    "pip-render-performance-4k60": "samples",
    "cadence-matrix": "samples",
    "native-subtitle-matrix": "metrics.samples",
}


def validate_endurance_duration_measurements(
    evidence: dict, scenario_id: str, *, stable: bool
) -> tuple[float, float]:
    if scenario_id not in STABLE_MINIMUM_DURATION_SECONDS:
        raise QualificationPolicyError(f"{scenario_id} is not an endurance scenario")
    device_duration = _finite_number(
        evidence.get("deviceObservedDurationSeconds"),
        f"{scenario_id} deviceObservedDurationSeconds",
    )
    host_duration = _finite_number(
        evidence.get("hostAttemptDurationSeconds"),
        f"{scenario_id} hostAttemptDurationSeconds",
    )
    canonical_duration = _finite_number(
        evidence.get("durationSeconds"), f"{scenario_id} durationSeconds"
    )
    if device_duration <= 0 or host_duration <= 0 or canonical_duration <= 0:
        raise QualificationPolicyError(
            f"{scenario_id} duration measurements must be positive"
        )
    if canonical_duration != device_duration:
        raise QualificationPolicyError(
            f"{scenario_id} canonical duration is not the device-observed duration"
        )
    minimum = STABLE_MINIMUM_DURATION_SECONDS[scenario_id]
    if stable and device_duration < minimum:
        raise QualificationPolicyError(
            f"{scenario_id} device ran for {device_duration:g}s, below immutable "
            f"stable minimum {minimum:g}s"
        )
    if device_duration > (host_duration + ENDURANCE_HOST_EARLY_TOLERANCE_SECONDS):
        raise QualificationPolicyError(
            f"{scenario_id} device duration exceeds its host attempt clock"
        )
    if host_duration > (device_duration + ENDURANCE_HOST_MAXIMUM_OVERHEAD_SECONDS):
        raise QualificationPolicyError(
            f"{scenario_id} host attempt contains more than "
            f"{ENDURANCE_HOST_MAXIMUM_OVERHEAD_SECONDS}s of non-device time"
        )
    return device_duration, host_duration


def validate_endurance_evidence(
    evidence: dict, scenario_id: str, *, stable: bool
) -> None:
    if scenario_id not in STABLE_MINIMUM_DURATION_SECONDS:
        return
    device_duration, _ = validate_endurance_duration_measurements(
        evidence, scenario_id, stable=stable
    )

    if scenario_id in {"timebase-vod-soak", "timebase-live-soak"}:
        raw = evidence.get("rawCapture")
        if not isinstance(raw, dict):
            raise QualificationPolicyError(
                f"{scenario_id} has no raw timebase duration series"
            )
        start = _integer(
            raw.get("timelineStartSeconds"),
            f"{scenario_id} raw timeline start",
        )
        end = _integer(raw.get("timelineEndSeconds"), f"{scenario_id} raw timeline end")
        maximum_gap = _integer(
            raw.get("maximumSampleGapSeconds"),
            f"{scenario_id} raw maximum sample gap",
        )
        sample_count = _integer(
            raw.get("sampleCount"), f"{scenario_id} raw sample count"
        )
        drift_sample_count = _integer(
            raw.get("driftSampleCount"),
            f"{scenario_id} raw drift sample count",
        )
        missing_seconds = _integer(
            raw.get("missingTimelineSeconds"),
            f"{scenario_id} raw missing timeline seconds",
        )
        if (
            start < 0
            or start > ENDURANCE_HOST_EARLY_TOLERANCE_SECONDS
            or end < device_duration - ENDURANCE_HOST_EARLY_TOLERANCE_SECONDS
            or end > device_duration + ENDURANCE_HOST_EARLY_TOLERANCE_SECONDS
            or end - start < device_duration - ENDURANCE_HOST_EARLY_TOLERANCE_SECONDS
            or maximum_gap > 5
            or sample_count
            < device_duration - ENDURANCE_SERIES_MAXIMUM_UNCOVERED_SECONDS
            or drift_sample_count
            < sample_count - ENDURANCE_SERIES_MAXIMUM_UNCOVERED_SECONDS
            or missing_seconds > ENDURANCE_SERIES_MAXIMUM_UNCOVERED_SECONDS
        ):
            raise QualificationPolicyError(
                f"{scenario_id} raw timebase series does not cover device duration"
            )
        return

    series_path = ENDURANCE_SERIES_PATHS[scenario_id]
    series = nested_value(evidence, series_path)
    if not isinstance(series, list) or len(series) < 2:
        raise QualificationPolicyError(
            f"{scenario_id} {series_path} has insufficient duration samples"
        )
    elapsed: list[int] = []
    for index, sample in enumerate(series):
        if not isinstance(sample, dict):
            raise QualificationPolicyError(
                f"{scenario_id} {series_path}[{index}] is malformed"
            )
        value = _integer(
            sample.get("elapsedSeconds"),
            f"{scenario_id} {series_path}[{index}].elapsedSeconds",
        )
        if value < 0:
            raise QualificationPolicyError(
                f"{scenario_id} {series_path} contains negative elapsed time"
            )
        elapsed.append(value)
    if any(current <= previous for previous, current in zip(elapsed, elapsed[1:])):
        raise QualificationPolicyError(
            f"{scenario_id} {series_path} is not strictly increasing"
        )
    maximum_gap = max(
        current - previous for previous, current in zip(elapsed, elapsed[1:])
    )
    if (
        elapsed[0] > ENDURANCE_SERIES_MAXIMUM_UNCOVERED_SECONDS
        or elapsed[-1] > device_duration + ENDURANCE_HOST_EARLY_TOLERANCE_SECONDS
        or elapsed[-1] - elapsed[0]
        < device_duration - ENDURANCE_SERIES_MAXIMUM_UNCOVERED_SECONDS
        or maximum_gap > ENDURANCE_SERIES_MAXIMUM_GAP_SECONDS
    ):
        raise QualificationPolicyError(
            f"{scenario_id} {series_path} does not cover device duration"
        )


def validate_adaptive_playback_oracle(evidence: dict) -> None:
    device_duration = _finite_number(
        evidence.get("deviceObservedDurationSeconds"),
        "adaptive-hls-soak device duration",
    )
    memory_series = evidence.get("memorySeries")
    if not isinstance(memory_series, list) or len(memory_series) < 2:
        raise QualificationPolicyError(
            "adaptive-hls-soak has no retained counter series"
        )
    counter_fields = (
        "readBytes",
        "decodedVideoFrames",
        "displayedPictures",
    )
    samples: list[dict] = []
    for index, item in enumerate(memory_series):
        sample = _exact_object(
            item,
            ADAPTIVE_MEMORY_SAMPLE_KEYS,
            f"adaptive-hls-soak memory sample {index}",
        )
        elapsed = _integer(
            sample["elapsedSeconds"],
            f"adaptive-hls-soak memory sample {index} elapsed",
        )
        if (
            elapsed < 0
            or (samples and elapsed <= samples[-1]["elapsedSeconds"])
            or sample["mode"] not in ADAPTIVE_MODES
            or not isinstance(sample["playerState"], str)
            or not sample["playerState"]
        ):
            raise QualificationPolicyError(
                f"adaptive-hls-soak memory sample {index} identity is invalid"
            )
        for field in (
            "residentBytes",
            "mallocBytesInUse",
            "mallocBytesAllocated",
            *counter_fields,
            "demuxDiscontinuities",
        ):
            if (
                _integer(
                    sample[field], f"adaptive-hls-soak memory sample {index} {field}"
                )
                < 0
            ):
                raise QualificationPolicyError(
                    f"adaptive-hls-soak memory sample {index} has a negative counter"
                )
        samples.append(sample)

    expected_windows: list[dict] = []
    for previous, current in zip(samples, samples[1:]):
        if previous["mode"] != current["mode"]:
            continue
        if (
            current["elapsedSeconds"] - previous["elapsedSeconds"]
            > ADAPTIVE_PROGRESS_WINDOW_SECONDS
        ):
            raise QualificationPolicyError(
                "adaptive-hls-soak same-mode counter samples contain a gap"
            )
        deltas: dict[str, int] = {}
        for source, output in (
            ("readBytes", "readBytesDelta"),
            ("decodedVideoFrames", "decodedVideoFramesDelta"),
            ("displayedPictures", "displayedPicturesDelta"),
        ):
            if current[source] < previous[source]:
                raise QualificationPolicyError(
                    "adaptive-hls-soak counters reset inside one playback phase"
                )
            deltas[output] = current[source] - previous[source]
        expected_windows.append(
            {
                "mode": current["mode"],
                "startElapsedSeconds": previous["elapsedSeconds"],
                "endElapsedSeconds": current["elapsedSeconds"],
                **deltas,
            }
        )
    if not expected_windows:
        raise QualificationPolicyError(
            "adaptive-hls-soak retained counters contain no same-mode windows"
        )
    progress = _exact_object(
        evidence.get("playbackProgress"),
        {"formatVersion", "windowSeconds", "modes", "windows"},
        "adaptive-hls-soak playbackProgress",
    )
    if (
        progress["formatVersion"] != 1
        or progress["windowSeconds"] != ADAPTIVE_PROGRESS_WINDOW_SECONDS
        or progress["modes"] != sorted(ADAPTIVE_MODES)
    ):
        raise QualificationPolicyError(
            "adaptive-hls-soak playback progress contract changed"
        )
    windows = progress["windows"]
    if not isinstance(windows, list) or not windows:
        raise QualificationPolicyError(
            "adaptive-hls-soak has no playback progress windows"
        )
    observed_modes: set[str] = set()
    starts: list[int] = []
    ends: list[int] = []
    for index, item in enumerate(windows):
        window = _exact_object(
            item,
            ADAPTIVE_PROGRESS_WINDOW_KEYS,
            f"adaptive-hls-soak progress window {index}",
        )
        mode = window["mode"]
        if mode not in ADAPTIVE_MODES:
            raise QualificationPolicyError(
                f"adaptive-hls-soak progress window {index} has unknown mode"
            )
        start = _integer(
            window["startElapsedSeconds"],
            f"adaptive-hls-soak progress window {index} start",
        )
        end = _integer(
            window["endElapsedSeconds"],
            f"adaptive-hls-soak progress window {index} end",
        )
        deltas = [
            _integer(
                window[field],
                f"adaptive-hls-soak progress window {index} {field}",
            )
            for field in (
                "readBytesDelta",
                "decodedVideoFramesDelta",
                "displayedPicturesDelta",
            )
        ]
        if (
            start < 0
            or end <= start
            or end - start > ADAPTIVE_PROGRESS_WINDOW_SECONDS
            or any(delta <= 0 for delta in deltas)
        ):
            raise QualificationPolicyError(
                f"adaptive-hls-soak progress window {index} did not advance"
            )
        if starts and start < starts[-1]:
            raise QualificationPolicyError(
                "adaptive-hls-soak progress windows are not chronological"
            )
        observed_modes.add(mode)
        starts.append(start)
        ends.append(end)
    if not _json_same(windows, expected_windows):
        raise QualificationPolicyError(
            "adaptive-hls-soak progress windows differ from retained counters"
        )
    maximum_gap = max(
        (current - previous for previous, current in zip(ends, starts[1:])),
        default=0,
    )
    if (
        observed_modes != ADAPTIVE_MODES
        or starts[0] > ENDURANCE_HOST_EARLY_TOLERANCE_SECONDS
        or ends[-1] < device_duration - ENDURANCE_HOST_EARLY_TOLERANCE_SECONDS
        or maximum_gap > ADAPTIVE_PROGRESS_WINDOW_SECONDS
    ):
        raise QualificationPolicyError(
            "adaptive-hls-soak progress windows do not cover every mode/duration"
        )

    raw_visual = _visual_observations(
        evidence,
        record_keys={
            "elapsedSeconds",
            "mode",
            "frameHashes",
            "adjacentChangedPixelRatios",
            "changedPixelScore",
        },
        description="adaptive-hls-soak",
    )
    expected_checkpoints: list[dict] = []
    for index, record in enumerate(raw_visual):
        elapsed = _integer(
            record["elapsedSeconds"],
            f"adaptive-hls-soak raw visual observation {index} elapsed",
        )
        mode = record["mode"]
        if (
            mode not in ADAPTIVE_MODES
            or elapsed < 0
            or (
                expected_checkpoints
                and elapsed <= expected_checkpoints[-1]["elapsedSeconds"]
            )
            or not any(
                window["mode"] == mode
                and window["startElapsedSeconds"]
                <= elapsed
                <= window["endElapsedSeconds"]
                for window in windows
            )
        ):
            raise QualificationPolicyError(
                f"adaptive-hls-soak raw visual observation {index} is unbound"
            )
        expected_checkpoints.append(
            {
                "elapsedSeconds": elapsed,
                "mode": mode,
                "motionScore": record["changedPixelScore"],
                "distinctFrameHashes": len(set(record["frameHashes"])),
            }
        )

    visual = _exact_object(
        evidence.get("visualOracle"),
        {"formatVersion", "method", "maximumMotionGapSeconds", "checkpoints"},
        "adaptive-hls-soak visualOracle",
    )
    if (
        visual["formatVersion"] != 1
        or visual["method"] != VISUAL_OBSERVATION_METHOD
        or visual["maximumMotionGapSeconds"] != ADAPTIVE_PROGRESS_WINDOW_SECONDS
    ):
        raise QualificationPolicyError(
            "adaptive-hls-soak visual oracle contract changed"
        )
    checkpoints = visual["checkpoints"]
    if not isinstance(checkpoints, list) or not checkpoints:
        raise QualificationPolicyError(
            "adaptive-hls-soak has no independent visual checkpoints"
        )
    if not _json_same(checkpoints, expected_checkpoints):
        raise QualificationPolicyError(
            "adaptive-hls-soak visual oracle differs from retained UI observations"
        )
    elapsed_values: list[int] = []
    visual_modes: set[str] = set()
    for index, item in enumerate(checkpoints):
        checkpoint = _exact_object(
            item,
            {"elapsedSeconds", "mode", "motionScore", "distinctFrameHashes"},
            f"adaptive-hls-soak visual checkpoint {index}",
        )
        elapsed = _integer(
            checkpoint["elapsedSeconds"],
            f"adaptive-hls-soak visual checkpoint {index} elapsed",
        )
        score = _finite_number(
            checkpoint["motionScore"],
            f"adaptive-hls-soak visual checkpoint {index} motion score",
        )
        hashes = _integer(
            checkpoint["distinctFrameHashes"],
            f"adaptive-hls-soak visual checkpoint {index} distinct frames",
        )
        mode = checkpoint["mode"]
        if (
            mode not in ADAPTIVE_MODES
            or score < ADAPTIVE_VISUAL_MOTION_MINIMUM_SCORE
            or hashes < 2
            or elapsed < 0
            or (elapsed_values and elapsed <= elapsed_values[-1])
        ):
            raise QualificationPolicyError(
                f"adaptive-hls-soak visual checkpoint {index} is not moving"
            )
        visual_modes.add(mode)
        elapsed_values.append(elapsed)
        if not any(
            window["mode"] == mode
            and window["startElapsedSeconds"] <= elapsed <= window["endElapsedSeconds"]
            for window in windows
        ):
            raise QualificationPolicyError(
                "adaptive-hls-soak visual checkpoint has no counter window"
            )
    maximum_visual_gap = max(
        (
            current - previous
            for previous, current in zip(elapsed_values, elapsed_values[1:])
        ),
        default=device_duration,
    )
    if (
        visual_modes != ADAPTIVE_MODES
        or elapsed_values[0] > ADAPTIVE_PROGRESS_WINDOW_SECONDS
        or elapsed_values[-1] < device_duration - ADAPTIVE_PROGRESS_WINDOW_SECONDS
        or maximum_visual_gap > ADAPTIVE_PROGRESS_WINDOW_SECONDS
    ):
        raise QualificationPolicyError(
            "adaptive-hls-soak visual oracle has a sustained-motion gap"
        )


def _cadence_interval_counts(value: object, description: str) -> dict[str, int]:
    counts = _exact_object(value, CADENCE_INTERVAL_COUNT_KEYS, description)
    result: dict[str, int] = {}
    for key in sorted(CADENCE_INTERVAL_COUNT_KEYS):
        count = _integer(counts[key], f"{description} {key}")
        if count < 0:
            raise QualificationPolicyError(f"{description} contains a negative count")
        result[key] = count
    return result


def _cadence_int64(value: object, description: str) -> int:
    result = _integer(value, description)
    if result < -(1 << 63) or result > (1 << 63) - 1:
        raise QualificationPolicyError(f"{description} is outside Int64")
    return result


def _cadence_delta_histogram(value: object, description: str) -> dict[int, int]:
    if not isinstance(value, list):
        raise QualificationPolicyError(f"{description} must be an array")
    result: dict[int, int] = {}
    prior_delta: int | None = None
    for index, item in enumerate(value):
        entry = _exact_object(
            item,
            CADENCE_VMEM_DELTA_HISTOGRAM_ENTRY_KEYS,
            f"{description} entry {index}",
        )
        delta = _cadence_int64(
            entry["deltaMicroseconds"], f"{description} entry {index} delta"
        )
        count = _integer(entry["count"], f"{description} entry {index} count")
        if count <= 0 or (prior_delta is not None and delta <= prior_delta):
            raise QualificationPolicyError(
                f"{description} must contain sorted unique positive-count entries"
            )
        result[delta] = count
        prior_delta = delta
    return result


def _cadence_histogram_delta(
    before: dict[int, int], after: dict[int, int], description: str
) -> dict[int, int]:
    if any(after.get(delta, 0) < count for delta, count in before.items()):
        raise QualificationPolicyError(f"{description} moved backwards")
    return {
        delta: after.get(delta, 0) - before.get(delta, 0)
        for delta in sorted(set(before) | set(after))
        if after.get(delta, 0) != before.get(delta, 0)
    }


def _cadence_exact_frame_multiple(
    delta_microseconds: int, numerator: int, denominator: int
) -> int | None:
    """Return the exact rational-frame multiple represented by an integer PTS delta."""

    if delta_microseconds <= 0:
        return None
    scale = 1_000_000 * denominator
    estimate = max(1, round(delta_microseconds * numerator / scale))
    matches: list[int] = []
    for multiple in range(max(1, estimate - 2), estimate + 3):
        quotient, remainder = divmod(multiple * scale, numerator)
        if delta_microseconds in {quotient, quotient + (1 if remainder else 0)}:
            matches.append(multiple)
    return min(matches) if matches else None


def _classify_cadence_window_histogram(
    profile: str, histogram: dict[int, int]
) -> dict[str, int]:
    exact = 0
    multiple = 0
    skipped = 0
    redisplay = 0
    unclassified = 0
    backward = 0
    rates = (
        [(24, 1), (60, 1)]
        if profile == "vfr-24-60"
        else [CADENCE_CFR_SOURCE_RATE_RATIONALS[profile]]
    )
    for delta, count in histogram.items():
        if delta < 0:
            backward += count
            continue
        if delta == 0:
            redisplay += count
            continue
        candidates = [
            value
            for numerator, denominator in rates
            if (value := _cadence_exact_frame_multiple(delta, numerator, denominator))
            is not None
        ]
        if not candidates:
            unclassified += count
            continue
        source_frames = min(candidates)
        if source_frames == 1:
            exact += count
        else:
            multiple += count
            skipped += (source_frames - 1) * count
    return {
        "nativePTSExactIntervalCount": exact,
        "nativePTSMultipleIntervalCount": multiple,
        "nativePTSEstimatedSkippedPictureCount": skipped,
        "nativePTSRedisplayCount": redisplay,
        "nativePTSUnclassifiedIntervalCount": unclassified,
        "nativePTSBackwardCount": backward,
    }


def _cadence_vfr_frame_integral(media_seconds: float) -> float:
    if media_seconds < 0:
        raise QualificationPolicyError("cadence-matrix VFR media offset is negative")
    cycle = CADENCE_VFR_REGIME_SECONDS * 2
    cycles = math.floor(media_seconds / cycle)
    remainder = media_seconds - cycles * cycle
    low_duration = min(remainder, CADENCE_VFR_REGIME_SECONDS)
    high_duration = max(0.0, remainder - CADENCE_VFR_REGIME_SECONDS)
    return (
        cycles * CADENCE_VFR_REGIME_SECONDS * (24.0 + 60.0)
        + low_duration * 24.0
        + high_duration * 60.0
    )


def _cadence_exact_single_frame_deltas(
    numerator: int, denominator: int
) -> set[int]:
    quotient, remainder = divmod(1_000_000 * denominator, numerator)
    return {quotient, quotient + (1 if remainder else 0)}


def _cadence_vfr_expected_exact_regime_counts(
    start_pts_us: int, end_pts_us: int
) -> dict[int, int]:
    """Count 24/60 source intervals inside an absolute fixture PTS span."""

    if start_pts_us < 0 or end_pts_us <= start_pts_us:
        raise QualificationPolicyError(
            "cadence semantics probe VFR PTS span is invalid"
        )
    segment_us = round(CADENCE_VFR_REGIME_SECONDS * 1_000_000)
    first_segment = max(0, start_pts_us // segment_us - 1)
    final_segment = end_pts_us // segment_us + 1
    timestamps: set[int] = set()
    for segment in range(first_segment, final_segment + 1):
        fps = 24 if segment % 2 == 0 else 60
        segment_start = segment * segment_us
        frame_count = round(fps * CADENCE_VFR_REGIME_SECONDS)
        for frame in range(frame_count):
            timestamp = segment_start + frame * 1_000_000 // fps
            if start_pts_us - 50_000 <= timestamp <= end_pts_us + 50_000:
                timestamps.add(timestamp)

    interval_sets = {
        fps: _cadence_exact_single_frame_deltas(fps, 1) for fps in (24, 60)
    }
    counts = {24: 0, 60: 0}
    ordered = sorted(timestamps)
    for previous, current in zip(ordered, ordered[1:]):
        if previous < start_pts_us or current > end_pts_us:
            continue
        delta = current - previous
        matching = [fps for fps, values in interval_sets.items() if delta in values]
        if len(matching) == 1:
            counts[matching[0]] += 1
    return counts


def _validate_cadence_vfr_regimes(
    histogram: dict[int, int], start_pts_us: int, end_pts_us: int, description: str
) -> None:
    expected = _cadence_vfr_expected_exact_regime_counts(
        start_pts_us, end_pts_us
    )
    observed = {24: 0, 60: 0}
    for delta, count in histogram.items():
        if delta <= 0:
            continue
        matches = {
            fps: multiple
            for fps in (24, 60)
            if (
                multiple := _cadence_exact_frame_multiple(delta, fps, 1)
            )
            is not None
        }
        # An interval such as 1/12s is compatible with both regimes and
        # therefore cannot prove either one without ordered per-frame PTS.
        if len(matches) == 1:
            fps, source_frames = next(iter(matches.items()))
            observed[fps] += source_frames * count
    minimum = {
        fps: max(
            3,
            math.floor(
                count * CADENCE_VFR_MINIMUM_REGIME_SOURCE_FRAME_FRACTION
            ),
        )
        for fps, count in expected.items()
    }
    if any(expected[fps] < 3 or observed[fps] < minimum[fps] for fps in (24, 60)):
        raise QualificationPolicyError(
            f"{description} does not prove both material 24fps and 60fps VFR "
            f"regimes: observed={observed!r}, minimum={minimum!r}, "
            f"expected={expected!r}"
        )


def _cadence_minimum_submission_fps(
    *,
    profile: str,
    applied_rate: float,
    window_duration: float,
    start_pts_us: int,
    end_pts_us: int,
) -> float:
    if profile == "vfr-24-60":
        # Cap each absolute-PTS fixture regime independently. At 2x, 24fps
        # remains 48fps while 60fps is selected at roughly every other source
        # frame; globally capping their weighted average would overstate the
        # number of selected-output callbacks a correct vout can produce.
        regime_frames = _cadence_vfr_expected_exact_regime_counts(
            start_pts_us, end_pts_us
        )
        expected_output_fps = sum(
            count * min(1.0, 60.0 / (fps * applied_rate))
            for fps, count in regime_frames.items()
        ) / window_duration
    else:
        expected_output_fps = CADENCE_CFR_SOURCE_RATES[profile] * applied_rate
    return CADENCE_MINIMUM_SUBMISSION_FRACTION * min(expected_output_fps, 60.0)


def _validate_cadence_presentation_metrics(
    evidence: dict, window_totals: dict[str, dict[str, int]]
) -> None:
    metrics = evidence.get("presentationMetrics")
    if not isinstance(metrics, list) or len(metrics) != len(CADENCE_PROFILE_ORDER):
        raise QualificationPolicyError(
            "cadence-matrix presentation metrics do not cover every profile"
        )
    if [
        item.get("profile") if isinstance(item, dict) else None for item in metrics
    ] != list(CADENCE_PROFILE_ORDER):
        raise QualificationPolicyError(
            "cadence-matrix presentation metric profile order changed"
        )

    for index, item in enumerate(metrics):
        if (
            not isinstance(item, dict)
            or not CADENCE_PRESENTATION_METRIC_REQUIRED_KEYS.issubset(item)
            or set(item)
            - CADENCE_PRESENTATION_METRIC_REQUIRED_KEYS
            - CADENCE_PRESENTATION_METRIC_OPTIONAL_KEYS
        ):
            raise QualificationPolicyError(
                f"cadence-matrix presentation metric {index} schema is not exact"
            )
        if any(key in item for key in CADENCE_PRESENTATION_METRIC_OPTIONAL_KEYS):
            raise QualificationPolicyError(
                f"cadence-matrix presentation metric {index} fabricated frame duration"
            )
        profile = item["profile"]
        delivered = _integer(
            item["deliveredFrames"],
            f"cadence-matrix presentation metric {index} delivered frames",
        )
        dropped = _integer(
            item["droppedFrames"],
            f"cadence-matrix presentation metric {index} dropped frames",
        )
        backpressure = _integer(
            item["backpressureEvents"],
            f"cadence-matrix presentation metric {index} backpressure",
        )
        elapsed = _finite_number(
            item["elapsedSeconds"],
            f"cadence-matrix presentation metric {index} elapsed",
        )
        drop_rate = _finite_number(
            item["dropRate"],
            f"cadence-matrix presentation metric {index} drop rate",
        )
        presentation_rate = _finite_number(
            item["presentationRate"],
            f"cadence-matrix presentation metric {index} presentation rate",
        )
        copy_failures = _integer(
            item["presentationCopyFailures"],
            f"cadence-matrix presentation metric {index} copy failures",
        )
        consume_failures = _integer(
            item["displayConsumeFailures"],
            f"cadence-matrix presentation metric {index} consume failures",
        )
        total = delivered + dropped
        expected_drop_rate = dropped / total if total > 0 else 1.0
        retained = window_totals[profile]
        if (
            delivered <= 0
            or dropped < 0
            or backpressure < 0
            or elapsed <= 0
            or copy_failures != 0
            or consume_failures != 0
            or abs(drop_rate - expected_drop_rate) > 1e-9
            or abs(presentation_rate - (delivered / elapsed)) > 1e-6
            or presentation_rate <= 0
            or elapsed < retained["windowDurationSeconds"]
            or delivered < retained["deliveredFrames"]
            or dropped < retained["droppedFrames"]
            or backpressure < retained["backpressureEvents"]
        ):
            raise QualificationPolicyError(
                f"cadence-matrix presentation metric {index} violates delivery policy"
            )


def _validate_cadence_transitions(evidence: dict) -> None:
    transitions = _exact_object(
        evidence.get("transitionResults"),
        CADENCE_TRANSITION_RESULT_KEYS,
        "cadence-matrix transitionResults",
    )
    rate_changes = _integer(transitions["rateChanges"], "cadence-matrix rate changes")
    pause_resume = _integer(
        transitions["pauseResumeCycles"], "cadence-matrix pause/resume cycles"
    )
    replacements = _integer(transitions["replacements"], "cadence-matrix replacements")
    resize_cycles = _integer(
        transitions["resizeCycles"], "cadence-matrix resize cycles"
    )
    monotonicity = _integer(
        transitions["monotonicityViolations"],
        "cadence-matrix monotonicity violations",
    )
    targets = transitions["resizeTargets"]
    device_duration = _finite_number(
        evidence.get("deviceObservedDurationSeconds", evidence.get("durationSeconds")),
        "cadence-matrix device duration",
    )
    springboard_gestures = _integer(
        evidence.get("springboardResizeGestures"),
        "cadence-matrix SpringBoard resize gestures",
    )
    if (
        rate_changes != len(CADENCE_PROFILE_ORDER) * 4
        or pause_resume != len(CADENCE_PROFILE_ORDER)
        or replacements != len(CADENCE_PROFILE_ORDER) - 1
        or monotonicity != 0
        or not isinstance(targets, list)
        or not targets
        or any(
            not isinstance(target, str)
            or re.fullmatch(r"(?:0x0|[1-9][0-9]*x[1-9][0-9]*)", target) is None
            for target in targets
        )
        or any(current == previous for previous, current in zip(targets, targets[1:]))
        or resize_cycles != len(targets) - 1
        or resize_cycles <= 0
        or len({target for target in targets if target != "0x0"}) < 2
        or device_duration <= 0
        or springboard_gestures < max(4, int(device_duration) // 90)
        or evidence.get("fabricatedDurationCount") != 0
    ):
        raise QualificationPolicyError(
            "cadence-matrix transition evidence violates the immutable matrix"
        )


def validate_cadence_oracle(evidence: dict) -> None:
    _validate_raw_evidence_shape(
        evidence,
        CADENCE_RAW_EVIDENCE_KEYS,
        "cadence-matrix",
        duration_is_host_owned=False,
    )
    if evidence.get("sourceTimestampProvenance") != CADENCE_SOURCE_TIMESTAMP_PROVENANCE:
        raise QualificationPolicyError(
            "cadence-matrix legacy picture-date telemetry identity changed"
        )
    if (
        evidence.get("vmemOutputTimestampProvenance")
        != CADENCE_VMEM_OUTPUT_TIMESTAMP_PROVENANCE
    ):
        raise QualificationPolicyError(
            "cadence-matrix lacks post-filter, vout-selected vmem "
            "output-attempt PTS provenance"
        )
    samples_value = evidence.get("samples")
    if not isinstance(samples_value, list) or len(samples_value) < 2:
        raise QualificationPolicyError("cadence-matrix has no retained samples")

    required_profiles = set(CADENCE_PROFILE_ORDER)
    vmem_counter_fields = (
        "vmemOutputCallbackCount",
        "vmemOutputValidPTSCount",
        "vmemOutputInvalidPTSCount",
        "vmemOutputDuplicatePTSCount",
        "vmemOutputBackwardPTSCount",
        "vmemOutputDeltaOverflowCount",
        "vmemOutputSubmittedCount",
        "vmemOutputSwiftRejectedCount",
        "vmemOutputInFlightCount",
    )
    vmem_generation_fields = (
        "vmemOutputPlaybackGeneration",
        "vmemOutputVoutGeneration",
    )
    runtime_counter_fields = (
        "libVLCDecodedVideoCount",
        "libVLCDisplayedPictureCount",
        "libVLCLostPictureCount",
        "libVLCLatePictureCount",
    )
    samples: list[dict] = []
    sample_histograms: list[dict[int, int]] = []
    for index, item in enumerate(samples_value):
        if (
            not isinstance(item, dict)
            or not CADENCE_SAMPLE_REQUIRED_KEYS.issubset(item)
            or set(item) - CADENCE_SAMPLE_REQUIRED_KEYS - CADENCE_SAMPLE_OPTIONAL_KEYS
        ):
            raise QualificationPolicyError(
                f"cadence-matrix sample {index} schema is not exact"
            )
        profile = item["profile"]
        elapsed = _integer(
            item["elapsedSeconds"], f"cadence-matrix sample {index} elapsed"
        )
        uptime = _finite_number(
            item["systemUptime"], f"cadence-matrix sample {index} system uptime"
        )
        generation = _integer(
            item["playbackGeneration"],
            f"cadence-matrix sample {index} generation",
        )
        requested_rate = _finite_number(
            item["requestedRate"],
            f"cadence-matrix sample {index} requested rate",
        )
        effective_rate = _finite_number(
            item["effectivePlayerRate"],
            f"cadence-matrix sample {index} effective rate",
        )
        _finite_number(
            item["lastPTSSeconds"], f"cadence-matrix sample {index} legacy PTS"
        )
        _cadence_interval_counts(
            item["sourceIntervalCounts"],
            f"cadence-matrix sample {index} legacy interval counts",
        )
        _cadence_interval_counts(
            item["vmemOutputIntervalCounts"],
            f"cadence-matrix sample {index} diagnostic vmem interval counts",
        )
        histogram = _cadence_delta_histogram(
            item["vmemOutputDeltaHistogram"],
            f"cadence-matrix sample {index} vmem PTS histogram",
        )
        counters = {
            field: _integer(item[field], f"cadence-matrix sample {index} {field}")
            for field in vmem_counter_fields
        }
        vmem_generations = {
            field: _integer(item[field], f"cadence-matrix sample {index} {field}")
            for field in vmem_generation_fields
        }
        runtime = {
            field: _integer(item[field], f"cadence-matrix sample {index} {field}")
            for field in runtime_counter_fields
        }
        first_pts = _cadence_int64(
            item["vmemOutputFirstPTSUS"],
            f"cadence-matrix sample {index} first vmem PTS",
        )
        last_pts = _cadence_int64(
            item["vmemOutputLastPTSUS"],
            f"cadence-matrix sample {index} last vmem PTS",
        )
        first_valid_pts = _cadence_int64(
            item["vmemOutputFirstValidPTSUS"],
            f"cadence-matrix sample {index} first valid vmem PTS",
        )
        last_valid_pts = _cadence_int64(
            item["vmemOutputLastValidPTSUS"],
            f"cadence-matrix sample {index} last valid vmem PTS",
        )
        for field in ("deliveredFrames", "droppedFrames", "backpressureEvents"):
            if _integer(item[field], f"cadence-matrix sample {index} {field}") < 0:
                raise QualificationPolicyError(
                    f"cadence-matrix sample {index} has a negative renderer counter"
                )
        histogram_count = sum(histogram.values())
        if (
            profile not in required_profiles
            or elapsed < 0
            or uptime <= 0
            or generation < 0
            or any(value < 0 for value in vmem_generations.values())
            or requested_rate not in {0.5, 1.0, 2.0}
            or effective_rate not in {0.5, 1.0, 2.0}
            or abs(requested_rate - effective_rate) > 0.001
            or vmem_generations["vmemOutputPlaybackGeneration"] != generation
            or vmem_generations["vmemOutputVoutGeneration"] <= 0
            or item["vmemOutputTimestampProvenance"]
            != CADENCE_VMEM_OUTPUT_TIMESTAMP_PROVENANCE
            or any(value < 0 for value in counters.values())
            or any(value < 0 for value in runtime.values())
            or counters["vmemOutputValidPTSCount"]
            + counters["vmemOutputInvalidPTSCount"]
            != counters["vmemOutputCallbackCount"]
            or counters["vmemOutputSubmittedCount"]
            + counters["vmemOutputSwiftRejectedCount"]
            + counters["vmemOutputInFlightCount"]
            != counters["vmemOutputCallbackCount"]
            or counters["vmemOutputInvalidPTSCount"] != 0
            or counters["vmemOutputBackwardPTSCount"] != 0
            or counters["vmemOutputDeltaOverflowCount"] != 0
            or histogram.get(0, 0) != counters["vmemOutputDuplicatePTSCount"]
            or sum(count for delta, count in histogram.items() if delta < 0)
            != counters["vmemOutputBackwardPTSCount"]
            or histogram_count != max(0, counters["vmemOutputValidPTSCount"] - 1)
            or first_pts > last_pts
            or first_pts != first_valid_pts
            or last_pts != last_valid_pts
            or (samples and elapsed <= samples[-1]["elapsedSeconds"])
            or (samples and uptime <= samples[-1]["systemUptime"])
        ):
            raise QualificationPolicyError(
                f"cadence-matrix sample {index} vmem timing/counter contract is invalid"
            )
        samples.append(item)
        sample_histograms.append(histogram)

    expected_observations: list[dict] = []
    window_totals = {
        profile: {
            "submittedFrames": 0,
            "deliveredFrames": 0,
            "droppedFrames": 0,
            "backpressureEvents": 0,
            "windowDurationSeconds": 0.0,
        }
        for profile in CADENCE_PROFILE_ORDER
    }
    cumulative_fields = (
        *vmem_counter_fields,
        *runtime_counter_fields,
        "deliveredFrames",
        "droppedFrames",
        "backpressureEvents",
    )
    for sample_index, (previous, current) in enumerate(zip(samples, samples[1:])):
        if any(
            previous[field] != current[field]
            for field in (
                "profile",
                "playbackGeneration",
                "requestedRate",
                "effectivePlayerRate",
                "vmemOutputPlaybackGeneration",
                "vmemOutputVoutGeneration",
            )
        ):
            continue
        compatibility_duration = current["elapsedSeconds"] - previous["elapsedSeconds"]
        window_duration = current["systemUptime"] - previous["systemUptime"]
        if (
            compatibility_duration < CADENCE_WINDOW_SECONDS
            or compatibility_duration > CADENCE_WINDOW_SECONDS + 1
            or window_duration < CADENCE_WINDOW_SECONDS
            or window_duration > CADENCE_WINDOW_SECONDS + 1
        ):
            continue
        if any(current[field] < previous[field] for field in cumulative_fields):
            raise QualificationPolicyError(
                "cadence-matrix counters moved backwards within one stable window"
            )
        if (
            current["vmemOutputFirstPTSUS"] != previous["vmemOutputFirstPTSUS"]
            or current["vmemOutputFirstValidPTSUS"]
            != previous["vmemOutputFirstValidPTSUS"]
            or current["vmemOutputInFlightCount"] != previous["vmemOutputInFlightCount"]
        ):
            raise QualificationPolicyError(
                "cadence-matrix stable window has an ambiguous vmem boundary"
            )
        histogram_delta = _cadence_histogram_delta(
            sample_histograms[sample_index],
            sample_histograms[sample_index + 1],
            "cadence-matrix vmem PTS histogram",
        )
        callback_count = (
            current["vmemOutputCallbackCount"] - previous["vmemOutputCallbackCount"]
        )
        submitted = (
            current["vmemOutputSubmittedCount"] - previous["vmemOutputSubmittedCount"]
        )
        rejected = (
            current["vmemOutputSwiftRejectedCount"]
            - previous["vmemOutputSwiftRejectedCount"]
        )
        native_delta_us = (
            current["vmemOutputLastValidPTSUS"] - previous["vmemOutputLastValidPTSUS"]
        )
        histogram_count = sum(histogram_delta.values())
        histogram_span = sum(delta * count for delta, count in histogram_delta.items())
        classification = _classify_cadence_window_histogram(
            current["profile"], histogram_delta
        )
        overflow = (
            current["vmemOutputDeltaOverflowCount"]
            - previous["vmemOutputDeltaOverflowCount"]
        )
        applied_rate = float(current["effectivePlayerRate"])
        native_delta_seconds = native_delta_us / 1_000_000
        minimum_submission_fps = _cadence_minimum_submission_fps(
            profile=current["profile"],
            applied_rate=applied_rate,
            window_duration=window_duration,
            start_pts_us=previous["vmemOutputLastValidPTSUS"],
            end_pts_us=current["vmemOutputLastValidPTSUS"],
        )
        observed_submission_fps = submitted / window_duration
        runtime_deltas = {
            field: current[field] - previous[field] for field in runtime_counter_fields
        }
        delivered = current["deliveredFrames"] - previous["deliveredFrames"]
        dropped = current["droppedFrames"] - previous["droppedFrames"]
        backpressure = current["backpressureEvents"] - previous["backpressureEvents"]
        if (
            callback_count <= 0
            or callback_count != histogram_count
            or callback_count != submitted + rejected
            or histogram_span != native_delta_us
            or native_delta_us <= 0
            or classification["nativePTSBackwardCount"] != 0
            or classification["nativePTSUnclassifiedIntervalCount"] != 0
            or overflow != 0
            or abs(native_delta_seconds / window_duration - applied_rate) / applied_rate
            > CADENCE_RATE_TOLERANCE_FRACTION
            or submitted <= 0
            or delivered <= 0
            or observed_submission_fps + 1e-9 < minimum_submission_fps
            or runtime_deltas["libVLCDecodedVideoCount"] <= 0
            or runtime_deltas["libVLCDisplayedPictureCount"] <= 0
        ):
            raise QualificationPolicyError(
                "cadence-matrix stable window violates vmem cadence semantics"
            )
        raw_histogram = [
            {"deltaMicroseconds": delta, "count": count}
            for delta, count in histogram_delta.items()
        ]
        profile = current["profile"]
        window_totals[profile]["submittedFrames"] += submitted
        window_totals[profile]["deliveredFrames"] += delivered
        window_totals[profile]["droppedFrames"] += dropped
        window_totals[profile]["backpressureEvents"] += backpressure
        window_totals[profile]["windowDurationSeconds"] += window_duration
        expected_observations.append(
            {
                "profile": profile,
                # Preserve Swift JSONSerialization's integer representation for
                # whole-valued Double rates while using float for all math.
                "requestedRate": current["requestedRate"],
                "startElapsedSeconds": previous["elapsedSeconds"],
                "durationSeconds": compatibility_duration,
                "windowStartSystemUptime": previous["systemUptime"],
                "windowEndSystemUptime": current["systemUptime"],
                "windowDurationSeconds": window_duration,
                "appliedRate": current["effectivePlayerRate"],
                "nativePTSDeltaSeconds": native_delta_seconds,
                **classification,
                "nativePTSDeltaOverflowCount": overflow,
                "nativePTSDeltaHistogram": raw_histogram,
                "outputCallbackCount": callback_count,
                "submittedFrames": submitted,
                "swiftRejectedFrames": rejected,
                "observedSubmissionFPS": observed_submission_fps,
                "minimumSubmissionFPS": minimum_submission_fps,
                "libVLCDecodedVideoDelta": runtime_deltas["libVLCDecodedVideoCount"],
                "libVLCDisplayedPictureDelta": runtime_deltas[
                    "libVLCDisplayedPictureCount"
                ],
                "libVLCLostPictureDelta": runtime_deltas["libVLCLostPictureCount"],
                "libVLCLatePictureDelta": runtime_deltas["libVLCLatePictureCount"],
                "deliveredFrames": delivered,
            }
        )
    if len(expected_observations) != len(CADENCE_PROFILE_ORDER) * 3:
        raise QualificationPolicyError(
            "cadence-matrix retained samples do not contain exactly one stable "
            "window per profile/rate"
        )
    _validate_cadence_presentation_metrics(evidence, window_totals)
    _validate_cadence_transitions(evidence)

    raw_visual = _visual_observations(
        evidence,
        record_keys={
            "startElapsedSeconds",
            "durationSeconds",
            "profile",
            "requestedRate",
            "frameHashes",
            "adjacentChangedPixelRatios",
            "changedPixelScore",
        },
        description="cadence-matrix",
    )
    if len(raw_visual) != len(expected_observations):
        raise QualificationPolicyError(
            "cadence-matrix raw visual/window observation counts differ"
        )
    _validate_cadence_visual_capture_bindings(
        evidence, expected_observations, raw_visual
    )

    oracle = _exact_object(
        evidence.get("cadenceOracle"),
        {
            "formatVersion",
            "windowSeconds",
            "rateToleranceFraction",
            "minimumVisualMotionScore",
            "vfrObservedRegimesFPS",
            "windows",
        },
        "cadence-matrix cadenceOracle",
    )
    if (
        oracle["formatVersion"] != 1
        or oracle["windowSeconds"] != CADENCE_WINDOW_SECONDS
        or oracle["rateToleranceFraction"] != CADENCE_RATE_TOLERANCE_FRACTION
        or oracle["minimumVisualMotionScore"] != CADENCE_VISUAL_MOTION_MINIMUM_SCORE
        or oracle["vfrObservedRegimesFPS"] != [24.0, 60.0]
    ):
        raise QualificationPolicyError("cadence-matrix oracle contract changed")
    windows = oracle["windows"]
    if not isinstance(windows, list) or len(windows) != len(expected_observations):
        raise QualificationPolicyError(
            "cadence-matrix oracle omitted retained cadence windows"
        )
    observed: dict[str, set[float]] = {profile: set() for profile in required_profiles}
    elapsed_values: list[int] = []
    measured_fields = {
        "windowStartSystemUptime",
        "windowEndSystemUptime",
        "windowDurationSeconds",
        "nativePTSDeltaSeconds",
        "observedSubmissionFPS",
        "minimumSubmissionFPS",
    }
    exact_fields = (
        CADENCE_ORACLE_WINDOW_KEYS
        - measured_fields
        - {
            "visualMotionScore",
            "distinctFrameHashes",
        }
    )
    for index, item in enumerate(windows):
        window = _exact_object(
            item,
            CADENCE_ORACLE_WINDOW_KEYS,
            f"cadence-matrix oracle window {index}",
        )
        retained = expected_observations[index]
        visual = raw_visual[index]
        for field in exact_fields:
            if not _json_same(window[field], retained[field]):
                raise QualificationPolicyError(
                    f"cadence-matrix oracle {field} differs from retained samples"
                )
        for field in measured_fields:
            measured = _finite_number(
                window[field], f"cadence-matrix oracle window {index} {field}"
            )
            if abs(measured - float(retained[field])) > 0.000001:
                raise QualificationPolicyError(
                    f"cadence-matrix oracle {field} differs from retained samples"
                )
        for field in (
            "profile",
            "requestedRate",
            "startElapsedSeconds",
            "durationSeconds",
        ):
            if not _json_same(visual[field], retained[field]):
                raise QualificationPolicyError(
                    f"cadence-matrix raw visual {field} differs from samples"
                )
        profile = window["profile"]
        requested_rate = _finite_number(
            window["requestedRate"],
            f"cadence-matrix oracle window {index} requested rate",
        )
        applied_rate = _finite_number(
            window["appliedRate"],
            f"cadence-matrix oracle window {index} applied rate",
        )
        start = _integer(
            window["startElapsedSeconds"],
            f"cadence-matrix oracle window {index} start",
        )
        duration = _finite_number(
            window["windowDurationSeconds"],
            f"cadence-matrix oracle window {index} exact duration",
        )
        submitted = _integer(
            window["submittedFrames"],
            f"cadence-matrix oracle window {index} submitted frames",
        )
        observed_fps = _finite_number(
            window["observedSubmissionFPS"],
            f"cadence-matrix oracle window {index} observed submission FPS",
        )
        minimum_fps = _finite_number(
            window["minimumSubmissionFPS"],
            f"cadence-matrix oracle window {index} minimum submission FPS",
        )
        motion_score = _finite_number(
            window["visualMotionScore"],
            f"cadence-matrix oracle window {index} visual motion",
        )
        distinct_hashes = _integer(
            window["distinctFrameHashes"],
            f"cadence-matrix oracle window {index} distinct frames",
        )
        if motion_score != visual["changedPixelScore"] or distinct_hashes != len(
            set(visual["frameHashes"])
        ):
            raise QualificationPolicyError(
                "cadence-matrix oracle differs from retained UI frames"
            )
        if (
            profile not in required_profiles
            or requested_rate not in {0.5, 1.0, 2.0}
            or applied_rate not in {0.5, 1.0, 2.0}
            or abs(requested_rate - applied_rate) > 0.001
            or start < 0
            or duration < CADENCE_WINDOW_SECONDS
            or duration > CADENCE_WINDOW_SECONDS + 1
            or submitted <= 0
            or abs(submitted / duration - observed_fps) > 0.000001
            or observed_fps + 1e-9 < minimum_fps
            or motion_score < CADENCE_VISUAL_MOTION_MINIMUM_SCORE
            or distinct_hashes < 3
            or (elapsed_values and start <= elapsed_values[-1])
        ):
            raise QualificationPolicyError(
                f"cadence-matrix oracle window {index} violates cadence policy"
            )
        elapsed_values.append(start)
        observed[profile].add(float(requested_rate))
    if any(rates != {0.5, 1.0, 2.0} for rates in observed.values()):
        raise QualificationPolicyError(
            "cadence-matrix did not prove 0.5x/1x/2x for every CFR/VFR fixture"
        )


def validate_cadence_semantics_probe_payload(payload: object) -> dict:
    """Validate the short non-release cadence probe from its raw measurements."""

    report = _exact_object(
        payload,
        CADENCE_SEMANTICS_PROBE_REPORT_KEYS,
        "cadence semantics probe payload",
    )
    started = _finite_number(
        report["startedSystemUptime"], "cadence semantics probe start uptime"
    )
    ended = _finite_number(
        report["endedSystemUptime"], "cadence semantics probe end uptime"
    )
    if (
        report["formatVersion"] != 1
        or report["purpose"]
        != "exploratory-vmem-output-attempt-cadence-semantics"
        or report["releaseCreditEligible"] is not False
        or report["vmemOutputTimestampProvenance"]
        != CADENCE_VMEM_OUTPUT_TIMESTAMP_PROVENANCE
        or report["targetWindowSeconds"] != CADENCE_WINDOW_SECONDS
        or report["settlingSeconds"] != 2
        or started <= 0
        or ended <= started
    ):
        raise QualificationPolicyError(
            "cadence semantics probe top-level contract changed"
        )
    windows = report["windows"]
    if not isinstance(windows, list) or len(windows) != len(
        CADENCE_SEMANTICS_PROBE_EXPECTED_WINDOWS
    ):
        raise QualificationPolicyError(
            "cadence semantics probe must contain exactly nine windows"
        )

    raw_window_values: list[dict] = []
    prior_window_end: float | None = None
    raw_counter_fields = {
        "vmemOutputCallbackCount",
        "vmemOutputValidPTSCount",
        "vmemOutputInvalidPTSCount",
        "vmemOutputDuplicatePTSCount",
        "vmemOutputBackwardPTSCount",
        "vmemOutputDeltaOverflowCount",
        "vmemOutputSubmittedCount",
        "vmemOutputSwiftRejectedCount",
        "vmemOutputInFlightCount",
        *CADENCE_SEMANTICS_PROBE_RENDERER_COUNTERS.values(),
        *CADENCE_SEMANTICS_PROBE_LIBVLC_COUNTERS.values(),
    }
    for index, (raw_window, expected) in enumerate(
        zip(windows, CADENCE_SEMANTICS_PROBE_EXPECTED_WINDOWS)
    ):
        window = _exact_object(
            raw_window,
            CADENCE_SEMANTICS_PROBE_WINDOW_KEYS,
            f"cadence semantics probe window {index}",
        )
        profile, expected_rate = expected
        requested_rate = _finite_number(
            window["requestedRate"],
            f"cadence semantics probe window {index} requested rate",
        )
        window_start = _finite_number(
            window["windowStartSystemUptime"],
            f"cadence semantics probe window {index} start uptime",
        )
        window_end = _finite_number(
            window["windowEndSystemUptime"],
            f"cadence semantics probe window {index} end uptime",
        )
        duration = _finite_number(
            window["windowDurationSeconds"],
            f"cadence semantics probe window {index} duration",
        )
        if (
            window["profile"] != profile
            or abs(requested_rate - expected_rate) > 0.000001
            or duration < CADENCE_WINDOW_SECONDS
            or duration > CADENCE_WINDOW_SECONDS + 1
            or abs((window_end - window_start) - duration) > 0.000001
            or window_start < started
            or window_end > ended
            or (prior_window_end is not None and window_start <= prior_window_end)
        ):
            raise QualificationPolicyError(
                f"cadence semantics probe window {index} identity/timing changed"
            )
        prior_window_end = window_end

        before = window["before"]
        after = window["after"]
        if not isinstance(before, dict) or not isinstance(after, dict):
            raise QualificationPolicyError(
                f"cadence semantics probe window {index} has no raw boundaries"
            )
        required_snapshot_fields = {
            "systemUptime",
            "playbackGeneration",
            "isPlaybackActive",
            "isPictureInPictureActive",
            "requestedRate",
            "effectivePlayerRate",
            "mediaTimeSeconds",
            "controlTimebaseSeconds",
            "controlTimebaseRate",
            "vmemOutputTimestampProvenance",
            "vmemOutputPlaybackGeneration",
            "vmemOutputVoutGeneration",
            "vmemOutputLastValidPTSUS",
            "vmemOutputDeltaHistogram",
            *raw_counter_fields,
        }
        if not required_snapshot_fields.issubset(before) or not (
            required_snapshot_fields.issubset(after)
        ):
            raise QualificationPolicyError(
                f"cadence semantics probe window {index} raw boundaries are incomplete"
            )

        snapshot_counters: list[dict[str, int]] = []
        snapshot_histograms: list[dict[int, int]] = []
        for label, snapshot, expected_uptime in (
            ("before", before, window_start),
            ("after", after, window_end),
        ):
            uptime = _finite_number(
                snapshot["systemUptime"],
                f"cadence semantics probe window {index} {label} uptime",
            )
            effective = _finite_number(
                snapshot["effectivePlayerRate"],
                f"cadence semantics probe window {index} {label} effective rate",
            )
            compatible_rate = _finite_number(
                snapshot["requestedRate"],
                f"cadence semantics probe window {index} {label} compatibility rate",
            )
            control_rate = _finite_number(
                snapshot["controlTimebaseRate"],
                f"cadence semantics probe window {index} {label} timebase rate",
            )
            playback_generation = _integer(
                snapshot["playbackGeneration"],
                f"cadence semantics probe window {index} {label} generation",
            )
            output_generation = _integer(
                snapshot["vmemOutputPlaybackGeneration"],
                f"cadence semantics probe window {index} {label} output generation",
            )
            vout_generation = _integer(
                snapshot["vmemOutputVoutGeneration"],
                f"cadence semantics probe window {index} {label} vout generation",
            )
            counters = {
                field: _integer(
                    snapshot[field],
                    f"cadence semantics probe window {index} {label} {field}",
                )
                for field in raw_counter_fields
            }
            if any(value < 0 for value in counters.values()):
                raise QualificationPolicyError(
                    f"cadence semantics probe window {index} has a negative counter"
                )
            histogram = _cadence_delta_histogram(
                snapshot["vmemOutputDeltaHistogram"],
                f"cadence semantics probe window {index} {label} PTS histogram",
            )
            callbacks = counters["vmemOutputCallbackCount"]
            valid = counters["vmemOutputValidPTSCount"]
            invalid = counters["vmemOutputInvalidPTSCount"]
            submitted = counters["vmemOutputSubmittedCount"]
            rejected = counters["vmemOutputSwiftRejectedCount"]
            in_flight = counters["vmemOutputInFlightCount"]
            if (
                abs(uptime - expected_uptime) > 0.000001
                or snapshot["isPlaybackActive"] is not True
                or snapshot["isPictureInPictureActive"] is not True
                or abs(effective - requested_rate) > 0.001
                or abs(compatible_rate - requested_rate) > 0.001
                or abs(control_rate - requested_rate) > 0.001
                or playback_generation <= 0
                or output_generation != playback_generation
                or vout_generation <= 0
                or snapshot["vmemOutputTimestampProvenance"]
                != CADENCE_VMEM_OUTPUT_TIMESTAMP_PROVENANCE
                or valid + invalid != callbacks
                or submitted + rejected + in_flight != callbacks
                or in_flight != 0
                or histogram.get(0, 0)
                != counters["vmemOutputDuplicatePTSCount"]
                or sum(count for delta, count in histogram.items() if delta < 0)
                != counters["vmemOutputBackwardPTSCount"]
                or sum(histogram.values()) != max(0, valid - 1)
            ):
                raise QualificationPolicyError(
                    f"cadence semantics probe window {index} {label} raw boundary "
                    "violates native callback conservation"
                )
            snapshot_counters.append(counters)
            snapshot_histograms.append(histogram)

        if any(
            before[field] != after[field]
            for field in (
                "playbackGeneration",
                "vmemOutputPlaybackGeneration",
                "vmemOutputVoutGeneration",
            )
        ):
            raise QualificationPolicyError(
                f"cadence semantics probe window {index} changed generation"
            )
        first_counters, last_counters = snapshot_counters
        histogram_delta = _cadence_histogram_delta(
            snapshot_histograms[0],
            snapshot_histograms[1],
            f"cadence semantics probe window {index} PTS histogram",
        )

        def raw_delta(field: str) -> int:
            value = last_counters[field] - first_counters[field]
            if value < 0:
                raise QualificationPolicyError(
                    f"cadence semantics probe window {index} {field} moved backwards"
                )
            return value

        if (
            histogram_delta.get(0, 0)
            != raw_delta("vmemOutputDuplicatePTSCount")
            or sum(
                count for delta, count in histogram_delta.items() if delta < 0
            )
            != raw_delta("vmemOutputBackwardPTSCount")
        ):
            raise QualificationPolicyError(
                f"cadence semantics probe window {index} PTS anomaly counters "
                "differ from the lossless histogram"
            )

        callbacks = _integer(
            window["outputCallbackCount"],
            f"cadence semantics probe window {index} callbacks",
        )
        valid = _integer(
            window["validPTSCount"],
            f"cadence semantics probe window {index} valid PTS",
        )
        invalid = _integer(
            window["invalidPTSCount"],
            f"cadence semantics probe window {index} invalid PTS",
        )
        submitted = _integer(
            window["submittedFrames"],
            f"cadence semantics probe window {index} submitted frames",
        )
        rejected = _integer(
            window["swiftRejectedFrames"],
            f"cadence semantics probe window {index} rejected frames",
        )
        in_flight_start = _integer(
            window["inFlightStart"],
            f"cadence semantics probe window {index} start in-flight callbacks",
        )
        in_flight_end = _integer(
            window["inFlightEnd"],
            f"cadence semantics probe window {index} end in-flight callbacks",
        )
        summarized_boundary_rates = (
            (
                "effectivePlayerRateStart",
                before["effectivePlayerRate"],
            ),
            (
                "effectivePlayerRateEnd",
                after["effectivePlayerRate"],
            ),
            (
                "controlTimebaseRateStart",
                before["controlTimebaseRate"],
            ),
            (
                "controlTimebaseRateEnd",
                after["controlTimebaseRate"],
            ),
        )
        if any(
            abs(
                _finite_number(
                    window[field],
                    f"cadence semantics probe window {index} {field}",
                )
                - _finite_number(
                    raw,
                    f"cadence semantics probe window {index} raw {field}",
                )
            )
            > 0.000001
            for field, raw in summarized_boundary_rates
        ):
            raise QualificationPolicyError(
                f"cadence semantics probe window {index} rate summary differs "
                "from raw boundaries"
            )
        expected_histogram = [
            {"deltaMicroseconds": delta, "count": count}
            for delta, count in histogram_delta.items()
        ]
        if (
            callbacks != raw_delta("vmemOutputCallbackCount")
            or valid != raw_delta("vmemOutputValidPTSCount")
            or invalid != raw_delta("vmemOutputInvalidPTSCount")
            or submitted != raw_delta("vmemOutputSubmittedCount")
            or rejected != raw_delta("vmemOutputSwiftRejectedCount")
            or callbacks <= 0
            or callbacks != valid + invalid
            or callbacks != submitted + rejected
            or callbacks != sum(histogram_delta.values())
            or invalid != 0
            or submitted <= 0
            or in_flight_start != first_counters["vmemOutputInFlightCount"]
            or in_flight_end != last_counters["vmemOutputInFlightCount"]
            or in_flight_start != 0
            or in_flight_end != 0
            or window["callbackConservationAtStart"] is not True
            or window["callbackConservationAtEnd"] is not True
            or window["callbackDeltaConservation"] is not True
            or not _json_same(window["nativePTSDeltaHistogram"], expected_histogram)
        ):
            raise QualificationPolicyError(
                f"cadence semantics probe window {index} summarized callback "
                "conservation differs from raw boundaries"
            )

        start_pts = _cadence_int64(
            before["vmemOutputLastValidPTSUS"],
            f"cadence semantics probe window {index} start PTS",
        )
        end_pts = _cadence_int64(
            after["vmemOutputLastValidPTSUS"],
            f"cadence semantics probe window {index} end PTS",
        )
        native_delta_us = end_pts - start_pts
        histogram_span = sum(
            delta * count for delta, count in histogram_delta.items()
        )
        native_delta = _finite_number(
            window["nativePTSDeltaSeconds"],
            f"cadence semantics probe window {index} native PTS delta",
        )
        media_delta = _finite_number(
            window["mediaTimeDeltaSeconds"],
            f"cadence semantics probe window {index} media delta",
        )
        control_delta = _finite_number(
            window["controlTimebaseDeltaSeconds"],
            f"cadence semantics probe window {index} timebase delta",
        )
        raw_media_delta = _finite_number(
            after["mediaTimeSeconds"],
            f"cadence semantics probe window {index} ending media time",
        ) - _finite_number(
            before["mediaTimeSeconds"],
            f"cadence semantics probe window {index} starting media time",
        )
        raw_control_delta = _finite_number(
            after["controlTimebaseSeconds"],
            f"cadence semantics probe window {index} ending timebase",
        ) - _finite_number(
            before["controlTimebaseSeconds"],
            f"cadence semantics probe window {index} starting timebase",
        )
        for value, description in (
            (native_delta, "native PTS"),
            (media_delta, "media clock"),
            (control_delta, "control timebase"),
        ):
            if (
                value <= 0
                or abs(value / duration - requested_rate) / requested_rate
                > CADENCE_RATE_TOLERANCE_FRACTION
            ):
                raise QualificationPolicyError(
                    f"cadence semantics probe window {index} {description} rate "
                    "does not match the request"
                )
        if (
            native_delta_us <= 0
            or native_delta_us != histogram_span
            or window["nativePTSDeltaMatchesHistogram"] is not True
            or abs(native_delta - native_delta_us / 1_000_000) > 0.000001
            or abs(media_delta - raw_media_delta) > 0.000001
            or abs(control_delta - raw_control_delta) > 0.000001
        ):
            raise QualificationPolicyError(
                f"cadence semantics probe window {index} clock/PTS summary "
                "differs from raw boundaries"
        )
        if profile == "vfr-24-60":
            _validate_cadence_vfr_regimes(
                histogram_delta,
                start_pts,
                end_pts,
                f"cadence semantics probe window {index}",
            )

        classification = _exact_object(
            window["nativePTSClassification"],
            CADENCE_SEMANTICS_PROBE_CLASSIFICATION_KEYS,
            f"cadence semantics probe window {index} PTS classification",
        )
        classified = _classify_cadence_window_histogram(profile, histogram_delta)
        overflow = raw_delta("vmemOutputDeltaOverflowCount")
        expected_classification = {
            "exactIntervalCount": classified["nativePTSExactIntervalCount"],
            "multipleIntervalCount": classified["nativePTSMultipleIntervalCount"],
            "estimatedSkippedPictureCount": classified[
                "nativePTSEstimatedSkippedPictureCount"
            ],
            "redisplayCount": classified["nativePTSRedisplayCount"],
            "backwardCount": classified["nativePTSBackwardCount"],
            "unclassifiedIntervalCount": classified[
                "nativePTSUnclassifiedIntervalCount"
            ],
            "deltaOverflowCount": overflow,
        }
        if (
            not _json_same(classification, expected_classification)
            or classification["backwardCount"] != 0
            or classification["unclassifiedIntervalCount"] != 0
            or classification["deltaOverflowCount"] != 0
        ):
            raise QualificationPolicyError(
                f"cadence semantics probe window {index} PTS classification "
                "differs from its lossless histogram"
            )

        observed_fps = _finite_number(
            window["observedSubmissionFPS"],
            f"cadence semantics probe window {index} submission FPS",
        )
        minimum_fps = _cadence_minimum_submission_fps(
            profile=profile,
            applied_rate=requested_rate,
            window_duration=duration,
            start_pts_us=start_pts,
            end_pts_us=end_pts,
        )
        if (
            abs(observed_fps - submitted / duration) > 0.000001
            or observed_fps + 1e-9 < minimum_fps
        ):
            raise QualificationPolicyError(
                f"cadence semantics probe window {index} undersubmitted frames"
            )

        renderer = _exact_object(
            window["renderer"],
            set(CADENCE_SEMANTICS_PROBE_RENDERER_COUNTERS),
            f"cadence semantics probe window {index} renderer deltas",
        )
        renderer_values = {
            output: _integer(
                renderer[output],
                f"cadence semantics probe window {index} renderer {output}",
            )
            for output in CADENCE_SEMANTICS_PROBE_RENDERER_COUNTERS
        }
        if any(value < 0 for value in renderer_values.values()) or any(
            renderer_values[output] != raw_delta(snapshot_field)
            for output, snapshot_field in (
                CADENCE_SEMANTICS_PROBE_RENDERER_COUNTERS.items()
            )
        ):
            raise QualificationPolicyError(
                f"cadence semantics probe window {index} renderer summary "
                "differs from raw boundaries"
            )
        if (
            renderer_values["vmemLockAttempts"] <= 0
            or renderer_values["vmemLockSuccesses"] <= 0
            or renderer_values["vmemDisplayCallbacks"] <= 0
            or renderer_values["deliveredFrames"] <= 0
            or any(
                renderer_values[field] != 0
                for field in (
                    "vmemPoolUnavailable",
                    "vmemBaseAddressLockFailures",
                    "vmemPendingInstallFailures",
                    "vmemDisplayConsumeFailures",
                    "presentationCopyFailures",
                    "decodePoolAllocationFailures",
                    "renderPoolAllocationFailures",
                )
            )
        ):
            raise QualificationPolicyError(
                f"cadence semantics probe window {index} renderer did not "
                "deliver cleanly"
            )

        libvlc = _exact_object(
            window["libVLC"],
            set(CADENCE_SEMANTICS_PROBE_LIBVLC_COUNTERS),
            f"cadence semantics probe window {index} libVLC deltas",
        )
        libvlc_values = {
            output: _integer(
                libvlc[output],
                f"cadence semantics probe window {index} libVLC {output}",
            )
            for output in CADENCE_SEMANTICS_PROBE_LIBVLC_COUNTERS
        }
        if (
            any(value < 0 for value in libvlc_values.values())
            or any(
                libvlc_values[output] != raw_delta(snapshot_field)
                for output, snapshot_field in (
                    CADENCE_SEMANTICS_PROBE_LIBVLC_COUNTERS.items()
                )
            )
            or libvlc_values["decodedVideo"] <= 0
            or libvlc_values["displayedPictures"] <= 0
        ):
            raise QualificationPolicyError(
                f"cadence semantics probe window {index} has no independent "
                "libVLC progress"
            )
        raw_window_values.append(window)

    springboard = _exact_object(
        report["springBoardFrames"],
        {
            "formatVersion",
            "method",
            "framesPerWindow",
            "captureBoundaryGuardSeconds",
            "records",
        },
        "cadence semantics probe SpringBoard frames",
    )
    records = springboard["records"]
    capture_guard = _finite_number(
        springboard["captureBoundaryGuardSeconds"],
        "cadence semantics probe SpringBoard capture boundary guard",
    )
    if (
        springboard["formatVersion"] != 1
        or springboard["method"] != VISUAL_OBSERVATION_METHOD
        or springboard["framesPerWindow"] != 3
        or abs(
            capture_guard
            - CADENCE_SEMANTICS_PROBE_CAPTURE_BOUNDARY_GUARD_SECONDS
        )
        > 0.000001
        or not isinstance(records, list)
        or len(records) != len(raw_window_values)
    ):
        raise QualificationPolicyError(
            "cadence semantics probe SpringBoard frame contract changed"
        )
    prior_capture_end: float | None = None
    for index, (raw_record, window) in enumerate(zip(records, raw_window_values)):
        record = _exact_object(
            raw_record,
            CADENCE_SEMANTICS_PROBE_SPRINGBOARD_RECORD_KEYS,
            f"cadence semantics probe SpringBoard record {index}",
        )
        for field in ("profile", "requestedRate"):
            if not _json_same(record[field], window[field]):
                raise QualificationPolicyError(
                    f"cadence semantics probe SpringBoard record {index} "
                    f"{field} differs from its native window"
                )
        window_start = _finite_number(
            record["windowStartSystemUptime"],
            f"cadence semantics probe SpringBoard record {index} start",
        )
        window_end = _finite_number(
            record["windowEndSystemUptime"],
            f"cadence semantics probe SpringBoard record {index} end",
        )
        if (
            abs(window_start - float(window["windowStartSystemUptime"])) > 0.000001
            or abs(window_end - float(window["windowEndSystemUptime"])) > 0.000001
        ):
            raise QualificationPolicyError(
                f"cadence semantics probe SpringBoard record {index} window drifted"
            )
        capture_start_values = record["captureStartSystemUptimes"]
        capture_end_values = record["captureEndSystemUptimes"]
        capture_values = record["captureSystemUptimes"]
        encoded_frames = record["canonicalRGB8Base64"]
        if (
            not isinstance(capture_start_values, list)
            or len(capture_start_values) != 3
            or not isinstance(capture_end_values, list)
            or len(capture_end_values) != 3
            or not isinstance(capture_values, list)
            or len(capture_values) != 3
            or not isinstance(encoded_frames, list)
            or len(encoded_frames) != 3
        ):
            raise QualificationPolicyError(
                f"cadence semantics probe SpringBoard record {index} must retain "
                "three raw frames"
            )
        capture_starts = [
            _finite_number(
                value,
                f"cadence semantics probe SpringBoard record {index} "
                f"capture {offset} start",
            )
            for offset, value in enumerate(capture_start_values)
        ]
        capture_ends = [
            _finite_number(
                value,
                f"cadence semantics probe SpringBoard record {index} "
                f"capture {offset} end",
            )
            for offset, value in enumerate(capture_end_values)
        ]
        capture_midpoints = [
            _finite_number(
                value,
                f"cadence semantics probe SpringBoard record {index} capture {offset}",
            )
            for offset, value in enumerate(capture_values)
        ]
        if (
            any(end <= start for start, end in zip(capture_starts, capture_ends))
            or any(
                abs(midpoint - ((start + end) / 2)) > 0.000001
                for start, end, midpoint in zip(
                    capture_starts, capture_ends, capture_midpoints
                )
            )
            or any(
                start < window_start + capture_guard
                or end > window_end - capture_guard
                for start, end in zip(capture_starts, capture_ends)
            )
            or any(
                current_start <= previous_end
                for previous_end, current_start in zip(
                    capture_ends, capture_starts[1:]
                )
            )
            or (
                prior_capture_end is not None
                and capture_starts[0] <= prior_capture_end
            )
        ):
            raise QualificationPolicyError(
                f"cadence semantics probe SpringBoard record {index} captures "
                "are outside its native window"
            )
        prior_capture_end = capture_ends[-1]
        frames = [
            _decode_canonical_visual_frame(
                value,
                f"cadence semantics probe SpringBoard record {index} frame {offset}",
            )
            for offset, value in enumerate(encoded_frames)
        ]
        hashes = [_canonical_visual_frame_hash(frame) for frame in frames]
        ratios = [
            _canonical_visual_changed_pixel_ratio(first, second)
            for first, second in zip(frames, frames[1:])
        ]
        score = min(ratios)
        reported_ratios = record["adjacentChangedPixelRatios"]
        if not isinstance(reported_ratios, list) or len(reported_ratios) != 2:
            raise QualificationPolicyError(
                f"cadence semantics probe SpringBoard record {index} has "
                "malformed motion ratios"
            )
        normalized_reported_ratios = [
            _finite_number(
                value,
                f"cadence semantics probe SpringBoard record {index} ratio {offset}",
            )
            for offset, value in enumerate(reported_ratios)
        ]
        if (
            record["frameHashes"] != hashes
            or len(set(hashes)) != 3
            or any(
                abs(float(observed) - expected) > 1e-12
                for observed, expected in zip(normalized_reported_ratios, ratios)
            )
            or abs(
                _finite_number(
                    record["changedPixelScore"],
                    f"cadence semantics probe SpringBoard record {index} motion",
                )
                - score
            )
            > 1e-12
            or score < CADENCE_VISUAL_MOTION_MINIMUM_SCORE
        ):
            raise QualificationPolicyError(
                f"cadence semantics probe SpringBoard record {index} raw-frame "
                "motion did not replay"
            )
    return report


def validate_vod_controls_evidence(evidence: dict) -> None:
    _validate_raw_evidence_shape(
        evidence,
        VOD_CONTROLS_RAW_EVIDENCE_KEYS,
        "vod-controls",
        duration_is_host_owned=True,
    )
    status_keys = {
        "play",
        "pause",
        "scrub",
        "skipForward",
        "skipBackward",
        "skipPastZero",
        "postBoundaryForward",
    }
    summary_events = _exact_object(
        evidence.get("events"),
        {"started", "unexpectedStopCount", "order"},
        "vod-controls summary events",
    )
    summary_controls = _exact_object(
        evidence.get("controls"), status_keys, "vod-controls summary controls"
    )
    motion = _exact_object(
        evidence.get("systemPiPMotion"),
        {"native", "direct"},
        "vod-controls system PiP motion",
    )
    backend_results = _exact_object(
        evidence.get("backendResults"),
        {"native", "direct"},
        "vod-controls backend results",
    )
    if (
        evidence.get("formatVersion") != 1
        or evidence.get("scenario") != "vod-controls"
        or not _json_same(
            summary_events,
            {"started": True, "unexpectedStopCount": 0, "order": "pass"},
        )
        or any(value != "pass" for value in summary_controls.values())
        or not _json_same(motion, {"native": "pass", "direct": "pass"})
    ):
        raise QualificationPolicyError("vod-controls summary contract did not pass")

    control_keys = status_keys | {
        "pauseObservationDurationMilliseconds",
        "maximumPausedClockDeltaMilliseconds",
        "pausedBeforeMilliseconds",
        "pausedAfterMilliseconds",
        "scrubTargetMilliseconds",
        "scrubLandedTimeMilliseconds",
        "presentedBeforeScrub",
        "presentedAfterScrub",
        "forwardBeforeMilliseconds",
        "forwardAfterMilliseconds",
        "backwardBeforeMilliseconds",
        "backwardAfterMilliseconds",
        "zeroBoundaryBeforeMilliseconds",
        "zeroBoundaryOffsetMilliseconds",
        "zeroBoundaryAfterMilliseconds",
        "presentedBeforeZeroBoundary",
        "presentedAfterZeroBoundary",
        "postBoundaryForwardBeforeMilliseconds",
        "postBoundaryForwardAfterMilliseconds",
    }
    expected_commands = {
        "native": "nativeMediaController",
        "direct": "sampleBufferPlaybackDelegate",
    }
    for backend in ("native", "direct"):
        record = _exact_object(
            backend_results[backend],
            {
                "formatVersion",
                "scenario",
                "backend",
                "commandPath",
                "orderedEvents",
                "events",
                "controls",
            },
            f"vod-controls {backend} backend",
        )
        events = _exact_object(
            record["events"],
            {"started", "unexpectedStopCount", "order"},
            f"vod-controls {backend} events",
        )
        controls = _exact_object(
            record["controls"], control_keys, f"vod-controls {backend} controls"
        )
        ordered_events = record["orderedEvents"]
        required_lifecycle = [
            "willStart",
            "didStart",
            "willStop:programmatic",
            "didStop:programmatic",
        ]
        if (
            record["formatVersion"] != 1
            or record["scenario"] != "vod-controls"
            or record["backend"] != backend
            or record["commandPath"] != expected_commands[backend]
            or not isinstance(ordered_events, list)
            or any(not isinstance(item, str) for item in ordered_events)
            or any(ordered_events.count(item) != 1 for item in required_lifecycle)
            or not all(
                ordered_events.index(previous) < ordered_events.index(current)
                for previous, current in zip(required_lifecycle, required_lifecycle[1:])
            )
            or not _json_same(
                events,
                {"started": True, "unexpectedStopCount": 0, "order": "pass"},
            )
            or sum(
                item.startswith("didStop:") and item != "didStop:programmatic"
                for item in ordered_events
            )
            != 0
            or any(controls[field] != "pass" for field in status_keys)
        ):
            raise QualificationPolicyError(
                f"vod-controls {backend} lifecycle/status claims are invalid"
            )

        numbers = {
            field: _integer(
                controls[field], f"vod-controls {backend} control field {field}"
            )
            for field in control_keys - status_keys
        }
        for field in (
            "presentedBeforeScrub",
            "presentedAfterScrub",
            "presentedBeforeZeroBoundary",
            "presentedAfterZeroBoundary",
        ):
            if numbers[field] < 0:
                raise QualificationPolicyError(
                    f"vod-controls {backend} has a negative presentation counter"
                )
        pause_delta = abs(
            numbers["pausedAfterMilliseconds"] - numbers["pausedBeforeMilliseconds"]
        )
        forward_delta = (
            numbers["forwardAfterMilliseconds"] - numbers["forwardBeforeMilliseconds"]
        )
        backward_delta = (
            numbers["backwardAfterMilliseconds"] - numbers["backwardBeforeMilliseconds"]
        )
        post_boundary_delta = (
            numbers["postBoundaryForwardAfterMilliseconds"]
            - numbers["postBoundaryForwardBeforeMilliseconds"]
        )
        if (
            numbers["pauseObservationDurationMilliseconds"] != 1000
            or numbers["maximumPausedClockDeltaMilliseconds"] != 250
            or pause_delta > numbers["maximumPausedClockDeltaMilliseconds"]
            or numbers["scrubTargetMilliseconds"] != 15000
            or abs(
                numbers["scrubLandedTimeMilliseconds"]
                - numbers["scrubTargetMilliseconds"]
            )
            > 2000
            or numbers["presentedAfterScrub"] <= numbers["presentedBeforeScrub"]
            or abs(forward_delta - 10000) > 2000
            or abs(backward_delta + 10000) > 2000
            or numbers["zeroBoundaryBeforeMilliseconds"] <= 0
            or numbers["zeroBoundaryOffsetMilliseconds"]
            != -(numbers["zeroBoundaryBeforeMilliseconds"] + 10000)
            or not (0 <= numbers["zeroBoundaryAfterMilliseconds"] <= 2000)
            or numbers["presentedAfterZeroBoundary"]
            <= numbers["presentedBeforeZeroBoundary"]
            or abs(post_boundary_delta - 3000) > 2000
        ):
            raise QualificationPolicyError(
                f"vod-controls {backend} raw clocks/counters do not derive pass"
            )


def _native_recovery_uint64(value: object, description: str) -> int:
    result = _integer(value, description)
    if result < 0 or result > (1 << 64) - 1:
        raise QualificationPolicyError(f"{description} is outside UInt64")
    return result


def _validate_native_recovery_counter_relationships(
    counters: dict, description: str
) -> None:
    values = {
        field: _native_recovery_uint64(counters[field], f"{description} {field}")
        for field in NATIVE_RENDERER_RECOVERY_COUNTER_KEYS
    }
    recovery_flush_sources = (
        values["revocationFlushCount"] + values["failureFlushCount"]
    )
    if (
        recovery_flush_sources > (1 << 64) - 1
        or values["revocationNotificationCount"]
        > values["requirementNotificationCount"]
        or values["recoveryFlushCount"] != recovery_flush_sources
        or values["recoveredEpisodeCount"] > values["recoveryEpisodeCount"]
        or values["recoverySubmissionCount"] > values["recoveredEpisodeCount"]
        or values["recoverySubmissionCount"] > values["successfulSubmissionCount"]
        or values["permanentFailureCount"] > values["failureFlushCount"]
    ):
        raise QualificationPolicyError(
            f"{description} contains impossible native recovery counter relationships"
        )


def _native_recovery_snapshot(value: object, description: str) -> dict:
    snapshot = _exact_object(value, NATIVE_RENDERER_RECOVERY_SNAPSHOT_KEYS, description)
    abi_version = _integer(snapshot["abiVersion"], f"{description} ABI version")
    raw_flags = _integer(snapshot["rawFlags"], f"{description} raw flags")
    display_generation = _native_recovery_uint64(
        snapshot["displayGeneration"], f"{description} display generation"
    )
    for field in NATIVE_RENDERER_RECOVERY_COUNTER_KEYS:
        _native_recovery_uint64(snapshot[field], f"{description} {field}")
    boolean_fields = {
        "isCurrent": 1 << 0,
        "requiresFlush": 1 << 1,
        "isFailed": 1 << 2,
        "isRecoveryInProgress": 1 << 3,
        "hasRecoverySample": 1 << 4,
    }
    expected_flags = 0
    for field, flag in boolean_fields.items():
        observed = snapshot[field]
        if not isinstance(observed, bool):
            raise QualificationPolicyError(f"{description} {field} is not boolean")
        if observed:
            expected_flags |= flag
    if (
        abi_version != 1
        or display_generation <= 0
        or raw_flags < 0
        or raw_flags > 0x1F
        or raw_flags != expected_flags
    ):
        raise QualificationPolicyError(
            f"{description} ABI, generation, flags, and decoded state disagree"
        )
    _validate_native_recovery_counter_relationships(snapshot, description)
    return snapshot


def validate_native_renderer_recovery_evidence(evidence: dict) -> None:
    _validate_raw_evidence_shape(
        evidence,
        NATIVE_RENDERER_RECOVERY_RAW_EVIDENCE_KEYS,
        "native renderer recovery",
        duration_is_host_owned=True,
    )
    if (
        evidence.get("formatVersion") != 1
        or evidence.get("scenario") != "playback-foreground-displaylayer-recovery"
        or evidence.get("renderingPath") != "native"
        or evidence.get("trigger") != "real-os-home-background-foreground-v1"
        or evidence.get("syntheticNotificationsPosted") is not False
        or evidence.get("playbackStateAtBaseline") != "paused"
        or evidence.get("playbackStateAtEvaluation") != "paused"
        or evidence.get("status") != "pass"
        or evidence.get("reason") != "native-mechanics-and-system-pip-motion-proved"
    ):
        raise QualificationPolicyError(
            "native renderer recovery did not retain the exact physical trigger contract"
        )
    cycles = _integer(
        evidence.get("backgroundForegroundCycles"),
        "native renderer recovery background/foreground cycles",
    )
    if cycles < 1 or cycles > 5:
        raise QualificationPolicyError(
            "native renderer recovery has an invalid physical trigger count"
        )

    mechanics = _exact_object(
        evidence.get("mechanics"),
        {
            "formatVersion",
            "outcome",
            "reason",
            "baseline",
            "postForeground",
            "deltas",
            "checks",
        },
        "native renderer recovery mechanics",
    )
    if (
        mechanics["formatVersion"] != 1
        or mechanics["outcome"] != "pass"
        or mechanics["reason"] != "renderer-recovered-after-real-os-revocation"
    ):
        raise QualificationPolicyError(
            "native renderer recovery mechanics were failed or not exercised"
        )
    baseline = _native_recovery_snapshot(
        mechanics["baseline"], "native renderer recovery baseline"
    )
    recovered = _native_recovery_snapshot(
        mechanics["postForeground"], "native renderer recovery post-foreground"
    )
    deltas = _exact_object(
        mechanics["deltas"],
        NATIVE_RENDERER_RECOVERY_COUNTER_KEYS,
        "native renderer recovery deltas",
    )
    expected_deltas: dict[str, int] = {}
    for field in NATIVE_RENDERER_RECOVERY_COUNTER_KEYS:
        before = _native_recovery_uint64(
            baseline[field], f"native renderer recovery baseline {field}"
        )
        after = _native_recovery_uint64(
            recovered[field], f"native renderer recovery post-foreground {field}"
        )
        if after < before:
            raise QualificationPolicyError(
                f"native renderer recovery counter {field} moved backwards"
            )
        expected_deltas[field] = after - before
        if (
            _native_recovery_uint64(
                deltas[field], f"native renderer recovery delta {field}"
            )
            != expected_deltas[field]
        ):
            raise QualificationPolicyError(
                f"native renderer recovery delta {field} was not derived from snapshots"
            )
    _validate_native_recovery_counter_relationships(
        expected_deltas, "native renderer recovery deltas"
    )

    checks = _exact_object(
        mechanics["checks"],
        NATIVE_RENDERER_RECOVERY_CHECK_KEYS,
        "native renderer recovery checks",
    )
    required_advances = {
        "requirementNotificationCount",
        "revocationNotificationCount",
        "foregroundCheckCount",
        "recoveryEpisodeCount",
        "recoveredEpisodeCount",
        "recoveryFlushCount",
        "revocationFlushCount",
        "successfulSubmissionCount",
        "recoverySubmissionCount",
    }
    expected_checks = {
        "sameDisplayGeneration": (
            baseline["displayGeneration"] == recovered["displayGeneration"]
        ),
        "countersMonotonic": True,
        "actualResourceRevocationObserved": (
            expected_deltas["revocationNotificationCount"] > 0
        ),
        "requirementNotificationAdvanced": (
            expected_deltas["requirementNotificationCount"] > 0
        ),
        "revocationNotificationAdvanced": (
            expected_deltas["revocationNotificationCount"] > 0
        ),
        "foregroundCheckAdvanced": (expected_deltas["foregroundCheckCount"] > 0),
        "recoveryEpisodeAdvanced": (expected_deltas["recoveryEpisodeCount"] > 0),
        "recoveredEpisodeAdvanced": (expected_deltas["recoveredEpisodeCount"] > 0),
        "recoveryFlushAdvanced": (expected_deltas["recoveryFlushCount"] > 0),
        "revocationFlushAdvanced": (expected_deltas["revocationFlushCount"] > 0),
        "successfulSubmissionAdvanced": (
            expected_deltas["successfulSubmissionCount"] > 0
        ),
        "recoverySubmissionAdvanced": (expected_deltas["recoverySubmissionCount"] > 0),
        "permanentFailureUnchanged": (expected_deltas["permanentFailureCount"] == 0),
        "episodesBalanced": (
            recovered["recoveryEpisodeCount"] == recovered["recoveredEpisodeCount"]
        ),
        "currentRenderer": recovered["isCurrent"] is True,
        "requiresFlushCleared": recovered["requiresFlush"] is False,
        "failedCleared": recovered["isFailed"] is False,
        "recoveryInProgressCleared": (recovered["isRecoveryInProgress"] is False),
        "recoverySampleAvailable": recovered["hasRecoverySample"] is True,
    }
    if not _json_same(checks, expected_checks) or not all(expected_checks.values()):
        raise QualificationPolicyError(
            "native renderer recovery checks do not match retained counters/state"
        )
    if (
        any(expected_deltas[field] <= 0 for field in required_advances)
        or expected_deltas["permanentFailureCount"] != 0
        or baseline["recoveryEpisodeCount"] != baseline["recoveredEpisodeCount"]
        or baseline["successfulSubmissionCount"] <= 0
        or not baseline["isCurrent"]
        or baseline["requiresFlush"]
        or baseline["isFailed"]
        or baseline["isRecoveryInProgress"]
        or not baseline["hasRecoverySample"]
        or not recovered["isCurrent"]
        or recovered["requiresFlush"]
        or recovered["isFailed"]
        or recovered["isRecoveryInProgress"]
        or not recovered["hasRecoverySample"]
    ):
        raise QualificationPolicyError(
            "native renderer recovery did not prove a balanced healthy recovery episode"
        )

    visual = _exact_object(
        evidence.get("postRecoveryVisualOracle"),
        NATIVE_RENDERER_RECOVERY_VISUAL_KEYS,
        "native renderer recovery visual oracle",
    )
    if (
        visual["formatVersion"] != 1
        or visual["status"] != "pass"
        or visual["reason"] != "moving-system-pip-pixels-observed"
        or visual["surface"] != "system-picture-in-picture"
        or visual["minimumChangedPixelScore"] != CADENCE_VISUAL_MOTION_MINIMUM_SCORE
    ):
        raise QualificationPolicyError(
            "native renderer recovery visual oracle did not pass the system PiP contract"
        )
    binding = _exact_object(
        visual["captureBinding"],
        NATIVE_RENDERER_RECOVERY_VISUAL_BINDING_KEYS,
        "native renderer recovery visual capture binding",
    )
    timestamps_value = binding["captureSystemUptimeSeconds"]
    frames_value = binding["canonicalRGB8Base64"]
    if (
        binding["formatVersion"] != 1
        or binding["method"] != VISUAL_OBSERVATION_METHOD
        or binding["encoding"] != "base64-rgb8-row-major"
        or binding["frameWidthPixels"] != _VISUAL_FRAME_WIDTH
        or binding["frameHeightPixels"] != _VISUAL_FRAME_HEIGHT
        or binding["channelCount"] != _VISUAL_FRAME_CHANNELS
        or binding["bytesPerFrame"] != _VISUAL_FRAME_BYTE_COUNT
        or binding["frameCount"] != 3
        or not isinstance(timestamps_value, list)
        or len(timestamps_value) != 3
        or not isinstance(frames_value, list)
        or len(frames_value) != 3
    ):
        raise QualificationPolicyError(
            "native renderer recovery visual capture binding contract changed"
        )
    timestamps = [
        _finite_number(value, f"native renderer recovery capture time {index}")
        for index, value in enumerate(timestamps_value)
    ]
    if timestamps[0] < 0 or any(
        current <= previous for previous, current in zip(timestamps, timestamps[1:])
    ):
        raise QualificationPolicyError(
            "native renderer recovery capture times are not strictly increasing"
        )
    frames = [
        _decode_canonical_visual_frame(
            value, f"native renderer recovery visual frame {index}"
        )
        for index, value in enumerate(frames_value)
    ]
    hashes = [_canonical_visual_frame_hash(frame) for frame in frames]
    ratios = [
        _canonical_visual_changed_pixel_ratio(first, second)
        for first, second in zip(frames, frames[1:])
    ]
    score = min(ratios)
    observed_ratios = visual["adjacentChangedPixelRatios"]
    if (
        visual["frameHashes"] != hashes
        or not isinstance(observed_ratios, list)
        or len(observed_ratios) != len(ratios)
        or any(
            abs(
                _finite_number(
                    observed,
                    f"native renderer recovery changed-pixel ratio {index}",
                )
                - expected
            )
            > 1e-12
            for index, (observed, expected) in enumerate(zip(observed_ratios, ratios))
        )
        or abs(
            _finite_number(
                visual["changedPixelScore"],
                "native renderer recovery changed-pixel score",
            )
            - score
        )
        > 1e-12
        or visual["distinctFrameHashes"] != len(set(hashes))
        or len(set(hashes)) != 3
        or score < CADENCE_VISUAL_MOTION_MINIMUM_SCORE
    ):
        raise QualificationPolicyError(
            "native renderer recovery visual claims do not replay from retained RGB8"
        )


def validate_performance_evidence(evidence: dict, scenario_id: str) -> None:
    budget = PERFORMANCE_RESOURCE_BUDGETS[scenario_id]
    expected_profile = (
        "1080p60" if scenario_id == "pip-render-performance-1080p60" else "4k60"
    )
    expected_geometry = (1920, 1080) if expected_profile == "1080p60" else (3840, 2160)
    if evidence.get("profile") != expected_profile:
        raise QualificationPolicyError(
            f"{scenario_id} evidence profile is not {expected_profile}"
        )
    duration = _finite_number(
        evidence.get("deviceObservedDurationSeconds"),
        f"{scenario_id} device duration",
    )
    samples = evidence.get("samples")
    if not isinstance(samples, list) or len(samples) < 3:
        raise QualificationPolicyError(f"{scenario_id} has insufficient samples")
    elapsed_values: list[int] = []
    resident_values: list[int] = []
    cpu_values: list[float] = []
    thermal_states: set[str] = set()
    prior_counters: dict[str, int] | None = None
    for index, sample in enumerate(samples):
        if not isinstance(sample, dict):
            raise QualificationPolicyError(f"{scenario_id} sample {index} is malformed")
        elapsed = _integer(
            sample.get("elapsedSeconds"), f"{scenario_id} sample {index} elapsed"
        )
        resident = _integer(
            sample.get("residentBytes"), f"{scenario_id} sample {index} RSS"
        )
        cpu = _finite_number(
            sample.get("cpuSeconds"), f"{scenario_id} sample {index} CPU"
        )
        state = sample.get("thermalState")
        if state not in {"nominal", "fair"}:
            raise QualificationPolicyError(
                f"{scenario_id} sample {index} exceeds the thermal ceiling"
            )
        if (
            sample.get("sourceWidth") != expected_geometry[0]
            or sample.get("sourceHeight") != expected_geometry[1]
            or _integer(
                sample.get("targetWidth"),
                f"{scenario_id} sample {index} target width",
            )
            <= 0
            or _integer(
                sample.get("targetHeight"),
                f"{scenario_id} sample {index} target height",
            )
            <= 0
            or resident <= 0
            or cpu < 0
        ):
            raise QualificationPolicyError(
                f"{scenario_id} sample {index} has invalid measured state"
            )
        for failure_field in (
            "presentationCopyFailures",
            "displayConsumeFailures",
            "renderPoolAllocationFailureCount",
        ):
            if (
                _integer(
                    sample.get(failure_field),
                    f"{scenario_id} sample {index} {failure_field}",
                )
                != 0
            ):
                raise QualificationPolicyError(
                    f"{scenario_id} sample {index} recorded a renderer failure"
                )
        if sample.get("lastRenderPoolAllocationStatus") is not None:
            raise QualificationPolicyError(
                f"{scenario_id} sample {index} recorded a pool allocation status"
            )
        counters = {
            field: _integer(sample.get(field), f"{scenario_id} sample {index} {field}")
            for field in (
                "presentationCopyFrames",
                "decodedContentChanges",
                "deliveredFrameCount",
                "measuredConversionCount",
            )
        }
        if any(value < 0 for value in counters.values()):
            raise QualificationPolicyError(
                f"{scenario_id} sample {index} has negative counters"
            )
        if prior_counters is not None:
            for field in (
                "presentationCopyFrames",
                "decodedContentChanges",
                "deliveredFrameCount",
            ):
                # A replacement may reset a generation-scoped counter, but the
                # first sample after that reset must itself contain progress.
                delta = (
                    counters[field] - prior_counters[field]
                    if counters[field] >= prior_counters[field]
                    else counters[field]
                )
                if delta <= 0:
                    raise QualificationPolicyError(
                        f"{scenario_id} sustained {field} progress stopped"
                    )
        prior_counters = counters
        elapsed_values.append(elapsed)
        resident_values.append(resident)
        cpu_values.append(cpu)
        thermal_states.add(state)
    if (
        elapsed_values[0] > 5
        or elapsed_values[-1] < duration - 5
        or any(
            current <= previous or current - previous > 10
            for previous, current in zip(elapsed_values, elapsed_values[1:])
        )
        or any(
            current < previous for previous, current in zip(cpu_values, cpu_values[1:])
        )
    ):
        raise QualificationPolicyError(
            f"{scenario_id} samples do not continuously cover the device run"
        )

    metrics = _exact_object(
        evidence.get("metrics"),
        {
            "cpu",
            "gpu",
            "rss",
            "energy",
            "thermal",
            "conversionCost",
            "frameDrops",
            "presentationRate",
        },
        f"{scenario_id} metrics",
    )
    cpu_metric = _exact_object(
        metrics["cpu"], {"value", "unit", "source"}, f"{scenario_id} CPU metric"
    )
    cpu_seconds = _finite_number(cpu_metric["value"], f"{scenario_id} CPU seconds")
    if (
        cpu_metric["unit"] != "cpu-seconds"
        or cpu_metric["source"] != "Mach task thread times"
        or abs(cpu_seconds - (cpu_values[-1] - cpu_values[0])) > 0.1
        or cpu_seconds / duration > budget["cpuAverageCores"]
    ):
        raise QualificationPolicyError(f"{scenario_id} exceeds the CPU budget")
    rss = _exact_object(
        metrics["rss"],
        {
            "baselineBytes",
            "peakBytes",
            "finalBytes",
            "growthBytes",
            "limitBytes",
            "peakGrowthBytes",
            "peakLimitBytes",
        },
        f"{scenario_id} RSS metric",
    )
    baseline = resident_values[0]
    peak = max(resident_values)
    final = resident_values[-1]
    growth = max(0, final - baseline)
    peak_growth = max(0, peak - baseline)
    if (
        rss
        != {
            "baselineBytes": baseline,
            "peakBytes": peak,
            "finalBytes": final,
            "growthBytes": growth,
            "limitBytes": 160 * 1_048_576,
            "peakGrowthBytes": peak_growth,
            "peakLimitBytes": 256 * 1_048_576,
        }
        or growth > 160 * 1_048_576
        or peak_growth > 256 * 1_048_576
    ):
        raise QualificationPolicyError(f"{scenario_id} exceeds the RSS budget")
    thermal = _exact_object(
        metrics["thermal"], {"states"}, f"{scenario_id} thermal metric"
    )
    if thermal["states"] != sorted(thermal_states):
        raise QualificationPolicyError(
            f"{scenario_id} thermal metric differs from retained samples"
        )
    conversion = metrics["conversionCost"]
    if not isinstance(conversion, dict):
        raise QualificationPolicyError(f"{scenario_id} conversion metric is malformed")
    measured = _integer(
        conversion.get("measuredConversions"), f"{scenario_id} conversions"
    )
    average_ms = _finite_number(
        conversion.get("averageMilliseconds"),
        f"{scenario_id} average conversion cost",
    )
    maximum_ms = _finite_number(
        conversion.get("maximumMilliseconds"),
        f"{scenario_id} maximum conversion cost",
    )
    if (
        measured <= 0
        or average_ms <= 0
        or maximum_ms < average_ms
        or average_ms > budget["conversionAverageMilliseconds"]
        or maximum_ms > budget["conversionMaximumMilliseconds"]
    ):
        raise QualificationPolicyError(
            f"{scenario_id} exceeds the conversion-cost budget"
        )
    drops = metrics["frameDrops"]
    presentation = metrics["presentationRate"]
    if (
        not isinstance(drops, dict)
        or _finite_number(drops.get("libVLCDropRate"), f"{scenario_id} VLC drops")
        > 0.05
        or _finite_number(
            drops.get("rendererDropRate"), f"{scenario_id} renderer drops"
        )
        > 0.05
        or not isinstance(presentation, dict)
        or presentation.get("unit") != "frames-per-second"
        or _finite_number(presentation.get("value"), f"{scenario_id} presentation rate")
        < 54
    ):
        raise QualificationPolicyError(
            f"{scenario_id} exceeds the frame-delivery budget"
        )

    raw_motion = _visual_observations(
        evidence,
        record_keys={
            "elapsedSeconds",
            "frameHashes",
            "adjacentChangedPixelRatios",
            "changedPixelScore",
        },
        description=scenario_id,
    )
    expected_motion = [
        {
            "elapsedSeconds": record["elapsedSeconds"],
            "motionScore": record["changedPixelScore"],
            "distinctFrameHashes": len(set(record["frameHashes"])),
        }
        for record in raw_motion
    ]
    motion = evidence.get("systemPiPMotionSeries")
    if not isinstance(motion, list) or not motion:
        raise QualificationPolicyError(
            f"{scenario_id} has no periodic system-PiP motion oracle"
        )
    if not _json_same(motion, expected_motion):
        raise QualificationPolicyError(
            f"{scenario_id} motion oracle differs from retained UI observations"
        )
    motion_elapsed: list[int] = []
    for index, item in enumerate(motion):
        checkpoint = _exact_object(
            item,
            {"elapsedSeconds", "motionScore", "distinctFrameHashes"},
            f"{scenario_id} system PiP motion checkpoint {index}",
        )
        elapsed = _integer(
            checkpoint["elapsedSeconds"],
            f"{scenario_id} system PiP motion checkpoint {index} elapsed",
        )
        score = _finite_number(
            checkpoint["motionScore"],
            f"{scenario_id} system PiP motion checkpoint {index} score",
        )
        hashes = _integer(
            checkpoint["distinctFrameHashes"],
            f"{scenario_id} system PiP motion checkpoint {index} hashes",
        )
        if (
            elapsed < 0
            or score < CADENCE_VISUAL_MOTION_MINIMUM_SCORE
            or hashes < 2
            or (motion_elapsed and elapsed <= motion_elapsed[-1])
        ):
            raise QualificationPolicyError(
                f"{scenario_id} system PiP motion checkpoint {index} is invalid"
            )
        motion_elapsed.append(elapsed)
    if (
        motion_elapsed[0] > PERFORMANCE_VISUAL_MAXIMUM_GAP_SECONDS
        or motion_elapsed[-1] < duration - PERFORMANCE_VISUAL_MAXIMUM_GAP_SECONDS
        or any(
            current - previous > PERFORMANCE_VISUAL_MAXIMUM_GAP_SECONDS
            for previous, current in zip(motion_elapsed, motion_elapsed[1:])
        )
    ):
        raise QualificationPolicyError(
            f"{scenario_id} system PiP motion has a sustained gap"
        )


TRACE_RECORD_KEYS = {
    "status",
    "artifactRole",
    "template",
    "format",
    "runArtifact",
    "tableOfContents",
    "treeDigestAlgorithm",
    "treeDigest",
    "treeSizeBytes",
    "treeEntryCount",
    "tableOfContentsDigestAlgorithm",
    "tableOfContentsDigest",
    "tableOfContentsSizeBytes",
    "targetProcess",
    "producerRunnerScenario",
    "producerSourceAttempt",
    "producerXcresultDigest",
    "evidenceStem",
    "exportSummary",
    "exportSummaryDigestAlgorithm",
    "exportSummaryDigest",
    "exportSummarySizeBytes",
}

TRACE_EXPORT_SUMMARY_KEYS = {
    "formatVersion",
    "status",
    "source",
    "runNumber",
    "scenario",
    "artifactRole",
    "template",
    "targetProcess",
    "targetDeviceIdentifier",
    "captureDurationSeconds",
    "tables",
    "totalRowCount",
    "measurement",
    "traceTreeDigestAlgorithm",
    "traceTreeDigest",
    "tableOfContentsDigestAlgorithm",
    "tableOfContentsDigest",
    "producerRunnerScenario",
    "producerSourceAttempt",
    "producerXcresultDigest",
    "evidenceStem",
}

TRACE_TABLE_SUMMARY_KEYS = {"schema", "rowCount", "targetProcessRowCount"}
TRACE_MEASUREMENT_KEYS = {
    "metric",
    "unit",
    "sampleCount",
    "targetProcessRowCount",
    "minimumValue",
    "averageValue",
    "maximumValue",
    "timelineStartSeconds",
    "timelineEndSeconds",
    "maximumSampleGapSeconds",
    "sourceFields",
}
TRACE_MEASUREMENT_SPECS = {
    "allocation": ("allocated-bytes", "bytes"),
    "gpu": ("gpu-utilization", "percent"),
    "energy": ("energy-impact", "score"),
    "conversionCost": ("output-pixel-buffer-duration", "milliseconds"),
    "cpu": ("cpu-utilization", "percent"),
    "colorHDRImpact": ("metal-gpu-duration", "milliseconds"),
    "audioPresentationSeries": ("audio-render-events", "events"),
}

TIMEBASE_SAMPLE_LINE_KEYS = {"kind", "clock", "audio", "frame"}
TIMEBASE_CLOCK_REQUIRED_KEYS = {
    "elapsedSeconds",
    "mediaTimeSeconds",
    "playbackGeneration",
    "requestedRate",
}
TIMEBASE_CLOCK_OPTIONAL_KEYS = {
    "controlTimebaseSeconds",
    "controlTimebaseRate",
    "driftSeconds",
}
TIMEBASE_AUDIO_KEYS = {
    "elapsedSeconds",
    "mediaTimeSeconds",
    "estimatedPresentationSeconds",
    "outputLatencySeconds",
    "ioBufferDurationSeconds",
    "playedBuffers",
    "lostBuffers",
}
TIMEBASE_FRAME_KEYS = {
    "elapsedSeconds",
    "playbackGeneration",
    "deliveredFrames",
    "droppedFrames",
    "presentedSeconds",
    "decodedFrames",
    "decodedFrameMediaTimeSeconds",
}
TIMEBASE_CORRECTION_REQUIRED_KEYS = {
    "sequence",
    "capturedAt",
    "systemUptime",
    "playbackGeneration",
    "reason",
    "mediaTimeSeconds",
    "previousTimebaseSeconds",
    "correctedTimebaseSeconds",
    "driftSeconds",
}
TIMEBASE_CORRECTION_OPTIONAL_KEYS = {
    "previousTimebaseRate",
    "correctedTimebaseRate",
}
TIMEBASE_CORRECTION_REASONS = {
    "initialSynchronization",
    "playbackStateTransition",
    "playbackRateTransition",
    "steadyStateDrift",
    "skipLanding",
}


def trace_minimum_capture_duration(
    scenario_id: str, role: str, device_duration: float
) -> float:
    if scenario_id == "adaptive-hls-soak":
        return max(1, device_duration - ENDURANCE_SERIES_MAXIMUM_UNCOVERED_SECONDS)
    if scenario_id in {
        "pip-render-performance-1080p60",
        "pip-render-performance-4k60",
        "native-subtitle-matrix",
    }:
        return max(55, (device_duration - 120) // 3 - 5)
    if scenario_id in {"timebase-vod-soak", "timebase-live-soak"}:
        return max(1, device_duration - ENDURANCE_HOST_EARLY_TOLERANCE_SECONDS)
    raise QualificationPolicyError(
        f"{scenario_id} has no trace duration policy for {role}"
    )


def _xml_local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _xctrace_duration(run: ElementTree.Element) -> float:
    values: list[float] = []
    for element in run.iter():
        if _xml_local_name(element.tag).lower() != "duration":
            continue
        text = (element.text or "").strip()
        if re.fullmatch(r"\d+(?:\.\d+)?", text):
            values.append(float(text))
    if values:
        return max(values)
    dates: dict[str, datetime] = {}
    for element in run.iter():
        name = _xml_local_name(element.tag).lower()
        if name not in {"start-date", "end-date"}:
            continue
        text = (element.text or "").strip().replace("Z", "+00:00")
        try:
            dates[name] = datetime.fromisoformat(text)
        except ValueError:
            continue
    if set(dates) == {"start-date", "end-date"}:
        return (dates["end-date"] - dates["start-date"]).total_seconds()
    raise QualificationPolicyError("xctrace TOC has no parseable run duration")


def _xml_context(element: ElementTree.Element) -> str:
    return " ".join(
        [
            _xml_local_name(element.tag),
            *(f"{key}={value}" for key, value in sorted(element.attrib.items())),
        ]
    ).casefold()


def _numeric_xml_value(element: ElementTree.Element) -> float | None:
    text = (element.text or "").strip().replace(",", "")
    if not re.fullmatch(r"[-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?", text):
        return None
    value = float(text)
    return value if math.isfinite(value) else None


def _duration_to_seconds(value: float, context: str) -> float:
    if "nanosecond" in context or re.search(r"\bns\b", context):
        return value / 1_000_000_000
    if "microsecond" in context or re.search(r"\bus\b", context):
        return value / 1_000_000
    if "millisecond" in context or re.search(r"\bms\b", context):
        return value / 1_000
    return value


def _duration_to_milliseconds(value: float, context: str) -> float:
    if "nanosecond" in context or re.search(r"\bns\b", context):
        return value / 1_000_000
    if "microsecond" in context or re.search(r"\bus\b", context):
        return value / 1_000
    if "second" in context or re.search(r"\bsec(?:ond)?s?\b", context):
        return value * 1_000
    return value


def _process_value_matches(value: object, target_process: str) -> bool:
    if not isinstance(value, str):
        return False
    candidate = value.strip()
    if not candidate:
        return False
    return (
        re.fullmatch(
            rf"(?:.*/)?{re.escape(target_process)}(?:\s+\(\d+\))?",
            candidate,
            re.IGNORECASE,
        )
        is not None
    )


def _target_process_references(
    exported: ElementTree.Element, target_process: str
) -> set[str]:
    references: set[str] = set()
    for element in exported.iter():
        if "process" not in _xml_local_name(element.tag).casefold():
            continue
        candidates = [element.text, *element.attrib.values()]
        if any(_process_value_matches(value, target_process) for value in candidates):
            for key in ("id", "ref", "identifier"):
                value = element.attrib.get(key)
                if isinstance(value, str) and value:
                    references.add(value)
    return references


def _row_identifies_target_process(
    row: ElementTree.Element,
    target_process: str,
    target_references: set[str],
) -> bool:
    for element in row.iter():
        tag = _xml_local_name(element.tag).casefold()
        if "process" in tag:
            if any(
                _process_value_matches(value, target_process)
                for value in (element.text, *element.attrib.values())
            ):
                return True
            if any(
                element.attrib.get(key) in target_references
                for key in ("id", "ref", "identifier")
            ):
                return True
        for key, value in element.attrib.items():
            if "process" in key.casefold() and _process_value_matches(
                value, target_process
            ):
                return True
    return False


def _trace_row_measurements(
    row: ElementTree.Element,
    *,
    role: str,
    target_process: str,
    target_references: set[str],
) -> tuple[bool, list[tuple[float, str]], list[float]]:
    serialized = ElementTree.tostring(row, encoding="unicode")
    target = _row_identifies_target_process(row, target_process, target_references)
    if not target:
        return False, [], []
    row_text = serialized.casefold()
    values: list[tuple[float, str]] = []
    timeline: list[float] = []
    for element in row.iter():
        value = _numeric_xml_value(element)
        if value is None:
            continue
        context = _xml_context(element)
        if any(token in context for token in ("timestamp", "start-time", "end-time")):
            timeline.append(_duration_to_seconds(value, context))
        selected = False
        converted = value
        if role == "allocation":
            selected = "alloc" in row_text and any(
                token in context for token in ("byte", "size", "allocation")
            )
        elif role == "gpu":
            selected = "gpu" in row_text and any(
                token in context for token in ("util", "activity", "percent", "%")
            )
        elif role == "energy":
            selected = any(token in row_text for token in ("energy", "power")) and any(
                token in context for token in ("impact", "energy", "power", "score")
            )
        elif role == "conversionCost":
            selected = (
                "pixelbufferrenderer.outputpixelbuffer" in row_text
                and "duration" in context
            )
            converted = _duration_to_milliseconds(value, context)
        elif role == "cpu":
            selected = "cpu" in row_text and any(
                token in context for token in ("util", "weight", "percent", "%")
            )
        elif role == "colorHDRImpact":
            selected = any(token in row_text for token in ("metal", "gpu")) and (
                "duration" in context
            )
            converted = _duration_to_milliseconds(value, context)
        elif role == "audioPresentationSeries":
            selected = any(token in row_text for token in ("audio", "render")) and any(
                token in context for token in ("sample", "frame", "buffer", "render")
            )
        if selected and converted >= 0:
            values.append((converted, context))
    if (
        role == "audioPresentationSeries"
        and not values
        and any(token in row_text for token in ("audio", "render"))
    ):
        values.append((1.0, "audio-render-row"))
    return True, values, timeline


def _trace_measurement_summary(
    exported_tables: list[tuple[str, ElementTree.Element]],
    *,
    role: str,
    target_process: str,
) -> tuple[list[dict], dict]:
    metric, unit = TRACE_MEASUREMENT_SPECS[role]
    values: list[float] = []
    source_fields: set[str] = set()
    timeline: list[float] = []
    tables: list[dict] = []
    target_rows_total = 0
    for schema, exported in exported_tables:
        target_references = _target_process_references(exported, target_process)
        rows = [
            node
            for node in exported.iter()
            if _xml_local_name(node.tag).lower() == "row"
        ]
        target_rows = 0
        for row in rows:
            target, row_values, row_timeline = _trace_row_measurements(
                row,
                role=role,
                target_process=target_process,
                target_references=target_references,
            )
            if target and row_values:
                target_rows += 1
            for value, context in row_values:
                values.append(value)
                source_fields.add(context)
            if row_values:
                timeline.extend(row_timeline)
        target_rows_total += target_rows
        tables.append(
            {
                "schema": schema,
                "rowCount": len(rows),
                "targetProcessRowCount": target_rows,
            }
        )
    timeline = sorted(set(timeline))
    if not values or target_rows_total <= 0 or len(timeline) < 2:
        raise QualificationPolicyError(
            f"xctrace {role} export has no target-bound numeric timeline"
        )
    maximum_gap = max(
        current - previous for previous, current in zip(timeline, timeline[1:])
    )
    return tables, {
        "metric": metric,
        "unit": unit,
        "sampleCount": len(values),
        "targetProcessRowCount": target_rows_total,
        "minimumValue": min(values),
        "averageValue": sum(values) / len(values),
        "maximumValue": max(values),
        "timelineStartSeconds": timeline[0],
        "timelineEndSeconds": timeline[-1],
        "maximumSampleGapSeconds": maximum_gap,
        "sourceFields": sorted(source_fields),
    }


def capture_xctrace_export_summary(
    trace: Path,
    toc: Path,
    *,
    scenario_id: str,
    role: str,
    template: str,
    target_device_identifier: str,
    producer_fields: dict,
) -> dict:
    try:
        toc_root = ElementTree.fromstring(toc.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ElementTree.ParseError) as error:
        raise QualificationPolicyError(f"cannot parse xctrace TOC: {error}") from error
    runs = [node for node in toc_root.iter() if _xml_local_name(node.tag) == "run"]
    if len(runs) != 1:
        raise QualificationPolicyError(
            f"xctrace export must contain exactly one run, found {len(runs)}"
        )
    run = runs[0]
    try:
        run_number = int(run.attrib["number"])
    except (KeyError, TypeError, ValueError) as error:
        raise QualificationPolicyError("xctrace run number is missing") from error
    if run_number != 1:
        raise QualificationPolicyError("xctrace export did not describe run 1")
    toc_text = ElementTree.tostring(toc_root, encoding="unicode")
    for expected, description in (
        (template, "template"),
        ("iOS", "target process"),
        (target_device_identifier, "target device"),
    ):
        if expected.casefold() not in toc_text.casefold():
            raise QualificationPolicyError(
                f"xctrace TOC does not identify expected {description} {expected!r}"
            )
    schemas = sorted(
        {
            node.attrib["schema"]
            for node in run.iter()
            if _xml_local_name(node.tag) == "table"
            and isinstance(node.attrib.get("schema"), str)
            and node.attrib["schema"]
        }
    )
    if not schemas:
        raise QualificationPolicyError("xctrace TOC contains no exported tables")
    exported_tables: list[tuple[str, ElementTree.Element]] = []
    for schema in schemas:
        xpath = (
            f'/trace-toc/run[@number="{run_number}"]/data/' f'table[@schema="{schema}"]'
        )
        try:
            result = subprocess.run(
                [
                    "xcrun",
                    "xctrace",
                    "export",
                    "--quiet",
                    "--input",
                    str(trace),
                    "--xpath",
                    xpath,
                ],
                check=True,
                capture_output=True,
                text=True,
                timeout=120,
            )
            exported = ElementTree.fromstring(result.stdout)
        except (
            OSError,
            subprocess.CalledProcessError,
            subprocess.TimeoutExpired,
            ElementTree.ParseError,
        ) as error:
            raise QualificationPolicyError(
                f"cannot export xctrace table {schema!r}: {error}"
            ) from error
        exported_tables.append((schema, exported))
    tables, measurement = _trace_measurement_summary(
        exported_tables, role=role, target_process="iOS"
    )
    total_rows = sum(table["rowCount"] for table in tables)
    if total_rows <= 0:
        raise QualificationPolicyError("xctrace exports contain zero sample rows")
    return {
        "formatVersion": 1,
        "status": "captured",
        "source": "xctrace-export-v1",
        "runNumber": run_number,
        "scenario": scenario_id,
        "artifactRole": role,
        "template": template,
        "targetProcess": "iOS",
        "targetDeviceIdentifier": target_device_identifier,
        "captureDurationSeconds": _xctrace_duration(run),
        "tables": tables,
        "totalRowCount": total_rows,
        "measurement": measurement,
        "traceTreeDigestAlgorithm": "swiftvlc-tree-v1",
        "traceTreeDigest": tree_digest(trace),
        "tableOfContentsDigestAlgorithm": "sha256",
        "tableOfContentsDigest": sha256_file(toc),
        **producer_fields,
    }


def host_artifact_producer_fields(evidence: dict, evidence_stem: str) -> dict:
    producer = evidence.get("qualificationProducer")
    runner = producer.get("runnerScenario") if isinstance(producer, dict) else None
    attempt = producer.get("sourceAttempt") if isinstance(producer, dict) else None
    xcresult_digest = (
        producer.get("sourceXcresultDigest") if isinstance(producer, dict) else None
    )
    if (
        not isinstance(runner, str)
        or not ID.fullmatch(runner)
        or isinstance(attempt, bool)
        or not isinstance(attempt, int)
        or attempt < 1
        or not isinstance(xcresult_digest, str)
        or not SHA256.fullmatch(xcresult_digest)
        or not isinstance(evidence_stem, str)
        or not ID.fullmatch(evidence_stem)
    ):
        raise QualificationPolicyError(
            "host artifact has no exact final-attempt producer namespace"
        )
    return {
        "producerRunnerScenario": runner,
        "producerSourceAttempt": attempt,
        "producerXcresultDigest": xcresult_digest,
        "evidenceStem": evidence_stem,
    }


def validate_host_trace_record(
    record: object,
    artifact_base: Path,
    *,
    role: str,
    template: str,
    scenario_id: str,
    target_device_identifier: str,
    minimum_duration: float,
    description: str,
    artifact_token: str,
    producer_fields: dict,
    extra: dict[str, object] | None = None,
) -> tuple[Path, Path, Path, dict]:
    extras = extra or {}
    if not isinstance(record, dict) or set(record) != TRACE_RECORD_KEYS | set(extras):
        raise QualificationPolicyError(f"{description} trace schema is not exact")
    for field, expected in {
        "status": "captured",
        "artifactRole": role,
        "template": template,
        "format": "com.apple.instruments.trace",
        "treeDigestAlgorithm": "swiftvlc-tree-v1",
        "tableOfContentsDigestAlgorithm": "sha256",
        "targetProcess": "iOS",
        **producer_fields,
        **extras,
    }.items():
        if record.get(field) != expected:
            raise QualificationPolicyError(
                f"{description} trace {field} differs from immutable policy"
            )
    trace = safe_relative_directory(
        artifact_base, record.get("runArtifact"), f"{description} trace"
    )
    reject_tree_symlinks(trace, f"{description} trace")
    toc = safe_relative_file(
        artifact_base,
        record.get("tableOfContents"),
        f"{description} trace table of contents",
    )
    summary = safe_relative_file(
        artifact_base,
        record.get("exportSummary"),
        f"{description} xctrace export summary",
    )
    expected_parent = Path("artifacts") / producer_fields["evidenceStem"]
    runner = producer_fields["producerRunnerScenario"]
    attempt = producer_fields["producerSourceAttempt"]
    expected_trace = (
        expected_parent / f"{runner}-{artifact_token}-attempt{attempt}.trace"
    )
    expected_toc = (
        expected_parent / f"{runner}-{artifact_token}-attempt{attempt}-toc.xml"
    )
    expected_summary = (
        expected_parent / f"{runner}-{artifact_token}-attempt{attempt}-summary.json"
    )
    if (
        Path(record["runArtifact"]) != expected_trace
        or Path(record["tableOfContents"]) != expected_toc
        or Path(record["exportSummary"]) != expected_summary
    ):
        raise QualificationPolicyError(
            f"{description} paths are outside the final-attempt namespace"
        )
    if (
        record.get("treeDigest") != tree_digest(trace)
        or record.get("treeSizeBytes") != tree_size_bytes(trace)
        or record.get("treeEntryCount") != tree_entry_count(trace)
        or record.get("tableOfContentsDigest") != sha256_file(toc)
        or record.get("tableOfContentsSizeBytes") != toc.stat().st_size
        or record.get("exportSummaryDigestAlgorithm") != "sha256"
        or record.get("exportSummaryDigest") != sha256_file(summary)
        or record.get("exportSummarySizeBytes") != summary.stat().st_size
    ):
        raise QualificationPolicyError(f"{description} retained trace binding mismatch")
    try:
        toc_text = toc.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise QualificationPolicyError(
            f"{description} trace table of contents is not readable UTF-8"
        ) from error
    lower = toc_text.lower()
    if template == "Allocations":
        valid_toc = "allocation" in lower or "vm-tracker" in lower
    elif template == "Audio System Trace":
        valid_toc = "audio" in lower
    else:
        valid_toc = "schema" in lower or "table" in lower
    if not valid_toc:
        raise QualificationPolicyError(
            f"{description} trace table of contents contradicts its template"
        )
    export_summary = load_json(summary, f"{description} xctrace export summary")
    if set(export_summary) != TRACE_EXPORT_SUMMARY_KEYS:
        raise QualificationPolicyError(
            f"{description} xctrace export summary schema is not exact"
        )
    for field, expected in {
        "formatVersion": 1,
        "status": "captured",
        "source": "xctrace-export-v1",
        "runNumber": 1,
        "scenario": scenario_id,
        "artifactRole": role,
        "template": template,
        "targetProcess": "iOS",
        "targetDeviceIdentifier": target_device_identifier,
        "traceTreeDigestAlgorithm": "swiftvlc-tree-v1",
        "traceTreeDigest": record["treeDigest"],
        "tableOfContentsDigestAlgorithm": "sha256",
        "tableOfContentsDigest": record["tableOfContentsDigest"],
        **producer_fields,
    }.items():
        if export_summary.get(field) != expected:
            raise QualificationPolicyError(
                f"{description} xctrace summary {field} mismatch"
            )
    capture_duration = _finite_number(
        export_summary.get("captureDurationSeconds"),
        f"{description} xctrace capture duration",
    )
    tables = export_summary.get("tables")
    total_row_count = export_summary.get("totalRowCount")
    if (
        capture_duration < minimum_duration
        or not isinstance(tables, list)
        or not tables
        or any(
            not isinstance(table, dict)
            or set(table) != TRACE_TABLE_SUMMARY_KEYS
            or not isinstance(table.get("schema"), str)
            or not table["schema"]
            or isinstance(table.get("rowCount"), bool)
            or not isinstance(table.get("rowCount"), int)
            or table["rowCount"] < 0
            or isinstance(table.get("targetProcessRowCount"), bool)
            or not isinstance(table.get("targetProcessRowCount"), int)
            or table["targetProcessRowCount"] < 0
            or table["targetProcessRowCount"] > table["rowCount"]
            for table in tables
        )
        or len({table["schema"] for table in tables}) != len(tables)
        or isinstance(total_row_count, bool)
        or not isinstance(total_row_count, int)
        or total_row_count != sum(table["rowCount"] for table in tables)
        or total_row_count <= 0
    ):
        raise QualificationPolicyError(
            f"{description} xctrace summary has no qualifying sample coverage"
        )
    measurement = export_summary.get("measurement")
    if not isinstance(measurement, dict) or set(measurement) != TRACE_MEASUREMENT_KEYS:
        raise QualificationPolicyError(
            f"{description} xctrace measurement schema is not exact"
        )
    expected_metric, expected_unit = TRACE_MEASUREMENT_SPECS[role]
    numeric_fields = (
        "minimumValue",
        "averageValue",
        "maximumValue",
        "timelineStartSeconds",
        "timelineEndSeconds",
        "maximumSampleGapSeconds",
    )
    numeric = {
        field: _finite_number(
            measurement.get(field), f"{description} xctrace measurement {field}"
        )
        for field in numeric_fields
    }
    sample_count = measurement.get("sampleCount")
    target_rows = measurement.get("targetProcessRowCount")
    source_fields = measurement.get("sourceFields")
    timeline_span = numeric["timelineEndSeconds"] - numeric["timelineStartSeconds"]
    maximum_allowed_gap = (
        TIMEBASE_AUDIO_PROGRESS_MAXIMUM_GAP_SECONDS
        if role == "audioPresentationSeries"
        else ENDURANCE_SERIES_MAXIMUM_GAP_SECONDS
    )
    if (
        measurement.get("metric") != expected_metric
        or measurement.get("unit") != expected_unit
        or isinstance(sample_count, bool)
        or not isinstance(sample_count, int)
        or sample_count <= 0
        or isinstance(target_rows, bool)
        or not isinstance(target_rows, int)
        or target_rows <= 0
        or target_rows != sum(table["targetProcessRowCount"] for table in tables)
        or not isinstance(source_fields, list)
        or not source_fields
        or any(not isinstance(field, str) or not field for field in source_fields)
        or source_fields != sorted(set(source_fields))
        or numeric["minimumValue"] < 0
        or numeric["averageValue"] < numeric["minimumValue"]
        or numeric["maximumValue"] < numeric["averageValue"]
        or timeline_span < minimum_duration
        or numeric["maximumSampleGapSeconds"] < 0
        or numeric["maximumSampleGapSeconds"] > maximum_allowed_gap
    ):
        raise QualificationPolicyError(
            f"{description} xctrace measurement does not prove target-bound coverage"
        )
    performance_budget = PERFORMANCE_RESOURCE_BUDGETS.get(scenario_id)
    if performance_budget is not None:
        if role == "gpu" and (
            numeric["averageValue"] > performance_budget["gpuAveragePercent"]
            or numeric["maximumValue"] > performance_budget["gpuMaximumPercent"]
        ):
            raise QualificationPolicyError(
                f"{description} exceeds the immutable GPU budget"
            )
        if role == "energy" and (
            numeric["averageValue"] > performance_budget["energyAverageScore"]
            or numeric["maximumValue"] > performance_budget["energyMaximumScore"]
        ):
            raise QualificationPolicyError(
                f"{description} exceeds the immutable energy budget"
            )
        if role == "conversionCost" and (
            numeric["averageValue"]
            > performance_budget["conversionAverageMilliseconds"]
            or numeric["maximumValue"]
            > performance_budget["conversionMaximumMilliseconds"]
        ):
            raise QualificationPolicyError(
                f"{description} exceeds the trace-derived conversion budget"
            )
    return trace, toc, summary, export_summary


def inspect_timebase_raw_capture(path: Path, sample_interval: object) -> dict:
    if sample_interval != 1:
        raise QualificationPolicyError(
            "timebase raw capture sampleIntervalSeconds must be 1"
        )
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise QualificationPolicyError(
            "timebase raw capture is not readable UTF-8"
        ) from error
    lines = text.splitlines()
    if not lines or any(not line.strip() for line in lines):
        raise QualificationPolicyError("timebase raw capture is empty or truncated")
    samples = 0
    corrections: list[int] = []
    elapsed_values: list[int] = []
    maximum_drift = 0.0
    drift_samples = 0
    maximum_correction = 0.0
    observed_rates: set[float] = set()
    monotonicity_violations = 0
    previous_presented: dict[int, float] = {}
    decoded_samples = 0
    first_played: int | None = None
    last_played: int | None = None
    prior_audio_by_generation: dict[int, tuple[int, int, int]] = {}
    last_audio_progress_elapsed: int | None = None
    maximum_audio_progress_gap = 0
    played_buffer_delta = 0
    lost_buffer_delta = 0
    played_buffer_advance_count = 0
    audio_generations: set[int] = set()
    audio_progress_generations: set[int] = set()
    prior_video_by_generation: dict[int, tuple[int, int, int, float, float, float]] = {}
    last_video_progress_elapsed: int | None = None
    maximum_video_progress_gap = 0
    delivered_frame_advance_count = 0
    decoded_frame_advance_count = 0
    presented_clock_advance_count = 0
    clock_slope_sample_count = 0
    clock_slope_violation_count = 0
    video_progress_generations: set[int] = set()
    for number, line in enumerate(lines, 1):
        value = loads_json(line, f"timebase raw capture line {number}")
        if not isinstance(value, dict):
            raise QualificationPolicyError(
                f"timebase raw capture line {number} is not an object"
            )
        kind = value.get("kind")
        if kind == "sample":
            if set(value) != TIMEBASE_SAMPLE_LINE_KEYS or not all(
                isinstance(value.get(key), dict) for key in ("clock", "audio", "frame")
            ):
                raise QualificationPolicyError(
                    f"timebase raw sample line {number} is incomplete"
                )
            clock = value["clock"]
            audio = value["audio"]
            frame = value["frame"]
            if (
                not TIMEBASE_CLOCK_REQUIRED_KEYS.issubset(clock)
                or set(clock)
                - TIMEBASE_CLOCK_REQUIRED_KEYS
                - TIMEBASE_CLOCK_OPTIONAL_KEYS
                or set(audio) != TIMEBASE_AUDIO_KEYS
                or set(frame) != TIMEBASE_FRAME_KEYS
            ):
                raise QualificationPolicyError(
                    f"timebase raw sample line {number} schema is not exact"
                )
            elapsed = _integer(
                clock.get("elapsedSeconds"),
                f"timebase raw sample line {number} elapsedSeconds",
            )
            elapsed_values.append(elapsed)
            clock_generation = _integer(
                clock.get("playbackGeneration"),
                f"timebase raw sample line {number} clock generation",
            )
            clock_media = _finite_number(
                clock.get("mediaTimeSeconds"),
                f"timebase raw sample line {number} media time",
            )
            for optional_clock_field in TIMEBASE_CLOCK_OPTIONAL_KEYS:
                if optional_clock_field in clock:
                    _finite_number(
                        clock[optional_clock_field],
                        f"timebase raw sample line {number} {optional_clock_field}",
                    )
            drift = clock.get("driftSeconds")
            if type(drift) in (int, float) and math.isfinite(float(drift)):
                maximum_drift = max(maximum_drift, abs(float(drift)))
                drift_samples += 1
            rate = clock.get("requestedRate")
            if type(rate) in (int, float) and math.isfinite(float(rate)):
                observed_rates.add(float(rate))
            generation = frame.get("playbackGeneration")
            presented = frame.get("presentedSeconds")
            if (
                isinstance(generation, bool)
                or not isinstance(generation, int)
                or generation < 0
            ):
                raise QualificationPolicyError(
                    f"timebase raw sample line {number} has no playback generation"
                )
            if (
                clock_generation != generation
                or audio.get("elapsedSeconds") != elapsed
                or frame.get("elapsedSeconds") != elapsed
            ):
                raise QualificationPolicyError(
                    f"timebase raw sample line {number} clocks/generation disagree"
                )
            for field in (
                "mediaTimeSeconds",
                "estimatedPresentationSeconds",
                "outputLatencySeconds",
                "ioBufferDurationSeconds",
            ):
                measured = _finite_number(
                    audio.get(field),
                    f"timebase raw sample line {number} audio {field}",
                )
                if (
                    field in {"outputLatencySeconds", "ioBufferDurationSeconds"}
                    and measured < 0
                ):
                    raise QualificationPolicyError(
                        f"timebase raw sample line {number} has negative audio latency"
                    )
            if abs(float(clock_media) - float(audio["mediaTimeSeconds"])) > 0.25:
                raise QualificationPolicyError(
                    f"timebase raw sample line {number} media clocks disagree"
                )
            audio_generations.add(generation)
            if type(presented) in (int, float):
                prior = previous_presented.get(generation)
                if prior is not None and float(presented) + 0.001 < prior:
                    monotonicity_violations += 1
                previous_presented[generation] = float(presented)
            played = audio.get("playedBuffers")
            lost = audio.get("lostBuffers")
            if (
                isinstance(played, bool)
                or not isinstance(played, int)
                or played < 0
                or isinstance(lost, bool)
                or not isinstance(lost, int)
                or lost < 0
            ):
                raise QualificationPolicyError(
                    f"timebase raw sample line {number} has invalid audio counters"
                )
            first_played = played if first_played is None else first_played
            last_played = played
            prior_audio = prior_audio_by_generation.get(generation)
            if prior_audio is None:
                if last_audio_progress_elapsed is not None:
                    maximum_audio_progress_gap = max(
                        maximum_audio_progress_gap,
                        elapsed - last_audio_progress_elapsed,
                    )
                last_audio_progress_elapsed = elapsed
            else:
                prior_elapsed, prior_played, prior_lost = prior_audio
                if played < prior_played or lost < prior_lost:
                    raise QualificationPolicyError(
                        "timebase raw audio counters moved backwards within one "
                        "playback generation"
                    )
                played_delta = played - prior_played
                lost_delta = lost - prior_lost
                played_buffer_delta += played_delta
                lost_buffer_delta += lost_delta
                if played_delta > 0:
                    played_buffer_advance_count += 1
                    audio_progress_generations.add(generation)
                    last_audio_progress_elapsed = elapsed
                elif last_audio_progress_elapsed is None:
                    last_audio_progress_elapsed = prior_elapsed
            prior_audio_by_generation[generation] = (elapsed, played, lost)
            if last_audio_progress_elapsed is not None:
                maximum_audio_progress_gap = max(
                    maximum_audio_progress_gap,
                    elapsed - last_audio_progress_elapsed,
                )
            if type(frame.get("decodedFrameMediaTimeSeconds")) in (int, float):
                decoded_samples += 1
            delivered_frames = frame.get("deliveredFrames")
            dropped_frames = frame.get("droppedFrames")
            decoded_frames = frame.get("decodedFrames")
            decoded_time = frame.get("decodedFrameMediaTimeSeconds")
            requested_rate = clock.get("requestedRate")
            if (
                isinstance(delivered_frames, bool)
                or not isinstance(delivered_frames, int)
                or delivered_frames < 0
                or isinstance(dropped_frames, bool)
                or not isinstance(dropped_frames, int)
                or dropped_frames < 0
                or isinstance(decoded_frames, bool)
                or not isinstance(decoded_frames, int)
                or decoded_frames < 0
                or type(presented) not in (int, float)
                or not math.isfinite(float(presented))
                or type(decoded_time) not in (int, float)
                or not math.isfinite(float(decoded_time))
                or type(requested_rate) not in (int, float)
                or not math.isfinite(float(requested_rate))
                or float(requested_rate) not in {0.5, 1.0, 2.0}
            ):
                raise QualificationPolicyError(
                    f"timebase raw sample line {number} has invalid video progress"
                )
            prior_video = prior_video_by_generation.get(generation)
            if prior_video is None:
                if last_video_progress_elapsed is not None:
                    maximum_video_progress_gap = max(
                        maximum_video_progress_gap,
                        elapsed - last_video_progress_elapsed,
                    )
                last_video_progress_elapsed = elapsed
            else:
                (
                    prior_elapsed,
                    prior_delivered,
                    prior_decoded,
                    prior_presented,
                    prior_decoded_time,
                    prior_rate,
                ) = prior_video
                if (
                    delivered_frames < prior_delivered
                    or decoded_frames < prior_decoded
                    or float(presented) + 0.001 < prior_presented
                    or float(decoded_time) + 0.001 < prior_decoded_time
                ):
                    raise QualificationPolicyError(
                        "timebase raw video counters/clocks moved backwards within "
                        "one playback generation"
                    )
                delivered_delta = delivered_frames - prior_delivered
                decoded_delta = decoded_frames - prior_decoded
                presented_delta = float(presented) - prior_presented
                decoded_time_delta = float(decoded_time) - prior_decoded_time
                if delivered_delta > 0:
                    delivered_frame_advance_count += 1
                if decoded_delta > 0:
                    decoded_frame_advance_count += 1
                if presented_delta > 0 and decoded_time_delta > 0:
                    presented_clock_advance_count += 1
                if (
                    delivered_delta > 0
                    and decoded_delta > 0
                    and presented_delta > 0
                    and decoded_time_delta > 0
                ):
                    last_video_progress_elapsed = elapsed
                    video_progress_generations.add(generation)
                if float(requested_rate) == prior_rate and elapsed > prior_elapsed:
                    clock_slope_sample_count += 1
                    expected_slope = float(requested_rate)
                    tolerance = max(0.10, abs(expected_slope) * 0.20)
                    presented_slope = presented_delta / (elapsed - prior_elapsed)
                    decoded_slope = decoded_time_delta / (elapsed - prior_elapsed)
                    if (
                        abs(presented_slope - expected_slope) > tolerance
                        or abs(decoded_slope - expected_slope) > tolerance
                    ):
                        clock_slope_violation_count += 1
            prior_video_by_generation[generation] = (
                elapsed,
                delivered_frames,
                decoded_frames,
                float(presented),
                float(decoded_time),
                float(requested_rate),
            )
            if last_video_progress_elapsed is not None:
                maximum_video_progress_gap = max(
                    maximum_video_progress_gap,
                    elapsed - last_video_progress_elapsed,
                )
            samples += 1
        elif kind == "correction":
            if set(value) != {"kind", "correction"}:
                raise QualificationPolicyError(
                    f"timebase raw correction line {number} schema is not exact"
                )
            correction = value.get("correction")
            if (
                not isinstance(correction, dict)
                or not TIMEBASE_CORRECTION_REQUIRED_KEYS.issubset(correction)
                or set(correction)
                - TIMEBASE_CORRECTION_REQUIRED_KEYS
                - TIMEBASE_CORRECTION_OPTIONAL_KEYS
            ):
                raise QualificationPolicyError(
                    f"timebase raw correction line {number} is malformed"
                )
            sequence = _integer(
                correction.get("sequence"),
                f"timebase raw correction line {number} sequence",
            )
            correction_generation = _integer(
                correction.get("playbackGeneration"),
                f"timebase raw correction line {number} generation",
            )
            if (
                sequence < 1
                or correction_generation < 0
                or correction.get("reason") not in TIMEBASE_CORRECTION_REASONS
            ):
                raise QualificationPolicyError(
                    f"timebase raw correction line {number} identity is invalid"
                )
            for field in (
                "capturedAt",
                "systemUptime",
                "mediaTimeSeconds",
                "previousTimebaseSeconds",
                "correctedTimebaseSeconds",
                "driftSeconds",
                *TIMEBASE_CORRECTION_OPTIONAL_KEYS,
            ):
                if field in correction:
                    _finite_number(
                        correction[field],
                        f"timebase raw correction line {number} {field}",
                    )
            corrections.append(sequence)
            drift = correction.get("driftSeconds")
            if correction.get("reason") == "steadyStateDrift" and type(drift) in (
                int,
                float,
            ):
                maximum_correction = max(maximum_correction, abs(float(drift)))
        else:
            raise QualificationPolicyError(
                f"timebase raw capture line {number} has unknown kind"
            )
    if not elapsed_values:
        raise QualificationPolicyError("timebase raw capture contains no samples")
    if any(
        current <= previous
        for previous, current in zip(elapsed_values, elapsed_values[1:])
    ):
        raise QualificationPolicyError(
            "timebase raw sample timeline is not strictly increasing"
        )
    if any(
        current != previous + 1
        for previous, current in zip(corrections, corrections[1:])
    ):
        raise QualificationPolicyError("timebase raw correction sequence has a gap")
    maximum_gap = max(
        (
            current - previous
            for previous, current in zip(elapsed_values, elapsed_values[1:])
        ),
        default=1,
    )
    missing_seconds = elapsed_values[-1] - elapsed_values[0] + 1 - len(elapsed_values)
    if last_audio_progress_elapsed is not None:
        maximum_audio_progress_gap = max(
            maximum_audio_progress_gap,
            elapsed_values[-1] - last_audio_progress_elapsed,
        )
    if last_video_progress_elapsed is not None:
        maximum_video_progress_gap = max(
            maximum_video_progress_gap,
            elapsed_values[-1] - last_video_progress_elapsed,
        )
    lost_ratio = lost_buffer_delta / max(1, played_buffer_delta + lost_buffer_delta)
    if samples >= TIMEBASE_AUDIO_PROGRESS_MAXIMUM_GAP_SECONDS and (
        played_buffer_advance_count
        < samples // TIMEBASE_AUDIO_PROGRESS_MAXIMUM_GAP_SECONDS
        or maximum_audio_progress_gap > TIMEBASE_AUDIO_PROGRESS_MAXIMUM_GAP_SECONDS
        or elapsed_values[-1] - (last_audio_progress_elapsed or elapsed_values[0])
        > TIMEBASE_AUDIO_PROGRESS_MAXIMUM_GAP_SECONDS
        or lost_ratio > TIMEBASE_AUDIO_MAXIMUM_LOST_BUFFER_RATIO
        or delivered_frame_advance_count
        < samples // TIMEBASE_AUDIO_PROGRESS_MAXIMUM_GAP_SECONDS
        or decoded_frame_advance_count
        < samples // TIMEBASE_AUDIO_PROGRESS_MAXIMUM_GAP_SECONDS
        or presented_clock_advance_count
        < samples // TIMEBASE_AUDIO_PROGRESS_MAXIMUM_GAP_SECONDS
        or maximum_video_progress_gap > TIMEBASE_AUDIO_PROGRESS_MAXIMUM_GAP_SECONDS
        or elapsed_values[-1] - (last_video_progress_elapsed or elapsed_values[0])
        > TIMEBASE_AUDIO_PROGRESS_MAXIMUM_GAP_SECONDS
        or clock_slope_sample_count < samples - 10
        or clock_slope_violation_count != 0
        or audio_progress_generations != audio_generations
        or video_progress_generations != audio_generations
    ):
        raise QualificationPolicyError(
            "timebase raw capture has a sustained audio/video progress, loss, "
            "or clock-slope violation"
        )
    return {
        "status": "captured",
        "format": "application/x-ndjson",
        "sha256": sha256_file(path),
        "sizeBytes": path.stat().st_size,
        "sampleIntervalSeconds": sample_interval,
        "sampleCount": samples,
        "correctionCount": len(corrections),
        "firstCorrectionSequence": corrections[0] if corrections else None,
        "lastCorrectionSequence": corrections[-1] if corrections else None,
        "maximumObservedDriftSeconds": maximum_drift,
        "driftSampleCount": drift_samples,
        "timelineStartSeconds": elapsed_values[0],
        "timelineEndSeconds": elapsed_values[-1],
        "maximumSampleGapSeconds": maximum_gap,
        "missingTimelineSeconds": missing_seconds,
        "maximumSteadyCorrectionSeconds": maximum_correction,
        "observedRates": sorted(observed_rates),
        "monotonicityViolations": monotonicity_violations,
        "audioBuffersAdvanced": (played_buffer_delta > 0),
        "audioPlaybackGenerationCount": len(audio_generations),
        "audioProgressGenerationCount": len(audio_progress_generations),
        "playedBufferAdvanceCount": played_buffer_advance_count,
        "playedBufferDelta": played_buffer_delta,
        "lostBufferDelta": lost_buffer_delta,
        "lostBufferRatio": lost_ratio,
        "maximumAudioProgressGapSeconds": maximum_audio_progress_gap,
        "audioProgressWindowSeconds": (TIMEBASE_AUDIO_PROGRESS_MAXIMUM_GAP_SECONDS),
        "audioProgressWindowViolationCount": int(
            maximum_audio_progress_gap > TIMEBASE_AUDIO_PROGRESS_MAXIMUM_GAP_SECONDS
        ),
        "finalAudioProgressAgeSeconds": (
            elapsed_values[-1] - last_audio_progress_elapsed
            if last_audio_progress_elapsed is not None
            else elapsed_values[-1] - elapsed_values[0]
        ),
        "decodedFrameMediaClockSampleCount": decoded_samples,
        "videoProgressWindowSeconds": (TIMEBASE_AUDIO_PROGRESS_MAXIMUM_GAP_SECONDS),
        "maximumVideoProgressGapSeconds": maximum_video_progress_gap,
        "videoProgressWindowViolationCount": int(
            maximum_video_progress_gap > TIMEBASE_AUDIO_PROGRESS_MAXIMUM_GAP_SECONDS
        ),
        "deliveredFrameAdvanceCount": delivered_frame_advance_count,
        "videoProgressGenerationCount": len(video_progress_generations),
        "decodedFrameAdvanceCount": decoded_frame_advance_count,
        "presentedClockAdvanceCount": presented_clock_advance_count,
        "clockSlopeSampleCount": clock_slope_sample_count,
        "clockSlopeViolationCount": clock_slope_violation_count,
        "finalVideoProgressAgeSeconds": (
            elapsed_values[-1] - last_video_progress_elapsed
            if last_video_progress_elapsed is not None
            else elapsed_values[-1] - elapsed_values[0]
        ),
        "_correctionSequences": corrections,
    }


def validate_timebase_raw_artifact(
    record: object,
    artifact_base: Path,
    *,
    scenario_id: str,
    producer_fields: dict,
) -> tuple[Path, dict]:
    expected_keys = {
        "status",
        "format",
        "runArtifact",
        "digestAlgorithm",
        "sha256",
        "sizeBytes",
        "sampleIntervalSeconds",
        "sampleCount",
        "correctionCount",
        "firstCorrectionSequence",
        "lastCorrectionSequence",
        "maximumObservedDriftSeconds",
        "driftSampleCount",
        "timelineStartSeconds",
        "timelineEndSeconds",
        "maximumSampleGapSeconds",
        "missingTimelineSeconds",
        "maximumSteadyCorrectionSeconds",
        "observedRates",
        "monotonicityViolations",
        "audioBuffersAdvanced",
        "audioPlaybackGenerationCount",
        "audioProgressGenerationCount",
        "playedBufferAdvanceCount",
        "playedBufferDelta",
        "lostBufferDelta",
        "lostBufferRatio",
        "maximumAudioProgressGapSeconds",
        "audioProgressWindowSeconds",
        "audioProgressWindowViolationCount",
        "finalAudioProgressAgeSeconds",
        "decodedFrameMediaClockSampleCount",
        "videoProgressWindowSeconds",
        "maximumVideoProgressGapSeconds",
        "videoProgressWindowViolationCount",
        "deliveredFrameAdvanceCount",
        "videoProgressGenerationCount",
        "decodedFrameAdvanceCount",
        "presentedClockAdvanceCount",
        "clockSlopeSampleCount",
        "clockSlopeViolationCount",
        "finalVideoProgressAgeSeconds",
        "producerRunnerScenario",
        "producerSourceAttempt",
        "producerXcresultDigest",
        "evidenceStem",
    }
    if not isinstance(record, dict) or set(record) != expected_keys:
        raise QualificationPolicyError("timebase raw capture schema is not exact")
    if record.get("digestAlgorithm") != "sha256":
        raise QualificationPolicyError(
            "timebase raw capture digest algorithm is invalid"
        )
    for field, expected in producer_fields.items():
        if record.get(field) != expected:
            raise QualificationPolicyError(
                f"timebase raw capture {field} producer mismatch"
            )
    path = safe_relative_file(
        artifact_base, record.get("runArtifact"), "timebase raw capture"
    )
    expected_parent = Path("artifacts") / producer_fields["evidenceStem"]
    mode = "vod" if scenario_id == "timebase-vod-soak" else "live"
    raw_name_pattern = re.compile(
        rf"swiftvlc-timebase-[A-Za-z0-9-]+-{mode}-"
        rf"{producer_fields['producerSourceAttempt']}-{mode}\.jsonl"
    )
    if Path(
        record["runArtifact"]
    ).parent != expected_parent or not raw_name_pattern.fullmatch(
        Path(record["runArtifact"]).name
    ):
        raise QualificationPolicyError(
            "timebase raw capture is outside the final-attempt namespace"
        )
    rebuilt = inspect_timebase_raw_capture(path, record.get("sampleIntervalSeconds"))
    public_rebuilt = {
        key: value for key, value in rebuilt.items() if key != "_correctionSequences"
    }
    expected = {
        **public_rebuilt,
        "runArtifact": record["runArtifact"],
        "digestAlgorithm": "sha256",
        **producer_fields,
    }
    if record != expected:
        raise QualificationPolicyError("timebase raw capture binding/stats mismatch")
    return path, rebuilt


HOST_TRACE_REQUIREMENTS = {
    "adaptive-hls-soak": [
        (
            "allocationProvenance.instrumentsTrace",
            "allocation",
            "Allocations",
            "allocations",
            {"rollingWindow": "15m"},
        )
    ],
    "pip-render-performance-1080p60": [
        ("metrics.gpu", "gpu", "Game Performance", "game", {}),
        ("metrics.energy", "energy", "Power Profiler", "power", {}),
        (
            "metrics.conversionCost.hostTrace",
            "conversionCost",
            "Time Profiler",
            "time",
            {},
        ),
    ],
    "pip-render-performance-4k60": [
        ("metrics.gpu", "gpu", "Game Performance", "game", {}),
        ("metrics.energy", "energy", "Power Profiler", "power", {}),
        (
            "metrics.conversionCost.hostTrace",
            "conversionCost",
            "Time Profiler",
            "time",
            {},
        ),
    ],
    "native-subtitle-matrix": [
        ("metrics.cpu.hostTrace", "cpu", "Time Profiler", "time", {}),
        ("metrics.gpu", "gpu", "Game Performance", "game", {}),
        (
            "metrics.colorHDRImpact.hostTrace",
            "colorHDRImpact",
            "Metal System Trace",
            "metal",
            {},
        ),
    ],
    "timebase-vod-soak": [
        (
            "audioPresentationSeries.hostTrace",
            "audioPresentationSeries",
            "Audio System Trace",
            "audio",
            {},
        )
    ],
    "timebase-live-soak": [
        (
            "audioPresentationSeries.hostTrace",
            "audioPresentationSeries",
            "Audio System Trace",
            "audio",
            {},
        )
    ],
}


def validate_host_augmented_artifacts(
    evidence: dict,
    scenario_id: str,
    artifact_base: Path,
    evidence_stem: str | None,
) -> set[tuple[str, ...]]:
    requirements = HOST_TRACE_REQUIREMENTS.get(scenario_id)
    if requirements is None:
        return set()
    if evidence_stem is None:
        first_record = nested_value(evidence, requirements[0][0])
        evidence_stem = (
            first_record.get("evidenceStem") if isinstance(first_record, dict) else None
        )
    if not isinstance(evidence_stem, str):
        raise QualificationPolicyError(
            f"{scenario_id} host artifacts have no evidence namespace"
        )
    producer_fields = host_artifact_producer_fields(evidence, evidence_stem)
    target_device_identifier = evidence.get("deviceIdentifier")
    if not isinstance(target_device_identifier, str) or not target_device_identifier:
        raise QualificationPolicyError(
            f"{scenario_id} evidence has no exact target device identifier"
        )
    device_duration = _finite_number(
        evidence.get("deviceObservedDurationSeconds"),
        f"{scenario_id} device-observed duration",
    )
    seen_paths: set[Path] = set()
    fingerprints: set[tuple[str, ...]] = set()
    for field, role, template, artifact_token, extra in requirements:
        record = nested_value(evidence, field)
        trace, toc, summary, export_summary = validate_host_trace_record(
            record,
            artifact_base,
            role=role,
            template=template,
            scenario_id=scenario_id,
            target_device_identifier=target_device_identifier,
            minimum_duration=trace_minimum_capture_duration(
                scenario_id, role, device_duration
            ),
            description=f"{scenario_id} {field}",
            artifact_token=artifact_token,
            producer_fields=producer_fields,
            extra=extra,
        )
        if trace in seen_paths or toc in seen_paths or summary in seen_paths:
            raise QualificationPolicyError(
                f"{scenario_id} host artifacts are reused across roles"
            )
        seen_paths.update({trace, toc, summary})
        fingerprint = (
            "trace",
            str(record["treeDigest"]),
            str(record["tableOfContentsDigest"]),
        )
        if fingerprint in fingerprints:
            raise QualificationPolicyError(
                f"{scenario_id} reuses trace content across artifact roles"
            )
        fingerprints.add(fingerprint)
        if scenario_id in PERFORMANCE_RESOURCE_BUDGETS and role == "conversionCost":
            conversion = evidence.get("metrics", {}).get("conversionCost")
            measurement = export_summary["measurement"]
            if not isinstance(conversion, dict) or (
                abs(
                    _finite_number(
                        conversion.get("averageMilliseconds"),
                        f"{scenario_id} app conversion average",
                    )
                    - measurement["averageValue"]
                )
                > max(0.5, measurement["averageValue"] * 0.20)
                or abs(
                    _finite_number(
                        conversion.get("maximumMilliseconds"),
                        f"{scenario_id} app conversion maximum",
                    )
                    - measurement["maximumValue"]
                )
                > max(1.0, measurement["maximumValue"] * 0.20)
            ):
                raise QualificationPolicyError(
                    f"{scenario_id} app and trace conversion metrics disagree"
                )
    if scenario_id in {"timebase-vod-soak", "timebase-live-soak"}:
        raw, rebuilt = validate_timebase_raw_artifact(
            evidence.get("rawCapture"),
            artifact_base,
            scenario_id=scenario_id,
            producer_fields=producer_fields,
        )
        if raw in seen_paths:
            raise QualificationPolicyError(
                f"{scenario_id} raw capture aliases a trace artifact"
            )
        drift_budget = evidence.get("driftBudget")
        correction_budget = evidence.get("correctionBudget")
        if not isinstance(drift_budget, dict) or not isinstance(
            correction_budget, dict
        ):
            raise QualificationPolicyError(
                f"{scenario_id} has malformed timebase budgets"
            )
        maximum_drift = _finite_number(
            drift_budget.get("maximumSeconds"),
            f"{scenario_id} drift budget",
        )
        maximum_correction = _finite_number(
            correction_budget.get("maximumSeconds"),
            f"{scenario_id} correction budget",
        )
        if maximum_drift < 0 or maximum_correction < 0:
            raise QualificationPolicyError(
                f"{scenario_id} timebase budgets must be non-negative"
            )
        corrections = evidence.get("corrections")
        if not isinstance(corrections, list):
            raise QualificationPolicyError(
                f"{scenario_id} compact correction series is malformed"
            )
        compact_sequences: list[int] = []
        for index, correction in enumerate(corrections):
            if not isinstance(correction, dict):
                raise QualificationPolicyError(
                    f"{scenario_id} compact correction {index} is malformed"
                )
            compact_sequences.append(
                _integer(
                    correction.get("sequence"),
                    f"{scenario_id} compact correction {index} sequence",
                )
            )
        required_rates = (0.5, 1.0, 2.0)
        observed_rates = rebuilt["observedRates"]
        if (
            rebuilt["maximumObservedDriftSeconds"] > maximum_drift
            or rebuilt["maximumSteadyCorrectionSeconds"] > maximum_correction
            or rebuilt["monotonicityViolations"] != 0
            or not rebuilt["audioBuffersAdvanced"]
            or rebuilt["playedBufferAdvanceCount"]
            < (rebuilt["sampleCount"] // TIMEBASE_AUDIO_PROGRESS_MAXIMUM_GAP_SECONDS)
            or rebuilt["maximumAudioProgressGapSeconds"]
            > TIMEBASE_AUDIO_PROGRESS_MAXIMUM_GAP_SECONDS
            or rebuilt["audioProgressWindowViolationCount"] != 0
            or rebuilt["audioProgressGenerationCount"]
            != rebuilt["audioPlaybackGenerationCount"]
            or rebuilt["finalAudioProgressAgeSeconds"]
            > TIMEBASE_AUDIO_PROGRESS_MAXIMUM_GAP_SECONDS
            or rebuilt["lostBufferRatio"] > TIMEBASE_AUDIO_MAXIMUM_LOST_BUFFER_RATIO
            or rebuilt["decodedFrameMediaClockSampleCount"]
            < rebuilt["sampleCount"] // 2
            or rebuilt["maximumVideoProgressGapSeconds"]
            > TIMEBASE_AUDIO_PROGRESS_MAXIMUM_GAP_SECONDS
            or rebuilt["videoProgressWindowViolationCount"] != 0
            or rebuilt["videoProgressGenerationCount"]
            != rebuilt["audioPlaybackGenerationCount"]
            or rebuilt["finalVideoProgressAgeSeconds"]
            > TIMEBASE_AUDIO_PROGRESS_MAXIMUM_GAP_SECONDS
            or rebuilt["deliveredFrameAdvanceCount"]
            < rebuilt["sampleCount"] // TIMEBASE_AUDIO_PROGRESS_MAXIMUM_GAP_SECONDS
            or rebuilt["decodedFrameAdvanceCount"]
            < rebuilt["sampleCount"] // TIMEBASE_AUDIO_PROGRESS_MAXIMUM_GAP_SECONDS
            or rebuilt["presentedClockAdvanceCount"]
            < rebuilt["sampleCount"] // TIMEBASE_AUDIO_PROGRESS_MAXIMUM_GAP_SECONDS
            or rebuilt["clockSlopeSampleCount"] < rebuilt["sampleCount"] - 10
            or rebuilt["clockSlopeViolationCount"] != 0
            or any(
                not any(abs(rate - expected) < 0.01 for rate in observed_rates)
                for expected in required_rates
            )
            or compact_sequences != rebuilt["_correctionSequences"]
        ):
            raise QualificationPolicyError(
                f"{scenario_id} retained raw timebase semantics failed"
            )
        seen_paths.add(raw)
        raw_fingerprint = ("raw", str(evidence["rawCapture"]["sha256"]))
        if raw_fingerprint in fingerprints:
            raise QualificationPolicyError(
                f"{scenario_id} reuses raw content across artifact roles"
            )
        fingerprints.add(raw_fingerprint)
    return fingerprints


def validate_seek_frame_oracle_evidence(evidence: dict, scenario: dict) -> None:
    contract = scenario.get("oracleContract")
    if not _json_same(contract, SEEK_FRAME_ORACLE_CONTRACT):
        raise QualificationPolicyError(
            "seek-frame-oracles matrix contract differs from immutable policy"
        )

    seek_results = _exact_object(
        evidence.get("seekResults"),
        {"precise", "fastKeyframe", "overlap"},
        "seek-frame-oracles seekResults",
    )
    if any(value != "pass" for value in seek_results.values()):
        raise QualificationPolicyError("seek-frame-oracles seek results did not pass")

    seek_oracle = _exact_object(
        evidence.get("seekOracle"),
        {
            "preciseTimelineSeconds",
            "fastTimelineSeconds",
            "overlapTimelineSeconds",
            "contentSource",
        },
        "seek-frame-oracles seekOracle",
    )
    if seek_oracle["contentSource"] != "xcui-video-surface-screenshot":
        raise QualificationPolicyError(
            "seek-frame-oracles seek oracle is not screenshot-derived"
        )
    tolerance = SEEK_FRAME_ORACLE_CONTRACT["seekToleranceSeconds"]
    for value_field, target_field in (
        ("preciseTimelineSeconds", "preciseTargetSeconds"),
        ("fastTimelineSeconds", "fastTargetSeconds"),
        ("overlapTimelineSeconds", "overlapTargetSeconds"),
    ):
        observed = _finite_number(
            seek_oracle[value_field], f"seek-frame-oracles {value_field}"
        )
        target = SEEK_FRAME_ORACLE_CONTRACT[target_field]
        if abs(observed - target) > tolerance:
            raise QualificationPolicyError(
                f"seek-frame-oracles {value_field} {observed:g}s is outside "
                f"the immutable {target:g}s +/- {tolerance:g}s oracle"
            )

    seek_clock = _exact_object(
        evidence.get("seekClock"),
        {"preciseMilliseconds", "fastMilliseconds", "overlapMilliseconds"},
        "seek-frame-oracles seekClock",
    )
    for clock_field, oracle_field, target_field in (
        (
            "preciseMilliseconds",
            "preciseTimelineSeconds",
            "preciseTargetSeconds",
        ),
        ("fastMilliseconds", "fastTimelineSeconds", "fastTargetSeconds"),
        (
            "overlapMilliseconds",
            "overlapTimelineSeconds",
            "overlapTargetSeconds",
        ),
    ):
        clock_seconds = (
            _integer(
                seek_clock[clock_field], f"seek-frame-oracles seekClock.{clock_field}"
            )
            / 1000
        )
        oracle_seconds = float(seek_oracle[oracle_field])
        target_seconds = SEEK_FRAME_ORACLE_CONTRACT[target_field]
        if (
            abs(clock_seconds - oracle_seconds) > tolerance
            or abs(clock_seconds - target_seconds) > tolerance
        ):
            raise QualificationPolicyError(
                f"seek-frame-oracles {clock_field} contradicts the decoded seek oracle"
            )

    seek_outcomes = _exact_object(
        evidence.get("seekOutcomes"),
        {"precise", "fast", "overlap"},
        "seek-frame-oracles seekOutcomes",
    )
    if (
        seek_outcomes["precise"] != "settled"
        or seek_outcomes["fast"] != "settled"
        or seek_outcomes["overlap"]
        != ["superseded", "superseded", "superseded", "settled"]
    ):
        raise QualificationPolicyError(
            "seek-frame-oracles typed seek outcomes are not authoritative"
        )

    frame_results = _exact_object(
        evidence.get("frameResults"),
        {"single", "burst", "resumeClock", "eof", "replacement"},
        "seek-frame-oracles frameResults",
    )
    if any(value != "pass" for value in frame_results.values()):
        raise QualificationPolicyError("seek-frame-oracles frame results did not pass")

    frame_oracle = _exact_object(
        evidence.get("frameOracle"),
        {
            "baselineIndex",
            "singleIndex",
            "burstBaselineIndex",
            "burstFinalIndex",
            "resumeBaselineIndex",
            "resumeFinalIndex",
            "eofIndex",
            "baselineClockMilliseconds",
            "resumeClockMilliseconds",
            "singleSubmittedTimeMilliseconds",
            "burstSubmittedTimesMilliseconds",
            "eofSubmittedTimesMilliseconds",
            "contentSource",
        },
        "seek-frame-oracles frameOracle",
    )
    if frame_oracle["contentSource"] != "xcui-video-surface-screenshot":
        raise QualificationPolicyError(
            "seek-frame-oracles frame oracle is not screenshot-derived"
        )
    index_fields = {
        "baselineIndex",
        "singleIndex",
        "burstBaselineIndex",
        "burstFinalIndex",
        "resumeBaselineIndex",
        "resumeFinalIndex",
        "eofIndex",
    }
    indexes = {
        key: _integer(value, f"seek-frame-oracles frameOracle.{key}")
        for key, value in frame_oracle.items()
        if key in index_fields
    }
    frame_count = SEEK_FRAME_ORACLE_CONTRACT["frameCount"]
    if any(index < 0 or index >= frame_count for index in indexes.values()):
        raise QualificationPolicyError(
            "seek-frame-oracles decoded frame index is outside the bound fixture"
        )
    baseline_target = SEEK_FRAME_ORACLE_CONTRACT["baselineTargetIndex"]
    baseline_tolerance = SEEK_FRAME_ORACLE_CONTRACT["baselineToleranceFrames"]
    if abs(indexes["baselineIndex"] - baseline_target) > baseline_tolerance:
        raise QualificationPolicyError(
            "seek-frame-oracles baseline is inconsistent with the 1s/10fps fixture"
        )
    if indexes["singleIndex"] != (
        indexes["baselineIndex"] + SEEK_FRAME_ORACLE_CONTRACT["singleAdvanceFrames"]
    ):
        raise QualificationPolicyError(
            "seek-frame-oracles single step did not present exactly one frame"
        )
    if indexes["burstBaselineIndex"] != indexes["singleIndex"]:
        raise QualificationPolicyError(
            "seek-frame-oracles burst baseline changed before the burst"
        )
    if indexes["burstFinalIndex"] != (
        indexes["burstBaselineIndex"] + SEEK_FRAME_ORACLE_CONTRACT["burstAdvanceFrames"]
    ):
        raise QualificationPolicyError(
            "seek-frame-oracles burst did not present exactly twenty frames"
        )
    if (
        indexes["resumeBaselineIndex"] != indexes["burstFinalIndex"]
        or indexes["resumeFinalIndex"] <= indexes["resumeBaselineIndex"]
    ):
        raise QualificationPolicyError(
            "seek-frame-oracles resume clock/frame sequence is inconsistent"
        )
    if indexes["eofIndex"] != frame_count - 1:
        raise QualificationPolicyError(
            "seek-frame-oracles EOF screenshot is not the final fixture frame"
        )
    baseline_clock = _integer(
        frame_oracle["baselineClockMilliseconds"],
        "seek-frame-oracles frameOracle.baselineClockMilliseconds",
    )
    resume_clock = _integer(
        frame_oracle["resumeClockMilliseconds"],
        "seek-frame-oracles frameOracle.resumeClockMilliseconds",
    )
    if abs(baseline_clock - indexes["baselineIndex"] * 100) > 100:
        raise QualificationPolicyError(
            "seek-frame-oracles baseline clock contradicts visible frame"
        )
    if abs(resume_clock - indexes["resumeFinalIndex"] * 100) > 300:
        raise QualificationPolicyError(
            "seek-frame-oracles resumed clock contradicts visible frame"
        )
    single_time = _integer(
        frame_oracle["singleSubmittedTimeMilliseconds"],
        "seek-frame-oracles frameOracle.singleSubmittedTimeMilliseconds",
    )
    if single_time != indexes["singleIndex"] * 100:
        raise QualificationPolicyError(
            "seek-frame-oracles single submitted timestamp contradicts visible frame"
        )
    burst_times_value = frame_oracle["burstSubmittedTimesMilliseconds"]
    if not isinstance(burst_times_value, list):
        raise QualificationPolicyError(
            "seek-frame-oracles burst submitted timestamps are malformed"
        )
    burst_times = [
        _integer(value, "seek-frame-oracles burst submitted timestamp")
        for value in burst_times_value
    ]
    expected_burst_times = [
        frame_index * 100
        for frame_index in range(
            indexes["burstBaselineIndex"] + 1,
            indexes["burstFinalIndex"] + 1,
        )
    ]
    if burst_times != expected_burst_times:
        raise QualificationPolicyError(
            "seek-frame-oracles burst timestamps do not map each visible frame"
        )
    eof_times_value = frame_oracle["eofSubmittedTimesMilliseconds"]
    if not isinstance(eof_times_value, list) or not eof_times_value:
        raise QualificationPolicyError(
            "seek-frame-oracles EOF submitted timestamps are missing"
        )
    eof_times = [
        _integer(value, "seek-frame-oracles EOF submitted timestamp")
        for value in eof_times_value
    ]
    expected_eof_times = [
        frame_index * 100 for frame_index in range(frame_count - 4, frame_count)
    ]
    if eof_times != expected_eof_times:
        raise QualificationPolicyError(
            "seek-frame-oracles EOF timestamps are not the exact final four frames"
        )

    frame_terminals = _exact_object(
        evidence.get("frameTerminals"),
        {"single", "burst", "eof", "replacement"},
        "seek-frame-oracles frameTerminals",
    )
    burst_terminals = frame_terminals["burst"]
    eof_terminals = frame_terminals["eof"]
    replacement_terminals = frame_terminals["replacement"]
    if frame_terminals["single"] != "submitted":
        raise QualificationPolicyError("seek-frame-oracles single terminal is invalid")
    if (
        burst_terminals
        != ["submitted"] * SEEK_FRAME_ORACLE_CONTRACT["burstAdvanceFrames"]
    ):
        raise QualificationPolicyError(
            "seek-frame-oracles burst terminal inventory is not exactly twenty submissions"
        )
    if not isinstance(eof_terminals, list) or eof_terminals != ["submitted"] * 4 + [
        "noFrame"
    ]:
        raise QualificationPolicyError(
            "seek-frame-oracles EOF terminals are not submissions followed by one noFrame"
        )
    if (
        replacement_terminals
        != ["superseded"] * SEEK_FRAME_ORACLE_CONTRACT["replacementRequestCount"]
    ):
        raise QualificationPolicyError(
            "seek-frame-oracles replacement did not supersede all twelve requests"
        )
    if evidence.get("libraryErrorCount") != 0:
        raise QualificationPolicyError(
            "seek-frame-oracles contains library error diagnostics"
        )


def _valid_error_record(value: object) -> bool:
    return (
        isinstance(value, dict)
        and (value.get("module") is None or isinstance(value.get("module"), str))
        and isinstance(value.get("message"), str)
        and bool(value["message"].strip())
    )


ERROR_INVENTORY_ALGORITHM = "swiftvlc-raw-error-inventory-v2"
LEGACY_ERROR_INVENTORY_ALGORITHM = "swiftvlc-raw-error-inventory-v1"

TEST_LOG_UUID_PATTERN = re.compile(
    r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-" r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
)

TERMINAL_ERROR_ACTIONS = {
    "clean-eof": ("naturalEnd", None),
    "explicit-stop": ("requestedStop", None),
    "replacement": ("replacement", None),
    "server-close": ("failure:source", "source"),
    "malformed": ("failure:demux", "demux"),
    "decode-failure": ("failure:decoder", "decoder"),
    "renderer-failure": ("failure:renderer", "renderer"),
    "output-failure": ("failure:output", "output"),
    "network-loss": ("failure:source", "source"),
}

# A few qualification tests intentionally relaunch the candidate into isolated
# phases.  Every child filename remains anchored to the XCTest-owned base stem;
# no other free-form child logs are authorized.
DECLARED_TEST_CHILD_LOGS = {
    "audio-media-services-reset": frozenset({"audiounit", "avsamplebuffer"}),
    "audio-session-ownership": frozenset(
        {
            "library-order1-audiounit",
            "library-order1-avsamplebuffer",
            "library-order2-avsamplebuffer",
            "library-order2-audiounit",
            "application-audiounit",
            "application-avsamplebuffer",
        }
    ),
    "terminal-outcomes": frozenset(
        f"terminal-outcomes-{action}" for action in TERMINAL_ERROR_ACTIONS
    ),
    "dismissal": frozenset(
        f"{backend}-{affordance}"
        for backend in ("native", "direct")
        for affordance in ("restore", "close")
    ),
    "interruptions": frozenset({"native", "direct"}),
    "native-lifecycle": frozenset(
        {
            "native-lifecycle-restore",
            "native-lifecycle-close",
            "native-lifecycle-failed-start",
            "native-lifecycle-programmatic",
            "native-lifecycle-media-end",
            "native-lifecycle-failure",
            "native-lifecycle-recast",
            "native-lifecycle-replacement",
        }
    ),
}

LOG_MIRROR_HEALTH_MODULE = "swiftvlc.qualification.log-mirror"
LOG_MIRROR_HEALTH_MESSAGE = "mirror-start/v1"

# libVLC's module name is structured callback metadata.  These are deliberately
# exact normalized module identifiers, not substrings taken from a diagnostic.
# The action/phase comes from the host-owned log filename, so a renderer error
# observed during a source-loss injection cannot be relabelled by the test.
EXPECTED_ERROR_MODULES = {
    "source": frozenset(
        {
            "access",
            "access_http",
            "http",
            "http stream",
            "main input",
            "main stream",
            "stream",
            "tcp",
            "udp",
        }
    ),
    "demux": frozenset({"demux", "main demux", "mp4", "mp4 demux"}),
    "decoder": frozenset({"avcodec", "avcodec decoder", "decoder", "main decoder"}),
    "renderer": frozenset({"display", "main video output", "video output", "vout"}),
    "output": frozenset({"aout", "audio output", "main audio output"}),
    "adaptive": frozenset(
        {
            "access",
            "access_http",
            "adaptive",
            "adaptive stream",
            "hls",
            "http",
            "http stream",
            "main stream",
            "stream",
            "tcp",
        }
    ),
}


def _normalized_text(value: str) -> str:
    return " ".join(unicodedata.normalize("NFKC", value).split())


def normalize_error_record(record: object, phase: str) -> dict:
    if not _valid_error_record(record):
        raise QualificationPolicyError(
            "error inventory contains malformed error record"
        )
    assert isinstance(record, dict)
    module_value = record.get("module")
    module = (
        _normalized_text(module_value).casefold()
        if isinstance(module_value, str) and _normalized_text(module_value)
        else None
    )
    message = _normalized_text(record["message"])
    normalized = {"phase": phase, "module": module, "message": message}
    return {
        **normalized,
        "fingerprintAlgorithm": "sha256",
        "fingerprint": hashlib.sha256(canonical_json_bytes(normalized)).hexdigest(),
    }


def _inventory_digest(value: dict) -> str:
    unsigned = {
        key: item
        for key, item in value.items()
        if key not in {"inventoryDigestAlgorithm", "inventoryDigest"}
    }
    version = value.get("formatVersion")
    domain = (
        b"SwiftVLC raw qualification error inventory v2\0"
        if version == 2
        else b"SwiftVLC raw qualification error inventory v1\0"
    )
    return hashlib.sha256(domain + canonical_json_bytes(unsigned)).hexdigest()


def _error_phase(scenario_id: str, filename: str) -> str:
    if scenario_id != "terminal-outcomes":
        return scenario_id
    for action in TERMINAL_ERROR_ACTIONS:
        if filename.endswith(f"-terminal-outcomes-{action}.jsonl"):
            return action
    return "unattributed"


def test_log_filename(
    prefix: str,
    test_identifier: str,
    invocation_id: str,
    *,
    child: str | None = None,
) -> str:
    """Return the exact physical-device JSONL name produced for one XCTest."""

    canonical = normalize_test_identifier(test_identifier)
    if not prefix or Path(prefix).name != prefix:
        raise QualificationPolicyError("device log prefix is unsafe")
    if TEST_LOG_UUID_PATTERN.fullmatch(invocation_id) is None:
        raise QualificationPolicyError("device log invocation identifier is invalid")
    _, test_class, method = canonical.split("/")
    if child is not None and (
        not child or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*", child) is None
    ):
        raise QualificationPolicyError("device child log name is invalid")
    suffix = f"-{child}" if child is not None else ""
    return f"{prefix}-{test_class}_{method}-{invocation_id}{suffix}.jsonl"


def _test_log_tokens(test_identifier: str) -> tuple[str, str]:
    bundle, test_class, method = normalize_test_identifier(test_identifier).split("/")
    return (f"{test_class}_{method}", f"{bundle}.{test_class}_{method}")


def _bind_test_log_files(
    files: Sequence[Path],
    log_root: Path,
    prefix: str,
    scenario_id: str,
    test_identifiers: Sequence[str],
) -> dict[str, dict]:
    canonical_tests = normalize_catalog_identifiers(test_identifiers)
    matches_by_test: dict[str, list[tuple[str, str | None, str]]] = {
        identifier: [] for identifier in canonical_tests
    }
    metadata_by_path: dict[str, dict] = {}
    for path in files:
        relative = path.relative_to(log_root).as_posix()
        name = path.name
        if not name.startswith(prefix + "-") or not name.endswith(".jsonl"):
            raise QualificationPolicyError(
                f"device log is not anchored to host prefix: {relative!r}"
            )
        tail = name[len(prefix) + 1 : -len(".jsonl")]
        candidates: list[tuple[str, str, str | None]] = []
        for identifier in canonical_tests:
            for token in _test_log_tokens(identifier):
                match = re.fullmatch(
                    re.escape(token)
                    + r"-(?P<invocation>"
                    + TEST_LOG_UUID_PATTERN.pattern
                    + r")(?:-(?P<child>[A-Za-z0-9][A-Za-z0-9-]*))?",
                    tail,
                )
                if match is not None:
                    candidates.append(
                        (
                            identifier,
                            match.group("invocation").lower(),
                            match.group("child"),
                        )
                    )
        unique = set(candidates)
        if len(unique) != 1:
            raise QualificationPolicyError(
                f"device log {relative!r} does not map to exactly one expected XCTest"
            )
        identifier, invocation, child = unique.pop()
        matches_by_test[identifier].append((invocation, child, relative))
        metadata_by_path[relative] = {
            "testIdentifier": identifier,
            "invocationID": invocation,
            "logRole": "child" if child is not None else "base",
            **({"childName": child} if child is not None else {}),
        }

    declared_children = DECLARED_TEST_CHILD_LOGS.get(scenario_id)
    for identifier, matches in matches_by_test.items():
        if not matches:
            raise QualificationPolicyError(
                f"expected XCTest {identifier!r} has no retained device JSONL family"
            )
        invocations = {invocation for invocation, _, _ in matches}
        if len(invocations) != 1:
            raise QualificationPolicyError(
                f"expected XCTest {identifier!r} has multiple device log invocations"
            )
        base_paths = [path for _, child, path in matches if child is None]
        child_records = [
            (child, path) for _, child, path in matches if child is not None
        ]
        if declared_children is None:
            if len(base_paths) != 1 or child_records:
                raise QualificationPolicyError(
                    f"expected XCTest {identifier!r} has an invalid base device log set"
                )
            continue
        if len(base_paths) != 1:
            raise QualificationPolicyError(
                f"expected XCTest {identifier!r} must have exactly one base device log"
            )
        observed_children = Counter(child for child, _ in child_records)
        expected_children = Counter({child: 1 for child in declared_children})
        if observed_children != expected_children:
            raise QualificationPolicyError(
                f"expected XCTest {identifier!r} child device log set mismatch"
            )
    return metadata_by_path


def _is_log_mirror_health_record(value: object) -> bool:
    if not isinstance(value, dict) or set(value) != {
        "ts",
        "level",
        "module",
        "message",
    }:
        return False
    if (
        value.get("level") != "debug"
        or value.get("module") != LOG_MIRROR_HEALTH_MODULE
        or value.get("message") != LOG_MIRROR_HEALTH_MESSAGE
        or not isinstance(value.get("ts"), str)
    ):
        return False
    try:
        timestamp = datetime.fromisoformat(value["ts"].replace("Z", "+00:00"))
    except ValueError:
        return False
    return timestamp.tzinfo is not None


def build_error_inventory(
    log_root: Path,
    prefix: str,
    scenario_id: str,
    *,
    retained_root: str | None = None,
    expected_test_catalog: dict | Sequence[str] | None = None,
) -> dict:
    try:
        root_metadata = log_root.lstat()
    except OSError:
        root_metadata = None
    if (
        root_metadata is None
        or not stat.S_ISDIR(root_metadata.st_mode)
        or stat.S_ISLNK(root_metadata.st_mode)
    ):
        raise QualificationPolicyError(f"device log root is missing: {log_root}")
    if not prefix or Path(prefix).name != prefix:
        raise QualificationPolicyError("device log prefix is unsafe")
    if retained_root is not None:
        retained_candidate = Path(retained_root)
        if (
            not retained_root
            or retained_candidate.is_absolute()
            or ".." in retained_candidate.parts
        ):
            raise QualificationPolicyError("device log retainedRoot is unsafe")
    candidates = list(log_root.rglob("*.jsonl"))
    unexpected = sorted(
        path.relative_to(log_root).as_posix()
        for path in candidates
        if not path.name.startswith(prefix + "-")
    )
    if unexpected:
        raise QualificationPolicyError(
            "retained raw JSONL set contains files outside the exact host prefix: "
            f"{unexpected!r}"
        )
    for path in candidates:
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            raise QualificationPolicyError(
                f"device log is not a retained regular file: {path}"
            )
        try:
            path.resolve().relative_to(log_root.resolve())
        except ValueError as error:
            raise QualificationPolicyError(
                f"device log escapes root: {path}"
            ) from error
    files = sorted(
        candidates,
        key=lambda path: path.relative_to(log_root).as_posix(),
    )
    if not files:
        raise QualificationPolicyError(
            f"no device JSONL logs matched host prefix {prefix!r}"
        )
    canonical_test_catalog: dict | None = None
    test_log_metadata: dict[str, dict] = {}
    if expected_test_catalog is not None:
        if isinstance(expected_test_catalog, dict):
            identifiers = expected_test_catalog.get("testIdentifiers", [])
            canonical_test_catalog = catalog_record(identifiers)
            if expected_test_catalog != canonical_test_catalog:
                raise QualificationPolicyError(
                    "device log expected XCTest catalog is not canonical"
                )
        elif isinstance(expected_test_catalog, Sequence) and not isinstance(
            expected_test_catalog, (str, bytes)
        ):
            canonical_test_catalog = catalog_record(expected_test_catalog)
        else:
            raise QualificationPolicyError(
                "device log expected XCTest catalog is malformed"
            )
        test_log_metadata = _bind_test_log_files(
            files,
            log_root,
            prefix,
            scenario_id,
            canonical_test_catalog["testIdentifiers"],
        )
    file_records: list[dict] = []
    errors: list[dict] = []
    for path in files:
        relative = path.relative_to(log_root).as_posix()
        phase = _error_phase(scenario_id, path.name)
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeError) as error:
            raise QualificationPolicyError(
                f"cannot read device log {path}: {error}"
            ) from error
        if not lines:
            raise QualificationPolicyError(
                f"device log {relative} contains no structured records"
            )
        health_record_count = 0
        for line_number, line in enumerate(lines, 1):
            if not line.strip():
                raise QualificationPolicyError(
                    f"device log {relative}:{line_number} contains an empty record"
                )
            value = loads_json(line, f"device log {relative}:{line_number}")
            if not isinstance(value, dict):
                raise QualificationPolicyError(
                    f"device log {relative}:{line_number} record is not an object"
                )
            if _is_log_mirror_health_record(value):
                health_record_count += 1
            level = value.get("level")
            if not isinstance(level, str):
                raise QualificationPolicyError(
                    f"device log {relative}:{line_number} has no level"
                )
            structured_text = json.dumps(
                value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
            )
            signals = product_failure_signals(_normalized_text(structured_text))
            if signals:
                raise QualificationPolicyError(
                    f"device log {relative}:{line_number} contains immutable "
                    f"product-failure signals: {signals!r}"
                )
            if level.casefold() != "error":
                continue
            normalized = normalize_error_record(value, phase)
            errors.append(
                {
                    **normalized,
                    "sourceFile": relative,
                    "sourceLine": line_number,
                }
            )
        if canonical_test_catalog is not None and health_record_count < 1:
            raise QualificationPolicyError(
                f"device log {relative} has no valid synchronous mirror health record"
            )
        file_records.append(
            {
                "path": relative,
                "phase": phase,
                "digestAlgorithm": "sha256",
                "digest": sha256_file(path),
                "sizeBytes": path.stat().st_size,
                "recordCount": len(lines),
                "healthRecordCount": health_record_count,
                **test_log_metadata.get(relative, {}),
            }
        )
    inventory = {
        "formatVersion": 2 if canonical_test_catalog is not None else 1,
        "scenario": scenario_id,
        "logPrefix": prefix,
        **(
            {"testCatalog": canonical_test_catalog}
            if canonical_test_catalog is not None
            else {}
        ),
        **({"retainedRoot": retained_root} if retained_root is not None else {}),
        "rawFiles": file_records,
        "errorCount": len(errors),
        "errors": errors,
        "inventoryDigestAlgorithm": (
            ERROR_INVENTORY_ALGORITHM
            if canonical_test_catalog is not None
            else LEGACY_ERROR_INVENTORY_ALGORITHM
        ),
    }
    inventory["inventoryDigest"] = _inventory_digest(inventory)
    return inventory


def stage_error_logs(
    source_root: Path,
    source_prefix: str,
    destination_root: Path,
) -> None:
    """Copy one scenario's JSONL into a dedicated exact retained root."""

    if not source_prefix or Path(source_prefix).name != source_prefix:
        raise QualificationPolicyError("device log source prefix is unsafe")
    if destination_root.exists() or destination_root.is_symlink():
        raise QualificationPolicyError(
            f"retained device log root already exists: {destination_root}"
        )
    try:
        source_metadata = source_root.lstat()
    except OSError as error:
        raise QualificationPolicyError(
            f"device log source root is missing: {source_root}"
        ) from error
    if not stat.S_ISDIR(source_metadata.st_mode) or stat.S_ISLNK(
        source_metadata.st_mode
    ):
        raise QualificationPolicyError("device log source root is not a real directory")
    candidates = sorted(
        (
            path
            for path in source_root.rglob("*.jsonl")
            if path.name.startswith(source_prefix + "-")
        ),
        key=lambda path: path.relative_to(source_root).as_posix(),
    )
    if not candidates:
        raise QualificationPolicyError(
            f"no device JSONL logs matched scenario prefix {source_prefix!r}"
        )
    for path in candidates:
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            raise QualificationPolicyError(
                f"device log is not a retained regular file: {path}"
            )
        try:
            path.resolve().relative_to(source_root.resolve())
        except ValueError as error:
            raise QualificationPolicyError(
                f"device log escapes root: {path}"
            ) from error
    destination_root.mkdir(parents=True)
    for source in candidates:
        relative = source.relative_to(source_root)
        destination = destination_root / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)


def validate_error_inventory(
    value: object,
    *,
    retained_base: Path | None = None,
    require_retained: bool = False,
    expected_test_catalog: dict | Sequence[str] | None = None,
) -> dict:
    if not isinstance(value, dict) or value.get("formatVersion") not in {1, 2}:
        raise QualificationPolicyError("host error inventory is missing or malformed")
    format_version = value["formatVersion"]
    expected_algorithm = (
        ERROR_INVENTORY_ALGORITHM
        if format_version == 2
        else LEGACY_ERROR_INVENTORY_ALGORITHM
    )
    if value.get("inventoryDigestAlgorithm") != expected_algorithm:
        raise QualificationPolicyError("host error inventory algorithm mismatch")
    if value.get("inventoryDigest") != _inventory_digest(value):
        raise QualificationPolicyError("host error inventory digest mismatch")
    if not isinstance(value.get("scenario"), str) or not ID.fullmatch(
        value["scenario"]
    ):
        raise QualificationPolicyError("host error inventory scenario is invalid")
    canonical_test_catalog: dict | None = None
    if format_version == 2:
        test_catalog = value.get("testCatalog")
        if not isinstance(test_catalog, dict):
            raise QualificationPolicyError(
                "host error inventory has no XCTest log catalog"
            )
        canonical_test_catalog = catalog_record(test_catalog.get("testIdentifiers", []))
        if test_catalog != canonical_test_catalog:
            raise QualificationPolicyError(
                "host error inventory XCTest log catalog is not canonical"
            )
    elif expected_test_catalog is not None:
        raise QualificationPolicyError(
            "host error inventory lacks exact per-XCTest log bindings"
        )
    if expected_test_catalog is not None:
        if isinstance(expected_test_catalog, dict):
            expected_canonical = catalog_record(
                expected_test_catalog.get("testIdentifiers", [])
            )
            if expected_test_catalog != expected_canonical:
                raise QualificationPolicyError(
                    "expected XCTest log catalog is not canonical"
                )
        elif isinstance(expected_test_catalog, Sequence) and not isinstance(
            expected_test_catalog, (str, bytes)
        ):
            expected_canonical = catalog_record(expected_test_catalog)
        else:
            raise QualificationPolicyError("expected XCTest log catalog is malformed")
        if canonical_test_catalog != expected_canonical:
            raise QualificationPolicyError(
                "host error inventory XCTest log catalog mismatch"
            )
    log_prefix = value.get("logPrefix")
    if (
        not isinstance(log_prefix, str)
        or not log_prefix
        or Path(log_prefix).name != log_prefix
    ):
        raise QualificationPolicyError("host error inventory logPrefix is invalid")
    retained_root_value = value.get("retainedRoot")
    if retained_root_value is not None:
        retained_candidate = Path(str(retained_root_value))
        if (
            not isinstance(retained_root_value, str)
            or not retained_root_value
            or retained_candidate.is_absolute()
            or ".." in retained_candidate.parts
        ):
            raise QualificationPolicyError(
                "host error inventory retainedRoot is invalid"
            )
    raw_files = value.get("rawFiles")
    errors = value.get("errors")
    if not isinstance(raw_files, list) or not raw_files:
        raise QualificationPolicyError("host error inventory has no raw files")
    if not isinstance(errors, list) or value.get("errorCount") != len(errors):
        raise QualificationPolicyError("host error inventory errorCount mismatch")
    paths: set[str] = set()
    test_log_families: dict[str, list[tuple[str, str, str | None]]] | None = None
    if format_version == 2:
        assert canonical_test_catalog is not None
        test_log_families = {
            identifier: [] for identifier in canonical_test_catalog["testIdentifiers"]
        }
    for file_record in raw_files:
        if not isinstance(file_record, dict):
            raise QualificationPolicyError("host error inventory raw file is malformed")
        path = file_record.get("path")
        phase = file_record.get("phase")
        if (
            not isinstance(path, str)
            or not path
            or Path(path).is_absolute()
            or ".." in Path(path).parts
            or path in paths
            or not isinstance(phase, str)
            or not phase
            or file_record.get("digestAlgorithm") != "sha256"
            or not SHA256.fullmatch(str(file_record.get("digest", "")))
            or isinstance(file_record.get("sizeBytes"), bool)
            or not isinstance(file_record.get("sizeBytes"), int)
            or file_record.get("sizeBytes") < 0
            or isinstance(file_record.get("recordCount"), bool)
            or not isinstance(file_record.get("recordCount"), int)
            or file_record.get("recordCount") <= 0
            or isinstance(file_record.get("healthRecordCount"), bool)
            or not isinstance(file_record.get("healthRecordCount"), int)
            or file_record.get("healthRecordCount") < 0
            or (format_version == 2 and file_record.get("healthRecordCount") < 1)
        ):
            raise QualificationPolicyError(
                "host error inventory raw file binding is invalid"
            )
        paths.add(path)
        if format_version == 2:
            identifier = file_record.get("testIdentifier")
            invocation = file_record.get("invocationID")
            role = file_record.get("logRole")
            child = file_record.get("childName")
            if (
                canonical_test_catalog is None
                or identifier not in canonical_test_catalog["testIdentifiers"]
                or not isinstance(invocation, str)
                or TEST_LOG_UUID_PATTERN.fullmatch(invocation) is None
                or role not in {"base", "child"}
                or (role == "base" and child is not None)
                or (
                    role == "child"
                    and (
                        not isinstance(child, str)
                        or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*", child) is None
                    )
                )
            ):
                raise QualificationPolicyError(
                    "host error inventory XCTest raw file binding is invalid"
                )
            assert test_log_families is not None
            assert isinstance(identifier, str)
            assert isinstance(invocation, str)
            assert isinstance(role, str)
            test_log_families[identifier].append((invocation, role, child))
    if test_log_families is not None:
        declared_children = DECLARED_TEST_CHILD_LOGS.get(value["scenario"])
        expected_children = Counter(
            {}
            if declared_children is None
            else {child: 1 for child in declared_children}
        )
        for identifier, family in test_log_families.items():
            invocations = {invocation for invocation, _, _ in family}
            if len(invocations) != 1:
                raise QualificationPolicyError(
                    f"host error inventory expected XCTest {identifier!r} "
                    "must have exactly one invocation"
                )
            base_count = sum(1 for _, role, _ in family if role == "base")
            if base_count != 1:
                raise QualificationPolicyError(
                    f"host error inventory expected XCTest {identifier!r} "
                    "must have exactly one base log"
                )
            observed_children = Counter(
                child for _, role, child in family if role == "child"
            )
            if observed_children != expected_children:
                raise QualificationPolicyError(
                    f"host error inventory expected XCTest {identifier!r} "
                    "child log set mismatch"
                )
    if value["scenario"] == "terminal-outcomes":
        action_files = raw_files
        if format_version == 2:
            action_files = [
                record for record in raw_files if record.get("childName") is not None
            ]
            observed_children = Counter(record["childName"] for record in action_files)
            expected_children = Counter(
                {child: 1 for child in DECLARED_TEST_CHILD_LOGS["terminal-outcomes"]}
            )
            if observed_children != expected_children:
                raise QualificationPolicyError(
                    "terminal error inventory child-log set mismatch: "
                    f"observed={dict(observed_children)!r}"
                )
        observed_phases = Counter(record["phase"] for record in action_files)
        expected_phases = Counter({action: 1 for action in TERMINAL_ERROR_ACTIONS})
        if observed_phases != expected_phases:
            raise QualificationPolicyError(
                "terminal error inventory action-log set mismatch: "
                f"observed={dict(observed_phases)!r}"
            )
    file_phases = {record["path"]: record["phase"] for record in raw_files}
    previous: tuple[str, int] | None = None
    for record in errors:
        if not isinstance(record, dict):
            raise QualificationPolicyError("host error inventory record is malformed")
        source_file = record.get("sourceFile")
        source_line = record.get("sourceLine")
        if (
            source_file not in paths
            or isinstance(source_line, bool)
            or not isinstance(source_line, int)
            or source_line <= 0
            or record.get("phase") != file_phases.get(str(source_file))
        ):
            raise QualificationPolicyError(
                "host error inventory record source is invalid"
            )
        canonical = normalize_error_record(record, str(record.get("phase", "")))
        for field in (
            "phase",
            "module",
            "message",
            "fingerprintAlgorithm",
            "fingerprint",
        ):
            if record.get(field) != canonical[field]:
                raise QualificationPolicyError(
                    f"host error inventory record {field} is not canonical"
                )
        position = (source_file, source_line)
        if previous is not None and position <= previous:
            raise QualificationPolicyError(
                "host error inventory records are not ordered"
            )
        previous = position
    if retained_base is not None or require_retained:
        if retained_base is None:
            raise QualificationPolicyError(
                "host error inventory retained base was not supplied"
            )
        retained_root = safe_relative_directory(
            retained_base,
            retained_root_value,
            "host error inventory retainedRoot",
        )
        rebuilt = build_error_inventory(
            retained_root,
            value["logPrefix"],
            value["scenario"],
            retained_root=str(retained_root_value),
            expected_test_catalog=canonical_test_catalog,
        )
        if rebuilt != value:
            raise QualificationPolicyError(
                "host error inventory differs from retained raw JSONL files"
            )
    return value


def _inventory_counter(inventory: dict) -> Counter[tuple[str, str]]:
    return Counter(
        (record["phase"], record["fingerprint"]) for record in inventory["errors"]
    )


def _evidence_error_counter(
    records_by_phase: dict[str, list],
) -> Counter[tuple[str, str]]:
    result: Counter[tuple[str, str]] = Counter()
    for phase, records in records_by_phase.items():
        for record in records:
            normalized = normalize_error_record(record, phase)
            result[(phase, normalized["fingerprint"])] += 1
    return result


def _validate_attributed_modules(
    records: list[dict], attribution: str, description: str
) -> None:
    allowed = EXPECTED_ERROR_MODULES[attribution]
    unrelated = []
    product_signals: list[tuple[str | None, str, list[str]]] = []
    for record in records:
        normalized = normalize_error_record(record, description)
        if normalized["module"] not in allowed:
            unrelated.append(normalized["module"])
        matches = product_failure_signals(normalized["message"])
        if matches:
            product_signals.append(
                (normalized["module"], normalized["message"], matches)
            )
    if unrelated:
        raise QualificationPolicyError(
            f"{description} contains error modules outside exact {attribution} attribution: "
            f"{unrelated!r}"
        )
    if product_signals:
        raise QualificationPolicyError(
            f"{description} contains fatal/crash/sanitizer/product-failure signals: "
            f"{product_signals!r}"
        )


def validate_expected_error_evidence(
    evidence: dict,
    scenario_id: str,
    *,
    retained_base: Path | None = None,
    require_retained: bool = False,
) -> None:
    inventory_value = evidence.get("hostErrorInventory")
    if inventory_value is None:
        if scenario_id in {"terminal-outcomes", "adaptive-hls-soak"}:
            raise QualificationPolicyError(
                f"{scenario_id} evidence has no host raw-error inventory"
            )
        return
    inventory = validate_error_inventory(
        inventory_value,
        retained_base=retained_base,
        require_retained=require_retained,
    )
    if scenario_id == "terminal-outcomes":
        if inventory.get("scenario") != scenario_id:
            raise QualificationPolicyError(
                "terminal-outcomes error inventory scenario mismatch"
            )
        cases = evidence.get("cases")
        if not isinstance(cases, dict):
            raise QualificationPolicyError("terminal-outcomes evidence has no cases")
        expected = TERMINAL_ERROR_ACTIONS
        if set(cases) != set(expected):
            raise QualificationPolicyError(
                "terminal-outcomes cases do not exactly match the expected action set"
            )
        for action, (cause, classification) in expected.items():
            case = cases[action]
            if not isinstance(case, dict):
                raise QualificationPolicyError(f"terminal case {action} is malformed")
            outcome = case.get("outcome")
            if (
                case.get("action") != action
                or not isinstance(outcome, dict)
                or outcome.get("cause") != cause
                or outcome.get("failureClassification") != classification
            ):
                raise QualificationPolicyError(
                    f"terminal case {action} is not attributed to {cause!r}"
                )
            records = case.get("libraryErrors")
            if not isinstance(records, list) or any(
                not _valid_error_record(record) for record in records
            ):
                raise QualificationPolicyError(
                    f"terminal case {action} has malformed libraryErrors"
                )
            if classification is None and records:
                raise QualificationPolicyError(
                    f"terminal non-failure case {action} contains error logs"
                )
            if classification is not None:
                if not records:
                    raise QualificationPolicyError(
                        f"terminal failure case {action} contains no attributed error"
                    )
                _validate_attributed_modules(
                    records, classification, f"terminal case {action}"
                )
        expected_errors = _evidence_error_counter(
            {action: cases[action]["libraryErrors"] for action in expected}
        )
        observed_errors = _inventory_counter(inventory)
        if expected_errors != observed_errors:
            missing = list((expected_errors - observed_errors).elements())
            extra = list((observed_errors - expected_errors).elements())
            raise QualificationPolicyError(
                "terminal-outcomes raw/evidence error inventory mismatch; "
                f"missingRaw={missing!r}, unconsumedRaw={extra!r}"
            )
    elif scenario_id == "adaptive-hls-soak":
        if inventory.get("scenario") != scenario_id:
            raise QualificationPolicyError(
                "adaptive-hls-soak error inventory scenario mismatch"
            )
        records = evidence.get("libraryErrors")
        count = evidence.get("libraryErrorCount")
        if (
            not isinstance(records, list)
            or any(not _valid_error_record(record) for record in records)
            or isinstance(count, bool)
            or not isinstance(count, int)
            or count != len(records)
        ):
            raise QualificationPolicyError(
                "adaptive-hls-soak library errors are missing or inconsistent"
            )
        _validate_attributed_modules(records, "adaptive", "adaptive-hls-soak")
        expected_errors = _evidence_error_counter({scenario_id: records})
        observed_errors = _inventory_counter(inventory)
        if expected_errors != observed_errors:
            missing = list((expected_errors - observed_errors).elements())
            extra = list((observed_errors - expected_errors).elements())
            raise QualificationPolicyError(
                "adaptive-hls-soak raw/evidence error inventory mismatch; "
                f"missingRaw={missing!r}, unconsumedRaw={extra!r}"
            )
    elif inventory.get("errorCount") != 0:
        raise QualificationPolicyError(
            f"{scenario_id} contains unexpected raw error-level diagnostics"
        )


PROVENANCE_FIELDS = (
    "candidateBuildAttestation",
    "candidateBuildAttestationDigestAlgorithm",
    "candidateBuildAttestationDigest",
    "candidateRuntimeBinding",
    "candidateAppBundleIdentifier",
    "candidateAppDigestAlgorithm",
    "candidateAppDigest",
    "testRunnerBundleIdentifier",
    "testRunnerDigestAlgorithm",
    "testRunnerDigest",
    "testBundleRelativePath",
    "testBundleDigestAlgorithm",
    "testBundleDigest",
    "baseXCTestRunDigestAlgorithm",
    "baseXCTestRunDigest",
    "baseXCTestRunName",
    "testCatalogDigestAlgorithm",
    "testCatalogDigest",
    "testCatalogCount",
    "testCatalog",
    "testCatalogAuthorityDigestAlgorithm",
    "testCatalogAuthorityDigest",
    "qualificationMatrixChecksum",
    "featureManifestChecksum",
    "qualificationProfilesChecksum",
    "fixtureManifestChecksum",
    "qualificationPolicyDigestAlgorithm",
    "qualificationPolicyDigest",
)

CORE_IDENTITY_FIELDS = (
    "version",
    "sourceCommit",
    "releaseSourceDigestAlgorithm",
    "releaseSourceDigest",
    "artifactDigestAlgorithm",
    "artifactDigest",
    *PROVENANCE_FIELDS,
)

QUALIFICATION_RUNTIME_BINDING_FIELDS = frozenset(
    {"qualificationSessionBinding", "candidateRuntimeBinding"}
)


def validate_and_strip_qualification_runtime_bindings(
    payload: dict,
    *,
    expected_session_binding: str,
    expected_candidate_binding: str,
) -> dict:
    """Validate device/test-origin bindings before ordinary evidence semantics.

    The raw XCTest attachment owns these two values. They are deliberately
    stripped from the semantic payload after validation so every scenario's
    existing exact key schema remains closed rather than gaining optional
    envelope fields. The retained attachment and final xcresult keep the full
    original bytes and are independently revalidated at report assembly.
    """

    if not isinstance(payload, dict):
        raise QualificationPolicyError(
            "qualification runtime-bound attachment must be a JSON object"
        )
    for description, field, expected in (
        (
            "qualification session",
            "qualificationSessionBinding",
            expected_session_binding,
        ),
        ("candidate runtime", "candidateRuntimeBinding", expected_candidate_binding),
    ):
        if not isinstance(expected, str) or SHA256.fullmatch(expected) is None:
            raise QualificationPolicyError(
                f"expected {description} binding must be 64 lowercase hex characters"
            )
        observed = payload.get(field)
        if not isinstance(observed, str) or SHA256.fullmatch(observed) is None:
            raise QualificationPolicyError(
                f"raw attachment has no valid {description} binding"
            )
        if observed != expected:
            raise QualificationPolicyError(
                f"raw attachment {description} binding mismatch"
            )
    return {
        key: value
        for key, value in payload.items()
        if key not in QUALIFICATION_RUNTIME_BINDING_FIELDS
    }


CANDIDATE_BUILD_ATTESTATION_KEYS = {
    "formatVersion",
    "authority",
    "version",
    "candidateRuntimeBinding",
    "sourceCommit",
    "releaseSourceDigestAlgorithm",
    "releaseSourceDigest",
    "artifactRelativePath",
    "artifactBindingMode",
    "artifactDigestAlgorithm",
    "artifactDigest",
    "workspaceStateRelativePath",
    "workspaceStateDigestAlgorithm",
    "workspaceStateDigest",
    "workspaceBinding",
    "buildConfiguration",
    "buildPlatform",
    "swiftSourceRoot",
    "swiftSourceSetDigestAlgorithm",
    "swiftSourceSetDigest",
    "swiftSourceCount",
    "swiftSourceRelativePaths",
    "swiftSourceFiles",
    "showcaseSourceRoot",
    "showcaseSourceSetDigestAlgorithm",
    "showcaseSourceSetDigest",
    "showcaseSourceCount",
    "showcaseSourceRelativePaths",
    "showcaseSourceFiles",
    "sourceAuthorityBuildInputSetDigestAlgorithm",
    "sourceAuthorityBuildInputSetDigest",
    "sourceAuthorityBuildInputCount",
    "sourceAuthorityBuildInputFiles",
    "effectiveBuildInputSetDigestAlgorithm",
    "effectiveBuildInputSetDigest",
    "effectiveBuildInputCount",
    "effectiveBuildInputFiles",
    "authorizedBuildInputTransforms",
    "developmentTeam",
    "bundlePrefix",
    "effectiveBuildSettingsDigestAlgorithm",
    "effectiveBuildSettingsDigest",
    "effectiveBuildSettings",
    "swiftFileLists",
    "showcaseTargetFileLists",
    "candidateAppRelativePath",
    "candidateAppDigestAlgorithm",
    "candidateAppDigest",
    "testRunnerRelativePath",
    "testRunnerDigestAlgorithm",
    "testRunnerDigest",
    "testBundleRelativePath",
    "testBundleDigestAlgorithm",
    "testBundleDigest",
    "baseXCTestRunName",
    "baseXCTestRunDigestAlgorithm",
    "baseXCTestRunDigest",
    "testCatalogDigestAlgorithm",
    "testCatalogDigest",
    "testCatalogCount",
    "testCatalog",
}

CANDIDATE_WORKSPACE_BINDING = {
    "dependencyKind": "fileSystem",
    "dependencyLocation": "$BUILD_SOURCE_ROOT",
    "dependencyStateName": "fileSystem",
    "dependencyStatePath": "$BUILD_SOURCE_ROOT",
    "artifactKind": "xcframework",
    "artifactPath": "$BUILD_SOURCE_ROOT/Vendor/libvlc.xcframework",
    "artifactSourceType": "local",
    "artifactTargetName": "libvlc",
}


def compiled_source_set_digest(records: list[dict]) -> str:
    if not isinstance(records, list) or not records:
        raise QualificationPolicyError("compiled source inventory must be non-empty")
    normalized: list[tuple[str, int, str]] = []
    for record in records:
        if not isinstance(record, dict) or set(record) != {
            "relativePath",
            "mode",
            "digestAlgorithm",
            "digest",
        }:
            raise QualificationPolicyError("compiled source inventory record is malformed")
        relative = record.get("relativePath")
        mode = record.get("mode")
        content_digest = record.get("digest")
        if (
            not isinstance(relative, str)
            or not relative.endswith(".swift")
            or Path(relative).is_absolute()
            or ".." in Path(relative).parts
            or not isinstance(mode, int)
            or isinstance(mode, bool)
            or mode < 0
            or mode > 0o7777
            or record.get("digestAlgorithm") != "sha256"
            or SHA256.fullmatch(str(content_digest or "")) is None
        ):
            raise QualificationPolicyError("compiled source inventory record is invalid")
        normalized.append((relative, mode, content_digest))
    if normalized != sorted(set(normalized)):
        raise QualificationPolicyError("compiled source inventory is not canonical")
    digest = hashlib.sha256(b"SwiftVLC compiled source set v2\0")
    for relative, mode, content_digest in normalized:
        for value in (
            b"file",
            relative.encode("utf-8"),
            mode.to_bytes(4, "big"),
            bytes.fromhex(content_digest),
        ):
            digest.update(len(value).to_bytes(8, "big"))
            digest.update(value)
    return digest.hexdigest()


def build_input_set_digest(records: list[dict]) -> str:
    if not isinstance(records, list) or not records:
        raise QualificationPolicyError("build input inventory must be non-empty")
    normalized: list[tuple[str, int, str]] = []
    for record in records:
        if not isinstance(record, dict) or set(record) != {
            "relativePath",
            "mode",
            "digestAlgorithm",
            "digest",
        }:
            raise QualificationPolicyError("build input inventory record is malformed")
        relative = record.get("relativePath")
        mode = record.get("mode")
        content_digest = record.get("digest")
        if (
            not isinstance(relative, str)
            or not relative
            or Path(relative).is_absolute()
            or ".." in Path(relative).parts
            or not isinstance(mode, int)
            or isinstance(mode, bool)
            or mode < 0
            or mode > 0o7777
            or record.get("digestAlgorithm") != "sha256"
            or SHA256.fullmatch(str(content_digest or "")) is None
        ):
            raise QualificationPolicyError("build input inventory record is invalid")
        normalized.append((relative, mode, content_digest))
    if normalized != sorted(set(normalized)):
        raise QualificationPolicyError("build input inventory is not canonical")
    return hashlib.sha256(
        b"SwiftVLC qualification build input set v1\0"
        + canonical_json_bytes(normalized)
    ).hexdigest()


def effective_build_settings_digest(records: list[dict]) -> str:
    if not isinstance(records, list) or not records:
        raise QualificationPolicyError("effective build settings must be non-empty")
    targets: list[str] = []
    for record in records:
        if not isinstance(record, dict) or set(record) != {"target", "settings"}:
            raise QualificationPolicyError(
                "effective build-settings record is malformed"
            )
        target = record.get("target")
        settings = record.get("settings")
        if (
            not isinstance(target, str)
            or not target
            or not isinstance(settings, dict)
            or not settings
            or list(settings) != sorted(settings)
            or any(
                not isinstance(key, str) or not isinstance(value, str)
                for key, value in settings.items()
            )
        ):
            raise QualificationPolicyError(
                "effective build-settings record is invalid"
            )
        targets.append(target)
    if targets != sorted(set(targets)) or not {"iOS", "iOSUITests"}.issubset(targets):
        raise QualificationPolicyError(
            "effective build settings are non-canonical or omit required targets"
        )
    return hashlib.sha256(
        b"SwiftVLC effective Xcode build settings v1\0"
        + canonical_json_bytes(records)
    ).hexdigest()


def validate_candidate_build_attestation(
    attestation: object, *, candidate: dict | None = None
) -> dict:
    if not isinstance(attestation, dict):
        raise QualificationPolicyError(
            "candidate metadata has no candidateBuildAttestation"
        )
    if set(attestation) != CANDIDATE_BUILD_ATTESTATION_KEYS:
        missing = sorted(CANDIDATE_BUILD_ATTESTATION_KEYS - set(attestation))
        extra = sorted(set(attestation) - CANDIDATE_BUILD_ATTESTATION_KEYS)
        raise QualificationPolicyError(
            "candidate build attestation schema mismatch: "
            f"missing={missing!r}, extra={extra!r}"
        )
    expected_scalars = {
        "formatVersion": 1,
        "authority": "swiftvlc-candidate-build-binding-v1",
        "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
        "artifactRelativePath": "Vendor/libvlc.xcframework",
        "artifactDigestAlgorithm": "swiftvlc-tree-v1",
        "workspaceStateRelativePath": "SourcePackages/workspace-state.json",
        "workspaceStateDigestAlgorithm": "sha256",
        "buildConfiguration": "Release",
        "buildPlatform": "iphoneos",
        "swiftSourceRoot": "Sources/SwiftVLC",
        "swiftSourceSetDigestAlgorithm": "swiftvlc-compiled-source-set-v2",
        "showcaseSourceRoot": "Showcase",
        "showcaseSourceSetDigestAlgorithm": "swiftvlc-compiled-source-set-v2",
        "sourceAuthorityBuildInputSetDigestAlgorithm": (
            "swiftvlc-build-input-set-v1"
        ),
        "effectiveBuildInputSetDigestAlgorithm": "swiftvlc-build-input-set-v1",
        "effectiveBuildSettingsDigestAlgorithm": (
            "swiftvlc-effective-build-settings-v1"
        ),
        "candidateAppRelativePath": "Release-iphoneos/iOS.app",
        "candidateAppDigestAlgorithm": "swiftvlc-tree-v1",
        "testRunnerRelativePath": "Release-iphoneos/iOSUITests-Runner.app",
        "testRunnerDigestAlgorithm": "swiftvlc-tree-v1",
        "testBundleRelativePath": "PlugIns/iOSUITests.xctest",
        "testBundleDigestAlgorithm": "swiftvlc-tree-v1",
        "baseXCTestRunDigestAlgorithm": "sha256",
        "testCatalogDigestAlgorithm": "swiftvlc-test-catalog-v1",
    }
    for field, expected in expected_scalars.items():
        if attestation.get(field) != expected:
            raise QualificationPolicyError(
                f"candidate build attestation {field} must be {expected!r}"
            )
    if not isinstance(attestation.get("version"), str) or not attestation["version"]:
        raise QualificationPolicyError(
            "candidate build attestation has no version"
        )
    if attestation.get("artifactBindingMode") not in {
        "direct",
        "vendor-symlink-to-authority-root",
    }:
        raise QualificationPolicyError(
            "candidate build attestation artifactBindingMode is invalid"
        )
    if (
        re.fullmatch(r"[A-Z0-9]{10}", str(attestation.get("developmentTeam", "")))
        is None
        or re.fullmatch(
            r"[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+",
            str(attestation.get("bundlePrefix", "")),
        )
        is None
    ):
        raise QualificationPolicyError(
            "candidate build attestation signing transform inputs are invalid"
        )
    if attestation.get("workspaceBinding") != CANDIDATE_WORKSPACE_BINDING:
        raise QualificationPolicyError(
            "candidate build attestation workspace binding is not exact local SwiftVLC"
        )
    for field, pattern in (
        ("sourceCommit", SHA1),
        ("candidateRuntimeBinding", SHA256),
        ("releaseSourceDigest", SHA256),
        ("artifactDigest", SHA256),
        ("workspaceStateDigest", SHA256),
        ("swiftSourceSetDigest", SHA256),
        ("sourceAuthorityBuildInputSetDigest", SHA256),
        ("effectiveBuildInputSetDigest", SHA256),
        ("effectiveBuildSettingsDigest", SHA256),
        ("candidateAppDigest", SHA256),
        ("testRunnerDigest", SHA256),
        ("testBundleDigest", SHA256),
        ("baseXCTestRunDigest", SHA256),
        ("testCatalogDigest", SHA256),
    ):
        if pattern.fullmatch(str(attestation.get(field, ""))) is None:
            raise QualificationPolicyError(
                f"candidate build attestation has no valid {field}"
            )
    for prefix, description in (
        ("swift", "SwiftVLC"),
        ("showcase", "Showcase"),
    ):
        sources = attestation.get(f"{prefix}SourceRelativePaths")
        records = attestation.get(f"{prefix}SourceFiles")
        if (
            not isinstance(sources, list)
            or not sources
            or not isinstance(records, list)
            or [item.get("relativePath") for item in records if isinstance(item, dict)]
            != sources
            or sources != sorted(set(sources))
            or attestation.get(f"{prefix}SourceCount") != len(sources)
        ):
            raise QualificationPolicyError(
                f"candidate build attestation {description} source inventory is invalid"
            )
        if attestation.get(f"{prefix}SourceSetDigest") != compiled_source_set_digest(
            records
        ):
            raise QualificationPolicyError(
                f"candidate build attestation {description} source set digest mismatch"
            )
    for prefix, description in (
        ("sourceAuthority", "source authority"),
        ("effective", "effective"),
    ):
        records = attestation.get(f"{prefix}BuildInputFiles")
        if (
            not isinstance(records, list)
            or attestation.get(f"{prefix}BuildInputCount") != len(records)
            or attestation.get(f"{prefix}BuildInputSetDigest")
            != build_input_set_digest(records)
        ):
            raise QualificationPolicyError(
                f"candidate build attestation {description} build input inventory is invalid"
            )
    transforms = attestation.get("authorizedBuildInputTransforms")
    allowed_transforms = {
        "Package.swift",
        "Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj",
        (
            "Showcase/SwiftVLCShowcase.xcodeproj/project.xcworkspace/"
            "xcshareddata/swiftpm/Package.resolved"
        ),
    }
    if (
        not isinstance(transforms, list)
        or transforms != sorted(set(transforms))
        or not set(transforms).issubset(allowed_transforms)
    ):
        raise QualificationPolicyError(
            "candidate build attestation authorized build input transforms are invalid"
        )
    settings = attestation.get("effectiveBuildSettings")
    if (
        not isinstance(settings, list)
        or attestation.get("effectiveBuildSettingsDigest")
        != effective_build_settings_digest(settings)
    ):
        raise QualificationPolicyError(
            "candidate build attestation effective build settings are invalid"
        )
    file_lists = attestation.get("swiftFileLists")
    if not isinstance(file_lists, list) or not file_lists:
        raise QualificationPolicyError(
            "candidate build attestation has no Swift file-list verification"
        )
    architectures: set[str] = set()
    for record in file_lists:
        if not isinstance(record, dict) or set(record) != {
            "architecture",
            "digestAlgorithm",
            "digest",
            "relativePath",
            "sourceCount",
        }:
            raise QualificationPolicyError(
                "candidate build attestation has malformed Swift file-list evidence"
            )
        architecture = record.get("architecture")
        relative = record.get("relativePath")
        expected_suffix = (
            "/SwiftVLC.build/Release-iphoneos/SwiftVLC.build/Objects-normal/"
            f"{architecture}/SwiftVLC.SwiftFileList"
        )
        if (
            not isinstance(architecture, str)
            or not architecture
            or architecture in architectures
            or record.get("digestAlgorithm") != "sha256"
            or SHA256.fullmatch(str(record.get("digest", ""))) is None
            or not isinstance(relative, str)
            or Path(relative).is_absolute()
            or ".." in Path(relative).parts
            or not relative.endswith(expected_suffix)
            or record.get("sourceCount")
            != attestation.get("swiftSourceCount")
        ):
            raise QualificationPolicyError(
                "candidate build attestation Swift file-list evidence is invalid"
            )
        architectures.add(architecture)
    if file_lists != sorted(
        file_lists, key=lambda item: (item["architecture"], item["relativePath"])
    ):
        raise QualificationPolicyError(
            "candidate build attestation Swift file-list evidence is not canonical"
        )
    showcase_file_lists = attestation.get("showcaseTargetFileLists")
    if not isinstance(showcase_file_lists, list) or not showcase_file_lists:
        raise QualificationPolicyError(
            "candidate build attestation has no Showcase target file-list verification"
        )
    expected_sources_by_target = {
        "iOS": sum(
            1
            for path in attestation["showcaseSourceRelativePaths"]
            if path.startswith("Shared/") or path.startswith("iOS/")
        ),
        "iOSUITests": sum(
            1
            for path in attestation["showcaseSourceRelativePaths"]
            if path.startswith("Shared/") or path.startswith("UITests/iOS/")
        ),
    }
    observed_target_architectures: set[tuple[str, str]] = set()
    observed_targets: set[str] = set()
    for record in showcase_file_lists:
        if not isinstance(record, dict) or set(record) != {
            "target",
            "architecture",
            "digestAlgorithm",
            "digest",
            "relativePath",
            "sourceCount",
            "generatedSourceCount",
            "generatedSourceDigestAlgorithm",
            "generatedSourceDigest",
        }:
            raise QualificationPolicyError(
                "candidate build attestation has malformed Showcase file-list evidence"
            )
        target = record.get("target")
        architecture = record.get("architecture")
        relative = record.get("relativePath")
        expected_suffix = (
            f"/SwiftVLCShowcase.build/Release-iphoneos/{target}.build/"
            f"Objects-normal/{architecture}/{target}.SwiftFileList"
        )
        target_architecture = (target, architecture)
        if (
            target not in expected_sources_by_target
            or not isinstance(architecture, str)
            or not architecture
            or target_architecture in observed_target_architectures
            or record.get("digestAlgorithm") != "sha256"
            or SHA256.fullmatch(str(record.get("digest", ""))) is None
            or not isinstance(relative, str)
            or Path(relative).is_absolute()
            or ".." in Path(relative).parts
            or not relative.endswith(expected_suffix)
            or record.get("sourceCount") != expected_sources_by_target[target]
            or record.get("generatedSourceCount") != 1
            or record.get("generatedSourceDigestAlgorithm") != "sha256"
            or SHA256.fullmatch(str(record.get("generatedSourceDigest", "")))
            is None
        ):
            raise QualificationPolicyError(
                "candidate build attestation Showcase file-list evidence is invalid"
            )
        observed_target_architectures.add(target_architecture)
        observed_targets.add(target)
    if observed_targets != set(expected_sources_by_target):
        raise QualificationPolicyError(
            "candidate build attestation is missing an iOS or iOSUITests file list"
        )
    if showcase_file_lists != sorted(
        showcase_file_lists,
        key=lambda item: (
            item["target"],
            item["architecture"],
            item["relativePath"],
        ),
    ):
        raise QualificationPolicyError(
            "candidate build attestation Showcase file-list evidence is not canonical"
        )
    xctestrun_name = attestation.get("baseXCTestRunName")
    if (
        not isinstance(xctestrun_name, str)
        or xctestrun_name != Path(xctestrun_name).name
        or not xctestrun_name.endswith(".xctestrun")
    ):
        raise QualificationPolicyError(
            "candidate build attestation baseXCTestRunName is unsafe"
        )
    catalog = attestation.get("testCatalog")
    if not isinstance(catalog, list) or any(
        not isinstance(identifier, str) for identifier in catalog
    ):
        raise QualificationPolicyError(
            "candidate build attestation has no exact test catalog"
        )
    canonical_catalog = catalog_record(catalog)
    if (
        catalog != canonical_catalog["testIdentifiers"]
        or attestation.get("testCatalogCount") != canonical_catalog["testCount"]
        or attestation.get("testCatalogDigest") != canonical_catalog["digest"]
    ):
        raise QualificationPolicyError(
            "candidate build attestation test catalog is not canonical"
        )
    if candidate is not None:
        for field in (
            "version",
            "candidateRuntimeBinding",
            "sourceCommit",
            "releaseSourceDigest",
            "artifactDigest",
        ):
            if attestation.get(field) != candidate.get(field):
                raise QualificationPolicyError(
                    f"candidate build attestation {field} does not match candidate metadata"
                )
        for attestation_field, candidate_field in (
            ("candidateAppDigest", "candidateAppDigest"),
            ("testRunnerDigest", "testRunnerDigest"),
            ("testBundleRelativePath", "testBundleRelativePath"),
            ("testBundleDigest", "testBundleDigest"),
            ("baseXCTestRunName", "baseXCTestRunName"),
            ("baseXCTestRunDigest", "baseXCTestRunDigest"),
            ("testCatalogDigest", "testCatalogDigest"),
            ("testCatalogCount", "testCatalogCount"),
            ("testCatalog", "testCatalog"),
        ):
            if attestation.get(attestation_field) != candidate.get(candidate_field):
                raise QualificationPolicyError(
                    "candidate build attestation "
                    f"{attestation_field} does not match candidate metadata"
                )
    return attestation


def validate_candidate_identity(candidate: dict, *, strict: bool = True) -> dict:
    expected_algorithms = {
        "candidateBuildAttestationDigestAlgorithm": "sha256",
        "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
        "artifactDigestAlgorithm": "swiftvlc-tree-v1",
        "candidateAppDigestAlgorithm": "swiftvlc-tree-v1",
        "testRunnerDigestAlgorithm": "swiftvlc-tree-v1",
        "testBundleDigestAlgorithm": "swiftvlc-tree-v1",
        "baseXCTestRunDigestAlgorithm": "sha256",
        "testCatalogDigestAlgorithm": "swiftvlc-test-catalog-v1",
        "testCatalogAuthorityDigestAlgorithm": "sha256",
        "qualificationPolicyDigestAlgorithm": "swiftvlc-qualification-policy-v1",
    }
    if strict and candidate.get("formatVersion") != 2:
        raise QualificationPolicyError("candidate metadata formatVersion must be 2")
    if not isinstance(candidate.get("version"), str) or not candidate["version"]:
        raise QualificationPolicyError("candidate metadata has no version")
    if not SHA1.fullmatch(str(candidate.get("sourceCommit", ""))):
        raise QualificationPolicyError("candidate metadata has no valid sourceCommit")
    for field in (
        "candidateBuildAttestationDigest",
        "candidateRuntimeBinding",
        "releaseSourceDigest",
        "artifactDigest",
        "candidateAppDigest",
        "testRunnerDigest",
        "testBundleDigest",
        "baseXCTestRunDigest",
        "testCatalogDigest",
        "testCatalogAuthorityDigest",
        "qualificationMatrixChecksum",
        "featureManifestChecksum",
        "qualificationProfilesChecksum",
        "fixtureManifestChecksum",
        "qualificationPolicyDigest",
    ):
        if strict or field in candidate:
            if not SHA256.fullmatch(str(candidate.get(field, ""))):
                raise QualificationPolicyError(
                    f"candidate metadata has no valid {field}"
                )
    for field, expected in expected_algorithms.items():
        if strict or field in candidate:
            if candidate.get(field) != expected:
                raise QualificationPolicyError(
                    f"candidate metadata {field} must be {expected!r}"
                )
    if strict or "candidateBuildAttestation" in candidate:
        attestation = validate_candidate_build_attestation(
            candidate.get("candidateBuildAttestation"), candidate=candidate
        )
        expected_attestation_digest = hashlib.sha256(
            canonical_json_bytes(attestation)
        ).hexdigest()
        if candidate.get("candidateBuildAttestationDigest") != expected_attestation_digest:
            raise QualificationPolicyError(
                "candidate build attestation digest mismatch"
            )
    for field in (
        "candidateAppBundleIdentifier",
        "testRunnerBundleIdentifier",
    ):
        if strict or field in candidate:
            value = candidate.get(field)
            if not isinstance(value, str) or BUNDLE_IDENTIFIER.fullmatch(value) is None:
                raise QualificationPolicyError(
                    f"candidate metadata has no valid {field}"
                )
    if strict:
        candidate_bundle = candidate["candidateAppBundleIdentifier"]
        runner_bundle = candidate["testRunnerBundleIdentifier"]
        if candidate_bundle == runner_bundle or not runner_bundle.endswith(
            ".xctrunner"
        ):
            raise QualificationPolicyError(
                "candidate and UI-test runner bundle identifiers are inconsistent"
            )
    if strict:
        if candidate.get("qualificationPolicyDigest") != policy_digest():
            raise QualificationPolicyError(
                "candidate qualification policy digest mismatch"
            )
        catalog = candidate.get("testCatalog")
        if not isinstance(catalog, list) or any(
            not isinstance(identifier, str) for identifier in catalog
        ):
            raise QualificationPolicyError("candidate has no exact testCatalog")
        normalized = normalize_catalog_identifiers(catalog)
        if normalized != catalog:
            raise QualificationPolicyError("candidate testCatalog is not canonical")
        if candidate.get("testCatalogCount") != len(catalog) or not catalog:
            raise QualificationPolicyError(
                "candidate testCatalogCount mismatch or zero"
            )
        if candidate.get("testCatalogDigest") != catalog_digest(catalog):
            raise QualificationPolicyError("candidate testCatalogDigest mismatch")
        bundle_path = candidate.get("testBundleRelativePath")
        if (
            not isinstance(bundle_path, str)
            or not bundle_path
            or Path(bundle_path).is_absolute()
            or ".." in Path(bundle_path).parts
        ):
            raise QualificationPolicyError("candidate testBundleRelativePath is unsafe")
        xctestrun_name = candidate.get("baseXCTestRunName")
        if (
            not isinstance(xctestrun_name, str)
            or not xctestrun_name
            or not xctestrun_name.endswith(".xctestrun")
            or xctestrun_name != Path(xctestrun_name).name
        ):
            raise QualificationPolicyError("candidate baseXCTestRunName is unsafe")
    return candidate


def compare_identity(actual: dict, expected: dict, description: str) -> None:
    for field in CORE_IDENTITY_FIELDS:
        if field in expected and actual.get(field) != expected.get(field):
            raise QualificationPolicyError(
                f"{description} {field} mismatch: "
                f"{actual.get(field)!r} != {expected.get(field)!r}"
            )


def normalize_test_identifier(value: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise QualificationPolicyError("test identifier must be a non-empty string")
    text = unquote(value.strip())
    if "://" in text:
        parsed = urlparse(text)
        text = parsed.path or parsed.fragment
    text = text.split("?", 1)[0].strip("/")
    text = text.replace("\\", "/")
    components = [component for component in text.split("/") if component]
    if len(components) >= 3:
        components = components[-3:]
    elif len(components) == 2 and "." in components[0]:
        bundle, test_class = components[0].rsplit(".", 1)
        components = [bundle, test_class, components[1]]
    if len(components) != 3:
        raise QualificationPolicyError(f"identifier is not an XCTest leaf: {value!r}")
    components[-1] = components[-1].removesuffix("()")
    if any(not component for component in components):
        raise QualificationPolicyError(f"identifier is not an XCTest leaf: {value!r}")
    return "/".join(components)


def normalize_catalog_identifiers(values: Iterable[str]) -> list[str]:
    normalized = [normalize_test_identifier(value) for value in values]
    if len(set(normalized)) != len(normalized):
        raise QualificationPolicyError(
            "test catalog contains duplicate leaf identifiers"
        )
    return sorted(normalized)


def catalog_digest(identifiers: Sequence[str]) -> str:
    normalized = normalize_catalog_identifiers(identifiers)
    return hashlib.sha256(
        b"SwiftVLC XCTest leaf catalog v1\0" + canonical_json_bytes(normalized)
    ).hexdigest()


def _walk_json(value: object) -> Iterable[dict]:
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from _walk_json(child)
    elif isinstance(value, list):
        for child in value:
            yield from _walk_json(child)


def catalog_from_enumeration(document: dict) -> list[str]:
    errors = document.get("errors", [])
    if not isinstance(errors, list) or errors:
        raise QualificationPolicyError(
            f"XCTest enumeration reported errors: {errors!r}"
        )
    identifiers: list[str] = []
    # Xcode's flat enumeration includes disabledTests alongside enabledTests.
    # Only enabled leaves belong to the selected execution contract.
    enabled = [
        value.get("enabledTests", [])
        for value in document.get("values", [])
        if isinstance(value, dict)
    ]
    for node in _walk_json(enabled):
        identifier = node.get("identifier")
        if not isinstance(identifier, str):
            continue
        try:
            identifiers.append(normalize_test_identifier(identifier))
        except QualificationPolicyError:
            continue
    if not identifiers:
        raise QualificationPolicyError("XCTest enumeration selected zero leaf tests")
    return normalize_catalog_identifiers(identifiers)


def catalog_record(identifiers: Sequence[str]) -> dict:
    normalized = normalize_catalog_identifiers(identifiers)
    if not normalized:
        raise QualificationPolicyError("test catalog selected zero tests")
    return {
        "digestAlgorithm": "swiftvlc-test-catalog-v1",
        "digest": catalog_digest(normalized),
        "testCount": len(normalized),
        "testIdentifiers": normalized,
    }


ATTACHMENT_UUID_PATTERN = (
    r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-" r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
)


def attachment_name_matches(actual_name: object, expected_name: str) -> bool:
    if actual_name == expected_name:
        return True
    if not isinstance(actual_name, str):
        return False
    stem, separator, extension = expected_name.rpartition(".")
    if not separator or not stem or not extension:
        return False
    return (
        re.fullmatch(
            re.escape(stem)
            + r"_(?:0|[1-9][0-9]*)_"
            + ATTACHMENT_UUID_PATTERN
            + re.escape(separator + extension),
            actual_name,
        )
        is not None
    )


def _reconciled_test_identifier(
    raw_identifier: object,
    raw_url: object,
    *,
    description: str,
    identifier_field: str,
    url_field: str,
) -> str:
    """Strictly reconcile Xcode's short identifier with its canonical URL."""

    if raw_identifier is None and raw_url is None:
        raise QualificationPolicyError(
            f"{description} has no XCTest owner"
        )

    canonical_url: str | None = None
    if raw_url is not None:
        if not isinstance(raw_url, str) or not raw_url.strip():
            raise QualificationPolicyError(
                f"{description} has malformed {url_field}"
            )
        canonical_url = normalize_test_identifier(raw_url)

    canonical_identifier: str | None = None
    if raw_identifier is not None:
        if not isinstance(raw_identifier, str) or not raw_identifier.strip():
            raise QualificationPolicyError(
                f"{description} has malformed {identifier_field}"
            )
        try:
            canonical_identifier = normalize_test_identifier(raw_identifier)
        except QualificationPolicyError as error:
            short = unquote(raw_identifier.strip()).split("?", 1)[0].strip("/")
            short = short.replace("\\", "/")
            components = [component for component in short.split("/") if component]
            if len(components) != 2 or canonical_url is None:
                raise QualificationPolicyError(
                    f"{description} {identifier_field} is not canonical"
                ) from error
            components[-1] = components[-1].removesuffix("()")
            suffix = "/".join(components)
            if not all(components) or not canonical_url.endswith("/" + suffix):
                raise QualificationPolicyError(
                    f"{description} owner fields disagree"
                ) from error
            canonical_identifier = canonical_url

    canonical = canonical_identifier or canonical_url
    assert canonical is not None
    if canonical_identifier is not None and canonical_url is not None:
        if canonical_identifier != canonical_url:
            raise QualificationPolicyError(
                f"{description} owner fields disagree"
            )
    return canonical


def attachment_test_identifier(test_record: dict) -> str:
    """Return the canonical XCTest leaf that owns one manifest test record.

    Current ``xcresulttool export attachments`` manifests use a short
    ``Class/test()`` testIdentifier plus a fully-qualified testIdentifierURL.
    Older/newer formats may provide either value in fully-qualified form.  A
    short identifier is accepted only when the URL supplies the missing bundle
    and the two values agree exactly.
    """

    return _reconciled_test_identifier(
        test_record.get("testIdentifier"),
        test_record.get("testIdentifierURL"),
        description="xcresult attachment manifest test record",
        identifier_field="testIdentifier",
        url_field="testIdentifierURL",
    )


def normalize_attachment_expectations(
    expected_owners: Mapping[str, Iterable[str]],
) -> dict[str, list[str]]:
    if not isinstance(expected_owners, Mapping) or not expected_owners:
        raise QualificationPolicyError("qualification attachment set is empty")
    normalized: dict[str, list[str]] = {}
    for name, owners in expected_owners.items():
        if (
            not isinstance(name, str)
            or Path(name).name != name
            or not name.startswith("qualification-")
            or not name.endswith(".json")
        ):
            raise QualificationPolicyError(
                f"qualification attachment name is unsafe: {name!r}"
            )
        if isinstance(owners, (str, bytes)):
            raise QualificationPolicyError(
                f"qualification attachment {name!r} owner set is malformed"
            )
        try:
            canonical = normalize_catalog_identifiers(owners)
        except (TypeError, QualificationPolicyError) as error:
            raise QualificationPolicyError(
                f"qualification attachment {name!r} owner set is malformed"
            ) from error
        if not canonical:
            raise QualificationPolicyError(
                f"qualification attachment {name!r} has no authorized XCTest owner"
            )
        normalized[name] = canonical
    return normalized


def exported_qualification_attachments(
    export_root: Path, expected_owners: Mapping[str, Iterable[str]]
) -> dict[str, tuple[Path, dict, str]]:
    expected = normalize_attachment_expectations(expected_owners)
    reject_tree_symlinks(export_root, "xcresult attachment export")
    manifest_path = safe_relative_file(
        export_root, "manifest.json", "xcresult attachment manifest"
    )
    manifest = load_json(
        manifest_path, "xcresult attachment manifest", object_required=False
    )
    if not isinstance(manifest, list):
        raise QualificationPolicyError("xcresult attachment manifest must be an array")
    found: dict[str, list[tuple[Path, dict, str]]] = {name: [] for name in expected}
    for test in manifest:
        if not isinstance(test, dict):
            raise QualificationPolicyError(
                "xcresult attachment manifest contains a malformed test record"
            )
        attachments = test.get("attachments", [])
        if not isinstance(attachments, list):
            raise QualificationPolicyError(
                "xcresult attachment manifest contains malformed attachments"
            )
        for attachment in attachments:
            if not isinstance(attachment, dict):
                raise QualificationPolicyError(
                    "xcresult attachment manifest contains a malformed attachment"
                )
            suggested = attachment.get("suggestedHumanReadableName")
            matching = [
                name for name in expected if attachment_name_matches(suggested, name)
            ]
            if isinstance(suggested, str) and suggested.startswith("qualification-"):
                if len(matching) != 1:
                    raise QualificationPolicyError(
                        f"xcresult contains unauthorized qualification attachment {suggested!r}"
                    )
            if not matching:
                continue
            owner = attachment_test_identifier(test)
            attachment_name = matching[0]
            if owner not in expected[attachment_name]:
                raise QualificationPolicyError(
                    f"xcresult attachment {attachment_name!r} has unauthorized "
                    f"XCTest owner {owner!r}"
                )
            exported = attachment.get("exportedFileName")
            path = safe_relative_file(
                export_root,
                exported,
                f"xcresult attachment {attachment_name!r}",
            )
            try:
                payload = loads_json(
                    path.read_text(encoding="utf-8"),
                    f"xcresult attachment {attachment_name!r}",
                )
            except (OSError, UnicodeError) as error:
                raise QualificationPolicyError(
                    f"xcresult attachment {attachment_name!r} is not readable UTF-8"
                ) from error
            if not isinstance(payload, dict):
                raise QualificationPolicyError(
                    f"xcresult attachment {attachment_name!r} must be a JSON object"
                )
            found[attachment_name].append((path, payload, owner))
    invalid_counts = {
        name: len(matches) for name, matches in found.items() if len(matches) != 1
    }
    if invalid_counts:
        raise QualificationPolicyError(
            f"xcresult qualification attachment counts mismatch: {invalid_counts!r}"
        )
    return {name: matches[0] for name, matches in found.items()}


def inspect_xcresult_qualification_attachments(
    xcresult: Path, expected_owners: Mapping[str, Iterable[str]]
) -> dict[str, dict]:
    with tempfile.TemporaryDirectory(prefix="swiftvlc-xcresult-attachments-") as value:
        output = Path(value) / "export"
        try:
            result = subprocess.run(
                [
                    "xcrun",
                    "xcresulttool",
                    "export",
                    "attachments",
                    "--path",
                    str(xcresult),
                    "--output-path",
                    str(output),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
        except OSError as error:
            raise QualificationPolicyError(
                f"cannot export xcresult attachments from {xcresult}: {error}"
            ) from error
        if result.returncode != 0:
            raise QualificationPolicyError(
                f"cannot export xcresult attachments from {xcresult}: "
                f"{result.stderr.strip()}"
            )
        exported = exported_qualification_attachments(output, expected_owners)
        return {
            name: {
                "payload": payload,
                "sha256": sha256_file(path),
                "sizeBytes": path.stat().st_size,
                "testIdentifier": owner,
            }
            for name, (path, payload, owner) in exported.items()
        }


def exported_cadence_semantics_probe_attachment(export_root: Path) -> dict:
    """Load the probe's one exact XCTest-owned JSON attachment export."""

    reject_tree_symlinks(export_root, "cadence semantics attachment export")
    manifest_path = safe_relative_file(
        export_root, "manifest.json", "cadence semantics attachment manifest"
    )
    manifest = load_json(
        manifest_path,
        "cadence semantics attachment manifest",
        object_required=False,
    )
    if not isinstance(manifest, list):
        raise QualificationPolicyError(
            "cadence semantics attachment manifest must be an array"
        )
    expected_stem = Path(CADENCE_SEMANTICS_PROBE_ATTACHMENT_NAME).stem
    matches: list[dict] = []
    for test in manifest:
        if not isinstance(test, dict):
            raise QualificationPolicyError(
                "cadence semantics attachment manifest has a malformed test record"
            )
        attachments = test.get("attachments", [])
        if not isinstance(attachments, list):
            raise QualificationPolicyError(
                "cadence semantics attachment manifest has malformed attachments"
            )
        for attachment in attachments:
            if not isinstance(attachment, dict):
                raise QualificationPolicyError(
                    "cadence semantics attachment manifest has a malformed attachment"
                )
            suggested = attachment.get("suggestedHumanReadableName")
            name_matches = attachment_name_matches(
                suggested, CADENCE_SEMANTICS_PROBE_ATTACHMENT_NAME
            )
            if (
                isinstance(suggested, str)
                and suggested.startswith(expected_stem)
                and not name_matches
            ):
                raise QualificationPolicyError(
                    "cadence semantics attachment name is not canonical: "
                    f"{suggested!r}"
                )
            if not name_matches:
                continue
            owner = attachment_test_identifier(test)
            if owner != CADENCE_SEMANTICS_PROBE_TEST_IDENTIFIER:
                raise QualificationPolicyError(
                    "cadence semantics attachment has unauthorized XCTest owner "
                    f"{owner!r}"
                )
            path = safe_relative_file(
                export_root,
                attachment.get("exportedFileName"),
                "cadence semantics exported attachment",
            )
            try:
                raw = path.read_bytes()
                text = raw.decode("utf-8")
            except (OSError, UnicodeError) as error:
                raise QualificationPolicyError(
                    "cadence semantics attachment is not readable UTF-8"
                ) from error
            payload = loads_json(text, "cadence semantics exported attachment")
            if not isinstance(payload, dict):
                raise QualificationPolicyError(
                    "cadence semantics attachment must be a JSON object"
                )
            matches.append(
                {
                    "path": path,
                    "payload": payload,
                    "sha256": hashlib.sha256(raw).hexdigest(),
                    "sizeBytes": len(raw),
                    "testIdentifier": owner,
                }
            )
    if len(matches) != 1:
        raise QualificationPolicyError(
            "cadence semantics attachment count mismatch: "
            f"expected 1, observed {len(matches)}"
        )
    return {
        **matches[0],
        "manifestPath": manifest_path,
        "manifestSHA256": sha256_file(manifest_path),
        "manifestSizeBytes": manifest_path.stat().st_size,
    }


def inspect_xcresult_cadence_semantics_probe_attachment(xcresult: Path) -> dict:
    """Re-export and inspect the exact probe attachment from an xcresult."""

    with tempfile.TemporaryDirectory(prefix="swiftvlc-cadence-semantics-") as value:
        output = Path(value) / "export"
        try:
            result = subprocess.run(
                [
                    "xcrun",
                    "xcresulttool",
                    "export",
                    "attachments",
                    "--path",
                    str(xcresult),
                    "--output-path",
                    str(output),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
        except OSError as error:
            raise QualificationPolicyError(
                f"cannot export cadence semantics attachment from {xcresult}: {error}"
            ) from error
        if result.returncode != 0:
            raise QualificationPolicyError(
                f"cannot export cadence semantics attachment from {xcresult}: "
                f"{result.stderr.strip()}"
            )
        exported = exported_cadence_semantics_probe_attachment(output)
        return {
            "payload": exported["payload"],
            "sha256": exported["sha256"],
            "sizeBytes": exported["sizeBytes"],
            "testIdentifier": exported["testIdentifier"],
        }


def xcresult_test_document(path: Path) -> dict:
    try:
        result = subprocess.run(
            [
                "xcrun",
                "xcresulttool",
                "get",
                "test-results",
                "tests",
                "--path",
                str(path),
                "--compact",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        detail = getattr(error, "stderr", "") or str(error)
        raise QualificationPolicyError(
            f"cannot inspect xcresult {path}: {detail.strip()}"
        ) from error
    value = loads_json(result.stdout, f"xcresult {path}")
    if not isinstance(value, dict):
        raise QualificationPolicyError("xcresult test document must be an object")
    return value


def executed_catalog_from_xcresult(document: dict) -> tuple[list[str], list[str], bool]:
    identifiers, results, has_failure_message = _test_case_observations(document)
    if not identifiers:
        raise QualificationPolicyError("xcresult executed zero test cases")
    return sorted(identifiers), results, has_failure_message


def _test_case_observations(document: dict) -> tuple[list[str], list[str], bool]:
    identifiers: list[str] = []
    results: list[str] = []
    has_failure_message = False
    for node in _walk_json(document.get("testNodes", [])):
        node_type = node.get("nodeType")
        if node_type == "Failure Message":
            has_failure_message = True
        if node_type != "Test Case":
            continue
        raw_identifier = node.get("nodeIdentifier")
        raw_url = node.get("nodeIdentifierURL")
        if raw_identifier is None and raw_url is None:
            raw_identifier = node.get("name")
        identifier = _reconciled_test_identifier(
            raw_identifier,
            raw_url,
            description="xcresult Test Case",
            identifier_field="nodeIdentifier",
            url_field="nodeIdentifierURL",
        )
        identifiers.append(identifier)
        result = node.get("result")
        if not isinstance(result, str):
            raise QualificationPolicyError(
                f"xcresult Test Case {identifier!r} has no result"
            )
        results.append(result)
    if len(set(identifiers)) != len(identifiers):
        raise QualificationPolicyError(
            "xcresult contains duplicate Test Case identities"
        )
    return sorted(identifiers), results, has_failure_message


def verify_xcresult_execution(xcresult: Path, expected_catalog: dict) -> dict:
    expected = expected_catalog.get("testIdentifiers")
    if not isinstance(expected, list):
        raise QualificationPolicyError("expected catalog has no testIdentifiers")
    expected_record = catalog_record(expected)
    if expected_catalog != expected_record:
        raise QualificationPolicyError("expected catalog record is not canonical")
    document = xcresult_test_document(xcresult)
    structured_signals = product_failure_signals(
        json.dumps(document, ensure_ascii=False, sort_keys=True)
    )
    if structured_signals:
        raise QualificationPolicyError(
            "xcresult contains immutable product-failure signals: "
            f"{structured_signals!r}"
        )
    executed, results, has_failure_message = executed_catalog_from_xcresult(document)
    if executed != expected_record["testIdentifiers"]:
        missing = sorted(set(expected_record["testIdentifiers"]) - set(executed))
        extra = sorted(set(executed) - set(expected_record["testIdentifiers"]))
        raise QualificationPolicyError(
            f"executed XCTest identity mismatch; missing={missing}, extra={extra}"
        )
    if has_failure_message or any(result != "Passed" for result in results):
        raise QualificationPolicyError(f"selected XCTest did not all pass: {results!r}")
    executed_record = catalog_record(executed)
    return {
        "expected": expected_record,
        "executed": executed_record,
        "identityAndCountMatch": True,
        "allPassed": True,
    }


INFRASTRUCTURE_RETRY_PATTERNS = (
    re.compile(r"LaunchServicesDataMismatch", re.I),
    re.compile(r"LaunchServices GUID and sequence number do not match", re.I),
    re.compile(r"operation never finished bootstrapping", re.I),
    re.compile(r"signal kill before establishing connection", re.I),
    re.compile(r"Failed to resume target process", re.I),
    re.compile(r"process may have already terminated", re.I),
    re.compile(r"reason:\s*Busy", re.I),
    re.compile(r"is installing or uninstalling", re.I),
)
PRODUCT_FAILURE_PATTERNS = (
    re.compile(r"XCTAssert", re.I),
    re.compile(r"Assertion Failure", re.I),
    re.compile(r"Test Case .+ failed", re.I),
    re.compile(r"\*\* TEST (?:EXECUTE )?FAILED \*\*", re.I),
    re.compile(r"\bfatal\b", re.I),
    re.compile(r"\bcrash(?:ed|ing)?\b", re.I),
    re.compile(r"\babort(?:ed|ing)?\b", re.I),
    re.compile(r"\bSIG(?:ABRT|SEGV|BUS|ILL|TRAP|KILL|TERM)\b", re.I),
    re.compile(r"(?:address|thread|undefined\s*behavior|memory|leak)sanitizer", re.I),
    re.compile(r"\b(?:ASan|TSan|UBSan|MSan)\b", re.I),
    re.compile(r"heap corruption|memory corruption|use-after-free", re.I),
    re.compile(r"stack-buffer-overflow|heap-buffer-overflow", re.I),
    re.compile(r"double[- ]free|data race", re.I),
    re.compile(r"EXC_(?:BAD_ACCESS|CRASH|BAD_INSTRUCTION|GUARD)", re.I),
    re.compile(r"Swift runtime failure", re.I),
    re.compile(r"\b(?:assertion|precondition) (?:failed|failure)\b", re.I),
    re.compile(r"\buncaught (?:exception|error)\b", re.I),
    re.compile(
        r"test (?:runner|process|host).*(?:exited|terminated|abort|signal)", re.I
    ),
)


def product_failure_signals(text: str) -> list[str]:
    """Return immutable fail-closed product-failure signatures.

    There are deliberately no substring/module exceptions. A future harmless
    collision must be represented as an explicit, reviewed structured rule.
    """

    return sorted(
        {
            pattern.pattern
            for pattern in PRODUCT_FAILURE_PATTERNS
            if pattern.search(text)
        }
    )


def classify_retry(
    xcresult: Path | None, log_text: str, expected_catalog: dict | None = None
) -> dict:
    expected_identifiers: set[str] = set()
    catalog_valid = False
    if expected_catalog is not None:
        try:
            canonical = catalog_record(expected_catalog.get("testIdentifiers", []))
            catalog_valid = expected_catalog == canonical
            expected_identifiers = set(canonical["testIdentifiers"])
        except QualificationPolicyError:
            pass
    product_matches = [
        pattern.pattern
        for pattern in PRODUCT_FAILURE_PATTERNS
        if pattern.search(log_text)
    ]
    structured_bundle_present = bool(xcresult and xcresult.is_dir())
    structured_readable = False
    executed_identifiers: list[str] = []
    results: list[str] = []
    has_failure_message = False
    structured_text = ""
    if structured_bundle_present:
        try:
            document = xcresult_test_document(xcresult)  # type: ignore[arg-type]
            structured_readable = True
            executed_identifiers, results, has_failure_message = (
                _test_case_observations(document)
            )
            structured_text = json.dumps(document, ensure_ascii=False, sort_keys=True)
        except QualificationPolicyError:
            structured_readable = False
    product_matches.extend(
        pattern.pattern
        for pattern in PRODUCT_FAILURE_PATTERNS
        if structured_text and pattern.search(structured_text)
    )
    product_matches = sorted(set(product_matches))
    intended_began = bool(expected_identifiers.intersection(executed_identifiers))
    # Any concrete Test Case means the test lifecycle reached product code. A
    # mismatched case is also terminal selection/provenance state, not an
    # infrastructure incident that a retry may conceal.
    any_test_began = bool(executed_identifiers)
    nonpassing = any(result != "Passed" for result in results)
    product_failure = bool(product_matches) or any_test_began or nonpassing
    infra_matches = [
        pattern.pattern
        for pattern in INFRASTRUCTURE_RETRY_PATTERNS
        if pattern.search(log_text)
    ]
    lifecycle_proves_no_test_began = (
        catalog_valid and structured_readable and not any_test_began
    )
    retryable = (
        bool(infra_matches) and lifecycle_proves_no_test_began and not product_failure
    )
    return {
        "classification": (
            "infrastructureRetryable"
            if retryable
            else "productFailure" if product_failure else "notRetryable"
        ),
        "retryable": retryable,
        "structuredResultBundlePresent": structured_bundle_present,
        "structuredResultReadable": structured_readable,
        "expectedCatalogValid": catalog_valid,
        "lifecycleProvesNoIntendedTestBegan": lifecycle_proves_no_test_began,
        "intendedTestBegan": intended_began,
        "executedTestCount": len(executed_identifiers),
        "executedTestIdentifiers": executed_identifiers,
        "testResults": results,
        "structuredFailureMessageObserved": has_failure_message,
        "productFailureObserved": product_failure,
        "productFailureSignals": product_matches,
        "infrastructureSignals": infra_matches,
    }


def validate_test_execution(value: object) -> dict:
    if not isinstance(value, dict):
        raise QualificationPolicyError("evidence has no testExecution object")
    if (
        value.get("identityAndCountMatch") is not True
        or value.get("allPassed") is not True
    ):
        raise QualificationPolicyError(
            "testExecution is not an exact passing execution"
        )
    expected = value.get("expected")
    executed = value.get("executed")
    if not isinstance(expected, dict) or not isinstance(executed, dict):
        raise QualificationPolicyError("testExecution catalogs are malformed")
    expected_record = catalog_record(expected.get("testIdentifiers", []))
    executed_record = catalog_record(executed.get("testIdentifiers", []))
    if (
        expected != expected_record
        or executed != executed_record
        or expected != executed
    ):
        raise QualificationPolicyError(
            "testExecution expected/executed catalogs differ"
        )
    return value


RETRY_CLASSIFICATION_FIELDS = (
    "classification",
    "retryable",
    "structuredResultBundlePresent",
    "structuredResultReadable",
    "expectedCatalogValid",
    "lifecycleProvesNoIntendedTestBegan",
    "intendedTestBegan",
    "executedTestCount",
    "executedTestIdentifiers",
    "testResults",
    "structuredFailureMessageObserved",
    "productFailureObserved",
    "productFailureSignals",
    "infrastructureSignals",
)


def _regular_file_binding(root: Path, relative: object, description: str) -> dict:
    path = safe_relative_file(root, relative, description)
    return {
        "artifactType": "regular-file",
        "digestAlgorithm": "sha256",
        "digest": sha256_file(path),
        "sizeBytes": path.stat().st_size,
    }


def _directory_binding(root: Path, relative: object, description: str) -> dict:
    path = safe_relative_directory(root, relative, description)
    reject_tree_symlinks(path, description)
    return {
        "artifactType": "xcresult-directory",
        "digestAlgorithm": "swiftvlc-tree-v1",
        "digest": tree_digest(path),
        "sizeBytes": tree_size_bytes(path),
    }


def bind_attempt_artifacts(value: object, artifact_root: Path) -> list[dict]:
    """Add immutable content/type bindings without changing attempt outcomes."""

    if not isinstance(value, list) or not value:
        raise QualificationPolicyError("runner scenario has no attempt history")
    bound: list[dict] = []
    for index, item in enumerate(value, 1):
        if not isinstance(item, dict) or item.get("attempt") != index:
            raise QualificationPolicyError("runner attempt history is not sequential")
        attempt = dict(item)
        log = _regular_file_binding(
            artifact_root,
            attempt.get("logArtifact"),
            f"runner attempt {index} log",
        )
        attempt.update(
            {
                "logArtifactType": log["artifactType"],
                "logDigestAlgorithm": log["digestAlgorithm"],
                "logDigest": log["digest"],
                "logSizeBytes": log["sizeBytes"],
            }
        )
        xcresult_relative = attempt.get("xcresultArtifact")
        try:
            xcresult = _directory_binding(
                artifact_root,
                xcresult_relative,
                f"runner attempt {index} xcresult",
            )
        except QualificationPolicyError:
            lexical = Path(str(xcresult_relative))
            if (
                not isinstance(xcresult_relative, str)
                or not xcresult_relative
                or lexical.is_absolute()
                or ".." in lexical.parts
                or (artifact_root / lexical).exists()
                or (artifact_root / lexical).is_symlink()
            ):
                raise
            attempt.update(
                {
                    "xcresultArtifactType": "missing",
                    "xcresultDigestAlgorithm": None,
                    "xcresultDigest": None,
                    "xcresultSizeBytes": None,
                }
            )
        else:
            attempt.update(
                {
                    "xcresultArtifactType": xcresult["artifactType"],
                    "xcresultDigestAlgorithm": xcresult["digestAlgorithm"],
                    "xcresultDigest": xcresult["digest"],
                    "xcresultSizeBytes": xcresult["sizeBytes"],
                }
            )
        bound.append(attempt)
    return bound


def _validate_bound_attempt_artifact(
    attempt: dict,
    index: int,
    artifact_root: Path,
) -> tuple[Path, Path | None]:
    log = safe_relative_file(
        artifact_root,
        attempt.get("logArtifact"),
        f"runner attempt {index} log",
    )
    if (
        attempt.get("logArtifactType") != "regular-file"
        or attempt.get("logDigestAlgorithm") != "sha256"
        or attempt.get("logDigest") != sha256_file(log)
        or attempt.get("logSizeBytes") != log.stat().st_size
    ):
        raise QualificationPolicyError(f"runner attempt {index} log binding mismatch")
    if attempt.get("xcresultArtifactType") == "missing":
        relative = attempt.get("xcresultArtifact")
        candidate = Path(str(relative))
        if (
            not isinstance(relative, str)
            or not relative
            or candidate.is_absolute()
            or ".." in candidate.parts
            or (artifact_root / candidate).exists()
            or (artifact_root / candidate).is_symlink()
            or attempt.get("xcresultDigestAlgorithm") is not None
            or attempt.get("xcresultDigest") is not None
            or attempt.get("xcresultSizeBytes") is not None
        ):
            raise QualificationPolicyError(
                f"runner attempt {index} missing xcresult binding mismatch"
            )
        return log, None
    xcresult = safe_relative_directory(
        artifact_root,
        attempt.get("xcresultArtifact"),
        f"runner attempt {index} xcresult",
    )
    reject_tree_symlinks(xcresult, f"runner attempt {index} xcresult")
    if (
        attempt.get("xcresultArtifactType") != "xcresult-directory"
        or attempt.get("xcresultDigestAlgorithm") != "swiftvlc-tree-v1"
        or attempt.get("xcresultDigest") != tree_digest(xcresult)
        or attempt.get("xcresultSizeBytes") != tree_size_bytes(xcresult)
    ):
        raise QualificationPolicyError(
            f"runner attempt {index} xcresult binding mismatch"
        )
    return log, xcresult


def validate_attempt_history(
    value: object,
    *,
    runner_result: object,
    final_execution: object,
    expected_catalog: dict | None = None,
    artifact_root: Path | None = None,
    artifact_scope: object = None,
    require_artifacts: bool = False,
) -> list[dict]:
    if not isinstance(value, list) or not value:
        raise QualificationPolicyError("runner scenario has no attempt history")
    if artifact_root is not None:
        scope = safe_relative_directory(
            artifact_root, artifact_scope, "runner attempt artifact root"
        )
        reject_tree_symlinks(scope, "runner attempt artifact root")
        expected_entries: set[str] = set()
        for index, attempt in enumerate(value, 1):
            if not isinstance(attempt, dict):
                continue
            expected_log = f"{Path(str(artifact_scope)).as_posix()}/attempt-{index}.log"
            expected_xcresult = (
                f"{Path(str(artifact_scope)).as_posix()}/attempt-{index}.xcresult"
            )
            if attempt.get("logArtifact") != expected_log:
                raise QualificationPolicyError(
                    f"runner attempt {index} log path/ordinal mismatch"
                )
            if attempt.get("xcresultArtifact") != expected_xcresult:
                raise QualificationPolicyError(
                    f"runner attempt {index} xcresult path/ordinal mismatch"
                )
            expected_entries.add(f"attempt-{index}.log")
            if (artifact_root / expected_xcresult).exists():
                expected_entries.add(f"attempt-{index}.xcresult")
        actual_entries = {path.name for path in scope.iterdir()}
        if actual_entries != expected_entries:
            raise QualificationPolicyError(
                "runner attempt artifact inventory mismatch; "
                f"missing={sorted(expected_entries - actual_entries)!r}, "
                f"extra={sorted(actual_entries - expected_entries)!r}"
            )
    elif require_artifacts:
        raise QualificationPolicyError("runner attempt artifact root was not supplied")
    for index, attempt in enumerate(value, 1):
        if not isinstance(attempt, dict) or attempt.get("attempt") != index:
            raise QualificationPolicyError("runner attempt history is not sequential")
        for artifact_field in ("logArtifact", "xcresultArtifact"):
            artifact = attempt.get(artifact_field)
            if (
                not isinstance(artifact, str)
                or not artifact
                or Path(artifact).is_absolute()
                or ".." in Path(artifact).parts
            ):
                raise QualificationPolicyError(
                    f"runner attempt {index} has unsafe {artifact_field}"
                )
        log_path: Path | None = None
        xcresult_path: Path | None = None
        if artifact_root is not None:
            log_path, xcresult_path = _validate_bound_attempt_artifact(
                attempt, index, artifact_root
            )
        classification = attempt.get("classification")
        if index < len(value):
            if (
                classification != "infrastructureRetryable"
                or attempt.get("retryable") is not True
                or attempt.get("structuredResultReadable") is not True
                or attempt.get("lifecycleProvesNoIntendedTestBegan") is not True
                or attempt.get("intendedTestBegan") is not False
                or attempt.get("productFailureObserved") is not False
            ):
                raise QualificationPolicyError(
                    "a later attempt follows a failure without structured "
                    "infrastructure-only/no-test-began proof"
                )
        elif runner_result == "pass":
            if (
                classification != "passed"
                or attempt.get("retryable") is not False
                or attempt.get("xcodebuildExitCode") != 0
                or attempt.get("intendedTestBegan") is not True
            ):
                raise QualificationPolicyError(
                    "passing runner scenario does not end in an exact passing attempt"
                )
            attempt_execution = validate_test_execution(attempt.get("testExecution"))
            if attempt_execution != final_execution:
                raise QualificationPolicyError(
                    "passing attempt execution differs from runner execution"
                )
        if artifact_root is not None:
            assert log_path is not None
            try:
                log_text = log_path.read_text(encoding="utf-8")
            except (OSError, UnicodeError) as error:
                raise QualificationPolicyError(
                    f"runner attempt {index} log is not readable UTF-8: {error}"
                ) from error
            log_product_signals = product_failure_signals(log_text)
            if classification == "passed":
                if log_product_signals:
                    raise QualificationPolicyError(
                        f"passing runner attempt {index} log contains immutable "
                        f"product-failure signals: {log_product_signals!r}"
                    )
                if xcresult_path is None:
                    raise QualificationPolicyError(
                        f"passing runner attempt {index} has no retained xcresult"
                    )
                observed_execution = verify_xcresult_execution(
                    xcresult_path,
                    expected_catalog if expected_catalog is not None else {},
                )
                if observed_execution != attempt.get("testExecution"):
                    raise QualificationPolicyError(
                        f"runner attempt {index} retained xcresult differs from execution"
                    )
            else:
                observed = classify_retry(
                    xcresult_path,
                    log_text,
                    expected_catalog,
                )
                for field in RETRY_CLASSIFICATION_FIELDS:
                    if attempt.get(field) != observed[field]:
                        raise QualificationPolicyError(
                            f"runner attempt {index} retained classification {field} mismatch"
                        )
                if index < len(value) and xcresult_path is None:
                    raise QualificationPolicyError(
                        "retry attempt has no retained readable xcresult"
                    )
    return value


def validate_cadence_semantics_probe_artifacts(
    report_root: Path,
    runner_row: dict,
    *,
    expected_version: str,
    require_proof: bool,
) -> dict:
    """Bind the report-only marker to one exact passing retained probe run."""

    if not isinstance(expected_version, str) or not expected_version:
        raise QualificationPolicyError(
            "cadence semantics proof requires an exact candidate version"
        )
    expected_runner_fields = set(CADENCE_SEMANTICS_PROBE_RUNNER_FIELDS)
    if not require_proof:
        expected_runner_fields.remove("reportOnlyEvidence")
    if not isinstance(runner_row, dict) or set(runner_row) != expected_runner_fields:
        raise QualificationPolicyError(
            "cadence semantics runner schema differs from report-only policy"
        )
    expected_catalog = catalog_record([CADENCE_SEMANTICS_PROBE_TEST_IDENTIFIER])
    execution = validate_test_execution(runner_row.get("testExecution"))
    duration = runner_row.get("durationSeconds")
    if (
        runner_row.get("scenario") != CADENCE_SEMANTICS_PROBE_SCENARIO
        or runner_row.get("result") != "pass"
        or type(runner_row.get("xcodebuildExitCode")) is not int
        or runner_row.get("xcodebuildExitCode") != 0
        or type(runner_row.get("libraryErrorCount")) is not int
        or runner_row.get("libraryErrorCount") != 0
        or runner_row.get("appLog") != "captured"
        or runner_row.get("qualificationEvidence") != "report-only"
        or isinstance(duration, bool)
        or not isinstance(duration, int)
        or duration <= 0
        or not _json_same(
            runner_row.get("expectedTestCatalog"), expected_catalog
        )
        or not _json_same(execution["expected"], expected_catalog)
        or not _json_same(execution["executed"], expected_catalog)
        or runner_row.get("attemptArtifactRoot")
        != f"{CADENCE_SEMANTICS_PROBE_SCENARIO}-attempt-artifacts"
    ):
        raise QualificationPolicyError(
            "cadence semantics runner is not one exact clean passing execution"
        )
    if require_proof:
        inventory = validate_error_inventory(
            runner_row.get("hostErrorInventory"),
            retained_base=report_root,
            require_retained=True,
            expected_test_catalog=expected_catalog,
        )
        if (
            inventory.get("scenario") != CADENCE_SEMANTICS_PROBE_SCENARIO
            or inventory.get("errorCount") != 0
        ):
            raise QualificationPolicyError(
                "cadence semantics runner contains unexpected raw diagnostics"
            )
    attempts = validate_attempt_history(
        runner_row.get("attempts"),
        runner_result="pass",
        final_execution=execution,
        expected_catalog=expected_catalog,
        artifact_root=report_root,
        artifact_scope=runner_row.get("attemptArtifactRoot"),
        require_artifacts=True,
    )
    final_attempt = attempts[-1]
    if (
        type(final_attempt.get("attempt")) is not int
        or type(final_attempt.get("xcodebuildExitCode")) is not int
        or final_attempt.get("xcodebuildExitCode") != 0
    ):
        raise QualificationPolicyError(
            "cadence semantics final attempt has non-canonical success fields"
        )
    source_xcresult = safe_relative_directory(
        report_root,
        final_attempt.get("xcresultArtifact"),
        "cadence semantics final attempt xcresult",
    )
    retained_final_relative = f"{CADENCE_SEMANTICS_PROBE_SCENARIO}.xcresult"
    retained_final = safe_relative_directory(
        report_root,
        retained_final_relative,
        "cadence semantics retained final xcresult",
    )
    reject_tree_symlinks(
        retained_final, "cadence semantics retained final xcresult"
    )
    retained_digest = tree_digest(retained_final)
    retained_size = tree_size_bytes(retained_final)
    if (
        final_attempt.get("xcresultArtifactType") != "xcresult-directory"
        or final_attempt.get("xcresultDigestAlgorithm") != "swiftvlc-tree-v1"
        or final_attempt.get("xcresultDigest") != tree_digest(source_xcresult)
        or final_attempt.get("xcresultSizeBytes") != tree_size_bytes(source_xcresult)
        or retained_digest != final_attempt.get("xcresultDigest")
        or retained_size != final_attempt.get("xcresultSizeBytes")
    ):
        raise QualificationPolicyError(
            "cadence semantics retained final xcresult differs from its passing attempt"
        )
    observed_execution = verify_xcresult_execution(retained_final, expected_catalog)
    if not _json_same(observed_execution, execution):
        raise QualificationPolicyError(
            "cadence semantics retained final xcresult execution drifted"
        )

    retained_root_relative = f"{CADENCE_SEMANTICS_PROBE_SCENARIO}-attachments"
    retained_root = safe_relative_directory(
        report_root,
        retained_root_relative,
        "cadence semantics retained attachment export",
    )
    retained_attachment = exported_cadence_semantics_probe_attachment(retained_root)
    inspected_attachment = inspect_xcresult_cadence_semantics_probe_attachment(
        retained_final
    )
    if (
        retained_attachment["testIdentifier"]
        != inspected_attachment.get("testIdentifier")
        or retained_attachment["sha256"] != inspected_attachment.get("sha256")
        or retained_attachment["sizeBytes"] != inspected_attachment.get("sizeBytes")
        or not _json_same(
            retained_attachment["payload"], inspected_attachment.get("payload")
        )
    ):
        raise QualificationPolicyError(
            "cadence semantics retained export differs from its final xcresult"
        )
    validate_cadence_semantics_probe_payload(retained_attachment["payload"])

    manifest_path = retained_attachment["manifestPath"]
    attachment_path = retained_attachment["path"]
    proof = {
        "formatVersion": 1,
        "authority": "report-only-cadence-semantics-v1",
        "version": expected_version,
        "releaseCreditEligible": False,
        "sourceAttempt": final_attempt["attempt"],
        "sourceXcresultArtifact": final_attempt["xcresultArtifact"],
        "sourceXcresultDigestAlgorithm": final_attempt["xcresultDigestAlgorithm"],
        "sourceXcresultDigest": final_attempt["xcresultDigest"],
        "sourceXcresultSizeBytes": final_attempt["xcresultSizeBytes"],
        "retainedFinalXcresultArtifact": retained_final_relative,
        "retainedFinalXcresultDigestAlgorithm": "swiftvlc-tree-v1",
        "retainedFinalXcresultDigest": retained_digest,
        "retainedFinalXcresultSizeBytes": retained_size,
        "attachmentName": CADENCE_SEMANTICS_PROBE_ATTACHMENT_NAME,
        "attachmentTestIdentifier": retained_attachment["testIdentifier"],
        "retainedAttachmentRoot": retained_root_relative,
        "manifestRelativePath": manifest_path.relative_to(
            report_root.resolve()
        ).as_posix(),
        "manifestDigestAlgorithm": "sha256",
        "manifestDigest": retained_attachment["manifestSHA256"],
        "manifestSizeBytes": retained_attachment["manifestSizeBytes"],
        "attachmentRelativePath": attachment_path.relative_to(
            report_root.resolve()
        ).as_posix(),
        "attachmentDigestAlgorithm": "sha256",
        "attachmentDigest": retained_attachment["sha256"],
        "attachmentSizeBytes": retained_attachment["sizeBytes"],
    }
    if set(proof) != CADENCE_SEMANTICS_PROBE_PROOF_FIELDS:
        raise QualificationPolicyError(
            "internal cadence semantics proof schema is incomplete"
        )
    if require_proof:
        reported_proof = runner_row.get("reportOnlyEvidence")
        if not isinstance(reported_proof, dict) or not _json_same(
            reported_proof, proof
        ):
            raise QualificationPolicyError(
                "cadence semantics report-only proof differs from retained artifacts"
            )
    return proof


def validate_report_only_cadence_report(report_path: Path, report: dict) -> dict:
    """Validate the only authorized non-release report-only report."""

    validate_report_timing(report, stable=False)
    scenarios = report.get("scenarios")
    if (
        report.get("formatVersion") != 2
        or report.get("mode") not in {"exploratory", "qualification"}
        or report.get("reportOnly") is not True
        or report.get("releaseGateSatisfied") is not False
        or report.get("releaseGateReason")
        != "exploratory cadence semantics probe cannot produce release credit"
        or report.get("result") != "pass"
        or report.get("qualificationRows") != []
        or not isinstance(scenarios, list)
        or len(scenarios) != 1
        or not isinstance(scenarios[0], dict)
    ):
        raise QualificationPolicyError(
            "cadence semantics report-only document contract failed"
        )
    validate_cadence_semantics_probe_artifacts(
        report_path.parent,
        scenarios[0],
        expected_version=report.get("version"),
        require_proof=True,
    )
    return report


def validate_ordinary_report_contract(report: dict) -> None:
    """Require the non-report-only device report's fail-closed gate marker."""

    if (
        not isinstance(report, dict)
        or report.get("reportOnly") is not False
        or report.get("releaseGateSatisfied") is not False
        or report.get("releaseGateReason") != ORDINARY_RELEASE_GATE_REASON
    ):
        raise QualificationPolicyError(
            "ordinary device report release-gate contract failed"
        )


def validate_evidence(
    evidence: dict,
    scenario: dict,
    identity: dict,
    hardware_id: str,
    *,
    stable: bool,
    retained_base: Path | None = None,
    require_retained: bool = False,
    artifact_base: Path | None = None,
    artifact_stem: str | None = None,
    require_host_artifacts: bool | None = None,
    require_endurance_series: bool = True,
) -> set[tuple[str, ...]]:
    scenario_id = scenario["id"]
    for field, expected in (
        ("scenario", scenario_id),
        ("hardware", hardware_id),
        *[(field, identity.get(field)) for field in CORE_IDENTITY_FIELDS],
    ):
        if expected is not None and evidence.get(field) != expected:
            raise QualificationPolicyError(
                f"{scenario_id} evidence {field} mismatch: "
                f"{evidence.get(field)!r} != {expected!r}"
            )
    validate_test_execution(evidence.get("testExecution"))
    duration = evidence.get("durationSeconds")
    if duration is not None:
        validate_duration(scenario_id, duration, stable=stable)
    if require_endurance_series:
        validate_endurance_evidence(evidence, scenario_id, stable=stable)
    elif scenario_id in STABLE_MINIMUM_DURATION_SECONDS:
        validate_endurance_duration_measurements(evidence, scenario_id, stable=stable)
    enforce_host_artifacts = (
        require_retained if require_host_artifacts is None else require_host_artifacts
    )
    return validate_evidence_semantics(
        evidence,
        scenario,
        retained_base=retained_base,
        require_retained=require_retained,
        artifact_base=artifact_base or retained_base,
        artifact_stem=artifact_stem,
        require_host_artifacts=enforce_host_artifacts,
        expected_probe_bundle_identifier=identity.get("testRunnerBundleIdentifier"),
    )


def validate_duration(scenario_id: str, value: object, *, stable: bool) -> float:
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
        or value <= 0
    ):
        raise QualificationPolicyError(
            f"{scenario_id} durationSeconds must be a positive finite number"
        )
    if stable:
        minimum = STABLE_MINIMUM_DURATION_SECONDS.get(scenario_id, 0)
        if value < minimum:
            raise QualificationPolicyError(
                f"{scenario_id} ran for {value:g}s, below immutable stable minimum "
                f"{minimum:g}s"
            )
    return float(value)


def validate_os_row(row: dict, hardware: dict, *, stable: bool) -> None:
    if row.get("deviceFamily") != hardware.get("deviceFamily"):
        raise QualificationPolicyError("qualification row deviceFamily mismatch")
    try:
        os_major = int(str(row.get("osVersion", "")).split(".", 1)[0])
    except ValueError:
        os_major = None
    if os_major != hardware.get("osMajor"):
        raise QualificationPolicyError("qualification row OS major mismatch")
    release_type = row.get("osReleaseType")
    if stable and release_type != "stable":
        raise QualificationPolicyError("stable qualification row uses non-stable OS")
    build = str(row.get("osBuild", ""))
    if release_type == "stable" and re.fullmatch(r"\d+[A-Z]\d{1,5}[a-z]+", build):
        raise QualificationPolicyError(
            "qualification row has conflicting stable label and seed-style OS build"
        )


_ATTACHMENT_HOST_FIELDS = {
    "hardware",
    "testExecution",
    "hostErrorInventory",
    "qualificationProducer",
    "sourceRequestProof",
    "deviceObservedDurationSeconds",
    "hostAttemptDurationSeconds",
    "deviceIdentifier",
    "progressiveServerTranscripts",
    *CORE_IDENTITY_FIELDS,
}

_AUGMENTED_ATTACHMENT_PATHS = {
    "audio-media-services-reset": {"sourceRequestProof"},
    "audio-session-ownership": {"sourceRequestProof"},
    "progressive-http-range-seek": {"progressiveServerTranscripts"},
    "adaptive-hls-soak": {"allocationProvenance.instrumentsTrace"},
    "pip-render-performance-1080p60": {
        "hostTraceRequirements",
        "metrics.gpu",
        "metrics.energy",
        "metrics.conversionCost.hostTraceStatus",
    },
    "pip-render-performance-4k60": {
        "hostTraceRequirements",
        "metrics.gpu",
        "metrics.energy",
        "metrics.conversionCost.hostTraceStatus",
    },
    "native-subtitle-matrix": {
        "hostTraceRequirements",
        "metrics.gpu",
        "metrics.cpu.hostTraceStatus",
        "metrics.colorHDRImpact.hostTraceStatus",
    },
    "timebase-vod-soak": {
        "hostTraceRequirements",
        "audioPresentationSeries.hostTraceStatus",
        "rawCapture",
    },
    "timebase-live-soak": {
        "hostTraceRequirements",
        "audioPresentationSeries.hostTraceStatus",
        "rawCapture",
    },
}

RAW_HOST_TRACE_REQUIREMENTS = {
    "pip-render-performance-1080p60": {
        "gpu": "Game Performance trace",
        "energy": "Power Profiler trace",
        "conversionCost": (
            "Time Profiler signpost interval " "PixelBufferRenderer.outputPixelBuffer"
        ),
    },
    "pip-render-performance-4k60": {
        "gpu": "Game Performance trace",
        "energy": "Power Profiler trace",
        "conversionCost": (
            "Time Profiler signpost interval " "PixelBufferRenderer.outputPixelBuffer"
        ),
    },
    "native-subtitle-matrix": {
        "cpu": "Time Profiler",
        "gpu": "Game Performance",
        "colorHDRImpact": "Metal System Trace",
    },
    "timebase-vod-soak": {"audioPresentationSeries": "Audio System Trace"},
    "timebase-live-soak": {"audioPresentationSeries": "Audio System Trace"},
}


def _attachment_payload_is_preserved(
    raw: object,
    enriched: object,
    *,
    excluded_paths: set[str],
    path: str = "",
) -> bool:
    if path in excluded_paths:
        return True
    if isinstance(raw, dict):
        if not isinstance(enriched, dict):
            return False
        for key, value in raw.items():
            child_path = f"{path}.{key}" if path else key
            if child_path in excluded_paths:
                continue
            if key not in enriched or not _attachment_payload_is_preserved(
                value,
                enriched[key],
                excluded_paths=excluded_paths,
                path=child_path,
            ):
                return False
        return True
    if isinstance(raw, list):
        return (
            isinstance(enriched, list)
            and len(raw) == len(enriched)
            and all(
                _attachment_payload_is_preserved(
                    raw_item,
                    enriched_item,
                    excluded_paths=excluded_paths,
                    path=path,
                )
                for raw_item, enriched_item in zip(raw, enriched)
            )
        )
    return _json_same(enriched, raw)


def _validate_qualification_producer(
    *,
    evidence: dict,
    row: dict,
    scenario: dict,
    output_contract: dict,
    runner_row: dict,
    report: dict,
    report_root: Path,
    retained_attachment: tuple[Path, dict, str],
    inspected_attachment: dict,
    stable: bool,
) -> None:
    scenario_id = scenario["id"]
    runner_id = runner_row["scenario"]
    producer = evidence.get("qualificationProducer")
    expected_keys = {
        "runnerScenario",
        "sourceAttempt",
        "sourceXcresultArtifact",
        "sourceXcresultDigestAlgorithm",
        "sourceXcresultDigest",
        "sourceXcresultSizeBytes",
        "attachmentName",
        "attachmentTestIdentifier",
        "retainedAttachmentRoot",
        "manifestRelativePath",
        "manifestDigestAlgorithm",
        "manifestDigest",
        "manifestSizeBytes",
        "attachmentRelativePath",
        "attachmentDigestAlgorithm",
        "attachmentDigest",
        "attachmentSizeBytes",
    }
    if not isinstance(producer, dict) or set(producer) != expected_keys:
        raise QualificationPolicyError(
            f"{scenario_id} evidence has malformed qualificationProducer"
        )
    attempts = runner_row["attempts"]
    final_attempt = attempts[-1]
    for field, expected in (
        ("runnerScenario", runner_id),
        ("sourceAttempt", final_attempt.get("attempt")),
        ("sourceXcresultArtifact", final_attempt.get("xcresultArtifact")),
        (
            "sourceXcresultDigestAlgorithm",
            final_attempt.get("xcresultDigestAlgorithm"),
        ),
        ("sourceXcresultDigest", final_attempt.get("xcresultDigest")),
        ("sourceXcresultSizeBytes", final_attempt.get("xcresultSizeBytes")),
        ("attachmentName", output_contract["attachmentName"]),
        ("retainedAttachmentRoot", f"{runner_id}-attachments"),
        ("manifestRelativePath", f"{runner_id}-attachments/manifest.json"),
    ):
        if producer.get(field) != expected:
            raise QualificationPolicyError(f"{scenario_id} producer {field} mismatch")
    authorized_attachment_owners = normalize_catalog_identifiers(
        output_contract["testIdentifiers"]
    )
    attachment_owner = producer.get("attachmentTestIdentifier")
    if attachment_owner not in authorized_attachment_owners:
        raise QualificationPolicyError(
            f"{scenario_id} producer attachment XCTest owner mismatch"
        )
    manifest_path = safe_relative_file(
        report_root,
        producer["manifestRelativePath"],
        f"{scenario_id} retained attachment manifest",
    )
    if (
        producer.get("manifestDigestAlgorithm") != "sha256"
        or producer.get("manifestDigest") != sha256_file(manifest_path)
        or producer.get("manifestSizeBytes") != manifest_path.stat().st_size
    ):
        raise QualificationPolicyError(
            f"{scenario_id} retained attachment manifest binding mismatch"
        )
    retained_path, raw_payload, retained_owner = retained_attachment
    bound_path = safe_relative_file(
        report_root,
        producer["attachmentRelativePath"],
        f"{scenario_id} retained qualification attachment",
    )
    if bound_path != retained_path:
        raise QualificationPolicyError(
            f"{scenario_id} retained qualification attachment path mismatch"
        )
    if (
        producer.get("attachmentDigestAlgorithm") != "sha256"
        or producer.get("attachmentDigest") != sha256_file(bound_path)
        or producer.get("attachmentSizeBytes") != bound_path.stat().st_size
        or producer.get("attachmentDigest") != inspected_attachment.get("sha256")
        or producer.get("attachmentSizeBytes") != inspected_attachment.get("sizeBytes")
        or attachment_owner != retained_owner
        or attachment_owner != inspected_attachment.get("testIdentifier")
        or raw_payload != inspected_attachment.get("payload")
    ):
        raise QualificationPolicyError(
            f"{scenario_id} retained/final-xcresult attachment mismatch"
        )
    semantic_raw_payload = validate_and_strip_qualification_runtime_bindings(
        raw_payload,
        expected_session_binding=report.get("orchestratorSessionBinding"),
        expected_candidate_binding=report.get("candidateRuntimeBinding"),
    )
    forged = sorted(_ATTACHMENT_HOST_FIELDS.intersection(semantic_raw_payload))
    if forged:
        raise QualificationPolicyError(
            f"{scenario_id} raw attachment forged host fields: {forged!r}"
        )
    if semantic_raw_payload.get("scenario") != scenario_id:
        raise QualificationPolicyError(
            f"{scenario_id} raw attachment scenario mismatch"
        )
    expected_trace_requirements = RAW_HOST_TRACE_REQUIREMENTS.get(scenario_id)
    if expected_trace_requirements is not None and not _json_same(
        semantic_raw_payload.get("hostTraceRequirements"), expected_trace_requirements
    ):
        raise QualificationPolicyError(
            f"{scenario_id} raw host-trace requirements differ from policy"
        )
    if scenario_id in {"timebase-vod-soak", "timebase-live-soak"}:
        raw_reference = semantic_raw_payload.get("rawCapture")
        retained_raw = evidence.get("rawCapture")
        mode = "vod" if scenario_id == "timebase-vod-soak" else "live"
        expected_name_pattern = re.compile(
            rf"swiftvlc-timebase-[A-Za-z0-9-]+-{mode}-"
            rf"{producer.get('sourceAttempt')}-{mode}\.jsonl"
        )
        if (
            not isinstance(raw_reference, dict)
            or set(raw_reference) != {"status", "fileName", "sampleIntervalSeconds"}
            or raw_reference.get("status") != "required-host-augmentation"
            or raw_reference.get("sampleIntervalSeconds") != 1
            or not isinstance(retained_raw, dict)
            or Path(str(retained_raw.get("runArtifact", ""))).name
            != raw_reference.get("fileName")
            or not isinstance(raw_reference.get("fileName"), str)
            or not expected_name_pattern.fullmatch(raw_reference["fileName"])
        ):
            raise QualificationPolicyError(
                f"{scenario_id} retained raw capture differs from device reference"
            )
    if row.get("runnerScenario") != runner_id:
        raise QualificationPolicyError(f"{scenario_id} row producer runner mismatch")
    report_device = report.get("device")
    expected_device_identifier = (
        report_device.get("udid") if isinstance(report_device, dict) else None
    )
    if (
        not isinstance(expected_device_identifier, str)
        or not expected_device_identifier
        or evidence.get("deviceIdentifier") != expected_device_identifier
    ):
        raise QualificationPolicyError(
            f"{scenario_id} evidence device identifier differs from report target"
        )
    if evidence.get("testExecution") != runner_row.get("testExecution"):
        raise QualificationPolicyError(
            f"{scenario_id} evidence execution differs from producing runner"
        )
    endurance = scenario_id in STABLE_MINIMUM_DURATION_SECONDS
    if endurance:
        raw_duration = semantic_raw_payload.get("durationSeconds")
        if (
            evidence.get("durationSeconds") != raw_duration
            or evidence.get("deviceObservedDurationSeconds") != raw_duration
            or evidence.get("hostAttemptDurationSeconds")
            != runner_row.get("durationSeconds")
            or row.get("durationSeconds") != raw_duration
        ):
            raise QualificationPolicyError(
                f"{scenario_id} device/host duration producer binding mismatch"
            )
        validate_endurance_duration_measurements(evidence, scenario_id, stable=stable)
    elif evidence.get("durationSeconds") != runner_row.get(
        "durationSeconds"
    ) or row.get("durationSeconds") != runner_row.get("durationSeconds"):
        raise QualificationPolicyError(
            f"{scenario_id} duration differs from producing runner"
        )
    if evidence.get("hostErrorInventory") != runner_row.get("hostErrorInventory"):
        raise QualificationPolicyError(
            f"{scenario_id} raw error inventory differs from producing runner"
        )
    reconstructed = {
        **semantic_raw_payload,
        **{field: report[field] for field in CORE_IDENTITY_FIELDS},
        "hardware": row["hardware"],
        "deviceIdentifier": expected_device_identifier,
        "testExecution": runner_row["testExecution"],
        "hostErrorInventory": runner_row["hostErrorInventory"],
        "qualificationProducer": producer,
        **(
            {"sourceRequestProof": evidence.get("sourceRequestProof")}
            if scenario_id in {"audio-media-services-reset", "audio-session-ownership"}
            else {}
        ),
        **(
            {
                "deviceObservedDurationSeconds": semantic_raw_payload.get(
                    "durationSeconds"
                ),
                "hostAttemptDurationSeconds": runner_row.get("durationSeconds"),
            }
            if endurance
            else {"durationSeconds": runner_row.get("durationSeconds")}
        ),
    }
    validate_evidence(
        reconstructed,
        scenario,
        report,
        row["hardware"],
        stable=stable,
        retained_base=report_root,
        require_retained=True,
        require_host_artifacts=False,
        require_endurance_series=False,
    )
    excluded = set(_AUGMENTED_ATTACHMENT_PATHS.get(scenario_id, set()))
    if not _attachment_payload_is_preserved(
        semantic_raw_payload, evidence, excluded_paths=excluded
    ):
        raise QualificationPolicyError(
            f"{scenario_id} enriched evidence contradicts its xcresult attachment"
        )


def runner_record_summary(
    runner_row: dict, hardware_id: str, source_report_path: str
) -> dict:
    attempts = runner_row.get("attempts")
    inventory = runner_row.get("hostErrorInventory")
    return {
        "scenario": runner_row.get("scenario"),
        "hardware": hardware_id,
        "result": runner_row.get("result"),
        "xcodebuildExitCode": runner_row.get("xcodebuildExitCode"),
        "libraryErrorCount": runner_row.get("libraryErrorCount"),
        "appLog": runner_row.get("appLog"),
        "qualificationEvidence": runner_row.get("qualificationEvidence"),
        "durationSeconds": runner_row.get("durationSeconds"),
        "expectedTestCatalog": runner_row.get("expectedTestCatalog"),
        "testExecution": runner_row.get("testExecution"),
        "attemptCount": len(attempts) if isinstance(attempts, list) else None,
        "attemptHistoryDigestAlgorithm": "sha256",
        "attemptHistoryDigest": hashlib.sha256(
            canonical_json_bytes(attempts)
        ).hexdigest(),
        "hostErrorInventoryDigest": (
            inventory.get("inventoryDigest") if isinstance(inventory, dict) else None
        ),
        "sourceReport": source_report_path,
    }


def required_release_runner_runs(matrix: dict) -> set[tuple[str, str]]:
    required_hardware = {hardware for _, hardware in required_rows(matrix)}
    return {
        (runner, hardware)
        for hardware in required_hardware
        for runner in REQUIRED_RELEASE_RUNNER_SCENARIOS
        if runner not in IPHONE_CURRENT_ONLY_RUNNER_SCENARIOS
        or hardware == "iphone-current"
    }


def validate_report(
    report_path: Path,
    matrix: dict,
    *,
    candidate: dict | None = None,
    require_complete: bool = False,
    stable_required: bool = False,
    strict_provenance: bool = True,
) -> dict:
    report = load_json(report_path, "device report")
    validate_ordinary_report_contract(report)
    scenarios, hardware = validate_matrix(matrix)
    release_matrix = is_release_matrix(matrix)
    if strict_provenance and release_matrix:
        validate_release_matrix_contract(matrix)
    if strict_provenance:
        validate_report_device_snapshot(report_path, report)
    runner_contracts: dict[str, dict] = {}
    output_contracts: dict[str, tuple[dict, dict]] = {}
    if strict_provenance:
        runner_contracts, output_contracts = validate_runner_contracts(
            matrix, scenarios
        )
    if candidate is not None:
        validate_candidate_identity(candidate, strict=strict_provenance)
        compare_identity(report, candidate, f"report {report_path}")
    elif strict_provenance:
        validate_candidate_identity(report, strict=True)
    if strict_provenance:
        candidate_catalog = report.get("testCatalog")
        if not isinstance(candidate_catalog, list):
            raise QualificationPolicyError("report has no candidate XCTest catalog")
        validate_release_catalog_partition(matrix, candidate_catalog)
    stable = report.get("mode") == "qualification"
    if strict_provenance:
        validate_report_timing(report, stable=stable)
    if stable_required and (
        not stable or report.get("qualificationEligibleEnvironment") is not True
    ):
        raise QualificationPolicyError("report is not from a qualifying environment")
    if strict_provenance:
        effective_hardware, exploratory_evidence_hardware = report_hardware_context(
            report, hardware
        )
        report_device = report["device"]
    else:
        effective_hardware = set(hardware)
        exploratory_evidence_hardware = ""
        report_device = {}

    runner_rows = report.get("scenarios")
    if not isinstance(runner_rows, list) or not runner_rows:
        raise QualificationPolicyError("report has no executed runner scenarios")
    runner_ids: set[str] = set()
    runner_rows_by_id: dict[str, dict] = {}
    runner_xcresults: dict[str, Path] = {}
    for index, runner_row in enumerate(runner_rows):
        if not isinstance(runner_row, dict):
            raise QualificationPolicyError(f"runner scenario {index} is not an object")
        runner_id = runner_row.get("scenario")
        if not isinstance(runner_id, str) or not ID.fullmatch(runner_id):
            raise QualificationPolicyError(f"runner scenario {index} has invalid id")
        if runner_id in runner_ids:
            raise QualificationPolicyError(f"duplicate runner scenario {runner_id!r}")
        runner_ids.add(runner_id)
        runner_rows_by_id[runner_id] = runner_row
        if strict_provenance and runner_id not in runner_contracts:
            raise QualificationPolicyError(
                f"runner scenario {runner_id!r} has no matrix-owned contract"
            )
        if (
            strict_provenance
            and runner_row.get("attemptArtifactRoot")
            != f"{runner_id}-attempt-artifacts"
        ):
            raise QualificationPolicyError(
                f"runner scenario {runner_id} attempt artifact root mismatch"
            )
        validate_duration(runner_id, runner_row.get("durationSeconds"), stable=False)
        expected_catalog = runner_row.get("expectedTestCatalog")
        if not isinstance(expected_catalog, dict):
            raise QualificationPolicyError(
                f"runner scenario {runner_id} has no expected test catalog"
            )
        canonical_expected = catalog_record(expected_catalog.get("testIdentifiers", []))
        if expected_catalog != canonical_expected:
            raise QualificationPolicyError(
                f"runner scenario {runner_id} expected catalog is not canonical"
            )
        runner_result = runner_row.get("result")
        if runner_result not in {"pass", "fail"}:
            raise QualificationPolicyError(
                f"runner scenario {runner_id} has invalid result"
            )
        reported_exit_code = runner_row.get("xcodebuildExitCode")
        if type(reported_exit_code) is not int:
            raise QualificationPolicyError(
                f"runner scenario {runner_id} has non-integer xcodebuild exit code"
            )
        validated_attempts: list[dict] | None = None
        if runner_result == "pass":
            if reported_exit_code != 0:
                raise QualificationPolicyError(
                    f"passing runner scenario {runner_id} has nonzero xcodebuild exit code"
                )
            execution = validate_test_execution(runner_row.get("testExecution"))
            if execution["expected"] != canonical_expected:
                raise QualificationPolicyError(
                    f"runner scenario {runner_id} execution differs from preflight"
                )
            if strict_provenance:
                validated_attempts = validate_attempt_history(
                    runner_row.get("attempts"),
                    runner_result="pass",
                    final_execution=execution,
                    expected_catalog=canonical_expected,
                    artifact_root=report_path.parent,
                    artifact_scope=runner_row.get("attemptArtifactRoot"),
                    require_artifacts=True,
                )
                final_xcresult = safe_relative_directory(
                    report_path.parent,
                    runner_row["attempts"][-1].get("xcresultArtifact"),
                    f"runner scenario {runner_id} final xcresult",
                )
                runner_xcresults[runner_id] = final_xcresult
        elif report.get("result") == "pass":
            raise QualificationPolicyError(
                f"passing report contains failed runner scenario {runner_id}"
            )
        elif strict_provenance:
            validated_attempts = validate_attempt_history(
                runner_row.get("attempts"),
                runner_result=runner_row.get("result"),
                final_execution=runner_row.get("testExecution"),
                expected_catalog=canonical_expected,
                artifact_root=report_path.parent,
                artifact_scope=runner_row.get("attemptArtifactRoot"),
                require_artifacts=True,
            )
        if strict_provenance:
            assert validated_attempts is not None
            final_attempt_exit_code = validated_attempts[-1].get(
                "xcodebuildExitCode"
            )
            if type(final_attempt_exit_code) is not int:
                raise QualificationPolicyError(
                    f"runner scenario {runner_id} final attempt has non-integer "
                    "xcodebuild exit code"
                )
            if reported_exit_code != final_attempt_exit_code:
                raise QualificationPolicyError(
                    f"runner scenario {runner_id} xcodebuild exit code differs "
                    "from its final retained attempt"
                )
            inventory_value = runner_row.get("hostErrorInventory")
            if runner_row.get("appLog") == "captured":
                inventory = validate_error_inventory(
                    inventory_value,
                    retained_base=report_path.parent,
                    require_retained=True,
                    expected_test_catalog=canonical_expected,
                )
                if inventory.get("scenario") != runner_id:
                    raise QualificationPolicyError(
                        f"runner scenario {runner_id} error inventory scenario mismatch"
                    )
                if runner_row.get("libraryErrorCount") != inventory.get("errorCount"):
                    raise QualificationPolicyError(
                        f"runner scenario {runner_id} error inventory count mismatch"
                    )
                if (
                    runner_result == "pass"
                    and runner_id not in {"terminal-outcomes", "adaptive-hls-soak"}
                    and inventory.get("errorCount") != 0
                ):
                    raise QualificationPolicyError(
                        f"runner scenario {runner_id} has unexpected raw errors"
                    )
            elif runner_result == "fail" and runner_row.get("appLog") == "missing":
                # An assertion can stop before every child player/log exists.
                # Retain a diagnostic failed report; missing logs never satisfy
                # a passing scenario or provide an error-free playback claim.
                if inventory_value is not None or runner_row.get("libraryErrorCount") != 0:
                    raise QualificationPolicyError(
                        f"failed runner {runner_id} claims an inventory for missing logs"
                    )
            elif runner_id == "analyzer":
                if (
                    inventory_value is not None
                    or runner_row.get("libraryErrorCount") != 0
                ):
                    raise QualificationPolicyError(
                        f"support runner {runner_id} cannot claim device log error inventory"
                    )
            else:
                raise QualificationPolicyError(
                    f"runner scenario {runner_id} has no captured raw device log inventory"
                )
    expected_report_result = (
        "pass" if all(row.get("result") == "pass" for row in runner_rows) else "fail"
    )
    if report.get("result") != expected_report_result:
        raise QualificationPolicyError(
            "device report result does not reconcile with runner scenarios"
        )

    report_rows = report.get("qualificationRows")
    if not isinstance(report_rows, list):
        raise QualificationPolicyError("report has no qualificationRows array")
    if not stable and report_rows:
        raise QualificationPolicyError(
            "exploratory report cannot contain qualification rows"
        )
    output_scenarios_by_runner: dict[str, set[str]] = {
        runner_id: set() for runner_id in runner_ids
    }
    if strict_provenance:
        for index, row in enumerate(report_rows):
            if not isinstance(row, dict):
                raise QualificationPolicyError(
                    f"qualification row {index} is not an object"
                )
            scenario_id = row.get("scenario")
            if scenario_id not in output_contracts:
                raise QualificationPolicyError(
                    f"qualification row {index} has no authorized producer"
                )
            contract, _ = output_contracts[str(scenario_id)]
            runner_id = contract["id"]
            if row.get("runnerScenario") != runner_id:
                raise QualificationPolicyError(
                    f"qualification row {scenario_id!r} producer mismatch"
                )
            if runner_id not in runner_rows_by_id:
                raise QualificationPolicyError(
                    f"qualification row {scenario_id!r} has no executed producer"
                )
            output_scenarios_by_runner.setdefault(runner_id, set()).add(
                str(scenario_id)
            )

    inspected_by_runner: dict[str, dict[str, dict]] = {}
    retained_by_runner: dict[str, dict[str, tuple[Path, dict, str]]] = {}
    evidence_scenarios_by_runner: dict[str, set[str]] = {}
    if strict_provenance:
        candidate_catalog = report.get("testCatalog")
        assert isinstance(candidate_catalog, list)
        for runner_id, runner_row in runner_rows_by_id.items():
            contract = runner_contracts[runner_id]
            produced = output_scenarios_by_runner.get(runner_id, set())
            applicable = applicable_runner_outputs(
                contract, scenarios, effective_hardware
            )
            if not produced.issubset(applicable):
                raise QualificationPolicyError(
                    f"runner scenario {runner_id} produced an inapplicable qualification row"
                )
            authorized = authorized_runner_catalog(
                contract, applicable, candidate_catalog
            )
            if runner_row.get("expectedTestCatalog") != authorized:
                raise QualificationPolicyError(
                    f"runner scenario {runner_id} catalog differs from matrix authority"
                )
            runner_passed = runner_row.get("result") == "pass"
            expected_evidence_status = (
                "captured"
                if runner_passed and applicable
                else "missing" if applicable else "not-applicable"
            )
            if runner_row.get("qualificationEvidence") != expected_evidence_status:
                raise QualificationPolicyError(
                    f"runner scenario {runner_id} qualification-evidence status "
                    "does not match its result and applicable outputs"
                )
            if runner_passed and applicable:
                if stable and produced != applicable:
                    missing = sorted(applicable - produced)
                    raise QualificationPolicyError(
                        f"passing runner scenario {runner_id} produced incomplete "
                        f"qualification rows: {missing!r}"
                    )
            elif produced:
                raise QualificationPolicyError(
                    f"non-passing runner scenario {runner_id} produced qualification rows"
                )
            evidence_scenarios = (
                produced if stable else (applicable if runner_passed else set())
            )
            evidence_scenarios_by_runner[runner_id] = evidence_scenarios
            if not evidence_scenarios:
                continue
            expected_owners = runner_attachment_expectations(
                contract, evidence_scenarios
            )
            final_xcresult = runner_xcresults.get(runner_id)
            if final_xcresult is None:
                raise QualificationPolicyError(
                    f"runner scenario {runner_id} has no final passing xcresult"
                )
            inspected_by_runner[runner_id] = inspect_xcresult_qualification_attachments(
                final_xcresult, expected_owners
            )
            retained_root = safe_relative_directory(
                report_path.parent,
                f"{runner_id}-attachments",
                f"runner scenario {runner_id} retained attachment export",
            )
            retained_by_runner[runner_id] = exported_qualification_attachments(
                retained_root, expected_owners
            )
    seen: set[tuple[str, str]] = set()
    seen_host_artifact_fingerprints: set[tuple[str, ...]] = set()
    fixture_checksum = report.get("fixtureManifestChecksum")
    for index, row in enumerate(report_rows):
        if not isinstance(row, dict):
            raise QualificationPolicyError(
                f"qualification row {index} is not an object"
            )
        key = (row.get("scenario"), row.get("hardware"))
        if key[0] not in scenarios or key[1] not in hardware:
            raise QualificationPolicyError(
                f"qualification row {index} is unknown: {key!r}"
            )
        if key[1] not in effective_hardware:
            raise QualificationPolicyError(
                f"qualification row {index} does not belong to the report device: {key!r}"
            )
        if strict_provenance and release_matrix:
            validate_release_qualification_row_evidence_path(row, index)
        if strict_provenance:
            expected_device_fields = {
                "device": report_device.get("marketingName"),
                "deviceFamily": report_device.get("deviceFamily"),
                "productType": report_device.get("productType"),
                "osVersion": report_device.get("osVersion"),
                "osBuild": report_device.get("osBuild"),
                "osReleaseType": report_device.get("osReleaseType"),
            }
            contradicted = sorted(
                field
                for field, expected in expected_device_fields.items()
                if not isinstance(expected, str)
                or not expected
                or row.get(field) != expected
            )
            if contradicted:
                raise QualificationPolicyError(
                    f"qualification row {index} contradicts report device fields: "
                    f"{contradicted!r}"
                )
        if key in seen:
            raise QualificationPolicyError(f"duplicate qualification row {key!r}")
        seen.add(key)  # type: ignore[arg-type]
        scenario = scenarios[key[0]]  # type: ignore[index]
        selected = scenario.get("hardware", list(hardware))
        if key[1] not in selected:
            raise QualificationPolicyError(
                f"qualification row is inapplicable: {key!r}"
            )
        if row.get("result") != "pass":
            raise QualificationPolicyError(f"qualification row did not pass: {key!r}")
        validate_duration(str(key[0]), row.get("durationSeconds"), stable=stable)
        validate_os_row(row, hardware[key[1]], stable=stable)  # type: ignore[index]
        if row.get("fixture") != f"qualification-fixtures:{fixture_checksum}":
            raise QualificationPolicyError(
                f"qualification row fixture mismatch: {key!r}"
            )
        evidence_path = safe_relative_file(
            report_path.parent, row.get("evidence"), f"row {key!r} evidence"
        )
        evidence = load_json(evidence_path, "qualification evidence")
        host_artifact_fingerprints = validate_evidence(
            evidence,
            scenario,
            report,
            str(key[1]),
            stable=stable,
            retained_base=report_path.parent,
            require_retained=True,
            artifact_base=evidence_path.parent,
            artifact_stem=evidence_path.stem,
            require_host_artifacts=True,
        )
        reused_artifacts = seen_host_artifact_fingerprints & host_artifact_fingerprints
        if reused_artifacts:
            raise QualificationPolicyError(
                f"qualification rows reuse retained host artifacts: "
                f"{sorted(reused_artifacts)!r}"
            )
        seen_host_artifact_fingerprints.update(host_artifact_fingerprints)
        if strict_provenance:
            contract, output = output_contracts[str(key[0])]
            runner_id = contract["id"]
            _validate_qualification_producer(
                evidence=evidence,
                row=row,
                scenario=scenario,
                output_contract=output,
                runner_row=runner_rows_by_id[runner_id],
                report=report,
                report_root=report_path.parent,
                retained_attachment=retained_by_runner[runner_id][
                    output["attachmentName"]
                ],
                inspected_attachment=inspected_by_runner[runner_id][
                    output["attachmentName"]
                ],
                stable=stable,
            )
        if evidence.get("durationSeconds") != row.get("durationSeconds"):
            raise QualificationPolicyError(
                f"row/evidence duration mismatch for {key!r}"
            )
    if strict_provenance and not stable:
        for runner_id, evidence_scenarios in evidence_scenarios_by_runner.items():
            runner_row = runner_rows_by_id[runner_id]
            for scenario_id in sorted(evidence_scenarios):
                contract, output = output_contracts[scenario_id]
                evidence_path = safe_relative_file(
                    report_path.parent,
                    (
                        f"evidence/{scenario_id}-"
                        f"{exploratory_evidence_hardware}.json"
                    ),
                    f"exploratory {scenario_id!r} evidence",
                )
                evidence = load_json(evidence_path, "exploratory qualification evidence")
                host_artifact_fingerprints = validate_evidence(
                    evidence,
                    scenarios[scenario_id],
                    report,
                    exploratory_evidence_hardware,
                    stable=False,
                    retained_base=report_path.parent,
                    require_retained=True,
                    artifact_base=evidence_path.parent,
                    artifact_stem=evidence_path.stem,
                    require_host_artifacts=True,
                )
                reused_artifacts = (
                    seen_host_artifact_fingerprints & host_artifact_fingerprints
                )
                if reused_artifacts:
                    raise QualificationPolicyError(
                        "exploratory evidence reuses retained host artifacts: "
                        f"{sorted(reused_artifacts)!r}"
                    )
                seen_host_artifact_fingerprints.update(host_artifact_fingerprints)
                synthetic_row = {
                    "scenario": scenario_id,
                    "runnerScenario": runner_id,
                    "hardware": exploratory_evidence_hardware,
                    "durationSeconds": evidence.get("durationSeconds"),
                }
                _validate_qualification_producer(
                    evidence=evidence,
                    row=synthetic_row,
                    scenario=scenarios[scenario_id],
                    output_contract=output,
                    runner_row=runner_row,
                    report=report,
                    report_root=report_path.parent,
                    retained_attachment=retained_by_runner[runner_id][
                        output["attachmentName"]
                    ],
                    inspected_attachment=inspected_by_runner[runner_id][
                        output["attachmentName"]
                    ],
                    stable=False,
                )
    if require_complete:
        missing = sorted(required_rows(matrix) - seen)
        if missing:
            raise QualificationPolicyError(
                f"report is missing required rows: {missing!r}"
            )
    return report


def validate_record(
    record_path: Path,
    matrix: dict,
    *,
    expected_identity: dict | None = None,
    strict_provenance: bool = True,
    require_complete: bool = True,
) -> dict:
    record = load_json(record_path, "qualification record")
    scenarios, hardware = validate_matrix(matrix)
    if strict_provenance:
        if is_release_matrix(matrix):
            validate_release_matrix_contract(matrix)
        validate_candidate_identity(record, strict=True)
    if expected_identity is not None:
        compare_identity(record, expected_identity, f"record {record_path}")
    source_rows: dict[tuple[object, object], tuple[dict, dict]] = {}
    source_runner_summaries: dict[tuple[str, str], dict] = {}
    if strict_provenance:
        source_reports = record.get("sourceReports")
        if not isinstance(source_reports, list) or not source_reports:
            raise QualificationPolicyError(
                "qualification record has no retained source reports"
            )
        source_paths: set[str] = set()
        for index, binding in enumerate(source_reports):
            if not isinstance(binding, dict):
                raise QualificationPolicyError(
                    f"retained source report {index} is malformed"
                )
            relative_root = binding.get("path")
            if not isinstance(relative_root, str) or relative_root in source_paths:
                raise QualificationPolicyError("duplicate retained source report path")
            source_paths.add(relative_root)
            root = safe_relative_directory(
                record_path.parent,
                relative_root,
                f"retained source report {index}",
            )
            if (
                binding.get("treeDigestAlgorithm") != "swiftvlc-tree-v1"
                or binding.get("treeDigest") != tree_digest(root)
                or binding.get("treeSizeBytes") != tree_size_bytes(root)
            ):
                raise QualificationPolicyError(
                    f"retained source report {index} tree binding mismatch"
                )
            retained_report_path = safe_relative_file(
                root,
                binding.get("reportRelativePath"),
                f"retained source report {index} document",
            )
            if (
                binding.get("reportDigestAlgorithm") != "sha256"
                or binding.get("reportDigest") != sha256_file(retained_report_path)
                or binding.get("reportSizeBytes") != retained_report_path.stat().st_size
            ):
                raise QualificationPolicyError(
                    f"retained source report {index} document binding mismatch"
                )
            # Import lazily: report_validation imports this module while issuing
            # receipts, whereas records consume those receipts only here.
            import report_validation

            try:
                retained_report_bytes = report_validation.regular_file_bytes(
                    retained_report_path,
                    f"retained source report {index} document",
                )
            except report_validation.ReportValidationError as error:
                raise QualificationPolicyError(str(error)) from error
            if not report_validation.is_valid(
                root, report_bytes=retained_report_bytes
            ):
                raise QualificationPolicyError(
                    f"retained source report {index} has no matching "
                    "successful-validation receipt"
                )
            if is_release_matrix(matrix) and not (
                report_validation.is_release_scope_valid(
                    root, report_bytes=retained_report_bytes
                )
            ):
                raise QualificationPolicyError(
                    f"retained source report {index} is not a canonical "
                    "full-scope release run"
                )
            source_report = validate_report(
                retained_report_path,
                matrix,
                candidate=record,
                stable_required=True,
                strict_provenance=True,
            )
            try:
                retained_report_unchanged = (
                    report_validation.regular_file_bytes(
                        retained_report_path,
                        f"retained source report {index} document",
                    )
                    == retained_report_bytes
                )
            except report_validation.ReportValidationError as error:
                raise QualificationPolicyError(str(error)) from error
            if not retained_report_unchanged or not report_validation.is_valid(
                root, report_bytes=retained_report_bytes
            ):
                raise QualificationPolicyError(
                    f"retained source report {index} changed while its receipt "
                    "was consumed"
                )
            if (
                source_report.get("result") != "pass"
                or source_report.get("mode") != "qualification"
                or source_report.get("qualificationEligibleEnvironment") is not True
            ):
                raise QualificationPolicyError(
                    f"retained source report {index} is not a qualifying pass"
                )
            report_rows = source_report.get("qualificationRows", [])
            report_hardware = {
                row.get("hardware") for row in report_rows if isinstance(row, dict)
            }
            if len(report_hardware) != 1 or not all(
                isinstance(item, str) for item in report_hardware
            ):
                raise QualificationPolicyError(
                    f"retained source report {index} has ambiguous hardware"
                )
            hardware_id = next(iter(report_hardware))
            source_report_relative = (
                Path(relative_root) / binding["reportRelativePath"]
            ).as_posix()
            for runner_row in source_report.get("scenarios", []):
                runner_id = runner_row.get("scenario")
                key = (runner_id, hardware_id)
                if not isinstance(runner_id, str) or key in source_runner_summaries:
                    raise QualificationPolicyError(
                        f"duplicate retained runner scenario {key!r}"
                    )
                source_runner_summaries[key] = runner_record_summary(
                    runner_row, hardware_id, source_report_relative
                )
            for source_row in source_report.get("qualificationRows", []):
                key = (source_row.get("scenario"), source_row.get("hardware"))
                if key in source_rows:
                    raise QualificationPolicyError(
                        f"duplicate retained source qualification row {key!r}"
                    )
                source_evidence_path = safe_relative_file(
                    retained_report_path.parent,
                    source_row.get("evidence"),
                    f"retained source row {key!r} evidence",
                )
                source_rows[key] = (
                    source_row,
                    load_json(source_evidence_path, "retained qualification evidence"),
                )
        runner_summaries = record.get("runnerScenarios")
        if not isinstance(runner_summaries, list) or not runner_summaries:
            raise QualificationPolicyError(
                "qualification record has no aggregate runnerScenarios"
            )
        record_runner_summaries: dict[tuple[str, str], dict] = {}
        for index, summary in enumerate(runner_summaries):
            if not isinstance(summary, dict):
                raise QualificationPolicyError(
                    f"aggregate runner scenario {index} is malformed"
                )
            key = (summary.get("scenario"), summary.get("hardware"))
            if (
                not isinstance(key[0], str)
                or not isinstance(key[1], str)
                or key in record_runner_summaries
            ):
                raise QualificationPolicyError(
                    f"duplicate aggregate runner scenario {key!r}"
                )
            record_runner_summaries[key] = summary
        if record_runner_summaries != source_runner_summaries:
            raise QualificationPolicyError(
                "aggregate runner scenarios differ from retained source reports"
            )
        if require_complete:
            required_runner_runs = required_release_runner_runs(matrix)
            actual_runner_runs = set(record_runner_summaries)
            missing_runner_runs = sorted(required_runner_runs - actual_runner_runs)
            if missing_runner_runs:
                raise QualificationPolicyError(
                    "qualification record is missing release runner coverage: "
                    f"{missing_runner_runs!r}"
                )
    rows = record.get("rows")
    if not isinstance(rows, list):
        raise QualificationPolicyError("qualification record has no rows array")
    seen: set[tuple[str, str]] = set()
    seen_host_artifact_fingerprints: set[tuple[str, ...]] = set()
    fixture_checksum = record.get("fixtureManifestChecksum")
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            raise QualificationPolicyError(f"record row {index} is not an object")
        key = (row.get("scenario"), row.get("hardware"))
        if key[0] not in scenarios or key[1] not in hardware:
            raise QualificationPolicyError(f"record row {index} is unknown: {key!r}")
        if key in seen:
            raise QualificationPolicyError(f"duplicate record row {key!r}")
        seen.add(key)  # type: ignore[arg-type]
        if row.get("result") != "pass" or row.get("osReleaseType") != "stable":
            raise QualificationPolicyError(f"record row is not a stable pass: {key!r}")
        validate_duration(str(key[0]), row.get("durationSeconds"), stable=True)
        validate_os_row(row, hardware[key[1]], stable=True)  # type: ignore[index]
        if row.get("fixture") != f"qualification-fixtures:{fixture_checksum}":
            raise QualificationPolicyError(f"record row fixture mismatch: {key!r}")
        evidence_path = safe_relative_file(
            record_path.parent, row.get("evidence"), f"record row {key!r} evidence"
        )
        evidence = load_json(evidence_path, "qualification evidence")
        host_artifact_fingerprints = validate_evidence(
            evidence,
            scenarios[key[0]],  # type: ignore[index]
            record,
            str(key[1]),
            stable=True,
            artifact_base=evidence_path.parent,
            require_host_artifacts=True,
        )
        reused_artifacts = seen_host_artifact_fingerprints & host_artifact_fingerprints
        if reused_artifacts:
            raise QualificationPolicyError(
                f"qualification record rows reuse retained host artifacts: "
                f"{sorted(reused_artifacts)!r}"
            )
        seen_host_artifact_fingerprints.update(host_artifact_fingerprints)
        if evidence.get("durationSeconds") != row.get("durationSeconds"):
            raise QualificationPolicyError(
                f"row/evidence duration mismatch for {key!r}"
            )
        if strict_provenance:
            source_pair = source_rows.get(key)
            if source_pair is None:
                raise QualificationPolicyError(
                    f"record row has no retained source report: {key!r}"
                )
            source_row, source_evidence = source_pair
            expected_row = dict(source_row, evidence=row.get("evidence"))
            if row != expected_row:
                raise QualificationPolicyError(
                    f"record row differs from retained source report: {key!r}"
                )
            if evidence != source_evidence:
                raise QualificationPolicyError(
                    f"record evidence differs from retained source report: {key!r}"
                )
    missing = sorted(required_rows(matrix) - seen)
    extra = sorted(seen - required_rows(matrix))
    if extra or (require_complete and missing):
        raise QualificationPolicyError(
            f"qualification record row set mismatch; missing={missing}, extra={extra}"
        )
    if strict_provenance and set(source_rows) != seen:
        raise QualificationPolicyError(
            "retained source report row set differs from qualification record"
        )
    return record


def _write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    catalog_parser = subparsers.add_parser("normalize-catalog")
    catalog_parser.add_argument("--input", type=Path, required=True)
    catalog_parser.add_argument("--output", type=Path, required=True)
    catalog_parser.add_argument("--full-catalog", type=Path)

    execution_parser = subparsers.add_parser("verify-xcresult")
    execution_parser.add_argument("--xcresult", type=Path, required=True)
    execution_parser.add_argument("--expected-catalog", type=Path, required=True)
    execution_parser.add_argument("--output", type=Path, required=True)

    retry_parser = subparsers.add_parser("classify-retry")
    retry_parser.add_argument("--xcresult", type=Path)
    retry_parser.add_argument("--log", type=Path, required=True)
    retry_parser.add_argument("--expected-catalog", type=Path, required=True)
    retry_parser.add_argument("--output", type=Path, required=True)

    bind_attempts_parser = subparsers.add_parser("bind-attempt-artifacts")
    bind_attempts_parser.add_argument("--input", type=Path, required=True)
    bind_attempts_parser.add_argument("--artifact-root", type=Path, required=True)
    bind_attempts_parser.add_argument("--output", type=Path, required=True)

    cadence_probe_parser = subparsers.add_parser(
        "validate-cadence-semantics-probe"
    )
    cadence_probe_parser.add_argument("--artifact-root", type=Path, required=True)
    cadence_probe_parser.add_argument("--expected-catalog", type=Path, required=True)
    cadence_probe_parser.add_argument("--test-execution", type=Path, required=True)
    cadence_probe_parser.add_argument("--attempts", type=Path, required=True)
    cadence_probe_parser.add_argument("--version", required=True)
    cadence_probe_parser.add_argument("--output", type=Path, required=True)

    inventory_parser = subparsers.add_parser("build-error-inventory")
    inventory_parser.add_argument("--log-root", type=Path, required=True)
    inventory_parser.add_argument("--log-prefix", required=True)
    inventory_parser.add_argument("--source-prefix", required=True)
    inventory_parser.add_argument("--scenario", required=True)
    inventory_parser.add_argument("--retained-root", required=True)
    inventory_parser.add_argument("--retained-base", type=Path, required=True)
    inventory_parser.add_argument("--expected-catalog", type=Path, required=True)
    inventory_parser.add_argument("--output", type=Path, required=True)

    error_evidence_parser = subparsers.add_parser("validate-error-evidence")
    error_evidence_parser.add_argument("--evidence", type=Path, required=True)
    error_evidence_parser.add_argument("--scenario", required=True)
    error_evidence_parser.add_argument("--retained-root-base", type=Path)
    error_evidence_parser.add_argument(
        "--require-retained-artifacts", action="store_true"
    )

    evidence_parser = subparsers.add_parser("validate-evidence")
    evidence_parser.add_argument("--evidence", type=Path, required=True)
    evidence_parser.add_argument("--matrix", type=Path, required=True)
    evidence_parser.add_argument("--identity", type=Path, required=True)
    evidence_parser.add_argument("--scenario", required=True)
    evidence_parser.add_argument("--hardware", required=True)
    evidence_parser.add_argument("--stable", action="store_true")
    evidence_parser.add_argument("--retained-root-base", type=Path)
    evidence_parser.add_argument("--require-retained-artifacts", action="store_true")

    report_parser = subparsers.add_parser("validate-report")
    report_parser.add_argument("--report", type=Path, required=True)
    report_parser.add_argument("--matrix", type=Path, required=True)
    report_parser.add_argument("--candidate", type=Path)
    report_parser.add_argument("--stable-required", action="store_true")

    record_parser = subparsers.add_parser("validate-record")
    record_parser.add_argument("--record", type=Path, required=True)
    record_parser.add_argument("--matrix", type=Path, required=True)
    record_parser.add_argument("--identity", type=Path)
    record_parser.add_argument("--version")
    record_parser.add_argument("--artifact-digest")
    record_parser.add_argument("--source-digest")
    record_parser.add_argument("--source-commit")
    record_parser.add_argument("--matrix-checksum")
    record_parser.add_argument("--feature-checksum")
    record_parser.add_argument("--profiles-checksum")
    record_parser.add_argument("--allow-incomplete", action="store_true")

    args = parser.parse_args()
    try:
        if args.command == "normalize-catalog":
            document = load_json(args.input, "XCTest enumeration")
            result = catalog_record(catalog_from_enumeration(document))
            if args.full_catalog is not None:
                full = load_json(args.full_catalog, "full XCTest catalog")
                canonical_full = catalog_record(full.get("testIdentifiers", []))
                if full != canonical_full:
                    raise QualificationPolicyError(
                        "full XCTest catalog is not canonical"
                    )
                unknown = sorted(
                    set(result["testIdentifiers"])
                    - set(canonical_full["testIdentifiers"])
                )
                if unknown:
                    raise QualificationPolicyError(
                        f"selected tests are absent from the bound full catalog: {unknown!r}"
                    )
            _write_json(args.output, result)
        elif args.command == "verify-xcresult":
            expected = load_json(args.expected_catalog, "expected test catalog")
            result = verify_xcresult_execution(args.xcresult, expected)
            _write_json(args.output, result)
        elif args.command == "classify-retry":
            expected = load_json(args.expected_catalog, "expected test catalog")
            result = classify_retry(
                args.xcresult,
                args.log.read_text(encoding="utf-8"),
                expected,
            )
            _write_json(args.output, result)
            return 0 if result["retryable"] else 1
        elif args.command == "bind-attempt-artifacts":
            attempts = load_json(args.input, "runner attempts", object_required=False)
            result = bind_attempt_artifacts(attempts, args.artifact_root)
            _write_json(args.output, result)
        elif args.command == "validate-cadence-semantics-probe":
            expected_catalog = load_json(
                args.expected_catalog, "cadence semantics expected test catalog"
            )
            execution = load_json(
                args.test_execution, "cadence semantics test execution"
            )
            attempts = load_json(
                args.attempts,
                "cadence semantics runner attempts",
                object_required=False,
            )
            runner_row = {
                "scenario": CADENCE_SEMANTICS_PROBE_SCENARIO,
                "result": "pass",
                "xcodebuildExitCode": 0,
                "libraryErrorCount": 0,
                "appLog": "captured",
                "qualificationEvidence": "report-only",
                "durationSeconds": 1,
                "expectedTestCatalog": expected_catalog,
                "testExecution": execution,
                "attempts": attempts,
                "attemptArtifactRoot": (
                    f"{CADENCE_SEMANTICS_PROBE_SCENARIO}-attempt-artifacts"
                ),
                "hostErrorInventory": None,
            }
            result = validate_cadence_semantics_probe_artifacts(
                args.artifact_root,
                runner_row,
                expected_version=args.version,
                require_proof=False,
            )
            _write_json(args.output, result)
        elif args.command == "build-error-inventory":
            if not ID.fullmatch(args.scenario):
                raise QualificationPolicyError("error inventory scenario is invalid")
            expected_catalog_value = load_json(
                args.expected_catalog, "device log expected XCTest catalog"
            )
            expected_catalog = catalog_record(
                expected_catalog_value.get("testIdentifiers", [])
            )
            if expected_catalog_value != expected_catalog:
                raise QualificationPolicyError(
                    "device log expected XCTest catalog is not canonical"
                )
            retained_destination = args.retained_base / args.retained_root
            try:
                retained_destination.resolve().relative_to(args.retained_base.resolve())
            except ValueError as error:
                raise QualificationPolicyError(
                    "error inventory retained destination escapes its base"
                ) from error
            stage_error_logs(
                args.log_root,
                args.source_prefix,
                retained_destination,
            )
            result = build_error_inventory(
                retained_destination,
                args.log_prefix,
                args.scenario,
                retained_root=args.retained_root,
                expected_test_catalog=expected_catalog,
            )
            _write_json(args.output, result)
        elif args.command == "validate-error-evidence":
            evidence = load_json(args.evidence, "expected-error evidence")
            validate_expected_error_evidence(
                evidence,
                args.scenario,
                retained_base=args.retained_root_base,
                require_retained=args.require_retained_artifacts,
            )
        elif args.command == "validate-evidence":
            matrix = load_json(args.matrix, "qualification matrix")
            scenarios, _ = validate_matrix(matrix)
            if args.scenario not in scenarios:
                raise QualificationPolicyError(f"unknown scenario {args.scenario!r}")
            evidence = load_json(args.evidence, "qualification evidence")
            identity = load_json(args.identity, "candidate identity")
            validate_evidence(
                evidence,
                scenarios[args.scenario],
                identity,
                args.hardware,
                stable=args.stable,
                retained_base=args.retained_root_base,
                require_retained=args.require_retained_artifacts,
                artifact_base=args.evidence.parent,
                artifact_stem=args.evidence.stem,
                require_host_artifacts=args.require_retained_artifacts,
            )
        elif args.command == "validate-report":
            matrix = load_json(args.matrix, "qualification matrix")
            candidate = (
                load_json(args.candidate, "candidate metadata")
                if args.candidate
                else None
            )
            validate_report(
                args.report,
                matrix,
                candidate=candidate,
                stable_required=args.stable_required,
            )
        else:
            matrix = load_json(args.matrix, "qualification matrix")
            identity = (
                load_json(args.identity, "expected identity") if args.identity else None
            )
            record = validate_record(
                args.record,
                matrix,
                expected_identity=identity,
                require_complete=not args.allow_incomplete,
            )
            for field, expected in (
                ("version", args.version),
                ("artifactDigest", args.artifact_digest),
                ("releaseSourceDigest", args.source_digest),
                ("sourceCommit", args.source_commit),
                ("qualificationMatrixChecksum", args.matrix_checksum),
                ("featureManifestChecksum", args.feature_checksum),
                ("qualificationProfilesChecksum", args.profiles_checksum),
            ):
                if expected is not None and record.get(field) != expected:
                    raise QualificationPolicyError(
                        f"record {field} mismatch: {record.get(field)!r} != {expected!r}"
                    )
    except (QualificationPolicyError, OSError, UnicodeError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
