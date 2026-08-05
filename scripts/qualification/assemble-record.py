#!/usr/bin/env python3
"""Assemble candidate-bound device reports into one qualification record."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import sys
import tempfile
from pathlib import Path


class AssemblyError(ValueError):
    pass


SHA1 = re.compile(r"[0-9a-f]{40}")
SHA256 = re.compile(r"[0-9a-f]{64}")
ROW_ID = re.compile(r"[a-z0-9][a-z0-9-]*")


def load_object(path: Path, description: str) -> dict:
    try:
        value = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise AssemblyError(f"cannot read {description} {path}: {error}") from error
    if not isinstance(value, dict):
        raise AssemblyError(f"{description} {path} must be a JSON object")
    return value


def required_rows(matrix: dict) -> set[tuple[str, str]]:
    scenarios = matrix.get("scenarios")
    hardware = matrix.get("hardware")
    if not isinstance(scenarios, list) or not isinstance(hardware, list):
        raise AssemblyError("qualification matrix needs scenarios and hardware arrays")
    if any(
        not isinstance(row, dict)
        or not ROW_ID.fullmatch(str(row.get("id", "")))
        for row in hardware
    ):
        raise AssemblyError("qualification matrix has an invalid hardware id")
    hardware_ids = {row["id"] for row in hardware}
    if len(hardware_ids) != len(hardware):
        raise AssemblyError("qualification matrix has invalid or duplicate hardware ids")

    result: set[tuple[str, str]] = set()
    scenario_ids: set[str] = set()
    for scenario in scenarios:
        if (
            not isinstance(scenario, dict)
            or not ROW_ID.fullmatch(str(scenario.get("id", "")))
        ):
            raise AssemblyError("qualification matrix has an invalid scenario id")
        scenario_id = scenario["id"]
        if scenario_id in scenario_ids:
            raise AssemblyError("qualification matrix has duplicate scenario ids")
        scenario_ids.add(scenario_id)
        selected = scenario.get("hardware", sorted(hardware_ids))
        if not isinstance(selected, list) or not selected:
            raise AssemblyError(f"scenario {scenario_id!r} has no hardware rows")
        unknown = set(selected) - hardware_ids
        if unknown:
            raise AssemblyError(
                f"scenario {scenario_id!r} has unknown hardware rows: "
                + ", ".join(sorted(unknown))
            )
        result.update((scenario_id, hardware_id) for hardware_id in selected)
    return result


def safe_evidence_path(report_path: Path, relative: object) -> Path:
    if not isinstance(relative, str) or not relative:
        raise AssemblyError(f"report {report_path} row has no evidence path")
    candidate = Path(relative)
    if candidate.is_absolute() or ".." in candidate.parts:
        raise AssemblyError(f"report {report_path} has unsafe evidence path {relative!r}")
    resolved = (report_path.parent / candidate).resolve()
    try:
        resolved.relative_to(report_path.parent.resolve())
    except ValueError as error:
        raise AssemblyError(
            f"report {report_path} evidence escapes its directory: {relative!r}"
        ) from error
    if not resolved.is_file():
        raise AssemblyError(f"report {report_path} evidence is missing: {relative}")
    return resolved


def safe_evidence_artifact_path(
    evidence_path: Path, relative: object, description: str, *, directory: bool
) -> tuple[Path, Path]:
    if not isinstance(relative, str) or not relative:
        raise AssemblyError(f"evidence {evidence_path} has no {description} path")
    candidate = Path(relative)
    if candidate.is_absolute() or ".." in candidate.parts:
        raise AssemblyError(
            f"evidence {evidence_path} has unsafe {description} path {relative!r}"
        )
    resolved = (evidence_path.parent / candidate).resolve()
    try:
        resolved.relative_to(evidence_path.parent.resolve())
    except ValueError as error:
        raise AssemblyError(
            f"evidence {evidence_path} {description} escapes its directory"
        ) from error
    valid = resolved.is_dir() if directory else resolved.is_file()
    if not valid:
        kind = "directory" if directory else "file"
        raise AssemblyError(
            f"evidence {evidence_path} {description} {kind} is missing: {relative}"
        )
    return resolved, candidate


def tree_digest(root: Path) -> str:
    digest = hashlib.sha256(b"SwiftVLC artifact tree digest v1\0")
    entries = sorted(root.rglob("*"), key=lambda path: path.relative_to(root).as_posix())
    if not entries:
        raise AssemblyError(f"trace is empty: {root}")

    def update(value: bytes) -> None:
        digest.update(len(value).to_bytes(8, "big"))
        digest.update(value)

    for path in entries:
        metadata = path.lstat()
        if stat.S_ISDIR(metadata.st_mode):
            kind, payload = b"directory", b""
        elif stat.S_ISREG(metadata.st_mode):
            content = hashlib.sha256()
            with path.open("rb") as source:
                while chunk := source.read(1024 * 1024):
                    content.update(chunk)
            kind, payload = b"file", content.digest()
        elif stat.S_ISLNK(metadata.st_mode):
            kind, payload = b"symlink", os.readlink(path).encode()
        else:
            raise AssemblyError(f"unsupported trace entry: {path}")
        update(kind)
        update(path.relative_to(root).as_posix().encode())
        update(stat.S_IMODE(metadata.st_mode).to_bytes(4, "big"))
        update(payload)
    return digest.hexdigest()


def retained_trace_artifacts(
    evidence_path: Path, trace: object, description: str
) -> list[tuple[Path, Path, bool]]:
    if not isinstance(trace, dict):
        raise AssemblyError(
            f"evidence {evidence_path} has malformed {description} provenance"
        )
    trace_source, trace_relative = safe_evidence_artifact_path(
        evidence_path,
        trace.get("runArtifact"),
        description,
        directory=True,
    )
    toc_source, toc_relative = safe_evidence_artifact_path(
        evidence_path,
        trace.get("tableOfContents"),
        f"{description} table of contents",
        directory=False,
    )
    if tree_digest(trace_source) != trace.get("treeDigest"):
        raise AssemblyError(f"evidence {evidence_path} {description} digest mismatch")
    return [
        (trace_source, trace_relative, True),
        (toc_source, toc_relative, False),
    ]


def assemble(
    version: str,
    candidate_path: Path,
    matrix_path: Path,
    report_paths: list[Path],
    output_path: Path,
) -> dict:
    if not report_paths:
        raise AssemblyError("at least one device report is required")
    candidate = load_object(candidate_path, "candidate metadata")
    matrix = load_object(matrix_path, "qualification matrix")
    matrix_checksum = hashlib.sha256(matrix_path.read_bytes()).hexdigest()
    required = required_rows(matrix)

    identity = {
        "version": version,
        "artifactDigestAlgorithm": "swiftvlc-tree-v1",
        "artifactDigest": candidate.get("artifactDigest"),
        "sourceCommit": candidate.get("sourceCommit"),
        "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
        "releaseSourceDigest": candidate.get("releaseSourceDigest"),
        "qualificationMatrixChecksum": matrix_checksum,
    }
    for field, pattern in (
        ("artifactDigest", SHA256),
        ("sourceCommit", SHA1),
        ("releaseSourceDigest", SHA256),
    ):
        if not pattern.fullmatch(str(identity[field] or "")):
            raise AssemblyError(f"candidate metadata has no valid {field}")
    if candidate.get("version") != version:
        raise AssemblyError(
            f"candidate metadata version is {candidate.get('version')!r}, expected {version!r}"
        )
    for field, expected in (
        ("artifactDigestAlgorithm", "swiftvlc-tree-v1"),
        ("releaseSourceDigestAlgorithm", "swiftvlc-git-tree-v1"),
    ):
        if candidate.get(field) != expected:
            raise AssemblyError(
                f"candidate metadata {field} mismatch: "
                f"{candidate.get(field)!r} != {expected!r}"
            )

    rows: dict[tuple[str, str], tuple[dict, Path, list[tuple[Path, Path, bool]]]] = {}
    for report_path in report_paths:
        report = load_object(report_path, "device report")
        if report.get("result") != "pass":
            raise AssemblyError(f"report {report_path} did not pass")
        if report.get("qualificationEligibleEnvironment") is not True:
            raise AssemblyError(f"report {report_path} is not from a qualifying environment")
        if report.get("mode") != "qualification":
            raise AssemblyError(f"report {report_path} is not in qualification mode")
        for field, expected in identity.items():
            if report.get(field) != expected:
                raise AssemblyError(
                    f"report {report_path} {field} mismatch: "
                    f"{report.get(field)!r} != {expected!r}"
                )

        report_rows = report.get("qualificationRows")
        if not isinstance(report_rows, list) or not report_rows:
            raise AssemblyError(f"report {report_path} has no qualification rows")
        for row in report_rows:
            if not isinstance(row, dict):
                raise AssemblyError(f"report {report_path} contains a non-object row")
            scenario = row.get("scenario")
            hardware = row.get("hardware")
            if not isinstance(scenario, str) or not isinstance(hardware, str):
                raise AssemblyError(
                    f"report {report_path} contains a row without string ids"
                )
            key = (scenario, hardware)
            if key not in required:
                raise AssemblyError(f"report {report_path} contains unknown row {key!r}")
            if key in rows:
                raise AssemblyError(
                    f"duplicate qualification row {key[0]} on {key[1]}"
                )
            if row.get("result") != "pass":
                raise AssemblyError(f"row {key[0]} on {key[1]} did not pass")
            if row.get("osReleaseType") != "stable":
                raise AssemblyError(f"row {key[0]} on {key[1]} is not from stable OS software")
            evidence_path = safe_evidence_path(report_path, row.get("evidence"))
            evidence = load_object(evidence_path, "evidence")
            for field, expected in (
                ("artifactDigest", identity["artifactDigest"]),
                ("releaseSourceDigest", identity["releaseSourceDigest"]),
                ("scenario", key[0]),
                ("hardware", key[1]),
            ):
                if evidence.get(field) != expected:
                    raise AssemblyError(
                        f"evidence {evidence_path} {field} mismatch: "
                        f"{evidence.get(field)!r} != {expected!r}"
                    )
            artifacts: list[tuple[Path, Path, bool]] = []
            provenance = evidence.get("allocationProvenance")
            trace = provenance.get("instrumentsTrace") if isinstance(provenance, dict) else None
            if trace is not None:
                artifacts.extend(
                    retained_trace_artifacts(evidence_path, trace, "allocation trace")
                )
            if key[0] in {
                "pip-render-performance-1080p60",
                "pip-render-performance-4k60",
            }:
                metrics = evidence.get("metrics")
                if not isinstance(metrics, dict):
                    raise AssemblyError(
                        f"evidence {evidence_path} has no performance metrics"
                    )
                conversion = metrics.get("conversionCost")
                if not isinstance(conversion, dict):
                    raise AssemblyError(
                        f"evidence {evidence_path} has no conversion-cost metric"
                    )
                for performance_trace, description in (
                    (metrics.get("gpu"), "Game Performance trace"),
                    (metrics.get("energy"), "Power Profiler trace"),
                    (conversion.get("hostTrace"), "Time Profiler trace"),
                ):
                    artifacts.extend(
                        retained_trace_artifacts(
                            evidence_path, performance_trace, description
                        )
                    )
            rows[key] = (row, evidence_path, artifacts)

    evidence_directory = output_path.parent / "evidence" / version
    staged_rows = []
    for key in sorted(rows):
        row, source, _ = rows[key]
        filename = f"{key[0]}-{key[1]}.json"
        relative = Path("evidence") / version / filename
        staged = dict(row, evidence=str(relative))
        staged_rows.append(staged)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    evidence_directory.mkdir(parents=True, exist_ok=True)
    for key, (_, source, artifacts) in sorted(rows.items()):
        destination = evidence_directory / f"{key[0]}-{key[1]}.json"
        with tempfile.NamedTemporaryFile(
            dir=evidence_directory, prefix=f".{destination.name}.", delete=False
        ) as temporary:
            temporary_path = Path(temporary.name)
        try:
            shutil.copyfile(source, temporary_path)
            os.replace(temporary_path, destination)
        finally:
            temporary_path.unlink(missing_ok=True)
        for artifact_source, artifact_relative, is_directory in artifacts:
            artifact_destination = evidence_directory / artifact_relative
            artifact_destination.parent.mkdir(parents=True, exist_ok=True)
            if artifact_destination.exists():
                identical = (
                    is_directory
                    and artifact_destination.is_dir()
                    and tree_digest(artifact_destination) == tree_digest(artifact_source)
                ) or (
                    not is_directory
                    and artifact_destination.is_file()
                    and artifact_destination.read_bytes() == artifact_source.read_bytes()
                )
                if not identical:
                    raise AssemblyError(
                        f"retained evidence artifact collision: {artifact_relative}"
                    )
                continue
            if is_directory:
                shutil.copytree(artifact_source, artifact_destination, symlinks=True)
            else:
                shutil.copyfile(artifact_source, artifact_destination)

    record = {**identity, "rows": staged_rows}
    with tempfile.NamedTemporaryFile(
        mode="w",
        dir=output_path.parent,
        prefix=f".{output_path.name}.",
        delete=False,
    ) as temporary:
        temporary_path = Path(temporary.name)
        json.dump(record, temporary, indent=2, sort_keys=True)
        temporary.write("\n")
    try:
        os.replace(temporary_path, output_path)
    finally:
        temporary_path.unlink(missing_ok=True)
    return record


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--candidate-metadata", type=Path, required=True)
    parser.add_argument("--matrix", type=Path, required=True)
    parser.add_argument("--report", type=Path, action="append", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        record = assemble(
            args.version,
            args.candidate_metadata,
            args.matrix,
            args.report,
            args.output,
        )
    except AssemblyError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    print(f"Assembled {len(record['rows'])} candidate-bound qualification row(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
