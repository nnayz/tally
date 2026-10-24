#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  echo "Usage: scripts/dev-build.sh"
  echo "Build the Debug app and relaunch the menu bar item."
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_xcodebuild
ensure_project
build_app Debug
relaunch_app "$DEBUG_APP"
echo "Running $DEBUG_APP"
