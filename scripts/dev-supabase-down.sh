#!/usr/bin/env bash
set -euo pipefail

# Stop shared Supabase instance.
# Usage: dev sb down [--force]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/dev-supabase-helpers.sh"

if ! supabase_is_running; then
  echo "Supabase is not running."
  exit 0
fi

# Warn about active worktrees
current_wt="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$current_wt" ]; then
  parent_dir="$(cd "$current_wt/.." && pwd)"
  registry="$parent_dir/.worktree-ports"
  if [ -f "$registry" ]; then
    wt_count=$(grep -cv '^#' "$registry" || true)
    if [ "$wt_count" -gt 1 ] && [ "${1:-}" != "--force" ]; then
      echo "Warning: $wt_count worktrees are registered. Stopping Supabase will affect them all."
      read -p "Continue? [y/N] " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
      fi
    fi
  fi
fi

echo "Stopping Supabase..."
supabase stop
echo "Supabase stopped."
