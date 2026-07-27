#!/usr/bin/env bash
set -euo pipefail

# Bootout NanoClaw via launchd. Idempotent: no-op if not registered.
# Usage: dev nanoclaw down

shopt -s nullglob
plists=(~/Library/LaunchAgents/com.nanoclaw*.plist)
shopt -u nullglob

if [ ${#plists[@]} -eq 0 ]; then
  echo "Error: no com.nanoclaw*.plist found in ~/Library/LaunchAgents/" >&2
  exit 1
fi

label="$(basename "${plists[0]}" .plist)"
domain="gui/$(id -u)"

# Is the service known to launchd at all?
if ! launchctl list 2>/dev/null | awk -v lbl="$label" '$3 == lbl { found=1 } END { exit !found }'; then
  echo "NanoClaw ($label) is already down."
  exit 0
fi

echo "Booting out $label..."
launchctl bootout "$domain/$label"

# Verify.
sleep 1
if launchctl list 2>/dev/null | awk -v lbl="$label" '$3 == lbl { found=1 } END { exit !found }'; then
  echo "Error: $label is still registered after bootout." >&2
  exit 1
fi

echo "NanoClaw is down."
