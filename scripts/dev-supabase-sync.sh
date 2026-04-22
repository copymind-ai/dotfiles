#!/usr/bin/env bash
set -euo pipefail

# Fetch origin/main, update supabase worktree, clean stale symlinks, apply migrations.
# Usage: dev sb sync [--reset]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/dev-supabase-helpers.sh"

require_bare_repo

if ! supabase_is_running; then
  echo "Error: Supabase is not running. Start it first: dev sb up" >&2
  exit 1
fi

supabase_wt="$(resolve_supabase_wt)"

if [ ! -d "$supabase_wt" ]; then
  echo "Error: Supabase worktree not found. Run: dev sb up" >&2
  exit 1
fi

if [ "${1:-}" = "--reset" ]; then
  echo "Resetting database (applying all migrations from scratch)..."
  supabase_db_reset_with_retry "$supabase_wt"
  exit 0
fi

ensure_fetch_refspec

# Fetch and update supabase worktree to origin/main
echo "Fetching origin..."
git fetch origin
echo "Updating supabase worktree to origin/main..."
(cd "$supabase_wt" && git checkout -f origin/main) 2>&1 | grep -v "^HEAD is now at" || true

# Clean up stale symlinks from all worktrees
clean_all_stale_symlinks "$supabase_wt"

# Apply migrations
apply_migrations "$supabase_wt"

echo ""
echo "=== Supabase synced ==="
echo "  Updated to: origin/main"
