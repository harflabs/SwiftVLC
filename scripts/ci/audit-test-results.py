#!/usr/bin/env python3
"""Fail CI when the headless SwiftPM run is broad but behaviorally hollow.

SwiftVLC intentionally disables tests that require a hosted video/audio output
when CI=true. xUnit makes that debt visible, while this gate additionally
requires the small set of high-value contracts that *can* run headlessly to
have passed. A source-level budget prevents adding another blanket playback
skip without changing this reviewed contract.
"""

from __future__ import annotations

import argparse
import html
import json
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

PLAYBACK_GATE = re.compile(
    r"\.enabled\s*\(\s*if\s*:\s*TestCondition\.canPlayMedia\b",
    re.MULTILINE,
)
TEST_DECLARATION = re.compile(r"^\s*@Test\b", re.MULTILINE)
XUNIT_OUTCOME_TAGS = frozenset({"failure", "error", "skipped"})
XUNIT_TESTCASE_ATTRIBUTES = frozenset({"classname", "name", "time"})
XUNIT_TESTCASE_CHILD_TAGS = frozenset(
    {*XUNIT_OUTCOME_TAGS, "properties", "system-out", "system-err"}
)
CONTRACT_KEYS = frozenset(
    {
        "minimum_reported_tests",
        "minimum_passed_tests",
        "minimum_source_test_declarations",
        "counting_assumptions",
        "maximum_uncontracted_reported_skips",
        "maximum_declared_playback_gates",
        "reviewed_conditional_skips",
        "required_suites",
    }
)
CONDITIONAL_SKIP_KEYS = frozenset({"classname", "name", "skip_reason", "reason"})
REQUIRED_SUITE_KEYS = frozenset({"classname", "minimum_passed", "reason"})


@dataclass(frozen=True)
class TestCase:
    label: str
    classname: str
    name: str
    status: str
    skip_reason: str | None
    skip_reason_error: str | None
    outcome_error: str | None


def local_name(tag: str) -> str:
    """Remove an optional ElementTree namespace from an XML tag."""

    return tag.rsplit("}", 1)[-1]


def normalize_skip_reason(value: str) -> str:
    """Normalize xUnit formatting whitespace without weakening case matching."""

    return " ".join(value.split())


def strict_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON object key: {key}")
        value[key] = item
    return value


def reject_json_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON constant is not allowed: {value}")


def strict_json_loads(value: str) -> Any:
    return json.loads(
        value,
        object_pairs_hook=strict_json_object,
        parse_constant=reject_json_constant,
    )


def require_exact_object(value: Any, keys: frozenset[str], label: str) -> None:
    if type(value) is not dict:
        raise TypeError(f"{label} must be an object")
    missing = sorted(keys - value.keys())
    unknown = sorted(value.keys() - keys)
    if missing or unknown:
        details = []
        if missing:
            details.append(f"missing keys: {', '.join(missing)}")
        if unknown:
            details.append(f"unknown keys: {', '.join(unknown)}")
        raise ValueError(f"{label} has invalid schema ({'; '.join(details)})")


def require_integer(value: Any, label: str, *, minimum: int) -> None:
    if type(value) is not int:
        raise TypeError(f"{label} must be an integer")
    if value < minimum:
        raise ValueError(f"{label} must be at least {minimum}")


def require_nonempty_string(value: Any, label: str) -> None:
    if type(value) is not str:
        raise TypeError(f"{label} must be a string")
    if not value.strip():
        raise ValueError(f"{label} must not be empty")


def require_array(value: Any, label: str, *, nonempty: bool) -> None:
    if type(value) is not list:
        raise TypeError(f"{label} must be an array")
    if nonempty and not value:
        raise ValueError(f"{label} must not be empty")


def validate_contract(config: Any) -> None:
    require_exact_object(config, CONTRACT_KEYS, "contract")
    for key in (
        "minimum_reported_tests",
        "minimum_passed_tests",
        "minimum_source_test_declarations",
    ):
        require_integer(config[key], key, minimum=1)
    for key in (
        "maximum_uncontracted_reported_skips",
        "maximum_declared_playback_gates",
    ):
        require_integer(config[key], key, minimum=0)

    assumptions = config["counting_assumptions"]
    require_array(assumptions, "counting_assumptions", nonempty=True)
    for index, assumption in enumerate(assumptions):
        require_nonempty_string(assumption, f"counting_assumptions[{index}]")

    conditional_skips = config["reviewed_conditional_skips"]
    require_array(
        conditional_skips,
        "reviewed_conditional_skips",
        nonempty=False,
    )
    conditional_identities: set[tuple[str, str]] = set()
    for index, conditional_skip in enumerate(conditional_skips):
        label = f"reviewed_conditional_skips[{index}]"
        require_exact_object(conditional_skip, CONDITIONAL_SKIP_KEYS, label)
        for key in sorted(CONDITIONAL_SKIP_KEYS):
            require_nonempty_string(conditional_skip[key], f"{label}.{key}")
        identity = (
            conditional_skip["classname"].strip(),
            conditional_skip["name"].strip(),
        )
        if identity in conditional_identities:
            raise ValueError(
                "duplicate reviewed conditional skip identity: "
                f"{identity[0]} / {identity[1]}"
            )
        conditional_identities.add(identity)

    required_suites = config["required_suites"]
    require_array(required_suites, "required_suites", nonempty=True)
    required_classnames: set[str] = set()
    for index, required_suite in enumerate(required_suites):
        label = f"required_suites[{index}]"
        require_exact_object(required_suite, REQUIRED_SUITE_KEYS, label)
        require_nonempty_string(required_suite["classname"], f"{label}.classname")
        require_integer(
            required_suite["minimum_passed"],
            f"{label}.minimum_passed",
            minimum=1,
        )
        require_nonempty_string(required_suite["reason"], f"{label}.reason")
        classname = required_suite["classname"].strip()
        if classname in required_classnames:
            raise ValueError(f"duplicate required suite classname: {classname}")
        required_classnames.add(classname)


def xunit_skip_reason(element: ET.Element) -> tuple[str | None, str | None]:
    skipped = [child for child in element if local_name(child.tag) == "skipped"]
    if not skipped:
        return None, None
    if len(skipped) != 1:
        return None, f"has {len(skipped)} <skipped> elements"

    child = skipped[0]
    candidates = []
    message = normalize_skip_reason(child.attrib.get("message", ""))
    text = normalize_skip_reason("".join(child.itertext()))
    if message:
        candidates.append(message)
    if text:
        candidates.append(text)
    unique = set(candidates)
    if len(unique) > 1:
        return None, "has conflicting <skipped> message and text reasons"
    return (candidates[0] if candidates else None), None


def xunit_outcome(element: ET.Element) -> tuple[str, str | None]:
    """Classify the calibrated Swift xUnit testcase vocabulary fail-closed."""

    direct_children = list(element)
    direct_child_names = [local_name(child.tag) for child in direct_children]
    direct_outcomes = [
        child
        for child in direct_children
        if local_name(child.tag) in XUNIT_OUTCOME_TAGS
    ]
    direct_outcome_names = [local_name(child.tag) for child in direct_outcomes]
    direct_child_ids = {id(child) for child in direct_children}
    nested_outcome_names = [
        local_name(descendant.tag)
        for descendant in element.iter()
        if descendant is not element
        and id(descendant) not in direct_child_ids
        and local_name(descendant.tag) in XUNIT_OUTCOME_TAGS
    ]
    unsupported_attributes = [
        local_name(attribute)
        for attribute in element.attrib
        if local_name(attribute) not in XUNIT_TESTCASE_ATTRIBUTES
    ]
    unsupported_direct_children = [
        name for name in direct_child_names if name not in XUNIT_TESTCASE_CHILD_TAGS
    ]
    invalid_nested_children: list[str] = []
    for child in direct_children:
        child_name = local_name(child.tag)
        nested_children = list(child)
        if child_name == "properties":
            for nested_child in nested_children:
                nested_name = local_name(nested_child.tag)
                if nested_name != "property":
                    invalid_nested_children.append(
                        f"<properties> contains unsupported <{nested_name}>"
                    )
                elif list(nested_child):
                    invalid_nested_children.append(
                        "<property> contains nested elements"
                    )
        elif nested_children:
            invalid_nested_children.append(f"<{child_name}> must be text-only")

    problems: list[str] = []
    if unsupported_attributes:
        formatted = ", ".join(repr(name) for name in unsupported_attributes)
        problems.append(f"uses unsupported testcase attributes: {formatted}")
    if unsupported_direct_children:
        formatted = ", ".join(f"<{name}>" for name in unsupported_direct_children)
        problems.append(f"uses unsupported direct testcase children: {formatted}")
    problems.extend(invalid_nested_children)
    if nested_outcome_names:
        formatted = ", ".join(f"<{name}>" for name in nested_outcome_names)
        problems.append(f"has nested outcome elements: {formatted}")
    if len(direct_outcomes) > 1:
        formatted = ", ".join(f"<{name}>" for name in direct_outcome_names)
        problems.append(f"has conflicting direct outcome elements: {formatted}")

    if "failure" in direct_outcome_names or "error" in direct_outcome_names:
        status = "failed"
    elif "skipped" in direct_outcome_names:
        status = "skipped"
    else:
        status = "passed"
    return status, "; ".join(problems) if problems else None


def xunit_cases(root: ET.Element) -> list[TestCase]:
    """Return every xUnit testcase with enough ancestry for suite matching."""

    cases: list[TestCase] = []

    def visit(element: ET.Element, suites: tuple[str, ...]) -> None:
        kind = local_name(element.tag)
        if kind == "testsuite":
            name = element.attrib.get("name", "").strip()
            if name:
                suites = (*suites, name)
        if kind == "testcase":
            classname = element.attrib.get("classname", "").strip()
            name = element.attrib.get("name", "").strip()
            parts = [
                *suites,
                classname,
                name,
            ]
            label = " / ".join(part.strip() for part in parts if part.strip())
            status, outcome_error = xunit_outcome(element)
            skip_reason, skip_reason_error = xunit_skip_reason(element)
            cases.append(
                TestCase(
                    label=label,
                    classname=classname,
                    name=name,
                    status=status,
                    skip_reason=skip_reason,
                    skip_reason_error=skip_reason_error,
                    outcome_error=outcome_error,
                )
            )
            return
        for child in element:
            visit(child, suites)

    visit(root, ())
    return cases


def swift_sources(root: Path) -> Iterable[Path]:
    return sorted(path for path in root.rglob("*.swift") if path.is_file())


def source_inventory(root: Path) -> tuple[int, list[dict[str, Any]]]:
    declarations = 0
    gates: list[dict[str, Any]] = []
    for path in swift_sources(root):
        text = path.read_text(encoding="utf-8")
        declarations += len(TEST_DECLARATION.findall(text))
        for match in PLAYBACK_GATE.finditer(text):
            gates.append(
                {
                    "path": str(path),
                    "line": text.count("\n", 0, match.start()) + 1,
                }
            )
    return declarations, gates


def evaluate(
    cases: list[TestCase],
    config: dict[str, Any],
    declarations: int,
    gates: list[dict[str, Any]],
) -> tuple[dict[str, Any], list[str]]:
    validate_contract(config)
    counts = {
        status: sum(case.status == status for case in cases)
        for status in ("passed", "skipped", "failed")
    }
    required: list[dict[str, Any]] = []
    errors: list[str] = []

    reported = len(cases)
    minimum_reported = config["minimum_reported_tests"]
    minimum_passed = config["minimum_passed_tests"]
    minimum_declarations = config["minimum_source_test_declarations"]
    counting_assumptions = list(config["counting_assumptions"])
    maximum_uncontracted_skips = config["maximum_uncontracted_reported_skips"]
    maximum_gates = config["maximum_declared_playback_gates"]

    malformed = [case.label for case in cases if not case.classname or not case.name]
    malformed_outcomes = [
        f"{case.label}: {case.outcome_error}"
        for case in cases
        if case.outcome_error is not None
    ]
    identities: dict[tuple[str, str], int] = {}
    for case in cases:
        identity = (case.classname, case.name)
        identities[identity] = identities.get(identity, 0) + 1
    duplicates = sorted(
        f"{classname} / {name}"
        for (classname, name), count in identities.items()
        if count > 1
    )

    conditional_skips: list[dict[str, Any]] = []
    conditional_identities: set[tuple[str, str]] = set()
    for contract in config["reviewed_conditional_skips"]:
        classname = contract["classname"].strip()
        name = contract["name"].strip()
        expected_skip_reason = normalize_skip_reason(contract["skip_reason"])
        reason = contract["reason"].strip()
        identity = (classname, name)
        if identity in conditional_identities:
            raise ValueError(
                f"duplicate reviewed conditional skip identity: {classname} / {name}"
            )
        conditional_identities.add(identity)
        matches = [case for case in cases if (case.classname, case.name) == identity]
        status = matches[0].status if len(matches) == 1 else "missing-or-duplicate"
        observed_skip_reason = matches[0].skip_reason if len(matches) == 1 else None
        skip_reason_error = matches[0].skip_reason_error if len(matches) == 1 else None
        outcome_error = matches[0].outcome_error if len(matches) == 1 else None
        allowance_active = (
            len(matches) == 1
            and status == "skipped"
            and outcome_error is None
            and skip_reason_error is None
            and observed_skip_reason == expected_skip_reason
        )
        conditional_skips.append(
            {
                "classname": classname,
                "name": name,
                "expected_skip_reason": expected_skip_reason,
                "observed_skip_reason": observed_skip_reason,
                "skip_reason_error": skip_reason_error,
                "outcome_error": outcome_error,
                "reason": reason,
                "reported": len(matches),
                "status": status,
                "allowance_active": allowance_active,
            }
        )
        if len(matches) != 1:
            errors.append(
                f"reviewed conditional skip {classname} / {name} was reported "
                f"{len(matches)} times; contract requires exactly once"
            )
        elif status == "skipped" and skip_reason_error is not None:
            errors.append(
                f"reviewed conditional skip {classname} / {name} "
                f"{skip_reason_error}"
            )
        elif status == "skipped" and observed_skip_reason != expected_skip_reason:
            errors.append(
                f"reviewed conditional skip {classname} / {name} reports skip "
                f"reason {observed_skip_reason!r}; expected {expected_skip_reason!r}"
            )

    contracted_skipped_identities = {
        (contract["classname"], contract["name"])
        for contract in conditional_skips
        if contract["allowance_active"]
    }
    uncontracted_skipped_cases = [
        case
        for case in cases
        if case.status == "skipped"
        and (case.classname, case.name) not in contracted_skipped_identities
    ]
    dynamic_skip_budget = maximum_uncontracted_skips + len(
        contracted_skipped_identities
    )

    if reported < minimum_reported:
        errors.append(
            f"xUnit reported {reported} tests; contract requires at least {minimum_reported}"
        )
    if counts["passed"] < minimum_passed:
        errors.append(
            f"xUnit reported {counts['passed']} passing tests; contract requires at least {minimum_passed}"
        )
    if declarations < minimum_declarations:
        errors.append(
            f"source declares {declarations} @Test functions; contract requires at least {minimum_declarations}"
        )
    if counts["failed"]:
        errors.append(f"xUnit contains {counts['failed']} failed tests")
    if len(uncontracted_skipped_cases) > maximum_uncontracted_skips:
        errors.append(
            f"xUnit reports {len(uncontracted_skipped_cases)} uncontracted skipped "
            f"tests; reviewed budget is {maximum_uncontracted_skips} "
            f"({counts['skipped']} total, "
            f"{len(contracted_skipped_identities)} exact conditional)"
        )
    if len(gates) > maximum_gates:
        errors.append(
            f"source declares {len(gates)} canPlayMedia gates; reviewed budget is {maximum_gates}"
        )
    if malformed:
        errors.append(
            f"xUnit contains {len(malformed)} test cases without exact class/name identity"
        )
    if malformed_outcomes:
        errors.append(
            f"xUnit contains {len(malformed_outcomes)} test cases with malformed outcomes"
        )
    if duplicates:
        errors.append(
            f"xUnit contains {len(duplicates)} duplicate class/name identities"
        )

    for contract in config["required_suites"]:
        classname = contract["classname"].strip()
        matches = [case for case in cases if case.classname == classname]
        passed = sum(case.status == "passed" for case in matches)
        skipped = sum(case.status == "skipped" for case in matches)
        failed = sum(case.status == "failed" for case in matches)
        minimum = contract["minimum_passed"]
        result = {
            "classname": classname,
            "reason": contract["reason"].strip(),
            "reported": len(matches),
            "passed": passed,
            "skipped": skipped,
            "failed": failed,
            "minimum_passed": minimum,
        }
        required.append(result)
        if passed < minimum:
            errors.append(
                f"{classname} has {passed} passing tests (reported={len(matches)}, "
                f"skipped={skipped}, failed={failed}); contract requires {minimum}"
            )

    report = {
        "reported": reported,
        **counts,
        "source_test_declarations": declarations,
        "source_test_declaration_minimum": minimum_declarations,
        "counting_assumptions": counting_assumptions,
        "reported_skip_budget": dynamic_skip_budget,
        "uncontracted_skipped": len(uncontracted_skipped_cases),
        "uncontracted_skip_budget": maximum_uncontracted_skips,
        "conditional_skipped": len(contracted_skipped_identities),
        "reviewed_conditional_skips": conditional_skips,
        "declared_playback_gates": len(gates),
        "playback_gate_budget": maximum_gates,
        "required_suites": required,
        "skipped_tests": [case.label for case in cases if case.status == "skipped"],
        "uncontracted_skipped_tests": [
            case.label for case in uncontracted_skipped_cases
        ],
        "failed_tests": [case.label for case in cases if case.status == "failed"],
        "malformed_test_identities": malformed,
        "malformed_test_outcomes": malformed_outcomes,
        "duplicate_test_identities": duplicates,
        "playback_gate_locations": gates,
        "errors": errors,
    }
    return report, errors


def markdown_text(value: object) -> str:
    return (
        html.escape(str(value), quote=False)
        .replace("`", "&#96;")
        .replace("\r\n", "<br>")
        .replace("\r", "<br>")
        .replace("\n", "<br>")
    )


def markdown_table_cell(value: object) -> str:
    return markdown_text(value).replace("|", "&#124;")


def markdown_code(value: object) -> str:
    escaped = (
        html.escape(str(value), quote=False)
        .replace("|", "&#124;")
        .replace("\r\n", "<br>")
        .replace("\r", "<br>")
        .replace("\n", "<br>")
    )
    return f"<code>{escaped}</code>"


def markdown_summary(report: dict[str, Any]) -> str:
    if report.get("execution") == "not-run":
        return "## SwiftPM behavior-contract accounting\n\n**NOT RUN** — " + report["reason"] + "\n"
    verdict = "PASS" if not report["errors"] else "FAIL"
    lines = [
        "## SwiftPM behavior-contract accounting",
        "",
        f"**{verdict}** — line coverage is not used as the behavioral oracle.",
        "",
        "| Reported | Passed | Skipped total | Uncontracted / ceiling | Exact conditional | Failed | Source `@Test` / floor | Playback gates / budget |",
        "|---:|---:|---:|---:|---:|---:|---:|---:|",
        (
            f"| {report['reported']} | {report['passed']} | "
            f"{report['skipped']} | {report['uncontracted_skipped']} / "
            f"{report['uncontracted_skip_budget']} | "
            f"{report['conditional_skipped']} | {report['failed']} | "
            f"{report['source_test_declarations']} / "
            f"{report['source_test_declaration_minimum']} | "
            f"{report['declared_playback_gates']} / {report['playback_gate_budget']} |"
        ),
        "",
        "### Counting assumptions",
        "",
        *[f"- {assumption}" for assumption in report["counting_assumptions"]],
        "",
        "### Required headless contracts",
        "",
        "| Suite marker | Passed | Skipped | Failed | Required | Boundary |",
        "|---|---:|---:|---:|---:|---|",
    ]
    for suite in report["required_suites"]:
        lines.append(
            f"| {markdown_code(suite['classname'])} | {suite['passed']} | "
            f"{suite['skipped']} | {suite['failed']} | {suite['minimum_passed']} | "
            f"{markdown_table_cell(suite['reason'])} |"
        )

    conditional_skips = report["reviewed_conditional_skips"]
    if conditional_skips:
        lines.extend(
            [
                "",
                "### Reviewed conditional skips",
                "",
                "| Exact identity | Status | Allowance active | Required skip reason | Conditional boundary |",
                "|---|---|---|---|---|",
            ]
        )
        for contract in conditional_skips:
            identity = f"{contract['classname']} / {contract['name']}"
            lines.append(
                f"| {markdown_code(identity)} | {contract['status']} | "
                f"{'yes' if contract['allowance_active'] else 'no'} | "
                f"{markdown_table_cell(contract['expected_skip_reason'])} | "
                f"{markdown_table_cell(contract['reason'])} |"
            )

    if report["errors"]:
        lines.extend(["", "### Gate failures", ""])
        lines.extend(f"- {markdown_text(error)}" for error in report["errors"])

    skipped = report["skipped_tests"]
    lines.extend(
        [
            "",
            f"<details><summary>Skipped tests ({len(skipped)})</summary>",
            "",
            *[f"- {markdown_code(label)}" for label in skipped],
            "",
            "</details>",
            "",
        ]
    )
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--xunit", type=Path, required=True)
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--test-source-root", type=Path, required=True)
    parser.add_argument("--json-output", type=Path, required=True)
    parser.add_argument("--github-summary", type=Path)
    parser.add_argument("--test-step-outcome", choices=("success", "failure", "cancelled", "skipped"))
    return parser.parse_args()


def emit_report(args: argparse.Namespace, report: dict[str, Any]) -> None:
    args.json_output.parent.mkdir(parents=True, exist_ok=True)
    args.json_output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    summary = markdown_summary(report)
    print(summary)
    if args.github_summary:
        args.github_summary.parent.mkdir(parents=True, exist_ok=True)
        with args.github_summary.open("a", encoding="utf-8") as output:
            output.write(summary)


def main() -> int:
    args = parse_args()
    if not args.xunit.exists() and args.test_step_outcome in {"skipped", "cancelled"}:
        emit_report(args, {
            "execution": "not-run",
            "reason": "The test step did not execute. Check the preceding setup or cancellation result; no passing-test evidence was produced.",
        })
        return 0  # Keep the setup/cancellation failure as the primary cause.
    try:
        config = strict_json_loads(args.contract.read_text(encoding="utf-8"))
        root = ET.parse(args.xunit).getroot()
        cases = xunit_cases(root)
        declarations, gates = source_inventory(args.test_source_root)
        report, errors = evaluate(cases, config, declarations, gates)
    except (OSError, ET.ParseError, KeyError, TypeError, ValueError) as error:
        message = f"test-accounting error: {error}"
        print(message, file=sys.stderr)
        report = {
            "reported": 0,
            "passed": 0,
            "skipped": 0,
            "failed": 0,
            "source_test_declarations": 0,
            "source_test_declaration_minimum": "unavailable",
            "counting_assumptions": [
                "Unavailable because the contract could not be evaluated."
            ],
            "reported_skip_budget": "unavailable",
            "uncontracted_skipped": 0,
            "uncontracted_skip_budget": "unavailable",
            "conditional_skipped": 0,
            "reviewed_conditional_skips": [],
            "declared_playback_gates": 0,
            "playback_gate_budget": "unavailable",
            "required_suites": [],
            "skipped_tests": [],
            "uncontracted_skipped_tests": [],
            "failed_tests": [],
            "malformed_test_identities": [],
            "malformed_test_outcomes": [],
            "duplicate_test_identities": [],
            "playback_gate_locations": [],
            "errors": [message],
        }
        emit_report(args, report)
        return 2

    emit_report(args, report)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
