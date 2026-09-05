import importlib.util
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
        for path in ("Sources/CLibVLC/shim.h", "scripts/patches/old.patch", "Package.swift",
                     "scripts/build-libvlc.sh", "scripts/validate-libvlc-extensions.sh",
                     "scripts/native-validator-assets.sha256", "scripts/artifact-tree-digest.py"):
            with self.subTest(path=path):
                self.assertTrue(CHANGES.needs_build([path]))
        self.assertFalse(CHANGES.needs_build(["Sources/SwiftVLC/Player.swift", "README.md"]))

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
