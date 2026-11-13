import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("native_changes", SCRIPTS / "native-changes.py")
CHANGES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHANGES)


class NativeIntegrationTests(unittest.TestCase):
    def test_changed_native_inputs_require_compilation(self):
        for path in ("Tests/SwiftVLCTests/Player/PausedSeekPlaybackTests.swift",
                     "Tests/SwiftVLCTests/Player/RemoteMP4SeekTests.swift",
                     "Tests/SwiftVLCTests/Fixtures/paused-seek.mp4",
                     "Sources/CLibVLC/shim.h", "scripts/patches/old.patch", "Package.swift",
                     "scripts/build-libvlc.sh", "scripts/validate-libvlc-extensions.sh",
                     "scripts/native-validator-assets.sha256", "scripts/artifact-tree-digest.py",
                     "scripts/ci/check-rtsp.py", "scripts/ci/rtsp-playback-probe.c",
                     "scripts/ci/rtsp_transport.py", ".github/workflows/test.yml",
                     "scripts/ci/tests/test_rtsp_transport.py"):
            with self.subTest(path=path):
                self.assertTrue(CHANGES.needs_build([path]))
        # The detector and its tests are exercised here, by the lint job. An
        # engine build proves nothing about either.
        self.assertFalse(CHANGES.needs_build([
            "Sources/SwiftVLC/Player.swift", "README.md",
            "scripts/ci/native-changes.py", "scripts/ci/tests/test_native_integration.py"]))

    WORKFLOW = """\
name: Tests
on:
  pull_request:
    branches: [main]
permissions:
  contents: read
jobs:
  # Decides whether the compiled lane runs.
  native-changes:
    runs-on: ubuntu-latest
    steps:
      - run: python3 -B scripts/ci/native-changes.py
  native-build:
    needs: native-changes
    timeout-minutes: 200
    steps:
      # Build the engine.
      - run: ./scripts/build-libvlc.sh --clean-build --macos-only
  lint:
    runs-on: macos-26
    steps:
      - run: swiftlint lint --strict
"""

    def test_workflow_edits_outside_the_native_lane_are_not_native_changes(self):
        base = self.WORKFLOW
        for label, head in (
            ("comment", base.replace("# Build the engine.", "# Compile the patched engine.")),
            ("added comment and blank line", base.replace("  lint:", "\n  # Style gate.\n  lint:")),
            ("another job", base.replace("swiftlint lint --strict", "swiftlint lint --strict --quiet")),
            ("new job", base + "  docs:\n    runs-on: macos-26\n    steps:\n      - run: true\n"),
        ):
            with self.subTest(label):
                self.assertNotEqual(base, head)
                self.assertFalse(CHANGES.workflow_lane_changed(base, head))

    def test_workflow_edits_to_the_native_lane_are_native_changes(self):
        base = self.WORKFLOW
        for label, head in (
            ("build step", base.replace("--macos-only", "--all")),
            ("build timeout", base.replace("timeout-minutes: 200", "timeout-minutes: 210")),
            ("detector step", base.replace("python3 -B scripts", "python3 scripts")),
            ("trigger", base.replace("branches: [main]", "branches: [main, next]")),
            ("permissions", base.replace("contents: read", "contents: write")),
            ("lane job removed", base.replace("  native-build:", "  renamed-build:")),
            ("top-level key after jobs", base + "env:\n  CI: 'true'\n"),
            ("no jobs", "name: Tests\n"),
            ("missing file", ""),
        ):
            with self.subTest(label):
                self.assertTrue(CHANGES.workflow_lane_changed(base, head))
                self.assertTrue(CHANGES.workflow_lane_changed(head, base))

    def test_pull_request_selects_the_lane_from_the_workflow_definition(self):
        def build_output(head):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                def git(*args):
                    return subprocess.check_output(["git", "-C", directory, *args],
                                                   stderr=subprocess.DEVNULL, text=True).strip()
                git("init", "-q")
                git("config", "user.name", "Fixture")
                git("config", "user.email", "fixture@example.invalid")
                workflow = root / ".github/workflows/test.yml"
                workflow.parent.mkdir(parents=True)
                workflow.write_text(self.WORKFLOW)
                git("add", ".")
                git("commit", "-qm", "base")
                base = git("rev-parse", "HEAD")
                workflow.write_text(head)
                (root / "README.md").write_text("prose\n")
                git("add", ".")
                git("commit", "-qm", "head")
                output = root / "output"
                environment = dict(os.environ, FORCE_NATIVE="false", CANDIDATE="false",
                                   EVENT="pull_request", BASE_SHA=base, GITHUB_OUTPUT=str(output))
                subprocess.run([sys.executable, str(SCRIPTS / "native-changes.py")],
                               cwd=root, env=environment, check=True, capture_output=True)
                return output.read_text()
        self.assertEqual(build_output(self.WORKFLOW.replace("swiftlint lint", "swiftlint  lint")),
                         "build=false\n")
        self.assertEqual(build_output(self.WORKFLOW.replace("--macos-only", "--all")),
                         "build=true\n")

    def test_renaming_native_input_to_docs_still_requires_compilation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", "-C", directory, *args],
                                               stderr=subprocess.DEVNULL, text=True).strip()
            git("init", "-q")
            git("config", "user.name", "Fixture")
            git("config", "user.email", "fixture@example.invalid")
            git("config", "diff.renames", "true")
            native = root / "Sources/CLibVLC/shim.h"
            native.parent.mkdir(parents=True)
            native.write_text("native input\n")
            git("add", ".")
            git("commit", "-qm", "base")
            base = git("rev-parse", "HEAD")
            native.rename(root / "README.md")
            git("add", ".")
            git("commit", "-qm", "rename")
            output = root / "output"
            environment = dict(os.environ, FORCE_NATIVE="false", CANDIDATE="false",
                               EVENT="pull_request", BASE_SHA=base, GITHUB_OUTPUT=str(output))
            subprocess.run([sys.executable, str(SCRIPTS / "native-changes.py")],
                           cwd=root, env=environment, check=True, capture_output=True)
            self.assertEqual(output.read_text(), "build=true\n")

    def test_local_engine_binding_requires_artifact_and_single_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "Package.swift"
            original = '.binaryTarget(name: "libvlc", url: "https://example.invalid/engine.zip", checksum: "abc")'
            manifest.write_text(original)
            def bind():
                return subprocess.run([sys.executable, str(SCRIPTS / "use-local-native.py")],
                                      cwd=root, capture_output=True).returncode
            self.assertNotEqual(bind(), 0)
            self.assertEqual(manifest.read_text(), original)
            artifact = root / "Vendor/libvlc.xcframework/Info.plist"
            artifact.parent.mkdir(parents=True)
            artifact.write_text("fixture")
            self.assertEqual(bind(), 0)
            self.assertIn('path: "Vendor/libvlc.xcframework"', manifest.read_text())
            manifest.write_text(original + original)
            self.assertNotEqual(bind(), 0)
            self.assertEqual(manifest.read_text(), original + original)
