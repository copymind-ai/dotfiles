#!/usr/bin/env bash
set -euo pipefail

# Manage shared local Supabase instance (one per repo, shared across worktrees).
# Usage: dev supabase <up|down|status|migrate>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Require supabase CLI ---
if ! command -v supabase &>/dev/null; then
  echo "Error: supabase CLI not found. Install via: brew install supabase/tap/supabase" >&2
  exit 1
fi

# --- Require supabase/config.toml ---
require_supabase_project() {
  if [ ! -f "supabase/config.toml" ]; then
    echo "Error: No supabase/config.toml found in $(pwd)." >&2
    echo "This directory is not a Supabase project." >&2
    exit 1
  fi
}

supabase_is_running() {
  supabase status --output json >/dev/null 2>&1
}

# --- Commands ---

cmd_up() {
  require_supabase_project

  if supabase_is_running; then
    echo "Supabase is already running."
    supabase status
    return
  fi

  echo "Starting Supabase..."
  echo "(First run pulls ~10 Docker images and may take a few minutes)"
  supabase start
}

cmd_down() {
  require_supabase_project

  if ! supabase_is_running; then
    echo "Supabase is not running."
    return
  fi

  # Warn about active worktrees
  CURRENT_WORKTREE="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$CURRENT_WORKTREE" ]; then
    PARENT_DIR="$(cd "$CURRENT_WORKTREE/.." && pwd)"
    REGISTRY="$PARENT_DIR/.worktree-ports"
    if [ -f "$REGISTRY" ]; then
      WORKTREE_COUNT=$(grep -cv '^#' "$REGISTRY" || true)
      if [ "$WORKTREE_COUNT" -gt 1 ] && [ "${1:-}" != "--force" ]; then
        echo "Warning: $WORKTREE_COUNT worktrees are registered. Stopping Supabase will affect them all."
        read -p "Continue? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
          echo "Aborted."
          return
        fi
      fi
    fi
  fi

  echo "Stopping Supabase..."
  supabase stop
  echo "Supabase stopped."
}

cmd_status() {
  require_supabase_project

  if supabase_is_running; then
    supabase status
  else
    echo "Supabase is not running."
    echo "  To start: dev supabase up"
  fi
}

cmd_migrate() {
  require_supabase_project

  if ! supabase_is_running; then
    echo "Error: Supabase is not running. Start it first: dev supabase up" >&2
    exit 1
  fi

  if [ "${1:-}" = "--reset" ]; then
    echo "Resetting database (applying all migrations from scratch)..."
    supabase db reset
  else
    echo "Applying pending migrations..."
    supabase migration up
  fi
}

# --- Dispatch ---
case "${1:-}" in
  up)
    shift
    cmd_up "$@"
    ;;
  down)
    shift
    cmd_down "$@"
    ;;
  status)
    shift
    cmd_status "$@"
    ;;
  migrate)
    shift
    cmd_migrate "$@"
    ;;
  *)
    echo "Usage: dev supabase <up|down|status|migrate>" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  up                Start shared Supabase instance" >&2
    echo "  down [--force]    Stop shared Supabase instance" >&2
    echo "  status            Show Supabase status" >&2
    echo "  migrate [--reset] Apply pending migrations (or reset all)" >&2
    exit 1
    ;;
esac
