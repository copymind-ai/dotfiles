#!/usr/bin/env bash
set -euo pipefail

# Manage shared local Supabase instance (one per repo, shared across worktrees).
# Usage: dev supabase <up|down|status|sync>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Require supabase CLI ---
if ! command -v supabase &>/dev/null; then
  echo "Error: supabase CLI not found. Install via: brew install supabase/tap/supabase" >&2
  exit 1
fi

# --- Helpers ---

require_bare_repo() {
  local git_common_dir
  git_common_dir="$(git rev-parse --git-common-dir)"
  if ! git -C "$git_common_dir" rev-parse --is-bare-repository 2>/dev/null | grep -q "true"; then
    echo "Error: You should clone the repo with --bare flag enabled to use the worktree setup script." >&2
    exit 1
  fi
}

supabase_is_running() {
  supabase status --output json >/dev/null 2>&1
}

resolve_supabase_wt() {
  local current_wt parent_dir
  current_wt="$(git rev-parse --show-toplevel)"
  parent_dir="$(cd "$current_wt/.." && pwd)"
  echo "$parent_dir/supabase"
}

ensure_fetch_refspec() {
  if ! git config --get remote.origin.fetch &>/dev/null; then
    git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
  fi
}

# --- Commands ---

cmd_up() {
  require_bare_repo

  local supabase_wt
  supabase_wt="$(resolve_supabase_wt)"

  ensure_fetch_refspec

  echo "Fetching origin..."
  git fetch origin

  # Create or update supabase worktree
  if [ -d "$supabase_wt" ]; then
    echo "Updating supabase worktree to origin/main..."
    (cd "$supabase_wt" && git checkout -f origin/main) 2>&1 | grep -v "^HEAD is now at" || true
  else
    echo "Creating supabase worktree..."
    git worktree add "$supabase_wt" --detach origin/main
  fi

  # Start Supabase if not running
  if supabase_is_running; then
    echo "Supabase already running."
  else
    echo "Starting Supabase..."
    echo "(First run pulls ~10 Docker images and may take a few minutes)"
    (cd "$supabase_wt" && supabase start)
  fi

  # Apply origin/main migrations
  echo "Applying origin/main migrations..."
  if [ -x "$supabase_wt/scripts/db-migrate-local.sh" ]; then
    (cd "$supabase_wt" && ./scripts/db-migrate-local.sh)
  else
    (cd "$supabase_wt" && supabase migration up --local)
  fi

  # Inject env vars
  echo "Injecting Supabase env vars..."
  (cd "$supabase_wt" && "$SCRIPT_DIR/dev-worktree-env.sh")

  echo ""
  echo "=== Supabase hub ready ==="
  echo "  Worktree: $supabase_wt"
  echo "  Branch:   origin/main (detached)"
  echo ""
  echo "To sync after rebase: dev sb sync"
}

cmd_down() {
  if ! supabase_is_running; then
    echo "Supabase is not running."
    return
  fi

  # Warn about active worktrees
  local current_wt parent_dir registry
  current_wt="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$current_wt" ]; then
    parent_dir="$(cd "$current_wt/.." && pwd)"
    registry="$parent_dir/.worktree-ports"
    if [ -f "$registry" ]; then
      local wt_count
      wt_count=$(grep -cv '^#' "$registry" || true)
      if [ "$wt_count" -gt 1 ] && [ "${1:-}" != "--force" ]; then
        echo "Warning: $wt_count worktrees are registered. Stopping Supabase will affect them all."
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
  if supabase_is_running; then
    supabase status
  else
    echo "Supabase is not running."
    echo "  To start: dev sb up"
  fi
}

cmd_sync() {
  require_bare_repo

  if ! supabase_is_running; then
    echo "Error: Supabase is not running. Start it first: dev sb up" >&2
    exit 1
  fi

  local supabase_wt
  supabase_wt="$(resolve_supabase_wt)"

  if [ ! -d "$supabase_wt" ]; then
    echo "Error: Supabase worktree not found. Run: dev sb up" >&2
    exit 1
  fi

  if [ "${1:-}" = "--reset" ]; then
    echo "Resetting database (applying all migrations from scratch)..."
    (cd "$supabase_wt" && supabase db reset)
    return
  fi

  ensure_fetch_refspec

  # Fetch and update hub to origin/main
  echo "Fetching origin..."
  git fetch origin
  echo "Updating supabase worktree to origin/main..."
  (cd "$supabase_wt" && git checkout -f origin/main) 2>&1 | grep -v "^HEAD is now at" || true

  # Clean up stale symlinks from all worktrees
  "$SCRIPT_DIR/dev-worktree-migrate.sh" clean-all "$supabase_wt"

  # Apply migrations
  echo "Applying migrations..."
  if [ -x "$supabase_wt/scripts/db-migrate-local.sh" ]; then
    (cd "$supabase_wt" && ./scripts/db-migrate-local.sh)
  else
    (cd "$supabase_wt" && supabase migration up --local)
  fi

  echo ""
  echo "=== Supabase hub synced ==="
  echo "  Updated to: origin/main"
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
  sync)
    shift
    cmd_sync "$@"
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
