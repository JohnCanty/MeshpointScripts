#!/usr/bin/env bash
set -Eeuo pipefail

# MeshCore companion firmware updater for Heltec V3 radios.
#
# Operator summary:
# - Run with a serial port plus optional flags, or use --tui for prompts.
# - Use --show-device-info for a safe read-only interrogation path.
#
# Intended environment:
# - Linux host with systemd managing the service that normally owns the port
# - Serial device exposed at the path passed with --port or as the positional arg
# - curl, git, lsof, logger, python3, sudo, esptool, and meshcli available
#
# Workflow:
# 1. Stop the owning service so the serial port is free.
# 2. Optionally interrogate the attached device for current info/version.
# 3. Verify the ESP32-S3 answers on the requested port.
# 4. Query GitHub for the newest Companion Firmware release matching the
#    selected transport.
# 5. Skip flashing when STATE_FILE already records an equal or newer release,
#    unless --force is set.
# 6. Download, erase, flash, apply the selected radio settings, verify them,
#    and record the successful release metadata.
#
# Maintainer map:
# - Defaults and operator-tunable behavior live in the variable block below.
# - usage() is the CLI contract and must stay aligned with the parser and run_tui().
# - resolve_radio_preset() and validate_radio_params() define accepted radio inputs.
# - show_device_info() is the read-only diagnostic path.
# - github_release_common.sh resolves the latest public companion release and asset.
# - get_latest_release_info(), read_state_published_at(), and write_state() implement release gating.
# - The main execution path handles preflight checks, flashing, radio configuration, and state persistence.
#
# Support notes:
# - If you add a new flag, update usage(), the parser, run_tui(), and README together.
# - The shared TUI helpers print prompts to stderr and return values on stdout so command substitution stays clean.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/Users/johncanty/Documents/PlatformIO/Projects/MeshpointScripts/tui_common.sh
source "${SCRIPT_DIR}/tui_common.sh"
# shellcheck source=/Users/johncanty/Documents/PlatformIO/Projects/MeshpointScripts/github_release_common.sh
source "${SCRIPT_DIR}/github_release_common.sh"

TAG="meshcore-update"
PORT=""
TRANSPORT="usb"
DWELL_SECS="10"
PRECONNECT_SETTLE_SECS="2"
POST_REBOOT_SETTLE_SECS="8"
ERASE_BAUD="115200"
WRITE_BAUD="460800"
RADIO_PRESET="us915-legacy"
RADIO_PARAMS=""
VENV="${HOME}/meshcore-venv"
LOG_FILE="${HOME}/meshcore_update.log"
STATE_FILE="${HOME}/.meshcore_companion_last_flash.json"
SERVICE_NAME="meshpoint"
FORCE="0"
SHOW_DEVICE_INFO="0"
TUI_MODE="0"
SERVICE_STOPPED="0"
RADIO_SETTINGS_NAME=""
RADIO_SETTINGS_LABEL=""
RADIO_SETTINGS_TUPLE=""
WORKDIR=""
ESPT=""
MESHCLI=""

usage() {
  cat <<EOF
Usage:
  $0 /dev/ttyUSB0 [OPTIONS]
  $0 --port /dev/ttyUSB0 [OPTIONS]

Examples:
  $0 /dev/ttyUSB0
  $0 /dev/ttyUSB0 --radio-preset eu-uk-narrow
  $0 /dev/ttyUSB0 --radio-params 910.525,62.5,7,5
  $0 /dev/ttyUSB0 --transport ble --force
  $0 /dev/ttyUSB0 --show-device-info
  $0 --tui
  $0 --list-radio-presets

Options:
  --port PATH              Serial port path (alternative to positional argument)
  --transport usb|ble      Firmware transport variant (default: usb)
  --radio-preset NAME      Radio preset applied after flash (default: us915-legacy)
  --radio-params SPEC      Custom radio tuple freq,bw,sf,cr; overrides --radio-preset
  --list-radio-presets     Print supported radio presets and exit
  --show-device-info       Query current node info/version/radio settings and exit
  --tui                    Launch an interactive menu and collect the required settings
  --service NAME           systemd service that owns the port (default: meshpoint)
  --force                  Flash even if state file shows firmware is current
  --log-file PATH          Log file path (default: ~/meshcore_update.log)
  -h, --help               Show this help text and exit

Requirements:
  - Linux host with systemd and sudo permissions to stop/start [--service]
  - git, curl, lsof, logger, and python3 available in PATH
  - ${VENV}/bin/esptool present and executable
  - ${VENV}/bin/meshcli present and executable

Files:
  - Log output: ${LOG_FILE}
  - Flash state: ${STATE_FILE}

Behavior:
  - Stops [--service] if running and always attempts to restart it on exit.
  - Uses meshcli to query the current companion firmware with the 'ver' command.
  - Fetches the newest Companion Firmware asset matching the selected transport.
  - Flashes only if the release is newer than the stored state, unless --force.
  - Applies the selected radio preset or custom tuple, reboots, and verifies the radio settings.
  - Writes release metadata to the state file after a successful flash and verification.
EOF
}

list_radio_presets() {
  cat <<'EOF'
Supported radio presets:
  us915-legacy             910.525,250,11,5  US 915 (Legacy default)
  usa-canada-recommended   910.525,62.5,7,5  USA/Canada (Recommended)
  eu-uk-narrow             869.618,62.5,8,8  EU/UK (Narrow)
  eu-uk-deprecated         869.525,250,11,5  EU/UK (Deprecated)
  australia                915.800,250,10,5  Australia
  australia-narrow         916.575,62.5,7,8  Australia (Narrow)
  australia-mid            915.075,125,9,5   Australia (Mid)
  australia-sa-wa          923.125,62.5,8,8  Australia: SA, WA
  australia-qld            923.125,62.5,8,5  Australia: QLD
  new-zealand              917.375,250,11,5  New Zealand
  new-zealand-narrow       917.375,62.5,7,5  New Zealand (Narrow)
  switzerland              869.618,62.5,8,8  Switzerland
  czech-republic-narrow    869.432,62.5,7,5  Czech Republic (Narrow)
  portugal-868             869.618,62.5,7,6  Portugal 868
  portugal-433             433.375,62.5,9,6  Portugal 433
  eu-433-long-range        433.650,250,11,5  EU 433MHz (Long Range)
  eu-433-narrow            433.650,62.5,8,8  EU 433MHz (Narrow)
  vietnam-narrow           920.250,62.5,8,5  Vietnam (Narrow)
  vietnam-deprecated       920.250,250,11,5  Vietnam (Deprecated)

Aliases:
  us915         -> us915-legacy
  us915-narrow  -> usa-canada-recommended
  eu868         -> eu-uk-narrow
  au915         -> australia-narrow
  nz915         -> new-zealand-narrow
  eu433         -> eu-433-narrow
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

  if [[ $rc -eq 0 ]]; then
    [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
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

validate_radio_params() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+([.][0-9]+)?,[0-9]+([.][0-9]+)?,[0-9]+,[0-9]+$ ]]
}

resolve_radio_preset() {
  local preset_key
  preset_key="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

  case "$preset_key" in
    us915-legacy|us915|us915-wide)
      RADIO_SETTINGS_NAME="us915-legacy"
      RADIO_SETTINGS_LABEL="US 915 (Legacy)"
      RADIO_SETTINGS_TUPLE="910.525,250,11,5"
      ;;
    usa-canada-recommended|us915-narrow|usa-canada|us-canada)
      RADIO_SETTINGS_NAME="usa-canada-recommended"
      RADIO_SETTINGS_LABEL="USA/Canada (Recommended)"
      RADIO_SETTINGS_TUPLE="910.525,62.5,7,5"
      ;;
    eu-uk-narrow|eu868)
      RADIO_SETTINGS_NAME="eu-uk-narrow"
      RADIO_SETTINGS_LABEL="EU/UK (Narrow)"
      RADIO_SETTINGS_TUPLE="869.618,62.5,8,8"
      ;;
    eu-uk-deprecated)
      RADIO_SETTINGS_NAME="eu-uk-deprecated"
      RADIO_SETTINGS_LABEL="EU/UK (Deprecated)"
      RADIO_SETTINGS_TUPLE="869.525,250,11,5"
      ;;
    australia)
      RADIO_SETTINGS_NAME="australia"
      RADIO_SETTINGS_LABEL="Australia"
      RADIO_SETTINGS_TUPLE="915.800,250,10,5"
      ;;
    australia-narrow|au915)
      RADIO_SETTINGS_NAME="australia-narrow"
      RADIO_SETTINGS_LABEL="Australia (Narrow)"
      RADIO_SETTINGS_TUPLE="916.575,62.5,7,8"
      ;;
    australia-mid)
      RADIO_SETTINGS_NAME="australia-mid"
      RADIO_SETTINGS_LABEL="Australia (Mid)"
      RADIO_SETTINGS_TUPLE="915.075,125,9,5"
      ;;
    australia-sa-wa)
      RADIO_SETTINGS_NAME="australia-sa-wa"
      RADIO_SETTINGS_LABEL="Australia: SA, WA"
      RADIO_SETTINGS_TUPLE="923.125,62.5,8,8"
      ;;
    australia-qld)
      RADIO_SETTINGS_NAME="australia-qld"
      RADIO_SETTINGS_LABEL="Australia: QLD"
      RADIO_SETTINGS_TUPLE="923.125,62.5,8,5"
      ;;
    new-zealand)
      RADIO_SETTINGS_NAME="new-zealand"
      RADIO_SETTINGS_LABEL="New Zealand"
      RADIO_SETTINGS_TUPLE="917.375,250,11,5"
      ;;
    new-zealand-narrow|nz915)
      RADIO_SETTINGS_NAME="new-zealand-narrow"
      RADIO_SETTINGS_LABEL="New Zealand (Narrow)"
      RADIO_SETTINGS_TUPLE="917.375,62.5,7,5"
      ;;
    switzerland)
      RADIO_SETTINGS_NAME="switzerland"
      RADIO_SETTINGS_LABEL="Switzerland"
      RADIO_SETTINGS_TUPLE="869.618,62.5,8,8"
      ;;
    czech-republic-narrow)
      RADIO_SETTINGS_NAME="czech-republic-narrow"
      RADIO_SETTINGS_LABEL="Czech Republic (Narrow)"
      RADIO_SETTINGS_TUPLE="869.432,62.5,7,5"
      ;;
    portugal-868)
      RADIO_SETTINGS_NAME="portugal-868"
      RADIO_SETTINGS_LABEL="Portugal 868"
      RADIO_SETTINGS_TUPLE="869.618,62.5,7,6"
      ;;
    portugal-433)
      RADIO_SETTINGS_NAME="portugal-433"
      RADIO_SETTINGS_LABEL="Portugal 433"
      RADIO_SETTINGS_TUPLE="433.375,62.5,9,6"
      ;;
    eu-433-long-range)
      RADIO_SETTINGS_NAME="eu-433-long-range"
      RADIO_SETTINGS_LABEL="EU 433MHz (Long Range)"
      RADIO_SETTINGS_TUPLE="433.650,250,11,5"
      ;;
    eu-433-narrow|eu433)
      RADIO_SETTINGS_NAME="eu-433-narrow"
      RADIO_SETTINGS_LABEL="EU 433MHz (Narrow)"
      RADIO_SETTINGS_TUPLE="433.650,62.5,8,8"
      ;;
    vietnam-narrow)
      RADIO_SETTINGS_NAME="vietnam-narrow"
      RADIO_SETTINGS_LABEL="Vietnam (Narrow)"
      RADIO_SETTINGS_TUPLE="920.250,62.5,8,5"
      ;;
    vietnam-deprecated)
      RADIO_SETTINGS_NAME="vietnam-deprecated"
      RADIO_SETTINGS_LABEL="Vietnam (Deprecated)"
      RADIO_SETTINGS_TUPLE="920.250,250,11,5"
      ;;
    *)
      return 1
      ;;
  esac
}

run_tui() {
  local action
  local service_prompt
  local log_prompt
  local radio_mode
  local default_tuple
  local custom_tuple
  local -a preset_names=()

  tui_require_terminal || exit 1
  tui_print_heading "MeshCore updater TUI"

  if [[ -n "$PORT" ]]; then
    PORT="$(tui_prompt_default_or_custom "MeshCore serial port" "$PORT")"
  else
    PORT="$(tui_select_serial_port "Select MeshCore serial port")"
  fi

  action="$(tui_select_menu "Choose MeshCore action" "Flash latest companion firmware" "Show current device info")"

  service_prompt="Service that owns the MeshCore serial port"
  SERVICE_NAME="$(tui_prompt_default_or_custom "$service_prompt" "$SERVICE_NAME")"

  log_prompt="MeshCore log file path"
  LOG_FILE="$(tui_prompt_default_or_custom "$log_prompt" "$LOG_FILE")"

  if [[ "$action" == "Show current device info" ]]; then
    SHOW_DEVICE_INFO="1"
    return 0
  fi

  TRANSPORT="$(tui_select_menu "Select MeshCore firmware transport" "usb" "ble")"

  radio_mode="$(tui_select_menu "Select MeshCore radio configuration" "Use default preset (${RADIO_PRESET})" "Choose named preset" "Enter custom tuple")"
  case "$radio_mode" in
    "Use default preset (${RADIO_PRESET})")
      RADIO_PARAMS=""
      ;;
    "Choose named preset")
      list_radio_presets >&2
      while IFS= read -r preset_name; do
        [[ -n "$preset_name" ]] && preset_names+=("$preset_name")
      done < <(list_radio_presets | awk 'NR > 1 && $1 == "Aliases:" {exit} NR > 1 && NF {print $1}')
      RADIO_PRESET="$(tui_select_menu "Select MeshCore radio preset" "${preset_names[@]}")"
      RADIO_PARAMS=""
      ;;
    "Enter custom tuple")
      resolve_radio_preset "$RADIO_PRESET"
      default_tuple="$RADIO_SETTINGS_TUPLE"
      while true; do
        custom_tuple="$(tui_prompt_input "Enter custom radio tuple (freq,bw,sf,cr)" "$default_tuple")"
        if validate_radio_params "$custom_tuple"; then
          RADIO_PARAMS="$custom_tuple"
          break
        fi
        printf 'Invalid tuple. Expected format: freq,bw,sf,cr\n' >&2
      done
      ;;
  esac

  FORCE="$(tui_prompt_yes_no "Force flashing even if the MeshCore state file says the release is current?" "No")"
}

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
  log "Reading MeshCore node info from $PORT"
  retry 3 2 run "$MESHCLI" -s "$PORT" infos
  retry 3 2 run "$MESHCLI" -s "$PORT" ver
  retry 3 2 run "$MESHCLI" -s "$PORT" get radio
}

get_latest_release_info() {
  github_latest_release_asset_info \
    "meshcore-dev/MeshCore" \
    '^companion-v' \
    "^Heltec_v3_companion_radio_${TRANSPORT}-.*-merged\.bin$"
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
    "transport": sys.argv[6],
    "radio_preset": sys.argv[7],
    "radio_params": sys.argv[8],
    "recorded_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}
with open(sys.argv[9], "w") as f:
    json.dump(out, f, indent=2)
' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$STATE_FILE"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      need_arg "$@"
      PORT="$2"
      shift 2
      ;;
    --transport)
      need_arg "$@"
      TRANSPORT="$2"
      shift 2
      ;;
    --radio-preset)
      need_arg "$@"
      RADIO_PRESET="$2"
      shift 2
      ;;
    --radio-params)
      need_arg "$@"
      RADIO_PARAMS="$2"
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
    --list-radio-presets)
      list_radio_presets
      exit 0
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
[[ -c "$PORT" ]] || die "Port not found: $PORT"

MESHCLI="${VENV}/bin/meshcli"
[[ -x "$MESHCLI" ]] || die "meshcli not found at $MESHCLI"

if [[ "$SHOW_DEVICE_INFO" == "0" ]]; then
  ESPT="${VENV}/bin/esptool"
  [[ -x "$ESPT" ]] || die "esptool not found at $ESPT"

  if [[ -n "$RADIO_PARAMS" ]]; then
    validate_radio_params "$RADIO_PARAMS" \
      || die "Invalid --radio-params value: $RADIO_PARAMS (expected freq,bw,sf,cr)"
    RADIO_SETTINGS_NAME="custom"
    RADIO_SETTINGS_LABEL="Custom"
    RADIO_SETTINGS_TUPLE="$RADIO_PARAMS"
  else
    resolve_radio_preset "$RADIO_PRESET" \
      || die "Unknown --radio-preset: $RADIO_PRESET (use --list-radio-presets to see supported values)"
  fi
fi

log "Starting MeshCore companion updater"
log "PORT=$PORT TRANSPORT=$TRANSPORT SERVICE=$SERVICE_NAME FORCE=$FORCE SHOW_DEVICE_INFO=$SHOW_DEVICE_INFO LOG_FILE=$LOG_FILE"
if [[ "$SHOW_DEVICE_INFO" == "0" ]]; then
  log "RADIO_PRESET=$RADIO_SETTINGS_NAME RADIO_PARAMS=$RADIO_SETTINGS_TUPLE DWELL_SECS=$DWELL_SECS PRECONNECT_SETTLE_SECS=$PRECONNECT_SETTLE_SECS POST_REBOOT_SETTLE_SECS=$POST_REBOOT_SETTLE_SECS"
  log "STATE_FILE=$STATE_FILE"
  log "esptool reset strategy: --before default-reset --after hard-reset"
fi

stop_service_if_needed
ensure_port_free

if [[ "$SHOW_DEVICE_INFO" == "1" ]]; then
  show_device_info
  exit 0
fi

log "Attempting to read current device info before update"
if ! show_device_info; then
  log "WARN: Could not read current MeshCore device info before flashing"
fi

log "Settling ${PRECONNECT_SETTLE_SECS}s before first connect..."
sleep "$PRECONNECT_SETTLE_SECS"

log "Verifying chip connection..."
retry 5 2 run "$ESPT" \
  --port "$PORT" --chip esp32s3 --baud 115200 \
  --connect-attempts 10 \
  --before default-reset --after hard-reset \
  chip-id \
  || die "Chip did not respond on $PORT"

log "Querying public GitHub release pages for the latest companion release..."
IFS=$'\t' read -r LATEST_REF LATEST_DATE LATEST_TAG BIN_URL BIN_NAME \
  < <(retry 3 5 get_latest_release_info) \
  || die "Failed to retrieve release info from GitHub"

log "Latest release_ref=$LATEST_REF published_at=$LATEST_DATE tag=$LATEST_TAG asset=$BIN_NAME"

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

WORKDIR="$(mktemp -d)"

log "Downloading $BIN_NAME..."
retry 3 5 run curl -fL -o "${WORKDIR}/${BIN_NAME}" "$BIN_URL" \
  || die "Failed to download firmware"

BIN_SIZE="$(stat -c%s "${WORKDIR}/${BIN_NAME}")"
log "Downloaded firmware: ${WORKDIR}/${BIN_NAME} ($BIN_SIZE bytes)"

log "Erasing flash..."
retry 3 5 run "$ESPT" \
  --port "$PORT" --chip esp32s3 --baud "$ERASE_BAUD" \
  --connect-attempts 10 \
  --before default-reset --after no-reset \
  erase-flash \
  || die "Erase failed"

log "Dwell ${DWELL_SECS}s (chip settling after erase)..."
sleep "$DWELL_SECS"

log "Writing firmware..."
retry 3 5 run "$ESPT" \
  --port "$PORT" --chip esp32s3 --baud "$WRITE_BAUD" \
  --connect-attempts 10 \
  --before default-reset --after hard-reset \
  write-flash \
  --flash-mode dio --flash-freq 80m --flash-size 8MB \
  0x0 "${WORKDIR}/${BIN_NAME}" \
  || die "Write failed"

log "Configuring radio settings (${RADIO_SETTINGS_LABEL}: ${RADIO_SETTINGS_TUPLE})"
retry 5 3 run "$MESHCLI" -s "$PORT" set radio "$RADIO_SETTINGS_TUPLE" \
  || die "Failed to apply radio settings"

log "Rebooting radio to apply settings"
retry 3 3 run "$MESHCLI" -s "$PORT" reboot \
  || die "Failed to reboot radio after applying settings"

log "Waiting ${POST_REBOOT_SETTLE_SECS}s for the radio to return"
sleep "$POST_REBOOT_SETTLE_SECS"

show_device_info || die "Failed to read MeshCore device info after reboot"

write_state \
  "$LATEST_REF" "$LATEST_DATE" "$LATEST_TAG" "$BIN_NAME" "$PORT" \
  "$TRANSPORT" "$RADIO_SETTINGS_NAME" "$RADIO_SETTINGS_TUPLE"

log "SUCCESS: flashed $BIN_NAME to $PORT, applied radio settings, and wrote state to $STATE_FILE"