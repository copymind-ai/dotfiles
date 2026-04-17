#!/usr/bin/env bash
set -euo pipefail

# Manage shared local Supabase instance (one per repo, shared across worktrees).
# Usage: dev supabase <up|down|status|sync>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

case "${1:-}" in
  up)
    shift
    exec "$SCRIPT_DIR/dev-supabase-up.sh" "$@"
    ;;
  down)
    shift
    exec "$SCRIPT_DIR/dev-supabase-down.sh" "$@"
    ;;
  status)
    shift
    exec "$SCRIPT_DIR/dev-supabase-status.sh" "$@"
    ;;
  sync)
    shift
    exec "$SCRIPT_DIR/dev-supabase-sync.sh" "$@"
    ;;
  *)
    echo "Usage: dev supabase <up|down|status|sync>" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  up              Create supabase worktree and start Supabase" >&2
    echo "  down [--force]  Stop shared Supabase instance" >&2
    echo "  status          Show Supabase status" >&2
    echo "  sync [--reset]  Fetch origin/main, update hub, clean stale symlinks" >&2
    exit 1
    ;;
esac
