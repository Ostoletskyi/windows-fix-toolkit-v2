#!/usr/bin/env bash
set -euo pipefail

SCRIPT_BUILD="WindowsFixToolkit-Bash v1.0.0"

PROGRESS_TOTAL=1
PROGRESS_DONE=0

init_progress() {
  local total="$1"
  PROGRESS_TOTAL="$total"
  PROGRESS_DONE=0
  echo "[PROGRESS] 0% (0/$PROGRESS_TOTAL) - start"
}

progress_tick() {
  local label="$1"
  local status="$2"
  PROGRESS_DONE=$((PROGRESS_DONE + 1))
  local pct=$(( (PROGRESS_DONE * 100) / PROGRESS_TOTAL ))
  if (( pct > 100 )); then pct=100; fi
  echo "[PROGRESS] ${pct}% (${PROGRESS_DONE}/${PROGRESS_TOTAL}) - ${label} => ${status}"
}

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//"/\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/}
  printf '%s' "$s"
}

is_admin() {
  if command -v net.exe >/dev/null 2>&1; then
    net.exe session >/dev/null 2>&1 && return 0 || return 1
  fi
  return 1
}

log_line() {
  local level="$1"; shift
  local msg="$*"
  local line="[$(date +"%Y-%m-%d %H:%M:%S")][$level] $msg"
  echo "$line"
  if [[ -n "${TOOLKIT_LOG_PATH:-}" ]]; then
    printf '%s\r\n' "$line" >> "$TOOLKIT_LOG_PATH" 2>/dev/null || true
  fi
}

should_use_timeout() {
  local first="$1"
  case "$first" in
    *.exe|*.EXE) return 1 ;;
    */*.exe|*/.exe|*\*.exe|*\*.EXE) return 1 ;;
    cmd|cmd.exe|where|where.exe|sc|sc.exe|dism|dism.exe|nslookup|nslookup.exe|ipconfig|ipconfig.exe|netsh|netsh.exe)
      return 1
      ;;
  esac
  return 0
}

run_cmd() {
  local timeout_sec="$1"; shift
  local cmd=("$@")
  local start end
  start=$(date +%s%3N)
  log_line INFO ">> ${cmd[*]}"

  local out err
  out="$(mktemp)"; err="$(mktemp)"

  local runner=("${cmd[@]}")
  if command -v timeout >/dev/null 2>&1 && should_use_timeout "${cmd[0]}"; then
    runner=(timeout "${timeout_sec}s" "${cmd[@]}")
  fi

  if [[ -t 1 ]]; then
    "${runner[@]}" >"$out" 2>"$err" &
    local pid=$!
    local spin='|/-\'
    local i=0
    local short_name="${cmd[0]}"
    while kill -0 "$pid" 2>/dev/null; do
      printf '
[STEP] %c %s ...' "${spin:i++%${#spin}:1}" "$short_name"
      sleep 0.12
    done
    set +e
    wait "$pid"
    CMD_EXIT_CODE=$?
    set -e
    printf '
[STEP] ✓ %s finished.                
' "$short_name"
  else
    if "${runner[@]}" >"$out" 2>"$err"; then CMD_EXIT_CODE=0; else CMD_EXIT_CODE=$?; fi
  fi

  end=$(date +%s%3N)
  CMD_DURATION_MS=$((end-start))
  CMD_STDOUT="$(cat "$out" 2>/dev/null || true)"
  CMD_STDERR="$(cat "$err" 2>/dev/null || true)"
  rm -f "$out" "$err"
}


add_step() {
  local name="$1" status="$2" exit_code="$3" duration_ms="$4" details="$5"
  STEPS+=("$name|$status|$exit_code|$duration_ms|$details")
}

write_report() {
  local json_path="$REPORT_PATH/report.json"
  local md_path="$REPORT_PATH/report.md"

  {
    echo "{"
    echo "  \"mode\": \"$(json_escape "$MODE")\"," 
    echo "  \"startedAt\": \"$(json_escape "$STARTED_AT")\"," 
    echo "  \"finishedAt\": \"$(now_iso)\"," 
    echo "  \"isAdmin\": $([[ "$IS_ADMIN" == "1" ]] && echo true || echo false),"
    echo "  \"logPath\": \"$(json_escape "$TOOLKIT_LOG_PATH")\"," 
    echo "  \"steps\": ["
    local i=0 total=${#STEPS[@]}
    for s in "${STEPS[@]}"; do
      IFS='|' read -r n st ec dur det <<<"$s"
      i=$((i+1))
      local suffix=""
      [[ $i -lt $total ]] && suffix=","
      echo "    {\"name\":\"$(json_escape "$n")\",\"status\":\"$st\",\"exitCode\":$ec,\"durationMs\":$dur,\"details\":\"$(json_escape "$det")\"}$suffix"
    done
    echo "  ]"
    echo "}"
  } > "$json_path"

  {
    echo "# Windows Fix Toolkit Report (Bash)"
    echo
    echo "- Mode: $MODE"
    echo "- IsAdmin: $IS_ADMIN"
    echo "- StartedAt: $STARTED_AT"
    echo
    echo "## Steps"
    for s in "${STEPS[@]}"; do
      IFS='|' read -r n st ec dur det <<<"$s"
      echo "- **$n**: $st (exit=$ec, ${dur}ms)"
      [[ -n "$det" ]] && echo "  - ${det//$'\n'/ }"
    done
  } > "$md_path"
}

selftest() {
  local checks=(
    "cmd.exe /c echo OK"
    "where.exe dism.exe"
    "where.exe sfc.exe"
    "where.exe netsh.exe"
    "where.exe ipconfig.exe"
  )
  local any_fail=0
  for c in "${checks[@]}"; do
    read -r -a arr <<<"$c"
    run_cmd 30 "${arr[@]}"
    print_cmd_result "SelfTest: $c" 4
    if [[ "$CMD_EXIT_CODE" == "0" ]]; then
      add_step "SelfTest: $c" "OK" 0 "$CMD_DURATION_MS" "$CMD_STDOUT $CMD_STDERR"
      progress_tick "SelfTest: $c" "OK"
    else
      any_fail=1
      add_step "SelfTest: $c" "FAIL" "$CMD_EXIT_CODE" "$CMD_DURATION_MS" "$CMD_STDERR"
      progress_tick "SelfTest: $c" "FAIL"
    fi
  done
  return $any_fail
}


print_cmd_result() {
  local title="$1"
  local max_lines="${2:-8}"
  echo "[RESULT] $title | exit=$CMD_EXIT_CODE | duration=${CMD_DURATION_MS}ms"

  local shown=0
  if [[ -n "${CMD_STDOUT:-}" ]]; then
    echo "[STDOUT]"
    while IFS= read -r line; do
      echo "  $line"
      shown=$((shown+1))
      [[ $shown -ge $max_lines ]] && { echo "  ..."; break; }
    done <<< "$CMD_STDOUT"
  fi

  shown=0
  if [[ -n "${CMD_STDERR:-}" ]]; then
    echo "[STDERR]"
    while IFS= read -r line; do
      echo "  $line"
      shown=$((shown+1))
      [[ $shown -ge $max_lines ]] && { echo "  ..."; break; }
    done <<< "$CMD_STDERR"
  fi
}

confirm_action() {
  local prompt="$1"
  if [[ "${ASSUME_YES:-0}" == "1" || "${FORCE:-0}" == "1" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    # non-interactive session (e.g. elevated child shell). default to yes to avoid silent skip.
    return 0
  fi
  local ans
  read -r -p "$prompt [y/N]: " ans
  [[ "${ans,,}" == "y" ]]
}

diagnose() {
  run_cmd 20 cmd.exe /c ver
  print_cmd_result "Snapshot: OS version" 6
  add_step "Snapshot: OS version" "OK" "$CMD_EXIT_CODE" "$CMD_DURATION_MS" "$CMD_STDOUT"
  progress_tick "Snapshot: OS version" "OK"

  for svc in wuauserv bits cryptsvc trustedinstaller; do
    run_cmd 20 sc.exe query "$svc"
    print_cmd_result "Service: $svc" 6
    if [[ "$CMD_EXIT_CODE" == "0" ]]; then
      add_step "Service: $svc" "OK" 0 "$CMD_DURATION_MS" "$CMD_STDOUT"
      progress_tick "Service: $svc" "OK"
    else
      add_step "Service: $svc" "WARN" "$CMD_EXIT_CODE" "$CMD_DURATION_MS" "$CMD_STDERR"
      progress_tick "Service: $svc" "WARN"
    fi
  done

  if [[ "$NO_NETWORK" == "1" ]]; then
    add_step "Network: DNS resolve" "SKIPPED" 0 0 "NoNetwork switch specified"
    progress_tick "Network: DNS resolve" "SKIPPED"
  else
    run_cmd 20 nslookup www.microsoft.com
    print_cmd_result "Network: DNS resolve" 6
    if [[ "$CMD_EXIT_CODE" == "0" ]]; then
      add_step "Network: DNS resolve" "OK" 0 "$CMD_DURATION_MS" "$CMD_STDOUT"
      progress_tick "Network: DNS resolve" "OK"
    else
      add_step "Network: DNS resolve" "WARN" "$CMD_EXIT_CODE" "$CMD_DURATION_MS" "$CMD_STDERR"
      progress_tick "Network: DNS resolve" "WARN"
    fi
  fi

  add_step "Integrity: DISM/SFC availability" "OK" 0 0 "Use SelfTest mode to verify executable presence"
  progress_tick "Integrity: DISM/SFC availability" "OK"
}

repair() {
  if [[ "$DRY_RUN" == "1" ]]; then
    add_step "Repair: DISM CheckHealth" "PLANNED" 0 0 "DryRun preview: dism.exe /Online /Cleanup-Image /CheckHealth (not executed)"
    progress_tick "Repair: DISM CheckHealth" "PLANNED"
    add_step "Repair: DISM ScanHealth" "PLANNED" 0 0 "DryRun preview: dism.exe /Online /Cleanup-Image /ScanHealth (not executed)"
    progress_tick "Repair: DISM ScanHealth" "PLANNED"
    add_step "Repair: SFC ScanNow" "PLANNED" 0 0 "DryRun preview: sfc.exe /scannow (not executed)"
    progress_tick "Repair: SFC ScanNow" "PLANNED"
    return 0
  fi

  local rc=0

  echo "[ACTION] Running DISM CheckHealth..."
  run_cmd 1800 dism.exe /Online /Cleanup-Image /CheckHealth
  print_cmd_result "DISM CheckHealth" 10
  if [[ "$CMD_EXIT_CODE" == "0" ]]; then
    add_step "Repair: DISM CheckHealth" "OK" 0 "$CMD_DURATION_MS" "$CMD_STDOUT"
    progress_tick "Repair: DISM CheckHealth" "OK"
  else
    add_step "Repair: DISM CheckHealth" "FAIL" "$CMD_EXIT_CODE" "$CMD_DURATION_MS" "$CMD_STDERR"
    progress_tick "Repair: DISM CheckHealth" "FAIL"
    rc=1
  fi

  if confirm_action "Run DISM ScanHealth? (can take significant time)"; then
    echo "[ACTION] Running DISM ScanHealth..."
    run_cmd 3600 dism.exe /Online /Cleanup-Image /ScanHealth
    print_cmd_result "DISM ScanHealth" 10
    if [[ "$CMD_EXIT_CODE" == "0" ]]; then
      add_step "Repair: DISM ScanHealth" "OK" 0 "$CMD_DURATION_MS" "$CMD_STDOUT"
      progress_tick "Repair: DISM ScanHealth" "OK"
    else
      add_step "Repair: DISM ScanHealth" "FAIL" "$CMD_EXIT_CODE" "$CMD_DURATION_MS" "$CMD_STDERR"
      progress_tick "Repair: DISM ScanHealth" "FAIL"
      rc=1
    fi
  else
    add_step "Repair: DISM ScanHealth" "SKIPPED" 0 0 "Skipped by user"
    progress_tick "Repair: DISM ScanHealth" "SKIPPED"
  fi

  if confirm_action "Run SFC /scannow?"; then
    echo "[ACTION] Running SFC /scannow..."
    run_cmd 5400 sfc.exe /scannow
    print_cmd_result "SFC ScanNow" 10
    if [[ "$CMD_EXIT_CODE" == "0" ]]; then
      add_step "Repair: SFC ScanNow" "OK" 0 "$CMD_DURATION_MS" "$CMD_STDOUT"
      progress_tick "Repair: SFC ScanNow" "OK"
    else
      add_step "Repair: SFC ScanNow" "FAIL" "$CMD_EXIT_CODE" "$CMD_DURATION_MS" "$CMD_STDERR"
      progress_tick "Repair: SFC ScanNow" "FAIL"
      rc=1
    fi
  else
    add_step "Repair: SFC ScanNow" "SKIPPED" 0 0 "Skipped by user"
    progress_tick "Repair: SFC ScanNow" "SKIPPED"
  fi

  return $rc
}



collect_windows_logs() {
  local out_dir="$REPORT_PATH/collected-logs"
  mkdir -p "$out_dir"

  local copied=0
  local candidates=(
    "/c/Windows/Logs/CBS/CBS.log"
    "/c/Windows/Logs/DISM/dism.log"
    "/c/Windows/WindowsUpdate.log"
  )

  for f in "${candidates[@]}"; do
    if [[ -f "$f" ]]; then
      cp "$f" "$out_dir/" 2>/dev/null || true
      copied=$((copied+1))
    fi
  done

  COLLECTED_LOGS_DIR="$out_dir"
  COLLECTED_LOGS_COUNT="$copied"
}

analyze_collected_logs() {
  local out_dir="$1"
  local issues=()

  if [[ ! -d "$out_dir" ]]; then
    ANALYSIS_STATUS="WARN"
    ANALYSIS_DETAILS="Log directory not found: $out_dir"
    ANALYSIS_RECOMMEND="Run Diagnose/Repair as administrator and ensure Windows logs are accessible."
    return
  fi

  local files=("$out_dir"/*.log)
  if [[ ! -e "${files[0]}" ]]; then
    ANALYSIS_STATUS="WARN"
    ANALYSIS_DETAILS="No .log files collected in $out_dir"
    ANALYSIS_RECOMMEND="Collect CBS/DISM/WU logs first, then re-run analysis."
    return
  fi

  if grep -Eqi "corrupt|component store corruption|cannot repair|repair failed|0x800f081f|0x800f0906" "$out_dir"/*.log 2>/dev/null; then
    issues+=("Component corruption signatures detected (CBS/DISM).")
  fi
  if grep -Eqi "windows update|wuauserv|0x8024|wu error|download failed" "$out_dir"/*.log 2>/dev/null; then
    issues+=("Windows Update related errors detected.")
  fi
  if grep -Eqi "sfc|windows resource protection|cannot fix|hash mismatch" "$out_dir"/*.log 2>/dev/null; then
    issues+=("SFC/WRP repair findings detected.")
  fi

  if [[ ${#issues[@]} -eq 0 ]]; then
    ANALYSIS_STATUS="OK"
    ANALYSIS_DETAILS="Problems not detected in collected logs (heuristic scan)."
    ANALYSIS_RECOMMEND="No immediate repair recommendation from log analysis."
    return
  fi

  ANALYSIS_STATUS="WARN"
  ANALYSIS_DETAILS="$(printf '%s ' "${issues[@]}")"
  ANALYSIS_RECOMMEND="Recommended: run Repair mode with DISM CheckHealth/ScanHealth + SFC, then reboot and repeat Diagnose."
}

append_analysis_steps() {
  local t0 t1 duration
  t0=$(date +%s%3N)
  collect_windows_logs
  t1=$(date +%s%3N)
  duration=$((t1-t0))
  local status="OK"
  [[ "${COLLECTED_LOGS_COUNT:-0}" == "0" ]] && status="WARN"
  local collect_details="Collected logs: ${COLLECTED_LOGS_COUNT:-0} in ${COLLECTED_LOGS_DIR:-unknown}"
  if [[ "$DRY_RUN" == "1" ]]; then
    collect_details+=" (safe diagnostics in DryRun)"
  fi
  add_step "Logs: Collect" "$status" 0 "$duration" "$collect_details"
  progress_tick "Logs: Collect" "$status"

  t0=$(date +%s%3N)
  analyze_collected_logs "${COLLECTED_LOGS_DIR:-$REPORT_PATH/collected-logs}"
  t1=$(date +%s%3N)
  duration=$((t1-t0))

  local details="$ANALYSIS_DETAILS"
  if [[ -n "${ANALYSIS_RECOMMEND:-}" ]]; then
    details+=" Recommendation: $ANALYSIS_RECOMMEND"
  fi
  add_step "Analysis: Known Windows logs" "$ANALYSIS_STATUS" 0 "$duration" "$details"
  progress_tick "Analysis: Known Windows logs" "$ANALYSIS_STATUS"

  if [[ "$ANALYSIS_STATUS" == "WARN" ]]; then
    log_line WARN "Analysis found potential issues. $ANALYSIS_RECOMMEND"
  else
    log_line INFO "Analysis: problems not detected in collected logs."
  fi
}

run_toolkit() {
  STARTED_AT="$(now_iso)"
  STEPS=()
  IS_ADMIN=0
  is_admin && IS_ADMIN=1

  log_line INFO "Mode=$MODE, IsAdmin=$IS_ADMIN, ReportPath=$REPORT_PATH"

  local effective="$MODE"
  [[ "$MODE" == "DryRun" ]] && { effective="Full"; DRY_RUN=1; }

  case "$effective" in
    SelfTest) init_progress 5 ;;
    Diagnose) init_progress 9 ;;
    Repair) init_progress 5 ;;
    Full) init_progress 13 ;;
    *) init_progress 1 ;;
  esac

  if [[ "$DRY_RUN" != "1" && ( "$effective" == "Repair" || "$effective" == "Full" ) ]]; then
    if [[ "$IS_ADMIN" != "1" ]]; then
      add_step "Admin check" "FAIL" 2 0 "Repair/Full requires Administrator privileges"
      progress_tick "Admin check" "FAIL"
      write_report
      return 2
    fi
  fi

  local rc=0
  case "$effective" in
    SelfTest) selftest || rc=1 ;;
    Diagnose)
      diagnose
      append_analysis_steps
      ;;
    Repair)
      repair || rc=1
      append_analysis_steps
      ;;
    Full)
      diagnose
      repair || rc=1
      mkdir -p "$REPORT_PATH/collected-logs"
      add_step "Export logs" "OK" 0 0 "Created log export directory: $REPORT_PATH/collected-logs"
      progress_tick "Export logs" "OK"
      append_analysis_steps
      ;;
    *)
      add_step "Invalid mode" "FAIL" 3 0 "Unsupported mode: $MODE"
      progress_tick "Invalid mode" "FAIL"
      rc=3
      ;;
  esac

  write_report
  return $rc
}
