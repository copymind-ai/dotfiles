#!/usr/bin/env bash
set -euo pipefail

# Bootstrap NanoClaw via launchd. Idempotent:
#   - if already running, no-op
#   - if registered but failed (PID is "-"), kickstart to retry
#   - otherwise bootstrap
#
# Usage: dev nanoclaw up

# The plist filename is per-install (e.g. com.nanoclaw-v2-<hash>.plist) so
# we glob for it rather than hardcoding the label.
shopt -s nullglob
plists=(~/Library/LaunchAgents/com.nanoclaw*.plist)
shopt -u nullglob

if [ ${#plists[@]} -eq 0 ]; then
  echo "Error: no com.nanoclaw*.plist found in ~/Library/LaunchAgents/" >&2
  echo "Hint: run /setup or check that NanoClaw was installed for this user." >&2
  exit 1
fi
if [ ${#plists[@]} -gt 1 ]; then
  echo "Warning: multiple NanoClaw plists found:" >&2
  printf '  %s\n' "${plists[@]}" >&2
  echo "Using the first one." >&2
fi

plist="${plists[0]}"
label="$(basename "$plist" .plist)"
domain="gui/$(id -u)"

# Inspect current state from launchctl list. Columns: PID  ExitStatus  Label
state="$(launchctl list 2>/dev/null | awk -v lbl="$label" '$3 == lbl { print $1 }' || true)"

if [ -n "$state" ] && [ "$state" != "-" ]; then
  echo "NanoClaw is already running (PID $state, label $label)."
  exit 0
fi

if [ -n "$state" ] && [ "$state" = "-" ]; then
  echo "Service registered but not running — kickstarting..."
  launchctl kickstart -k "$domain/$label"
else
  echo "Bootstrapping $label..."
  launchctl bootstrap "$domain" "$plist"
fi

# Give launchd a moment to spawn the process, then verify.
sleep 1
state="$(launchctl list 2>/dev/null | awk -v lbl="$label" '$3 == lbl { print $1 }' || true)"

if [ -z "$state" ]; then
  echo "Error: $label is not registered with launchd after bootstrap." >&2
  exit 1
fi

if [ "$state" = "-" ]; then
  exit_code="$(launchctl list 2>/dev/null | awk -v lbl="$label" '$3 == lbl { print $2 }' || true)"
  echo "Error: $label registered but failed to spawn (last exit code: ${exit_code:-?})." >&2
  echo "Check logs/nanoclaw.error.log in the NanoClaw repo." >&2
  exit 1
fi

echo "NanoClaw is up (PID $state, label $label)."
