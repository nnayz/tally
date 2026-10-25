#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  echo "Usage: scripts/install.sh"
  echo "Build the Release app, replace /Applications/Tally.app, and open it."
  echo "Refuses to replace a bundle whose id is not com.nnayz.tally."
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_xcodebuild
ensure_project
build_app Release

built_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$RELEASE_APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$built_id" != "com.nnayz.tally" ]]; then
  echo "Refusing to install: $RELEASE_APP bundle id is '${built_id}'." >&2
  exit 1
fi

if [[ -d "$INSTALLED_APP" ]]; then
  installed_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$installed_id" != "com.nnayz.tally" ]]; then
    echo "Refusing to replace $INSTALLED_APP because its bundle id is '${installed_id}', not com.nnayz.tally." >&2
    exit 1
  fi
fi

if [[ ! -w /Applications ]]; then
  echo "/Applications is not writable from this session. Install stopped." >&2
  exit 1
fi

quit_app "$INSTALLED_APP"
if [[ -d "$INSTALLED_APP" ]]; then
  echo "Removing $INSTALLED_APP"
  rm -rf "$INSTALLED_APP"
fi
ditto "$RELEASE_APP" "$INSTALLED_APP"
relaunch_app "$INSTALLED_APP"
echo "Installed $INSTALLED_APP"
