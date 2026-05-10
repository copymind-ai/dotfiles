#!/usr/bin/env bash
set -euo pipefail

# Manage the NanoClaw host service via launchd.
# Usage: dev nanoclaw <up|down>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

case "${1:-}" in
  up)
    shift
    exec "$SCRIPT_DIR/dev-nanoclaw-up.sh" "$@"
    ;;
  down)
    shift
    exec "$SCRIPT_DIR/dev-nanoclaw-down.sh" "$@"
    ;;
  *)
    echo "Usage: dev nanoclaw <up|down>" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  up      Bootstrap NanoClaw via launchd (kickstarts a stale registration)" >&2
    echo "  down    Bootout NanoClaw via launchd" >&2
    exit 1
    ;;
esac
