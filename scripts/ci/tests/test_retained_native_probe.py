import importlib.util
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "retained_probe", Path(__file__).resolve().parents[1] / "check-retained-native-probe.py")
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class RetainedNativeProbeTests(unittest.TestCase):
    def test_uses_compiled_merge_revision_instead_of_branch_head(self):
        branch = "a" * 40
        compiled = "b" * 40
        log = f"Branch head: {branch}\n[info] [0m00s] SwiftVLC source provenance: {compiled}\n"
        self.assertEqual(PROBE.source_revision(log), compiled)

    def test_accepts_repeated_evidence_only_when_revision_agrees(self):
        record = "SwiftVLC source provenance: " + "c" * 40 + "\n"
        self.assertEqual(PROBE.source_revision(record * 2), "c" * 40)
        with self.assertRaises(ValueError):
            PROBE.source_revision(record + "SwiftVLC source provenance: " + "d" * 40)

    def test_rejects_missing_or_incomplete_source_identity(self):
        for log in ("", "SwiftVLC source provenance: HEAD", "SwiftVLC source provenance: " + "e" * 39,
                    "SwiftVLC source provenance: " + "e" * 41):
            with self.subTest(log=log), self.assertRaises(ValueError):
                PROBE.source_revision(log)
