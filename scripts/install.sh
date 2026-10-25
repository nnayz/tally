#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  echo "Usage: scripts/install.sh"
  echo "Build the Release app and copy it to /Applications/Tally.app."
  echo "This will not install an ad-hoc or unsandboxed app, replace a bundle whose id is not com.nnayz.tally, or strip the quarantine attribute."
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_xcodebuild
ensure_project
build_app Release

refuse() {
  echo "$1" >&2
  echo "This script will not install an ad-hoc, unsandboxed app or strip quarantine." >&2
  exit 1
}

signature="$(codesign -dvvv "$RELEASE_APP" 2>&1 || true)"
if grep -Eq 'Signature=adhoc|flags=0x2\(adhoc\)' <<<"$signature"; then
  refuse "Refusing to install: $RELEASE_APP is ad-hoc signed."
fi

entitlements="$(codesign -d --entitlements :- "$RELEASE_APP" 2>&1 || true)"
if ! grep -A1 'com.apple.security.app-sandbox' <<<"$entitlements" | grep -q '<true/>'; then
  refuse "Refusing to install: $RELEASE_APP has no app sandbox entitlement."
fi

built_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$RELEASE_APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$built_id" != "com.nnayz.tally" ]]; then
  refuse "Refusing to install: $RELEASE_APP bundle id is '${built_id}'."
fi

if [[ -d "$INSTALLED_APP" ]]; then
  installed_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$installed_id" != "com.nnayz.tally" ]]; then
    refuse "Refusing to replace $INSTALLED_APP because its bundle id is '${installed_id}', not com.nnayz.tally."
  fi
fi

if [[ ! -w /Applications ]]; then
  echo "/Applications is not writable from this session. Install stopped." >&2
  exit 1
fi

quit_app "$INSTALLED_APP"
rm -rf "$INSTALLED_APP"
ditto "$RELEASE_APP" "$INSTALLED_APP"
relaunch_app "$INSTALLED_APP"
echo "Installed $INSTALLED_APP"
