#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ENTRYPOINT="$REPO_ROOT/bin/windowsfix.ps1"

if [[ ! -f "$ENTRYPOINT" ]]; then
  echo "[ERROR] Entrypoint not found: $ENTRYPOINT"
  exit 1
fi

resolve_ps() {
  if command -v powershell.exe >/dev/null 2>&1; then
    echo "powershell.exe"; return 0
  fi
  if command -v pwsh >/dev/null 2>&1; then
    echo "pwsh"; return 0
  fi
  return 1
}

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

  local filtered_flags=()
  local i=0
  while [[ $i -lt ${#extra_flags[@]} ]]; do
    local token="${extra_flags[$i]}"
    if [[ "$token" == "-ReportPath" ]]; then
      i=$((i+2)); continue
    fi
    filtered_flags+=("$token")
    i=$((i+1))
  done

  local extra_raw=""
  if [[ ${#filtered_flags[@]} -gt 0 ]]; then
    extra_raw="$(printf '%s\n' "${filtered_flags[@]}")"
  fi

  local ep="$ENTRYPOINT"
  if command -v cygpath >/dev/null 2>&1; then
    ep="$(cygpath -w "$ep")"
  fi

  local ps_file
  ps_file="$(mktemp).ps1"
  cat > "$ps_file" <<'PS'
param(
  [Parameter(Mandatory=$true)][string]$EntryPoint,
  [Parameter(Mandatory=$true)][string]$Mode,
  [Parameter(Mandatory=$true)][string]$ReportPath,
  [string]$ExtraArgsRaw = ""
)
$argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $EntryPoint, '-Mode', $Mode, '-ReportPath', $ReportPath)
if ($ExtraArgsRaw) {
  $extra = $ExtraArgsRaw -split "`n" | Where-Object { $_ -ne '' }
  if ($extra.Count -gt 0) {
    $argList += $extra
  }
}
$p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -Wait -PassThru
exit $p.ExitCode
PS

  echo "[INFO] Запускаю повышенный процесс (UAC prompt)..."
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps_file" -EntryPoint "$ep" -Mode "$mode" -ReportPath "$report_path" -ExtraArgsRaw "$extra_raw"
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

  local steps_total=0 ok=0 warn=0 fail=0 skipped=0 planned=0
  if [[ -f "$report_md" ]]; then
    steps_total="$(grep -c '^- \*\*' "$report_md" || true)"
    ok="$(grep -cE '^- \*\*.*: OK \(' "$report_md" || true)"
    warn="$(grep -cE '^- \*\*.*: WARN \(' "$report_md" || true)"
    fail="$(grep -cE '^- \*\*.*: FAIL \(' "$report_md" || true)"
    skipped="$(grep -cE '^- \*\*.*: SKIPPED \(' "$report_md" || true)"
    planned="$(grep -cE '^- \*\*.*: PLANNED \(' "$report_md" || true)"
  fi

  echo "Steps      : total=$steps_total, ok=$ok, warn=$warn, fail=$fail, skipped=$skipped, planned=$planned"
  echo "Artifacts  :"
  [[ -f "$report_json" ]] && echo "  - $report_json"
  [[ -f "$report_md" ]] && echo "  - $report_md"
  [[ -f "$toolkit_log" ]] && echo "  - $toolkit_log"

  if [[ -f "$report_md" ]]; then
    echo
    echo "Step outcomes:"
    grep -E '^- \*\*.*: (OK|WARN|FAIL|SKIPPED|PLANNED) \(' "$report_md" || true
  fi

  echo "===================================="
  if [[ "$mode" == "DryRun" ]]; then
    echo
    echo "[NOTE] DryRun = preview mode. Repair commands (DISM/SFC) are shown as PLANNED and are NOT executed."
  fi
}


print_mode_banner() {
  local mode="$1"
  case "$mode" in
    DryRun)
      echo "[INFO] You selected DryRun: this is PREVIEW ONLY mode."
      echo "[INFO] DISM/SFC repair steps will be marked PLANNED and will NOT run."
      echo "[INFO] Safe diagnostics and log analysis still run; repair commands stay PLANNED."
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

  local ps_cmd
  ps_cmd="$(resolve_ps || true)"
  if [[ -z "$ps_cmd" ]]; then
    echo "[ERROR] powershell.exe/pwsh not found in PATH."
    return 10
  fi

  local cmd=(
    "$ps_cmd"
    -NoProfile
    -ExecutionPolicy Bypass
    -File "$ENTRYPOINT"
    -Mode "$mode"
  )

  if [[ ${#extra[@]} -gt 0 ]]; then
    cmd+=("${extra[@]}")
  fi

  echo
  echo "[RUN] ${cmd[*]}"
  print_mode_banner "$mode"

  local out_file exit_code used_elevated
  out_file="$(mktemp)"
  used_elevated=0

  if mode_requires_admin "$mode" && ! is_admin; then
    used_elevated=1
    echo "[INFO] Команды вручную вводить не нужно: запуск выполняется автоматически в elevated-процессе."
    set +e
    run_elevated "$mode" "$report_path" "${extra[@]}" >"$out_file" 2>&1
    exit_code=$?
    set -e
    printf '[WORK] ✓ Повышенный запуск завершён.\n'
    if [[ ! -f "$report_path/report.md" && ! -f "$report_path/report.json" ]]; then
      echo "[WARN] Elevated process did not write reports to requested ReportPath: $report_path" >>"$out_file"
    fi
  else
    set +e
    spinner_run "$out_file" "${cmd[@]}"
    exit_code=$?
    set -e
  fi

  cat "$out_file"

  local reported_path
  reported_path="$(awk -F': ' '/^ReportPath/{print $2; exit}' "$out_file" | tr -d '\r')"
  if [[ -n "$reported_path" && -d "$reported_path" ]]; then
    if [[ -f "$reported_path/report.md" || -f "$reported_path/report.json" ]]; then
      report_path="$reported_path"
    elif [[ ! -f "$report_path/report.md" && ! -f "$report_path/report.json" ]]; then
      report_path="$reported_path"
    fi
  fi
  if [[ -z "${report_path:-}" || ! -d "$report_path" ]]; then
    report_path="$reported_path"
  fi
  if [[ ( -z "${report_path:-}" || ! -d "$report_path" ) && "$used_elevated" != "1" ]]; then
    report_path="$(ls -1dt "$REPO_ROOT"/Outputs/WindowsFix_* 2>/dev/null | head -n1 || true)"
  fi

  print_run_summary "$mode" "$report_path" "$exit_code"

  case "$exit_code" in
    0) echo "[INFO] Выполнено успешно." ;;
    1)
      local fail_count=0
      if [[ -f "$report_path/report.md" ]]; then
        fail_count="$(grep -cE '^- \*\*.*: FAIL \(' "$report_path/report.md" || true)"
      fi
      if [[ "$fail_count" == "0" ]]; then
        echo "[WARN] Код завершения=1, но FAIL-шагов нет. Вероятна проблема elevated-launch/UAC, а не диагностики системы."
      else
        echo "[WARN] Обнаружены ошибки в шагах. Проверьте Step outcomes и report.md."
      fi
      ;;
    2) echo "[WARN] Для режима Repair/Full требуются права администратора. Если UAC отклонён — это ожидаемо." ;;
    3) echo "[ERROR] Непредвиденная ошибка выполнения. Смотрите toolkit.log/report.md." ;;
    *)
      if grep -Eqi 'canceled by the user|операция отменена пользователем|The operation was canceled by the user' "$out_file"; then
        echo "[WARN] UAC-повышение было отменено пользователем. Запуск прерван."
      else
        echo "[WARN] Неожиданный код завершения: $exit_code"
      fi
      ;;
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
    '1) Diagnose' \
    '2) Repair (staged: readiness -> DISM -> SFC -> postcheck)' \
    '3) Full (Diagnose + Repair + Recheck)' \
    '4) DryRun (preview only, no real system changes)' \
    '5) Custom mode with flags' \
    '0) Exit'
}

main_menu() {
  while true; do
    clear || true
    print_menu

    read -r -p "Select option: " choice

    case "$choice" in
      1) run_toolkit "Diagnose" ;;
      2) run_toolkit "Repair" ;;
      3) run_toolkit "Full" ;;
      4) run_toolkit "DryRun" ;;
      5)
        read -r -p "Mode (Diagnose/Repair/Full/DryRun): " mode
        case "$mode" in
          Diagnose|Repair|Full|DryRun) ;;
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
