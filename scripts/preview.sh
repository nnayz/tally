#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  echo "Usage: scripts/preview.sh"
  echo "Rebuild and relaunch the Debug app whenever UI sources change. Ctrl-C stops watching and leaves the app running."
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_xcodebuild
ensure_project

reload() {
  ensure_project
  if build_app Debug; then
    relaunch_app "$DEBUG_APP"
    echo "Reloaded $DEBUG_APP"
    return 0
  fi
  echo "Build failed. The last good app is still running." >&2
  return 0
}

source_stamp() {
  {
    find "$ROOT/Tally" -type f \
      \( -name '*.swift' -o -name '*.plist' -o -name '*.json' -o -name '*.png' \) \
      ! -name '.DS_Store' -print0
    printf '%s\0' "$ROOT/project.yml"
  } | xargs -0 stat -f '%m %N' 2>/dev/null | shasum | awk '{print $1}'
}

watch_with_fswatch() {
  fswatch -o -l 0.4 -e '/\.DS_Store$' "$ROOT/Tally" "$ROOT/project.yml" | while read -r _; do
    reload
  done
}

watch_by_polling() {
  local last now
  last="$(source_stamp)"
  while true; do
    sleep 0.5
    now="$(source_stamp)"
    if [[ "$now" != "$last" ]]; then
      sleep 0.4
      last="$(source_stamp)"
      reload
    fi
  done
}

trap 'echo "Stopped watching. $DEBUG_APP is still running."; exit 0' INT TERM

reload
echo "Watching Tally/ for changes. Ctrl-C to stop."

if command -v fswatch >/dev/null 2>&1; then
  watch_with_fswatch
else
  echo "fswatch is not installed. Checking for changes twice a second."
  watch_by_polling
fi
