#!/usr/bin/env bash
set -Eeuo pipefail

# Reticulum RNode firmware updater.
#
# Operator summary:
# - Run as root with a serial port plus optional flags, or use --tui for prompts.
# - Use --show-device-info for a safe read-only interrogation path.
#
# Intended environment:
# - Linux host running systemd, with the Reticulum service installed as SERVICE_NAME
# - Reticulum Python venv present at VENV and owned by RETICULUM_USER
# - RNode exposed as the serial device passed with --port or as the positional arg
#
# Workflow:
# 1. Stop the owning service so the serial port is free.
# 2. Optionally interrogate the attached device with rnodeconf --info.
# 3. Compare the reported device firmware version with the latest installed RNS version.
# 4. Skip flashing when the versions already match, unless --force is set.
# 5. Upgrade rns in the configured virtual environment and run rnodeconf --autoinstall.
#
# Maintainer map:
# - Defaults and operator-tunable behavior live in the variable block below.
# - usage() is the CLI contract and must stay aligned with the parser and run_tui().
# - capture_logged() is the helper to preserve stdout while still logging command output.
# - show_device_info() is the read-only diagnostic path.
# - extract_device_version() and extract_latest_rns_version() implement version comparison.
# - The main execution path enforces root access, performs version checks, and runs the update.
#
# Support notes:
# - Root access is intentional because service control, log file writes, and venv updates rely on it.
# - Keep argument quoting intact inside capture_logged() so commands with spaces survive unchanged.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/Users/johncanty/Documents/PlatformIO/Projects/MeshpointScripts/tui_common.sh
source "${SCRIPT_DIR}/tui_common.sh"

TAG="reticulum-update"
PORT=""
LOG_FILE="/var/log/rnode-update.log"
VENV="/var/lib/reticulum/venv"
SERVICE_NAME="reticulum"
RETICULUM_USER="reticulum"
MAX_RETRIES=3
RETRY_DELAY=5
FORCE="0"
SHOW_DEVICE_INFO="0"
TUI_MODE="0"
SERVICE_STOPPED="0"

usage() {
  cat <<EOF
Usage:
  sudo $0 /dev/ttyUSB0 [OPTIONS]
  sudo $0 --port /dev/ttyUSB0 [OPTIONS]

Examples:
  sudo $0 /dev/ttyUSB0
  sudo $0 /dev/ttyUSB0 --show-device-info
  sudo $0 /dev/ttyUSB0 --force
  sudo $0 --tui

Options:
  --port PATH              Serial port path (alternative to positional argument)
  --show-device-info       Query current RNode device info and exit
  --tui                    Launch an interactive menu and collect the required settings
  --service NAME           systemd service to stop/start (default: reticulum)
  --log-file PATH          Log file path (default: /var/log/rnode-update.log)
  --force                  Update even if the installed firmware already matches
  -h, --help               Show this help text and exit

Requirements:
  - Must be run as root or via sudo
  - systemctl, lsof, logger, python3, and sudo available in PATH
  - ${VENV}/bin/pip and ${VENV}/bin/rnodeconf present and executable
  - Service ${SERVICE_NAME}.service installed

Behavior:
  - Stops [--service] if it is active and restarts it on exit.
  - Uses rnodeconf --info to interrogate the attached RNode.
  - Skips flashing when the device firmware version matches the latest RNS version, unless --force.
  - Upgrades rns in the configured virtual environment and runs rnodeconf --autoinstall.
EOF
}

log() {
  local timestamp
  if timestamp="$(date -Is 2>/dev/null)"; then
    :
  else
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  fi
  printf '%s %s\n' "$timestamp" "$*" | tee -a "$LOG_FILE" | logger -t "$TAG" >/dev/null
}

die() {
  log "ERROR: $*"
  exit 1
}

need_arg() {
  [[ $# -ge 2 && -n "${2:-}" ]] || die "Option $1 requires a value"
}

on_exit() {
  local rc=$?
  if [[ "$SERVICE_STOPPED" == "1" ]]; then
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
      log "Service $SERVICE_NAME already running."
    else
      log "Restarting $SERVICE_NAME..."
      systemctl start "$SERVICE_NAME" 2>/dev/null || log "WARN: Failed to start $SERVICE_NAME"
    fi
  fi
  [[ $rc -eq 0 ]] || log "Script exited with code $rc"
}
trap on_exit EXIT

on_err() {
  local code=$?
  log "FAIL (exit=$code) at line ${BASH_LINENO[0]}: ${BASH_COMMAND}"
}
trap on_err ERR

retry() {
  local attempts="$1"; shift
  local sleep_s="$1"; shift
  local n=1
  while true; do
    if "$@"; then return 0; fi
    (( n >= attempts )) && return 1
    log "Retry $n/$attempts failed: $* ; sleeping ${sleep_s}s"
    sleep "$sleep_s"
    n=$(( n + 1 ))
  done
}

run() {
  log "RUN: $*"
  "$@" 2>&1 | tee -a "$LOG_FILE" | logger -t "$TAG" >/dev/null
}

capture_logged() {
  local output
  output="$("$@" 2>&1 || true)"
  [[ -n "$output" ]] && printf '%s\n' "$output" | tee -a "$LOG_FILE" | logger -t "$TAG" >/dev/null
  printf '%s' "$output"
}

stop_service_if_needed() {
  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    log "Stopping $SERVICE_NAME..."
    systemctl stop "$SERVICE_NAME" || die "Failed to stop $SERVICE_NAME"
    SERVICE_STOPPED="1"
  else
    log "Service $SERVICE_NAME is not active, continuing."
  fi
}

ensure_port_free() {
  if lsof "$PORT" &>/dev/null; then
    die "Port $PORT is still held by another process after stopping $SERVICE_NAME"
  fi
}

show_device_info() {
  log "Reading RNode device info from $PORT"
  retry 3 3 run sudo -u "$RETICULUM_USER" "${VENV}/bin/rnodeconf" --info "$PORT"
}

run_tui() {
  local action

  tui_require_terminal || exit 1
  tui_print_heading "Reticulum updater TUI"

  if [[ -n "$PORT" ]]; then
    PORT="$(tui_prompt_default_or_custom "RNode serial port" "$PORT")"
  else
    PORT="$(tui_select_serial_port "Select RNode serial port")"
  fi

  action="$(tui_select_menu "Choose Reticulum action" "Update attached RNode" "Show current device info")"

  SERVICE_NAME="$(tui_prompt_default_or_custom "Reticulum systemd service name" "$SERVICE_NAME")"
  LOG_FILE="$(tui_prompt_default_or_custom "Reticulum log file path" "$LOG_FILE")"

  if [[ "$action" == "Show current device info" ]]; then
    SHOW_DEVICE_INFO="1"
    return 0
  fi

  FORCE="$(tui_prompt_yes_no "Force update even if the installed firmware already matches the latest RNS version?" "No")"
}

extract_device_version() {
  local info_text="$1"
  printf '%s\n' "$info_text" \
    | python3 -c 'import re, sys
text = sys.stdin.read()
m = re.search(r"Firmware version[^0-9]*([0-9][0-9A-Za-z.]*)", text, re.I)
print(m.group(1) if m else "")'
}

extract_latest_rns_version() {
  local versions_text="$1"
  printf '%s\n' "$versions_text" \
    | python3 -c 'import re, sys
text = sys.stdin.read()
m = re.search(r"rns \(([0-9.]+)\)", text, re.I)
print(m.group(1) if m else "")'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      need_arg "$@"
      PORT="$2"
      shift 2
      ;;
    --show-device-info)
      SHOW_DEVICE_INFO="1"
      shift
      ;;
    --tui)
      TUI_MODE="1"
      shift
      ;;
    --service)
      need_arg "$@"
      SERVICE_NAME="$2"
      shift 2
      ;;
    --log-file)
      need_arg "$@"
      LOG_FILE="$2"
      shift 2
      ;;
    --force)
      FORCE="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      if [[ -z "$PORT" ]]; then
        PORT="$1"
        shift
      else
        die "Unexpected argument: $1"
      fi
      ;;
  esac
done

[[ -n "$PORT" ]] || { usage; exit 2; }

if [[ "$EUID" -ne 0 ]]; then
  echo "[!] This script must be run as root or with sudo. Exiting."
  exit 1
fi

if [[ "$TUI_MODE" == "1" ]]; then
  run_tui
fi

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 640 "$LOG_FILE"

[[ -c "$PORT" ]] || die "Port $PORT does not exist or is not a character device"
[[ -x "${VENV}/bin/pip" ]] || die "pip not found at ${VENV}/bin/pip"
[[ -x "${VENV}/bin/rnodeconf" ]] || die "rnodeconf not found at ${VENV}/bin/rnodeconf"

if ! systemctl cat "${SERVICE_NAME}.service" >/dev/null 2>&1; then
  die "systemd service '${SERVICE_NAME}' not found"
fi

log "Starting Reticulum updater"
log "PORT=$PORT SERVICE=$SERVICE_NAME FORCE=$FORCE SHOW_DEVICE_INFO=$SHOW_DEVICE_INFO LOG_FILE=$LOG_FILE"

stop_service_if_needed
ensure_port_free

if [[ "$SHOW_DEVICE_INFO" == "1" ]]; then
  show_device_info
  exit 0
fi

log "Checking installed firmware version on ${PORT}"
DEVICE_INFO="$(capture_logged sudo -u "$RETICULUM_USER" "${VENV}/bin/rnodeconf" --info "$PORT")"
DEVICE_VERSION="$(extract_device_version "$DEVICE_INFO")"

if [[ -z "$DEVICE_VERSION" ]]; then
  log "WARNING: Could not determine device firmware version — proceeding with update path"
else
  log "Device firmware version: ${DEVICE_VERSION}"
fi

log "Checking latest available RNS version via pip index"
PIP_VERSIONS="$(capture_logged sudo -u "$RETICULUM_USER" "${VENV}/bin/pip" index versions rns)"
LATEST_VERSION="$(extract_latest_rns_version "$PIP_VERSIONS")"

if [[ -z "$LATEST_VERSION" ]]; then
  log "WARNING: Could not determine latest RNS version — proceeding with update path"
else
  log "Latest available RNS version: ${LATEST_VERSION}"
fi

if [[ "$FORCE" == "0" && -n "$DEVICE_VERSION" && -n "$LATEST_VERSION" ]]; then
  if [[ "$DEVICE_VERSION" == "$LATEST_VERSION" ]]; then
    log "Device is already running the latest firmware version (${DEVICE_VERSION}). No update needed."
    echo "Up to date. Log: ${LOG_FILE}"
    exit 0
  fi
  log "Update required: device=${DEVICE_VERSION} latest=${LATEST_VERSION}"
elif [[ "$FORCE" == "1" ]]; then
  log "--force set. Updating regardless of version match."
fi

log "Upgrading RNS in venv at ${VENV}"
retry "$MAX_RETRIES" "$RETRY_DELAY" \
  run sudo -u "$RETICULUM_USER" "${VENV}/bin/pip" install --upgrade rns

log "Running autoinstall on RNode at ${PORT}"
retry "$MAX_RETRIES" "$RETRY_DELAY" \
  run sudo -u "$RETICULUM_USER" "${VENV}/bin/rnodeconf" --autoinstall "$PORT"

show_device_info || log "WARN: Could not read updated RNode info after autoinstall"

log "Starting ${SERVICE_NAME} service"
run systemctl start "$SERVICE_NAME"
SERVICE_STOPPED="0"

sleep 3

if ! systemctl is-active --quiet "$SERVICE_NAME"; then
  die "${SERVICE_NAME} started but is not active — check: journalctl -u ${SERVICE_NAME}"
fi

log "Done. ${SERVICE_NAME} is running."
run systemctl status "$SERVICE_NAME" --no-pager

echo
echo "OK. Log: ${LOG_FILE}"