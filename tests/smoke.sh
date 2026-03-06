#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

[[ -f "$ROOT_DIR/src/bash_toolkit.sh" ]] || { echo "Missing src/bash_toolkit.sh"; exit 1; }
[[ -x "$ROOT_DIR/bin/windowsfix.sh" ]] || { echo "Missing executable bin/windowsfix.sh"; exit 1; }

bash "$ROOT_DIR/bin/windowsfix.sh" -Mode DryRun >/dev/null
LATEST_REPORT="$(ls -1dt "$ROOT_DIR"/Outputs/WindowsFix_* | head -n1)"
[[ -f "$LATEST_REPORT/report.json" ]] || { echo "Missing report.json"; exit 1; }
[[ -f "$LATEST_REPORT/report.md" ]] || { echo "Missing report.md"; exit 1; }
[[ -f "$LATEST_REPORT/toolkit.log" ]] || { echo "Missing toolkit.log"; exit 1; }

echo "OK: bash smoke tests passed"
