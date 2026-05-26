#!/bin/bash

set -euo pipefail

# Reticulum RNode firmware updater.
#
# Intended environment:
# - Linux host running systemd, with the Reticulum service installed as SERVICE
# - Reticulum Python venv present at VENV and owned by the reticulum user
# - RNode exposed as the serial device passed as the first argument
#
# Workflow:
# 1. Verify the script is running as root and confirm required binaries exist.
# 2. Check that the serial port exists, is free, and that the Reticulum service
#    is installed.
# 3. Read the connected device firmware version with rnodeconf and compare it
#    against the latest available RNS package version from pip.
# 4. If an update is needed, stop the service, upgrade RNS in the venv, run
#    rnodeconf --autoinstall, then restart and verify the service.
#
# The EXIT trap only performs recovery on failure. When that happens, the
# script attempts to restart SERVICE and leaves the log file in place.

TAG="rnodeconf-update"
LOGFILE="/var/log/rnode-update.log"
VENV="/var/lib/reticulum/venv"
SERVICE="reticulum"
MAX_RETRIES=3
RETRY_DELAY=5

usage() {
  cat <<EOF
Usage:
  $0 /dev/ttyUSB0 [OPTIONS]

Examples:
  sudo $0 /dev/ttyUSB0

Options:
  -h, --help                Show this help text and exit

Requirements:
  - Must be run as root or via sudo
  - systemctl and lsof available in PATH
  - ${VENV}/bin/pip and ${VENV}/bin/rnodeconf present and executable
  - Service ${SERVICE}.service installed

Files:
  - Log file: ${LOGFILE}

Behavior:
  - Skips flashing when the device firmware version matches the latest RNS version.
  - Stops ${SERVICE} before upgrade and verifies it is active again afterward.
  - On failure, attempts to restart ${SERVICE} and records details in the log.
EOF
}

# ── helpers ──────────────────────────────────────────────────────────────────

log() {
  local msg="$1"
  logger -t "${TAG}" -- "${msg}"
  printf '%s %s\n' "$(date -Is)" "${msg}" | tee -a "${LOGFILE}"
}

# retry <attempts> <delay> <cmd> [args...]
retry() {
  local attempts="$1" delay="$2"
  shift 2
  local i=1
  until "$@" 2>&1 | tee -a "${LOGFILE}" | logger -t "${TAG}"; do
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
    log "FAILED with exit code ${code}."
    log "Attempting to restart ${SERVICE} to restore service..."
    systemctl start "${SERVICE}" 2>&1 | tee -a "${LOGFILE}" || \
      log "WARNING: Could not restart ${SERVICE} — manual intervention required"
    log "Log file: ${LOGFILE}"
  fi
}

# ── preflight ─────────────────────────────────────────────────────────────────

ARG1="${1:-}"
if [[ "${ARG1}" == "-h" || "${ARG1}" == "--help" ]]; then
  usage
  exit 0
fi

if [ "$EUID" -ne 0 ]; then
  echo "[!] This script must be run as root or with sudo. Exiting."
  exit 1
fi

PORT="${ARG1}"
if [[ -z "${PORT}" ]]; then
  usage >&2
  exit 2
fi

touch "${LOGFILE}"
chmod 640 "${LOGFILE}"

trap cleanup_on_error EXIT

log "Starting RNode update on port=${PORT}"

# Dependency check
for bin in systemctl lsof; do
  command -v "${bin}" >/dev/null 2>&1 || { log "Missing dependency: ${bin}"; exit 1; }
done

if [[ ! -x "${VENV}/bin/pip" ]]; then
  log "ERROR: pip not found at ${VENV}/bin/pip — is the venv set up?"
  exit 1
fi

if [[ ! -x "${VENV}/bin/rnodeconf" ]]; then
  log "ERROR: rnodeconf not found at ${VENV}/bin/rnodeconf"
  exit 1
fi

# Check port exists
if [[ ! -c "${PORT}" ]]; then
  log "ERROR: ${PORT} does not exist or is not a character device"
  exit 1
fi

# Check port is not held by another process
if lsof "${PORT}" >/dev/null 2>&1; then
  log "ERROR: ${PORT} is in use by another process:"
  lsof "${PORT}" | tee -a "${LOGFILE}" | logger -t "${TAG}"
  exit 1
fi

# Check service exists
if ! systemctl cat "${SERVICE}.service" >/dev/null 2>&1; then
  log "ERROR: systemd service '${SERVICE}' not found"
  exit 1
fi

# ── version check ─────────────────────────────────────────────────────────────

# Compare the device's reported firmware version to the latest published RNS
# package version. If either side is unavailable, continue with the update path.
log "Checking installed firmware version on ${PORT}"
DEVICE_VERSION="$(sudo -u reticulum "${VENV}/bin/rnodeconf" --info "${PORT}" 2>&1 \
  | grep -i "Firmware version" \
  | grep -oP '\d+.\d+[\w.]*' \
  | head -n 1 || true)"

if [[ -z "${DEVICE_VERSION}" ]]; then
  log "WARNING: Could not determine device firmware version — proceeding with update anyway"
else
  log "Device firmware version: ${DEVICE_VERSION}"
fi

log "Checking latest available RNS version via pip index"
LATEST_VERSION="$(sudo -u reticulum "${VENV}/bin/pip" index versions rns 2>/dev/null \
  | grep -oP '(?<=rns \()[\d.]+(?=\))' \
  | head -n 1 || true)"

if [[ -z "${LATEST_VERSION}" ]]; then
  log "WARNING: Could not determine latest RNS version — proceeding with update anyway"
else
  log "Latest available RNS version: ${LATEST_VERSION}"
fi

if [[ -n "${DEVICE_VERSION}" && -n "${LATEST_VERSION}" ]]; then
  if [[ "${DEVICE_VERSION}" == "${LATEST_VERSION}" ]]; then
    log "Device is already running the latest firmware version (${DEVICE_VERSION}). No update needed."
    echo "Up to date. Log: ${LOGFILE}"
    exit 0
  else
    log "Update required: device=${DEVICE_VERSION} latest=${LATEST_VERSION}"
  fi
fi

# ── main ──────────────────────────────────────────────────────────────────────

log "Stopping ${SERVICE} service"
if ! systemctl stop "${SERVICE}" 2>&1 | tee -a "${LOGFILE}" | logger -t "${TAG}"; then
  log "ERROR: Failed to stop ${SERVICE}"
  exit 1
fi

log "Upgrading RNS in venv at ${VENV}"
retry "${MAX_RETRIES}" "${RETRY_DELAY}" \
  sudo -u reticulum "${VENV}/bin/pip" install --upgrade rns

# rnodeconf autoinstall updates the attached radio using the newly installed
# RNS package content from the Reticulum virtual environment.
log "Running autoinstall on RNode at ${PORT}"
retry "${MAX_RETRIES}" "${RETRY_DELAY}" \
  sudo -u reticulum "${VENV}/bin/rnodeconf" --autoinstall "${PORT}"

log "Starting ${SERVICE} service"
if ! systemctl start "${SERVICE}" 2>&1 | tee -a "${LOGFILE}" | logger -t "${TAG}"; then
  log "ERROR: Failed to start ${SERVICE} after update"
  exit 1
fi

# Give the service a moment to stabilise before checking status
sleep 3

if ! systemctl is-active --quiet "${SERVICE}"; then
  log "ERROR: ${SERVICE} started but is not active — check: journalctl -u ${SERVICE}"
  exit 1
fi

log "Done. ${SERVICE} is running."
systemctl status "${SERVICE}" --no-pager 2>&1 | tee -a "${LOGFILE}"

echo ""
echo "OK. Log: ${LOGFILE}"
