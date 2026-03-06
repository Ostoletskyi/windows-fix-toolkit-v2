#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/src/bash_toolkit.sh"

MODE="Diagnose"
REPORT_PATH=""
LOG_PATH=""
NO_NETWORK=0
ASSUME_YES=0
FORCE=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -Mode) MODE="$2"; shift 2 ;;
    -ReportPath) REPORT_PATH="$2"; shift 2 ;;
    -LogPath) LOG_PATH="$2"; shift 2 ;;
    -NoNetwork) NO_NETWORK=1; shift ;;
    -AssumeYes) ASSUME_YES=1; shift ;;
    -Force) FORCE=1; shift ;;
    -h|--help)
      echo "Usage: bash ./bin/windowsfix.sh -Mode Diagnose|Repair|Full|SelfTest|DryRun [-ReportPath path] [-LogPath path] [-NoNetwork] [-AssumeYes] [-Force]"
      exit 0
      ;;
    *) echo "Unknown argument: $1"; exit 3 ;;
  esac
done

case "$MODE" in Diagnose|Repair|Full|SelfTest|DryRun) ;; *) echo "Invalid mode: $MODE"; exit 3;; esac

TS="$(date +%Y%m%d_%H%M%S_%3N)"
if [[ -z "$REPORT_PATH" ]]; then
  REPORT_PATH="$REPO_ROOT/Outputs/WindowsFix_$TS"
fi
mkdir -p "$REPORT_PATH"

TRANSCRIPT_PATH="$REPORT_PATH/transcript.log"
TOOLKIT_LOG_PATH="${LOG_PATH:-$REPORT_PATH/toolkit.log}"
[[ "$TOOLKIT_LOG_PATH" == "$TRANSCRIPT_PATH" ]] && TOOLKIT_LOG_PATH="$REPORT_PATH/toolkit.log"

{
  echo "SCRIPT_BUILD    : $SCRIPT_BUILD"
  echo "ScriptPath      : $0"
  echo "PWD             : $(pwd)"
  echo "BashVersion     : ${BASH_VERSION:-unknown}"
  echo "Mode            : $MODE"
  echo "ReportPath      : $REPORT_PATH"
  echo "ToolkitLogPath  : $TOOLKIT_LOG_PATH"
  echo "TranscriptPath  : $TRANSCRIPT_PATH"
} | tee -a "$TRANSCRIPT_PATH"

set +e
run_toolkit
EXIT_CODE=$?
set -e

echo "ExitCode=$EXIT_CODE" | tee -a "$TRANSCRIPT_PATH" >/dev/null
exit "$EXIT_CODE"
