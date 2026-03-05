#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ENTRYPOINT="$REPO_ROOT/bin/windowsfix.sh"

if [[ ! -f "$ENTRYPOINT" ]]; then
  echo "[ERROR] Entrypoint not found: $ENTRYPOINT"
  exit 1
fi

run_toolkit() {
  local mode="$1"
  shift
  local extra=("$@")

  local cmd=(
    bash "$ENTRYPOINT"
    -Mode "$mode"
  )

  if [[ ${#extra[@]} -gt 0 ]]; then
    cmd+=("${extra[@]}")
  fi

  echo
  echo "[RUN] ${cmd[*]}"
  echo
  set +e
  "${cmd[@]}"
  local exit_code=$?
  set -e

  echo
  echo "[DONE] ExitCode=$exit_code"
  echo
  read -r -p "Press Enter to continue..." _
}

ask_common_flags() {
  local flags=()

  read -r -p "Add -NoNetwork? (y/N): " ans
  [[ "${ans,,}" == "y" ]] && flags+=("-NoNetwork")

  read -r -p "Add -AssumeYes? (y/N): " ans
  [[ "${ans,,}" == "y" ]] && flags+=("-AssumeYes")

  read -r -p "Add -Force? (y/N): " ans
  [[ "${ans,,}" == "y" ]] && flags+=("-Force")

  read -r -p "Custom ReportPath (leave empty for default): " report_path
  if [[ -n "${report_path:-}" ]]; then
    flags+=("-ReportPath" "$report_path")
  fi

  printf '%s\n' "${flags[@]}"
}

print_menu() {
  printf '%s\n' \
    '========================================' \
    ' Windows Fix Toolkit - Bash Launcher Menu' \
    '========================================' \
    "Repo: $REPO_ROOT" \
    "Entry: $ENTRYPOINT" \
    'Runtime: bash' \
    '' \
    '1) SelfTest' \
    '2) Diagnose' \
    '3) Repair (DISM CheckHealth MVP)' \
    '4) Full (Diagnose + Repair + logs export)' \
    '5) DryRun (plan only, no actions)' \
    '6) Custom mode with flags' \
    '0) Exit'
}

main_menu() {
  while true; do
    clear || true
    print_menu

    read -r -p "Select option: " choice

    case "$choice" in
      1) run_toolkit "SelfTest" ;;
      2) run_toolkit "Diagnose" ;;
      3) run_toolkit "Repair" ;;
      4) run_toolkit "Full" ;;
      5) run_toolkit "DryRun" ;;
      6)
        read -r -p "Mode (SelfTest/Diagnose/Repair/Full/DryRun): " mode
        case "$mode" in
          SelfTest|Diagnose|Repair|Full|DryRun) ;;
          *)
            echo "[WARN] Invalid mode: $mode"
            read -r -p "Press Enter to continue..." _
            continue
            ;;
        esac

        mapfile -t flags < <(ask_common_flags)
        run_toolkit "$mode" "${flags[@]}"
        ;;
      0)
        echo "Bye."
        exit 0
        ;;
      *)
        echo "[WARN] Unknown option: $choice"
        read -r -p "Press Enter to continue..." _
        ;;
    esac
  done
}

main_menu
