from __future__ import annotations

import importlib.util
import sys
import tempfile
import argparse
from unittest.mock import patch
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

SCRIPT = Path(__file__).parents[1] / "audit-test-results.py"
REPOSITORY = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("audit_test_results", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
AUDIT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = AUDIT
SPEC.loader.exec_module(AUDIT)


class AuditTestResultsTests(unittest.TestCase):
    def test_missing_report_after_setup_failure_is_not_run(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            args = argparse.Namespace(xunit=root / "missing.xml", test_step_outcome="skipped",
                                      json_output=root / "report.json", github_summary=None)
            with patch.object(AUDIT, "parse_args", return_value=args):
                self.assertEqual(AUDIT.main(), 0)
            self.assertIn('"execution": "not-run"', args.json_output.read_text())

    def test_missing_report_after_test_execution_fails_closed(self):
        for outcome in ("success", "failure"):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                contract = root / "contract.json"
                contract.write_text("{}")
                args = argparse.Namespace(xunit=root / "missing.xml", test_step_outcome=outcome,
                                          contract=contract, json_output=root / "report.json", github_summary=None)
                with patch.object(AUDIT, "parse_args", return_value=args):
                    self.assertEqual(AUDIT.main(), 2)
                self.assertNotIn('"execution": "not-run"', args.json_output.read_text())

    def config(self, **overrides):
        value = {
            "minimum_reported_tests": 2,
            "minimum_passed_tests": 1,
            "minimum_source_test_declarations": 2,
            "counting_assumptions": [
                "xUnit fixture count",
                "lexical source declaration count",
            ],
            "maximum_uncontracted_reported_skips": 1,
            "maximum_declared_playback_gates": 1,
            "reviewed_conditional_skips": [],
            "required_suites": [
                {
                    "classname": "SwiftVLCTests.Integration.DecodedFrameHarnessTests",
                    "minimum_passed": 1,
                    "reason": "real decode",
                }
            ],
        }
        value.update(overrides)
        return value

    def cases(self, xml: str):
        return AUDIT.xunit_cases(ET.fromstring(xml))

    def contract_cases(self):
        return self.cases("""
            <testsuite name="DecodedFrameHarnessTests">
              <testcase classname="SwiftVLCTests.Integration.DecodedFrameHarnessTests"
                        name="real decode" />
              <testcase classname="SwiftVLCTests.Integration.OtherTests"
                        name="another" />
            </testsuite>
            """)

    def assert_contract_rejected(self, config, expected_error: str):
        with self.assertRaises((TypeError, ValueError)) as raised:
            AUDIT.evaluate(
                self.contract_cases(),
                config,
                declarations=2,
                gates=[],
            )
        self.assertIn(expected_error, str(raised.exception))

    def test_counts_pass_skip_failure_and_suite_ancestry(self):
        cases = self.cases("""
            <testsuites>
              <testsuite name="SwiftVLCTests">
                <testsuite name="DecodedFrameHarnessTests">
                  <testcase classname="SwiftVLCTests.Integration.DecodedFrameHarnessTests"
                            name="real decode" />
                  <testcase classname="SwiftVLCTests.Integration.DecodedFrameHarnessTests"
                            name="conditional"><skipped /></testcase>
                </testsuite>
              </testsuite>
            </testsuites>
            """)
        report, errors = AUDIT.evaluate(
            cases,
            self.config(),
            declarations=2,
            gates=[{"path": "Example.swift", "line": 3}],
        )

        self.assertEqual(errors, [])
        self.assertEqual(report["reported"], 2)
        self.assertEqual(report["passed"], 1)
        self.assertEqual(report["skipped"], 1)
        self.assertEqual(report["required_suites"][0]["passed"], 1)

    def test_required_suite_cannot_be_satisfied_by_a_skip(self):
        cases = self.cases("""
            <testsuite name="DecodedFrameHarnessTests">
              <testcase classname="SwiftVLCTests.Integration.DecodedFrameHarnessTests"
                        name="real decode"><skipped /></testcase>
              <testcase classname="SwiftVLCTests.Integration.DecodedFrameHarnessTests"
                        name="another"><skipped /></testcase>
            </testsuite>
            """)
        report, errors = AUDIT.evaluate(cases, self.config(), declarations=2, gates=[])

        self.assertTrue(errors)
        self.assertEqual(report["required_suites"][0]["passed"], 0)
        self.assertIn("contract requires 1", errors[-1])

    def test_source_inventory_counts_multiline_gate_and_locations(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "Example.swift"
            source.write_text(
                """
                @Test
                func example() {}
                @Test(
                  .enabled(
                    if: TestCondition.canPlayMedia
                  )
                )
                func playback() {}
                """,
                encoding="utf-8",
            )

            declarations, gates = AUDIT.source_inventory(Path(directory))

        self.assertEqual(declarations, 2)
        self.assertEqual(len(gates), 1)
        self.assertEqual(gates[0]["path"], str(source))

    def test_new_playback_gate_exceeding_budget_fails(self):
        cases = self.cases("""
            <testsuite name="DecodedFrameHarnessTests">
              <testcase classname="SwiftVLCTests.Integration.DecodedFrameHarnessTests"
                        name="real decode" />
              <testcase classname="SwiftVLCTests.Integration.DecodedFrameHarnessTests"
                        name="another" />
            </testsuite>
            """)
        _, errors = AUDIT.evaluate(
            cases,
            self.config(maximum_declared_playback_gates=0),
            declarations=2,
            gates=[{"path": "Example.swift", "line": 1}],
        )

        self.assertTrue(any("reviewed budget is 0" in error for error in errors))

    def test_new_reported_skip_exceeding_budget_fails(self):
        cases = self.cases("""
            <testsuite name="DecodedFrameHarnessTests">
              <testcase classname="SwiftVLCTests.Integration.DecodedFrameHarnessTests"
                        name="real decode" />
              <testcase classname="SwiftVLCTests.Integration.DecodedFrameHarnessTests"
                        name="first skip"><skipped /></testcase>
              <testcase classname="SwiftVLCTests.Integration.DecodedFrameHarnessTests"
                        name="second skip"><skipped /></testcase>
            </testsuite>
            """)
        _, errors = AUDIT.evaluate(
            cases,
            self.config(
                minimum_reported_tests=3,
                maximum_uncontracted_reported_skips=1,
            ),
            declarations=3,
            gates=[],
        )

        self.assertTrue(any("reviewed budget is 1" in error for error in errors))

    def test_contract_rejects_coercible_numeric_types(self):
        numeric_keys = (
            "minimum_reported_tests",
            "minimum_passed_tests",
            "minimum_source_test_declarations",
            "maximum_uncontracted_reported_skips",
            "maximum_declared_playback_gates",
        )
        for key in numeric_keys:
            for invalid in (True, 1.5, "1"):
                with self.subTest(key=key, invalid=invalid):
                    self.assert_contract_rejected(
                        self.config(**{key: invalid}),
                        f"{key} must be an integer",
                    )

    def test_contract_rejects_disabled_floor_and_negative_ceiling(self):
        for key in (
            "minimum_reported_tests",
            "minimum_passed_tests",
            "minimum_source_test_declarations",
        ):
            for invalid in (0, -1):
                with self.subTest(key=key, invalid=invalid):
                    self.assert_contract_rejected(
                        self.config(**{key: invalid}),
                        f"{key} must be at least 1",
                    )
        for key in (
            "maximum_uncontracted_reported_skips",
            "maximum_declared_playback_gates",
        ):
            with self.subTest(key=key):
                self.assert_contract_rejected(
                    self.config(**{key: -1}),
                    f"{key} must be at least 0",
                )

    def test_contract_rejects_invalid_required_suite_minimum(self):
        for invalid in (False, 0, -1, 1.5, "1"):
            with self.subTest(invalid=invalid):
                suite = dict(self.config()["required_suites"][0])
                suite["minimum_passed"] = invalid
                expected = (
                    "must be an integer"
                    if type(invalid) is not int
                    else "must be at least 1"
                )
                self.assert_contract_rejected(
                    self.config(required_suites=[suite]),
                    expected,
                )

    def test_contract_rejects_unknown_missing_and_wrong_container_schema(self):
        unknown_top = self.config(typo_skip_budget=1000)
        self.assert_contract_rejected(unknown_top, "unknown keys: typo_skip_budget")

        missing_top = self.config()
        del missing_top["minimum_passed_tests"]
        self.assert_contract_rejected(
            missing_top,
            "missing keys: minimum_passed_tests",
        )

        for key in ("counting_assumptions", "reviewed_conditional_skips"):
            with self.subTest(key=key):
                self.assert_contract_rejected(
                    self.config(**{key: "not-an-array"}),
                    f"{key} must be an array",
                )
        self.assert_contract_rejected(
            self.config(required_suites={}),
            "required_suites must be an array",
        )
        self.assert_contract_rejected(
            self.config(required_suites=[]),
            "required_suites must not be empty",
        )
        self.assert_contract_rejected(
            self.config(reviewed_conditional_skips=["not-an-object"]),
            "reviewed_conditional_skips[0] must be an object",
        )
        self.assert_contract_rejected(
            self.config(required_suites=["not-an-object"]),
            "required_suites[0] must be an object",
        )

        conditional = {
            "classname": "NativeTests",
            "name": "v8",
            "skip_reason": "Requires v8",
            "reason": "native boundary",
            "typo": "accepted",
        }
        self.assert_contract_rejected(
            self.config(reviewed_conditional_skips=[conditional]),
            "unknown keys: typo",
        )
        suite = dict(self.config()["required_suites"][0])
        del suite["reason"]
        self.assert_contract_rejected(
            self.config(required_suites=[suite]),
            "missing keys: reason",
        )
        suite = dict(self.config()["required_suites"][0])
        suite["typo"] = "accepted"
        self.assert_contract_rejected(
            self.config(required_suites=[suite]),
            "unknown keys: typo",
        )

    def test_contract_rejects_empty_or_non_string_explanations(self):
        for invalid in ([], "", "   ", 1):
            with self.subTest(field="counting_assumptions", invalid=invalid):
                value = invalid if isinstance(invalid, list) else [invalid]
                self.assert_contract_rejected(
                    self.config(counting_assumptions=value),
                    "counting_assumptions",
                )

        conditional = {
            "classname": "NativeTests",
            "name": "v8",
            "skip_reason": "Requires v8",
            "reason": "native boundary",
        }
        for key in conditional:
            for invalid in ("", "   ", 1):
                with self.subTest(field=key, invalid=invalid):
                    mutated = dict(conditional)
                    mutated[key] = invalid
                    self.assert_contract_rejected(
                        self.config(reviewed_conditional_skips=[mutated]),
                        f"reviewed_conditional_skips[0].{key}",
                    )

        for key in ("classname", "reason"):
            for invalid in ("", "   ", 1):
                with self.subTest(field=f"required suite {key}", invalid=invalid):
                    suite = dict(self.config()["required_suites"][0])
                    suite[key] = invalid
                    self.assert_contract_rejected(
                        self.config(required_suites=[suite]),
                        f"required_suites[0].{key}",
                    )

    def test_contract_rejects_duplicate_policy_identities(self):
        conditional = {
            "classname": "NativeTests",
            "name": "v8",
            "skip_reason": "Requires v8",
            "reason": "native boundary",
        }
        self.assert_contract_rejected(
            self.config(reviewed_conditional_skips=[conditional, conditional]),
            "duplicate reviewed conditional skip identity",
        )

        suite = self.config()["required_suites"][0]
        self.assert_contract_rejected(
            self.config(required_suites=[suite, suite]),
            "duplicate required suite classname",
        )

    def test_contract_json_rejects_duplicate_keys_and_nonfinite_numbers(self):
        with self.assertRaisesRegex(ValueError, "duplicate JSON object key: floor"):
            AUDIT.strict_json_loads('{"floor": 1, "floor": 2}')
        for value in ("NaN", "Infinity", "-Infinity"):
            with self.subTest(value=value):
                with self.assertRaisesRegex(ValueError, "non-finite JSON constant"):
                    AUDIT.strict_json_loads(f'{{"floor": {value}}}')

    def test_exact_conditional_skip_does_not_consume_general_skip_budget(self):
        cases = self.cases("""
            <testsuite name="DecodedFrameHarnessTests">
              <testcase classname="SwiftVLCTests.Integration.DecodedFrameHarnessTests"
                        name="real decode" />
              <testcase classname="SwiftVLCTests.Integration.OtherTests"
                        name="ordinary skip"><skipped /></testcase>
              <testcase classname="SwiftVLCTests.Integration.NativeContractTests"
                        name="version eight"><skipped message="Requires version 8" /></testcase>
            </testsuite>
            """)
        contract = {
            "classname": "SwiftVLCTests.Integration.NativeContractTests",
            "name": "version eight",
            "skip_reason": "Requires version 8",
            "reason": "requires the rebuilt native artifact",
        }

        report, errors = AUDIT.evaluate(
            cases,
            self.config(
                minimum_reported_tests=3,
                reviewed_conditional_skips=[contract],
            ),
            declarations=3,
            gates=[],
        )

        self.assertEqual(errors, [])
        self.assertEqual(report["skipped"], 2)
        self.assertEqual(report["reported_skip_budget"], 2)
        self.assertEqual(report["uncontracted_skipped"], 1)
        self.assertEqual(report["reviewed_conditional_skips"][0]["status"], "skipped")

    def test_conditional_skip_allowance_disappears_when_exact_test_passes(self):
        cases = self.cases("""
            <testsuite name="DecodedFrameHarnessTests">
              <testcase classname="SwiftVLCTests.Integration.DecodedFrameHarnessTests"
                        name="real decode" />
              <testcase classname="SwiftVLCTests.Integration.NativeContractTests"
                        name="version eight" />
              <testcase classname="SwiftVLCTests.Integration.OtherTests"
                        name="first skip"><skipped /></testcase>
              <testcase classname="SwiftVLCTests.Integration.OtherTests"
                        name="replacement skip"><skipped /></testcase>
            </testsuite>
            """)
        contract = {
            "classname": "SwiftVLCTests.Integration.NativeContractTests",
            "name": "version eight",
            "skip_reason": "Requires version 8",
            "reason": "requires the rebuilt native artifact",
        }

        report, errors = AUDIT.evaluate(
            cases,
            self.config(
                minimum_reported_tests=4,
                reviewed_conditional_skips=[contract],
            ),
            declarations=4,
            gates=[],
        )

        self.assertTrue(
            any("2 uncontracted skipped tests" in error for error in errors)
        )
        self.assertEqual(report["reported_skip_budget"], 1)
        self.assertEqual(report["reviewed_conditional_skips"][0]["status"], "passed")

    def test_reciprocal_conditional_skips_preserve_budget_across_native_upgrade(self):
        version_eight_contract = {
            "classname": "SwiftVLCTests.Integration.NativeContractTests",
            "name": "version eight behavior",
            "skip_reason": "Requires version 8",
            "reason": "requires the rebuilt native artifact",
        }
        pre_version_eight_contract = {
            "classname": "SwiftVLCTests.Integration.NativeContractTests",
            "name": "pre-version-eight rejection",
            "skip_reason": "Current archive is already version 8",
            "reason": "applies only to the released native artifact",
        }
        transitions = (
            (
                "pre-version-eight",
                '<skipped message="Requires version 8" />',
                "",
                "version eight behavior",
            ),
            (
                "version-eight",
                "",
                '<skipped message="Current archive is already version 8" />',
                "pre-version-eight rejection",
            ),
        )

        for baseline, version_eight_result, pre_version_result, active_name in transitions:
            with self.subTest(baseline=baseline):
                cases = self.cases(f"""
                    <testsuite name="DecodedFrameHarnessTests">
                      <testcase classname="SwiftVLCTests.Integration.DecodedFrameHarnessTests"
                                name="real decode" />
                      <testcase classname="SwiftVLCTests.Integration.OtherTests"
                                name="ordinary skip"><skipped /></testcase>
                      <testcase classname="SwiftVLCTests.Integration.NativeContractTests"
                                name="version eight behavior">{version_eight_result}</testcase>
                      <testcase classname="SwiftVLCTests.Integration.NativeContractTests"
                                name="pre-version-eight rejection">{pre_version_result}</testcase>
                    </testsuite>
                    """)
                report, errors = AUDIT.evaluate(
                    cases,
                    self.config(
                        minimum_reported_tests=4,
                        reviewed_conditional_skips=[
                            version_eight_contract,
                            pre_version_eight_contract,
                        ],
                    ),
                    declarations=4,
                    gates=[],
                )

                self.assertEqual(errors, [])
                self.assertEqual(report["skipped"], 2)
                self.assertEqual(report["uncontracted_skipped"], 1)
                self.assertEqual(report["reported_skip_budget"], 2)
                active = [
                    contract["name"]
                    for contract in report["reviewed_conditional_skips"]
                    if contract["allowance_active"]
                ]
                self.assertEqual(active, [active_name])

    def test_missing_conditional_skip_identity_fails_closed(self):
        cases = self.cases("""
            <testsuite name="DecodedFrameHarnessTests">
              <testcase classname="SwiftVLCTests.Integration.DecodedFrameHarnessTests"
                        name="real decode" />
              <testcase classname="SwiftVLCTests.Integration.OtherTests"
                        name="another" />
            </testsuite>
            """)
        contract = {
            "classname": "SwiftVLCTests.Integration.NativeContractTests",
            "name": "version eight",
            "skip_reason": "Requires version 8",
            "reason": "requires the rebuilt native artifact",
        }

        _, errors = AUDIT.evaluate(
            cases,
            self.config(reviewed_conditional_skips=[contract]),
            declarations=2,
            gates=[],
        )

        self.assertTrue(
            any("contract requires exactly once" in error for error in errors)
        )

    def test_conditional_skip_reason_is_exact_and_fail_closed(self):
        contract = {
            "classname": "SwiftVLCTests.Integration.NativeContractTests",
            "name": "version eight",
            "skip_reason": "Requires version 8",
            "reason": "requires the rebuilt native artifact",
        }
        rejected = (
            ("<skipped />", "reports skip reason None"),
            ('<skipped message="requires version 8" />', "requires version 8"),
            (
                '<skipped message="Requires version 8">different reason</skipped>',
                "conflicting <skipped> message and text reasons",
            ),
        )

        for skipped, expected_error in rejected:
            with self.subTest(skipped=skipped):
                cases = self.cases(f"""
                    <testsuite name="DecodedFrameHarnessTests">
                      <testcase classname="SwiftVLCTests.Integration.DecodedFrameHarnessTests"
                                name="real decode" />
                      <testcase classname="SwiftVLCTests.Integration.NativeContractTests"
                                name="version eight">{skipped}</testcase>
                    </testsuite>
                    """)
                report, errors = AUDIT.evaluate(
                    cases,
                    self.config(reviewed_conditional_skips=[contract]),
                    declarations=2,
                    gates=[],
                )

                self.assertTrue(
                    any(expected_error in error for error in errors), errors
                )
                self.assertEqual(report["reported_skip_budget"], 1)
                self.assertFalse(
                    report["reviewed_conditional_skips"][0]["allowance_active"]
                )

    def test_malformed_xunit_outcome_encodings_fail_closed(self):
        contract = {
            "classname": "SwiftVLCTests.Integration.NativeContractTests",
            "name": "version eight",
            "skip_reason": "Requires version 8",
            "reason": "requires the rebuilt native artifact",
        }
        malformed = (
            (
                '<testcase classname="SwiftVLCTests.Integration.NativeContractTests" '
                'name="version eight" status="skipped" />',
                "unsupported testcase attributes: 'status'",
            ),
            (
                '<testcase classname="SwiftVLCTests.Integration.NativeContractTests" '
                'name="version eight" result="skipped" />',
                "unsupported testcase attributes: 'result'",
            ),
            (
                '<testcase classname="SwiftVLCTests.Integration.NativeContractTests" '
                'name="version eight" outcome="failed" />',
                "unsupported testcase attributes: 'outcome'",
            ),
            (
                '<testcase classname="SwiftVLCTests.Integration.NativeContractTests" '
                'name="version eight"><notrun>Requires version 8</notrun></testcase>',
                "unsupported direct testcase children: <notrun>",
            ),
            (
                '<testcase classname="SwiftVLCTests.Integration.NativeContractTests" '
                'name="version eight"><rerunFailure /></testcase>',
                "unsupported direct testcase children: <rerunFailure>",
            ),
            (
                '<testcase classname="SwiftVLCTests.Integration.NativeContractTests" '
                'name="version eight"><flakyFailure /></testcase>',
                "unsupported direct testcase children: <flakyFailure>",
            ),
            (
                '<testcase classname="SwiftVLCTests.Integration.NativeContractTests" '
                'name="version eight"><unknown /></testcase>',
                "unsupported direct testcase children: <unknown>",
            ),
            (
                '<testcase classname="SwiftVLCTests.Integration.NativeContractTests" '
                'name="version eight"><system-out><skipped>Requires version 8</skipped>'
                "</system-out></testcase>",
                "nested outcome elements: <skipped>",
            ),
            (
                '<testcase classname="SwiftVLCTests.Integration.NativeContractTests" '
                'name="version eight"><system-out><notrun /></system-out></testcase>',
                "<system-out> must be text-only",
            ),
            (
                '<testcase classname="SwiftVLCTests.Integration.NativeContractTests" '
                'name="version eight"><properties><flakyFailure /></properties>'
                "</testcase>",
                "<properties> contains unsupported <flakyFailure>",
            ),
        )

        for testcase, expected_error in malformed:
            with self.subTest(testcase=testcase):
                cases = self.cases(f"""
                    <testsuite name="DecodedFrameHarnessTests">
                      <testcase classname="SwiftVLCTests.Integration.DecodedFrameHarnessTests"
                                name="real decode" />
                      {testcase}
                    </testsuite>
                    """)
                report, errors = AUDIT.evaluate(
                    cases,
                    self.config(reviewed_conditional_skips=[contract]),
                    declarations=2,
                    gates=[],
                )

                self.assertTrue(
                    any("test cases with malformed outcomes" in error for error in errors)
                )
                self.assertTrue(
                    any(
                        expected_error in outcome
                        for outcome in report["malformed_test_outcomes"]
                    ),
                    report["malformed_test_outcomes"],
                )
                self.assertFalse(
                    report["reviewed_conditional_skips"][0]["allowance_active"]
                )

    def test_conflicting_direct_xunit_outcomes_fail_closed(self):
        conflicts = (
            "<failure /><skipped />",
            "<error /><skipped />",
            "<failure /><error />",
            "<skipped /><skipped />",
        )

        for outcomes in conflicts:
            with self.subTest(outcomes=outcomes):
                cases = self.cases(f"""
                    <testsuite name="DecodedFrameHarnessTests">
                      <testcase classname="SwiftVLCTests.Integration.DecodedFrameHarnessTests"
                                name="real decode" />
                      <testcase classname="SwiftVLCTests.Integration.OtherTests"
                                name="ambiguous">{outcomes}</testcase>
                    </testsuite>
                    """)
                report, errors = AUDIT.evaluate(
                    cases,
                    self.config(),
                    declarations=2,
                    gates=[],
                )

                self.assertTrue(errors)
                self.assertIn(
                    "conflicting direct outcome elements",
                    report["malformed_test_outcomes"][0],
                )

    def test_namespaced_direct_skip_remains_supported(self):
        cases = self.cases("""
            <j:testsuite xmlns:j="urn:junit" name="DecodedFrameHarnessTests">
              <j:testcase classname="SwiftVLCTests.Integration.DecodedFrameHarnessTests"
                          name="real decode" />
              <j:testcase classname="SwiftVLCTests.Integration.NativeContractTests"
                          name="version eight">
                <j:skipped>Requires version 8</j:skipped>
              </j:testcase>
            </j:testsuite>
            """)
        contract = {
            "classname": "SwiftVLCTests.Integration.NativeContractTests",
            "name": "version eight",
            "skip_reason": "Requires version 8",
            "reason": "requires the rebuilt native artifact",
        }

        report, errors = AUDIT.evaluate(
            cases,
            self.config(reviewed_conditional_skips=[contract]),
            declarations=2,
            gates=[],
        )

        self.assertEqual(errors, [])
        self.assertEqual(report["skipped"], 1)
        self.assertEqual(report["malformed_test_outcomes"], [])
        self.assertTrue(report["reviewed_conditional_skips"][0]["allowance_active"])

    def test_benign_xunit_testcase_metadata_children_remain_supported(self):
        cases = self.cases("""
            <testsuite name="DecodedFrameHarnessTests">
              <testcase classname="SwiftVLCTests.Integration.DecodedFrameHarnessTests"
                        name="real decode" time="0.01">
                <properties><property name="runner" value="swift-testing" /></properties>
                <system-out>diagnostic output</system-out>
                <system-err>diagnostic error output</system-err>
              </testcase>
              <testcase classname="SwiftVLCTests.Integration.OtherTests"
                        name="another" />
            </testsuite>
            """)

        report, errors = AUDIT.evaluate(
            cases,
            self.config(),
            declarations=2,
            gates=[],
        )

        self.assertEqual(errors, [])
        self.assertEqual(report["passed"], 2)
        self.assertEqual(report["malformed_test_outcomes"], [])

    def test_reported_minimum_fails_independently(self):
        cases = self.cases("""
            <testsuite name="DecodedFrameHarnessTests">
              <testcase classname="SwiftVLCTests.Integration.DecodedFrameHarnessTests"
                        name="real decode" />
              <testcase classname="SwiftVLCTests.Integration.OtherTests"
                        name="another" />
            </testsuite>
            """)
        _, errors = AUDIT.evaluate(
            cases,
            self.config(minimum_reported_tests=3),
            declarations=2,
            gates=[],
        )

        self.assertEqual(len(errors), 1)
        self.assertIn("reported 2 tests", errors[0])

    def test_passed_minimum_fails_independently(self):
        cases = self.cases("""
            <testsuite name="DecodedFrameHarnessTests">
              <testcase classname="SwiftVLCTests.Integration.DecodedFrameHarnessTests"
                        name="real decode" />
              <testcase classname="SwiftVLCTests.Integration.OtherTests"
                        name="conditional"><skipped /></testcase>
            </testsuite>
            """)
        _, errors = AUDIT.evaluate(
            cases,
            self.config(minimum_passed_tests=2),
            declarations=2,
            gates=[],
        )

        self.assertEqual(len(errors), 1)
        self.assertIn("reported 1 passing tests", errors[0])

    def test_source_declaration_minimum_fails_independently(self):
        cases = self.cases("""
            <testsuite name="DecodedFrameHarnessTests">
              <testcase classname="SwiftVLCTests.Integration.DecodedFrameHarnessTests"
                        name="real decode" />
              <testcase classname="SwiftVLCTests.Integration.OtherTests"
                        name="another" />
            </testsuite>
            """)
        _, errors = AUDIT.evaluate(
            cases,
            self.config(minimum_source_test_declarations=3),
            declarations=2,
            gates=[],
        )

        self.assertEqual(len(errors), 1)
        self.assertIn("source declares 2 @Test functions", errors[0])

    def test_markdown_exposes_skip_budget_with_one_suite_separator(self):
        cases = self.cases("""
            <testsuite name="DecodedFrameHarnessTests">
              <testcase classname="SwiftVLCTests.Integration.DecodedFrameHarnessTests"
                        name="real decode" />
              <testcase classname="SwiftVLCTests.Integration.DecodedFrameHarnessTests"
                        name="conditional"><skipped /></testcase>
            </testsuite>
            """)
        report, errors = AUDIT.evaluate(cases, self.config(), declarations=2, gates=[])

        self.assertEqual(errors, [])
        summary = AUDIT.markdown_summary(report)
        self.assertIn("| Skipped total | Uncontracted / ceiling |", summary)
        self.assertIn("| 2 | 1 | 1 | 1 / 1 | 0 | 0 |", summary)
        self.assertEqual(summary.count("|---|---:|---:|---:|---:|---|"), 1)

    def test_markdown_escapes_swift_test_identity_metacharacters(self):
        cases = self.cases("""
            <testsuite name="DecodedFrameHarnessTests">
              <testcase classname="SwiftVLCTests.Integration.DecodedFrameHarnessTests"
                        name="real decode" />
              <testcase classname="SwiftVLCTests.Integration.Native|ContractTests"
                        name="`version eight`">
                <skipped>Requires version 8 | native</skipped>
              </testcase>
            </testsuite>
            """)
        contract = {
            "classname": "SwiftVLCTests.Integration.Native|ContractTests",
            "name": "`version eight`",
            "skip_reason": "Requires version 8 | native",
            "reason": "native | boundary",
        }
        report, errors = AUDIT.evaluate(
            cases,
            self.config(reviewed_conditional_skips=[contract]),
            declarations=2,
            gates=[],
        )

        self.assertEqual(errors, [])
        summary = AUDIT.markdown_summary(report)
        self.assertIn(
            "<code>SwiftVLCTests.Integration.Native&#124;ContractTests / "
            "`version eight`</code>",
            summary,
        )
        self.assertIn("Requires version 8 &#124; native", summary)
        self.assertIn("native &#124; boundary", summary)

    def test_required_suite_requires_exact_xunit_classname(self):
        cases = self.cases("""
            <testsuite name="OtherTests">
              <testcase classname="SwiftVLCTests.Integration.OtherTests"
                        name="mentions DecodedFrameHarnessTests" />
              <testcase classname="SwiftVLCTests.Integration.OtherTests"
                        name="another" />
            </testsuite>
            """)

        report, errors = AUDIT.evaluate(cases, self.config(), declarations=2, gates=[])

        self.assertTrue(errors)
        self.assertEqual(report["required_suites"][0]["reported"], 0)

    def test_duplicate_xunit_identity_cannot_inflate_contract_count(self):
        cases = self.cases("""
            <testsuite name="DecodedFrameHarnessTests">
              <testcase classname="SwiftVLCTests.Integration.DecodedFrameHarnessTests"
                        name="real decode" />
              <testcase classname="SwiftVLCTests.Integration.DecodedFrameHarnessTests"
                        name="real decode" />
            </testsuite>
            """)

        report, errors = AUDIT.evaluate(cases, self.config(), declarations=2, gates=[])

        self.assertTrue(any("duplicate class/name" in error for error in errors))
        self.assertEqual(len(report["duplicate_test_identities"]), 1)

    def test_missing_xunit_identity_fails_closed(self):
        cases = self.cases("""
            <testsuite name="DecodedFrameHarnessTests">
              <testcase name="real decode" />
              <testcase classname="SwiftVLCTests.Integration.DecodedFrameHarnessTests"
                        name="another" />
            </testsuite>
            """)

        report, errors = AUDIT.evaluate(cases, self.config(), declarations=2, gates=[])

        self.assertTrue(any("without exact class/name" in error for error in errors))
        self.assertEqual(len(report["malformed_test_identities"]), 1)

    def test_repository_contract_matches_declared_headless_debt(self):
        contract = AUDIT.strict_json_loads(
            (REPOSITORY / "scripts/ci/headless-test-contracts.json").read_text(
                encoding="utf-8"
            )
        )
        AUDIT.validate_contract(contract)
        declarations, gates = AUDIT.source_inventory(REPOSITORY / "Tests/SwiftVLCTests")
        all_test_source = "\n".join(
            path.read_text(encoding="utf-8")
            for path in AUDIT.swift_sources(REPOSITORY / "Tests/SwiftVLCTests")
        )

        self.assertGreaterEqual(
            declarations, contract["minimum_source_test_declarations"]
        )
        self.assertTrue(contract["counting_assumptions"])
        self.assertTrue(
            all(assumption.strip() for assumption in contract["counting_assumptions"])
        )
        self.assertLessEqual(len(gates), contract["maximum_declared_playback_gates"])
        for suite in contract["required_suites"]:
            self.assertIn(suite["classname"].rsplit(".", 1)[-1], all_test_source)


if __name__ == "__main__":
    unittest.main()
