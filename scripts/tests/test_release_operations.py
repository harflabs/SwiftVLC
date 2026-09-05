import importlib.util
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), ROOT / name)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runner = load("release-runner.py")
reuse = load("native-reuse.py")
status = load("release-status.py")


class ReleaseOperationsTests(unittest.TestCase):
    def test_phase_log_retains_original_failure_and_elapsed_time(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            code = runner.run([sys.executable, "-u", "-c",
                               "print('Release phase: upload'); print('fixture failure'); raise SystemExit(7)"],
                              root, 5, 2)
            record = json.loads((root / "phases.json").read_text())
            self.assertEqual(code, 7)
            self.assertEqual(record["outcome"], "failed")
            self.assertEqual(record["phases"][-1]["name"], "upload")
            self.assertGreater(record["durationSeconds"], 0)
            self.assertIn("fixture failure", (root / "output.log").read_text())

    def test_idle_timeout_is_bounded_and_recorded(self):
        with tempfile.TemporaryDirectory() as directory:
            code = runner.run([sys.executable, "-c", "import time; time.sleep(30)"], Path(directory), 7, 1)
            record = json.loads((Path(directory) / "phases.json").read_text())
            self.assertEqual(code, 124)
            self.assertEqual(record["outcome"], "timed-out")
            self.assertLess(record["durationSeconds"], 6)

    def test_non_newline_progress_counts_as_activity_but_wall_limit_remains(self):
        with tempfile.TemporaryDirectory() as directory:
            code = runner.run([sys.executable, "-u", "-c",
                               "import time\nwhile True: print('.', end='', flush=True); time.sleep(.03)"],
                              Path(directory), 3, 2)
            record = json.loads((Path(directory) / "phases.json").read_text())
            self.assertEqual(code, 124)
            self.assertGreaterEqual(record["durationSeconds"], 3)

    def test_termination_signal_stops_child_and_retains_interruption(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pidfile = root / "child.pid"
            child = f"import os,time; open({str(pidfile)!r}, 'w').write(str(os.getpid())); time.sleep(30)"
            code = (f"import runpy,sys; from pathlib import Path; "
                    f"m=runpy.run_path({str(ROOT / 'release-runner.py')!r}); "
                    f"sys.exit(m['run']([sys.executable, '-c', {child!r}], Path({directory!r}), 5, 4))")
            proc = subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 10
                while not pidfile.exists() and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertTrue(pidfile.exists())
                child_pid = int(pidfile.read_text())
                proc.send_signal(signal.SIGTERM)
                self.assertEqual(proc.wait(timeout=10), 143)
                with self.assertRaises(ProcessLookupError):
                    os.kill(child_pid, 0)
                record = json.loads((root / "phases.json").read_text())
                self.assertEqual(record["outcome"], "interrupted")
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()

    def test_status_uses_only_reads_and_reports_all_local_blockers(self):
        commands = []
        def response(args, **kwargs):
            commands.append(args)
            if args[:3] == ("git", "branch", "--show-current"):
                return "feature\n"
            if args[:3] == ("git", "status", "--porcelain"):
                return " M file\n"
            if args[:3] == ("gh", "pr", "list"):
                return "[]"
            return "fixture"
        with tempfile.TemporaryDirectory() as directory, patch.object(status.subprocess, "check_output", side_effect=response):
            report = status.inspect(Path(directory), "1.1.0-beta.11")
        self.assertEqual(len(report["blockers"]), 3)
        for args in commands:
            self.assertIn(args[:2], (("git", "rev-parse"), ("git", "branch"), ("git", "status"),
                                     ("git", "ls-remote"), ("gh", "auth"), ("gh", "pr")))

    def test_reuse_accepts_swift_only_change_and_rejects_native_or_unknown_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.DEVNULL, text=True).strip()
            git("init", "-q")
            git("config", "user.name", "Fixture")
            git("config", "user.email", "fixture@example.invalid")
            (root / "base").write_text("base")
            git("add", "."); git("commit", "-qm", "base")
            base = git("rev-parse", "HEAD")
            swift = root / "Sources/SwiftVLC/Test.swift"
            swift.parent.mkdir(parents=True)
            swift.write_text("// Swift-only change")
            git("add", "."); git("commit", "-qm", "Swift")
            self.assertEqual(reuse.verify(root, base), base)
            for name in ("Sources/CLibVLC/shim.c", "scripts/patches/0001.patch", "unknown-build-input"):
                file = root / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text("changed")
                git("add", "."); git("commit", "-qm", "native")
                with self.subTest(name=name), self.assertRaisesRegex(ValueError, "requires a rebuild"):
                    reuse.verify(root, base)
                git("reset", "--hard", "HEAD^")

    def test_reuse_rejects_native_input_renamed_to_documentation(self):
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
            with self.assertRaisesRegex(ValueError, "Sources/CLibVLC/shim.h"):
                reuse.verify(root, base)

    def test_reuse_does_not_accept_short_revision(self):
        with self.assertRaises(ValueError):
            reuse.verify(ROOT.parent, "HEAD")
