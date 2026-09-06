import importlib.util
import tempfile
import unittest
from pathlib import Path

PATH = Path(__file__).resolve().parents[1] / "candidate-metadata.py"
SPEC = importlib.util.spec_from_file_location("candidate_paths", PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CandidatePathTests(unittest.TestCase):
    def test_literal_directory_characters_survive_direct_and_template_paths(self):
        for name in ("ordinary", "audit__literal", "audit$literal", "with spaces"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary) / name
                root.mkdir()
                runner = root / "Runner.app"
                runner.mkdir()
                for value in (str(runner), "__TESTROOT__/Runner.app"):
                    self.assertEqual(MODULE._resolve_xctestrun_product_path(
                        value, xctestrun=root / "tests.xctestrun", description="TestHostPath"
                    ), runner.resolve())

    def test_inserted_paths_are_not_interpreted_as_templates(self):
        with tempfile.TemporaryDirectory() as temporary:
            runner = Path(temporary) / "__TESTROOT__"
            bundle = runner / "Tests.xctest"
            bundle.mkdir(parents=True)
            self.assertEqual(MODULE._resolve_xctestrun_product_path(
                "__TESTHOST__/Tests.xctest", xctestrun=Path(temporary) / "tests.xctestrun",
                test_host=runner, description="TestBundlePath"
            ), bundle.resolve())

    def test_unresolved_placeholders_fail_even_if_a_matching_file_exists(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for token in ("__UNKNOWN__", "$(UNKNOWN)", "${UNKNOWN}"):
                (root / token).mkdir()
                with self.subTest(token=token), self.assertRaisesRegex(
                    MODULE.CandidateMetadataError, "unsupported path placeholder"
                ):
                    MODULE._resolve_xctestrun_product_path(
                        str(root / token), xctestrun=root / "tests.xctestrun", description="TestHostPath"
                    )

    def test_missing_host_and_missing_product_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            for value, message in (("__TESTHOST__/Tests.xctest", "without a test host"),
                                   ("__TESTROOT__/Missing.app", "does not resolve")):
                with self.subTest(value=value), self.assertRaisesRegex(MODULE.CandidateMetadataError, message):
                    MODULE._resolve_xctestrun_product_path(
                        value, xctestrun=Path(temporary) / "tests.xctestrun", description="TestHostPath"
                    )
