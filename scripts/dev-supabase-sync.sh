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
  (cd "$supabase_wt" && supabase db reset)
  exit 0
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
