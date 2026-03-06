#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ENTRYPOINT="$REPO_ROOT/bin/windowsfix.sh"

if [[ ! -f "$ENTRYPOINT" ]]; then
  echo "[ERROR] Entrypoint not found: $ENTRYPOINT"
  exit 1
fi

is_admin() {
  if command -v net.exe >/dev/null 2>&1; then
    net.exe session >/dev/null 2>&1 && return 0 || return 1
  fi
  return 1
}

mode_requires_admin() {
  local mode="$1"
  [[ "$mode" == "Repair" || "$mode" == "Full" ]]
}

run_elevated() {
  local mode="$1"
  local report_path="$2"
  shift 2
  local extra_flags=("$@")

  if ! command -v powershell.exe >/dev/null 2>&1; then
    echo "[ERROR] Для автоповышения прав требуется powershell.exe в PATH."
    return 2
  fi

  local cmdline
  cmdline=""$ENTRYPOINT" -Mode "$mode" -ReportPath "$report_path""

  local i=0
  while [[ $i -lt ${#extra_flags[@]} ]]; do
    local token="${extra_flags[$i]}"
    if [[ "$token" == "-ReportPath" ]]; then
      i=$((i+2))
      continue
    fi
    cmdline+=" $token"
    i=$((i+1))
  done

  local bash_path
  bash_path="$(command -v bash)"
  if command -v cygpath >/dev/null 2>&1; then
    bash_path="$(cygpath -w "$bash_path")"
  fi

  local ps_file
  ps_file="$(mktemp).ps1"
  cat > "$ps_file" <<'PS'
param(
  [Parameter(Mandatory=$true)][string]$BashPath,
  [Parameter(Mandatory=$true)][string]$CmdLine
)
$p = Start-Process -FilePath $BashPath -ArgumentList @('-lc', $CmdLine) -Verb RunAs -Wait -PassThru
exit $p.ExitCode
PS

  echo "[INFO] Запускаю повышенный процесс (UAC prompt)..."
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps_file" -BashPath "$bash_path" -CmdLine "$cmdline"
  local rc=$?
  rm -f "$ps_file" 2>/dev/null || true
  return $rc
}


spinner_run() {
  local out_file="$1"
  shift
  local cmd=("$@")

  "${cmd[@]}" >"$out_file" 2>&1 &
  local pid=$!
  local spin='|/-\\'
  local i=0

  while kill -0 "$pid" 2>/dev/null; do
    printf '\r[WORK] %c Выполняется... ' "${spin:i++%${#spin}:1}"
    sleep 0.12
  done

  local exit_code
  wait "$pid"
  exit_code=$?

  printf '\r[WORK] ✓ Выполнение завершено.           \n'
  return "$exit_code"
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


print_mode_banner() {
  local mode="$1"
  case "$mode" in
    DryRun)
      echo "[INFO] You selected DryRun: repair actions are preview-only in this mode."
      echo "[INFO] Safe diagnostics and log analysis still run; repair commands stay SKIPPED."
      ;;
    Diagnose)
      echo "[INFO] Running real diagnostics (system/service/network checks + log analysis)."
      ;;
    Repair)
      echo "[INFO] Running real repair pipeline (DISM + optional SFC), may take time."
      ;;
    Full)
      echo "[INFO] Running full pipeline: Diagnose + Repair + log collection/analysis."
      ;;
  esac
}

run_toolkit() {
  local mode="$1"
  shift
  local extra=("$@")

  local report_path=""
  local has_report_path=0
  for ((i=0; i<${#extra[@]}; i++)); do
    if [[ "${extra[$i]}" == "-ReportPath" && $((i+1)) -lt ${#extra[@]} ]]; then
      report_path="${extra[$((i+1))]}"
      has_report_path=1
      break
    fi
  done
  if [[ $has_report_path -eq 0 ]]; then
    report_path="$REPO_ROOT/Outputs/WindowsFix_$(date +%Y%m%d_%H%M%S_%3N)"
    extra+=("-ReportPath" "$report_path")
  fi

  local cmd=(
    bash "$ENTRYPOINT"
    -Mode "$mode"
  )

  if [[ ${#extra[@]} -gt 0 ]]; then
    cmd+=("${extra[@]}")
  fi

  echo
  echo "[RUN] ${cmd[*]}"
  print_mode_banner "$mode"

  local out_file exit_code
  out_file="$(mktemp)"

  if mode_requires_admin "$mode" && ! is_admin; then
    echo "[INFO] Команды вручную вводить не нужно: запуск выполняется автоматически в elevated-процессе."
    set +e
    run_elevated "$mode" "$report_path" "${extra[@]}" >"$out_file" 2>&1
    exit_code=$?
    set -e
    printf '[WORK] ✓ Повышенный запуск завершён.\n'
  else
    set +e
    spinner_run "$out_file" "${cmd[@]}"
    exit_code=$?
    set -e
  fi

  cat "$out_file"

  if [[ -z "${report_path:-}" || ! -d "$report_path" ]]; then
    report_path="$(awk -F': ' '/^ReportPath/{print $2; exit}' "$out_file" | tr -d '\r')"
  fi
  if [[ -z "${report_path:-}" ]]; then
    report_path="$(ls -1dt "$REPO_ROOT"/Outputs/WindowsFix_* 2>/dev/null | head -n1 || true)"
  fi

  print_run_summary "$mode" "$report_path" "$exit_code"

  case "$exit_code" in
    0) echo "[INFO] Выполнено успешно." ;;
    1) echo "[WARN] Обнаружены ошибки в шагах. Проверьте Step outcomes и report.md." ;;
    2) echo "[WARN] Для режима Repair/Full требуются права администратора. Если UAC отклонён — это ожидаемо." ;;
    3) echo "[ERROR] Непредвиденная ошибка выполнения. Смотрите toolkit.log/report.md." ;;
    *) echo "[WARN] Неожиданный код завершения: $exit_code" ;;
  esac

  if [[ "$mode" == "DryRun" ]]; then
    echo "[NEXT] To run REAL diagnostics choose option 2 (Diagnose)."
    echo "[NEXT] To run REAL repairs choose option 3 (Repair) or 4 (Full)."
  fi

  rm -f "$out_file"

  echo
  echo "[DONE] ExitCode=$exit_code"
  echo
  read -r -p "Press Enter to continue..." _ || true
  return 0
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
    '3) Repair (DISM CheckHealth + ScanHealth + SFC)' \
    '4) Full (Diagnose + Repair + logs export)' \
    '5) DryRun (preview only, no real system changes)' \
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
