#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PS_ENTRY="$SCRIPT_DIR/windowsfix.ps1"

if [[ ! -f "$PS_ENTRY" ]]; then
  echo "[ERROR] PowerShell entrypoint not found: $PS_ENTRY"
  exit 10
fi

if command -v powershell.exe >/dev/null 2>&1; then
  exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PS_ENTRY" "$@"
fi
if command -v pwsh >/dev/null 2>&1; then
  exec pwsh -NoProfile -File "$PS_ENTRY" "$@"
fi

echo "[ERROR] powershell.exe/pwsh is required for toolkit runtime."
exit 3
