import importlib.util
import os
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("engine_coverage", Path(__file__).parents[1] / "engine-coverage.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class EngineCoverageTests(unittest.TestCase):
    def test_changed_existing_patch_is_not_reported_as_covered(self):
        self.assertEqual(MODULE.patch_changes(
            {"0001.patch": "old", "0002.patch": "removed"},
            {"0001.patch": "new", "0003.patch": "added"},
        ), {"added": ["0003.patch"], "removed": ["0002.patch"], "modified": ["0001.patch"]})

    def test_identical_contents_have_no_divergence(self):
        self.assertFalse(any(MODULE.patch_changes({"p": "hash"}, {"p": "hash"}).values()))

    def test_candidate_advisory_never_requests_draft_access(self):
        with patch.dict(os.environ, {"SWIFTVLC_RELEASE_CANDIDATE_LINT": "1"}), patch.object(MODULE, "run") as run, patch.object(MODULE, "emit") as emit:
            MODULE.main()
            run.assert_not_called()
            self.assertEqual(emit.call_args.args[0], "candidate")

    def test_unavailable_metadata_is_explicitly_unknown(self):
        with patch.dict(os.environ, {"SWIFTVLC_RELEASE_CANDIDATE_LINT": ""}), patch.object(MODULE, "run", side_effect=subprocess.CalledProcessError(1, "resolver")), patch.object(MODULE, "emit") as emit:
            MODULE.main()
            self.assertEqual(emit.call_args.args[0], "unknown")
