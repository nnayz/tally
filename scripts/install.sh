#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  echo "Usage: scripts/install.sh"
  echo "Build the Release app and copy it to /Applications/Tally.app."
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_xcodebuild
ensure_project
build_app Release

if [[ ! -w /Applications ]]; then
  echo "/Applications is not writable from this session. Install stopped." >&2
  exit 1
fi

quit_app "$INSTALLED_APP"
rm -rf "$INSTALLED_APP"
ditto "$RELEASE_APP" "$INSTALLED_APP"
xattr -dr com.apple.quarantine "$INSTALLED_APP" 2>/dev/null || true
relaunch_app "$INSTALLED_APP"
echo "Installed $INSTALLED_APP"
