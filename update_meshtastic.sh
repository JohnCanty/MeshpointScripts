#!/usr/bin/env bash
set -Eeuo pipefail

# Meshtastic firmware updater for Heltec V3 devices.
#
# Operator summary:
# - Run with a serial port plus optional flags, or use --tui for prompts.
# - Use --show-device-info for a safe read-only interrogation path.
#
# Intended environment:
# - Linux host with systemd managing the service that normally owns the port
# - Serial device exposed at the path passed with --port or as the positional arg
# - curl, git, unzip, lsof, logger, python3, sudo, esptool, and meshtastic available
# - Network access to the latest public GitHub release pages for meshtastic/firmware
#
# Workflow:
# 1. Stop the owning service so the serial port is free.
# 2. Optionally interrogate the attached device for current info.
# 3. Verify the ESP32-S3 answers on the requested port.
# 4. Query GitHub for the newest firmware-esp32s3 release zip.
# 5. Skip flashing when STATE_FILE already records an equal or newer release,
#    unless --force is set.
# 6. Download, unzip, flash, apply region and owner settings, and record the
#    successful release metadata.
#
# Maintainer map:
# - Defaults and operator-tunable behavior live in the variable block below.
# - usage() is the CLI contract and must stay aligned with the parser and run_tui().
# - show_device_info() is the read-only diagnostic path.
# - github_release_common.sh resolves the latest public release and matching asset.
# - get_latest_release_info() resolves the GitHub asset to download.
# - read_state_published_at() and write_state() implement release gating.
# - The main execution path handles download, unpack, flash, post-flash config, and verification.
#
# Support notes:
# - If you add a new flag, update usage(), the parser, run_tui(), and README together.
# - Release discovery is intentionally anonymous and does not depend on GitHub API tokens.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./tui_common.sh
source "${SCRIPT_DIR}/tui_common.sh"
# shellcheck source=./github_release_common.sh
source "${SCRIPT_DIR}/github_release_common.sh"

TAG="meshtastic-update"
PORT=""
PRECONNECT_SETTLE_SECS="2"
POST_REBOOT_SETTLE_SECS="8"
ERASE_BAUD="115200"
WRITE_BAUD="460800"
BASE_DIR="${HOME}/MeshtasticDL"
VENV="${HOME}/meshtastic-venv"
LOG_FILE=""
STATE_FILE="${HOME}/.meshtastic_last_flash.json"
SERVICE_NAME="meshpoint"
FORCE="0"
SHOW_DEVICE_INFO="0"
TUI_MODE="0"
REGION="US"
OWNER_NAME="Meshpoint-Home"
SERVICE_STOPPED="0"
WORKDIR=""
ESPTOOL=""
MESHTASTIC=""

usage() {
  cat <<EOF
Usage:
  $0 /dev/ttyUSB0 [OPTIONS]
  $0 --port /dev/ttyUSB0 [OPTIONS]

Examples:
  $0 /dev/ttyUSB0
  $0 /dev/ttyUSB0 --region US --owner Meshpoint-Home
  $0 /dev/ttyUSB0 --force
  $0 /dev/ttyUSB0 --show-device-info
  $0 --tui

Options:
  --port PATH              Serial port path (alternative to positional argument)
  --region NAME            Meshtastic region to apply after flash (default: US)
  --owner NAME             Owner name to apply after flash (default: Meshpoint-Home)
  --show-device-info       Query current Meshtastic device info and exit
  --tui                    Launch an interactive menu and collect the required settings
  --service NAME           systemd service that owns the port (default: meshpoint)
  --force                  Flash even if state file shows firmware is current
  --log-file PATH          Log file path (default: ~/MeshtasticDL/flash-YYYYMMDDTHHMMSS.log)
  -h, --help               Show this help text and exit

Requirements:
  - git, unzip, curl, lsof, logger, and python3 available in PATH
  - ${VENV}/bin/esptool present and executable
  - ${VENV}/bin/meshtastic present and executable

Files:
  - Working directory: ${BASE_DIR}
  - Log file: ${BASE_DIR}/flash-YYYYMMDDTHHMMSS.log
  - Flash state: ${STATE_FILE}

Behavior:
  - Stops [--service] if running and always attempts to restart it on exit.
  - Uses the Meshtastic CLI --info command to interrogate the attached device.
  - Fetches the newest firmware-esp32s3 release zip from GitHub.
  - Flashes only if the release is newer than the stored state, unless --force.
  - Applies the selected region and owner, then re-reads device info after reboot.
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

  if [[ $rc -ne 0 && -n "$WORKDIR" && -d "$WORKDIR" ]]; then
    log "FAILED: leaving artifacts in ${WORKDIR} for inspection"
  elif [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then
    rm -rf "$WORKDIR"
  fi

  if [[ "$SERVICE_STOPPED" == "1" ]]; then
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
      log "Service $SERVICE_NAME already running."
    else
      log "Restarting $SERVICE_NAME..."
      sudo systemctl start "$SERVICE_NAME" 2>/dev/null \
        || log "WARN: Failed to start $SERVICE_NAME"
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

iso_to_epoch() { date -d "$1" +%s 2>/dev/null || echo 0; }

stop_service_if_needed() {
  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    log "Stopping $SERVICE_NAME..."
    sudo systemctl stop "$SERVICE_NAME" || die "Failed to stop $SERVICE_NAME"
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
  log "Reading Meshtastic device info from $PORT"
  retry 3 3 run "$MESHTASTIC" --port "$PORT" --info
}

run_tui() {
  local action
  local log_default
  local region_choice

  tui_require_terminal || exit 1
  tui_print_heading "Meshtastic updater TUI"

  if [[ -n "$PORT" ]]; then
    PORT="$(tui_prompt_default_or_custom "Meshtastic serial port" "$PORT")"
  else
    PORT="$(tui_select_serial_port "Select Meshtastic serial port")"
  fi

  action="$(tui_select_menu "Choose Meshtastic action" "Flash latest firmware" "Show current device info")"

  SERVICE_NAME="$(tui_prompt_default_or_custom "Service that owns the Meshtastic serial port" "$SERVICE_NAME")"

  log_default="$LOG_FILE"
  if [[ -z "$log_default" ]]; then
    log_default="${BASE_DIR}/flash-$(date +%Y%m%dT%H%M%S).log"
  fi
  LOG_FILE="$(tui_prompt_default_or_custom "Meshtastic log file path" "$log_default")"

  if [[ "$action" == "Show current device info" ]]; then
    SHOW_DEVICE_INFO="1"
    return 0
  fi

  region_choice="$(tui_select_menu "Select Meshtastic region" "US" "EU_868" "ANZ" "IN" "KR" "JP" "TW" "MY_919" "SG_923" "TH" "PH_915" "NZ_865" "CN" "Custom")"
  if [[ "$region_choice" == "Custom" ]]; then
    REGION="$(tui_prompt_input "Enter Meshtastic region name" "$REGION")"
  else
    REGION="$region_choice"
  fi

  OWNER_NAME="$(tui_prompt_default_or_custom "Meshtastic owner name" "$OWNER_NAME")"
  FORCE="$(tui_prompt_yes_no "Force flashing even if the Meshtastic state file says the release is current?" "No")"
}

get_latest_release_info() {
  github_latest_release_asset_info \
    "meshtastic/firmware" \
    '^v' \
    '^firmware-esp32s3-.*\.zip$' \
    'last'
}

read_state_published_at() {
  [[ -f "$STATE_FILE" ]] || return 1
  python3 -c '
import json, sys
print(json.load(open(sys.argv[1])).get("published_at", "").strip())
' "$STATE_FILE"
}

write_state() {
  python3 -c '
import json, sys, time
out = {
  "release_id": sys.argv[1],
    "published_at": sys.argv[2],
    "tag_name": sys.argv[3],
    "asset_name": sys.argv[4],
    "port": sys.argv[5],
    "region": sys.argv[6],
    "owner": sys.argv[7],
    "recorded_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}
with open(sys.argv[8], "w") as f:
    json.dump(out, f, indent=2)
' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$STATE_FILE"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      need_arg "$@"
      PORT="$2"
      shift 2
      ;;
    --region)
      need_arg "$@"
      REGION="$2"
      shift 2
      ;;
    --owner)
      need_arg "$@"
      OWNER_NAME="$2"
      shift 2
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
    --show-device-info)
      SHOW_DEVICE_INFO="1"
      shift
      ;;
    --tui)
      TUI_MODE="1"
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

if [[ "$TUI_MODE" == "1" ]]; then
  run_tui
fi

[[ -n "$PORT" ]] || { usage; exit 2; }
mkdir -p "$BASE_DIR"

if [[ -z "$LOG_FILE" ]]; then
  LOG_FILE="${BASE_DIR}/flash-$(date +%Y%m%dT%H%M%S).log"
fi
touch "$LOG_FILE"

[[ -c "$PORT" ]] || die "Port not found: $PORT"

ESPTOOL="${VENV}/bin/esptool"
MESHTASTIC="${VENV}/bin/meshtastic"
[[ -x "$ESPTOOL" ]] || die "esptool not found at $ESPTOOL"
[[ -x "$MESHTASTIC" ]] || die "meshtastic CLI not found at $MESHTASTIC"

log "Starting Meshtastic updater"
log "PORT=$PORT SERVICE=$SERVICE_NAME FORCE=$FORCE SHOW_DEVICE_INFO=$SHOW_DEVICE_INFO REGION=$REGION OWNER=$OWNER_NAME LOG_FILE=$LOG_FILE"
log "STATE_FILE=$STATE_FILE BASE_DIR=$BASE_DIR"

stop_service_if_needed
ensure_port_free

if [[ "$SHOW_DEVICE_INFO" == "1" ]]; then
  show_device_info
  exit 0
fi

log "Attempting to read current device info before update"
if ! show_device_info; then
  log "WARN: Could not read current Meshtastic device info before flashing"
fi

log "Settling ${PRECONNECT_SETTLE_SECS}s before first connect..."
sleep "$PRECONNECT_SETTLE_SECS"

log "Verifying chip connection..."
retry 5 2 run "$ESPTOOL" \
  --port "$PORT" --chip esp32s3 --baud 115200 \
  --before default-reset --after hard-reset \
  chip-id \
  || die "Chip did not respond on $PORT"

log "Querying public GitHub release pages for the latest release..."
IFS=$'\t' read -r LATEST_REF LATEST_DATE LATEST_TAG ZIP_URL ZIP_NAME \
  < <(retry 3 5 get_latest_release_info) \
  || die "Failed to retrieve release info from GitHub"

log "Latest release_ref=$LATEST_REF published_at=$LATEST_DATE tag=$LATEST_TAG asset=$ZIP_NAME"

DO_FLASH="1"
if [[ "$FORCE" == "0" ]]; then
  if PREV_DATE="$(read_state_published_at 2>/dev/null)"; then
    LATEST_EPOCH="$(iso_to_epoch "$LATEST_DATE")"
    PREV_EPOCH="$(iso_to_epoch "$PREV_DATE")"
    if (( LATEST_EPOCH <= PREV_EPOCH )); then
      log "Firmware is current (state: $PREV_DATE). Skipping flash."
      DO_FLASH="0"
    else
      log "Newer firmware available ($LATEST_DATE > $PREV_DATE). Will flash."
    fi
  else
    log "No state file found. Will flash."
  fi
else
  log "--force set. Will flash regardless of state."
fi

if [[ "$DO_FLASH" == "0" ]]; then
  exit 0
fi

WORKDIR="$(mktemp -d "${BASE_DIR}/firmware-esp32s3-XXXXXX")"
ZIP_PATH="${WORKDIR}/${ZIP_NAME}"

log "Downloading ${ZIP_NAME}"
retry 3 5 run curl -fL -o "$ZIP_PATH" "$ZIP_URL" \
  || die "Failed to download firmware zip"

log "Extracting to ${WORKDIR}"
retry 3 5 run unzip -o "$ZIP_PATH" -d "$WORKDIR" \
  || die "Failed to extract firmware zip"

FW_BIN="$(find "$WORKDIR" -maxdepth 1 -type f -name 'firmware-heltec-v3-*.bin' ! -name '*-update.bin' | sort | head -n 1 || true)"
[[ -n "$FW_BIN" ]] || die "Could not find non-update Heltec V3 firmware bin in ${WORKDIR}"

log "Using firmware: $(basename "$FW_BIN")"

log "Erasing flash..."
retry 3 5 run "$ESPTOOL" \
  --port "$PORT" --chip esp32s3 --baud "$ERASE_BAUD" \
  erase-flash \
  || die "Erase failed"

log "Writing firmware..."
retry 3 5 run "$ESPTOOL" \
  --port "$PORT" --chip esp32s3 --baud "$WRITE_BAUD" \
  write-flash \
  --flash-mode dio --flash-freq 80m --flash-size 8MB \
  0x0 "$FW_BIN" \
  || die "Write failed"

log "Flash completed, waiting for reboot"
sleep "$POST_REBOOT_SETTLE_SECS"

log "Setting Meshtastic region to ${REGION}"
retry 5 8 run "$MESHTASTIC" --port "$PORT" --set lora.region "$REGION" \
  || die "Failed to set Meshtastic region"

log "Setting Meshtastic owner to ${OWNER_NAME}"
retry 5 8 run "$MESHTASTIC" --port "$PORT" --set-owner "$OWNER_NAME" \
  || die "Failed to set Meshtastic owner"

show_device_info || die "Failed to read Meshtastic device info after flashing"

write_state "$LATEST_REF" "$LATEST_DATE" "$LATEST_TAG" "$ZIP_NAME" "$PORT" "$REGION" "$OWNER_NAME"

log "SUCCESS: flashed ${ZIP_NAME} to $PORT, applied region/owner settings, and wrote state to $STATE_FILE"