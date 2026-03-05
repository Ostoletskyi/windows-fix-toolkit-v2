#!/usr/bin/env bash

#==============================================================================
# Windows Fix Toolkit - Bash Launcher (Enhanced Edition)
#==============================================================================

# Safer error handling: continue on errors, handle them gracefully
set -uo pipefail

#------------------------------------------------------------------------------
# Configuration & Constants
#------------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || {
  echo "[ERROR] Cannot determine script directory"
  exit 1
}

REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd)" || {
  echo "[ERROR] Cannot determine repo root"
  exit 1
}

ENTRYPOINT="$REPO_ROOT/bin/windowsfix.ps1"
LOG_FILE="${LOG_FILE:-$REPO_ROOT/launcher.log}"
MAX_RETRIES=3

#------------------------------------------------------------------------------
# Logging
#------------------------------------------------------------------------------
log() {
  local level="$1"
  shift
  local msg="$*"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$timestamp] [$level] $msg" | tee -a "$LOG_FILE" >&2
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_debug() { [[ "${DEBUG:-0}" == "1" ]] && log "DEBUG" "$@" || true; }

#------------------------------------------------------------------------------
# Error Handler
#------------------------------------------------------------------------------
handle_error() {
  local exit_code=$?
  local line_no=$1
  log_error "Script failed at line $line_no with exit code $exit_code"
  echo
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║  An error occurred. Check $LOG_FILE for details.           ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo
  read -r -p "Press Enter to continue..." _ || true
}

trap 'handle_error ${LINENO}' ERR

#------------------------------------------------------------------------------
# Validation
#------------------------------------------------------------------------------
validate_entrypoint() {
  if [[ ! -f "$ENTRYPOINT" ]]; then
    log_error "Entrypoint not found: $ENTRYPOINT"
    echo
    echo "Expected location: $ENTRYPOINT"
    echo "Please ensure the PowerShell script exists at this path."
    echo
    read -r -p "Press Enter to exit..." _ || true
    exit 1
  fi
  log_debug "Entrypoint validated: $ENTRYPOINT"
}

#------------------------------------------------------------------------------
# PowerShell Detection
#------------------------------------------------------------------------------
pick_powershell() {
  local candidates=("powershell.exe" "powershell" "pwsh")
  
  for ps_cmd in "${candidates[@]}"; do
    if command -v "$ps_cmd" >/dev/null 2>&1; then
      # Verify it actually works
      if "$ps_cmd" -Version >/dev/null 2>&1; then
        echo "$ps_cmd"
        log_debug "Found working PowerShell: $ps_cmd"
        return 0
      else
        log_warn "Found $ps_cmd but it doesn't respond correctly"
      fi
    fi
  done
  
  return 1
}

detect_powershell() {
  if ! PS_BIN="$(pick_powershell)"; then
    log_error "PowerShell not found in PATH"
    echo
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  PowerShell Not Found                                      ║"
    echo "╠════════════════════════════════════════════════════════════╣"
    echo "║  This script requires PowerShell to run.                   ║"
    echo "║                                                             ║"
    echo "║  Tried: powershell.exe, powershell, pwsh                   ║"
    echo "║                                                             ║"
    echo "║  Please install:                                            ║"
    echo "║  • Windows: PowerShell should be pre-installed             ║"
    echo "║  • Linux/Mac: Install PowerShell Core (pwsh)               ║"
    echo "║    https://github.com/PowerShell/PowerShell                ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo
    read -r -p "Press Enter to exit..." _ || true
    exit 1
  fi
  log_info "Using PowerShell: $PS_BIN"
}

#------------------------------------------------------------------------------
# Toolkit Runner
#------------------------------------------------------------------------------
run_toolkit() {
  local mode="$1"
  shift
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
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║  Executing: $mode Mode                                      "
  echo "╚════════════════════════════════════════════════════════════╝"
  log_info "Command: ${cmd[*]}"
  echo
  
  local retry=0
  local exit_code=1
  
  while [[ $retry -lt $MAX_RETRIES ]] && [[ $exit_code -ne 0 ]]; do
    if [[ $retry -gt 0 ]]; then
      log_warn "Retry attempt $retry/$MAX_RETRIES"
      echo
      echo "Retrying ($retry/$MAX_RETRIES)..."
      sleep 2
    fi
    
    # Run command and capture exit code without killing script
    set +e
    "${cmd[@]}"
    exit_code=$?
    set -e
    
    ((retry++))
  done
  
  echo
  if [[ $exit_code -eq 0 ]]; then
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  ✓ Completed Successfully                                  ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    log_info "Execution completed successfully (exit code: $exit_code)"
  else
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  ✗ Execution Failed                                        ║"
    echo "║    Exit Code: $exit_code                                    "
    echo "╚════════════════════════════════════════════════════════════╝"
    log_error "Execution failed with exit code: $exit_code"
  fi
  echo
  
  read -r -p "Press Enter to continue..." _ || true
  return $exit_code
}

#------------------------------------------------------------------------------
# Interactive Prompts
#------------------------------------------------------------------------------
ask_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local answer
  
  while true; do
    read -r -p "$prompt " answer || answer="$default"
    answer="${answer:-$default}"
    answer="${answer,,}"  # lowercase
    
    case "$answer" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) echo "Please answer 'y' or 'n'" ;;
    esac
  done
}

ask_common_flags() {
  local flags=()
  
  echo
  echo "Configure additional flags:"
  echo "─────────────────────────────"
  
  ask_yes_no "Add -NoNetwork? (y/N):" "n" && flags+=("-NoNetwork")
  ask_yes_no "Add -AssumeYes? (y/N):" "n" && flags+=("-AssumeYes")
  ask_yes_no "Add -Force? (y/N):" "n" && flags+=("-Force")
  
  echo
  read -r -p "Custom ReportPath (leave empty for default): " report_path || report_path=""
  if [[ -n "${report_path:-}" ]]; then
    # Expand ~ and validate path
    report_path="${report_path/#\~/$HOME}"
    flags+=("-ReportPath" "$report_path")
    log_debug "Custom report path: $report_path"
  fi
  
  printf '%s\n' "${flags[@]}"
}

#------------------------------------------------------------------------------
# Main Menu
#------------------------------------------------------------------------------
show_banner() {
  cat <<'BANNER'
╔════════════════════════════════════════════════════════════════════╗
║                                                                    ║
║         Windows Fix Toolkit - Bash Launcher (Enhanced)            ║
║                                                                    ║
╚════════════════════════════════════════════════════════════════════╝
BANNER
}

show_info() {
  cat <<INFO
Repository:  $REPO_ROOT
Entrypoint:  $ENTRYPOINT
PowerShell:  $PS_BIN
Log File:    $LOG_FILE

INFO
}

main_menu() {
  while true; do
    clear 2>/dev/null || printf '\033[2J\033[H'  # Fallback clear
    
    show_banner
    show_info
    
    cat <<'MENU'
────────────────────────────────────────────────────────────────────
  MODE OPTIONS:
────────────────────────────────────────────────────────────────────
  1) SelfTest   - Quick system checks (non-destructive)
  2) Diagnose   - Comprehensive diagnostics
  3) Repair     - DISM CheckHealth + SFC scan
  4) Full       - Complete workflow (Diagnose → Repair → Export)
  5) DryRun     - Show planned actions without executing
  6) Custom     - Configure mode and flags manually
────────────────────────────────────────────────────────────────────
  0) Exit
────────────────────────────────────────────────────────────────────
MENU
    
    read -r -p "Select option [0-6]: " choice || choice="0"
    
    case "$choice" in
      1)
        run_toolkit "SelfTest" || true
        ;;
      2)
        run_toolkit "Diagnose" || true
        ;;
      3)
        run_toolkit "Repair" || true
        ;;
      4)
        run_toolkit "Full" || true
        ;;
      5)
        run_toolkit "DryRun" || true
        ;;
      6)
        echo
        read -r -p "Enter Mode [SelfTest/Diagnose/Repair/Full/DryRun]: " mode || mode=""
        mode="${mode:-SelfTest}"
        
        case "$mode" in
          SelfTest|Diagnose|Repair|Full|DryRun)
            mapfile -t flags < <(ask_common_flags) || flags=()
            run_toolkit "$mode" "${flags[@]}" || true
            ;;
          *)
            log_warn "Invalid mode: $mode"
            echo
            echo "Invalid mode. Valid options: SelfTest, Diagnose, Repair, Full, DryRun"
            read -r -p "Press Enter to continue..." _ || true
            ;;
        esac
        ;;
      0)
        echo
        echo "Exiting. Goodbye!"
        log_info "User exited normally"
        exit 0
        ;;
      *)
        log_warn "Unknown menu option: $choice"
        echo
        echo "Invalid option. Please select 0-6."
        sleep 1
        ;;
    esac
  done
}

#------------------------------------------------------------------------------
# Entry Point
#------------------------------------------------------------------------------
main() {
  log_info "=== Launcher started ==="
  log_debug "Script: $SCRIPT_DIR/$(basename "$0")"
  
  validate_entrypoint
  detect_powershell
  
  main_menu
}

# Run if not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi