#!/usr/bin/env python3
"""Bound a release invocation and retain output plus a timed phase ledger."""

import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path


def run(command, directory, wall, idle):
    directory.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    activity = [started]
    phases = []
    report = {"startedAt": time.time(), "command": command, "outcome": "running", "phases": phases}
    ledger = directory / "phases.json"
    lock = threading.Lock()

    def save():
        temporary = ledger.with_suffix(".tmp")
        temporary.write_text(json.dumps(report, indent=2) + "\n")
        temporary.replace(ledger)

    def phase(name):
        elapsed = round(time.monotonic() - started, 3)
        if phases:
            phases[-1]["durationSeconds"] = round(elapsed - phases[-1]["startSeconds"], 3)
        phases.append({"name": name, "startSeconds": elapsed})
        save()

    phase("startup")
    environment = dict(os.environ, SWIFTVLC_RELEASE_SUPERVISED="1")
    proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            start_new_session=True, env=environment)

    def pump():
        pending = b""
        with (directory / "output.log").open("wb") as output:
            while chunk := os.read(proc.stdout.fileno(), 65536):
                with lock:
                    activity[0] = time.monotonic()
                    output.write(chunk)
                    output.flush()
                    pending += chunk
                    while b"\n" in pending:
                        line, pending = pending.split(b"\n", 1)
                        if line.startswith(b"Release phase: "):
                            phase(line.decode(errors="replace")[15:])
                    # Progress without newlines must not grow memory forever.
                    pending = pending[-65536:]
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()

    reader = threading.Thread(target=pump, daemon=True)
    reader.start()
    outcome = "running"
    code = None
    received_signal = [signal.SIGINT]

    def interrupted(signum, frame):
        received_signal[0] = signum
        raise KeyboardInterrupt()

    old_term = signal.signal(signal.SIGTERM, interrupted)

    def terminate():
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        # Reap remaining descendants even if the shell already exited.
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    try:
        while proc.poll() is None or reader.is_alive():
            time.sleep(0.05)
            with lock:
                quiet = time.monotonic() - activity[0]
            if time.monotonic() - started > wall or quiet > idle:
                outcome, code = "timed-out", 124
                terminate()
                break
    except KeyboardInterrupt:
        outcome, code = "interrupted", 128 + received_signal[0]
        terminate()
    finally:
        signal.signal(signal.SIGTERM, old_term)
        proc.wait()
        reader.join(timeout=5)
        proc.stdout.close()
        with lock:
            elapsed = round(time.monotonic() - started, 3)
            if code is None:
                code = proc.returncode if proc.returncode >= 0 else 128 - proc.returncode
                outcome = "success" if code == 0 else "failed"
            phases[-1]["durationSeconds"] = round(elapsed - phases[-1]["startSeconds"], 3)
            report.update(outcome=outcome, exitCode=code, durationSeconds=elapsed)
            save()
    print(f"Release {outcome}; phase timings and output: {directory}", flush=True)
    if outcome in {"timed-out", "interrupted"}:
        print("Remote publication may have completed. Inspect --status, then rerun the same phase to reconcile it.", file=sys.stderr)
    return code


def main():
    try:
        wall = float(os.environ.get("SWIFTVLC_RELEASE_WALL_SECONDS", "3600"))
        idle = float(os.environ.get("SWIFTVLC_RELEASE_IDLE_SECONDS", "600"))
        if not (0 < wall <= 86400 and 0 < idle <= wall):
            raise ValueError()
    except ValueError:
        print("Release timeouts must satisfy 0 < idle <= wall <= 86400 seconds.", file=sys.stderr)
        return 2
    directory = Path(tempfile.mkdtemp(prefix="swiftvlc-release-run-"))
    print(f"Release wall limit {wall:g}s, idle limit {idle:g}s; logs: {directory}", flush=True)
    return run(["bash", *sys.argv[1:]], directory, wall, idle)


if __name__ == "__main__":
    raise SystemExit(main())
