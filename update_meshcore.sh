#!/usr/bin/env bash
set -Eeuo pipefail

# MeshCore companion firmware updater for Heltec V3 radios.
#
# Intended environment:
# - Linux host with systemd managing the service that normally owns the port
# - Serial device exposed at the path passed as the first argument
# - curl, lsof, logger, python3, sudo, and esptool available
#
# Workflow:
# 1. Stop the owning service so the serial port is free.
# 2. Verify the ESP32-S3 answers on the requested port.
# 3. Query GitHub for the newest Companion Firmware release matching the
#    selected transport.
# 4. Skip flashing when STATE_FILE already records an equal or newer release,
#    unless --force is set.
# 5. Download, erase, flash, and record the successful release metadata.
#
# Successful flashes update STATE_FILE. Failures leave the previous state in
# place, and the EXIT trap restarts SERVICE_NAME if this script stopped it.

# ---- Runtime defaults ----
TAG="meshcore-update"
PORT=""
TRANSPORT="usb"
DWELL_SECS="10"
PRECONNECT_SETTLE_SECS="2"
ERASE_BAUD="115200"
WRITE_BAUD="460800"
VENV="${HOME}/meshcore-venv"
LOG_FILE="${HOME}/meshcore_update.log"
STATE_FILE="${HOME}/.meshcore_companion_last_flash.json"
SERVICE_NAME="meshpoint"
FORCE="0"
SERVICE_STOPPED="0"

usage() {
  cat <<EOF
Usage:
  $0 /dev/ttyUSB0 [OPTIONS]

Examples:
  $0 /dev/ttyUSB0
  $0 /dev/ttyUSB0 --transport ble --force
  $0 /dev/ttyUSB0 --service meshpoint --log-file /var/log/meshcore_update.log

Options:
  --transport usb|ble       Firmware transport variant (default: usb)
  --service NAME            systemd service that owns the port (default: meshpoint)
  --force                   Flash even if state file shows firmware is current
  --log-file PATH           Log file path (default: ~/meshcore_update.log)

Requirements:
  - Linux host with systemd and sudo permissions to stop/start [--service]
  - ${VENV}/bin/esptool present and executable
  - curl, lsof, logger, and python3 available in PATH

Files:
  - Log output: ${LOG_FILE}
  - Flash state: ${STATE_FILE}

Behavior:
  - Stops [--service] if running and always attempts to restart it on exit.
  - Fetches the newest Companion Firmware asset matching the selected transport.
  - Flashes only if the release is newer than the stored state, unless --force.
  - Writes release metadata to the state file after a successful flash.
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

# Restore the service on every exit path so the host returns to its normal
# operating state even after a failed flash attempt.
on_exit() {
  local rc=$?
  [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "$WORKDIR"
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

# Select the newest Companion Firmware release and the transport-specific asset
# that matches the naming convention used by MeshCore.
get_latest_release_info() {
  curl -fsSL "https://api.github.com/repos/meshcore-dev/MeshCore/releases?per_page=30" |
  python3 -c '
import json, re, sys
transport = sys.argv[1]
releases = json.load(sys.stdin)
rel = next((r for r in releases if "Companion Firmware" in (r.get("name") or "")), None)
if not rel:
    raise SystemExit("No Companion Firmware release found")
p_at  = (rel.get("published_at") or "").strip()
r_id  = rel.get("id")
tag   = (rel.get("tag_name") or "").strip()
pat   = re.compile(
    rf"^Heltec_v3_companion_radio_{re.escape(transport)}-.*-merged.bin$"
)
asset = next((a for a in rel.get("assets", []) if pat.match(a.get("name", ""))), None)
if not asset:
    raise SystemExit("No matching asset found in release")
print("{}\t{}\t{}\t{}\t{}".format(
  r_id, p_at, tag, asset["browser_download_url"], asset["name"]
))
' "$TRANSPORT"
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
    "release_id":   int(sys.argv[1]),
    "published_at": sys.argv[2],
    "tag_name":     sys.argv[3],
    "asset_name":   sys.argv[4],
    "port":         sys.argv[5],
    "recorded_at":  time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}
with open(sys.argv[6], "w") as f:
    json.dump(out, f, indent=2)
' "$1" "$2" "$3" "$4" "$5" "$STATE_FILE"
}

# ---- Arg Parsing ----
if [[ $# -ge 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  usage
  exit 0
fi

[[ $# -ge 1 && "${1:0:1}" != "-" ]] || { usage; exit 2; }
PORT="$1"; shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --transport) TRANSPORT="$2"; shift 2 ;;
    --service)   SERVICE_NAME="$2"; shift 2 ;;
    --force)     FORCE="1"; shift ;;
    --log-file)  LOG_FILE="$2"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) log "Unknown option: $1"; usage; exit 2 ;;
  esac
done

# ---- Preflight ----
[[ -c "$PORT" ]] || die "Port not found: $PORT"

ESPT="${VENV}/bin/esptool"
[[ -x "$ESPT" ]] || die "esptool not found at $ESPT"

log "Starting MeshCore companion updater"
log "PORT=$PORT TRANSPORT=$TRANSPORT DWELL_SECS=$DWELL_SECS PRECONNECT_SETTLE_SECS=$PRECONNECT_SETTLE_SECS"
log "STATE_FILE=$STATE_FILE FORCE=$FORCE LOG_FILE=$LOG_FILE"
log "esptool reset strategy: --before default-reset --after hard-reset"

WORKDIR="$(mktemp -d)"

# ---- Stop service ----
if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
  log "Stopping $SERVICE_NAME..."
  sudo systemctl stop "$SERVICE_NAME" || die "Failed to stop $SERVICE_NAME"
  SERVICE_STOPPED="1"
else
  log "Service $SERVICE_NAME is not active, continuing."
fi

# ---- Verify port is free ----
if lsof "$PORT" &>/dev/null; then
  die "Port $PORT is still held by another process after stopping $SERVICE_NAME"
fi

# ---- Chip connect check ----
log "Settling ${PRECONNECT_SETTLE_SECS}s before first connect..."
sleep "$PRECONNECT_SETTLE_SECS"

log "Verifying chip connection..."
retry 5 2 run "$ESPT" \
  --port "$PORT" --chip esp32s3 --baud 115200 \
  --connect-attempts 10 \
  --before default-reset --after hard-reset \
  chip-id \
  || die "Chip did not respond on $PORT"

# ---- Check GitHub ----
log "Querying GitHub for latest release..."
IFS=$'\t' read -r LATEST_ID LATEST_DATE LATEST_TAG BIN_URL BIN_NAME \
  < <(retry 3 5 get_latest_release_info) \
  || die "Failed to retrieve release info from GitHub"

log "Latest release_id=$LATEST_ID published_at=$LATEST_DATE tag=$LATEST_TAG asset=$BIN_NAME"

# ---- Version check ----
# Compare release timestamps instead of tags so the script can tolerate release
# naming changes as long as GitHub metadata remains monotonic.
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

# ---- Flash ----
if [[ "$DO_FLASH" == "1" ]]; then

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

  write_state "$LATEST_ID" "$LATEST_DATE" "$LATEST_TAG" "$BIN_NAME" "$PORT"
  log "SUCCESS: flashed $BIN_NAME to $PORT ; state written to $STATE_FILE"

fi
