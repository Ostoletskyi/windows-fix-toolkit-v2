#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ENTRYPOINT="$REPO_ROOT/bin/windowsfix.ps1"

if [[ ! -f "$ENTRYPOINT" ]]; then
  echo "[ERROR] Entrypoint not found: $ENTRYPOINT"
  exit 1
fi

pick_powershell() {
  if command -v pwsh >/dev/null 2>&1; then
    echo "pwsh"
    return 0
  fi
  if command -v powershell.exe >/dev/null 2>&1; then
    echo "powershell.exe"
    return 0
  fi
  if command -v powershell >/dev/null 2>&1; then
    echo "powershell"
    return 0
  fi
  return 1
}

if ! PS_BIN="$(pick_powershell)"; then
  echo "[ERROR] PowerShell not found in PATH (tried: pwsh, powershell.exe, powershell)."
  exit 1
fi

pause() { read -r -p "Press Enter to continue..." _; }

clear_screen() {
  if command -v clear >/dev/null 2>&1; then
    clear || true
  else
    printf '\033[2J\033[H' || true
  fi
}

print_header() {
  cat <<'HDR'
╔════════════════════════════════════════════════════════════════════╗
║                                                                    ║
║         Windows Fix Toolkit - Bash Launcher (Enhanced)            ║
║                                                                    ║
╚════════════════════════════════════════════════════════════════════╝
HDR
  echo "Repository:  $REPO_ROOT"
  echo "Entrypoint:  $ENTRYPOINT"
  echo "PowerShell:  $PS_BIN"
  echo
}

ask_common_flags() {
  local flags=()
  local ans report_path

  read -r -p "Add -NoNetwork? (y/N): " ans
  [[ "${ans,,}" == "y" ]] && flags+=("-NoNetwork")

  read -r -p "Add -AssumeYes? (y/N): " ans
  [[ "${ans,,}" == "y" ]] && flags+=("-AssumeYes")

  read -r -p "Add -Force? (y/N): " ans
  [[ "${ans,,}" == "y" ]] && flags+=("-Force")

  read -r -p "Custom -ReportPath (leave empty for default): " report_path
  if [[ -n "${report_path:-}" ]]; then
    flags+=("-ReportPath" "$report_path")
  fi

  printf '%s\n' "${flags[@]}"
}

run_toolkit() {
  local mode="$1"; shift
  local extra=("$@")

  local cmd=(
    "$PS_BIN"
    -ExecutionPolicy Bypass
    -NoProfile
    -File "$ENTRYPOINT"
    -Mode "$mode"
  )

  if [[ ${#extra[@]} -gt 0 ]]; then
    cmd+=("${extra[@]}")
  fi

  echo
  echo "────────────────────────────────────────────────────────────────────"
  echo "[RUN] ${cmd[*]}"
  echo "────────────────────────────────────────────────────────────────────"

  set +e
  "${cmd[@]}"
  local exit_code=$?
  set -e

  echo
  echo "[DONE] ExitCode=$exit_code"
  echo
  pause
}

show_menu() {
  cat <<'MENU'
────────────────────────────────────────────────────────────────────
  MODE OPTIONS:
────────────────────────────────────────────────────────────────────
  1) SelfTest   - Quick system checks (non-destructive)
  2) Diagnose   - Comprehensive diagnostics
  3) Repair     - Repair actions (requires Admin)
  4) Full       - Diagnose → Repair → Export
  5) DryRun     - Show planned actions without executing
  6) Custom     - Choose mode + flags manually
────────────────────────────────────────────────────────────────────
  0) Exit
────────────────────────────────────────────────────────────────────
MENU
}

main_menu() {
  while true; do
    clear_screen
    print_header
    show_menu

    read -r -p "Select option [0-6]: " choice
    case "${choice:-}" in
      1) mapfile -t flags < <(ask_common_flags || true); run_toolkit "SelfTest" "${flags[@]:-}" ;;
      2) mapfile -t flags < <(ask_common_flags || true); run_toolkit "Diagnose" "${flags[@]:-}" ;;
      3) mapfile -t flags < <(ask_common_flags || true); run_toolkit "Repair" "${flags[@]:-}" ;;
      4) mapfile -t flags < <(ask_common_flags || true); run_toolkit "Full" "${flags[@]:-}" ;;
      5) mapfile -t flags < <(ask_common_flags || true); run_toolkit "DryRun" "${flags[@]:-}" ;;
      6)
         echo
         read -r -p "Enter Mode (SelfTest/Diagnose/Repair/Full/DryRun): " mode
         mapfile -t flags < <(ask_common_flags || true)
         run_toolkit "$mode" "${flags[@]:-}"
         ;;
      0) echo "Bye 👋"; exit 0 ;;
      *) echo; echo "[WARN] Invalid choice: ${choice:-<empty>}"; pause ;;
    esac
  done
}

main_menu
