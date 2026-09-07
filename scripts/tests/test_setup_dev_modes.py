import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SetupDevModesTests(unittest.TestCase):
    def test_atomic_local_transforms_preserve_modes_and_are_idempotent(self):
        script = (ROOT / 'scripts/setup-dev.sh').read_text()
        for function, relative in (
            ('switch_package_to_local_path', 'Package.swift'),
            ('switch_showcase_to_local_package', 'Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj'),
        ):
            section = script.split(function + '() {', 1)[1]
            program = re.search(r"<<'PYEOF'\n(.*?)\nPYEOF", section, re.S).group(1)
            for mode in (0o644, 0o640):
                with self.subTest(function=function, mode=oct(mode)), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    path = root / relative
                    path.parent.mkdir(parents=True, exist_ok=True)
                    original = (ROOT / relative).read_bytes()
                    path.write_bytes(original)
                    path.chmod(mode)
                    environment = dict(os.environ, SHOWCASE_PROJECT=str(path))
                    subprocess.run([sys.executable, '-c', program], cwd=root, env=environment, check=True)
                    changed = path.read_bytes()
                    self.assertNotEqual(changed, original)
                    self.assertEqual(stat.S_IMODE(path.stat().st_mode), mode)
                    subprocess.run([sys.executable, '-c', program], cwd=root, env=environment, check=True)
                    self.assertEqual(path.read_bytes(), changed)
                    self.assertEqual(stat.S_IMODE(path.stat().st_mode), mode)
