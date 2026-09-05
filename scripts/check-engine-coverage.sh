#!/usr/bin/env bash
# Advisory only: compare the exact released patch contents with this checkout.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 -B "$SCRIPT_DIR/ci/engine-coverage.py"
