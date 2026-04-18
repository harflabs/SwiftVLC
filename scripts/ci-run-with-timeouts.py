#!/usr/bin/env python3
"""
Runs a command with two independent timeouts:

  - wall-clock:  maximum total runtime
  - idle:        maximum seconds without output

Either timeout kills the entire process group (SIGKILL) and exits non-zero.
Designed for CI safety so a hung swift test / swift build cannot burn
billing for hours.

Usage:
    ci-run-with-timeouts.py <wall_secs> <idle_secs> <cmd...>

Exit codes:
    124 — wall-clock timeout
    125 — idle timeout
    otherwise — the child's own exit code
"""

import os
import signal
import subprocess
import sys
import threading
import time


def main() -> int:
    if len(sys.argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2

    wall_secs = int(sys.argv[1])
    idle_secs = int(sys.argv[2])
    cmd = sys.argv[3:]

    print(
        f"[ci-run] wall_clock={wall_secs}s idle={idle_secs}s cmd={' '.join(cmd)}",
        flush=True,
    )

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        start_new_session=True,  # child is its own process group leader
    )

    last_output_at = time.monotonic()
    last_output_lock = threading.Lock()

    def pump_output() -> None:
        nonlocal last_output_at
        assert proc.stdout is not None
        for line in proc.stdout:
            with last_output_lock:
                last_output_at = time.monotonic()
            sys.stdout.write(line)
            sys.stdout.flush()

    reader = threading.Thread(target=pump_output, daemon=True)
    reader.start()

    started_at = time.monotonic()

    def kill_process_group(reason: str, exit_code: int) -> int:
        print(f"::error::{reason}", file=sys.stderr, flush=True)
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        return exit_code

    while proc.poll() is None:
        time.sleep(1)
        now = time.monotonic()
        with last_output_lock:
            idle_for = now - last_output_at
        wall_for = now - started_at

        if wall_for > wall_secs:
            return kill_process_group(
                f"Wall-clock timeout: command ran for {int(wall_for)}s "
                f"(limit {wall_secs}s). Killing process group.",
                124,
            )
        if idle_for > idle_secs:
            return kill_process_group(
                f"Idle timeout: no output for {int(idle_for)}s "
                f"(limit {idle_secs}s). Process is likely stuck. "
                f"Killing process group.",
                125,
            )

    reader.join(timeout=2)
    return proc.returncode


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
