#!/usr/bin/env python3
"""Bind host-captured Instruments performance traces to one PiP row."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path


class PerformanceTraceError(ValueError):
    pass


SHA256 = re.compile(r"[0-9a-f]{64}")
TRACE_FIELDS = {
    "game": ("gpu", "Game Performance"),
    "power": ("energy", "Power Profiler"),
    "time": ("conversionCost", "Time Profiler"),
}


def trace_record(
    trace: Path,
    toc: Path,
    digest_script: Path,
    template: str,
    artifact_directory: Path,
    evidence_directory: Path,
) -> dict:
    if not trace.is_dir() or not any(trace.rglob("*")):
        raise PerformanceTraceError(f"{template} trace is missing or empty")
    try:
        toc_text = toc.read_text(errors="replace")
    except OSError as error:
        raise PerformanceTraceError(f"cannot read {template} trace TOC: {error}") from error
    if "schema" not in toc_text.lower() and "table" not in toc_text.lower():
        raise PerformanceTraceError(f"{template} trace TOC has no recorded tables")
    staged_trace = artifact_directory / trace.name
    staged_toc = artifact_directory / toc.name
    try:
        shutil.copytree(trace, staged_trace)
        shutil.copy2(toc, staged_toc)
    except OSError as error:
        raise PerformanceTraceError(
            f"cannot retain {template} trace artifacts: {error}"
        ) from error
    result = subprocess.run(
        [sys.executable, str(digest_script), str(staged_trace)],
        check=False,
        capture_output=True,
        text=True,
    )
    digest = result.stdout.strip()
    if result.returncode != 0 or not SHA256.fullmatch(digest):
        raise PerformanceTraceError(f"could not digest {template} trace")
    return {
        "status": "captured",
        "template": template,
        "format": "com.apple.instruments.trace",
        "runArtifact": staged_trace.relative_to(evidence_directory).as_posix(),
        "tableOfContents": staged_toc.relative_to(evidence_directory).as_posix(),
        "treeDigestAlgorithm": "swiftvlc-tree-v1",
        "treeDigest": digest,
        "targetProcess": "iOS",
    }


def augment(
    evidence_path: Path,
    traces: dict[str, tuple[Path, Path]],
    digest_script: Path,
) -> dict:
    try:
        payload = json.loads(evidence_path.read_text())
    except (OSError, ValueError) as error:
        raise PerformanceTraceError(f"cannot read PiP performance evidence: {error}") from error
    scenario = payload.get("scenario") if isinstance(payload, dict) else None
    if scenario not in {
        "pip-render-performance-1080p60",
        "pip-render-performance-4k60",
    }:
        raise PerformanceTraceError("performance traces belong only to a PiP performance row")
    metrics = payload.get("metrics")
    if not isinstance(metrics, dict):
        raise PerformanceTraceError("performance evidence has no metrics object")

    artifact_directory = evidence_path.parent / "artifacts" / evidence_path.stem
    try:
        artifact_directory.mkdir(parents=True, exist_ok=False)
    except OSError as error:
        raise PerformanceTraceError(
            f"cannot create performance trace artifact directory: {error}"
        ) from error
    try:
        for key, (field, template) in TRACE_FIELDS.items():
            trace, toc = traces[key]
            record = trace_record(
                trace,
                toc,
                digest_script,
                template,
                artifact_directory,
                evidence_path.parent,
            )
            if field == "conversionCost":
                conversion = metrics.get(field)
                if not isinstance(conversion, dict):
                    raise PerformanceTraceError("conversion-cost evidence is malformed")
                conversion.pop("hostTraceStatus", None)
                conversion["hostTrace"] = record
            else:
                metrics[field] = record
    except (OSError, PerformanceTraceError):
        shutil.rmtree(artifact_directory, ignore_errors=True)
        raise
    payload.pop("hostTraceRequirements", None)
    evidence_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    return payload


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--game-trace", type=Path, required=True)
    parser.add_argument("--game-toc", type=Path, required=True)
    parser.add_argument("--power-trace", type=Path, required=True)
    parser.add_argument("--power-toc", type=Path, required=True)
    parser.add_argument("--time-trace", type=Path, required=True)
    parser.add_argument("--time-toc", type=Path, required=True)
    parser.add_argument("--digest-script", type=Path, required=True)
    args = parser.parse_args()
    try:
        augment(
            args.evidence,
            {
                "game": (args.game_trace, args.game_toc),
                "power": (args.power_trace, args.power_toc),
                "time": (args.time_trace, args.time_toc),
            },
            args.digest_script,
        )
    except PerformanceTraceError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
