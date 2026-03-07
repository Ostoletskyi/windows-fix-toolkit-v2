#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

[[ -f "$ROOT_DIR/src/WindowsFixToolkit.psm1" ]] || { echo "Missing src/WindowsFixToolkit.psm1"; exit 1; }
[[ -f "$ROOT_DIR/bin/windowsfix.ps1" ]] || { echo "Missing bin/windowsfix.ps1"; exit 1; }

PS_BIN=""
if command -v powershell.exe >/dev/null 2>&1; then
  PS_BIN="powershell.exe"
elif command -v pwsh >/dev/null 2>&1; then
  PS_BIN="pwsh"
else
  echo "WARN: powershell.exe/pwsh not found; skipping smoke"
  exit 0
fi

REPORT_PATH="$ROOT_DIR/Outputs/Smoke_$(date +%Y%m%d_%H%M%S_%3N)"
"$PS_BIN" -NoProfile -ExecutionPolicy Bypass -File "$ROOT_DIR/bin/windowsfix.ps1" -Mode DryRun -ReportPath "$REPORT_PATH" >/dev/null || true

[[ -f "$REPORT_PATH/report.json" ]] || { echo "Missing report.json"; exit 1; }
[[ -f "$REPORT_PATH/report.md" ]] || { echo "Missing report.md"; exit 1; }
[[ -f "$REPORT_PATH/toolkit.log" ]] || { echo "Missing toolkit.log"; exit 1; }

grep -q 'PLANNED' "$REPORT_PATH/report.md" || { echo "DryRun should contain PLANNED stages"; exit 1; }

echo "OK: smoke tests passed"
