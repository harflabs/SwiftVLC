#!/usr/bin/env python3
"""Create and verify source identity bound to an exact signed candidate app."""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import qualification_policy as policy

SHA1 = re.compile(r"[0-9a-f]{40}")
SHA256 = re.compile(r"[0-9a-f]{64}")
BUNDLE_IDENTIFIER = re.compile(
    r"[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+"
)


class CandidateMetadataError(ValueError):
    pass


def validated_bundle_identifier(value: object, description: str) -> str:
    if not isinstance(value, str) or BUNDLE_IDENTIFIER.fullmatch(value) is None:
        raise CandidateMetadataError(f"{description} has no valid bundle identifier")
    return value


def app_bundle_identifier(app: Path, description: str) -> str:
    try:
        with (app / "Info.plist").open("rb") as source:
            info = plistlib.load(source)
    except (OSError, plistlib.InvalidFileException) as error:
        raise CandidateMetadataError(
            f"cannot read {description} Info.plist: {error}"
        ) from error
    return validated_bundle_identifier(info.get("CFBundleIdentifier"), description)


def _resolve_xctestrun_product_path(
    value: object,
    *,
    xctestrun: Path,
    test_host: Path | None = None,
    description: str,
) -> Path:
    if not isinstance(value, str) or not value:
        raise CandidateMetadataError(f"base xctestrun has no {description}")
    # Inspect template tokens before inserting filesystem paths. A directory
    # supplied by tempfile (or a user) can legitimately contain '__' or '$'.
    tokens = re.findall(r"__[A-Z][A-Z0-9_]*__|\$\([^)]+\)|\$\{[^}]+\}", value)
    if any(token not in {"__TESTROOT__", "__TESTHOST__"} for token in tokens):
        raise CandidateMetadataError(
            f"base xctestrun {description} contains an unsupported path placeholder"
        )
    if "__TESTHOST__" in tokens:
        if test_host is None:
            raise CandidateMetadataError(
                f"base xctestrun {description} uses __TESTHOST__ without a test host"
            )
    replacements = {"__TESTROOT__": str(xctestrun.resolve().parent)}
    if test_host is not None:
        replacements["__TESTHOST__"] = str(test_host)
    expanded = re.sub(
        r"__TESTROOT__|__TESTHOST__", lambda match: replacements[match[0]], value
    )
    try:
        return Path(expanded).resolve(strict=True)
    except OSError as error:
        raise CandidateMetadataError(
            f"base xctestrun {description} does not resolve: {value!r}: {error}"
        ) from error


def validate_xctestrun_products(
    xctestrun: Path,
    *,
    candidate_app: Path,
    test_runner: Path,
    test_bundle: Path,
) -> None:
    try:
        with xctestrun.open("rb") as source:
            document = plistlib.load(source)
    except (OSError, plistlib.InvalidFileException) as error:
        raise CandidateMetadataError(f"cannot read base xctestrun: {error}") from error
    configurations = document.get("TestConfigurations")
    if not isinstance(configurations, list):
        raise CandidateMetadataError("base xctestrun has no TestConfigurations")
    targets = [
        target
        for configuration in configurations
        if isinstance(configuration, dict)
        for target in configuration.get("TestTargets", [])
        if isinstance(target, dict) and target.get("IsUITestBundle") is True
    ]
    if len(targets) != 1:
        raise CandidateMetadataError(
            "base xctestrun must contain exactly one UI-test target; "
            f"found {len(targets)}"
        )
    target = targets[0]
    forbidden_selection_keys = {
        "OnlyTestIdentifiers",
        "SkipTestIdentifiers",
        "TestIdentifiersToRun",
        "TestIdentifiersToSkip",
    }
    present_filters = sorted(forbidden_selection_keys & set(target))
    if present_filters:
        raise CandidateMetadataError(
            "base xctestrun contains preexisting test-selection filters: "
            + ", ".join(present_filters)
        )
    for argument_field in ("CommandLineArguments", "UITargetAppCommandLineArguments"):
        arguments = target.get(argument_field, [])
        if not isinstance(arguments, list) or any(
            not isinstance(argument, str) for argument in arguments
        ):
            raise CandidateMetadataError(
                f"base xctestrun {argument_field} is malformed"
            )
        if arguments:
            raise CandidateMetadataError(
                f"base xctestrun contains preexisting {argument_field}"
            )
    for environment_field in (
        "EnvironmentVariables",
        "TestingEnvironmentVariables",
        "UITargetAppEnvironmentVariables",
    ):
        environment = target.get(environment_field, {})
        if not isinstance(environment, dict) or any(
            not isinstance(key, str) or not isinstance(value, str)
            for key, value in environment.items()
        ):
            raise CandidateMetadataError(
                f"base xctestrun {environment_field} is malformed"
            )
        forbidden = sorted(
            key
            for key, value in environment.items()
            if key.startswith("SWIFTVLC_") or "SWIFTVLC_" in value
        )
        if forbidden:
            raise CandidateMetadataError(
                "base xctestrun contains preexisting SwiftVLC control environment: "
                + ", ".join(forbidden)
            )
    runner = _resolve_xctestrun_product_path(
        target.get("TestHostPath"),
        xctestrun=xctestrun,
        description="TestHostPath",
    )
    bundle = _resolve_xctestrun_product_path(
        target.get("TestBundlePath"),
        xctestrun=xctestrun,
        test_host=runner,
        description="TestBundlePath",
    )
    app = _resolve_xctestrun_product_path(
        target.get("UITargetAppPath"),
        xctestrun=xctestrun,
        description="UITargetAppPath",
    )
    expected = {
        "TestHostPath": (runner, test_runner.resolve()),
        "TestBundlePath": (bundle, test_bundle.resolve()),
        "UITargetAppPath": (app, candidate_app.resolve()),
    }
    for field, (actual, wanted) in expected.items():
        if actual != wanted:
            raise CandidateMetadataError(
                f"base xctestrun {field} does not reference the exact hashed product: "
                f"{actual} != {wanted}"
            )
    dependent = target.get("DependentProductPaths")
    if not isinstance(dependent, list) or not dependent:
        raise CandidateMetadataError(
            "base xctestrun has no exact dependent product paths"
        )
    resolved_dependents = [
        _resolve_xctestrun_product_path(
            value,
            xctestrun=xctestrun,
            description="DependentProductPaths entry",
        )
        for value in dependent
    ]
    expected_dependents = {
        candidate_app.resolve(),
        test_runner.resolve(),
        test_bundle.resolve(),
    }
    if len(resolved_dependents) != len(expected_dependents) or set(
        resolved_dependents
    ) != expected_dependents:
        raise CandidateMetadataError(
            "base xctestrun dependent products do not exactly reference the hashed "
            "candidate, runner, and test bundle"
        )
    runner_identifier = app_bundle_identifier(test_runner, "signed UI-test runner")
    candidate_identifier = app_bundle_identifier(candidate_app, "candidate application")
    if target.get("TestHostBundleIdentifier") != runner_identifier:
        raise CandidateMetadataError(
            "base xctestrun TestHostBundleIdentifier does not match the signed runner"
        )
    target_identifier = target.get("UITargetAppBundleIdentifier")
    if target_identifier is not None and target_identifier != candidate_identifier:
        raise CandidateMetadataError(
            "base xctestrun UITargetAppBundleIdentifier does not match the candidate"
        )


def command_output(arguments: list[str]) -> str:
    try:
        return subprocess.run(
            arguments,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
    except subprocess.CalledProcessError as error:
        detail = error.stderr.strip() or error.stdout.strip() or str(error)
        raise CandidateMetadataError(detail) from error


def validate(
    metadata: dict,
    version: str,
    app_digest: str,
    artifact_digest: str,
) -> dict:
    required = {
        "version": version,
        "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
        "candidateAppDigestAlgorithm": "swiftvlc-tree-v1",
        "candidateAppDigest": app_digest,
        "artifactDigestAlgorithm": "swiftvlc-tree-v1",
        "artifactDigest": artifact_digest,
    }
    if metadata.get("formatVersion") not in {1, 2}:
        raise CandidateMetadataError("candidate metadata formatVersion must be 1 or 2")
    for key, expected in required.items():
        if metadata.get(key) != expected:
            raise CandidateMetadataError(
                f"candidate metadata {key} mismatch: {metadata.get(key)!r} != {expected!r}"
            )
    if not SHA1.fullmatch(str(metadata.get("sourceCommit", ""))):
        raise CandidateMetadataError("candidate metadata has no valid sourceCommit")
    if not SHA256.fullmatch(str(metadata.get("releaseSourceDigest", ""))):
        raise CandidateMetadataError(
            "candidate metadata has no valid releaseSourceDigest"
        )
    if metadata.get("formatVersion") == 2 or "candidateAppBundleIdentifier" in metadata:
        validated_bundle_identifier(
            metadata.get("candidateAppBundleIdentifier"),
            "candidate metadata",
        )
    if metadata.get("formatVersion") == 2:
        try:
            policy.validate_candidate_identity(metadata, strict=True)
        except policy.QualificationPolicyError as error:
            raise CandidateMetadataError(str(error)) from error
    return metadata


def source_identity(source_root: Path, version: str) -> dict:
    source_digest_script = source_root / "scripts" / "release-source-digest.py"
    dirty = command_output(
        [
            "git",
            "-C",
            str(source_root),
            "status",
            "--porcelain",
            "--untracked-files=normal",
        ]
    )
    if dirty:
        raise CandidateMetadataError(
            "candidate metadata requires a clean committed source checkout"
        )
    return {
        "sourceCommit": command_output(
            ["git", "-C", str(source_root), "rev-parse", "HEAD"]
        ),
        "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
        "releaseSourceDigest": command_output(
            [
                "python3",
                str(source_digest_script),
                version,
                "--root",
                str(source_root),
            ]
        ),
    }


def create(
    app: Path,
    xcframework: Path,
    version: str,
    digest_script: Path,
    bindings: dict | None = None,
    build_attestation: dict | None = None,
) -> dict:
    try:
        with (app / "Info.plist").open("rb") as source:
            info = plistlib.load(source)
    except (OSError, plistlib.InvalidFileException) as error:
        raise CandidateMetadataError(
            f"cannot read candidate Info.plist: {error}"
        ) from error
    app_digest = command_output(["python3", str(digest_script), str(app)])
    artifact_digest = command_output(["python3", str(digest_script), str(xcframework)])
    embedded_artifact_digest = info.get("SwiftVLCArtifactDigest")
    if embedded_artifact_digest != artifact_digest:
        raise CandidateMetadataError(
            "candidate embedded artifact digest mismatch: "
            f"{embedded_artifact_digest!r} != {artifact_digest!r}"
        )
    if bindings is not None and build_attestation is None:
        raise CandidateMetadataError(
            "strict candidate metadata requires a verified candidate build attestation; "
            "Info.plist identity stamps alone are not accepted"
        )
    attestation_bindings: dict = {}
    if build_attestation is not None:
        try:
            attestation = policy.validate_candidate_build_attestation(
                build_attestation
            )
        except policy.QualificationPolicyError as error:
            raise CandidateMetadataError(str(error)) from error
        if attestation["version"] != version:
            raise CandidateMetadataError(
                "candidate build attestation version does not match --version"
            )
        if info.get("SwiftVLCCandidateVersion") != version:
            raise CandidateMetadataError(
                "candidate signed SwiftVLCCandidateVersion does not match --version"
            )
        if (
            info.get("SwiftVLCCandidateRuntimeBinding")
            != attestation["candidateRuntimeBinding"]
        ):
            raise CandidateMetadataError(
                "candidate signed runtime binding does not match the verified "
                "build attestation"
            )
        for field, embedded_field in (
            ("sourceCommit", "SwiftVLCSourceCommit"),
            ("releaseSourceDigest", "SwiftVLCReleaseSourceDigest"),
            ("artifactDigest", "SwiftVLCArtifactDigest"),
        ):
            if info.get(embedded_field) != attestation[field]:
                raise CandidateMetadataError(
                    f"candidate embedded {field} does not match the verified build "
                    "attestation"
                )
        if attestation["artifactDigest"] != artifact_digest:
            raise CandidateMetadataError(
                "candidate build attestation artifact digest does not match the "
                "candidate artifact"
            )
        attestation_bindings = {
            "candidateBuildAttestation": attestation,
            "candidateBuildAttestationDigestAlgorithm": "sha256",
            "candidateBuildAttestationDigest": hashlib.sha256(
                policy.canonical_json_bytes(attestation)
            ).hexdigest(),
        }
    metadata = {
        "formatVersion": 2 if bindings is not None else 1,
        "version": version,
        **(
            {"candidateRuntimeBinding": build_attestation["candidateRuntimeBinding"]}
            if build_attestation is not None
            else {}
        ),
        "candidateAppBundleIdentifier": validated_bundle_identifier(
            info.get("CFBundleIdentifier"), "candidate application"
        ),
        "sourceCommit": (
            build_attestation["sourceCommit"]
            if build_attestation is not None
            else info.get("SwiftVLCSourceCommit")
        ),
        "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
        "releaseSourceDigest": (
            build_attestation["releaseSourceDigest"]
            if build_attestation is not None
            else info.get("SwiftVLCReleaseSourceDigest")
        ),
        "candidateAppDigestAlgorithm": "swiftvlc-tree-v1",
        "candidateAppDigest": app_digest,
        "artifactDigestAlgorithm": "swiftvlc-tree-v1",
        "artifactDigest": embedded_artifact_digest,
        **attestation_bindings,
        **(bindings or {}),
    }
    return validate(metadata, version, app_digest, artifact_digest)


def verify(
    metadata: dict,
    app: Path,
    xcframework: Path,
    version: str,
    digest_script: Path,
    bindings: dict | None = None,
) -> dict:
    embedded = create(
        app,
        xcframework,
        version,
        digest_script,
        bindings,
        metadata.get("candidateBuildAttestation"),
    )
    validated = validate(
        metadata,
        version,
        embedded["candidateAppDigest"],
        embedded["artifactDigest"],
    )
    compared_fields = ["sourceCommit", "releaseSourceDigest"]
    if "candidateAppBundleIdentifier" in validated:
        compared_fields.append("candidateAppBundleIdentifier")
    for field in compared_fields:
        if validated.get(field) != embedded[field]:
            raise CandidateMetadataError(
                f"candidate metadata {field} does not match the signed app: "
                f"{validated.get(field)!r} != {embedded[field]!r}"
            )
    if bindings is not None and validated != embedded:
        differing = sorted(
            field
            for field in set(validated) | set(embedded)
            if validated.get(field) != embedded.get(field)
        )
        raise CandidateMetadataError(
            "candidate metadata does not match recomputed signed runner provenance: "
            + ", ".join(differing)
        )
    return validated


def qualification_bindings(
    *,
    candidate_app: Path,
    test_runner: Path,
    test_bundle: Path,
    xctestrun: Path,
    test_catalog: Path,
    test_catalog_authority: Path,
    matrix: Path,
    feature_manifest: Path,
    profiles: Path,
    fixture_manifest: Path,
    digest_script: Path,
) -> dict:
    runner = test_runner.resolve()
    bundle = test_bundle.resolve()
    try:
        bundle_relative = bundle.relative_to(runner).as_posix()
    except ValueError as error:
        raise CandidateMetadataError(
            "embedded test bundle is not inside the signed UI-test runner"
        ) from error
    if not runner.is_dir() or not bundle.is_dir():
        raise CandidateMetadataError(
            "signed UI-test runner or embedded test bundle is missing"
        )
    if not xctestrun.is_file() or xctestrun.suffix != ".xctestrun":
        raise CandidateMetadataError(
            "selected base xctestrun is missing or does not end in .xctestrun"
        )
    validate_xctestrun_products(
        xctestrun,
        candidate_app=candidate_app,
        test_runner=runner,
        test_bundle=bundle,
    )
    try:
        catalog = policy.load_json(test_catalog, "XCTest catalog")
        canonical_catalog = policy.catalog_record(catalog.get("testIdentifiers", []))
        catalog_authority = policy.load_json(
            test_catalog_authority, "reviewed XCTest catalog authority"
        )
    except policy.QualificationPolicyError as error:
        raise CandidateMetadataError(str(error)) from error
    if catalog != canonical_catalog:
        raise CandidateMetadataError("XCTest catalog is not canonical")
    expected_catalog_authority = {
        "formatVersion": 1,
        "authority": "swiftvlc-reviewed-ios-test-catalog-v1",
        "testCatalogDigestAlgorithm": "swiftvlc-test-catalog-v1",
        "testCatalogDigest": canonical_catalog["digest"],
        "testCatalogCount": canonical_catalog["testCount"],
        "testIdentifiers": canonical_catalog["testIdentifiers"],
    }
    if catalog_authority != expected_catalog_authority:
        raise CandidateMetadataError(
            "enumerated XCTest catalog does not exactly match the reviewed authority"
        )
    try:
        for document, description in (
            (matrix, "qualification matrix"),
            (feature_manifest, "feature manifest"),
            (profiles, "qualification profiles"),
            (fixture_manifest, "fixture manifest"),
        ):
            policy.load_json(document, description)
        loaded_matrix = policy.load_json(matrix, "qualification matrix")
        policy.validate_release_matrix_contract(loaded_matrix)
    except policy.QualificationPolicyError as error:
        raise CandidateMetadataError(str(error)) from error
    return {
        "testRunnerBundleIdentifier": app_bundle_identifier(
            runner, "signed UI-test runner"
        ),
        "testRunnerDigestAlgorithm": "swiftvlc-tree-v1",
        "testRunnerDigest": command_output(
            ["python3", str(digest_script), str(runner)]
        ),
        "testBundleRelativePath": bundle_relative,
        "testBundleDigestAlgorithm": "swiftvlc-tree-v1",
        "testBundleDigest": command_output(
            ["python3", str(digest_script), str(bundle)]
        ),
        "baseXCTestRunDigestAlgorithm": "sha256",
        "baseXCTestRunDigest": policy.sha256_file(xctestrun),
        "baseXCTestRunName": xctestrun.name,
        "testCatalogDigestAlgorithm": "swiftvlc-test-catalog-v1",
        "testCatalogDigest": canonical_catalog["digest"],
        "testCatalogCount": canonical_catalog["testCount"],
        "testCatalog": canonical_catalog["testIdentifiers"],
        "testCatalogAuthorityDigestAlgorithm": "sha256",
        "testCatalogAuthorityDigest": policy.sha256_file(test_catalog_authority),
        "qualificationMatrixChecksum": policy.sha256_file(matrix),
        "featureManifestChecksum": policy.sha256_file(feature_manifest),
        "qualificationProfilesChecksum": policy.sha256_file(profiles),
        "fixtureManifestChecksum": policy.sha256_file(fixture_manifest),
        "qualificationPolicyDigestAlgorithm": "swiftvlc-qualification-policy-v1",
        "qualificationPolicyDigest": policy.policy_digest(),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    create_parser = subparsers.add_parser("create")
    create_parser.add_argument("--candidate-app", type=Path, required=True)
    create_parser.add_argument("--xcframework", type=Path, required=True)
    create_parser.add_argument("--version", required=True)
    create_parser.add_argument("--digest-script", type=Path, required=True)
    create_parser.add_argument("--output", type=Path, required=True)
    create_parser.add_argument("--build-attestation", type=Path, required=True)

    source_parser = subparsers.add_parser("source")
    source_parser.add_argument("--source-root", type=Path, required=True)
    source_parser.add_argument("--version", required=True)

    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--candidate-app", type=Path, required=True)
    verify_parser.add_argument("--xcframework", type=Path, required=True)
    verify_parser.add_argument("--metadata", type=Path, required=True)
    verify_parser.add_argument("--version", required=True)
    verify_parser.add_argument("--digest-script", type=Path, required=True)

    for operation_parser in (create_parser, verify_parser):
        operation_parser.add_argument("--test-runner", type=Path, required=True)
        operation_parser.add_argument("--test-bundle", type=Path, required=True)
        operation_parser.add_argument("--xctestrun", type=Path, required=True)
        operation_parser.add_argument("--test-catalog", type=Path, required=True)
        operation_parser.add_argument(
            "--test-catalog-authority", type=Path, required=True
        )
        operation_parser.add_argument("--matrix", type=Path, required=True)
        operation_parser.add_argument("--feature-manifest", type=Path, required=True)
        operation_parser.add_argument("--profiles", type=Path, required=True)
        operation_parser.add_argument("--fixture-manifest", type=Path, required=True)

    args = parser.parse_args()
    try:
        if args.command == "create":
            build_attestation = policy.load_json(
                args.build_attestation, "candidate build attestation"
            )
            bindings = qualification_bindings(
                candidate_app=args.candidate_app,
                test_runner=args.test_runner,
                test_bundle=args.test_bundle,
                xctestrun=args.xctestrun,
                test_catalog=args.test_catalog,
                test_catalog_authority=args.test_catalog_authority,
                matrix=args.matrix,
                feature_manifest=args.feature_manifest,
                profiles=args.profiles,
                fixture_manifest=args.fixture_manifest,
                digest_script=args.digest_script,
            )
            metadata = create(
                args.candidate_app,
                args.xcframework,
                args.version,
                args.digest_script,
                bindings,
                build_attestation,
            )
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(
                json.dumps(metadata, indent=2, sort_keys=True) + "\n"
            )
        elif args.command == "source":
            metadata = source_identity(args.source_root.resolve(), args.version)
        else:
            bindings = qualification_bindings(
                candidate_app=args.candidate_app,
                test_runner=args.test_runner,
                test_bundle=args.test_bundle,
                xctestrun=args.xctestrun,
                test_catalog=args.test_catalog,
                test_catalog_authority=args.test_catalog_authority,
                matrix=args.matrix,
                feature_manifest=args.feature_manifest,
                profiles=args.profiles,
                fixture_manifest=args.fixture_manifest,
                digest_script=args.digest_script,
            )
            metadata = verify(
                policy.load_json(args.metadata, "candidate metadata"),
                args.candidate_app,
                args.xcframework,
                args.version,
                args.digest_script,
                bindings,
            )
    except (
        CandidateMetadataError,
        policy.QualificationPolicyError,
        OSError,
        json.JSONDecodeError,
    ) as error:
        parser.error(str(error))
    print(json.dumps(metadata, sort_keys=True))


if __name__ == "__main__":
    main()
