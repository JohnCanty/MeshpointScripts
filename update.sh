#!/usr/bin/env bash
set -Eeuo pipefail

# Convenience entry point for refreshing the managed MeshpointScripts files from
# the public main branch of this repository. With the recommended clone layout,
# this entry point lives at ~/MeshpointScripts/update.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/update_meshpoint_scripts.sh" "$@"