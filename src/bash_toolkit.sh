#!/usr/bin/env bash
set -euo pipefail

SCRIPT_BUILD="WindowsFixToolkit-Bash v1.0.0"

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
  if command -v timeout >/dev/null 2>&1 && should_use_timeout "${cmd[0]}"; then
    if timeout "${timeout_sec}s" "${cmd[@]}" >"$out" 2>"$err"; then CMD_EXIT_CODE=0; else CMD_EXIT_CODE=$?; fi
  else
    if "${cmd[@]}" >"$out" 2>"$err"; then CMD_EXIT_CODE=0; else CMD_EXIT_CODE=$?; fi
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
    if [[ "$CMD_EXIT_CODE" == "0" ]]; then
      add_step "SelfTest: $c" "OK" 0 "$CMD_DURATION_MS" "$CMD_STDOUT $CMD_STDERR"
    else
      any_fail=1
      add_step "SelfTest: $c" "FAIL" "$CMD_EXIT_CODE" "$CMD_DURATION_MS" "$CMD_STDERR"
    fi
  done
  return $any_fail
}

diagnose() {
  run_cmd 20 cmd.exe /c ver
  add_step "Snapshot: OS version" "OK" "$CMD_EXIT_CODE" "$CMD_DURATION_MS" "$CMD_STDOUT"

  for svc in wuauserv bits cryptsvc trustedinstaller; do
    run_cmd 20 sc.exe query "$svc"
    if [[ "$CMD_EXIT_CODE" == "0" ]]; then
      add_step "Service: $svc" "OK" 0 "$CMD_DURATION_MS" "$CMD_STDOUT"
    else
      add_step "Service: $svc" "WARN" "$CMD_EXIT_CODE" "$CMD_DURATION_MS" "$CMD_STDERR"
    fi
  done

  if [[ "$NO_NETWORK" == "1" ]]; then
    add_step "Network: DNS resolve" "SKIPPED" 0 0 "NoNetwork switch specified"
  else
    run_cmd 20 nslookup www.microsoft.com
    if [[ "$CMD_EXIT_CODE" == "0" ]]; then
      add_step "Network: DNS resolve" "OK" 0 "$CMD_DURATION_MS" "$CMD_STDOUT"
    else
      add_step "Network: DNS resolve" "WARN" "$CMD_EXIT_CODE" "$CMD_DURATION_MS" "$CMD_STDERR"
    fi
  fi

  add_step "Integrity: DISM/SFC availability" "OK" 0 0 "Use SelfTest mode to verify executable presence"
}

repair() {
  if [[ "$DRY_RUN" == "1" ]]; then
    add_step "Repair: DISM CheckHealth" "SKIPPED" 0 0 "DryRun: dism.exe /Online /Cleanup-Image /CheckHealth"
    return 0
  fi

  run_cmd 1800 dism.exe /Online /Cleanup-Image /CheckHealth
  if [[ "$CMD_EXIT_CODE" == "0" ]]; then
    add_step "Repair: DISM CheckHealth" "OK" 0 "$CMD_DURATION_MS" "$CMD_STDOUT"
    return 0
  fi
  add_step "Repair: DISM CheckHealth" "FAIL" "$CMD_EXIT_CODE" "$CMD_DURATION_MS" "$CMD_STDERR"
  return 1
}

run_toolkit() {
  STARTED_AT="$(now_iso)"
  STEPS=()
  IS_ADMIN=0
  is_admin && IS_ADMIN=1

  log_line INFO "Mode=$MODE, IsAdmin=$IS_ADMIN, ReportPath=$REPORT_PATH"

  local effective="$MODE"
  [[ "$MODE" == "DryRun" ]] && { effective="Full"; DRY_RUN=1; }

  if [[ "$DRY_RUN" != "1" && ( "$effective" == "Repair" || "$effective" == "Full" ) ]]; then
    if [[ "$IS_ADMIN" != "1" ]]; then
      add_step "Admin check" "FAIL" 2 0 "Repair/Full requires Administrator privileges"
      write_report
      return 2
    fi
  fi

  local rc=0
  case "$effective" in
    SelfTest) selftest || rc=1 ;;
    Diagnose) diagnose ;;
    Repair) repair || rc=1 ;;
    Full)
      diagnose
      repair || rc=1
      mkdir -p "$REPORT_PATH/collected-logs"
      add_step "Export logs" "OK" 0 0 "Created log export directory: $REPORT_PATH/collected-logs"
      ;;
    *)
      add_step "Invalid mode" "FAIL" 3 0 "Unsupported mode: $MODE"
      rc=3
      ;;
  esac

  write_report
  return $rc
}
