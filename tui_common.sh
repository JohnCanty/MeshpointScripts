#!/usr/bin/env bash

# Shared interactive helper library for the updater scripts in this repository.
#
# Design contract:
# - Source this file from Bash scripts that already run with strict mode enabled.
# - Prompts are written to stderr and returned values are written to stdout so
#   callers can safely capture selections with command substitution.
# - Helpers should avoid global side effects beyond terminal interaction.
# - Non-interactive callers should fail fast through tui_require_terminal().
#
# Function groups:
# - tui_select_menu() and tui_prompt_*() provide generic menu and input helpers.
# - tui_select_serial_port() discovers common Linux serial device paths and
#   falls back to manual entry when nothing suitable is found.
#
# Support notes:
# - Keep returned values normalized because caller scripts branch on exact strings.
# - If you add a helper here, document the contract in this header and keep it safe
#   for callers running with set -euo pipefail.

tui_require_terminal() {
  if [[ ! -t 0 || ! -t 1 ]]; then
    echo "ERROR: --tui requires an interactive terminal." >&2
    return 1
  fi
}

tui_print_heading() {
  local heading="$1"
  printf '\n%s\n' "$heading" >&2
}

tui_select_menu() {
  local prompt="$1"
  shift
  local options=("$@")
  local choice
  local REPLY
  local PS3="Select an option: "

  while true; do
    printf '%s\n' "$prompt" >&2
    select choice in "${options[@]}"; do
      if [[ -n "${choice:-}" ]]; then
        printf '%s\n' "$choice"
        return 0
      fi
      printf 'Invalid selection.\n' >&2
      break
    done
  done
}

tui_prompt_input() {
  local prompt="$1"
  local default_value="${2:-}"
  local value

  if [[ -n "$default_value" ]]; then
    printf '%s [%s]: ' "$prompt" "$default_value" >&2
  else
    printf '%s: ' "$prompt" >&2
  fi

  read -r value
  if [[ -z "$value" ]]; then
    value="$default_value"
  fi

  printf '%s\n' "$value"
}

tui_prompt_yes_no() {
  local prompt="$1"
  local default_choice="${2:-No}"
  local choice

  if [[ "$default_choice" == "Yes" ]]; then
    choice="$(tui_select_menu "$prompt" "Yes" "No")"
  else
    choice="$(tui_select_menu "$prompt" "No" "Yes")"
  fi

  if [[ "$choice" == "Yes" ]]; then
    printf '1\n'
  else
    printf '0\n'
  fi
}

tui_prompt_default_or_custom() {
  local label="$1"
  local default_value="$2"
  local choice

  choice="$(tui_select_menu "$label" "Use default (${default_value})" "Enter custom value")"
  if [[ "$choice" == "Enter custom value" ]]; then
    tui_prompt_input "Enter value" "$default_value"
  else
    printf '%s\n' "$default_value"
  fi
}

tui_select_serial_port() {
  local prompt="$1"
  local custom_label="Enter custom path"
  local -a ports=()
  local port
  local choice

  while IFS= read -r port; do
    [[ -n "$port" ]] && ports+=("$port")
  done < <(
    {
      shopt -s nullglob
      for port in /dev/serial/by-id/* /dev/ttyUSB* /dev/ttyACM*; do
        [[ -e "$port" ]] && printf '%s\n' "$port"
      done
      shopt -u nullglob
    } | awk '!seen[$0]++'
  )

  if (( ${#ports[@]} == 0 )); then
    tui_prompt_input "$prompt" "/dev/ttyUSB0"
    return 0
  fi

  choice="$(tui_select_menu "$prompt" "${ports[@]}" "$custom_label")"
  if [[ "$choice" == "$custom_label" ]]; then
    tui_prompt_input "Enter serial port path" "${ports[0]}"
  else
    printf '%s\n' "$choice"
  fi
}