#!/usr/bin/env bash
# Shared paths and build helpers for the Tally dev scripts.
# Source this file. Running it directly does nothing useful.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "Source this file from scripts/dev-build.sh, scripts/preview.sh, or scripts/install.sh." >&2
  exit 1
fi

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT/build"
DEBUG_APP="$DERIVED_DATA/Build/Products/Debug/Tally.app"
RELEASE_APP="$DERIVED_DATA/Build/Products/Release/Tally.app"
INSTALLED_APP="/Applications/Tally.app"

require_xcodebuild() {
  if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "xcodebuild is not on PATH. Install Xcode and its command line tools." >&2
    exit 1
  fi
}

ensure_project() {
  local project="$ROOT/Tally.xcodeproj/project.pbxproj"
  if [[ -f "$project" && ! "$ROOT/project.yml" -nt "$project" ]]; then
    return 0
  fi
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen is required because the Xcode project is missing or older than project.yml." >&2
    exit 1
  fi
  echo "Generating Tally.xcodeproj..."
  xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT"
}

# Quit Tally only when its executable is inside this exact bundle.
quit_app() {
  local app="$1"
  local bin="$app/Contents/MacOS/Tally"
  local pid cmd found attempt

  found=0
  while read -r pid cmd; do
    [[ -n "${pid:-}" ]] || continue
    case "$cmd" in
      "$bin"|"$bin "*)
        kill "$pid" 2>/dev/null || true
        found=1
        ;;
    esac
  done < <(ps -ax -o pid=,command=)

  [[ "$found" -eq 1 ]] || return 0

  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    found=0
    while read -r pid cmd; do
      [[ -n "${pid:-}" ]] || continue
      case "$cmd" in
        "$bin"|"$bin "*) found=1 ;;
      esac
    done < <(ps -ax -o pid=,command=)
    [[ "$found" -eq 0 ]] && return 0
    sleep 0.2
  done

  while read -r pid cmd; do
    [[ -n "${pid:-}" ]] || continue
    case "$cmd" in
      "$bin"|"$bin "*) kill -9 "$pid" 2>/dev/null || true ;;
    esac
  done < <(ps -ax -o pid=,command=)

  for attempt in 1 2 3 4 5; do
    app_is_running "$bin" || return 0
    sleep 0.2
  done
}

app_is_running() {
  local bin="$1"
  local pid cmd
  while read -r pid cmd; do
    [[ -n "${pid:-}" ]] || continue
    case "$cmd" in
      "$bin"|"$bin "*) return 0 ;;
    esac
  done < <(ps -ax -o pid=,command=)
  return 1
}

build_app() {
  local config="$1"
  local log
  log="$(mktemp "${TMPDIR:-/tmp}/tally-build.XXXXXX")"
  echo "Building ${config}..."
  if xcodebuild \
    -project "$ROOT/Tally.xcodeproj" \
    -scheme Tally \
    -configuration "$config" \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    build >"$log" 2>&1; then
    rm -f "$log"
    return 0
  fi
  tail -n 80 "$log" >&2
  rm -f "$log"
  return 1
}

app_is_detached() {
  local bin="$1"
  local pid ppid cmd
  while read -r pid ppid cmd; do
    [[ -n "${pid:-}" ]] || continue
    case "$cmd" in
      "$bin"|"$bin "*)
        [[ "$ppid" == "1" ]] && return 0
        ;;
    esac
  done < <(ps -ax -o pid=,ppid=,command=)
  return 1
}

relaunch_app() {
  local app="$1"
  local bin="$app/Contents/MacOS/Tally"
  local attempt
  quit_app "$app"
  open "$app"
  # LaunchServices needs a moment to move the app out of this shell's process group.
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if app_is_detached "$bin"; then
      return 0
    fi
    sleep 0.2
  done
  echo "Launched $app, but it was not running detached from this shell." >&2
  return 1
}
