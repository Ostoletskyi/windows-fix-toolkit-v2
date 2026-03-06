#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ENTRYPOINT="$REPO_ROOT/bin/windowsfix.sh"

if [[ ! -f "$ENTRYPOINT" ]]; then
  echo "[ERROR] Entrypoint not found: $ENTRYPOINT"
  exit 1
fi

P_SELFTEST=0
P_DIAGNOSE=0
P_REPAIR=0
P_FULL=0
P_DRYRUN=0

progress_bar() {
  local pct="$1"
  local filled=$((pct / 10))
  local empty=$((10 - filled))
  printf '['
  for ((i=0; i<filled; i++)); do printf '#'; done
  for ((i=0; i<empty; i++)); do printf '-'; done
  printf '] %s%%' "$pct"
}

set_mode_progress() {
  local mode="$1"
  case "$mode" in
    SelfTest) P_SELFTEST=100 ;;
    Diagnose) P_DIAGNOSE=100 ;;
    Repair) P_REPAIR=100 ;;
    Full) P_FULL=100 ;;
    DryRun) P_DRYRUN=100 ;;
  esac
}

print_run_summary() {
  local mode="$1"
  local report_path="$2"
  local exit_code="$3"

  echo
  echo "========== RESULT SUMMARY =========="
  echo "Mode       : $mode"
  echo "ExitCode   : $exit_code"
  echo "ReportPath : ${report_path:-unknown}"

  if [[ -z "${report_path:-}" || ! -d "$report_path" ]]; then
    echo "[WARN] Report directory not found."
    echo "===================================="
    return
  fi

  local report_md="$report_path/report.md"
  local report_json="$report_path/report.json"
  local toolkit_log="$report_path/toolkit.log"

  local steps_total=0 ok=0 warn=0 fail=0 skipped=0
  if [[ -f "$report_md" ]]; then
    steps_total="$(grep -c '^- \*\*' "$report_md" || true)"
    ok="$(grep -cE '^- \*\*.*: OK \(' "$report_md" || true)"
    warn="$(grep -cE '^- \*\*.*: WARN \(' "$report_md" || true)"
    fail="$(grep -cE '^- \*\*.*: FAIL \(' "$report_md" || true)"
    skipped="$(grep -cE '^- \*\*.*: SKIPPED \(' "$report_md" || true)"
  fi

  echo "Steps      : total=$steps_total, ok=$ok, warn=$warn, fail=$fail, skipped=$skipped"
  echo "Artifacts  :"
  [[ -f "$report_json" ]] && echo "  - $report_json"
  [[ -f "$report_md" ]] && echo "  - $report_md"
  [[ -f "$toolkit_log" ]] && echo "  - $toolkit_log"

  if [[ -f "$report_md" ]]; then
    echo
    echo "Step outcomes:"
    grep -E '^- \*\*.*: (OK|WARN|FAIL|SKIPPED) \(' "$report_md" || true
  fi

  echo "===================================="
}

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

  local progress=0
  echo
  echo "[RUN] ${cmd[*]}"
  echo -n "[PROGRESS] "
  progress_bar "$progress"
  echo

  local out_file
  out_file="$(mktemp)"

  progress=20
  echo -n "[PROGRESS] "
  progress_bar "$progress"
  echo "  -> starting"

  set +e
  "${cmd[@]}" | tee "$out_file"
  local exit_code=${PIPESTATUS[0]}
  set -e

  progress=85
  echo -n "[PROGRESS] "
  progress_bar "$progress"
  echo "  -> collecting results"

  local report_path
  report_path="$(awk -F': ' '/^ReportPath/{print $2; exit}' "$out_file" | tr -d '\r')"

  if [[ -z "${report_path:-}" ]]; then
    report_path="$(ls -1dt "$REPO_ROOT"/Outputs/WindowsFix_* 2>/dev/null | head -n1 || true)"
  fi

  print_run_summary "$mode" "$report_path" "$exit_code"

  progress=100
  set_mode_progress "$mode"
  echo -n "[PROGRESS] "
  progress_bar "$progress"
  echo "  -> completed"

  rm -f "$out_file"

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
    "1) SelfTest  $(progress_bar "$P_SELFTEST")" \
    "2) Diagnose  $(progress_bar "$P_DIAGNOSE")" \
    "3) Repair (DISM CheckHealth MVP)  $(progress_bar "$P_REPAIR")" \
    "4) Full (Diagnose + Repair + logs export)  $(progress_bar "$P_FULL")" \
    "5) DryRun (plan only, no actions)  $(progress_bar "$P_DRYRUN")" \
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
