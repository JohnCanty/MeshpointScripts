#!/usr/bin/env bash
set -euo pipefail

# Meshtastic firmware updater for Heltec V3 devices.
#
# Intended environment:
# - Linux host with a serial device available at the path passed as $1
# - curl, unzip, python3, lsof, and a working Meshtastic venv under VENV
# - Network access to the latest GitHub release for meshtastic/firmware
#
# Workflow:
# 1. Verify required tools and that the target serial port is not in use.
# 2. Confirm the connected device answers as an ESP32-S3.
# 3. Query GitHub for the newest firmware-esp32s3 release zip.
# 4. Download and extract the release, then select the non-update Heltec V3 bin.
# 5. Erase flash, write the image, apply post-flash Meshtastic settings, and
#    clean up downloaded artifacts.
#
# Logs and downloaded files are kept under BASEDIR. On failure, cleanup is
# intentionally skipped so the extracted image and log remain available.

TAG="meshtastic-flash"
BASEDIR="${HOME}/MeshtasticDL"
EXTRACTDIR="${BASEDIR}/firmware-esp32s3-latest"
VENV="${HOME}/meshtastic-venv"
ESPTOOL="${VENV}/bin/esptool"
MESHTASTIC="${VENV}/bin/meshtastic"
MAX_RETRIES=3
RETRY_DELAY=5

PORT="${1:-}"

usage() {
  cat <<EOF
Usage:
  $0 /dev/ttyUSB0 [OPTIONS]

Examples:
  $0 /dev/ttyUSB0
  GH_TOKEN=... $0 /dev/ttyUSB0

Options:
  -h, --help                Show this help text and exit

Environment:
  GH_TOKEN                  Optional GitHub token to avoid API rate limits

Requirements:
  - unzip, curl, python3, and lsof available in PATH
  - ${ESPTOOL} present and executable
  - ${VENV}/bin/pip available if meshtastic must be installed on demand

Files:
  - Working directory: ${BASEDIR}
  - Extracted zip contents: ${EXTRACTDIR}
  - Per-run log file: ${BASEDIR}/flash-YYYYMMDDTHHMMSS.log

Behavior:
  - Leaves extracted artifacts in place on failure for inspection.
  - Chooses the newest firmware-esp32s3-*.zip asset from the latest release.
  - Flashes the non-update Heltec V3 image, then sets region and owner.
EOF
}

log() {
  local msg="$1"
  logger -t "${TAG}" -- "${msg}"
  printf '%s %s\n' "$(date -Is)" "${msg}" >> "${LOGFILE}"
}

run_logged() {
  "$@" 2>&1 | tee -a "${LOGFILE}" | logger -t "${TAG}"
}

# retry <attempts> <delay_seconds> <cmd> [args...]
retry() {
  local attempts="$1" delay="$2"
  shift 2
  local i=1
  until run_logged "$@"; do
    if (( i >= attempts )); then
      log "ERROR: '${*}' failed after ${attempts} attempts"
      return 1
    fi
    log "WARNING: attempt ${i}/${attempts} failed for '${*}', retrying in ${delay}s..."
    sleep "${delay}"
    (( i++ ))
  done
}

cleanup_on_error() {
  local code=$?
  if (( code != 0 )); then
    log "FAILED with exit code ${code}. Leaving artifacts in ${BASEDIR} for inspection."
    log "Log file: ${LOGFILE}"
  fi
}

if [[ "${PORT}" == "-h" || "${PORT}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "${PORT}" ]]; then
  usage >&2
  exit 2
fi

mkdir -p "${BASEDIR}"
LOGFILE="${BASEDIR}/flash-$(date +%Y%m%dT%H%M%S).log"
touch "${LOGFILE}"

trap cleanup_on_error EXIT

log "Starting Heltec V3 flash on port=${PORT}"

# Dependency check
for bin in unzip curl python3 lsof; do
  command -v "${bin}" >/dev/null 2>&1 || { log "Missing dependency: ${bin}"; exit 1; }
done

if [[ ! -x "${ESPTOOL}" ]]; then
  log "Missing esptool at ${ESPTOOL}. Install: ${VENV}/bin/pip install --upgrade esptool"
  exit 1
fi

# Check nothing else is holding the port open
if lsof "${PORT}" >/dev/null 2>&1; then
  log "ERROR: ${PORT} is in use by another process:"
  lsof "${PORT}" | tee -a "${LOGFILE}" | logger -t "${TAG}"
  exit 1
fi

# Verify the device is actually present and responding
log "Verifying device on ${PORT}"
if ! run_logged "${ESPTOOL}" --port "${PORT}" --baud 115200 --chip esp32s3 chip-id; then
  log "ERROR: Could not communicate with device on ${PORT}"
  exit 1
fi

# Fetch latest release
API_URL="https://api.github.com/repos/meshtastic/firmware/releases/latest"
AUTH_HEADER=()
if [[ -n "${GH_TOKEN:-}" ]]; then
  AUTH_HEADER=(-H "Authorization: Bearer ${GH_TOKEN}")
fi

log "Querying GitHub API: ${API_URL}"

# Resolve the latest esp32s3 firmware zip from the GitHub release asset list.
fetch_release() {
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: ${TAG}" \
    "${AUTH_HEADER[@]}" \
    "${API_URL}" |
  python3 -c '
import json, sys
data = json.load(sys.stdin)
assets = data.get("assets", [])
candidates = []
for a in assets:
    name = a.get("name", "")
    url = a.get("browser_download_url", "")
    if name.startswith("firmware-esp32s3-") and name.endswith(".zip") and url:
        candidates.append((name, url))
if not candidates:
    raise SystemExit("No firmware-esp32s3-*.zip asset found in latest release")
name, url = sorted(candidates)[-1]
print(url, name)
'
}

ZIP_URL=""
ZIP_NAME=""
i=1
until read -r ZIP_URL ZIP_NAME < <(fetch_release); do
  if (( i >= MAX_RETRIES )); then
    log "ERROR: GitHub API query failed after ${MAX_RETRIES} attempts"
    exit 1
  fi
  log "WARNING: GitHub API attempt ${i}/${MAX_RETRIES} failed, retrying in ${RETRY_DELAY}s..."
  sleep "${RETRY_DELAY}"
  (( i++ ))
done

if [[ -z "${ZIP_URL}" || -z "${ZIP_NAME}" ]]; then
  log "ERROR: Could not determine ZIP URL or name from GitHub API response"
  exit 1
fi

log "Latest firmware asset: ${ZIP_NAME}"

ZIP_PATH="${BASEDIR}/${ZIP_NAME}"

log "Downloading ${ZIP_NAME}"
retry "${MAX_RETRIES}" "${RETRY_DELAY}" curl -fL -o "${ZIP_PATH}" "${ZIP_URL}"

if [[ ! -f "${ZIP_PATH}" || ! -s "${ZIP_PATH}" ]]; then
  log "ERROR: Downloaded zip is missing or empty: ${ZIP_PATH}"
  exit 1
fi

log "Extracting to ${EXTRACTDIR}"
rm -rf "${EXTRACTDIR}"
mkdir -p "${EXTRACTDIR}"
run_logged unzip -o "${ZIP_PATH}" -d "${EXTRACTDIR}"

# Use the full device image and explicitly ignore incremental update bins.
FW_BIN="$(find "${EXTRACTDIR}" -maxdepth 1 -type f -name 'firmware-heltec-v3-*.bin' ! -name '*-update.bin' | sort | head -n 1 || true)"
if [[ -z "${FW_BIN}" ]]; then
  log "ERROR: Could not find non-update Heltec V3 firmware bin in ${EXTRACTDIR}"
  exit 1
fi

log "Using firmware: $(basename "${FW_BIN}")"

log "Erasing flash"
retry "${MAX_RETRIES}" "${RETRY_DELAY}" \
  "${ESPTOOL}" --port "${PORT}" --baud 115200 --chip esp32s3 erase-flash

log "Writing firmware"
retry "${MAX_RETRIES}" "${RETRY_DELAY}" \
  "${ESPTOOL}" \
    --port "${PORT}" \
    --baud 460800 \
    --chip esp32s3 \
    write-flash \
    --flash-mode dio \
    --flash-freq 80m \
    --flash-size 8MB \
    0x0 "${FW_BIN}"

log "Flash completed, waiting for reboot"
sleep 8

if [[ ! -x "${MESHTASTIC}" ]]; then
  log "meshtastic CLI not found, installing into venv"
  run_logged "${VENV}/bin/pip" install --upgrade meshtastic
fi

# Apply local defaults after the device reboots onto the new firmware.
log "Setting region to US"
retry "${MAX_RETRIES}" 8 \
  "${MESHTASTIC}" --port "${PORT}" --set lora.region US

log "Setting owner to Meshpoint-Home"
retry "${MAX_RETRIES}" 8 \
  "${MESHTASTIC}" --port "${PORT}" --set-owner "Meshpoint-Home"

log "Cleaning up"
rm -rf "${EXTRACTDIR}"
rm -f "${ZIP_PATH}"

log "Done"
echo "OK. Log: ${LOGFILE}"
