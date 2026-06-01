#!/usr/bin/env bash
set -Eeuo pipefail

# Convenience entry point for refreshing the managed MeshpointScripts files from
# the public main branch of this repository.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/update_meshpoint_scripts.sh" "$@"