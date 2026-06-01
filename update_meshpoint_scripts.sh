#!/usr/bin/env bash
set -Eeuo pipefail

# MeshpointScripts self-updater.
#
# Operator summary:
# - Run inside a clone of this repository, typically ~/MeshpointScripts, to refresh the managed scripts from the public main branch.
# - The recommended operator entry point is ./update.sh, which forwards to this script.
# - Use --check to see which files would change before anything is written.
#
# Intended environment:
# - Local clone of this repository, typically at ~/MeshpointScripts, with git metadata available.
# - Public network access to the repository's GitHub remote over HTTPS.
# - Standard Unix tools available: cmp, git, install, mkdir, and tee.
#
# Workflow:
# 1. Resolve the repository root and a public HTTPS URL for the upstream repo.
# 2. Fetch the requested branch into FETCH_HEAD without prompting for credentials.
# 3. Refuse to overwrite locally modified managed files unless --force is set.
# 4. Compare each managed file against FETCH_HEAD and install only changed files.
# 5. Update this script last so the running process is not replaced mid-run.
#
# Maintainer map:
# - TARGET_FILES defines the only files this updater manages.
# - derive_public_repo_url() normalizes common GitHub remote URL formats to HTTPS.
# - fetch_remote_branch() refreshes FETCH_HEAD from the requested public branch.
# - materialize_remote_file() and install_remote_file() copy fetched files into the worktree.
# - apply_updates() is the main loop and updates this script last.
#
# Support notes:
# - The script intentionally updates only TARGET_FILES, not arbitrary repo content.
# - Local changes in managed files block updates unless --force is used.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"

TAG="meshpoint-scripts-self-update"
REMOTE_NAME="origin"
BRANCH_NAME="main"
REPO_URL=""
LOG_FILE=""
FORCE="0"
CHECK_ONLY="0"
REMOTE_REF="FETCH_HEAD"
TEMP_DIR=""
UPDATED_FILES=()
TARGET_FILES=(
  README.md
  github_release_common.sh
  tui_common.sh
  update.sh
  update_meshcore.sh
  update_meshtastic.sh
  update_reticulum.sh
  update_meshpoint_scripts.sh
)

usage() {
  cat <<EOF
Usage:
  $0 [OPTIONS]

Examples:
  cd ~/MeshpointScripts && ./update.sh
  cd ~/MeshpointScripts && ./update.sh --check
  ./update.sh
  ./update.sh --check
  $0 --check
  $0
  $0 --force
  $0 --branch main --remote origin
  $0 --repo-url https://github.com/JohnCanty/MeshpointScripts.git --check

Options:
  --remote NAME           Git remote to inspect for the repository URL (default: origin)
  --branch NAME           Branch to fetch from the public repo URL (default: main)
  --repo-url URL          Override the public repo URL used for fetches
  --check                 Report which managed files would change, but do not write them
  --force                 Overwrite managed files even when they have local changes
  --log-file PATH         Log file path (default: stdout only)
  -h, --help              Show this help text and exit

Managed files:
  README.md
  github_release_common.sh
  tui_common.sh
  update.sh
  update_meshcore.sh
  update_meshtastic.sh
  update_reticulum.sh
  update_meshpoint_scripts.sh

Location:
  Run this script from inside your local clone, for example ~/MeshpointScripts

Behavior:
  - Fetches the requested branch into FETCH_HEAD using a public HTTPS URL.
  - Refuses to overwrite locally modified managed files unless --force is set.
  - Updates this script last so it can safely refresh itself in place.
EOF
}

log() {
  local timestamp
  local line

  if timestamp="$(date -Is 2>/dev/null)"; then
    :
  else
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  fi

  line="${timestamp} $*"
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s\n' "$line" | tee -a "$LOG_FILE"
  else
    printf '%s\n' "$line"
  fi
}

die() {
  log "ERROR: $*"
  exit 1
}

need_arg() {
  [[ $# -ge 2 && -n "${2:-}" ]] || die "Option $1 requires a value"
}

cleanup() {
  local rc=$?
  [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
  [[ $rc -eq 0 ]] || log "Script exited with code $rc"
}
trap cleanup EXIT

on_err() {
  local code=$?
  log "FAIL (exit=$code) at line ${BASH_LINENO[0]}: ${BASH_COMMAND}"
}
trap on_err ERR

derive_public_repo_url() {
  local configured_url

  configured_url="$(git -C "$REPO_DIR" config --get "remote.${REMOTE_NAME}.url" || true)"
  [[ -n "$configured_url" ]] || die "Git remote '${REMOTE_NAME}' is not configured"

  case "$configured_url" in
    git@github.com:*)
      printf 'https://github.com/%s\n' "${configured_url#git@github.com:}"
      ;;
    ssh://git@github.com/*)
      printf 'https://github.com/%s\n' "${configured_url#ssh://git@github.com/}"
      ;;
    http://github.com/*)
      printf 'https://github.com/%s\n' "${configured_url#http://github.com/}"
      ;;
    *)
      printf '%s\n' "$configured_url"
      ;;
  esac
}

fetch_remote_branch() {
  log "Fetching ${BRANCH_NAME} from ${REPO_URL}"
  GIT_TERMINAL_PROMPT=0 git -C "$REPO_DIR" fetch --quiet "$REPO_URL" "refs/heads/${BRANCH_NAME}" \
    || die "Failed to fetch ${BRANCH_NAME} from ${REPO_URL}"

  git -C "$REPO_DIR" rev-parse --verify --quiet "${REMOTE_REF}^{commit}" >/dev/null \
    || die "FETCH_HEAD does not reference a valid commit after fetch"
}

remote_file_exists() {
  local file="$1"
  git -C "$REPO_DIR" cat-file -e "${REMOTE_REF}:${file}" 2>/dev/null
}

ensure_target_is_safe() {
  local file="$1"
  local has_local_changes="$2"

  [[ "$FORCE" == "1" || "$CHECK_ONLY" == "1" ]] && return 0
  [[ "$has_local_changes" == "0" ]] || die "Local changes detected in ${file}; commit/stash them or rerun with --force"
}

target_has_local_changes() {
  local file="$1"
  local dirty_output

  dirty_output="$(git -C "$REPO_DIR" status --porcelain -- "$file")"
  if [[ -n "$dirty_output" ]]; then
    printf '1\n'
  else
    printf '0\n'
  fi
}

materialize_remote_file() {
  local file="$1"
  local output_path="$TEMP_DIR/$file"

  mkdir -p "$(dirname "$output_path")"
  git -C "$REPO_DIR" show "${REMOTE_REF}:${file}" > "$output_path" \
    || die "Failed to read ${file} from ${REMOTE_REF}"

  printf '%s\n' "$output_path"
}

remote_file_mode() {
  local file="$1"
  local mode

  mode="$(git -C "$REPO_DIR" ls-tree "$REMOTE_REF" -- "$file" | awk 'NR==1 {print $1}')"
  [[ -n "$mode" ]] || die "Could not determine file mode for ${file} in ${REMOTE_REF}"
  printf '%s\n' "$mode"
}

install_remote_file() {
  local file="$1"
  local source_path="$2"
  local destination_path="$REPO_DIR/$file"
  local mode

  mode="$(remote_file_mode "$file")"
  mkdir -p "$(dirname "$destination_path")"

  case "$mode" in
    100755)
      install -m 0755 "$source_path" "$destination_path"
      ;;
    *)
      install -m 0644 "$source_path" "$destination_path"
      ;;
  esac
}

apply_updates() {
  local file
  local has_local_changes
  local source_path

  for file in "${TARGET_FILES[@]}"; do
    has_local_changes="$(target_has_local_changes "$file")"
    ensure_target_is_safe "$file" "$has_local_changes"

    if ! remote_file_exists "$file"; then
      log "Skipping ${file}: not present in ${BRANCH_NAME} at ${REPO_URL}"
      continue
    fi

    source_path="$(materialize_remote_file "$file")"

    if [[ -e "$REPO_DIR/$file" ]] && cmp -s "$REPO_DIR/$file" "$source_path"; then
      log "Unchanged: ${file}"
      continue
    fi

    if [[ "$CHECK_ONLY" == "1" ]]; then
      if [[ "$has_local_changes" == "1" ]]; then
        log "Would update and overwrite local changes: ${file}"
      else
        log "Would update: ${file}"
      fi
      continue
    fi

    install_remote_file "$file" "$source_path"
    UPDATED_FILES+=("$file")
    log "Updated: ${file}"
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote)
      need_arg "$@"
      REMOTE_NAME="$2"
      shift 2
      ;;
    --branch)
      need_arg "$@"
      BRANCH_NAME="$2"
      shift 2
      ;;
    --repo-url)
      need_arg "$@"
      REPO_URL="$2"
      shift 2
      ;;
    --log-file)
      need_arg "$@"
      LOG_FILE="$2"
      shift 2
      ;;
    --check)
      CHECK_ONLY="1"
      shift
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
    -* )
      die "Unknown option: $1"
      ;;
    *)
      die "Unexpected argument: $1"
      ;;
  esac
done

[[ -n "$REPO_DIR" ]] || die "This script must be run from inside a git clone of MeshpointScripts (for example ~/MeshpointScripts)"
[[ -d "$REPO_DIR/.git" || -f "$REPO_DIR/.git" ]] || die "Could not find git metadata for ${REPO_DIR}"

if [[ -n "$LOG_FILE" ]]; then
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
fi

if [[ -z "$REPO_URL" ]]; then
  REPO_URL="$(derive_public_repo_url)"
fi

TEMP_DIR="$(mktemp -d)"

log "Starting MeshpointScripts self-update from ${REPO_URL} (${BRANCH_NAME})"
fetch_remote_branch
apply_updates

if [[ "$CHECK_ONLY" == "1" ]]; then
  log "Check complete. No files were written."
elif (( ${#UPDATED_FILES[@]} == 0 )); then
  log "Managed files are already current."
else
  log "SUCCESS: updated ${#UPDATED_FILES[@]} file(s): ${UPDATED_FILES[*]}"
fi